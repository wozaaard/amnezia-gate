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
               unbound ── :53, strict DoT through awg0
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

При аварийном завершении systemd делает не более пяти попыток запуска за две
минуты с паузой 10 секунд. После исчерпания лимита профиль остаётся в состоянии
`failed`, не создавая бесконечный restart loop. Явный `start` или `restart`
через `amneziactl` сбрасывает этот лимит.

AWG userspace UAPI socket каждого активного профиля доступен только root daemon
через `/run/amnezia-gate/profiles/PROFILE/awg0.sock`. D-Bus публикует суммарные
RX/TX counters и время последнего handshake, но не конфигурацию, ключи или
endpoint. GNOME application получает срезы раз в две секунды; скорость
вычисляется по фактическому monotonic time между успешно полученными срезами.
Счётчики начинаются заново после перезапуска контейнера.

## DNS

После поднятия `awg0` каждый контейнер запускает собственный validating
`unbound`. Локальные Dante и tinyproxy используют его через `127.0.0.1`, а
upstream-запросы отправляются только по DNS-over-TLS через tunnel default
route. Resolver также слушает guest address профильного veth, но принимает
запросы только из соответствующего `/30`.

Bootstrap-серверы из `DNS` импортируемого AWG-конфига используются только до
поднятия туннеля. DoT upstream задаются глобально при импорте профиля:

```bash
DNS_TLS_SERVERS=9.9.9.9@853#dns.quad9.net,149.112.112.112@853#dns.quad9.net
```

Опциональный backend `amnezia-gate-resolved` позволяет направить системный DNS
хоста в один явно выбранный профиль:

```bash
amneziactl dns check
amneziactl dns use tallin
amneziactl dns status
amneziactl dns off
```

Backend использует напрямую D-Bus API `systemd-resolved`: для `azNh`
регистрируются guest resolver и catch-all routing domain `~.`. NetworkManager,
wicked и systemd-networkd не вызываются и не конфигурируются. Выбор хранится в
`/etc/amnezia/dns-profile`, восстанавливается при следующем старте профиля и
сбрасывается при его удалении. Отдельный oneshot unit восстанавливает per-link
настройки после перезапуска `systemd-resolved`. Если backend не установлен,
GNOME application не показывает действия для системного DNS.

Уже запущенный контейнер продолжает использовать rootfs, с которым он был
создан. После обновления с версии без встроенного resolver такой профиль нужно
перезапустить. `amnezia-gate-resolved` проверяет доступность TCP/53 перед выбором и
не публикует `~.`, пока новый resolver не отвечает, поэтому старый контейнер не
превращает системный DNS в black hole.

Функция доступна, только если `systemd-resolved` уже является системным
resolver: его service отвечает, а `/etc/resolv.conf` использует stub
`127.0.0.53`. Backend не включает `systemd-resolved` и не меняет ownership
`/etc/resolv.conf`. При остановке выбранного профиля его per-link DNS исчезает,
но выбор сохраняется; до следующего старта действует штатный DNS fallback
хоста. Strict/fail-closed host mode пока не реализован.

Для openSUSE интеграцию можно подготовить явно:

```bash
sudo zypper --no-refresh install amnezia-gate-resolved
sudo systemctl enable --now systemd-resolved.service
sudo ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
amneziactl dns check
```

Перед заменой `/etc/resolv.conf` следует сохранить его текущую версию. Пакет
`amnezia-gate-resolved` устанавливает нужную зависимость, но не выполняет эти
системные изменения сам.

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
_build/rpmbuild/RPMS/x86_64/amnezia-gate-0.3.0-0.x86_64.rpm
_build/rpmbuild/RPMS/noarch/amnezia-gate-resolved-0.3.0-0.noarch.rpm
_build/rpmbuild/RPMS/noarch/amnezia-gate-gnome-0.3.0-0.noarch.rpm
_build/rpmbuild/RPMS/noarch/amnezia-gate-selinux-0.3.0-0.noarch.rpm
```

`amnezia-gate` содержит service, CLI и container image. Опциональное GNOME
приложение вместе с GTK/libadwaita dependencies вынесено в
`amnezia-gate-gnome`. Интеграция системного DNS вынесена в
`amnezia-gate-resolved`. SELinux policy находится в `amnezia-gate-selinux`; zypper
установит его вместе с основным пакетом, если в системе есть
`selinux-policy-base`.

Основной пакет рекомендует `amnezia-gate-resolved`, только когда в системе уже
есть `systemd-resolved`. Поэтому стандартная установка zypper добавляет backend
на подготовленной системе, но не затягивает новый системный resolver туда, где
он не используется. Явная установка `amnezia-gate-resolved` по-прежнему
установит `systemd-resolved` как обязательную зависимость backend.

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
sudo make install-selinux # на SELinux host
```

## Конфигурация и импорт

Перед импортом настройте `/etc/amnezia/profiles.conf`, прежде всего
`LAN_CIDRS`. Значение по умолчанию — `192.168.1.0/24`.

Через непривилегированный D-Bus client:

```bash
amneziactl import ~/Downloads/London.conf --name london
amneziactl import ~/Downloads/profile.conf --name site-msk-1
amneziactl list
amneziactl stats
amneziactl dns status
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
machine: от 1 до 32 символов, ASCII letters, digits и `-`, первый символ —
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
rpm -q amnezia-gate amnezia-gate-resolved amnezia-gate-gnome
amneziactl list
amneziactl dns status
systemctl --no-pager --full status \
  amnezia-gate-daemon.service \
  amnezia-gate-network.service \
  amnezia-gate-resolved-restore.service \
  'amnezia-gate@*.service'
journalctl -b --no-pager \
  -u amnezia-gate-daemon.service \
  -u amnezia-gate-network.service \
  -u amnezia-gate-resolved-restore.service \
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
- rootfs запускается через `--image` и `--volatile=overlay`; AWG-конфиг
  монтируется read-only, а отдельный resolver-файл writable только для
  переключения bootstrap DNS на container-local unbound;
- address families ограничены `AF_UNIX`, `AF_INET`, `AF_INET6` и `AF_NETLINK`.

## Ограничения

- Outer endpoint пока должен резолвиться в IPv4.
- Системная DNS-интеграция требует заранее настроенный `systemd-resolved` stub;
  автоматическая настройка netconfig/dnsmasq пока отсутствует.
- Наружу публикуются TCP SOCKS5 и HTTP proxy. SOCKS5 UDP ASSOCIATE потребует
  отдельного диапазона UDP relay ports.
- Существующие `awg-quick@*`, `awg-sock@*` и `tinyproxy.service` автоматически
  не отключаются; миграция выполняется после проверки нового профиля.
