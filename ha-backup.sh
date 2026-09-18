#!/bin/bash
set -euo pipefail

# =========================================================
# Home Assistant Backup Installer
# =========================================================

DEFAULT_INSTALL_DIR="/root"
DEFAULT_CONF_DIR="/root"
DEFAULT_LOG_DIR="/var/log.hdd/ha"

# =========================================================
# Разбор аргументов
# =========================================================

INSTALL_DIR="${HA_BACKUP_DIR:-$DEFAULT_INSTALL_DIR}"
CONF_DIR="${HA_BACKUP_CONF_DIR:-$DEFAULT_CONF_DIR}"
LOG_DIR="${HA_BACKUP_LOG_DIR:-$DEFAULT_LOG_DIR}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --conf-dir)
            CONF_DIR="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --help|-h)
            cat <<EOF
Использование: sudo bash install.sh [опции]

Опции:
  --dir PATH        Директория для ha-backup.sh (по умолчанию: /root)
  --conf-dir PATH   Директория для .ha-backup.conf (по умолчанию: /root)
  --log-dir PATH    Директория для логов (по умолчанию: /var/log.hdd/ha)
  --help            Показать эту справку

Переменные окружения:
  HA_BACKUP_REF        Версия (v1.0.1, main)
  HA_BACKUP_DIR        То же, что --dir
  HA_BACKUP_CONF_DIR   То же, что --conf-dir
  HA_BACKUP_LOG_DIR    То же, что --log-dir

Примеры:
  sudo bash install.sh
  sudo bash install.sh --dir /opt/ha-backup --conf-dir /opt/ha-backup
  HA_BACKUP_DIR=/opt/ha-backup sudo -E bash install.sh
EOF
            exit 0
            ;;
        *)
            echo "ОШИБКА: неизвестный аргумент: $1" >&2
            echo "Используйте --help для справки." >&2
            exit 1
            ;;
    esac
done

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
    util-linux \
    coreutils

# =========================================================
# Определение версии
# =========================================================

REPO="Maotsk/ha-backup"

REF="${HA_BACKUP_REF:-}"

if [ -z "$REF" ]; then
    echo
    echo "Определяю последнюю версию..."

    LATEST_URL=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
                 "https://github.com/${REPO}/releases/latest" \
                 2>/dev/null || true)

    if [[ "$LATEST_URL" == *"/tag/"* ]]; then
        REF="${LATEST_URL##*/tag/}"
    else
        echo "ВНИМАНИЕ: не удалось определить последнюю версию." >&2
        echo "Использую fallback: v1.0.0" >&2
        REF="v1.0.0"
    fi
fi

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"

# =========================================================
# Проверка/создание директорий
# =========================================================

echo
echo "Директория скрипта:   ${INSTALL_DIR}"
echo "Директория конфига:   ${CONF_DIR}"
echo "Директория логов:     ${LOG_DIR}"

for dir in "$INSTALL_DIR" "$CONF_DIR" "$LOG_DIR"; do
    if [ ! -d "$dir" ]; then
        echo "Создаю директорию: $dir"
        mkdir -p "$dir"
    fi

    if [ ! -w "$dir" ]; then
        echo "ОШИБКА: нет прав на запись в $dir" >&2
        exit 1
    fi
done

INSTALL_PATH="${INSTALL_DIR}/ha-backup.sh"
CONF_PATH="${CONF_DIR}/.ha-backup.conf"
CONF_EXAMPLE_PATH="${CONF_DIR}/.ha-backup.conf.example"
CREDENTIALS_PATH="${CONF_DIR}/.smbcredentials"

SERVICE_PATH="/etc/systemd/system/ha-backup.service"
TIMER_PATH="/etc/systemd/system/ha-backup.timer"

echo "========================================"
echo " Home Assistant Backup Installer"
echo " Version: ${REF}"
echo "========================================"

# =========================================================
# Проверка доступности версии
# =========================================================

if ! curl --fail --silent --show-error --location --range 0-0 \
        "${RAW_BASE}/ha-backup.sh" > /dev/null 2>&1; then
    echo "ОШИБКА: версия ${REF} недоступна" >&2
    echo "Проверьте теги: https://github.com/${REPO}/tags" >&2
    exit 1
fi

echo "Версия ${REF} доступна, продолжаю..."

# =========================================================
# Временные файлы
# =========================================================

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# =========================================================
# Загрузка
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

download_file "${RAW_BASE}/ha-backup.sh"             "${TMP_DIR}/ha-backup.sh"
download_file "${RAW_BASE}/.ha-backup.conf.example"  "${TMP_DIR}/.ha-backup.conf.example"
download_file "${RAW_BASE}/ha-backup.service"        "${TMP_DIR}/ha-backup.service"
download_file "${RAW_BASE}/ha-backup.timer"          "${TMP_DIR}/ha-backup.timer"

# =========================================================
# Установка скрипта
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

echo
echo "Каталог логов:"
echo "  $LOG_DIR"

chmod 755 "$LOG_DIR"
chown root:root "$LOG_DIR"

# =========================================================
# systemd service
# =========================================================

echo
echo "[6/7] Установка systemd service..."

sed \
    -e "s|^ExecStart=.*|ExecStart=${INSTALL_PATH}|" \
    -e "s|^Environment=HA_BACKUP_CONF=.*|Environment=HA_BACKUP_CONF=${CONF_PATH}|" \
    -e "s|^Environment=HA_BACKUP_LOG_DIR=.*|Environment=HA_BACKUP_LOG_DIR=${LOG_DIR}|" \
    "${TMP_DIR}/ha-backup.service" \
    > "${TMP_DIR}/ha-backup.service.patched"

install \
    -o root \
    -g root \
    -m 0644 \
    "${TMP_DIR}/ha-backup.service.patched" \
    "$SERVICE_PATH"

echo "Установлен:"
echo "  $SERVICE_PATH"
echo "  ExecStart=${INSTALL_PATH}"
echo "  HA_BACKUP_CONF=${CONF_PATH}"
echo "  HA_BACKUP_LOG_DIR=${LOG_DIR}"

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

systemctl enable --now ha-backup.timer

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
systemctl status ha-backup.service --no-pager | head -5 || true

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
echo "  $LOG_DIR"

exit 0
