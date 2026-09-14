#!/bin/bash
set -euo pipefail

# =========================================================
# Home Assistant Backup Installer
# Version: 1.0.0
# =========================================================

REPO="Maotsk/ha-backup"
REF="${HA_BACKUP_REF:-v1.0.0}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"

INSTALL_PATH="/root/ha-backup.sh"

CONF_PATH="/root/.ha-backup.conf"
CONF_EXAMPLE_PATH="/root/.ha-backup.conf.example"
CREDENTIALS_PATH="/root/.smbcredentials"

SERVICE_PATH="/etc/systemd/system/ha-backup.service"
TIMER_PATH="/etc/systemd/system/ha-backup.timer"

echo "========================================"
echo " Home Assistant Backup Installer"
echo " Version: ${REF}"
echo "========================================"

# =========================================================
# Проверка root
# =========================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ОШИБКА: install.sh необходимо запускать от root." >&2
    exit 1
fi

# =========================================================
# Проверка зависимостей
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
# Временные файлы
# =========================================================

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# =========================================================
# Загрузка файлов из репозитория
# =========================================================

echo
echo "[2/7] Загрузка файлов версии ${REF}..."

download_file() {
    local url="$1"
    local destination="$2"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        --retry-delay 2 \
        "$url" \
        -o "$destination"
}

download_file \
    "${RAW_BASE}/ha-backup.sh" \
    "${TMP_DIR}/ha-backup.sh"

download_file \
    "${RAW_BASE}/.ha-backup.conf.example" \
    "${TMP_DIR}/.ha-backup.conf.example"

download_file \
    "${RAW_BASE}/ha-backup.service" \
    "${TMP_DIR}/ha-backup.service"

download_file \
    "${RAW_BASE}/ha-backup.timer" \
    "${TMP_DIR}/ha-backup.timer"

# =========================================================
# Проверка загруженного скрипта
# =========================================================

echo
echo "[3/7] Проверка ha-backup.sh..."

bash -n "${TMP_DIR}/ha-backup.sh"

install \
    -o root \
    -g root \
    -m 0755 \
    "${TMP_DIR}/ha-backup.sh" \
    "$INSTALL_PATH"

echo "Установлен:"
echo "  $INSTALL_PATH"

# =========================================================
# Конфигурация
# =========================================================

echo
echo "[4/7] Проверка конфигурации..."

if [ ! -f "$CONF_PATH" ]; then

    install \
        -o root \
        -g root \
        -m 0600 \
        "${TMP_DIR}/.ha-backup.conf.example" \
        "$CONF_PATH"

    echo "Создан новый конфиг:"
    echo "  $CONF_PATH"

else

    chmod 600 "$CONF_PATH"
    chown root:root "$CONF_PATH"

    echo "Существующий конфиг НЕ изменён:"
    echo "  $CONF_PATH"
fi

# Сохраняем example отдельно для справки.
install \
    -o root \
    -g root \
    -m 0644 \
    "${TMP_DIR}/.ha-backup.conf.example" \
    "$CONF_EXAMPLE_PATH"

echo "Example-конфиг:"
echo "  $CONF_EXAMPLE_PATH"

# =========================================================
# SMB credentials
# =========================================================

echo
echo "[5/7] Проверка SMB credentials..."

if [ -f "$CREDENTIALS_PATH" ]; then

    chmod 600 "$CREDENTIALS_PATH"
    chown root:root "$CREDENTIALS_PATH"

    echo "Credentials найдены:"
    echo "  $CREDENTIALS_PATH"

else

    echo "ВНИМАНИЕ:"
    echo "  $CREDENTIALS_PATH не найден."

    echo
    echo "Если CIFS использует авторизацию,"
    echo "создайте credentials перед запуском backup."

fi

# =========================================================
# Каталог логов
# =========================================================

LOGDIR="/var/log.hdd/ha"

echo
echo "Создание каталога логов:"
echo "  $LOGDIR"

mkdir -p "$LOGDIR"

chmod 750 "$LOGDIR"
chown root:root "$LOGDIR"

# =========================================================
# systemd service
# =========================================================

echo
echo "[6/7] Установка systemd service..."

install \
    -o root \
    -g root \
    -m 0644 \
    "${TMP_DIR}/ha-backup.service" \
    "$SERVICE_PATH"

echo "Установлен:"
echo "  $SERVICE_PATH"

# =========================================================
# systemd timer
# =========================================================

install \
    -o root \
    -g root \
    -m 0644 \
    "${TMP_DIR}/ha-backup.timer" \
    "$TIMER_PATH"

echo "Установлен:"
echo "  $TIMER_PATH"

# =========================================================
# systemd
# =========================================================

echo
echo "[7/7] Настройка systemd..."

systemctl daemon-reload

systemctl enable ha-backup.timer

systemctl restart ha-backup.timer

# =========================================================
# Проверка
# =========================================================

echo
echo "========================================"
echo " Проверка установки"
echo "========================================"

echo
echo "ha-backup:"
ls -l "$INSTALL_PATH"

echo
echo "Конфигурация:"
ls -l "$CONF_PATH"

echo
echo "Service:"
systemctl cat ha-backup.service --no-pager

echo
echo "Timer:"
systemctl cat ha-backup.timer --no-pager

echo
echo "Статус timer:"
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
echo "Проверка лога:"
echo "  journalctl -u ha-backup.service"

echo
echo "Логи backup:"
echo "  $LOGDIR"

exit 0
