#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

make -s -C "$project_dir" install DESTDIR="$test_dir"
[[ ! -e $test_dir/usr/share/selinux/packages/targeted/amnezia_gate.pp ]]
[[ ! -e $test_dir/usr/libexec/amnezia-gate-resolved ]]
[[ ! -e $test_dir/usr/libexec/amnezia-gate-netconfig ]]
[[ -x $test_dir/usr/libexec/amnezia-gate-dns ]]

make -s -C "$project_dir" install-resolved DESTDIR="$test_dir"
[[ -x $test_dir/usr/libexec/amnezia-gate-resolved ]]
[[ -f $test_dir/usr/lib/systemd/system/amnezia-gate-resolved-restore.service ]]
[[ -f $test_dir/usr/lib/systemd/system/systemd-resolved.service.d/amnezia-gate-resolved.conf ]]
grep -Fqx 'ExecStart=/usr/libexec/amnezia-gate-dns restore-backend resolved' \
    "$test_dir/usr/lib/systemd/system/amnezia-gate-resolved-restore.service"

make -s -C "$project_dir" install-netconfig DESTDIR="$test_dir"
[[ -x $test_dir/usr/libexec/amnezia-gate-netconfig ]]

make -s -C "$project_dir" install-selinux DESTDIR="$test_dir"
[[ -f $test_dir/usr/share/selinux/packages/targeted/amnezia_gate.pp ]]

printf 'install tests passed\n'
