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

rm -f /etc/resolv.conf
install -m 0644 /dev/null /etc/resolv.conf
