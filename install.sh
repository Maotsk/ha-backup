#!/bin/bash
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/Maotsk/ha-backup/main/ha-backup.sh"
INSTALL_PATH="/usr/local/bin/ha-backup.sh"

SERVICE_PATH="/etc/systemd/system/ha-backup.service"
TIMER_PATH="/etc/systemd/system/ha-backup.timer"

CONF_PATH="/root/.ha-backup.conf"
CREDENTIALS_PATH="/root/.smbcredentials"

echo "========================================"
echo " Home Assistant Backup Installer"
echo "========================================"

# =========================================================
# Проверка root
# =========================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ОШИБКА: install.sh необходимо запускать от root." >&2
    exit 1
fi

# =========================================================
# Установка необходимых пакетов
# =========================================================

echo
echo "[1/7] Проверка необходимых пакетов..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    rsync \
    cifs-utils \
    curl \
    findutils \
    util-linux

# =========================================================
# Установка ha-backup.sh
# =========================================================

echo
echo "[2/7] Установка ha-backup.sh..."

TMP_SCRIPT=$(mktemp)

trap 'rm -f "$TMP_SCRIPT"' EXIT

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    "$SCRIPT_URL" \
    -o "$TMP_SCRIPT"

install \
    -o root \
    -g root \
    -m 0755 \
    "$TMP_SCRIPT" \
    "$INSTALL_PATH"

echo "Установлен:"
echo "$INSTALL_PATH"

# =========================================================
# Конфигурация
# =========================================================

echo
echo "[3/7] Проверка конфигурации..."

if [ ! -f "$CONF_PATH" ]; then

    cat > "$CONF_PATH" <<'EOF'
# =========================================================
# Home Assistant Backup configuration
# =========================================================

# ---------------------------------------------------------
# TrueNAS
# ---------------------------------------------------------

MOUNTPOINT="/mnt/truenas"
DEST="/mnt/truenas/home-assistant"

# ---------------------------------------------------------
# Логи
# ---------------------------------------------------------

LOGDIR="/var/log/ha-backup"
LOG_RETENTION_DAYS=7

# ---------------------------------------------------------
# Rsync
# ---------------------------------------------------------

# 0 = без ограничения скорости
BW_LIMIT=0

# ---------------------------------------------------------
# Telegram
# ---------------------------------------------------------

TG_TOKEN=""
TG_CHAT_ID=""

# SOCKS5 / HTTP proxy.
# Оставить пустым, если proxy не нужен.
TG_PROXY=""

TG_NOTIFY_SUCCESS="true"
TG_NOTIFY_ERROR="true"

TG_SILENT_SUCCESS="true"
TG_SILENT_ERROR="false"

# ---------------------------------------------------------
# Задачи
#
# Формат:
#
# "SOURCE|DESTINATION|EXCLUDES|DELETE"
#
# DELETE:
#   yes = использовать rsync --delete
#   no  = не удалять файлы назначения
# ---------------------------------------------------------

JOBS=(
    "/ha|backup/home-assistant||yes"
    "/root/.ha-backup.conf|backup/scripts/||no"
    "/root/.smbcredentials|backup/scripts/||no"
)
EOF

    chmod 600 "$CONF_PATH"

    echo "Создан:"
    echo "$CONF_PATH"

else

    chmod 600 "$CONF_PATH"

    echo "Конфигурация уже существует:"
    echo "$CONF_PATH"

fi

# =========================================================
# SMB credentials
# =========================================================

echo
echo "[4/7] Проверка SMB credentials..."

if [ -f "$CREDENTIALS_PATH" ]; then
    chmod 600 "$CREDENTIALS_PATH"
    chown root:root "$CREDENTIALS_PATH"

    echo "Credentials найдены:"
    echo "$CREDENTIALS_PATH"
else
    echo "ВНИМАНИЕ: $CREDENTIALS_PATH не найден."
    echo "Если CIFS требует авторизацию — создайте его перед запуском."
fi

# =========================================================
# Каталог логов
# =========================================================

echo
echo "[5/7] Создание каталога логов..."

mkdir -p "/var/log/ha-backup"

chmod 750 "/var/log/ha-backup"

chown root:root "/var/log/ha-backup"

# =========================================================
# systemd service
# =========================================================

echo
echo "[6/7] Создание systemd service..."

cat > "$SERVICE_PATH" <<'EOF'
[Unit]
Description=Home Assistant Backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ha-backup.sh

User=root
Group=root

# Немного дополнительной защиты systemd
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# =========================================================
# systemd timer
# =========================================================

cat > "$TIMER_PATH" <<'EOF'
[Unit]
Description=Home Assistant Backup Timer

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

RandomizedDelaySec=5min

Unit=ha-backup.service

[Install]
WantedBy=timers.target
EOF

# =========================================================
# Запуск systemd
# =========================================================

systemctl daemon-reload

systemctl enable --now ha-backup.timer

# =========================================================
# Проверка
# =========================================================

echo
echo "[7/7] Проверка установки..."

echo
echo "----------------------------------------"
echo "ha-backup:"
ls -l "$INSTALL_PATH"

echo
echo "systemd timer:"
systemctl status ha-backup.timer --no-pager || true

echo
echo "Следующий запуск:"
systemctl list-timers ha-backup.timer --no-pager || true

echo
echo "========================================"
echo " Установка завершена"
echo "========================================"

echo
echo "Конфигурация:"
echo "  $CONF_PATH"

echo
echo "Скрипт:"
echo "  $INSTALL_PATH"

echo
echo "Ручной запуск:"
echo "  systemctl start ha-backup.service"

echo
echo "Просмотр лога:"
echo "  journalctl -u ha-backup.service"

echo
echo "Лог backup:"
echo "  /var/log/ha-backup/"

exit 0
