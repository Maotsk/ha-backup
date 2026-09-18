#!/bin/bash
set -euo pipefail

# =========================================================
# Home Assistant Backup Installer
# =========================================================
#
# Установщик ставит файлы в директорию, где лежит сам.
# Логи всегда в /var/log.hdd/ha.
#
# Структура на шаре TrueNAS фиксирована:
#   backup/ha/            — данные Home Assistant
#   backup/docker-config/ — docker-compose.yaml
#   backup/scripts/       — скрипт и конфиг
#   backup/system/        — fstab
#
# Если GitHub заблокирован — скрипт пробует зеркала.
# Можно задать своё:
#   HA_BACKUP_MIRROR=https://gh-proxy.com/https://github.com sudo -E bash install.sh
# =========================================================

LOG_DIR="/var/log.hdd/ha"

REPO="Maotsk/ha-backup"

# =========================================================
# Зеркала GitHub
# =========================================================
#
# Формат: "тип|URL"
#   prefix  = https://gh-proxy.com/https://github.com
#             Скачивание: ${URL}/Maotsk/ha-backup/raw/${REF}/...
#   replace = https://kkgithub.com
#             Скачивание: ${URL}/Maotsk/ha-backup/raw/${REF}/...
#
# Пробуются по очереди. Первое рабочее — используется.

GITHUB_MIRROR="${HA_BACKUP_MIRROR:-}"

GITHUB_MIRRORS_CANDIDATES=(
    "prefix|https://gh-proxy.com/https://github.com"
    "prefix|https://ghproxy.net/https://github.com"
    "replace|https://xget.xi-xu.me/gh"
    "replace|https://kkgithub.com"
    "replace|https://github.com"
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
# Информация перед установкой
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
    [yY]|[yY][eE][sS])
        echo "Продолжаю..."
        ;;
    *)
        echo "Отменено пользователем."
        exit 0
        ;;
esac

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
# Выбор рабочего зеркала GitHub
# =========================================================

echo
echo "[2/7] Проверка доступа к GitHub..."

# Функция проверки зеркала
# $1 = URL зеркала
# Возвращает 0, если зеркало отдаёт README.md
check_mirror() {
    local base="$1"
    local test_url="${base}/${REPO}/raw/main/README.md"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --max-time 10 \
        --range 0-0 \
        "$test_url" > /dev/null 2>&1
}

MIRROR_KIND=""
MIRROR_BASE=""

if [ -n "$GITHUB_MIRROR" ]; then
    # Пользователь задал своё зеркало
    echo "Использую зеркало из HA_BACKUP_MIRROR: ${GITHUB_MIRROR}"

    if check_mirror "$GITHUB_MIRROR"; then
        MIRROR_KIND="custom"
        MIRROR_BASE="$GITHUB_MIRROR"
    else
        echo "ВНИМАНИЕ: заданное зеркало недоступно." >&2
        echo "Пробую стандартный список..." >&2
    fi
fi

if [ -z "$MIRROR_BASE" ]; then
    for entry in "${GITHUB_MIRRORS_CANDIDATES[@]}"; do
        IFS='|' read -r kind base <<< "$entry"

        echo "  пробую: ${base}"

        if check_mirror "$base"; then
            MIRROR_KIND="$kind"
            MIRROR_BASE="$base"
            echo "  ✅ доступно"
            break
        else
            echo "  ✗ не отвечает"
        fi
    done
fi

if [ -z "$MIRROR_BASE" ]; then
    echo
    echo "ОШИБКА: не удалось найти рабочее зеркало GitHub." >&2
    echo >&2
    echo "Варианты решения:" >&2
    echo "  1. Задать своё зеркало:" >&2
    echo "     HA_BACKUP_MIRROR=https://gh-proxy.com/https://github.com \\" >&2
    echo "         sudo -E bash install.sh" >&2
    echo >&2
    echo "  2. Использовать прокси:" >&2
    echo "     export https_proxy=socks5h://127.0.0.1:1080" >&2
    echo "     sudo -E bash install.sh" >&2
    echo >&2
    echo "  3. Использовать proxychains:" >&2
    echo "     sudo proxychains4 bash install.sh" >&2
    exit 1
fi

echo "Использую зеркало: ${MIRROR_BASE}"

# =========================================================
# Определение версии
# =========================================================

REF="${HA_BACKUP_REF:-}"

if [ -z "$REF" ]; then
    echo
    echo "Определяю последнюю версию..."

    # Для определения версии используем зеркало, если оно prefix
    # (для replace — тоже работает)
    LATEST_URL=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
                 --max-time 15 \
                 "${MIRROR_BASE}/${REPO}/releases/latest" \
                 2>/dev/null || true)

    if [[ "$LATEST_URL" == *"/tag/"* ]]; then
        REF="${LATEST_URL##*/tag/}"
    else
        echo "ВНИМАНИЕ: не удалось определить последнюю версию." >&2
        echo "Использую fallback: v1.0.0" >&2
        REF="v1.0.0"
    fi
fi

RAW_BASE="${MIRROR_BASE}/${REPO}/raw/${REF}"

echo
echo "Версия для установки: ${REF}"

# =========================================================
# Проверка/создание директорий
# =========================================================

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

# =========================================================
# Проверка доступности версии
# =========================================================

if ! curl --fail --silent --show-error --location --range 0-0 \
        --max-time 15 \
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
echo "[3/7] Загрузка файлов версии ${REF}..."

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
echo "[4/7] Проверка ha-backup.sh..."

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
echo "[5/7] Проверка конфигурации..."

if [ ! -f "$CONF_PATH" ]; then

    sed \
        -e "s|INSTALL_PATH|${INSTALL_PATH}|g" \
        -e "s|CONF_PATH|${CONF_PATH}|g" \
        -e "s|LOGDIR=\"/var/log.hdd/ha\"|LOGDIR=\"${LOG_DIR}\"|" \
        "${TMP_DIR}/.ha-backup.conf.example" \
        > "${TMP_DIR}/.ha-backup.conf.patched"

    install \
        -o root \
        -g root \
        -m 0600 \
        "${TMP_DIR}/.ha-backup.conf.patched" \
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
echo "Проверка SMB credentials..."

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

mkdir -p "$LOG_DIR"
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
# Итог
# =========================================================

echo
echo "========================================"
echo " Установка завершена"
echo "========================================"
echo
echo "Использовано зеркало:"
echo "  ${MIRROR_BASE}"
echo
echo "Скрипт:"
echo "  $INSTALL_PATH"
echo
echo "Конфигурация:"
echo "  $CONF_PATH"
echo
echo "Логи:"
echo "  $LOG_DIR/"
echo
echo "Что дальше:"
echo
echo "  1. Отредактируйте конфиг:"
echo "       sudo nano $CONF_PATH"
echo
echo "     Проверьте:"
echo "       DEST        — путь к шаре (обычно менять не нужно)"
echo "       MOUNTPOINT  — точка монтирования шары"
echo "       TG_TOKEN    — если нужны уведомления в Telegram"
echo "       TG_CHAT_ID"
echo
echo "  2. Проверьте timer:"
echo "       systemctl list-timers ha-backup.timer --no-pager"
echo
echo "  3. Запустите бэкап вручную:"
echo "       sudo systemctl start ha-backup.service"
echo
echo "  4. Смотрите лог:"
echo "       sudo tail -f $LOG_DIR/ha-backup-\$(date +%F).log"
echo

exit 0
