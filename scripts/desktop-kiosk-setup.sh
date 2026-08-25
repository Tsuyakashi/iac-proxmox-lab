#!/bin/bash
#
# scripts/desktop-kiosk-setup.sh
#
# Запускать НА ХОСТЕ (pve-rog): ssh root@pve-rog 'bash -s' < scripts/desktop-kiosk-setup.sh
#
# Превращает сам хост в "тонкий клиент самому себе" для environments/workstation:
# минимальный X + openbox + автологин под отдельным непривилегированным
# пользователем + автозапуск remote-viewer на весь экран (spice), развёрнутый
# на все физически подключённые к хосту мониторы. Гость по-прежнему
# рендерится через virtio-gl на host GPU (i915) — просто картинка теперь
# показывается локально на мониторах, воткнутых в ноут, а не через браузер
# с другой машины.
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

VMID="${VMID:-100}"
KIOSK_USER="${KIOSK_USER:-kiosk}"
VM_TITLE="${VM_TITLE:-Workstation}"

# 1. Пакеты. xserver-xorg + openbox — минимальный X-сеанс без полноценного
#    DE (никакого gnome/kde — тут только окно remote-viewer на весь экран).
#    lightdm — автологин, а не голый startx: переживает краш X без ручного
#    вмешательства (systemd перезапускает сервис).
if ! dpkg -l xserver-xorg &>/dev/null; then
    apt-get update -qq
    apt-get install -y xserver-xorg xinit openbox lightdm virt-viewer unclutter
fi

# 2. Пользователь-киоск — НЕ root, минимум прав, только на запуск X-сессии.
if ! id "${KIOSK_USER}" &>/dev/null; then
    useradd -m -s /bin/bash "${KIOSK_USER}"
fi

# kiosk — непривилегированный, но qm spiceproxy требует root. Даём точечный
# NOPASSWD только на этот конкретный вызов для этой конкретной VM — не на
# qm целиком, чтобы не открывать пользователю управление другими VM/нодой.
echo "${KIOSK_USER} ALL=(root) NOPASSWD: /usr/sbin/qm spiceproxy ${VMID}" > /etc/sudoers.d/kiosk-spiceproxy
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

# 4. Openbox autostart — здесь вся логика: развернуть мониторы, погасить
#    декорации/курсор, задизейблить screen blanking (иначе экран уснёт
#    посреди "рабочего дня" на десктопе), и в цикле держать remote-viewer
#    живым — если VM перезапустят или сессию закроют, переподключается
#    сам, без ручного вмешательства.
KIOSK_HOME=$(getent passwd "${KIOSK_USER}" | cut -d: -f6)
mkdir -p "${KIOSK_HOME}/.config/openbox"

cat > "${KIOSK_HOME}/.config/openbox/autostart" << EOF
# xrandr --auto включает все физически подключённые выходы на их
# нативном разрешении бок о бок слева направо — обычно этого достаточно
# для "два монитора рядом". Если раскладка не та (не тот порядок,
# зеркалирование вместо расширения) — поправь руками через
# --left-of/--right-of, актуальные имена выходов смотри через
# 'xrandr --query' под этим же пользователем.
xrandr --auto &

unclutter --idle 1 &          # прятать курсор, когда не двигается — киоск, не десктоп с мышью хоста
xset s off -dpms               # не гасить экран — это "постоянно включённый" ПК, не ноут на батарейке

while true; do
    # Тикет SPICE одноразовый/с ограниченным сроком — берём свежий перед
    # каждым (пере)подключением, а не один раз при старте сессии.
    sudo /usr/sbin/qm spiceproxy ${VMID} > /tmp/${VMID}.vv 2>/tmp/${VMID}.vv.err
    if [ -s /tmp/${VMID}.vv ]; then
        remote-viewer --full-screen --title="${VM_TITLE}" /tmp/${VMID}.vv
    else
        echo "\$(date): не удалось получить spice-тикет для VM ${VMID}, повтор через 10с" >> /tmp/kiosk-errors.log
        cat /tmp/${VMID}.vv.err >> /tmp/kiosk-errors.log
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
