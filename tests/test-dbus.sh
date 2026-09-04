#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${AMNEZIA_DBUS_TEST_SESSION:-0} != 1 ]]; then
    export AMNEZIA_DBUS_TEST_SESSION=1
    exec dbus-run-session -- bash "$0" "$@"
fi

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
daemon_pid=
statistics_pid=
cleanup() {
    [[ -z $daemon_pid ]] || kill "$daemon_pid" 2>/dev/null || true
    [[ -z $statistics_pid ]] || kill "$statistics_pid" 2>/dev/null || true
    [[ -z $statistics_pid ]] || wait "$statistics_pid" 2>/dev/null || true
    rm -rf -- "$test_root"
}
trap cleanup EXIT

mkdir -p "$test_root/bin" "$test_root/profiles"
cat >"$test_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$AMNEZIA_TEST_SYSTEMCTL_LOG"
if [[ ${1:-} == show ]]; then
    printf 'active\nrunning\n'
fi
EOF
chmod 0755 "$test_root/bin/systemctl"
cat >"$test_root/bin/ip" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$test_root/bin/resolvectl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$test_root/bin/ip" "$test_root/bin/resolvectl"

statistics_socket="$test_root/run/london/awg0.sock"
mkdir -p "${statistics_socket%/*}"
python3 - "$statistics_socket" <<'PY' &
import os
import socket
import sys

path = sys.argv[1]
if os.path.exists(path):
    os.unlink(path)
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
    server.bind(path)
    server.listen()
    while True:
        connection, _ = server.accept()
        with connection:
            request = bytearray()
            while not request.endswith(b'\n\n'):
                chunk = connection.recv(4096)
                if not chunk:
                    break
                request.extend(chunk)
            connection.sendall(
                b'private_key=test-interface-private-key\n'
                b'public_key=test-peer-one\n'
                b'last_handshake_time_sec=1700000000\n'
                b'tx_bytes=1000\n'
                b'rx_bytes=5000\n'
                b'public_key=test-peer-two\n'
                b'last_handshake_time_sec=1699999999\n'
                b'tx_bytes=234\n'
                b'rx_bytes=678\n'
                b'errno=0\n\n'
            )
PY
statistics_pid=$!
for _ in {1..50}; do
    [[ -S $statistics_socket ]] && break
    sleep 0.1
done
[[ -S $statistics_socket ]]

cat >"$test_root/London.conf" <<'EOF'
[Interface]
PrivateKey = client-private-key
Address = 10.0.0.2/32
DNS = 9.9.9.9

[Peer]
PublicKey = server-public-key
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.1:443
EOF

export AMNEZIA_GATE_TESTING=1
export AMNEZIA_PROFILE_TESTING=1
export AMNEZIA_GATE_BUS=session
export AMNEZIA_GATE_INTERFACE_FILE="$project_dir/dbus/org.amnezia.Gate1.xml"
export AMNEZIA_GATE_PROFILE_BIN="$project_dir/host/amnezia-gate-profile"
ln -s "$project_dir/host/amnezia-gate-dns" "$test_root/bin/amnezia-gate-dns"
ln -s "$project_dir/host/amnezia-gate-resolved" "$test_root/bin/amnezia-gate-resolved"
export AMNEZIA_DNS_BACKEND="$test_root/bin/amnezia-gate-dns"
export AMNEZIA_RESOLVED_BACKEND="$test_root/bin/amnezia-gate-resolved"
export AMNEZIA_NETCONFIG_BACKEND="$test_root/bin/amnezia-gate-netconfig"
export AMNEZIA_DNS_BACKEND_MODE=auto
export AMNEZIA_PROFILE_ROOT="$test_root/profiles"
export AMNEZIA_DNS_STATE_FILE="$test_root/dns-profile"
export AMNEZIA_DNS_SKIP_SYSTEM_CHECK=1
export AMNEZIA_DNS_SKIP_RESOLVER_CHECK=1
export AMNEZIA_PROFILE_CONFIG="$test_root/missing.conf"
export AMNEZIA_TEST_SYSTEMCTL_LOG="$test_root/systemctl.log"
export SYSTEMCTL_BIN="$test_root/bin/systemctl"
export IP_BIN="$test_root/bin/ip"
export RESOLVECTL_BIN="$test_root/bin/resolvectl"
export SS_BIN=/usr/bin/true
export AMNEZIA_GATE_UAPI_ROOT="$test_root/run"

