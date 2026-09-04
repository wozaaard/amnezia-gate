#!/usr/bin/env bash
set -Eeuo pipefail

test -f /.kconfig && source /.kconfig
test -f /.profile && source /.profile

sed -i -f /usr/share/amnezia-gate/force-userspace.sed /usr/bin/awg-quick
grep -Fq WG_QUICK_FORCE_USERSPACE /usr/bin/awg-quick
chmod 0755 /usr/local/sbin/amnezia-gate-entrypoint
rm -rf /usr/share/amnezia-gate

install -d -m 0755 /config /run/amnezia /run/amneziawg
install -m 0600 /dev/null /config/awg0.conf

# KIWI applies the distribution file-context database again after images.sh.
# Keep the whole immutable container payload in the type intended for nspawn
# images by overriding the distribution mappings at their supported local
# precedence point.
printf '/.* system_u:object_r:container_ro_file_t:s0\n' \
    >/etc/selinux/targeted/contexts/files/file_contexts.local

# Minimal images do not materialize systemd's synthetic nobody account for
# files-based NSS. Dante intentionally drops to this conventional UID/GID.
grep -q '^nobody:' /etc/group || printf 'nobody:x:65534:\n' >>/etc/group
grep -q '^nobody:' /etc/passwd ||
    printf 'nobody:x:65534:65534:Nobody:/var/lib/nobody:/usr/sbin/nologin\n' >>/etc/passwd

rm -f /etc/resolv.conf
install -m 0644 /dev/null /etc/resolv.conf
