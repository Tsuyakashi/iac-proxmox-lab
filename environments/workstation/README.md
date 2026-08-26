# workstation

Desktop VM(и) на `pve-rog` (`.20`) — полноценный персональный компьютер поверх
Proxmox, а не headless-сервис. Отдельная история от `environments/nodes`/
`immich-node` и т.п.: тут нет golden image, нет cloud-init, VM ставится
руками через обычный GUI-инсталлятор Ubuntu Desktop поверх подключённого ISO.
Причина архитектурных решений ниже разобрана подробно — большинство из них
не очевидны и стоили нескольких итераций проб/ошибок в чате.

## Топология

| | |
|---|---|
| VM ID | 100 |
| Host | `pve-rog` (`.20`) |
| IP | не пинуется — GUI-инсталлятор задаёт сеть сам, статик не используется |
| Ресурсы | 4 vCPU (`type=host`) / 8GB RAM / 64GB disk (`local-lvm`) |
| Видео | `vga_type = "qxl2"` (SPICE, 2 виртуальных головы) |
| USB | клавиатура, мышь, веб-камера — host passthrough |
| Аудио | SPICE audio channel (`ich9-intel-hda`, `driver=spice`) |

Мониторы у самого `pve-rog` (хоста): два внешних (DP-1, VGA-1), встроенный
экран ноута (LVDS-1) сознательно не используется вообще — ни под host-
консоль, ни под VM. Клавиатура/мышь/тачпад ноута тоже не используются —
только внешняя периферия, проброшенная в VM (см. ниже).

## Почему это не `modules/proxmox-vm`

Модуль целиком построен вокруг `clone{}` из golden image + cloud-init
user-data — подходит для серверных нод, где ОС/пользователь/сеть задаются
декларативно один раз. Тут нужен полноценный desktop с GUI-инсталлятором
(разметка диска, пользователь, пароль — руками, как на обычном железе),
поэтому `environments/workstation` — самостоятельный ресурс
`proxmox_virtual_environment_vm` без `clone{}`/`initialization{}`: Terraform
заводит только "железо" VM (диск, сеть, vga, cdrom с ISO, USB, аудио), сам
инсталл — руками через SPICE-консоль.

