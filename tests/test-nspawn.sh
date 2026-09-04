#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
source_image=${1:-$project_dir/_build/amnezia-gate-rootfs.squashfs}
[[ $EUID -eq 0 ]] || {
    printf 'test-nspawn: run as root\n' >&2
    exit 1
}
[[ -r $source_image ]] || {
    printf 'test-nspawn: rootfs image not found: %s\n' "$source_image" >&2
    exit 1
}

test_dir=$(mktemp -d /tmp/amnezia-gate-smoke.XXXXXX)
profile_root=$test_dir/profiles
runtime_root=$test_dir/run
rootfs_image=$test_dir/rootfs.squashfs
smoke_unit=amnezia-gate-smoke.service
lan_namespace=amnezia-gate-smoke-lan
lan_host_interface=ag1000lh
original_forwarding=$(</proc/sys/net/ipv4/ip_forward)
journal_since=$(date --iso-8601=seconds)

cleanup() {
    set +e
    systemctl stop "$smoke_unit" >/dev/null 2>&1
    systemctl reset-failed "$smoke_unit" >/dev/null 2>&1
    AMNEZIA_PROFILE_ROOT="$profile_root" \
        AMNEZIA_PROFILE_RUNTIME_ROOT="$runtime_root" \
        "$project_dir/host/amnezia-gate-run" cleanup Smoke >/dev/null 2>&1
    ip link delete dev "$lan_host_interface" >/dev/null 2>&1
    ip netns delete "$lan_namespace" >/dev/null 2>&1
    printf '%s\n' "$original_forwarding" >/proc/sys/net/ipv4/ip_forward
    rm -rf -- "$test_dir"
}
trap cleanup EXIT

mkdir -p "$profile_root/Smoke"
cp --reflink=auto "$source_image" "$rootfs_image"
if [[ -e /sys/fs/selinux/enforce ]]; then
    chcon -u system_u -r object_r -t container_ro_file_t -l s0 "$rootfs_image"
fi

private_key=$(/usr/bin/awg genkey)
peer_private=$(/usr/bin/awg genkey)
peer_public=$(printf '%s\n' "$peer_private" | /usr/bin/awg pubkey)
cat >"$profile_root/Smoke/awg0.conf" <<EOF
[Interface]
Address = 10.255.255.2/32
PrivateKey = $private_key
Table = off

[Peer]
PublicKey = $peer_public
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.1:51820
EOF
chmod 0600 "$profile_root/Smoke/awg0.conf"

cat >"$profile_root/Smoke/profile.env" <<EOF
PROFILE_NAME=Smoke
ROOTFS_IMAGE=$rootfs_image
NETWORK_PREFIX=10.231
NETWORK_SLOT=1000
LISTEN_ADDRESS=0.0.0.0
LAN_CIDRS=127.0.0.0/8,198.18.0.0/30
FORWARD_COMPAT=auto
SOCKS_PORT=19080
HTTP_PORT=19081
DNS_SERVERS=1.1.1.1,1.0.0.1
DNS_TLS_SERVERS=9.9.9.9@853#dns.quad9.net
EOF
chmod 0600 "$profile_root/Smoke/profile.env"

printf '1\n' >/proc/sys/net/ipv4/ip_forward
AMNEZIA_PROFILE_ROOT="$profile_root" \
    AMNEZIA_PROFILE_RUNTIME_ROOT="$runtime_root" \
    "$project_dir/host/amnezia-gate-run" prepare Smoke

ip netns delete "$lan_namespace" >/dev/null 2>&1 || true
ip link delete dev "$lan_host_interface" >/dev/null 2>&1 || true
ip netns add "$lan_namespace"
ip link add name "$lan_host_interface" type veth peer name ag1000lc
ip link set dev ag1000lc netns "$lan_namespace"
ip address add 198.18.0.1/30 dev "$lan_host_interface"
ip link set dev "$lan_host_interface" up
ip -n "$lan_namespace" address add 198.18.0.2/30 dev ag1000lc
ip -n "$lan_namespace" link set dev lo up
ip -n "$lan_namespace" link set dev ag1000lc up
ip -n "$lan_namespace" route add default via 198.18.0.1

