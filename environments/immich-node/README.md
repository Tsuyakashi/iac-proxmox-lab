# immich-node

Отдельная VM под Immich (docker-compose, не swarm) на ноде `pve` (`.30`),
`local-lvm`. Переехала с `rog` после инцидента с заполнением диска
(immich-compose съел место под nested `pve-rog`, VM встала на паузу,
кластер потерял кворум). История разбора — в основном README репозитория.

## Топология

| | |
|---|---|
| VM ID | 101 |
| Host | `pve` (`.30`) |
| IP | `192.168.100.60/24` |
| Ресурсы | 4 vCPU / 4GB RAM / 70GB disk (`local-lvm`) |
| CPU type | `host` |

Не изолирована в отдельный VLAN/network namespace (в отличие от
`minecraft-node`) — Immich наружу не выставляется.

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
к хосту `pve` как `/dev/sdb1` и проброшенном в VM как raw block device
в режиме read-only.

В Immich это настроено как **External Library** с путём
`/mnt/recovery-ro` — не через `UPLOAD_LOCATION`.

### Почему не датастор-volume

`bpg/proxmox` провайдер умеет декларативно описывать только
datastore-backed диски (`disk { ... }` внутри `proxmox_virtual_environment_vm`).
Проброс уже существующего физического блочного устройства хоста как
disk-ресурс им не поддерживается — единственный путь — `qm set` напрямую.

### Реализация в Terraform

`null_resource` с `local-exec`, дергающий `qm set` по ssh на хост:

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
Type=fuse.exfat-fuse
Options=ro

[Install]
WantedBy=multi-user.target
```

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
`docker compose restart immich-server`, иначе контейнер продолжит
видеть старую (пустую) точку монтирования.

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
cp terraform.tfvars.example terraform.tfvars   # заполнить
export AWS_ACCESS_KEY_ID=<minio-user>
export AWS_SECRET_ACCESS_KEY=<minio-password>
terraform init
terraform apply
```

После первого apply — вручную (не покрыто Terraform):

1. Перенос данных с прежнего хоста (`rsync -a --numeric-ids`, права
   через числовые uid/gid — см. основной README, там разобран весь
   траблшутинг с `wrong permissions`/`FATAL` при первом старте postgres)
2. Установка `exfat-fuse`, монтирование `recovery-ro`
3. Накат systemd-юнитов (`mnt-recovery-ro.mount`, `immich.service`)
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
