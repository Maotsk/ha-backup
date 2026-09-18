#!/bin/bash
set -euo pipefail

# =========================================================
# Home Assistant Backup Installer
# =========================================================
#
# Установщик ставит файлы в директорию, где лежит сам.
# Логи всегда в /var/log.hdd/ha.
#
# Если GitHub недоступен напрямую — скрипт пробует зеркала.
# Можно задать своё:
#   HA_BACKUP_MIRROR=https://gh-proxy.com/https://raw.githubusercontent.com \
#       sudo -E bash install.sh
# =========================================================

LOG_DIR="/var/log.hdd/ha"
REPO="Maotsk/ha-backup"

# Пользовательское зеркало (опционально)
GITHUB_MIRROR="${HA_BACKUP_MIRROR:-}"

# Список зеркал для raw-файлов
# prefix-тип: полный URL до raw.githubusercontent.com
MIRROR_RAW_CANDIDATES=(
    "https://raw.githubusercontent.com"
    "https://gh-proxy.com/https://raw.githubusercontent.com"
    "https://ghproxy.net/https://raw.githubusercontent.com"
    "https://cdn.jsdelivr.net/gh"
)

# =========================================================
# Проверка root
# =========================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ОШИБКА: install.sh необходимо запускать от root." >&2
    exit 1
fi

# =========================================================
# Определение директорий
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_DIR="$SCRIPT_DIR"
CONF_DIR="$SCRIPT_DIR"

INSTALL_PATH="${INSTALL_DIR}/ha-backup.sh"
CONF_PATH="${CONF_DIR}/.ha-backup.conf"
CONF_EXAMPLE_PATH="${CONF_DIR}/.ha-backup.conf.example"
CREDENTIALS_PATH="${CONF_DIR}/.smbcredentials"

SERVICE_PATH="/etc/systemd/system/ha-backup.service"
TIMER_PATH="/etc/systemd/system/ha-backup.timer"

# =========================================================
# Информация
# =========================================================

echo "========================================"
echo " Home Assistant Backup Installer"
echo "========================================"
echo
echo "Установка в:"
echo "  Скрипт:   ${INSTALL_PATH}"
echo "  Конфиг:   ${CONF_PATH}"
echo "  Логи:     ${LOG_DIR}/"
echo
echo "Структура на шаре TrueNAS:"
echo "  backup/ha/            — данные Home Assistant"
echo "  backup/docker-config/ — docker-compose.yaml"
echo "  backup/scripts/       — скрипт и конфиг"
echo "  backup/system/        — fstab"
echo
echo "Расписание: ежедневно в 04:00 (со случайной задержкой до 5 мин)"
echo

read -r -p "Продолжить установку? [y/N]: " CONFIRM

case "$CONFIRM" in
    [yY]|[yY][eE][sS]) echo "Продолжаю..." ;;
    *) echo "Отменено пользователем."; exit 0 ;;
esac

# =========================================================
# Проверка зависимостей
# =========================================================

echo
echo "[1/7] Проверка необходимых пакетов..."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    rsync cifs-utils curl findutils util-linux coreutils

# =========================================================
# Определение версии
# =========================================================

echo
echo "[2/7] Определение версии..."

REF="${HA_BACKUP_REF:-}"

if [ -z "$REF" ]; then
    # Пробуем api.github.com (надёжнее всего)
    LATEST_TAG=$(curl -fsSL --max-time 15 \
                 "https://api.github.com/repos/${REPO}/releases/latest" \
                 2>/dev/null \
                 | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
                 | head -1 \
                 | cut -d'"' -f4 || true)

    if [ -n "$LATEST_TAG" ]; then
        REF="$LATEST_TAG"
    else
        echo "ВНИМАНИЕ: не удалось определить последнюю версию через API." >&2
        echo "Использую fallback: v1.0.0" >&2
        REF="v1.0.0"
    fi
fi

echo "Версия: ${REF}"

# =========================================================
# Выбор зеркала для raw-файлов
# =========================================================

echo
echo "[3/7] Проверка доступности GitHub..."

# Проверка зеркала — читает первые 1 байт README
check_raw_mirror() {
    local base="$1"
    local test_url="${base}/${REPO}/${REF}/README.md"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --max-time 10 \
        --range 0-0 \
        "$test_url" > /dev/null 2>&1
}

MIRROR_RAW=""

# Если пользователь задал своё зеркало — пробуем в первую очередь
if [ -n "$GITHUB_MIRROR" ]; then
    echo "Пробую своё зеркало: ${GITHUB_MIRROR}"
    if check_raw_mirror "$GITHUB_MIRROR"; then
        MIRROR_RAW="$GITHUB_MIRROR"
        echo "  ✅ доступно"
    else
        echo "  ✗ не отвечает"
    fi
fi

# Если не задано или не сработало — пробуем стандартные
if [ -z "$MIRROR_RAW" ]; then
    for base in "${MIRROR_RAW_CANDIDATES[@]}"; do
        echo "  пробую: ${base}"
        if check_raw_mirror "$base"; then
            MIRROR_RAW="$base"
            echo "  ✅ доступно"
            break
        else
            echo "  ✗ не отвечает"
        fi
    done
fi

