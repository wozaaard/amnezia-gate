#
# spec file for package amnezia-gate
#

Name:           amnezia-gate
Version:        0.3.0
Release:        0
%global debug_package %{nil}
%global selinuxtype targeted
%global modulename amnezia_gate
Summary:        Isolated AmneziaWG proxy profiles managed by systemd-nspawn
License:        GPL-3.0-or-later
URL:            https://github.com/amnezia-vpn/amneziawg-go
Source0:        %{name}-%{version}.tar.zst
Source1:        %{name}-rootfs.squashfs
Source2:        %{name}-rootfs.squashfs.packages
Source3:        %{name}-rootfs.squashfs.verified
Source4:        %{name}-sysusers.conf
ExclusiveArch:  x86_64

BuildRequires:  checkpolicy
BuildRequires:  dbus-1-daemon
BuildRequires:  desktop-file-utils
BuildRequires:  glib2-tools
BuildRequires:  make
BuildRequires:  policycoreutils
BuildRequires:  python3-base
BuildRequires:  python3-gobject
BuildRequires:  selinux-policy-devel
BuildRequires:  systemd-rpm-macros
BuildRequires:  typelib-1_0-Polkit-1_0
BuildRequires:  zstd
Requires:       iproute2
Requires:       nftables
Requires:       polkit
Requires:       python3-base
Requires:       python3-gobject
Requires:       systemd-container
Requires:       typelib-1_0-Polkit-1_0
Requires:       (%{name}-selinux if selinux-policy-base)
Recommends:     (amnezia-gate-resolved if systemd-resolved)
Recommends:     (amnezia-gate-netconfig if sysconfig-netconfig)
%{?systemd_requires}
%add_sysuser g amnezia - -

%description
Runs named AmneziaWG profiles in isolated systemd-nspawn containers.
Each profile exposes independent Dante SOCKS5 and tinyproxy HTTP proxy ports,
while veth lifecycle, LAN forwarding and NAT are managed directly through
iproute2 and nftables. When an active iptables FORWARD ruleset is detected,
exact per-profile rules allow coexistence with a default drop policy.

%package selinux
Summary:        SELinux policy for Amnezia Gate
BuildArch:      noarch
Requires:       %{name} = %{version}-%{release}
Requires:       container-selinux
%{selinux_requires}

%description selinux
Provides the SELinux policy module and file contexts required to run
Amnezia Gate containers on an SELinux host.

%package -n amnezia-gate-resolved
Summary:        systemd-resolved backend for Amnezia Gate
BuildArch:      noarch
Requires:       %{name} = %{version}-%{release}
Requires:       systemd-resolved

%description -n amnezia-gate-resolved
Provides optional system DNS routing through a selected Amnezia Gate profile
and restores the volatile systemd-resolved per-link configuration after the
resolver service is restarted.

%package -n amnezia-gate-netconfig
Summary:        netconfig backend for Amnezia Gate
BuildArch:      noarch
Requires:       %{name} = %{version}-%{release}
Requires:       sysconfig-netconfig

%description -n amnezia-gate-netconfig
Provides optional system DNS routing through a selected Amnezia Gate profile
on systems where wicked and netconfig manage resolv.conf directly or through
a dnsmasq forwarder.

%package gnome
Summary:        GNOME application for managing Amnezia Gate profiles
BuildArch:      noarch
Requires:       %{name} = %{version}-%{release}
Requires:       gjs
Requires:       typelib-1_0-Adw-1
Requires:       typelib-1_0-Gtk-4_0

%description gnome
Provides a GTK 4 and libadwaita application for importing and controlling
Amnezia Gate profiles through its system D-Bus service.

%prep
%autosetup

%build
make %{?_smp_mflags} selinux

%check
make test
desktop-file-validate gui/org.amnezia.Gate.desktop

%install
make install \
    DESTDIR=%{buildroot}
make install-resolved \
    DESTDIR=%{buildroot}
make install-netconfig \
    DESTDIR=%{buildroot}
make install-selinux \
    DESTDIR=%{buildroot} \
    SELINUX_MODULE="$PWD/_build/amnezia_gate.pp"

rootfs_name=rootfs-%{version}-%{release}.%{_arch}.squashfs
install -D -m 0644 %{SOURCE1} \
    %{buildroot}%{_prefix}/lib/%{name}/images/$rootfs_name
ln -s images/$rootfs_name \
    %{buildroot}%{_prefix}/lib/%{name}/rootfs.squashfs
install -D -m 0644 %{SOURCE2} %{buildroot}%{_docdir}/%{name}/rootfs.packages
install -D -m 0644 %{SOURCE3} %{buildroot}%{_docdir}/%{name}/rootfs.verified

