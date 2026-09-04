ROOTFS_IMAGE ?= _build/amnezia-gate-rootfs.squashfs
SELINUX_MODULE ?= _build/amnezia_gate.pp
SELINUX_FILE_CONTEXTS ?= selinux/amnezia_gate.fc
VERSION ?= 0.3.0
SOURCE_ARCHIVE ?= _build/amnezia-gate-$(VERSION).tar.zst
RPM_TOPDIR ?= $(CURDIR)/_build/rpmbuild
PREFIX ?= /usr
SYSCONFDIR ?= /etc
SYSTEMD_UNIT_DIR ?= /usr/lib/systemd/system
DBUS_INTERFACE_DIR ?= /usr/share/dbus-1/interfaces
DBUS_POLICY_DIR ?= /usr/share/dbus-1/system.d
DBUS_SERVICE_DIR ?= /usr/share/dbus-1/system-services
POLKIT_ACTION_DIR ?= /usr/share/polkit-1/actions
POLKIT_RULE_DIR ?= /usr/share/polkit-1/rules.d
SYSUSERS_DIR ?= /usr/lib/sysusers.d
APPLICATION_DIR ?= /usr/share/applications
METAINFO_DIR ?= /usr/share/metainfo
ICON_DIR ?= /usr/share/icons/hicolor/scalable/apps
SELINUX_PACKAGE_DIR ?= /usr/share/selinux/packages/targeted

.PHONY: rootfs selinux source rpm test smoke install install-resolved install-selinux

KIWI_SOURCES := $(shell find kiwi -type f -print)

rootfs: $(ROOTFS_IMAGE)

$(ROOTFS_IMAGE): build/build-rootfs.sh $(KIWI_SOURCES)
	install -d $(dir $(ROOTFS_IMAGE))
	sudo bash build/build-rootfs.sh $(ROOTFS_IMAGE)

selinux: $(SELINUX_MODULE)

$(SELINUX_MODULE): selinux/amnezia_gate.te $(SELINUX_FILE_CONTEXTS)
	install -d $(dir $@)
	checkmodule -M -m -o $(@:.pp=.mod) $<
	semodule_package -o $@ -m $(@:.pp=.mod) -f $(SELINUX_FILE_CONTEXTS)

source:
	bash build/build-source.sh $(VERSION) $(SOURCE_ARCHIVE)

rpm: rootfs selinux source
	install -d $(RPM_TOPDIR)/BUILD $(RPM_TOPDIR)/BUILDROOT $(RPM_TOPDIR)/RPMS \
		$(RPM_TOPDIR)/SOURCES $(RPM_TOPDIR)/SPECS $(RPM_TOPDIR)/SRPMS
	install -m 0644 $(SOURCE_ARCHIVE) $(RPM_TOPDIR)/SOURCES/
	install -m 0644 $(ROOTFS_IMAGE) $(RPM_TOPDIR)/SOURCES/
	install -m 0644 $(ROOTFS_IMAGE).packages $(RPM_TOPDIR)/SOURCES/
	install -m 0644 $(ROOTFS_IMAGE).verified $(RPM_TOPDIR)/SOURCES/
	install -m 0644 sysusers/amnezia-gate.conf $(RPM_TOPDIR)/SOURCES/amnezia-gate-sysusers.conf
	install -m 0644 packaging/amnezia-gate.spec $(RPM_TOPDIR)/SPECS/
	rpmbuild -ba --define '_topdir $(RPM_TOPDIR)' \
		$(RPM_TOPDIR)/SPECS/amnezia-gate.spec

test: selinux
	bash tests/test-install.sh
	bash tests/test-import.sh
	bash tests/test-runner.sh
	bash tests/test-dns.sh
	bash tests/test-dbus.sh

smoke:
	sudo bash tests/test-nspawn.sh $(ROOTFS_IMAGE)

