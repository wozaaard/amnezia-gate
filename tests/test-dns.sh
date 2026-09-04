#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/profiles/London"
cat >"$test_dir/profiles/London/profile.env" <<'EOF'
NETWORK_PREFIX=10.231
NETWORK_SLOT=65
EOF
cat >"$test_dir/resolv.conf" <<'EOF'
nameserver 127.0.0.53
options edns0 trust-ad
EOF

cat >"$test_dir/bin/ip" <<'EOF'
#!/usr/bin/env bash
if [[ $* == 'link show dev az65h' && ${AMNEZIA_TEST_LINK_UP:-0} == 1 ]]; then
    exit 0
fi
exit 1
EOF
cat >"$test_dir/bin/resolvectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AMNEZIA_TEST_RESOLVECTL_LOG"
[[ ${1:-} != status || ${AMNEZIA_TEST_RESOLVED_DOWN:-0} != 1 ]]
EOF
cat >"$test_dir/bin/netconfig-backend" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
    check|active) [[ ${AMNEZIA_TEST_NETCONFIG_UP:-0} == 1 ]] ;;
    mode) printf '%s\n' "${AMNEZIA_TEST_NETCONFIG_MODE:-resolver}" ;;
    apply|revert) printf '%s\n' "$*" >>"$AMNEZIA_TEST_NETCONFIG_LOG" ;;
    *) exit 1 ;;
esac
EOF
chmod 0755 "$test_dir/bin/ip" "$test_dir/bin/resolvectl" "$test_dir/bin/netconfig-backend"

export AMNEZIA_RESOLV_CONF="$test_dir/resolv.conf"
export AMNEZIA_TEST_RESOLVECTL_LOG="$test_dir/resolvectl.log"
export RESOLVECTL_BIN="$test_dir/bin/resolvectl"

# The systemd-resolved adapter owns only resolver-specific mutations.
"$project_dir/host/amnezia-gate-resolved" check
[[ $("$project_dir/host/amnezia-gate-resolved" mode) == resolved ]]
"$project_dir/host/amnezia-gate-resolved" apply az65h 10.231.1.6
grep -Fqx 'domain az65h ~.' "$test_dir/resolvectl.log"
grep -Fqx 'default-route az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'llmnr az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'mdns az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'dnsovertls az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'dnssec az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'dns az65h 10.231.1.6' "$test_dir/resolvectl.log"
"$project_dir/host/amnezia-gate-resolved" revert az65h
grep -Fqx 'revert az65h' "$test_dir/resolvectl.log"

printf 'nameserver 192.168.1.1\n' >"$test_dir/resolv.conf"
if "$project_dir/host/amnezia-gate-resolved" check; then
    printf 'resolved backend accepted a resolver that bypasses its stub\n' >&2
    exit 1
fi
printf 'nameserver 127.0.0.53\n' >"$test_dir/resolv.conf"

export AMNEZIA_PROFILE_ROOT="$test_dir/profiles"
export AMNEZIA_PROFILE_CONFIG="$test_dir/missing.conf"
export AMNEZIA_DNS_STATE_FILE="$test_dir/dns-profile"
export AMNEZIA_RESOLVED_BACKEND="$project_dir/host/amnezia-gate-resolved"
export AMNEZIA_NETCONFIG_BACKEND="$test_dir/bin/netconfig-backend"
export AMNEZIA_TEST_NETCONFIG_LOG="$test_dir/netconfig.log"
export IP_BIN="$test_dir/bin/ip"
export AMNEZIA_DNS_SKIP_RESOLVER_CHECK=1
export AMNEZIA_DNS_BACKEND_MODE=auto

[[ $("$project_dir/host/amnezia-gate-dns" backend) == resolved ]]
[[ $("$project_dir/host/amnezia-gate-dns" mode) == resolved ]]
[[ $("$project_dir/host/amnezia-gate-dns" status) == $'-\toff' ]]
"$project_dir/host/amnezia-gate-dns" use London
[[ $(<"$test_dir/dns-profile") == $'resolved\tLondon' ]]
[[ $("$project_dir/host/amnezia-gate-dns" status) == $'London\twaiting' ]]

export AMNEZIA_TEST_LINK_UP=1
"$project_dir/host/amnezia-gate-dns" sync London
[[ $("$project_dir/host/amnezia-gate-dns" status) == $'London\tactive' ]]

# Explicit backend selection switches ownership without leaving the old
# integration behind.
export AMNEZIA_TEST_NETCONFIG_UP=1
export AMNEZIA_TEST_NETCONFIG_MODE=dnsmasq
export AMNEZIA_DNS_BACKEND_MODE=netconfig
[[ $("$project_dir/host/amnezia-gate-dns" mode) == dnsmasq ]]
"$project_dir/host/amnezia-gate-dns" use London
[[ $(<"$test_dir/dns-profile") == $'netconfig\tLondon' ]]
grep -Fqx 'apply az65h 10.231.1.6' "$test_dir/netconfig.log"
[[ $(grep -Fxc 'revert az65h' "$test_dir/resolvectl.log") -eq 2 ]]
"$project_dir/host/amnezia-gate-dns" off
grep -Fqx 'revert az65h' "$test_dir/netconfig.log"
[[ ! -e $test_dir/dns-profile ]]

# Auto mode refuses to guess when two backends claim operational ownership.
export AMNEZIA_DNS_BACKEND_MODE=auto
[[ -z $("$project_dir/host/amnezia-gate-dns" backend) ]]
if "$project_dir/host/amnezia-gate-dns" check 2>"$test_dir/ambiguous.log"; then
    printf 'dispatcher accepted two operational DNS backends\n' >&2
    exit 1
fi
grep -Fq 'multiple operational DNS backends' "$test_dir/ambiguous.log"

# A 0.3 profile-only state is migrated after a successful restore.
unset AMNEZIA_TEST_NETCONFIG_UP
printf 'London\n' >"$test_dir/dns-profile"
"$project_dir/host/amnezia-gate-dns" restore
[[ $(<"$test_dir/dns-profile") == $'resolved\tLondon' ]]
"$project_dir/host/amnezia-gate-dns" remove-backend resolved
[[ ! -e $test_dir/dns-profile ]]

printf 'DNS integration tests passed\n'
