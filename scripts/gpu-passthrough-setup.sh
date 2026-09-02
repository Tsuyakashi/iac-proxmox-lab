#!/bin/bash
#
# scripts/gpu-passthrough-setup.sh
#
# Запускать на хосте (ssh root@pve-rog 'bash -s' < scripts/gpu-passthrough-setup.sh).
# Одноразовая (но идемпотентная) настройка хоста под VFIO passthrough
# дискретной GPU (770M) в environments/workstation's windows-workstation.
#
# G750JX — Optimus-ноутбук: у 770M нет физического видеовыхода (все порты
# висят на встроенной Intel iGPU/i915, которую уже использует
# scripts/desktop-kiosk-setup.sh). Поэтому проброс делается в headless-
# режиме (без x-vga) — Windows использует карту как единственный настоящий
# видеоадаптер, но смотришь на неё через RDP, не через SPICE/консоль.
#
# ВАЖНО про Kepler reset bug (см. корневой README/troubleshooting.md,
# именно из-за него GPU passthrough изначально был отклонён для
# environments/workstation) — он никуда не делся: после выключения
# Windows-VM карта может не сброситься штатно, повторный qm start до
# следующего физического ребута хоста может не сработать. Осознанное
# решение — ребутить pve-rog руками между сессиями с GPU, не пытаться
# "хот-свапать" Windows/Ubuntu через одну эту карту без ребута.
#
# Requires: GPU_PCI_ID env var — bus:slot GPU (без .function, чтобы
# захватить сразу и видео, и HDMI-audio функции одним блоком), например:
#   GPU_PCI_ID=01:00 bash -s < scripts/gpu-passthrough-setup.sh
#
# Идемпотентно — безопасно перезапускать.

set -e

GPU_PCI_ID="${GPU_PCI_ID:?set GPU_PCI_ID (bus:slot, e.g. 01:00 — see 'lspci -nn | grep -i nvidia')}"

# 1. IOMMU в кернел-командлайне. Proxmox 9.x на UEFI обычно грузится через
#    systemd-boot (proxmox-boot-tool), но может быть и GRUB — проверяем оба.
IOMMU_PARAMS="intel_iommu=on iommu=pt"

if [ -f /etc/kernel/cmdline ]; then
    # systemd-boot / proxmox-boot-tool путь
    if ! grep -q "intel_iommu=on" /etc/kernel/cmdline; then
        echo "Добавляю IOMMU-параметры в /etc/kernel/cmdline (systemd-boot)..."
        sed -i "s/\$/ ${IOMMU_PARAMS}/" /etc/kernel/cmdline
        proxmox-boot-tool refresh
        NEED_REBOOT=1
    fi
elif [ -f /etc/default/grub ]; then
    # GRUB путь
    if ! grep -q "intel_iommu=on" /etc/default/grub; then
        echo "Добавляю IOMMU-параметры в /etc/default/grub..."
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${IOMMU_PARAMS} /" /etc/default/grub
        update-grub
        NEED_REBOOT=1
    fi
else
    echo "error: не нашёл ни /etc/kernel/cmdline, ни /etc/default/grub — разберись вручную с методом загрузки" >&2
    exit 1
fi

# 2. Блэклист nouveau — хост не должен трогать карту своим драйвером,
#    иначе vfio-pci не сможет её забрать.
if [ ! -f /etc/modprobe.d/blacklist-nouveau.conf ]; then
    echo "Блэклистю nouveau..."
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    NEED_REBOOT=1
fi

# 3. vfio-модули грузятся до графики (initramfs), карта биндится к
#    vfio-pci по PCI ID, а не по имени драйвера — так она гарантированно
#    достаётся vfio, а не nouveau/nvidia, независимо от порядка загрузки.
GPU_IDS=$(lspci -nn -s "${GPU_PCI_ID}" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | paste -sd, -)
if [ -z "${GPU_IDS}" ]; then
    echo "error: не нашёл устройства на ${GPU_PCI_ID} — проверь PCI-адрес (lspci -nn)" >&2
    exit 1
fi

if [ ! -f /etc/modprobe.d/vfio.conf ] || ! grep -q "${GPU_IDS}" /etc/modprobe.d/vfio.conf; then
    echo "Прописываю vfio-pci ids=${GPU_IDS}..."
    cat > /etc/modprobe.d/vfio.conf << EOF
options vfio-pci ids=${GPU_IDS}
EOF
    NEED_REBOOT=1
fi

if ! grep -q "^vfio$" /etc/modules 2>/dev/null; then
    cat >> /etc/modules << 'EOF'
vfio
vfio_iommu_type1
vfio_pci
EOF
    NEED_REBOOT=1
fi

if [ -n "${NEED_REBOOT:-}" ]; then
    update-initramfs -u -k all
fi

echo ""
echo "GPU: ${GPU_PCI_ID} (${GPU_IDS})"
echo ""
if [ -n "${NEED_REBOOT:-}" ]; then
    echo "Изменения внесены, нужен ПОЛНЫЙ РЕБУТ хоста (не qm/pct), чтобы:"
    echo "  - IOMMU реально включился"
    echo "  - карта досталась vfio-pci, а не nouveau, с самого старта"
    echo ""
    echo "После ребута проверь:"
    echo "  dmesg | grep -e DMAR -e IOMMU          # IOMMU включён"
    echo "  lspci -nnk -s ${GPU_PCI_ID}             # 'Kernel driver in use: vfio-pci'"
    echo ""
    echo "И обязательно проверь IOMMU-группу — если карта делит группу с"
    echo "чем-то ещё, кроме своей же HDMI-audio функции, passthrough не"
    echo "заработает без ACS override патча (отдельная история, не в этом скрипте):"
    echo "  for g in /sys/kernel/iommu_groups/*; do"
    echo "    echo \"IOMMU Group \${g##*/}:\""
    echo "    for d in \$g/devices/*; do lspci -nns \${d##*/}; done"
    echo "  done | grep -B1 -A1 -i nvidia"
else
    echo "Уже настроено, ребут не требуется."
fi
