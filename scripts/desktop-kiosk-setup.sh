#!/bin/bash
#
# scripts/desktop-kiosk-setup.sh
#
# Запускать НА ХОСТЕ (pve-rog): ssh root@pve-rog 'bash -s' < scripts/desktop-kiosk-setup.sh
#
# Превращает сам хост в "тонкий клиент самому себе" для environments/workstation:
# минимальный X + openbox + автологин под отдельным непривилегированным
# пользователем + автозапуск remote-viewer на весь экран (spice), развёрнутый
# на два физических внешних монитора (DP-1 слева, VGA-1 справа). Встроенный
# экран ноута (LVDS-1) сознательно выключается в X — не используется вообще,
# рабочий стол только на внешних мониках. Гость по-прежнему рендерится
# через virtio-gl на host GPU (i915) — просто картинка теперь показывается
# локально, а не через браузер с другой машины.
#
# Причина именно такого пути, а не GPU passthrough физических видеовыходов —
# см. корневой README/обсуждение: Kepler reset bug без софтового фикса +
# драйвер 470.xxx официально EOL. USB-периферия (клавиатура/мышь/веб-камера)
# сюда не относится — та пробрасывается напрямую в VM через usb_devices
# (см. environments/workstation/variables.tf), никак не завязана на этот
# скрипт.
#
# Идемпотентно — безопасно перезапускать (проверяет пользователя/пакеты/
# конфиги перед созданием).

set -e

VMID="${VMID:-110}"
KIOSK_USER="${KIOSK_USER:-kiosk}"
VM_TITLE="${VM_TITLE:-Workstation}"
PROXMOX_NODE="${PROXMOX_NODE:-$(hostname)}"

# 1. Пакеты. xserver-xorg + openbox — минимальный X-сеанс без полноценного
#    DE (никакого gnome/kde — тут только окно remote-viewer на весь экран).
#    lightdm — автологин, а не голый startx: переживает краш X без ручного
#    вмешательства (systemd перезапускает сервис). sudo — нужен для
#    точечного доступа kiosk-пользователя к pvesh (см. ниже), в базовом
#    Proxmox-хосте не установлен по умолчанию. x11-xserver-utils — даёт
#    xrandr/xset, тоже не входит в базовый xserver-xorg. python3 — для
#    сборки .vv-файла из JSON-ответа pvesh (см. ниже, qm spiceproxy как
#    CLI-команды не существует, только API-эндпоинт).
if ! dpkg -l xserver-xorg &>/dev/null; then
    apt-get update -qq
    apt-get install -y xserver-xorg xinit openbox lightdm virt-viewer unclutter sudo x11-xserver-utils python3
fi

# 2. Пользователь-киоск — НЕ root, минимум прав, только на запуск X-сессии.
if ! id "${KIOSK_USER}" &>/dev/null; then
    useradd -m -s /bin/bash "${KIOSK_USER}"
fi

# kiosk — непривилегированный, но получение SPICE-тикета через pvesh
# требует root (Proxmox отдаёт "only root can..." на многие подобные
# вызовы даже с полноправным API-токеном — тот же нюанс, что и с usbN
# в Terraform). Даём точечный NOPASSWD только на этот конкретный вызов
# для этой конкретной VM — не на pvesh/qm целиком, чтобы не открывать
# пользователю управление другими VM/нодой.
echo "${KIOSK_USER} ALL=(root) NOPASSWD: /usr/bin/pvesh create /nodes/${PROXMOX_NODE}/qemu/${VMID}/spiceproxy*" > /etc/sudoers.d/kiosk-spiceproxy
chmod 440 /etc/sudoers.d/kiosk-spiceproxy

# 3. Автологин через lightdm — тот же паттерн выбора формата конфига, что
#    и остальной репозиторий уже проходил на Proxmox VE 9 (deb822 vs .list
#    для apt-репозиториев) — тут проще, просто конфиг lightdm.
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-kiosk-autologin.conf << EOF
[Seat:*]
autologin-user=${KIOSK_USER}
autologin-user-timeout=0
autologin-session=openbox
user-session=openbox
EOF