if [ -z "$MIRROR_RAW" ]; then
    echo
    echo "ОШИБКА: не удалось найти рабочее зеркало." >&2
    echo
    echo "Варианты решения:" >&2
    echo "  1. Задать своё зеркало:" >&2
    echo "     HA_BACKUP_MIRROR=https://gh-proxy.com/https://raw.githubusercontent.com \\" >&2
    echo "         sudo -E bash install.sh" >&2
    echo
    echo "  2. Использовать прокси:" >&2
    echo "     export https_proxy=socks5h://127.0.0.1:1080" >&2
    echo "     sudo -E bash install.sh" >&2
    exit 1
fi

RAW_BASE="${MIRROR_RAW}/${REPO}/${REF}"
echo "Использую: ${MIRROR_RAW}"

# =========================================================
# Проверка/создание директорий
# =========================================================

for dir in "$INSTALL_DIR" "$CONF_DIR" "$LOG_DIR"; do
    [ -d "$dir" ] || mkdir -p "$dir"
    [ -w "$dir" ] || { echo "ОШИБКА: нет прав на запись в $dir" >&2; exit 1; }
done

# =========================================================
# Временные файлы
# =========================================================

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# =========================================================
# Загрузка
# =========================================================

echo
echo "[4/7] Загрузка файлов версии ${REF}..."

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
        --max-time 60 \
        "$url" -o "$destination"
}

download_file "${RAW_BASE}/ha-backup.sh"             "${TMP_DIR}/ha-backup.sh"
download_file "${RAW_BASE}/.ha-backup.conf.example"  "${TMP_DIR}/.ha-backup.conf.example"
download_file "${RAW_BASE}/ha-backup.service"        "${TMP_DIR}/ha-backup.service"
download_file "${RAW_BASE}/ha-backup.timer"          "${TMP_DIR}/ha-backup.timer"

# =========================================================
# Установка скрипта
# =========================================================

echo
echo "[5/7] Проверка и установка ha-backup.sh..."

bash -n "${TMP_DIR}/ha-backup.sh"

install -o root -g root -m 0755 \
    "${TMP_DIR}/ha-backup.sh" "$INSTALL_PATH"
echo "Установлен: $INSTALL_PATH"

# =========================================================
# Конфигурация
# =========================================================

if [ ! -f "$CONF_PATH" ]; then
    sed \
        -e "s|INSTALL_PATH|${INSTALL_PATH}|g" \
        -e "s|CONF_PATH|${CONF_PATH}|g" \
        -e "s|LOGDIR=\"/var/log.hdd/ha\"|LOGDIR=\"${LOG_DIR}\"|" \
        "${TMP_DIR}/.ha-backup.conf.example" \
        > "${TMP_DIR}/.ha-backup.conf.patched"

    install -o root -g root -m 0600 \
        "${TMP_DIR}/.ha-backup.conf.patched" "$CONF_PATH"
    echo "Создан конфиг: $CONF_PATH"
else
    chmod 600 "$CONF_PATH"
    chown root:root "$CONF_PATH"
    echo "Существующий конфиг НЕ изменён: $CONF_PATH"
fi

install -o root -g root -m 0644 \
    "${TMP_DIR}/.ha-backup.conf.example" "$CONF_EXAMPLE_PATH"

# =========================================================
# SMB credentials
# =========================================================

if [ -f "$CREDENTIALS_PATH" ]; then
    chmod 600 "$CREDENTIALS_PATH"
    chown root:root "$CREDENTIALS_PATH"
    echo "Credentials найдены: $CREDENTIALS_PATH"
else
    echo "ВНИМАНИЕ: $CREDENTIALS_PATH не найден."
fi

# =========================================================
# Логи
# =========================================================

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
chown root:root "$LOG_DIR"

# =========================================================
# systemd service
# =========================================================

echo
echo "[6/7] Установка systemd service и timer..."

sed \
    -e "s|^ExecStart=.*|ExecStart=${INSTALL_PATH}|" \
    -e "s|^Environment=HA_BACKUP_CONF=.*|Environment=HA_BACKUP_CONF=${CONF_PATH}|" \
    -e "s|^Environment=HA_BACKUP_LOG_DIR=.*|Environment=HA_BACKUP_LOG_DIR=${LOG_DIR}|" \
    "${TMP_DIR}/ha-backup.service" \
    > "${TMP_DIR}/ha-backup.service.patched"

install -o root -g root -m 0644 \
    "${TMP_DIR}/ha-backup.service.patched" "$SERVICE_PATH"

install -o root -g root -m 0644 \
    "${TMP_DIR}/ha-backup.timer" "$TIMER_PATH"

# =========================================================
# systemd
# =========================================================

echo
echo "[7/7] Настройка systemd..."

systemctl daemon-reload
systemctl enable --now ha-backup.timer
systemctl restart ha-backup.timer

# =========================================================
# Итог
# =========================================================

echo
echo "========================================"
echo " Установка завершена"
echo "========================================"
echo
echo "Версия:  ${REF}"
echo "Зеркало: ${MIRROR_RAW}"
echo "Скрипт:  ${INSTALL_PATH}"
echo "Конфиг:  ${CONF_PATH}"
echo "Логи:    ${LOG_DIR}/"
echo
echo "Что дальше:"
echo
echo "  1. Отредактируйте конфиг:"
echo "       sudo nano ${CONF_PATH}"
echo
echo "  2. Проверьте timer:"
echo "       systemctl list-timers ha-backup.timer --no-pager"
echo
echo "  3. Запустите бэкап вручную:"
echo "       sudo systemctl start ha-backup.service"
echo
echo "  4. Смотрите лог:"
echo "       sudo tail -f ${LOG_DIR}/ha-backup-\$(date +%F).log"
echo

exit 0
