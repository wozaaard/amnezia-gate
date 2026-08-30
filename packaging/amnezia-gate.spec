#
# spec file for package amnezia-gate
#

Name:           amnezia-gate
Version:        0.1.0
Release:        0
%global debug_package %{nil}
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
BuildRequires:  make
BuildRequires:  policycoreutils
BuildRequires:  systemd-rpm-macros
BuildRequires:  zstd
Requires:       container-selinux
Requires:       iproute2
Requires:       nftables
Requires:       policycoreutils
Requires:       polkit
Requires:       python3-base
Requires:       python3-gobject
Requires:       systemd-container
Requires:       typelib-1_0-Polkit-1_0
%{?systemd_requires}
%add_sysuser g amnezia - -

%description
Runs named AmneziaWG profiles in isolated systemd-nspawn containers.
Each profile exposes independent Dante SOCKS5 and tinyproxy HTTP proxy ports,
while veth lifecycle, LAN forwarding and NAT are managed directly through
iproute2 and nftables. When an active iptables FORWARD ruleset is detected,
exact per-profile rules allow coexistence with a default drop policy.

%package gnome
Summary:        GNOME application for managing Amnezia Gate profiles
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

%install
make install \
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
if /usr/sbin/selinuxenabled; then
    /usr/sbin/semodule -i %{_datadir}/selinux/packages/%{name}/amnezia_gate.pp || :
    /usr/bin/chcon -u system_u -r object_r -t container_ro_file_t -l s0 \
        %{_prefix}/lib/%{name}/images/rootfs-%{version}-%{release}.%{_arch}.squashfs || :
fi

%preun
%service_del_preun amnezia-gate-daemon.service amnezia-gate-network.service

%postun
%service_del_postun amnezia-gate-daemon.service
%service_del_postun_without_restart amnezia-gate-network.service
if [ "$1" -eq 0 ] && /usr/sbin/selinuxenabled; then
    /usr/sbin/semodule -r amnezia_gate || :
fi

%files
%license LICENSE
%doc README.md
%doc %{_docdir}/%{name}/rootfs.packages
%doc %{_docdir}/%{name}/rootfs.verified
%{_bindir}/amneziactl
%{_libexecdir}/amnezia-gate-profile
%{_libexecdir}/amnezia-gate-network
%{_libexecdir}/amnezia-gate-run
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
%{_datadir}/selinux/packages/%{name}/amnezia_gate.pp
%dir %{_prefix}/lib/%{name}
%dir %{_prefix}/lib/%{name}/images
%{_prefix}/lib/%{name}/images/rootfs-%{version}-%{release}.%{_arch}.squashfs
%{_prefix}/lib/%{name}/rootfs.squashfs
%config(noreplace) %{_sysconfdir}/amnezia/profiles.conf
%dir %attr(0700,root,root) %{_sysconfdir}/amnezia/profiles

%files gnome
%{_bindir}/org.amnezia.Gate
%{_datadir}/applications/org.amnezia.Gate.desktop
%{_datadir}/metainfo/org.amnezia.Gate.metainfo.xml
%{_datadir}/icons/hicolor/scalable/apps/org.amnezia.Gate.svg

%changelog
* Sun Aug 30 2026 Sergey - 0.1.0-0
- Split the optional GNOME application into amnezia-gate-gnome
- Optionally mirror profile forwarding into an active iptables ruleset
- Replace the core GJS daemon and CLI with Python/PyGObject
- Require an explicit system-safe profile name during import
- Let systemd provision the writable runtime directory for network state
- Disable a newly enabled profile when its initial start fails
- Show pending profile operations in the GNOME application
- Allow passwordless management for explicitly delegated amnezia group members

* Sat Aug 29 2026 Sergey - 0.1.0-0
- Initial systemd-nspawn implementation with direct nftables networking
