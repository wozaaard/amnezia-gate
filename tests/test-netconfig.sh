#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/run/netconfig"
cat >"$test_dir/network-config" <<'EOF'
NETCONFIG_DNS_POLICY="auto"
NETCONFIG_DNS_FORWARDER="resolver"
NETCONFIG_DNS_FORWARDER_FALLBACK="no"
NETCONFIG_DNS_RANKING="auto"
EOF
printf 'nameserver 192.168.1.1\n' >"$test_dir/run/netconfig/resolv.conf"
printf 'nameserver 192.168.1.1\n' >"$test_dir/run/dnsmasq-forwarders.conf"
ln -s "$test_dir/run/netconfig/resolv.conf" "$test_dir/resolv.conf"

cat >"$test_dir/bin/netconfig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$AMNEZIA_TEST_NETCONFIG_LOG"
case ${1:-} in
    modify)
        input=$(cat)
        printf '%s\n' "$input" >>"$AMNEZIA_TEST_NETCONFIG_LOG"
        address=$(sed -n -E "s/^DNSSERVERS='([^']+)'$/\\1/p" <<<"$input")
        if [[ ${AMNEZIA_TEST_NETCONFIG_MODE:-resolver} == dnsmasq ]]; then
            printf '# local dnsmasq is used implicitly\n' >"$AMNEZIA_NETCONFIG_RESOLV_CONF"
        else
            printf 'nameserver %s\n' "$address" >"$AMNEZIA_NETCONFIG_RESOLV_CONF"
        fi
        printf 'nameserver %s\n' "$address" >"$AMNEZIA_NETCONFIG_DNSMASQ_FORWARDERS"
        ;;
    remove)
        if [[ ${AMNEZIA_TEST_NETCONFIG_MODE:-resolver} == dnsmasq ]]; then
            printf '# local dnsmasq is used implicitly\n' >"$AMNEZIA_NETCONFIG_RESOLV_CONF"
        else
            printf 'nameserver 192.168.1.1\n' >"$AMNEZIA_NETCONFIG_RESOLV_CONF"
        fi
        printf 'nameserver 192.168.1.1\n' >"$AMNEZIA_NETCONFIG_DNSMASQ_FORWARDERS"
        ;;
    *) exit 1 ;;
esac
EOF
cat >"$test_dir/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ $* == 'is-active --quiet dnsmasq.service' ]]
EOF
chmod 0755 "$test_dir/bin/netconfig" "$test_dir/bin/systemctl"

export NETCONFIG_BIN="$test_dir/bin/netconfig"
export SYSTEMCTL_BIN="$test_dir/bin/systemctl"
export AMNEZIA_RESOLV_CONF="$test_dir/resolv.conf"
export AMNEZIA_NETCONFIG_RESOLV_CONF="$test_dir/run/netconfig/resolv.conf"
export AMNEZIA_NETCONFIG_DNSMASQ_FORWARDERS="$test_dir/run/dnsmasq-forwarders.conf"
export AMNEZIA_NETWORK_CONFIG="$test_dir/network-config"
export AMNEZIA_TEST_NETCONFIG_LOG="$test_dir/netconfig.log"

"$project_dir/host/amnezia-gate-netconfig" check
[[ $("$project_dir/host/amnezia-gate-netconfig" mode) == resolver ]]
"$project_dir/host/amnezia-gate-netconfig" apply az65h 10.231.1.6
grep -Fqx 'modify -s amnezia-gate-vpn -i az65h -m dns' "$test_dir/netconfig.log"
grep -Fqx "INTERFACE='az65h'" "$test_dir/netconfig.log"
grep -Fqx "DNSSERVERS='10.231.1.6'" "$test_dir/netconfig.log"
"$project_dir/host/amnezia-gate-netconfig" active az65h 10.231.1.6
"$project_dir/host/amnezia-gate-netconfig" revert az65h
grep -Fqx 'remove -s amnezia-gate-vpn -i az65h -m dns' "$test_dir/netconfig.log"
grep -Fqx 'nameserver 192.168.1.1' "$test_dir/resolv.conf"

sed -i 's/NETCONFIG_DNS_FORWARDER="resolver"/NETCONFIG_DNS_FORWARDER="dnsmasq"/' \
    "$test_dir/network-config"
export AMNEZIA_TEST_NETCONFIG_MODE=dnsmasq
printf '# local dnsmasq is used implicitly\n' >"$test_dir/run/netconfig/resolv.conf"
rm "$test_dir/run/dnsmasq-forwarders.conf"
"$project_dir/host/amnezia-gate-netconfig" check
[[ $("$project_dir/host/amnezia-gate-netconfig" mode) == dnsmasq ]]
"$project_dir/host/amnezia-gate-netconfig" apply az65h 10.231.1.6
"$project_dir/host/amnezia-gate-netconfig" active az65h 10.231.1.6
grep -Fqx 'nameserver 10.231.1.6' "$test_dir/run/dnsmasq-forwarders.conf"
"$project_dir/host/amnezia-gate-netconfig" revert az65h
grep -Fqx 'nameserver 192.168.1.1' "$test_dir/run/dnsmasq-forwarders.conf"

sed -i 's/NETCONFIG_DNS_FORWARDER="dnsmasq"/NETCONFIG_DNS_FORWARDER="bind"/' \
    "$test_dir/network-config"
if "$project_dir/host/amnezia-gate-netconfig" check 2>"$test_dir/forwarder.log"; then
    printf 'netconfig backend accepted an unsupported DNS forwarder\n' >&2
    exit 1
fi
grep -Fq 'unsupported NETCONFIG_DNS_FORWARDER: bind' "$test_dir/forwarder.log"

printf 'netconfig backend tests passed\n'