install:
	install -D -m 0755 host/amnezia-gate-profile $(DESTDIR)$(PREFIX)/libexec/amnezia-gate-profile
	install -D -m 0755 host/amnezia-gate-run $(DESTDIR)$(PREFIX)/libexec/amnezia-gate-run
	install -D -m 0755 host/amnezia-gate-network $(DESTDIR)$(PREFIX)/libexec/amnezia-gate-network
	install -D -m 0755 daemon/amnezia-gate-daemon $(DESTDIR)$(PREFIX)/libexec/amnezia-gate-daemon
	install -D -m 0755 client/amneziactl $(DESTDIR)$(PREFIX)/bin/amneziactl
	install -D -m 0755 gui/org.amnezia.Gate $(DESTDIR)$(PREFIX)/bin/org.amnezia.Gate
	install -D -m 0644 systemd/amnezia-gate@.service $(DESTDIR)$(SYSTEMD_UNIT_DIR)/amnezia-gate@.service
	install -D -m 0644 systemd/amnezia-gate-daemon.service $(DESTDIR)$(SYSTEMD_UNIT_DIR)/amnezia-gate-daemon.service
	install -D -m 0644 systemd/amnezia-gate-network.service $(DESTDIR)$(SYSTEMD_UNIT_DIR)/amnezia-gate-network.service
	install -D -m 0644 dbus/org.amnezia.Gate1.xml $(DESTDIR)$(DBUS_INTERFACE_DIR)/org.amnezia.Gate1.xml
	install -D -m 0644 dbus/org.amnezia.Gate1.conf $(DESTDIR)$(DBUS_POLICY_DIR)/org.amnezia.Gate1.conf
	install -D -m 0644 dbus/org.amnezia.Gate1.service $(DESTDIR)$(DBUS_SERVICE_DIR)/org.amnezia.Gate1.service
	install -D -m 0644 polkit/org.amnezia.gate.policy $(DESTDIR)$(POLKIT_ACTION_DIR)/org.amnezia.gate.policy
	install -D -m 0644 polkit/50-amnezia-gate.rules $(DESTDIR)$(POLKIT_RULE_DIR)/50-amnezia-gate.rules
	install -D -m 0644 sysusers/amnezia-gate.conf $(DESTDIR)$(SYSUSERS_DIR)/amnezia-gate.conf
	install -D -m 0644 gui/org.amnezia.Gate.desktop $(DESTDIR)$(APPLICATION_DIR)/org.amnezia.Gate.desktop
	install -D -m 0644 gui/org.amnezia.Gate.metainfo.xml $(DESTDIR)$(METAINFO_DIR)/org.amnezia.Gate.metainfo.xml
	install -D -m 0644 gui/org.amnezia.Gate.svg $(DESTDIR)$(ICON_DIR)/org.amnezia.Gate.svg
	install -d -m 0700 $(DESTDIR)$(SYSCONFDIR)/amnezia/profiles
	@test -e $(DESTDIR)$(SYSCONFDIR)/amnezia/profiles.conf || \
		install -m 0644 config/profiles.conf $(DESTDIR)$(SYSCONFDIR)/amnezia/profiles.conf
	@if test -z "$(DESTDIR)"; then systemctl daemon-reload; fi

install-resolved:
	install -D -m 0755 host/amnezia-gate-resolved $(DESTDIR)$(PREFIX)/libexec/amnezia-gate-resolved
	install -D -m 0644 systemd/amnezia-gate-resolved-restore.service \
		$(DESTDIR)$(SYSTEMD_UNIT_DIR)/amnezia-gate-resolved-restore.service
	install -D -m 0644 systemd/systemd-resolved.service.d/amnezia-gate-resolved.conf \
		$(DESTDIR)$(SYSTEMD_UNIT_DIR)/systemd-resolved.service.d/amnezia-gate-resolved.conf
	@if test -z "$(DESTDIR)"; then systemctl daemon-reload; fi

install-selinux: selinux
	install -D -m 0644 $(SELINUX_MODULE) $(DESTDIR)$(SELINUX_PACKAGE_DIR)/amnezia_gate.pp
	@if test -z "$(DESTDIR)"; then semodule -i $(SELINUX_PACKAGE_DIR)/amnezia_gate.pp; fi
