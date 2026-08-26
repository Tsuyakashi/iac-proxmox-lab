variable "proxmox_endpoint" {
  type = string
}

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
    Desktop VM topology. Одна запись сейчас (Ubuntu Desktop, установка с
    ISO через виртуальный cdrom, virtio-gl вместо GPU passthrough — Kepler
    reset bug без софтового фикса + драйвер 470.xxx официально EOL, см.
    обсуждение в чате). Вторая запись (Windows-десктоп, свой ISO, та же
    virtio-gl-схема, свои usb_devices) добавится сюда же позже — карта, а
    не одиночный ресурс, специально под это: обе VM смогут жить
    параллельно, каждая со своим виртуальным дисплеем, без конкуренции за
    физическую GPU.

    iso_file_id  — ID ISO-образа в датасторе, формат
                  "<datastore>:iso/<файл>", например
                  "local:iso/ubuntu-26.04-desktop-amd64.iso". Образ
                  должен уже лежать в датасторе ДО apply — Terraform его
                  не качает и не заливает сам (scp/rsync в
                  /var/lib/vz/template/iso/ на хосте, или через веб-UI).
                  null = не подключать cdrom вообще.
    boot_from_iso — true, пока VM не установлена (грузится с ISO первым в
                  порядке). Переключи на false и сделай re-apply после
                  того, как Ubuntu реально стоит на scsi0 — иначе
                  случайный ребут снова закинет тебя в установщик.
                  Игнорируется, если iso_file_id = null.
    vga_type   — "virtio-gl" даёт частичное 3D-ускорение через host GPU
                (Venus/virgl, через встроенный i915 на pve-rog, не через
                770M) — достаточно для 2D/казуальных игр.
    vga_memory — VGA memory в MB для virtio-gl. 64 — с запасом под
                2D/desktop compositing, не под тяжёлые игры (для них
                план — GPU passthrough как toggle, отдельная история, не
                эта VM).
    usb_devices — список host-USB устройств для passthrough в формате
                "vendorid:productid" (смотреть через `ssh pve-rog
                lsusb`), например ["046d:c52b", "046d:0843"] под
                клавиатуру/мышь/веб-камеру. Обычный HID/UVC passthrough,
                никак не связан с GPU reset bug (тот — только про
                видеовыходы). Пустой список по умолчанию — ничего не
                пробрасывается, пока явно не перечислишь устройства.
  EOT
  type = map(object({
    tag_name = string
    memory   = number
    cores    = number
    mac      = string

    proxmox_node      = optional(string)
    datastore_id_disk = optional(string, "local-lvm")
    disk_size         = optional(number, 64)
    vga_type          = optional(string, "qxl2")
    vga_memory        = optional(number, 64)
    iso_file_id       = optional(string, null)
    boot_from_iso     = optional(bool, true)
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
      usb_devices   = ["13d3:5188", "0c45:5004", "08bb:2902", "046d:0825"]
    }
  }
}
