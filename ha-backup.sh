```bash
#!/bin/bash
set -euo pipefail

CONF_BACKUP="/root/.ha-backup.conf"

if [ ! -f "$CONF_BACKUP" ]; then
    echo "ОШИБКА: $CONF_BACKUP не найден" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONF_BACKUP"

TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
TG_PROXY="${TG_PROXY:-}"
TG_NOTIFY_SUCCESS="${TG_NOTIFY_SUCCESS:-true}"
TG_NOTIFY_ERROR="${TG_NOTIFY_ERROR:-true}"
TG_SILENT_SUCCESS="${TG_SILENT_SUCCESS:-true}"
TG_SILENT_ERROR="${TG_SILENT_ERROR:-false}"
BW_LIMIT="${BW_LIMIT:-0}"

: "${DEST:?DEST не задан}"
: "${MOUNTPOINT:?MOUNTPOINT не задан}"
: "${LOGDIR:?LOGDIR не задан}"
: "${JOBS:?JOBS не задан}"

mkdir -p "$LOGDIR"

LOGFILE="$LOGDIR/ha-backup-$(date +%F).log"

# =========================================================
# Очистка старых логов
# =========================================================

cleanup_old_logs() {
    local days="${LOG_RETENTION_DAYS:-7}"
    local count

    count=$(find "$LOGDIR" \
        -maxdepth 1 \
        -type f \
        -name 'ha-backup-*.log' \
        -mtime +"$days" \
        2>/dev/null | wc -l)

    if [ "$count" -gt 0 ]; then
        find "$LOGDIR" \
            -maxdepth 1 \
            -type f \
            -name 'ha-backup-*.log' \
            -mtime +"$days" \
            -delete 2>/dev/null || true

        echo "$(date +'%Y-%m-%d %H:%M:%S') Удалено старых логов: $count (старше ${days} дней)" >> "$LOGFILE"
    fi
}

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
}

NOW() {
    date +'%Y-%m-%d %H:%M:%S'
}

HOSTNAME_SHORT=$(hostname)

# =========================================================
# Вспомогательные функции
# =========================================================

human_duration() {
    local SEC="$1"
    local M=$((SEC / 60))
    local S=$((SEC % 60))

    if [ "$M" -gt 0 ]; then
        echo "${M} мин ${S} сек"
    else
        echo "${S} сек"
    fi
}

html_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g'
}

send_telegram_raw() {
    local TEXT="$1"
    local SILENT="${2:-false}"

    if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        log "TG: пропуск — токен или chat_id не заданы"
        return 0
    fi

    local curl_args=(
        -s
        -X POST
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    )

    if [ -n "${TG_PROXY:-}" ]; then
        curl_args+=(-x "$TG_PROXY")
    fi

    curl_args+=(
        --data-urlencode "chat_id=${TG_CHAT_ID}"
        --data-urlencode "text=${TEXT}"
        --data-urlencode "parse_mode=HTML"
        --data-urlencode "disable_notification=${SILENT}"
        --max-time 20
    )

    local RESP

    RESP=$(curl "${curl_args[@]}" 2>&1) || true

    log "TG: silent=$SILENT resp=$RESP"
}

send_telegram() {
    local TEXT="$1"
    local TYPE="$2"

    if [ "$TYPE" = "success" ]; then
        if [ "${TG_NOTIFY_SUCCESS}" = "true" ]; then
            send_telegram_raw "$TEXT" "${TG_SILENT_SUCCESS}"
        else
            log "TG: success отключён"
        fi

    elif [ "$TYPE" = "error" ]; then
        if [ "${TG_NOTIFY_ERROR}" = "true" ]; then
            send_telegram_raw "$TEXT" "${TG_SILENT_ERROR}"
        else
            log "TG: error отключён"
        fi
    fi
}

# =========================================================
# Проверка точки монтирования
# =========================================================

if ! mountpoint -q "$MOUNTPOINT"; then

    log "ОШИБКА: $MOUNTPOINT не смонтирован, бэкап прерван"

    MSG="🔴 <b>Бэкап HA не выполнен</b>

<b>Что случилось:</b>
Сетевая папка (шара TrueNAS) сейчас не подключена.

<b>Последствия:</b>
Бэкап НЕ сделан. Локальные данные не пострадали.

<b>Что делать:</b>
Проверьте, включён ли TrueNAS и доступна ли сеть.
Если всё в порядке — подождите следующего запуска,
шара подключится автоматически.

Хост: <code>${HOSTNAME_SHORT}</code>
Время: <code>$(NOW)</code>"

    send_telegram "$MSG" error
    exit 1
fi

# =========================================================
# Проверка типа файловой системы
# =========================================================

FSTYPE=$(findmnt -n -o FSTYPE --target "$MOUNTPOINT" 2>/dev/null | tail -1)

if [ "$FSTYPE" != "cifs" ]; then

    log "ОШИБКА: $MOUNTPOINT имеет тип '$FSTYPE', ожидался cifs"

    MSG="🔴 <b>Бэкап HA не выполнен</b>

<b>Что случилось:</b>
Папка <code>${MOUNTPOINT}</code> не подключена к сетевой шаре.
Сейчас это просто локальная папка на SD-карте.

<b>Последствия:</b>
Бэкап остановлен, чтобы не заполнить локальный диск.

<b>Что делать:</b>
Проверьте связь с TrueNAS.

Хост: <code>${HOSTNAME_SHORT}</code>
Время: <code>$(NOW)</code>"

    send_telegram "$MSG" error
    exit 1
fi

log "Проверки пройдены: $MOUNTPOINT ($FSTYPE) доступен"

# =========================================================
# Очистка логов
# =========================================================

cleanup_old_logs

START_TS=$(date +%s)

log "=== Старт бэкапа $(NOW) ==="
log "Задач в очереди: ${#JOBS[@]}"

# =========================================================
# Основной цикл
# =========================================================

for job in "${JOBS[@]}"; do

    IFS='|' read -r SRC DST EXCL DEL <<< "$job"

    TARGET="$DEST$DST"

    # -----------------------------------------------------
    # Проверка источника
    # -----------------------------------------------------

    if [ ! -e "$SRC" ]; then

        log "ПРЕДУПРЕЖДЕНИЕ: $SRC не существует, пропущено"

        continue
    fi

    # -----------------------------------------------------
    # Защита rsync --delete
    #
    # Если источник является каталогом и внезапно стал
    # полностью пустым, удаление на стороне TrueNAS
    # запрещается.
    # -----------------------------------------------------

    if [ "$DEL" = "yes" ] && [ -d "$SRC" ]; then

        if [ -z "$(find "$SRC" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then

            log "ОШИБКА: источник $SRC пуст — rsync --delete ЗАПРЕЩЁН"

            MSG="🔴 <b>Бэкап HA остановлен</b>

<b>Причина:</b>
Источник <code>${SRC}</code> оказался пустым.

Чтобы не удалить существующий бэкап на TrueNAS,
операция <code>rsync --delete</code> запрещена.

<b>Источник:</b>
<code>${SRC}</code>

<b>Цель:</b>
<code>${TARGET}</code>

Хост: <code>${HOSTNAME_SHORT}</code>
Время: <code>$(NOW)</code>"

            send_telegram "$MSG" error
            exit 1
        fi

        log "Защита --delete: источник $SRC не пуст"
    fi

    # -----------------------------------------------------
    # Создание каталога назначения
    # -----------------------------------------------------

    mkdir -p "$TARGET"

    # -----------------------------------------------------
    # Параметры rsync
    # -----------------------------------------------------

    RSYNC_OPTS=(-av)

    if [ "$BW_LIMIT" != "0" ]; then
        RSYNC_OPTS+=(--bwlimit="$BW_LIMIT")
    fi

    # -----------------------------------------------------
    # Исключения
    # -----------------------------------------------------

    if [ -n "$EXCL" ]; then

        IFS=',' read -ra EXCL_ARR <<< "$EXCL"

        for e in "${EXCL_ARR[@]}"; do
            RSYNC_OPTS+=(--exclude="$e")
        done
    fi

    # -----------------------------------------------------
    # Удаление лишних файлов на TrueNAS
    # -----------------------------------------------------

    if [ "$DEL" = "yes" ]; then
        RSYNC_OPTS+=(--delete)
    fi

    log "rsync $SRC -> $TARGET [excl='${EXCL:-нет}' delete=${DEL:-no} bw=${BW_LIMIT}]"

    # -----------------------------------------------------
    # Запуск rsync
    # -----------------------------------------------------

    if rsync "${RSYNC_OPTS[@]}" "$SRC" "$TARGET" >> "$LOGFILE" 2>&1; then

        log "OK: $SRC"

    else

        RC=$?

        ERR_TAIL=$(tail -5 "$LOGFILE" | html_escape)

        log "ОШИБКА: rsync $SRC код $RC"

        MSG="🔴 <b>Бэкап HA прерван</b>

<b>Что случилось:</b>
Во время копирования данных произошла ошибка.
Копирование остановлено.

<b>Последствия:</b>
Часть файлов может быть не скопирована.
Следующий запуск продолжит с места остановки.

<b>Что делать:</b>
Если ошибка повторяется — проверьте доступ к TrueNAS.

Хост: <cod
```
