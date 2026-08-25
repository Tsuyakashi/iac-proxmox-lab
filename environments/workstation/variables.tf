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
    физической флешки через scsi1-passthrough, virtio-gl вместо GPU
    passthrough — Kepler reset bug без софтового фикса + драйвер 470.xxx
    официально EOL, см. обсуждение в чате). Вторая запись (Windows-
    десктоп, своя флешка, та же virtio-gl-схема, свои usb_devices)
    добавится сюда же позже — карта, а не одиночный ресурс, специально
    под это: обе VM смогут жить параллельно, каждая со своим виртуальным
    дисплеем, без конкуренции за физическую GPU.

    installer_usb_device — путь к устройству флешки НА ХОСТЕ (pve-rog),
                           не в госте, например "/dev/sdb". Пробрасывается
                           целиком (не /dev/sdb1 — Proxmox отдаёт
                           устройство целиком, разделы не пробрасывает
                           отдельно, см. immich-node README "Known
                           limitations"). null = не пробрасывать
                           (для будущей VM, у которой ещё нет флешки).
    boot_from_installer  — true, пока VM не установлена (грузится с
                           флешки первым в порядке). Переключи на false и
                           сделай re-apply после того, как Ubuntu реально
                           стоит на scsi0 — иначе случайный ребут снова
                           закинет тебя в установщик. Игнорируется, если
                           installer_usb_device = null.
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
                никак не связан с флешкой-инсталлятором выше (та —
                блочное устройство, отдельный механизм) и никак не
                связан с GPU reset bug (тот — только про видеовыходы).
                Пустой список по умолчанию — ничего не пробрасывается,
                пока явно не перечислишь устройства.
  EOT
  type = map(object({
    tag_name = string
    memory   = number
    cores    = number
    mac      = string

    proxmox_node         = optional(string)
    datastore_id_disk    = optional(string, "local-lvm")
    disk_size            = optional(number, 64)
    vga_type             = optional(string, "virtio-gl")
    vga_memory           = optional(number, 64)
    installer_usb_device = optional(string, null)
    boot_from_installer  = optional(bool, true)
    usb_devices          = optional(list(string), [])
  }))
  default = {
    # usb_devices — по lsusb на pve-rog: webcam (13d3:5188), клавиатура
    # (0c45:5004), мышь (1532:0085). Осознанно НЕ включены:
    #   - bluetooth-адаптер (13d3:3362) — трогать не нужно, если он не
    #     используется гостем напрямую; штатно остаётся на хосте.
    #   - "USB Disk 2.0" (346d:5678) — это и есть флешка-инсталлятор,
    #     она уже пробрасывается отдельно через installer_usb_device
    #     (блочное устройство, scsi1), добавлять её же в usb_devices
    #     нельзя — это два разных механизма проброса одного и того же
    #     физического устройства, будет конфликт.
    "ubuntu-workstation" = {
      tag_name             = "workstation",
      memory               = 8192,
      cores                = 4,
      mac                  = "BC:24:11:9A:2C:71",
      installer_usb_device = "/dev/sdb",
      usb_devices          = ["13d3:5188", "0c45:5004", "1532:0085"]
    }
  }
}
