#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -p \
    "$test_dir/bin" \
    "$test_dir/profiles/London"
touch "$test_dir/profiles/London/awg0.conf"
chmod 0600 "$test_dir/profiles/London/awg0.conf"
touch "$test_dir/rootfs.squashfs"

cat >"$test_dir/profiles/London/profile.env" <<EOF
PROFILE_NAME=London
ROOTFS_IMAGE=$test_dir/rootfs.squashfs
NETWORK_PREFIX=10.231
NETWORK_SLOT=65
LISTEN_ADDRESS=0.0.0.0
LAN_CIDRS=192.168.50.0/24,10.20.0.0/16
FORWARD_COMPAT=auto
SOCKS_PORT=1082
HTTP_PORT=10082
DNS_SERVERS=1.1.1.1,1.0.0.1
DNS_TLS_SERVERS=9.9.9.9@853#dns.quad9.net
EOF

cat >"$test_dir/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AMNEZIA_TEST_IP_LOG"
EOF
cat >"$test_dir/bin/nft" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == list ]]; then
    exit 1
fi
if [[ ${1:-} == -f && ${2:-} == - ]]; then
    cat >"$AMNEZIA_TEST_NFT_LOG"
    exit
fi
printf '%s\n' "$*" >>"$AMNEZIA_TEST_NFT_LOG"
EOF
cat >"$test_dir/bin/iptables" <<'EOF'
#!/usr/bin/env bash
if [[ $* == '-w -S FORWARD' ]]; then
    if [[ ${AMNEZIA_TEST_IPTABLES_FORWARD_EMPTY:-0} == 1 ]]; then
        printf '%s\n' '-P FORWARD ACCEPT'
    else
        printf '%s\n' '-P FORWARD DROP'
    fi
    exit 0
fi
printf '%s\n' "$*" >>"$AMNEZIA_TEST_IPTABLES_LOG"
if [[ ${2:-} == -C ]]; then
    [[ ${AMNEZIA_TEST_IPTABLES_RULES_PRESENT:-0} == 1 ]]
fi
EOF
cat >"$test_dir/bin/nspawn" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$AMNEZIA_TEST_NSPAWN_LOG"
EOF
cat >"$test_dir/bin/dns" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AMNEZIA_TEST_DNS_LOG"
EOF
chmod 0755 \
    "$test_dir/bin/dns" \
    "$test_dir/bin/ip" \
    "$test_dir/bin/iptables" \
    "$test_dir/bin/nft" \
    "$test_dir/bin/nspawn"

export AMNEZIA_PROFILE_TESTING=1
export AMNEZIA_PROFILE_ROOT="$test_dir/profiles"
export AMNEZIA_PROFILE_DEVICE_ROOT="$test_dir/dev"
export AMNEZIA_PROFILE_RUNTIME_ROOT="$test_dir/run"
export AMNEZIA_TEST_IP_LOG="$test_dir/ip.log"
export AMNEZIA_TEST_IPTABLES_LOG="$test_dir/iptables.log"
export AMNEZIA_TEST_NFT_LOG="$test_dir/nft.log"
export AMNEZIA_TEST_NSPAWN_LOG="$test_dir/nspawn.log"
export AMNEZIA_TEST_DNS_LOG="$test_dir/dns.log"
export IP_BIN="$test_dir/bin/ip"
export IPTABLES_BIN="$test_dir/bin/iptables"
export NFT_BIN="$test_dir/bin/nft"
export NSPAWN_BIN="$test_dir/bin/nspawn"
export AMNEZIA_DNS_BACKEND="$test_dir/bin/dns"
export DNS_READY_ATTEMPTS=1

if "$project_dir/host/amnezia-gate-run" run new_one; then
    echo 'runner accepted a profile name with an underscore' >&2
    exit 1
fi

"$project_dir/host/amnezia-gate-run" prepare London

grep -Fqx 'link add name az65h type veth peer name az65c' "$test_dir/ip.log"
grep -Fqx 'address add 10.231.1.5/30 dev az65h' "$test_dir/ip.log"
grep -Fq 'table ip amnezia_gate_65' "$test_dir/nft.log"
grep -Fq 'elements = { 10.231.1.4/30, 192.168.50.0/24, 10.20.0.0/16 }' "$test_dir/nft.log"
grep -Fq 'tcp dport 1082 counter dnat to 10.231.1.6:1080' "$test_dir/nft.log"
grep -Fq 'tcp dport 10082 counter dnat to 10.231.1.6:10080' "$test_dir/nft.log"
grep -Fqx -- \
    '-w -I FORWARD 1 -i az65h -m comment --comment amnezia-gate:London -j ACCEPT' \
    "$test_dir/iptables.log"
grep -Fqx -- \
    '-w -I FORWARD 1 -o az65h -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment amnezia-gate:London -j ACCEPT' \
    "$test_dir/iptables.log"
grep -Fqx -- \
    '-w -I FORWARD 1 -o az65h -s 192.168.50.0/24 -d 10.231.1.6 -p tcp -m multiport --dports 1080,10080 -m comment --comment amnezia-gate:London -j ACCEPT' \
    "$test_dir/iptables.log"