%pre
%service_add_pre amnezia-gate-daemon.service amnezia-gate-network.service
%sysusers_create_package %{name} %{SOURCE4}

%post
%service_add_post amnezia-gate-daemon.service amnezia-gate-network.service

%preun
%service_del_preun amnezia-gate-daemon.service amnezia-gate-network.service

%postun
%service_del_postun amnezia-gate-daemon.service
%service_del_postun_without_restart amnezia-gate-network.service

%pre -n amnezia-gate-resolved
%service_add_pre amnezia-gate-resolved-restore.service

%post -n amnezia-gate-resolved
%service_add_post amnezia-gate-resolved-restore.service

%preun -n amnezia-gate-resolved
if [ "$1" -eq 0 ]; then
    %{_libexecdir}/amnezia-gate-dns remove-backend resolved || :
fi
%service_del_preun amnezia-gate-resolved-restore.service

%postun -n amnezia-gate-resolved
%service_del_postun_without_restart amnezia-gate-resolved-restore.service

%preun -n amnezia-gate-netconfig
if [ "$1" -eq 0 ]; then
    %{_libexecdir}/amnezia-gate-dns remove-backend netconfig || :
fi

%pre selinux
%selinux_relabel_pre -s %{selinuxtype}

%post selinux
%selinux_modules_install -s %{selinuxtype} -p 200 %{_datadir}/selinux/packages/%{selinuxtype}/%{modulename}.pp

%postun selinux
if [ "$1" -eq 0 ]; then
    %selinux_modules_uninstall -s %{selinuxtype} -p 200 %{modulename}
fi

%posttrans selinux
%selinux_relabel_post -s %{selinuxtype}

%files
%license LICENSE
%doc README.md
%doc %{_docdir}/%{name}/rootfs.packages
%doc %{_docdir}/%{name}/rootfs.verified
%{_bindir}/amneziactl
%{_libexecdir}/amnezia-gate-profile
%{_libexecdir}/amnezia-gate-network
%{_libexecdir}/amnezia-gate-run
%{_libexecdir}/amnezia-gate-dns
%{_libexecdir}/amnezia-gate-daemon
%{_unitdir}/amnezia-gate@.service
%{_unitdir}/amnezia-gate-daemon.service
%{_unitdir}/amnezia-gate-network.service
%{_datadir}/dbus-1/interfaces/org.amnezia.Gate1.xml
%{_datadir}/dbus-1/system-services/org.amnezia.Gate1.service
%{_datadir}/dbus-1/system.d/org.amnezia.Gate1.conf
%{_datadir}/polkit-1/actions/org.amnezia.gate.policy
%{_datadir}/polkit-1/rules.d/50-amnezia-gate.rules
%{_sysusersdir}/amnezia-gate.conf
%dir %{_datadir}/dbus-1
%dir %{_datadir}/dbus-1/interfaces
%dir %{_datadir}/dbus-1/system-services
%dir %{_datadir}/dbus-1/system.d
%dir %{_prefix}/lib/%{name}
%dir %{_prefix}/lib/%{name}/images
%{_prefix}/lib/%{name}/images/rootfs-%{version}-%{release}.%{_arch}.squashfs
%{_prefix}/lib/%{name}/rootfs.squashfs
%config(noreplace) %{_sysconfdir}/amnezia/profiles.conf
%dir %{_sysconfdir}/amnezia
%dir %attr(0700,root,root) %{_sysconfdir}/amnezia/profiles

%files -n amnezia-gate-resolved
%{_libexecdir}/amnezia-gate-resolved
%{_unitdir}/amnezia-gate-resolved-restore.service
%dir %{_unitdir}/systemd-resolved.service.d
%{_unitdir}/systemd-resolved.service.d/amnezia-gate-resolved.conf

%files -n amnezia-gate-netconfig
%{_libexecdir}/amnezia-gate-netconfig

%files selinux
%dir %{_datadir}/selinux/packages/%{selinuxtype}
%{_datadir}/selinux/packages/%{selinuxtype}/%{modulename}.pp

%files gnome
%{_bindir}/org.amnezia.Gate
%{_datadir}/applications/org.amnezia.Gate.desktop
%{_datadir}/metainfo/org.amnezia.Gate.metainfo.xml
%dir %{_datadir}/icons/hicolor
%dir %{_datadir}/icons/hicolor/scalable
%dir %{_datadir}/icons/hicolor/scalable/apps
%{_datadir}/icons/hicolor/scalable/apps/org.amnezia.Gate.svg
