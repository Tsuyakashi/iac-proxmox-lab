# environments/workstation
#
# Desktop VM(и) на pve-rog: ставится вручную с ISO через встроенный
# cdrom (Ubuntu Desktop, не server-версия) — поэтому НЕ через
# modules/proxmox-vm. Тот модуль целиком построен вокруг clone{} из
# golden image + cloud-init user-data (см. modules/proxmox-vm/main.tf) —
# сюда не подходит архитектурно. Здесь Terraform только заводит железо
# VM (диск, сеть, vga, cdrom с ISO, USB-периферия, аудио), сам инсталл —
# руками через SPICE/консоль, обычный GUI-инсталлятор.
#
# Раньше пробовали физическую загрузочную флешку как сырой scsi1
# block-device passthrough (qm set -scsi1 /dev/sdX,ro=1) — не взлетело:
# SeaBIOS не смог корректно забутиться с гибридного ISO-образа на флешке
# через голое виртуальное SCSI-устройство ("no bootable device"). ISO в
# датасторе + виртуальный cdrom — надёжный путь, тот же, что
# рассматривался изначально.
#
# qxl2 вместо GPU passthrough — см. обсуждение в чате (Kepler reset
# bug без софтового фикса + драйвер 470.xxx официально EOL под свежие
# ядра; virtio-gl пробовали первым, но он single-head в этой сборке
# QEMU — см. README). Юзкейс — браузер/офис/редкие казуальные 2D-игры.
#
# USB-периферия (клавиатура/мышь/веб-камера) — это отдельная история от
# GPU passthrough и его reset bug'ом никак не связана: обычный host-USB
# passthrough по vendorid:productid. Проксмокс отдаёт "only root can set
# 'usbN' config for real devices" для любого не-root доступа, включая
# полноправный API-токен — поэтому это тоже null_resource + qm set по
# SSH (root@pam), а не декларативный usb{} блок провайдера.
#
# Аудио — через SPICE audio channel (ich9-intel-hda + driver "spice"), не
# через отдельный USB-проброс звуковой карты: спайс сам тащит звук на
# клиента (тот же remote-viewer на хосте из scripts/desktop-kiosk-setup.sh),
# не требует, чтобы в госте была видна какая-то конкретная физическая
# аудио-железка.
#
# Отдельный root-модуль/state (тот же паттерн "Two independent root
# modules, on purpose" из корневого README) — desktop VM(и) не зависят от
# lifecycle нод/раннера, и наоборот.
#
# nodes — карта, не одиночный ресурс: ubuntu-workstation + windows-workstation
# живут на одном физическом хосте параллельно — паравиртуальное видео
# (qxl2) не эксклюзивно, в отличие от GPU passthrough, так что обе VM
# заведены декларативно всегда, включена в моменте только одна (see
# on_boot ниже + вручную qm start/stop той, что нужна).
#
# on_boot решает, какая из двух поднимется сама при перезагрузке/старте
# самой ноды pve-rog — контролируется полем on_boot в var.nodes, Terraform
# не проверяет, что true выставлено ровно у одной записи (см. variables.tf).

resource "proxmox_virtual_environment_vm" "workstation" {
  for_each = var.nodes

  name      = each.key
  node_name = coalesce(each.value.proxmox_node, var.proxmox_node)
  tags      = [each.value.tag_name]
  on_boot   = each.value.on_boot

  # Никакого clone{}/initialization{} — VM создаётся "с нуля", пустой
  # диск. Сеть/пользователя/пароль задаёшь в самом GUI-инсталляторе.

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = each.value.datastore_id_disk
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
  }

  # ISO — виртуальный cdrom (ide3), не пустой, если задан iso_file_id.
  # Образ должен уже лежать в датасторе ДО apply (см. terraform.tfvars.example
  # / переменную iso_file_id ниже) — Terraform его не качает и не заливает
  # сам.
  dynamic "cdrom" {
    for_each = each.value.iso_file_id != null ? [each.value.iso_file_id] : []
    content {
      file_id = cdrom.value
    }
  }

  # Пока не установлено — грузимся с ide3 (ISO) первым. После установки
  # переключи boot_from_iso = false и сделай re-apply, иначе случайный
  # ребут снова закинет в инсталлятор.
  boot_order = (
    each.value.iso_file_id != null && each.value.boot_from_iso
    ? ["ide3", "scsi0"]
    : ["scsi0", "ide3"]
  )

  network_device {
    bridge      = var.network_bridge
    mac_address = each.value.mac
  }

  # guest agent появится только после того, как руками поставишь
  # qemu-guest-agent внутри установленной Ubuntu — до этого просто нет
  # ответа на agent-запросы, это ок, wait_for_ip выключен.
  agent {
    enabled = true

    wait_for_ip {
      disabled = true
    }
  }

  serial_device {
    device = "socket"
  }

  vga {
    type   = each.value.vga_type
    memory = each.value.vga_memory
  }

  # SPICE audio channel — звук идёт клиенту (remote-viewer на самом
  # pve-rog, см. scripts/desktop-kiosk-setup.sh), без проброса физической
  # звуковой карты хоста внутрь гостя.
  audio_device {
    device = "ich9-intel-hda"
    driver = "spice"
  }

  operating_system {
    type = each.value.os_type
  }

  lifecycle {
    ignore_changes = [usb]
  }
}

locals {
  usb_bindings = flatten([
    for k, v in var.nodes : [
      for idx, dev in v.usb_devices : {
        key          = "${k}-${idx}"
        node_key     = k
        proxmox_node = coalesce(v.proxmox_node, var.proxmox_node)
        usb_index    = idx
        device       = dev
      }
    ]
  ])
}

# Реальные USB-устройства (host=vendorid:productid) можно задать только
# через root@pam по SSH — Proxmox API отдаёт "only root can set 'usbN'
# config for real devices" для любого не-root доступа, включая полноправный
# API-токен.
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
