# amnezia-gate

Профили AmneziaWG с SOCKS5 (Dante) и HTTP CONNECT (tinyproxy), изолированные
через `systemd-nspawn`.

Docker и `systemd-networkd` не используются. Проект сам создаёт veth,
назначает адреса и устанавливает отдельную nftables table для каждого
профиля.

## Модель

```text
LAN / host
   │ TCP :1080+N, :10080+N
   ▼
nft DNAT/SNAT ── azNh 10.231.x.y/30
                    │ veth
                    ▼
             systemd-nspawn amnezia-PROFILE
               host0  ── outer route до endpoint и LAN
               awg0   ── default route, fail-closed
               sockd  ── :1080
               tinyproxy ── :10080
```

Каждый профиль получает:

- отдельный network namespace и одинаково именованный `awg0`;
- уникальный `/30` из `NETWORK_PREFIX` и уникальную MCS category SELinux;
- собственную пару внешних proxy-портов;
- volatile overlay поверх общего read-only squashfs image.

Поэтому tunnel IP, маршруты и внутренние порты у разных профилей могут
совпадать.

## Сеть

Runner напрямую управляет `ip` и `nft`:

- создаёт veth `azNh` / `azNc`, передавая peer в nspawn как `host0`;
- DNAT'ит SOCKS/HTTP с host и из `LAN_CIDRS` на контейнер;
- SNAT'ит локальный hairpin и masquerade'ит egress контейнера;
- разрешает forwarding к контейнеру только на proxy-порты и только из
  `LAN_CIDRS`;
- удаляет interface и профильную nft table при остановке.

При `FORWARD_COMPAT=auto` runner проверяет iptables `FORWARD`. Если chain
содержит rules или её policy отличается от `ACCEPT`, в неё зеркалируются
симметричные точечные `ACCEPT` rules для профильного `azNh`. Это работает как
с `iptables-legacy`, так и с `iptables-nft`, не меняет общую policy и не
затрагивает forwarding прочих interfaces. Значение `none` полностью отключает
iptables integration, а `iptables` требует доступный CLI и завершает старт
ошибкой, если правила установить нельзя. Пакет `iptables` не является
зависимостью `amnezia-gate`.

`amnezia-gate-network.service` включает IPv4 forwarding, пока запущен хотя
бы один профиль, и восстанавливает предыдущее значение после остановки
последнего. Это единственное глобальное сетевое состояние проекта.

В контейнере сохраняются явные outer routes до VPN endpoint и `LAN_CIDRS`,
после чего default route заменяется на `awg0`. Если tunnel исчезает, outer
default route не возвращается — профиль остаётся fail-closed.

## Сборка RPM

Требуется openSUSE Tumbleweed, KIWI NG и `squashfs-tools`:

```bash
sudo zypper install python3-kiwi squashfs
```

```bash
make rootfs
make rpm
```

Результат:

```text
_build/rpmbuild/RPMS/x86_64/amnezia-gate-0.1.0-0.x86_64.rpm
_build/rpmbuild/RPMS/x86_64/amnezia-gate-gnome-0.1.0-0.x86_64.rpm
```

`amnezia-gate` содержит service, CLI и container image. Опциональное GNOME
приложение вместе с GTK/libadwaita dependencies вынесено в
`amnezia-gate-gnome`.

Rootfs декларативно собирается KIWI из `repo-oss` и AmneziaWG repository.
Описание находится в `kiwi/config.xml`; вместе с squashfs сохраняются KIWI
package manifest и результат `rpm --verify`. Proxy и AmneziaWG binaries входят
в image и не зависят от ABI host userspace.

RPM содержит versioned image в
`/usr/lib/amnezia-gate/images/rootfs-VERSION-RELEASE.ARCH.squashfs` и
стабильную symlink `/usr/lib/amnezia-gate/rootfs.squashfs`. При обновлении
RPM новые профили открывают новый image. Уже работающий nspawn сохраняет старый
backing inode через loop device до остановки, поэтому отдельные image store,
распаковщик и garbage collector не нужны.

Для разработки без установки RPM доступны:

```bash
make selinux
make test
sudo make smoke
sudo make install
```

## Конфигурация и импорт

Перед импортом настройте `/etc/amnezia/profiles.conf`, прежде всего
`LAN_CIDRS`. Значение по умолчанию — `192.168.1.0/24`.

Через непривилегированный D-Bus client:

```bash
amneziactl import ~/Downloads/London.conf --name london
amneziactl import ~/Downloads/profile.conf --name site_msk_1
amneziactl list
amneziactl restart london
```

