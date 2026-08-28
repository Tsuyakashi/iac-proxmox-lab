# immich-node

Отдельная VM под Immich (docker-compose, не swarm) на ноде `pve-rog`
(`.20`), `local-lvm`. Переехала с ad-hoc `docker compose` на отдельном
физическом хосте после инцидента с заполнением диска (immich-compose съел
место под nested `pve-rog`, VM встала на паузу, кластер потерял кворум).
История разбора — в основном README репозитория.

> **Хост поправлен на факт (2026-08-28).** Дефолт `proxmox_node` в
> `variables.tf` и эта таблица раньше указывали `bare-pve` — реальное
> дерево Datacenter всегда показывало VM 101 на `pve-rog`. По правилу
> «что задеплоено — там и остаётся» исправлен дефолт/README под факт, а
> не сама VM под старые доки. Синхронно поправлен и `proxmox_host_ip`
> (`.20`, не `.30`) — от него зависит, куда `null_resource.recovery_ro_bind`
> шлёт `qm set` по SSH; если бы поправили только `proxmox_node`, бинд
> продолжил бы стучаться не в тот хост.

## Топология

| | |
|---|---|
| VM ID | 101 |
| Host | `pve-rog` (`.20`) |
| IP | `192.168.100.60/24` |
| Ресурсы | 2 vCPU / 4GB RAM / 100GB disk (`local-lvm`) |
| CPU type | `host` |
| Golden image | VM 9001 (локальный на `pve-rog`, см. `locals.tf`) |

