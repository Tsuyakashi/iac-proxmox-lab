# modules

Общая библиотека Terraform-модулей под кластер `nexus-cluster`, провайдер
`bpg/proxmox` 0.115+. Все остальные репы берут модули отсюда по тегу и своих
копий не держат.

```hcl
module "sandbox" {
  source = "git::https://github.com/Tsuyakashi/iac-proxmox-lab.git//modules/isolated-vm?ref=modules/v0.1.0"
  # ...
}
```

Готовые корни с вызовами всех модулей лежат в [`../examples`](../examples).

## Модули

| Модуль | Что | Ресурсы |
|---|---|---|
| `pve-nodes` | карта нод: endpoint API и SSH-адрес. Чистые данные, можно отдавать прямо в `provider` | — |
| `sdn` | Simple-зона на одной ноде, любое число vnet; vnet с `subnet` маршрутизируется (шлюз, опционально SNAT), без него — чистый L2 | zone, vnet, subnet, applier ×2 |
| `pve-image` | cloud-образ, который нода качает сама в `import` | `proxmox_download_file` |
| `cloud-init` | vendor-data сниппет: guest agent, Docker (+ rootless), свои пакеты, файлы, команды | `proxmox_virtual_environment_file` (**SSH**) |
| `pve-vm` | одна VM: cloud-образ + cloud-init **или** ISO без cloud-init; несколько NIC; доп. диски (`extra_disks`); PCI по маппингам; USB; флаг `protection` | VM |
| `pve-ct` | один LXC: unprivileged или privileged, только то, что может токен | CT |
| `guest-firewall` | файрвол VM/CT: IN DROP, SSH от шлюза, разрешённые сети, OUT DROP в частные диапазоны и tailnet | options, rules |
| `isolated-vm` | композит под самый частый случай: свой SNAT-сегмент + образ + сниппет + VM + файрвол | всё выше |

SDN не обязателен. Для локальных машин (workstation, runner) используются
`pve-vm` / `pve-ct` с `bridge = "vmbr0"`, файрвол по желанию.

## Решения, общие для всех

- **Корень владеет провайдером и backend'ом**, модули — нет. Провайдер
  собирается из `pve-nodes` (пример в `examples/*/providers.tf`).
- **`ignore_changes` статичен**, поэтому в `pve-vm` и `pve-ct` он покрывает
  все случаи сразу. Терраформ не трогает:
  - VM: `started`, `hook_script_file_id`, `kvm_arguments`, `machine`;
  - CT: `features`, `device_passthrough`, `mount_point`, `hook_script_file_id`,
    `description`, `console`, `started`, `template_file_id`, dns domain.

  Это либо root@pam-only настройки, которые на ноде доводит скрипт проекта,
  либо run state, которым управляет кто-то другой (GPU-арбитр). Следствие:
  `mount_points` у CT и `started` у обоих применяются только при создании.
- **Сниппет подключается строкой**, а не ссылкой на ресурс. Правка vendor-data
  не пересоздаёт VM, поэтому на VM нужен `depends_on = [module.<cloud_init>]`.
  Применяется vendor-data только при первой загрузке: правка = `-replace` VM.
- **Файрвол пересоздаётся вместе с гостем** через `instance_id`, это UUID,
  который меняется при каждом пересоздании VM/CT. Proxmox удаляет `<vmid>.fw`
  вместе с гостем, а фиксированный `vm_id` между пересозданиями не меняется.
- **`radv = false`** на всех гостях: дефолт провайдера `true` позволяет гостю
  рассылать IPv6 RA в сегмент.
- **CT по умолчанию с `1.1.1.1` / `8.8.8.8`**, а VM-сниппеты — с `dns_servers`.
  Резолвер нод — MagicDNS, из гостя он недоступен.
- **Образ и сниппет принадлежат стейту проекта.** `destroy` удаляет их с
  ноды, имена должны быть уникальными (префикс проекта).

## Требования к кластеру

- Content types `import` и `snippets` на `local`.
- Роль `TerraformProv`, назначенная на `/`: `VM.*`, `Datastore.*`,
  `SDN.Allocate`, `SDN.Use`, `Mapping.Use`, `Mapping.Modify`, `VM.Config.HWType`,
  `Sys.Audit`, `Sys.Modify` (privileged CT, `proxmox_download_file`).
  Источник правды — `scripts/cluster/role-init.sh`.
- Файрвол датацентра включён (`enable: 1`), иначе `guest-firewall` ничего не
  делает.
- Root SSH к нодам через ssh-agent с одним ключом (снипеты). Многоключевой
  агент упирается в `MaxAuthTries`.

## Версии

Теги вида `modules/vX.Y.Z`. Мажорный номер растёт при любом изменении,
которое на существующем стейте даёт replace или требует `moved`. В проектах
версия пинится всегда, обновление — осознанное, с plan без destroy.

## Проверка без кластера

```bash
for d in modules/* examples/*; do
  (cd "$d" && terraform init -backend=false -input=false >/dev/null && terraform validate) || echo "FAIL: $d"
done
terraform fmt -check -recursive
```

Корни из `examples/` планируются и без доступа к API:
`TF_VAR_proxmox_api_token=x terraform plan -refresh=false`.
