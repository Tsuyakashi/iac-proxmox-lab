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
# GPU passthrough для windows-workstation — см. gpu_pci_id в variables.tf
# и scripts/gpu-passthrough-setup.sh. Изначально (см. корневой README)
# passthrough был отклонён целиком из-за Kepler reset bug — решение
# пересмотрено сознательно, с принятием trade-off'а: после сессии с GPU
# нужен полный ребут хоста, не просто qm stop/start (карта не гарантирует
# штатный сброс). Headless — у 770M на этом Optimus-ноутбуке нет
# физического видеовыхода, смотришь через RDP внутри Windows, не через
# консоль/SPICE.
#
# USB-периферия (клавиатура/мышь/веб-камера) — это отдельная история от
# GPU passthrough и его reset bug'ом никак не связана: обычный host-USB
# passthrough по vendorid:productid. Проксмокс отдаёт "only root can set
# 'usbN' config for real devices" для любого не-root доступа, включая
# полноправный API-токен — поэтому это тоже null_resource + qm set по
# SSH (root@pam), а не декларативный usb{} блок провайдера.
#
# Аудио — через SPICE audio channel (ich9-intel-hda + driver "spice"),
# опционально (spice_audio в variables.tf) — нужен только тем VM, куда
# реально заходишь через SPICE/kiosk. windows-workstation его не
# использует — звук идёт через RDP.
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

# Причина disk_interface (см. variables.tf): Windows-инсталлятор не видит
# диск на scsi0/virtio-scsi без загрузки стороннего драйвера ("Нам не
# удалось найти драйверы" на шаге разметки) — у Linux-гостя virtio в ядре
# из коробки, у Windows нет. sata0 работает без доп. драйверов у обеих ОС,
# поэтому Windows-запись сидит на нём, Ubuntu остаётся на scsi0 (раз уже
# так стояло и работало).

# mutex_exclusive: обе VM (ubuntu/windows) сидят на одних и тех же
# usb_devices/vga — запускать их одновременно бессмысленно и физически
# конфликтно (usb-устройство не может слушать оба гостя разом). Вместо
# честного слова "не включай вторую, пока не выключил первую" — жёсткая
# блокировка на уровне самого Proxmox через hookscript (см.
# scripts/workstation-exclusive-hook.sh): pre-start смотрит другие VM с
# тегом "ws-exclusive" на этой ноде, если хоть одна running — отказывает
# в старте. Работает независимо от того, как стартуют VM (qm start,
# веб-UI, автостарт при ребуте хоста через on_boot) — не только через
# terraform apply.
#
# hook_script_file_id как декларативный атрибут провайдера НЕ работает —
# Proxmox отдаёт "only root can set 'hookscript' config" даже для
# полноправного API-токена (тот же класс ограничения, что usbN/hostpciN
# выше). Привязка идёт тем же null_resource + qm set по SSH (root@pam),
# см. null_resource.hookscript_bind ниже. Сам файл-снипет заливается
# декларативно (это разрешено — ограничение только на "приписать
# hookscript к конкретной VM", не на загрузку файла в датастор), но после
# любого re-apply, меняющего содержимое скрипта, право на исполнение
# слетает и его нужно возвращать руками:
#   ssh pve-rog chmod +x /var/lib/vz/snippets/workstation-exclusive-hook.sh
resource "proxmox_virtual_environment_file" "workstation_exclusive_hook" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = file("${path.module}/../../scripts/workstation-exclusive-hook.sh")
    file_name = "workstation-exclusive-hook.sh"
  }
}

