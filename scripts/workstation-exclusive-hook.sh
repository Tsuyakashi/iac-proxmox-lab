#!/bin/sh
#
# scripts/workstation-exclusive-hook.sh
#
# Proxmox hookscript (см. `man qm` -> hookscript). Вызывается Proxmox'ом
# как `<script> <vmid> <phase>` при любом изменении состояния VM — не
# только через `qm start`, но и через веб-UI, API, автостарт при ребуте
# хоста. На фазе pre-start проверяет остальные VM на этой же ноде с тем
# же тегом ("ws-exclusive") — если хоть одна уже running, выходит с
# ненулевым кодом, что Proxmox читает как отказ стартовать VM.
#
# Загружается в датастор Terraform'ом как snippet (см.
# environments/workstation/main.tf, proxmox_virtual_environment_file) и
# подключается к обеим VM через hook_script_file_id. Файл общий на обе
# VM — сам себя (OWN_VMID) скрипт исключает из проверки, поэтому одного
# и того же скрипта достаточно для всей exclusive-группы.
#
# Использует только `qm` (без jq/python3) — доступен на голом Proxmox-
# хосте сразу после установки, ничего дополнительно ставить не нужно.

OWN_VMID="$1"
PHASE="$2"
TAG="ws-exclusive"

[ "$PHASE" = "pre-start" ] || exit 0

for vid in $(qm list | awk 'NR>1{print $1}'); do
    [ "$vid" = "$OWN_VMID" ] && continue

    if qm config "$vid" 2>/dev/null | grep -q "^tags:.*${TAG}"; then
        status=$(qm status "$vid" 2>/dev/null | awk '{print $2}')
        if [ "$status" = "running" ]; then
            echo "workstation-exclusive-hook: VM ${vid} (тег ${TAG}) уже запущена — сначала останови её (qm shutdown ${vid}), потом запускай ${OWN_VMID}" >&2
            exit 1
        fi
    fi
done

exit 0
