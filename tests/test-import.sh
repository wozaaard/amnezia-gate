#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/profiles"
cat >"$test_dir/global.conf" <<'EOF'
ROOTFS_IMAGE=/usr/lib/amnezia-gate/rootfs.squashfs
NETWORK_PREFIX=10.231
LISTEN_ADDRESS=0.0.0.0
LAN_CIDRS=192.168.50.0/24
FORWARD_COMPAT=auto
SOCKS_PORT_BASE=1080
HTTP_PORT_BASE=10080
DNS_SERVERS=9.9.9.9
EOF

cat >"$test_dir/bin/ss" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
LISTEN 0 128 0.0.0.0:1080 0.0.0.0:*
LISTEN 0 128 0.0.0.0:1081 0.0.0.0:*
LISTEN 0 128 0.0.0.0:10080 0.0.0.0:*
OUT
EOF
chmod 0755 "$test_dir/bin/ss"

cat >"$test_dir/London.conf" <<'EOF'
[Interface]
Address = 10.8.1.2/32
DNS = 1.1.1.1, 1.0.0.1
PrivateKey = test-private-key

[Peer]
PublicKey = test-public-key
AllowedIPs=0.0.0.0/0,::/0
Endpoint = 192.0.2.1:443
EOF

AMNEZIA_PROFILE_TESTING=1 \
AMNEZIA_PROFILE_ROOT="$test_dir/profiles" \
AMNEZIA_PROFILE_CONFIG="$test_dir/global.conf" \
SS_BIN="$test_dir/bin/ss" \
    "$project_dir/host/amnezia-gate-profile" import "$test_dir/London.conf" \
        --name london-1 --no-start

profile="$test_dir/profiles/london-1"
test -f "$profile/awg0.conf"
test -f "$profile/profile.env"
test "$(stat -c '%a' "$profile/awg0.conf")" = 600
test "$(stat -c '%a' "$profile/profile.env")" = 600
grep -Fqx 'Table = off' "$profile/awg0.conf"
! grep -Eiq '^[[:space:]]*(DNS|PostUp)[[:space:]]*=' "$profile/awg0.conf"
grep -Fqx 'SOCKS_PORT=1082' "$profile/profile.env"
grep -Fqx 'HTTP_PORT=10082' "$profile/profile.env"
grep -Fqx 'NETWORK_PREFIX=10.231' "$profile/profile.env"
grep -Fqx 'NETWORK_SLOT=0' "$profile/profile.env"
grep -Fqx 'FORWARD_COMPAT=auto' "$profile/profile.env"
grep -Fqx 'DNS_SERVERS=1.1.1.1\,1.0.0.1' "$profile/profile.env"

# A running profile may retain its own published ports during atomic replace.
cat >"$test_dir/bin/ss" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
LISTEN 0 128 0.0.0.0:1080 0.0.0.0:*
LISTEN 0 128 0.0.0.0:1081 0.0.0.0:*
LISTEN 0 128 0.0.0.0:1082 0.0.0.0:*
LISTEN 0 128 0.0.0.0:10080 0.0.0.0:*
LISTEN 0 128 0.0.0.0:10082 0.0.0.0:*
OUT
EOF
chmod 0755 "$test_dir/bin/ss"

AMNEZIA_PROFILE_TESTING=1 \
AMNEZIA_PROFILE_ROOT="$test_dir/profiles" \
AMNEZIA_PROFILE_CONFIG="$test_dir/global.conf" \
SS_BIN="$test_dir/bin/ss" \
    "$project_dir/host/amnezia-gate-profile" import "$test_dir/London.conf" \
        --name london-1 --replace --no-start
grep -Fqx 'NETWORK_SLOT=0' "$profile/profile.env"

# Profile names are embedded into systemd machine names; underscores are invalid there.
if AMNEZIA_PROFILE_TESTING=1 \
   AMNEZIA_PROFILE_ROOT="$test_dir/profiles" \
   AMNEZIA_PROFILE_CONFIG="$test_dir/global.conf" \
   SS_BIN="$test_dir/bin/ss" \
   "$project_dir/host/amnezia-gate-profile" import "$test_dir/London.conf" \
       --name new_one --no-start; then
    echo 'profile name with an underscore was accepted' >&2
    exit 1
fi
[[ ! -e $test_dir/profiles/new_one ]]

# Import never derives the profile identity from the file name.
if AMNEZIA_PROFILE_TESTING=1 \
   AMNEZIA_PROFILE_ROOT="$test_dir/profiles" \
   AMNEZIA_PROFILE_CONFIG="$test_dir/global.conf" \
   SS_BIN="$test_dir/bin/ss" \
   "$project_dir/host/amnezia-gate-profile" import "$test_dir/London.conf" \
       --no-start; then
    echo 'profile name was derived from the config file name' >&2
    exit 1
fi

# Another profile may not claim a declared/listening port explicitly.
cp "$test_dir/London.conf" "$test_dir/Paris.conf"
if AMNEZIA_PROFILE_TESTING=1 \
   AMNEZIA_PROFILE_ROOT="$test_dir/profiles" \
   AMNEZIA_PROFILE_CONFIG="$test_dir/global.conf" \
   SS_BIN="$test_dir/bin/ss" \
   "$project_dir/host/amnezia-gate-profile" import "$test_dir/Paris.conf" --name paris \
       --socks-port 1082 --http-port 10083 --no-start; then
    echo 'explicitly colliding proxy port was accepted' >&2
    exit 1
fi

# A failed initial start must undo both profile data and systemd enablement.
cat >"$test_dir/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AMNEZIA_TEST_SYSTEMCTL_LOG"
[[ ${1:-} != enable ]]
EOF
chmod 0755 "$test_dir/bin/systemctl"
export AMNEZIA_TEST_SYSTEMCTL_LOG="$test_dir/systemctl.log"
if AMNEZIA_PROFILE_TESTING=1 \
   AMNEZIA_PROFILE_ROOT="$test_dir/profiles" \
   AMNEZIA_PROFILE_CONFIG="$test_dir/global.conf" \
   SS_BIN="$test_dir/bin/ss" \
   SYSTEMCTL_BIN="$test_dir/bin/systemctl" \
   "$project_dir/host/amnezia-gate-profile" import "$test_dir/London.conf" \
       --name failed-start; then
    echo 'profile with a failed initial start was accepted' >&2
    exit 1
fi
[[ ! -e $test_dir/profiles/failed-start ]]
grep -Fqx 'enable --now amnezia-gate@failed-start.service' "$test_dir/systemctl.log"
grep -Fqx 'disable --now amnezia-gate@failed-start.service' "$test_dir/systemctl.log"

cat >"$test_dir/Tallin.conf" <<'EOF'
[Interface]
Address = 10.8.1.2/32
PrivateKey = test-private-key
PostUp = touch /tmp/should-not-run

[Peer]
PublicKey = test-public-key
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.2:443
EOF

if AMNEZIA_PROFILE_TESTING=1 \
   AMNEZIA_PROFILE_ROOT="$test_dir/profiles" \
   AMNEZIA_PROFILE_CONFIG="$test_dir/global.conf" \
   SS_BIN="$test_dir/bin/ss" \
   "$project_dir/host/amnezia-gate-profile" import "$test_dir/Tallin.conf" \
       --name tallin --no-start; then
    echo 'forbidden PostUp was accepted' >&2
    exit 1
fi

printf 'import tests passed\n'
