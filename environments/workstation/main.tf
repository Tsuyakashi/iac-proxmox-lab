# environments/workstation
#
# Desktop VM(и) на pve-rog: ставится вручную с загрузочной флешки (Ubuntu
# Desktop, не server-версия) — поэтому НЕ через modules/proxmox-vm. Тот
# модуль целиком построен вокруг clone{} из golden image + cloud-init
# user-data (см. modules/proxmox-vm/main.tf) — сюда не подходит
# архитектурно. Здесь Terraform только заводит железо VM (диск, сеть,
# vga, USB-периферия, аудио) + пробрасывает физическую флешку как scsi1,
# сам инсталл — руками через SPICE/консоль, обычный GUI-инсталлятор.
#
# virtio-gl вместо GPU passthrough — см. обсуждение в чате (Kepler reset
# bug без софтового фикса + драйвер 470.xxx официально EOL под свежие
# ядра). Юзкейс — браузер/офис/редкие казуальные 2D-игры.
#
# USB-периферия (клавиатура/мышь/веб-камера) — это отдельная история от
# GPU passthrough и его reset bug'ом никак не связана: обычный host-USB
# passthrough по vendorid:productid, штатно поддерживается провайдером
# декларативно (в отличие от флешки-инсталлятора выше — та физический
# блочный диск, а не USB-HID/UVC устройство, отсюда и null_resource +
# qm set для неё, а не для usb{} здесь).
#
# Аудио — через SPICE audio channel (ich9-intel-hda + driver "spice"), не
# через отдельный USB-проброс звуковой карты: спайс сам тащит звук на
# клиента (тот же remote-viewer на хосте из desktop-kiosk-setup.sh), не
# требует, чтобы в госте была видна какая-то конкретная физическая
# аудио-железка.
#
# Отдельный root-модуль/state (тот же паттерн "Two independent root
# modules, on purpose" из корневого README) — desktop VM(и) не зависят от
# lifecycle нод/раннера, и наоборот.
#
# nodes — карта, не одиночный ресурс: вторая запись под Windows-десктоп
# (та же схема — своя флешка, virtio-gl, свои usb_devices) добавится сюда
# же позже. Обе VM смогут жить параллельно на одном физическом GPU —
# virtio не эксклюзивен в отличие от passthrough.

resource "proxmox_virtual_environment_vm" "workstation" {
  for_each = var.nodes

  name      = each.key
  node_name = coalesce(each.value.proxmox_node, var.proxmox_node)
  tags      = [each.value.tag_name]

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

  # scsi1 (флешка-инсталлятор) заводится ниже отдельным null_resource, не
  # здесь — тот же паттерн, что environments/immich-node/main.tf уже
  # использует для recovery-ro (см. корневой README, "The
  # raw-disk-passthrough pattern"): bpg/proxmox не умеет декларативно
  # цеплять физическое блочное устройство хоста как disk-ресурс, только
  # через qm set напрямую.
  boot_order = (
    each.value.installer_usb_device != null && each.value.boot_from_installer
    ? ["scsi1", "scsi0"]
    : ["scsi0", "scsi1"]
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

  # Клавиатура/мышь/веб-камера — обычный host-USB passthrough по
  # vendorid:productid (см. `ssh pve-rog lsusb`). Никак не связано с
  # флешкой-инсталлятором (та — блочное устройство, отдельный механизм
  # выше) и никак не связано с reset bug — это чисто HID/UVC USB,
  # затронутая passthrough-проблема была только у видеовыходов GPU.

  # SPICE audio channel — звук идёт клиенту (remote-viewer на самом
  # pve-rog, см. scripts/desktop-kiosk-setup.sh), без проброса физической
  # звуковой карты хоста внутрь гостя.
  audio_device {
    device = "ich9-intel-hda"
    driver = "spice"
  }

  operating_system {
    type = "l26"
  }
}

# Проброс физической флешки-инсталлятора как scsi1, read-only. Идентично
# environments/immich-node/main.tf::null_resource.recovery_ro_bind — см.
# то же "Known limitations" в его README: triggers реагируют только на
# смену vm_id/device, не на ручное выдёргивание флешки (drift-tolerant по
# омиссии, не drift-corrected — если физически выдернешь флешку, apply
# этого не заметит и state не откатит).
resource "null_resource" "installer_usb_bind" {
  for_each = { for k, v in var.nodes : k => v if v.installer_usb_device != null }

  triggers = {
    vm_id  = proxmox_virtual_environment_vm.workstation[each.key].vm_id
    device = each.value.installer_usb_device
  }

  provisioner "local-exec" {
    command = "ssh root@${coalesce(each.value.proxmox_node, var.proxmox_node)} qm set ${proxmox_virtual_environment_vm.workstation[each.key].vm_id} -scsi1 ${each.value.installer_usb_device},ro=1"
  }

  depends_on = [proxmox_virtual_environment_vm.workstation]
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
# API-токен. Тот же паттерн, что installer_usb_bind выше для флешки.
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
