# modules/proxmox-vm

Клонирует одну VM из golden image (`var.template_vm_id`) с cloud-init
снипетом (SSH-пользователь `ubuntu`, `qemu-guest-agent`, hostname) и
статическим либо dhcp-адресом.

Не содержит `backend`/`provider` — конфигурирует их вызывающий root-модуль.

## Пример: статический адрес

```hcl
module "node" {
  source = "../../modules/proxmox-vm"

  name           = "prod-node"
  proxmox_node   = "bare-pve"
  template_vm_id = 9000
  tags           = ["prod"]
  cores          = 2
  memory         = 2048
  mac_address    = "BC:24:11:B4:5A:47"

  ip_config = {
    mode    = "static"
    address = "192.168.100.101/24"
    gateway = "192.168.100.1"
  }
  wait_for_ip_disabled = true

  vm_ssh_public_key = var.vm_ssh_public_key
  ci_ssh_public_key = var.ci_ssh_public_key
}
```

## Пример: dhcp

```hcl
module "ci_runner" {
  source = "../../modules/proxmox-vm"

  name           = "ci-runner"
  proxmox_node   = "bare-pve"
  template_vm_id = 9000
  tags           = ["ci"]
  cores          = 1
  memory         = 1536
  disk_size      = 20

  ip_config = { mode = "dhcp" }

  vm_ssh_public_key = var.vm_ssh_public_key
  ci_ssh_public_key = var.ci_ssh_public_key
}
```

## Примечание об исправленном баге

В исходной (до-модульной) версии `runner/runner.tf` вызывал `templatefile()`
без параметра `hostname`, хотя `cloud-init/user-data.yml.tpl` использует
`${hostname}` — это падало бы на `terraform plan/apply` с ошибкой
`no value for required variable "hostname"`. Модуль это чинит: `hostname`
по умолчанию берётся из `var.name`, если не задан явно.