> Синхронизировано с дефолтом `var.nodes["immich-node"]` в `variables.tf`
> (`cores = 2`, `memory = 4096`, `disk_size = 100`) — эта таблица раньше
> разъезжалась с реальными значениями (показывала 4 vCPU / 70GB), см.
> [../../docs/troubleshooting.md#immich-node-variablestf-had-a-strict-object-type-violation-and-a-stale-readme-table](../../docs/troubleshooting.md#immich-node-variablestf-had-a-strict-object-type-violation-and-a-stale-readme-table).
> Если ресурсы этой VM снова поменяются в `variables.tf` — обнови и эту
> строку в том же PR, не отдельным заходом. То же правило теперь
> действует и на строку `Host`/`Golden image` выше — если VM когда-нибудь
> реально мигрирует между нодами, `proxmox_node`/`proxmox_host_ip`
> в `variables.tf` и эта таблица обновляются в одном PR.

Не изолирована в отдельный VLAN/network namespace (в отличие от
`minecraft-node`) — Immich наружу не выставляется.

## Эндпоинт и golden image: выводятся из `proxmox_node`, не задаются отдельно

`environments/immich-node/locals.tf` резолвит и Proxmox API endpoint, и
`template_vm_id` из одного и того же `var.proxmox_node`:

```hcl
locals {
  proxmox_nodes = {
    "bare-pve" = { endpoint = "https://192.168.100.30:8006/", template_vm_id = 9000 }
    "pve-rog"  = { endpoint = "https://192.168.100.20:8006/", template_vm_id = 9001 }
  }

  proxmox_endpoint = local.proxmox_nodes[var.proxmox_node].endpoint
  template_vm_id   = local.proxmox_nodes[var.proxmox_node].template_vm_id
}
```

Раньше `proxmox_endpoint` был отдельной переменной, а `template_vm_id`
жил в дефолтах `var.nodes` — можно было прописать один Proxmox-хост в
`.tfvars`, а клонировать golden image с другого, получив на выходе VM,
которая физически стоит не там, где Terraform думает, что она стоит (тот
же класс бага, что закрыт для `minecraft-node` в
[../../docs/troubleshooting.md](../../docs/troubleshooting.md)). Теперь
единственный вход — `var.proxmox_node` (дефолт — `pve-rog`, по факту), и
`template_node` в `main.tf` всегда равен ему же, кросс-нодовый клон здесь
структурно невозможен.

## CPU type: почему `host`, а не дефолт модуля

`modules/proxmox-vm` по умолчанию использует `kvm64` — консервативный
baseline-профиль без `sse4_2`/`popcnt`/`avx2`, рассчитанный на миграцию
между разнородным железом.

`immich-machine-learning` собран с зависимостями (numpy/onnxruntime) под
x86-64-v2, и на `kvm64` валится в рестарт-луп:

```
RuntimeError: NumPy was built with baseline optimizations: (X86_V2)
but your machine doesn't support
```

VM привязана к конкретному физическому диску (`recovery-ro` bind, см.
ниже) и никуда не мигрирует по определению — поэтому `cpu_type = "host"`
здесь не компромисс, а корректный выбор: полный проброс флагов
физического CPU хоста, без искусственного занижения.

Задаётся через `variables.tf`:

```hcl
variable "nodes" {
  type = map(object({
    ...
    cpu_type = optional(string, "host")
    ...
  }))
}
```

Применяется через `qm set --cpu host`. Важно: смена типа CPU не
хот-плагается — Proxmox применяет её только при (ре)старте VM
(`qm stop && qm start`, не `reboot` изнутри гостя).

## recovery-ro: физический диск с фотобиблиотекой

Библиотека Immich (36892 фото, ~189GB) живёт не в managed-хранилище, а
на отдельном физическом exFAT-диске (`RECOVERY`, 232.9G), подключённом
к хосту `pve-rog` как `/dev/sdb1` и проброшенном в VM как raw block device
в режиме read-only.

В Immich это настроено как **External Library** с путём
`/mnt/recovery-ro` — не через `UPLOAD_LOCATION`.

### Почему не датастор-volume

`bpg/proxmox` провайдер умеет декларативно описывать только
datastore-backed диски (`disk { ... }` внутри `proxmox_virtual_environment_vm`).
Проброс уже существующего физического блочного устройства хоста как
disk-ресурс им не поддерживается — единственный путь — `qm set` напрямую.

### Реализация в Terraform

`null_resource` с `local-exec`, дергающий `qm set` по ssh на хост
(`var.proxmox_host_ip`, дефолт `192.168.100.20` — синхронизирован с
`var.proxmox_node`, см. врезку в начале файла):

```hcl
resource "null_resource" "recovery_ro_bind" {
  for_each = { for k, v in var.nodes : k => v if v.recovery_ro_device != null }

  triggers = {
    vm_id  = module.node[each.key].vm_id
    device = each.value.recovery_ro_device
  }

  provisioner "local-exec" {
    command = "ssh root@${var.proxmox_host_ip} qm set ${module.node[each.key].vm_id} -scsi1 ${each.value.recovery_ro_device},ro=1"
  }

  depends_on = [module.node]
}
```

**Ограничения этого подхода (честно, не first-class ресурс):**

- Идемпотентно на уровне `qm set` (повторный вызов с теми же параметрами
  — no-op), но `triggers` реагируют только на смену `vm_id` (пересоздание
  VM) или `recovery_ro_device`. Если диск отцепят руками в обход
  Terraform — `apply` этого не заметит и не восстановит state.
- Индекс `scsi1` захардкожен под текущую топологию дисков этой VM. Если
  модуль когда-нибудь добавит ещё один диск на `scsi1` — коллизия,
  двигать на `scsi2`.
- `local-exec` бежит там, откуда вызван `apply` — требует рабочего
  ssh-доступа до `root@<proxmox_host_ip>` именно оттуда. Если apply
  когда-нибудь уйдёт в CI (self-hosted runner) — у раннера должен быть
  свой ключ, иначе тихий/не тихий фейл на этом шаге.
- Диск в госте появляется как raw `/dev/sdb`, не `/dev/sdb1` — Proxmox
  отдаёт устройство целиком, разделы QEMU не пробрасывает отдельно.

### Монтирование внутри гостя (не Terraform, configuration management уровня VM)

Файловая система — exFAT, ядро Ubuntu 24.04 cloud-image не тащит модуль
`exfat` (пусто в `/proc/filesystems`), нужен userspace-драйвер:

```bash
sudo apt-get install -y exfat-fuse
```

Монтирование через сам бинарник хелпера, не через `mount -t exfat`
(тип не зарегистрирован без встроенного ядерного модуля):

```bash
sudo mount.exfat-fuse -o ro /dev/sdb /mnt/recovery-ro
```

Персистентность — через systemd `.mount`-юнит (не `/etc/fstab`, с
`fuse.exfat-fuse` через fstab исторически ненадёжно):

```ini
# /etc/systemd/system/mnt-recovery-ro.mount
[Unit]
Description=Recovery exFAT disk (RO)
After=local-fs.target

[Mount]
What=/dev/sdb
Where=/mnt/recovery-ro
Type=exfat-fuse
Options=ro

[Install]
WantedBy=multi-user.target
```

> **⚠️ `Type=` — не `fuse.exfat-fuse`, а `exfat-fuse`.** Пакет
> `exfat-fuse` на текущей версии Ubuntu ставит бинарник
> `/sbin/mount.exfat-fuse` (проверено: `dpkg -L exfat-fuse | grep bin`).
> Systemd для `Type=<X>` вызывает `mount -t <X>`, который резолвится в
> хелпер по шаблону `/sbin/mount.<X>` — с `Type=exfat-fuse` это находит
> `/sbin/mount.exfat-fuse` и работает. Более старый/другой вариант
> `Type=fuse.exfat-fuse` идёт через generic FUSE-враппер
> (`/sbin/mount.fuse`), который в свою очередь ищет в `PATH` команду
> **без** префикса `mount.` — то есть `exfat-fuse` — а такого бинарника
> в пакете нет, отсюда `exfat-fuse: not found` (`status=127`) на старте
> systemd, при том что ручной `sudo mount.exfat-fuse ...` работает без
> проблем. Если после апдейта дистрибутива/пакета юнит вдруг снова не
> стартует с `status=127` — первым делом сверить `dpkg -L exfat-fuse`
> на актуальное имя бинарника, соответствие могло опять смениться.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-recovery-ro.mount
```

**Грабли, если маунт пропал:** Immich при скане External Library видит
пустую директорию вместо файлов → помечает все ассеты как offline →
кидает в Trash. `Restore` в UI не помогает — следующий scan/cron снова
находит пустую папку и повторяет цикл. Плюс bind-mount в
`docker-compose.yml` резолвится в момент старта контейнера — если диск
примонтирован на хосте VM уже после старта контейнера, нужен
`docker compose restart immich-server` (или `systemctl restart
immich.service`), иначе контейнер продолжит видеть старую (пустую)
точку монтирования.

**Симптом на стороне джобов, если маунт пропал, а Immich уже
крутится:** массовые `ENOENT: no such file or directory` /
`Input file is missing` в логе `immich_server` по всем джобам, которые
трогают файл (`AssetExtractMetadata`, `AssetGenerateThumbnails`,
`PersonGenerateThumbnail` — последнее особенно заметно на странице
**Job Queues → Facial Recognition**, поскольку генерация превью лица
идёт после кластеризации). Из-за того, что `stat()` на несуществующий
файл падает почти мгновенно, а не гоняет реальную ML-инференцию,
очередь **Waiting** на графике "Jobs over time" обманчиво резко падает
— выглядит как быстрый прогресс, на деле это волна фейлов при
низкой загрузке CPU (в инциденте 26.08.2026 — 13.5% CPU при "обработке"
тысяч задач в минуту).

**Разбор такого инцидента, если он уже произошёл:**

```bash
# 1. Убедиться, что диск реально не смонтирован
sudo systemctl status 'mnt-recovery\x2dro.mount'
# смотреть на "exit-code" / "status=127" в journalctl-выхлопе юнита

# 2. Проверить, что мешает бинарнику найтись (см. врезку про Type= выше)
which mount.exfat-fuse
dpkg -L exfat-fuse | grep bin

# 3. Смонтировать (после фикса Type= в юните, если он был неверным)
sudo systemctl daemon-reload
sudo systemctl start 'mnt-recovery\x2dro.mount'

# 4. Убедиться, что видно с хоста VM
ls /mnt/recovery-ro

# 5. Перезапустить стек, чтобы контейнер увидел непустой bind-mount
#    (голый `docker restart immich_server` тоже работает, но раз стек
#    управляется через systemd — предпочтительно так:)
sudo systemctl restart immich.service

# 6. Проверить, что контейнер видит файлы
docker exec immich_server ls -la /mnt/recovery-ro

# 7. В Immich UI: Trash — проверить, не улетели ли ассеты как offline
#    за время простоя диска. Если да — Scan Library ПЕРЕД Restore,
#    иначе следующий scan/cron повторит цикл (см. предупреждение выше)

# 8. Job Queues → Remove failed jobs (по всем затронутым очередям)

# 9. Пересканировать External Library и перезапустить джобы по цепочке:
#    Metadata Extraction → Thumbnail Generation → Face Detection
#    → Facial Recognition
```

## docker-compose, не swarm

Сознательное решение, не временная заглушка. Причины расписаны в
основном README (история разбора), кратко:

- `env_file`, `depends_on` не работают в `docker stack deploy`
- Все volume'ы — bind mount'ы к конкретным путям на конкретной VM,
  переносимость между нодами (смысл существования swarm) неприменима
- Postgres + библиотека + ML-кеш — насквозь stateful, single-instance

Автозапуск/restart-политика — через systemd, не через swarm:

```ini
# /etc/systemd/system/immich.service
[Unit]
Description=Immich stack
Requires=docker.service
After=docker.service network-online.target mnt-recovery-ro.mount

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/ubuntu/immich
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
```

Обрати внимание на `After=... mnt-recovery-ro.mount` — важно, чтобы
compose стартовал строго после маунта recovery-диска, иначе та же
проблема с offline-ассетами повторится уже на этапе автозагрузки.

```bash
sudo systemctl enable --now immich.service
```

## Деплой

```bash
cd environments/immich-node
source ../../scripts/vault-apply-wrapper.sh   # один раз на сессию — фетчит
                                                # api-token/ssh-ключи/minio-creds
                                                # из Vault, terraform.tfvars не нужен
terraform init
terraform apply
```

После первого apply — вручную (не покрыто Terraform):

1. Перенос данных с прежнего хоста (`rsync -a --numeric-ids`, права
   через числовые uid/gid — см. основной README, там разобран весь
   траблшутинг с `wrong permissions`/`FATAL` при первом старте postgres)
2. Установка `exfat-fuse`, монтирование `recovery-ro`
3. Накат systemd-юнитов (`mnt-recovery-ro.mount`, `immich.service`) —
   **см. врезку выше про `Type=exfat-fuse`**, не `fuse.exfat-fuse`
4. `qm stop 101 && qm start 101` — если `cpu_type` менялся на уже
   существующей VM, для применения нужен полный рестарт, не reboot
   изнутри гостя

## Проверка здоровья

```bash
# CPU флаги реально применились (не просто конфиг переписан)
ssh immich cat /proc/cpuinfo | grep -m1 flags | tr ' ' '\n' | grep -E 'sse4_2|popcnt|avx2'

# recovery-ro смонтирован и виден контейнеру, не только хосту VM
docker exec -it immich_server ls -la /mnt/recovery-ro

# postgres поднялась без permission errors
docker compose logs database | grep "ready to accept connections"
```

## Журнал инцидентов

| Дата | Что случилось | Причина | Фикс |
|---|---|---|---|
| 2026-08-26 | `mnt-recovery-ro.mount` в `failed`, тысячи `ENOENT`/`Input file is missing` в логах `immich_server`, очередь Facial Recognition резко "падает" (фейлы, не прогресс) | `Type=fuse.exfat-fuse` в юните не матчился с реальным бинарником пакета (`/sbin/mount.exfat-fuse`, без префикса `fuse.`) → `exfat-fuse: not found`, `status=127` | Юнит переведён на `Type=exfat-fuse`; после ремонта — `systemctl restart immich.service` для пересборки bind-mount в контейнере; проверено, что `Trash`/offline-ассеты не пострадали до перезапуска (сработали вовремя) |
| 2026-08-27 | Ревью диффа обнаружило, что дефолт `var.nodes["immich-node"]` в `variables.tf` разъезжался с этой таблицей (README показывал 4 vCPU/70GB, реальные значения — 2 vCPU/100GB) | Таблица не обновлялась после апгрейда ресурсов диска | Таблица выше синхронизирована с `variables.tf` (2 vCPU / 4GB / 100GB); см. [docs/troubleshooting.md](../../docs/troubleshooting.md#immich-node-variablestf-had-a-strict-object-type-violation-and-a-stale-readme-table) для полного разбора (тот же ревью также поймал три лишних ключа в дефолте, не описанных в `object({...})`-типе, до того как они попали в `apply`) |
| 2026-08-28 | README/`variables.tf` продолжали указывать `bare-pve` как хост, хотя дерево Datacenter всегда показывало VM 101 на `pve-rog` | Дефолт `proxmox_node` никогда не сверялся с фактическим размещением после того, как `locals.tf`/эндпоинт-резолюшн внедрили по всем environments | `proxmox_node` дефолт исправлен на `pve-rog`, `proxmox_host_ip` синхронно на `.20` (иначе `null_resource.recovery_ro_bind` продолжил бы слать `qm set` не туда), таблица топологии и `Golden image` строка обновлены под факт |