"$project_dir/daemon/amnezia-gate-daemon" &
daemon_pid=$!

for _ in {1..50}; do
    if gdbus call --session --dest org.amnezia.Gate1 \
        --object-path /org/amnezia/Gate1 \
        --method org.amnezia.Gate1.Manager.ListProfiles >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
kill -0 "$daemon_pid"

if "$project_dir/client/amneziactl" import "$test_root/London.conf"; then
    echo 'amneziactl accepted import without an explicit profile name' >&2
    exit 1
fi

if "$project_dir/client/amneziactl" \
    import "$test_root/London.conf" --name new_one; then
    echo 'D-Bus API accepted a profile name with an underscore' >&2
    exit 1
fi

import_output=$("$project_dir/client/amneziactl" \
    import "$test_root/London.conf" --name london)
grep -q 'london' <<<"$import_output"
grep -q '1080' <<<"$import_output"
grep -q '10080' <<<"$import_output"

if "$project_dir/client/amneziactl" \
    import "$test_root/London.conf" --name london; then
    echo 'duplicate profile name was accepted' >&2
    exit 1
fi

list_output=$("$project_dir/client/amneziactl" list)
grep -q 'active/running' <<<"$list_output"

statistics_output=$("$project_dir/client/amneziactl" stats)
grep -Eq '^london[[:space:]]+5678[[:space:]]+1234[[:space:]]+1700000000$' \
    <<<"$statistics_output"

gdbus call --session --dest org.amnezia.Gate1 \
    --object-path /org/amnezia/Gate1 \
    --method org.amnezia.Gate1.Manager.GetDnsBackend |
    grep -Fq "'resolved'"
gdbus call --session --dest org.amnezia.Gate1 \
    --object-path /org/amnezia/Gate1 \
    --method org.amnezia.Gate1.Manager.GetDnsMode |
    grep -Fq "'resolved'"
[[ $("$project_dir/client/amneziactl" dns backend) == resolved ]]
[[ $("$project_dir/client/amneziactl" dns mode) == resolved ]]
dns_output=$("$project_dir/client/amneziactl" dns status)
grep -Eq '^-[[:space:]]+resolved[[:space:]]+off$' <<<"$dns_output"
"$project_dir/client/amneziactl" dns check |
    grep -Fqx 'DNS integration is ready: resolved/resolved'
dns_output=$("$project_dir/client/amneziactl" dns use london)
grep -Eq '^london[[:space:]]+resolved[[:space:]]+waiting$' <<<"$dns_output"

"$project_dir/client/amneziactl" restart london
grep -q '^reset-failed amnezia-gate@london.service$' "$test_root/systemctl.log"
grep -q '^restart amnezia-gate@london.service$' "$test_root/systemctl.log"

"$project_dir/client/amneziactl" remove london --yes
[[ ! -e $test_root/profiles/london ]]
[[ ! -e $test_root/dns-profile ]]

rm "$test_root/bin/amnezia-gate-resolved"
gdbus call --session --dest org.amnezia.Gate1 \
    --object-path /org/amnezia/Gate1 \
    --method org.amnezia.Gate1.Manager.GetDnsBackend |
    grep -Fq "''"
[[ $("$project_dir/client/amneziactl" dns backend) == - ]]
[[ $("$project_dir/client/amneziactl" dns mode) == - ]]
if "$project_dir/client/amneziactl" dns status; then
    echo 'D-Bus API accepted DNS operation without a backend' >&2
    exit 1
fi

printf 'D-Bus API tests passed\n'