systemctl set-default graphical.target
systemctl enable lightdm

# 4. Openbox autostart — здесь вся логика: развернуть только два внешних
#    монитора (встроенный LVDS-1 выключен), погасить декорации/курсор,
#    держать DPMS включённым без автотаймаутов (гасим/включаем мониторы
#    вручную по факту состояния VM — см. цикл ниже, чтобы не светить
#    чёрным экраном, пока VM выключена), и в цикле держать remote-viewer
#    живым — если VM перезапустят или сессию закроют, переподключается
#    сам, без ручного вмешательства.
KIOSK_HOME=$(getent passwd "${KIOSK_USER}" | cut -d: -f6)
mkdir -p "${KIOSK_HOME}/.config/openbox"

cat > "${KIOSK_HOME}/.config/openbox/autostart" << EOF
# Встроенный экран (LVDS-1) сознательно выключен — используются только
# два внешних монитора, DP-1 слева, VGA-1 справа от него. Если физически
# переключишь порты/имена выходов другие — проверь актуальные через
# 'xrandr --query' под этим же пользователем и поправь имена ниже.
xrandr --output LVDS-1 --off --output DP-1 --auto --output VGA-1 --auto --right-of DP-1 &

unclutter --idle 1 &          # прятать курсор, когда не двигается — киоск, не десктоп с мышью хоста

# DPMS включён, но без автоматических таймаутов — гаснуть/включаться
# мониторы будут только по нашей команде (force on/off) в цикле ниже,
# синхронно с тем, доступна VM или нет, а не сами по себе.
xset s off
xset +dpms
xset dpms 0 0 0

while true; do
    # Тикет SPICE одноразовый/с ограниченным сроком — берём свежий перед
    # каждым (пере)подключением, а не один раз при старте сессии. qm
    # spiceproxy как CLI-команды не существует в этой версии Proxmox —
    # только API-эндпоинт через pvesh, отсюда сборка .vv-файла вручную.
    sudo /usr/bin/pvesh create /nodes/${PROXMOX_NODE}/qemu/${VMID}/spiceproxy --output-format json > /tmp/${VMID}.json 2>/tmp/${VMID}.vv.err
    if [ -s /tmp/${VMID}.json ]; then
        {
            echo "[virt-viewer]"
            python3 -c '
import json
with open("/tmp/${VMID}.json") as f:
    d = json.load(f)
for k, v in d.items():
    if k == "ca":
        v = str(v).replace("\n", "\\n")
    print(f"{k}={v}")
'
        } > /tmp/${VMID}.vv
    fi
    if [ -s /tmp/${VMID}.vv ]; then
        # VM доступна — тикет получен, будим мониторы перед подключением.
        xset dpms force on
        remote-viewer --full-screen=all --title="${VM_TITLE}" /tmp/${VMID}.vv
    else
        # VM выключена/недоступна — гасим мониторы вместо чёрного экрана
        # с висящим "тонким клиентом" без картинки.
        echo "\$(date): не удалось получить spice-тикет для VM ${VMID}, повтор через 10с" >> /tmp/kiosk-errors.log
        cat /tmp/${VMID}.vv.err >> /tmp/kiosk-errors.log
        xset dpms force off
    fi
    # remote-viewer завершился (VM выключена/перезагружается/ручной ребут
    # сессии) — короткая пауза и повтор, не спин-лупом.
    sleep 5
done
EOF

chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config"
chmod +x "${KIOSK_HOME}/.config/openbox/autostart"

echo "Kiosk-сессия настроена: пользователь ${KIOSK_USER}, VM ${VMID}."
echo "Проверь VMID/раскладку мониторов, затем: systemctl restart lightdm"
echo "(или просто ребутни pve-rog целиком, раз это его основной режим работы теперь)."
