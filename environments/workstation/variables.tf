variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "proxmox_insecure" {
  type    = bool
  default = true
}

variable "proxmox_node" {
  description = "Default target Proxmox node. pve-rog по умолчанию — VT-d включен, есть запас CPU/RAM (peak-load нода в кластере, см. корневой README Architecture). Переопределяется per-node через nodes[].proxmox_node."
  type        = string
  default     = "pve-rog"
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "nodes" {
  description = <<-EOT
    Desktop VM topology. Две записи: Ubuntu Desktop (установка с ISO через
    виртуальный cdrom, qxl2 вместо GPU passthrough — Kepler reset bug без
    софтового фикса + драйвер 470.xxx официально EOL) и Windows 10 (тот же
    паттерн — свой ISO, свой os_type, те же usb_devices). Обе живут на
    одном физическом хосте параллельно (не одновременно запущенные —
    паравиртуальное видео тут не про конкурентный доступ к GPU, а про то,
    что ни одна из VM физическую 770M не трогает вообще), карта — не
    одиночный ресурс, именно под это.

    on_boot — автостарт VM при старте/ребуте самой ноды pve-rog. Только
                одна из двух VM должна иметь on_boot = true одновременно —
                Terraform это не проверяет (обе technically могут стоять
                true, тогда после ребута ноды поднимутся обе разом и будут
                драться за usb_devices/SPICE-порт хоста), контролируется
                вручную при правке дефолтов.
    iso_file_id  — ID ISO-образа в датасторе, формат
                  "<datastore>:iso/<файл>", например
                  "local:iso/ubuntu-26.04-desktop-amd64.iso". Образ
                  должен уже лежать в датасторе ДО apply — Terraform его
                  не качает и не заливает сам (scp/rsync в
                  /var/lib/vz/template/iso/ на хосте, или через веб-UI).
                  null = не подключать cdrom вообще.
    boot_from_iso — true, пока VM не установлена (грузится с ISO первым в
                  порядке). Переключи на false и сделай re-apply после
                  того, как ОС реально стоит на scsi0 — иначе случайный
                  ребут снова закинет тебя в установщик. Игнорируется,
                  если iso_file_id = null.
    os_type    — тип гостевой ОС для Proxmox (`operating_system.type`) —
                "l26" для Linux, "win10" для Windows 10/11-гостя. Влияет
                на дефолтные оптимизации QEMU (ACPI/HPET и т.п.), не
                декоративное поле.
    vga_type   — "qxl2" — SPICE, 2 виртуальные головы, программный рендер
                (см. корневой README/troubleshooting — virtio-gl оказался
                single-head в этой сборке QEMU). Для Windows тоже qxl2 —
                тот же SPICE-путь через desktop-kiosk-setup.sh, тестового
                RDP-конфига пока нет.
    vga_memory — VGA memory в MB. 64 — с запасом под 2D/desktop
                compositing, не под тяжёлые игры (для них план — GPU
                passthrough как toggle, отдельная история, не эта VM).
    usb_devices — список host-USB устройств для passthrough в формате
                "vendorid:productid" (смотреть через `ssh pve-rog
                lsusb`), например ["046d:c52b", "046d:0843"] под
                клавиатуру/мышь/веб-камеру. Обычный HID/UVC passthrough,
                никак не связан с GPU reset bug (тот — только про
                видеовыходы). Одни и те же ID можно смело держать в обеих
                записях — раз VM не работают одновременно, коллизии по
                факту нет; `qm set` просто пишет конфиг в обе, реально
                устройство подхватывает та, что запущена.
  EOT
  type = map(object({
    tag_name = string
    memory   = number
    cores    = number
    mac      = string

    proxmox_node      = optional(string)
    datastore_id_disk = optional(string, "local-lvm")
    disk_size         = optional(number, 64)
    os_type           = optional(string, "l26")
    vga_type          = optional(string, "qxl2")
    vga_memory        = optional(number, 64)
    iso_file_id       = optional(string, null)
    boot_from_iso     = optional(bool, true)
    on_boot           = optional(bool, false)
    usb_devices       = optional(list(string), [])
  }))
  default = {
    # usb_devices — по lsusb на pve-rog: webcam (13d3:5188), клавиатура
    # (0c45:5004), мышь (1532:0085). Осознанно НЕ включены:
    #   - bluetooth-адаптер (13d3:3362) — трогать не нужно, если он не
    #     используется гостем напрямую; штатно остаётся на хосте.
    #   - "USB Disk 2.0" (346d:5678) — физическая флешка, от неё
    #     отказались как от способа установки (SeaBIOS не смог с неё
    #     забутиться через scsi1 passthrough), теперь установка идёт
    #     через iso_file_id ниже, флешка вообще не используется.
    "ubuntu-workstation" = {
      tag_name      = "workstation",
      memory        = 8192,
      cores         = 4,
      vga_type      = "qxl2",
      mac           = "BC:24:11:9A:2C:71",
      iso_file_id   = "local:iso/ubuntu-26.04-desktop-amd64.iso",
      boot_from_iso = false,
      on_boot       = false,
      usb_devices   = ["13d3:5188", "0c45:5004", "08bb:2902", "046d:0825"]
    }
    "windows-workstation" = {
      tag_name      = "workstation-win",
      memory        = 8192,
      cores         = 4,
      os_type       = "win10",
      vga_type      = "qxl2",
      mac           = "BC:24:11:7F:3D:19",
      iso_file_id   = "local:iso/Win10_22H2_Russian_x64v1.iso",
      boot_from_iso = true,
      on_boot       = true,
      usb_devices   = ["13d3:5188", "0c45:5004", "08bb:2902", "046d:0825"]
    }
  }
}
