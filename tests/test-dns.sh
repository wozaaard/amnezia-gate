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
chmod 0755 "$test_dir/bin/ip" "$test_dir/bin/resolvectl"

export AMNEZIA_PROFILE_ROOT="$test_dir/profiles"
export AMNEZIA_DNS_STATE_FILE="$test_dir/dns-profile"
export AMNEZIA_RESOLV_CONF="$test_dir/resolv.conf"
export AMNEZIA_TEST_RESOLVECTL_LOG="$test_dir/resolvectl.log"
export IP_BIN="$test_dir/bin/ip"
export RESOLVECTL_BIN="$test_dir/bin/resolvectl"
export AMNEZIA_DNS_SKIP_RESOLVER_CHECK=1

[[ $("$project_dir/host/amnezia-gate-resolved" status) == $'-\toff' ]]
"$project_dir/host/amnezia-gate-resolved" use London
[[ $("$project_dir/host/amnezia-gate-resolved" status) == $'London\twaiting' ]]
"$project_dir/host/amnezia-gate-resolved" restore

export AMNEZIA_TEST_LINK_UP=1
"$project_dir/host/amnezia-gate-resolved" sync London
grep -Fqx 'domain az65h ~.' "$test_dir/resolvectl.log"
grep -Fqx 'default-route az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'llmnr az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'mdns az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'dnsovertls az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'dnssec az65h no' "$test_dir/resolvectl.log"
grep -Fqx 'dns az65h 10.231.1.6' "$test_dir/resolvectl.log"
[[ $("$project_dir/host/amnezia-gate-resolved" status) == $'London\tactive' ]]
"$project_dir/host/amnezia-gate-resolved" restore
[[ $(grep -Fxc 'dns az65h 10.231.1.6' "$test_dir/resolvectl.log") -eq 2 ]]

"$project_dir/host/amnezia-gate-resolved" unsync London
grep -Fqx 'revert az65h' "$test_dir/resolvectl.log"
"$project_dir/host/amnezia-gate-resolved" off
[[ $("$project_dir/host/amnezia-gate-resolved" status) == $'-\toff' ]]
[[ ! -e $test_dir/dns-profile ]]

export AMNEZIA_DNS_SKIP_RESOLVER_CHECK=0
if "$project_dir/host/amnezia-gate-resolved" use London 2>"$test_dir/resolver-error.log"; then
    printf 'DNS backend accepted a profile without a running resolver\n' >&2
    exit 1
fi
grep -Fq 'restart the profile after updating Amnezia Gate' "$test_dir/resolver-error.log"
[[ ! -e $test_dir/dns-profile ]]

printf 'nameserver 192.168.1.1\n' >"$test_dir/resolv.conf"
if "$project_dir/host/amnezia-gate-resolved" check; then
    printf 'DNS backend accepted a resolver that bypasses systemd-resolved\n' >&2
    exit 1
fi

printf 'DNS integration tests passed\n'
