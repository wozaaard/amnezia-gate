#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${AMNEZIA_DBUS_TEST_SESSION:-0} != 1 ]]; then
    export AMNEZIA_DBUS_TEST_SESSION=1
    exec dbus-run-session -- bash "$0" "$@"
fi

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
daemon_pid=
cleanup() {
    [[ -z $daemon_pid ]] || kill "$daemon_pid" 2>/dev/null || true
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
export AMNEZIA_PROFILE_ROOT="$test_root/profiles"
export AMNEZIA_PROFILE_CONFIG="$test_root/missing.conf"
export AMNEZIA_TEST_SYSTEMCTL_LOG="$test_root/systemctl.log"
export SYSTEMCTL_BIN="$test_root/bin/systemctl"
export SS_BIN=/usr/bin/true

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

"$project_dir/client/amneziactl" restart london
grep -q '^restart amnezia-gate@london.service$' "$test_root/systemctl.log"

"$project_dir/client/amneziactl" remove london --yes
[[ ! -e $test_root/profiles/london ]]

printf 'D-Bus API tests passed\n'