grep -Fqx -- \
    '-w -I FORWARD 1 -o az65h -s 10.20.0.0/16 -d 10.231.1.6 -p tcp -m multiport --dports 1080,10080 -m comment --comment amnezia-gate:London -j ACCEPT' \
    "$test_dir/iptables.log"

"$project_dir/host/amnezia-gate-run" run London
grep -Fqx -- '--network-interface=az65c:host0' "$test_dir/nspawn.log"
grep -Fqx -- '--setenv=OUTER_ADDRESS=10.231.1.6/30' "$test_dir/nspawn.log"
grep -Fqx -- '--setenv=OUTER_GATEWAY=10.231.1.5' "$test_dir/nspawn.log"
grep -Fqx -- '--volatile=overlay' "$test_dir/nspawn.log"
grep -Fqx -- "--image=$test_dir/rootfs.squashfs" "$test_dir/nspawn.log"
grep -Fqx -- '--capability=CAP_NET_ADMIN,CAP_NET_BIND_SERVICE' "$test_dir/nspawn.log"
grep -Fqx -- '--kill-signal=SIGRTMIN+3' "$test_dir/nspawn.log"
! grep -Fq -- '--restrict-address-families=' "$test_dir/nspawn.log"
grep -Fqx 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' \
    "$project_dir/systemd/amnezia-gate@.service"
grep -Fqx 'StartLimitIntervalSec=2min' \
    "$project_dir/systemd/amnezia-gate@.service"
grep -Fqx 'StartLimitBurst=5' \
    "$project_dir/systemd/amnezia-gate@.service"
grep -Fqx 'RestartSec=10s' \
    "$project_dir/systemd/amnezia-gate@.service"
grep -Fqx 'ExecStartPost=/usr/libexec/amnezia-gate-run sync-dns %I' \
    "$project_dir/systemd/amnezia-gate@.service"
grep -Fqx -- "--bind=$test_dir/dev/London-tun:/dev/net/tun" \
    "$test_dir/nspawn.log"
grep -Fqx -- "--bind=$test_dir/run/London:/run/amneziawg" \
    "$test_dir/nspawn.log"
grep -Fqx -- "--bind=$test_dir/profiles/London/resolv.conf:/etc/resolv.conf" \
    "$test_dir/nspawn.log"
grep -Fqx -- '--setenv=DNS_TLS_SERVERS=9.9.9.9@853#dns.quad9.net' \
    "$test_dir/nspawn.log"
grep -Fqx -- "--bind-ro=$test_dir/profiles/London/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf" \
    "$test_dir/nspawn.log"
grep -Fqx 'nameserver 1.1.1.1' "$test_dir/profiles/London/resolv.conf"
grep -Fqx 'Allow 10.231.1.4/30' "$test_dir/profiles/London/tinyproxy.conf"
grep -Fqx 'Allow 192.168.50.0/24' "$test_dir/profiles/London/tinyproxy.conf"

# The post-start hook waits until the container resolver accepts TCP before
# publishing it through systemd-resolved. A closed test port only produces a
# warning and must not fail the VPN profile.
"$project_dir/host/amnezia-gate-run" sync-dns London 2>"$test_dir/dns-warning.log"
grep -Fq 'DNS resolver did not become ready for London' "$test_dir/dns-warning.log"

export AMNEZIA_TEST_IPTABLES_RULES_PRESENT=1
"$project_dir/host/amnezia-gate-run" cleanup London
grep -Fqx 'unsync London' "$test_dir/dns.log"
grep -Fqx -- \
    '-w -D FORWARD -i az65h -m comment --comment amnezia-gate:London -j ACCEPT' \
    "$test_dir/iptables.log"
grep -Fqx -- \
    '-w -D FORWARD -o az65h -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment amnezia-gate:London -j ACCEPT' \
    "$test_dir/iptables.log"

# Explicit nftables-only mode must not add iptables rules.
sed -i 's/^FORWARD_COMPAT=auto$/FORWARD_COMPAT=none/' \
    "$test_dir/profiles/London/profile.env"
unset AMNEZIA_TEST_IPTABLES_RULES_PRESENT
: >"$test_dir/iptables.log"
"$project_dir/host/amnezia-gate-run" prepare London
! grep -Fq -- '-w -I FORWARD' "$test_dir/iptables.log"
"$project_dir/host/amnezia-gate-run" cleanup London

# Auto mode skips an otherwise empty ACCEPT-policy compatibility ruleset.
sed -i 's/^FORWARD_COMPAT=none$/FORWARD_COMPAT=auto/' \
    "$test_dir/profiles/London/profile.env"
export AMNEZIA_TEST_IPTABLES_FORWARD_EMPTY=1
: >"$test_dir/iptables.log"
"$project_dir/host/amnezia-gate-run" prepare London
! grep -Fq -- '-w -I FORWARD' "$test_dir/iptables.log"
"$project_dir/host/amnezia-gate-run" cleanup London

printf 'runner tests passed\n'