systemd-run \
    --unit="${smoke_unit%.service}" \
    --slice=machine.slice \
    --property=Type=simple \
    --property=SELinuxContext=system_u:system_r:container_runtime_t:s0 \
    --property=Delegate=yes \
    --property=KillMode=mixed \
    --property=TimeoutStopSec=20s \
    --property='RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' \
    --property=DevicePolicy=closed \
    --property='DeviceAllow=/dev/net/tun rwm' \
    --property='DeviceAllow=/dev/loop-control rw' \
    --property='DeviceAllow=block-loop rw' \
    --setenv="AMNEZIA_PROFILE_ROOT=$profile_root" \
    --setenv="AMNEZIA_PROFILE_RUNTIME_ROOT=$runtime_root" \
    /bin/bash "$project_dir/host/amnezia-gate-run" run Smoke >/dev/null

ready=0
for _ in {1..40}; do
    if timeout 0.5 bash -c 'exec 3<>/dev/tcp/10.231.15.162/1080' 2>/dev/null &&
       timeout 0.5 bash -c 'exec 3<>/dev/tcp/10.231.15.162/10080' 2>/dev/null &&
       timeout 0.5 bash -c 'exec 3<>/dev/tcp/10.231.15.162/53' 2>/dev/null &&
       timeout 0.5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/19080' 2>/dev/null &&
       timeout 0.5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/19081' 2>/dev/null &&
       ip netns exec "$lan_namespace" \
           timeout 0.5 bash -c 'exec 3<>/dev/tcp/198.18.0.1/19080' 2>/dev/null &&
       ip netns exec "$lan_namespace" \
           timeout 0.5 bash -c 'exec 3<>/dev/tcp/198.18.0.1/19081' 2>/dev/null; then
        ready=1
        break
    fi
    if ! systemctl is-active --quiet "$smoke_unit"; then
        journalctl --no-pager -u "$smoke_unit" --since "$journal_since" >&2
        exit 1
    fi
    sleep 0.25
done

if (( ! ready )); then
    journalctl --no-pager -u "$smoke_unit" --since "$journal_since" >&2
    /usr/sbin/ip -details address show dev az1000h >&2 || true
    /usr/sbin/ip -4 route show >&2 || true
    /usr/sbin/nft list table ip amnezia_gate_1000 >&2 || true
    exit 1
fi

/usr/sbin/nft list table ip amnezia_gate_1000 >/dev/null
/usr/sbin/ip -4 address show dev az1000h | grep -Fq '10.231.15.161/30'
[[ -S $runtime_root/Smoke/awg0.sock ]]
machinectl show amnezia-Smoke --property=Leader --value | grep -Eq '^[0-9]+$'
/usr/sbin/iptables -w -C FORWARD \
    -i az1000h \
    -m comment --comment amnezia-gate:Smoke \
    -j ACCEPT

# RPM may unlink an old versioned image after switching its stable symlink.
# The active loop-backed nspawn root must remain usable until container exit.
mv "$rootfs_image" "$test_dir/rootfs.retired.squashfs"
cp --reflink=auto "$source_image" "$rootfs_image"
if [[ -e /sys/fs/selinux/enforce ]]; then
    chcon -u system_u -r object_r -t container_ro_file_t -l s0 "$rootfs_image"
fi
rm -f -- "$test_dir/rootfs.retired.squashfs"
timeout 0.5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/19080'
timeout 0.5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/19081'
timeout 0.5 bash -c 'exec 3<>/dev/tcp/10.231.15.162/53'
systemctl is-active --quiet "$smoke_unit"

systemctl stop "$smoke_unit"
[[ $(systemctl show "$smoke_unit" --property=Result --value) == success ]]
! systemctl is-active --quiet "$smoke_unit"

! /usr/sbin/iptables -w -C FORWARD \
    -i az1000h \
    -m comment --comment amnezia-gate:Smoke \
    -j ACCEPT

printf 'nspawn smoke test passed\n'