Отдельный root-модуль/state (тот же паттерн "Two independent root modules,
on purpose" из корневого README) — desktop VM(и) не зависят от lifecycle
нод/раннера/immich, и наоборот. Не в `pipeline.yml`, применяется вручную,
как `poly-nodes`/`minecraft-node`/`immich-node`.

`var.nodes` — карта, не одиночный ресурс, специально: вторая запись
(Windows-десктоп, свой ISO, та же `qxl2`-схема, свои `usb_devices`)
добавится сюда же позже. Обе VM смогут жить параллельно на одном
физическом GPU хоста — паравиртуальное видео не эксклюзивно в отличие от
passthrough.

## Установка: ISO в датасторе, не физическая флешка

Первая попытка — сырой USB block-device passthrough загрузочной флешки
(`qm set -scsi1 /dev/sdb,ro=1`, тот же паттерн, что у `immich-node`'s
recovery-диска). Не взлетело: SeaBIOS не смог корректно забутиться с
гибридного ISO-образа на флешке через голое виртуальное SCSI-устройство —
`no bootable device` и авто-ребут. Причина, по всей видимости, в том, что
гибридный ISO рассчитан на то, как BIOS видит именно физическую флешку с
её партиционированием, а не сырое блочное устройство под виртуальным
SCSI-контроллером — это разные вещи даже при побайтовой идентичности
содержимого.

Рабочий путь — ISO закачивается на хост заранее и подключается как
виртуальный cdrom (`ide3`):

```bash
mkdir -p /var/lib/vz/template/iso
scp ubuntu-26.04-desktop-amd64.iso root@pve-rog:/var/lib/vz/template/iso/
```

или через веб-UI (Datacenter → pve-rog → local → ISO Images → Upload).
Terraform **не** качает и не заливает ISO сам — `iso_file_id` в
`variables.tf` только ссылается на уже загруженный файл
(`"local:iso/ubuntu-26.04-desktop-amd64.iso"`).

`boot_order` переключается флагом `boot_from_iso`:

- `true` (дефолт, пока не установлено) — `["ide3", "scsi0"]`, грузится с ISO.
- `false` (после установки) — `["scsi0", "ide3"]`.

**После того как Ubuntu реально стоит на `scsi0` — обязательно переключить
`boot_from_iso = false` и сделать `terraform apply`**, иначе случайный
ребут VM снова закинет в установщик.

## Видео: `qxl2`, не `virtio-gl`, и уж тем более не GPU passthrough

Путь до этого решения был не прямым — коротко, по актуальному состоянию:

**GPU passthrough (проброс физической 770M) — отвергнут целиком.**
Причины (разобраны в чате подробно, не дублируются здесь):
- Kepler VFIO reset bug — систематический, не "иногда", софтового фикса
  под NVIDIA нет (`vendor-reset` покрывает только AMD Polaris/Vega/Navi).
- Драйвер 470.xxx — последняя ветка под Kepler, официально EOL, ядра 6.14+
  ломают сборку DKMS, Ubuntu уже начал ретайрить пакет в репах (июнь 2026).
- Юзкейс (браузер/офис/редкие казуальные 2D-игры) вообще не требует
  аппаратного 3D — passthrough даёт мощность, которая не нужна, и взамен
  требует постоянного ручного присмотра за официально не поддерживаемым
  железом.

**`virtio-gl` (Venus/virgl через host GPU) — тоже не подошёл, по другой
причине: single-head.** У Proxmox `virtio-vga-gl` физически может отдать
только одну голову — это ограничение сборки QEMU, которую использует
Proxmox, подтверждённое разработчиками на форуме, а не настройка. Для
одного монитора работало бы отлично, но юзкейс — два внешних монитора
одновременно.

**`qxl2` — единственный официально поддерживаемый путь под несколько
мониторов.** QXL — паравиртуализированная видеокарта с встроенным SPICE,
`qxl2` явно означает 2 виртуальные головы. Плата за это — рендер
программный (CPU), без GPU-офлоада. Для браузера/офиса/2D-казуалок
(тестировано на форматах вроде "Дом тысячи дверей" — hidden object,
спрайтовая отрисовка) разницы не заметно; для чего-то с полноценным
3D-движком под нагрузкой `qxl2` не подойдёт — тогда актуален вариант
"GPU passthrough как toggle, не daily driver" (см. обсуждение в чате про
редкие игровые сессии), отдельная тема, не эта VM.

**Важный практический нюанс: смена `vga_type` не хот-плагается.** Это
аппаратная перестройка QEMU-устройства — простой `reboot` изнутри гостя
подхватывает старое устройство, нужен полный холодный рестарт самой VM:

```bash
ssh pve-rog 'qm stop 100 && sleep 3 && qm start 100'
```

**Второй нюанс: `multi-head` активируется гостем по запросу клиента, не
сама по себе.** Даже с `vga: qxl2` в конфиге, `xrandr --query` внутри
гостя первое время показывал только один output (`Virtual-1 connected`,
остальные `disconnected`) — потому что `remote-viewer` был запущен с
`--full-screen` (один физический монитор клиента), а не
`--full-screen=all`. QXL/spice-vdagent включает ровно столько голов,
сколько клиент заявил через SPICE-протокол. См. `--full-screen=all` в
`scripts/desktop-kiosk-setup.sh` ниже.

**Host-side зависимость, не связанная с самим Terraform-конфигом:**
`virtio-gl`/`qxl2` рендерятся через host-side Mesa/EGL/GL-стек — на
свежем Proxmox-хосте (`pve-rog`) `libgl1`/`libegl1` не установлены по
умолчанию, `qm start` падает с `missing libraries for 'virtio-gl' detected!`
до тех пор, пока не поставлены:

```bash
ssh pve-rog apt-get install -y libgl1 libegl1
```

## USB-периферия: почему `null_resource` + SSH, не декларативный `usb{}`

Клавиатура/мышь/веб-камера пробрасываются как обычные host-USB устройства
по `vendorid:productid` (смотрится через `ssh pve-rog lsusb`) — это
отдельная история от GPU passthrough и его reset bug'ом никак не связана
(обычные HID/UVC-устройства, никакого reset issue у них нет).

Проблема в другом: Proxmox API отдаёт `only root can set 'usbN' config for
real devices` для **любого** не-root доступа, включая полноправный
API-токен — тот же самый нюанс, что уже был решён для raw-disk
passthrough в `immich-node` (`scsi1` через `qm set` по SSH, не через
`disk{}`). Декларативный `usb{}`-блок провайдера тут не работает вообще —
решение то же самое: `null_resource` + `local-exec`, дёргающий `qm set
<vmid> -usbN host=<vendorid:productid>,usb3=1` напрямую по SSH под
`root@pam`.

```hcl
resource "null_resource" "usb_bind" {
  for_each = { for b in local.usb_bindings : b.key => b }

  triggers = {
    vm_id  = proxmox_virtual_environment_vm.workstation[each.value.node_key].vm_id
    device = each.value.device
    index  = each.value.usb_index
  }

  provisioner "local-exec" {
    command = "ssh root@${each.value.proxmox_node} qm set ${proxmox_virtual_environment_vm.workstation[each.value.node_key].vm_id} -usb${each.value.usb_index} host=${each.value.device},usb3=1"
  }

  depends_on = [proxmox_virtual_environment_vm.workstation]
}
```

Раз `null_resource.usb_bind` пишет `usbN` мимо провайдера, а `usb_devices`
— обычный `list(string)`, сам VM-ресурс при `refresh`/`plan` видит
"дрифт" (реальные usb-устройства есть в факте, но не объявлены в HCL) и
пытается их "исправить" через API-токен — с той же ошибкой про root.
Фикс — `lifecycle { ignore_changes = [usb] }` на самом VM-ресурсе: усб
целиком отдан на откуп `null_resource.usb_bind`, провайдер его не трогает.

**Известное ограничение, принятое, не решённое:** `usb_devices` —
позиционный список, не карта по имени устройства. Индексы (`usb0`,
`usb1`, ...) считаются по позиции в списке — удаление/добавление
устройства в середине списка сдвигает индексы всех, что после него, и
Terraform пересоздаёт соответствующие `null_resource.usb_bind` (это
безопасно — просто `qm set` заново на новый индекс, не трогает саму VM/её
диск — но плановый diff может неожиданно показать "3 to destroy, 2 to
add" на, казалось бы, одну правку). Если это станет болезненным — перейти
на `map(object({...}))` с явными именами вместо `list(string)`, тогда
позиция в списке перестанет влиять на уже существующие биндинги.

## Аудио: SPICE-канал, не USB-проброс звуковой карты

`audio_device { device = "ich9-intel-hda", driver = "spice" }` — звук
идёт клиенту через сам SPICE-канал (тот же `remote-viewer` на хосте, см.
ниже), не требует, чтобы в госте была видна конкретная физическая
аудио-железка. Реальная USB-звуковая карта (`08bb:2902`, TI PCM2902) при
этом всё равно проброшена отдельно через `usb_devices` — в госте
оказываются одновременно и виртуальное SPICE-аудио, и физическое USB;
конфликта нет, просто в самой Ubuntu нужно руками выбрать нужный output в
настройках звука, если оба устройства не устраивают дефолтным выбором.

## `scripts/desktop-kiosk-setup.sh` — хост как "тонкий клиент самому себе"

Раз GPU passthrough физических видеовыходов отвергнут, картинку с VM на
физические мониторы ноута нужно выводить как-то иначе — единственный
рабочий путь: локальный SPICE-клиент прямо на самом хосте `pve-rog`,
развёрнутый на оба внешних монитора. Скрипт превращает хост в минимальный
X-киоск под отдельным непривилегированным пользователем (`kiosk`),
автологин через `lightdm`, автозапуск `remote-viewer` на весь экран в
цикле. Запускается на хосте, не в Terraform:

```bash
ssh root@pve-rog 'bash -s' < scripts/desktop-kiosk-setup.sh
ssh pve-rog systemctl restart lightdm
```

Идемпотентен — безопасно перезапускать при любой правке (проверяет
пользователя/пакеты/конфиги перед созданием).

**Пакеты, которых на голом Proxmox-хосте нет по умолчанию** (в отличие от
типового Ubuntu Desktop) — каждый стоил отдельного тупика при первом
прогоне:
- `sudo` — вообще отсутствует на дефолтном Proxmox-хосте (там root-шелл
  из коробки). Нужен для точечного `NOPASSWD`-доступа `kiosk`-пользователя
  к одному конкретному `pvesh`-вызову (см. ниже).
- `x11-xserver-utils` — не входит в базовый `xserver-xorg`, без него нет
  `xrandr`/`xset` (раскладка мониторов, DPMS).
- `python3` — нужен, чтобы собрать `.vv`-файл из JSON-ответа `pvesh` (см.
  ниже — `qm spiceproxy` как CLI-команды не существует).

**`qm spiceproxy <vmid>` не существует как CLI-команда в этой версии
Proxmox** — только API-эндпоинт. `.vv`-файл (формат `remote-viewer`)
собирается вручную из JSON, который отдаёт `pvesh`:

```bash
sudo /usr/bin/pvesh create /nodes/<node>/qemu/<vmid>/spiceproxy --output-format json > /tmp/<vmid>.json
```

и дальше построчно переносится в `[virt-viewer]`-секцию `.vv`-файла
Python-скриптом (см. сам скрипт). Тикет одноразовый — файл удаляется
самим `remote-viewer` сразу после чтения, поэтому берётся заново перед
**каждым** (пере)подключением, не один раз при старте сессии.

**`pvesh` тоже требует root**, тот же нюанс, что и с `usbN` в Terraform.
Точечное разрешение — `NOPASSWD` только на этот конкретный вызов для
этой конкретной VM, не на `pvesh`/`qm` целиком:

```bash
echo "kiosk ALL=(root) NOPASSWD: /usr/bin/pvesh create /nodes/<node>/qemu/<vmid>/spiceproxy*" > /etc/sudoers.d/kiosk-spiceproxy
```

**Курсор мыши не отрисовывался вообще**, хотя сама мышь двигала указатель
и кликала нормально. Причина — SPICE рисует курсор через свой input-канал,
а мышь на этой VM изначально пробрасывалась как сырое USB-устройство
(мимо SPICE, напрямую в гостя) — SPICE попросту не знал, что указатель
существует. Раз клиент (`remote-viewer`) и хост в данном случае — буквально
одна и та же машина, задержка через SPICE физически ниоткуда не возьмётся,
так что мышь убрана из `usb_devices` и оставлена на хосте штатно — курсор
снова рисуется через SPICE.

**`--full-screen=all`, не просто `--full-screen`.** См. раздел про
видео выше — без `=all` `remote-viewer` занимает один физический монитор
клиента, и гость активирует только одну QXL-голову.

**DPMS: не выключен совсем, а управляется вручную по факту состояния
VM.** Изначально был `xset s off -dpms` (DPMS выключен полностью) —
из-за этого при выключенной VM мониторы просто оставались чёрными
навсегда, без штатного "спящего" состояния. Сейчас DPMS включён, но без
автотаймаутов (`xset dpms 0 0 0`), и гасится/включается вручную в
зависимости от того, получен ли свежий SPICE-тикет:

```bash
if [ -s /tmp/${VMID}.vv ]; then
    xset dpms force on
    remote-viewer --full-screen=all --title="${VM_TITLE}" /tmp/${VMID}.vv
else
    xset dpms force off
fi
```

**Раскладка мониторов** задаётся явно по именам выходов (`xrandr --query`
под пользователем `kiosk`, не под собственной сессией — имена могут не
совпадать), встроенный экран выключается прямо в X:

```bash
xrandr --output LVDS-1 --off --output DP-1 --auto --output VGA-1 --auto --right-of DP-1 &
```

Если физически поменяются порты/мониторы — проверить актуальные имена
через `xrandr --query` и поправить эту строку в скрипте.

## Гостевые пакеты (внутри установленной Ubuntu, не покрыто Terraform)

После установки — обязательно поставить SPICE guest-агент, без него
`qxl2` не согласует multi-head с клиентом правильно:

```bash
sudo apt update && sudo apt install -y spice-vdagent qemu-guest-agent
sudo systemctl enable --now spice-vdagentd
```

## Деплой

```bash
cd environments/workstation
cp terraform.tfvars.example terraform.tfvars   # endpoint/token
# ISO уже должен лежать в датасторе на pve-rog — см. раздел "Установка" выше
terraform init
terraform apply
```

После первого `apply` (не покрыто Terraform):

1. Поставить `libgl1`/`libegl1` на хосте (см. раздел "Видео" выше), если
   ещё не сделано — иначе `qm start` падает.
2. Открыть SPICE-консоль через веб-UI (`https://<pve-rog-ip>:8006` →
   `100 (ubuntu-workstation)` → Console) и пройти GUI-установщик Ubuntu.
3. `boot_from_iso = false` в `variables.tf`, `terraform apply` ещё раз —
   иначе случайный ребут снова уйдёт в установщик.
4. Внутри гостя — `spice-vdagent`/`qemu-guest-agent` (см. выше).
5. `ssh root@pve-rog 'bash -s' < scripts/desktop-kiosk-setup.sh` +
   `systemctl restart lightdm` — превратить хост в тонкий клиент.

## Проверка

```bash
# vga реально qxl2, не старый virtio-gl (после смены типа — нужен qm stop/start, не reboot)
ssh pve-rog 'qm config 100 | grep -E "^vga"'

# обе головы видны гостю (после старта sessions и remote-viewer --full-screen=all)
# внутри гостя:
cat /sys/class/drm/*/status   # ожидаем минимум 2x connected

# kiosk реально подключился, тикет свежий
ssh pve-rog 'cat /tmp/kiosk-errors.log'   # пусто/нет файла = ок
ssh pve-rog 'ps aux | grep -E "Xorg|remote-viewer"'
```
