#!/usr/bin/env bash
set -Eeuo pipefail

context_file=/.amnezia-gate-file-contexts
policy_file=$(find /etc/selinux/targeted/policy -maxdepth 1 -type f -name 'policy.*' -print | sort -V | tail -n 1)

[[ -n $policy_file ]] || {
    printf 'images.sh: targeted SELinux policy is missing\n' >&2
    exit 1
}

printf '/.* system_u:object_r:container_ro_file_t:s0\n' >"$context_file"
setfiles -T0 -F -p -c "$policy_file" \
    -e /dev -e /proc -e /run -e /sys \
    "$context_file" /
rm -f "$context_file"