resource "proxmox_virtual_environment_vm" "workstation" {
  for_each = var.nodes

  name      = each.key
  node_name = coalesce(each.value.proxmox_node, var.proxmox_node)
  tags      = each.value.mutex_exclusive ? [each.value.tag_name, "ws-exclusive"] : [each.value.tag_name]
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
    interface    = each.value.disk_interface
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
    ? ["ide3", each.value.disk_interface]
    : [each.value.disk_interface, "ide3"]
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

  # SPICE audio channel — только если реально смотришь через SPICE
  # (kiosk/remote-viewer). Для windows-workstation выключено (spice_audio
  # = false) — звук идёт через сам RDP, отдельный SPICE-audio-канал
  # никем не потребляется.
  dynamic "audio_device" {
    for_each = each.value.spice_audio ? [1] : []
    content {
      device = "ich9-intel-hda"
      driver = "spice"
    }
  }

  operating_system {
    type = each.value.os_type
  }

  lifecycle {
    # cpu — статически в ignore_changes для ОБЕИХ VM, не только для той,
    # что с hide_hypervisor = true: Terraform не поддерживает условный
    # (per-instance) ignore_changes, список должен быть статическим для
    # всех элементов for_each. Trade-off: cores для ubuntu-workstation
    # тоже больше не меняется через terraform apply — только руками
    # (qm set <id> -cores N), тем же путём, что и hidden=1 ниже.
    #
    # hook_script_file_id — не задаётся в HCL вообще (см. комментарий
    # выше про "only root can set"), но раз он физически стоит на VM
    # через null_resource.hookscript_bind, provider увидит его при
    # refresh и попытается снять той же запрещённой командой без этого
    # ignore_changes.
    ignore_changes = [usb, cpu, hook_script_file_id]
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

  gpu_bindings = {
    for k, v in var.nodes : k => {
      proxmox_node = coalesce(v.proxmox_node, var.proxmox_node)
      pci_id       = v.gpu_pci_id
    } if v.gpu_pci_id != null
  }

  hidden_cpu_bindings = {
    for k, v in var.nodes : k => coalesce(v.proxmox_node, var.proxmox_node)
    if v.hide_hypervisor
  }

  hookscript_bindings = {
    for k, v in var.nodes : k => coalesce(v.proxmox_node, var.proxmox_node)
    if v.mutex_exclusive
  }
}

# hookscript тоже "only root can set" (см. комментарий у ресурса VM выше)
# — тот же null_resource + SSH паттерн, что usbN/hostpciN. Файл-снипет
# уже залит декларативно (proxmox_virtual_environment_file выше), тут
# только приписываем его к конкретной VM.
resource "null_resource" "hookscript_bind" {
  for_each = local.hookscript_bindings

  triggers = {
    vm_id = proxmox_virtual_environment_vm.workstation[each.key].vm_id
    file  = proxmox_virtual_environment_file.workstation_exclusive_hook.id
  }

  provisioner "local-exec" {
    command = "ssh root@${each.value} qm set ${proxmox_virtual_environment_vm.workstation[each.key].vm_id} -hookscript ${proxmox_virtual_environment_file.workstation_exclusive_hook.id}"
  }

  depends_on = [proxmox_virtual_environment_vm.workstation]
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

# GPU passthrough (hostpci0) — тот же паттерн, что usbN/recovery_ro_bind:
# PCI passthrough Proxmox тоже не пускает через API-токен, только
# root@pam по SSH. bus:slot без .function захватывает видео- и
# HDMI-audio функции одним блоком. Headless (без x-vga) — см.
# variables.tf про Optimus/отсутствие физического видеовыхода у 770M.
#
# ВАЖНО: требует одноразовой настройки хоста ДО первого apply с этим
# полем — scripts/gpu-passthrough-setup.sh (IOMMU, vfio-pci bind,
# блэклист nouveau), иначе qm set пройдёт, но VM не застартует (карта
# ещё занята host-драйвером).
resource "null_resource" "gpu_bind" {
  for_each = local.gpu_bindings

  triggers = {
    vm_id  = proxmox_virtual_environment_vm.workstation[each.key].vm_id
    pci_id = each.value.pci_id
  }

  provisioner "local-exec" {
    command = "ssh root@${each.value.proxmox_node} qm set ${proxmox_virtual_environment_vm.workstation[each.key].vm_id} -hostpci0 ${each.value.pci_id}"
  }

  depends_on = [proxmox_virtual_environment_vm.workstation]
}

# Обход анти-виртуалочной защиты GeForce-драйвера (Code 43 в диспетчере
# устройств) — тот же null_resource+SSH подход. Идёт отдельным ресурсом
# от gpu_bind, а не одной командой с ним, чтобы работать и для случая,
# когда карту не пробрасываешь, но по какой-то причине hide_hypervisor
# всё равно нужен (не текущий кейс, но поля независимы в variables.tf).
resource "null_resource" "cpu_hidden" {
  for_each = local.hidden_cpu_bindings

  triggers = {
    vm_id = proxmox_virtual_environment_vm.workstation[each.key].vm_id
  }

  provisioner "local-exec" {
    command = "ssh root@${each.value} qm set ${proxmox_virtual_environment_vm.workstation[each.key].vm_id} -cpu host,hidden=1"
  }

  depends_on = [proxmox_virtual_environment_vm.workstation]
}