Изменения авторизуются через polkit. Конфиг передаётся сервису содержимым, а не
путём в пользовательском filesystem. Те же операции доступны из GNOME
application `Amnezia Gate`.

По умолчанию Polkit запрашивает административную авторизацию. Для постоянного
делегирования только операций Amnezia Gate добавьте пользователя в системную
группу `amnezia`:

```bash
sudo usermod -aG amnezia sergey
```

Новая supplementary group применяется после следующего входа в пользовательскую
сессию. Пакет создаёт группу и устанавливает scoped Polkit rule, но сам
пользователей в неё не добавляет.

В GNOME application после выбора файла открывается отдельный диалог имени.
Имя файла используется только как начальное значение. Имя профиля уникально и
без преобразований становится именем каталога, systemd instance и nspawn
machine: от 1 до 32 символов, ASCII letters, digits, `_` и `-`, первый символ —
letter или digit.

Root backend для диагностики и автоматизации:

```bash
sudo /usr/libexec/amnezia-gate-profile import ~/Downloads/London.conf --name london
sudo /usr/libexec/amnezia-gate-profile status london
sudo /usr/libexec/amnezia-gate-profile logs london
sudo /usr/libexec/amnezia-gate-profile remove london --yes
```

Importer:

- требует явное уникальное имя и сохраняет профиль в
  `/etc/amnezia/profiles/PROFILE` с mode `0600`;
- удаляет `DNS` и `Table`, устанавливает `Table = off`;
- запрещает `PreUp`, `PostUp`, `PreDown`, `PostDown` и `SaveConfig`;
- атомарно заменяет профиль и откатывает конфигурацию при неуспешном restart;
- назначает свободные proxy ports, `/30` network slot и SELinux MCS category;
- включает и запускает `amnezia-gate@PROFILE.service`.

## Диагностика

К отчёту об ошибке приложите версии пакетов, список профилей и состояние
systemd units:

```bash
rpm -q amnezia-gate amnezia-gate-gnome
amneziactl list
systemctl --no-pager --full status \
  amnezia-gate-daemon.service \
  amnezia-gate-network.service \
  'amnezia-gate@*.service'
journalctl -b --no-pager \
  -u amnezia-gate-daemon.service \
  -u amnezia-gate-network.service \
  -u 'amnezia-gate@*'
```

Для конкретного профиля вместо `PROFILE` укажите его имя:

```bash
amneziactl status PROFILE
sudo /usr/libexec/amnezia-gate-profile logs PROFILE
systemctl show "amnezia-gate@PROFILE.service" \
  --property=ActiveState,SubState,Result,ExecMainCode,ExecMainStatus
```

Если профиль не стартует из-за сети или SELinux, дополнительно полезны:

```bash
sysctl net.ipv4.ip_forward
ip -brief link | grep -E '^az[0-9]+h[[:space:]]'
sudo nft list tables | grep amnezia_gate
command -v iptables >/dev/null && sudo iptables -S FORWARD
sudo semodule -l | grep '^amnezia_gate[[:space:]]'
ls -lZ /usr/lib/amnezia-gate/rootfs.squashfs \
  /usr/lib/amnezia-gate/images/*.squashfs
command -v ausearch >/dev/null && sudo ausearch -m AVC,USER_AVC -ts boot
```

Не прикладывайте `/etc/amnezia/profiles/*/awg0.conf`: в этих файлах находятся
private и preshared keys. Приведённые выше команды ключи не выводят; journal
может содержать адрес VPN endpoint и имена профилей.

## Изоляция

- nspawn payload работает как `container_t:s0:cN`, содержимое squashfs размечено
  `container_ro_file_t:s0`;
- `awg0.conf`, resolver config и приватный TUN clone-node получают
  `container_file_t:s0:cN`;
- SELinux module добавляет только `watch` собственного UAPI socket, нужный
  `amneziawg-go` для контроля его удаления;
- `DevicePolicy=closed` пропускает только TUN, capability set сокращён до
  необходимого payload;
- rootfs запускается через `--image` и `--volatile=overlay`, профильный конфиг
  и resolver монтируются read-only;
- address families ограничены `AF_UNIX`, `AF_INET`, `AF_INET6` и `AF_NETLINK`.

## Ограничения

- Outer endpoint пока должен резолвиться в IPv4.
- Наружу публикуются TCP SOCKS5 и HTTP proxy. SOCKS5 UDP ASSOCIATE потребует
  отдельного диапазона UDP relay ports.
- Существующие `awg-quick@*`, `awg-sock@*` и `tinyproxy.service` автоматически
  не отключаются; миграция выполняется после проверки нового профиля.
