#!/bin/bash
set -euo pipefail

CONF_BACKUP="/root/.ha-backup.conf"

if [ ! -f "$CONF_BACKUP" ]; then
    echo "ОШИБКА: $CONF_BACKUP не найден" >&2
    exit 1
fi
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

# ---------- очистка старых логов ----------
cleanup_old_logs() {
    local days="${LOG_RETENTION_DAYS:-7}"
    local count
    count=$(find "$LOGDIR" -maxdepth 1 -type f -name 'ha-backup-*.log' -mtime +"$days" 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        find "$LOGDIR" -maxdepth 1 -type f -name 'ha-backup-*.log' -mtime +"$days" -delete 2>/dev/null || true
        echo "$(date +'%Y-%m-%d %H:%M:%S') Удалено старых логов: $count (старше ${days} дней)" >> "$LOGFILE"
    fi
}

log() { echo "$(date +'%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }

NOW() { date +'%Y-%m-%d %H:%M:%S'; }
HOSTNAME_SHORT=$(hostname)

human_duration() {
    local SEC=$1
    local M=$((SEC / 60))
    local S=$((SEC % 60))
    if [ "$M" -gt 0 ]; then
        echo "${M} мин ${S} сек"
    else
        echo "${S} сек"
    fi
}

html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

send_telegram_raw() {
    local TEXT="$1"
    local SILENT="${2:-false}"
    if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        log "TG: пропуск — токен или chat_id не заданы"
        return 0
    fi
    local curl_args=(-s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage")
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
        [ "${TG_NOTIFY_SUCCESS}" = "true" ] || { log "TG: success отключён"; return 0; }
        send_telegram_raw "$TEXT" "${TG_SILENT_SUCCESS}"
    elif [ "$TYPE" = "error" ]; then
        [ "${TG_NOTIFY_ERROR}" = "true" ] || { log "TG: error отключён"; return 0; }
        send_telegram_raw "$TEXT" "${TG_SILENT_ERROR}"
    fi
}

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

FSTYPE=$(findmnt -n -o FSTYPE --target "$MOUNTPOINT" 2>/dev/null | tail -1)
if [ "$FSTYPE" != "cifs" ]; then
    log "ОШИБКА: $MOUNTPOINT имеет тип '$FSTYPE', ожидался cifs"
    MSG="🔴 <b>Бэкап HA не выполнен</b>

<b>Что случилось:</b>
Папка <code>${MOUNTPOINT}</code> не подключена к сетевой шаре.
Сейчас это просто пустая локальная папка на SD-карте.

<b>Последствия:</b>
Если бы бэкап пошёл туда, он лёг бы на SD-карту Armbian
и мог её забить. Бэкап остановлен, чтобы этого не случилось.

<b>Что делать:</b>
Проверьте связь с TrueNAS.
Если связи нет — следующий запуск попробует снова.

Хост: <code>${HOSTNAME_SHORT}</code>
Время: <code>$(NOW)</code>"
    send_telegram "$MSG" error
    exit 1
fi

log "Проверки пройдены: $MOUNTPOINT ($FSTYPE) доступен"

cleanup_old_logs

START_TS=$(date +%s)
log "=== Старт бэкапа $(NOW) ==="
log "Задач в очереди: ${#JOBS[@]}"

for job in "${JOBS[@]}"; do
    IFS='|' read -r SRC DST EXCL DEL <<< "$job"
    TARGET="$DEST$DST"
    if [ ! -e "$SRC" ]; then
        log "ПРЕДУПРЕЖДЕНИЕ: $SRC не существует, пропущено"
        continue
    fi
    mkdir -p "$TARGET"
    RSYNC_OPTS=(-av)
    [ "$BW_LIMIT" != "0" ] && RSYNC_OPTS+=(--bwlimit="$BW_LIMIT")
    if [ -n "$EXCL" ]; then
        IFS=',' read -ra EXCL_ARR <<< "$EXCL"
        for e in "${EXCL_ARR[@]}"; do
            RSYNC_OPTS+=(--exclude="$e")
        done
    fi
    [ "$DEL" = "yes" ] && RSYNC_OPTS+=(--delete)
    log "rsync $SRC -> $TARGET [excl='${EXCL:-нет}' delete=${DEL:-no} bw=${BW_LIMIT}]"
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

Хост: <code>${HOSTNAME_SHORT}</code>
Время: <code>$(NOW)</code>
Что копировалось: <code>${SRC}</code>
Код ошибки: <code>${RC}</code>

<b>Последние строки лога:</b>
<pre>${ERR_TAIL}</pre>"
        send_telegram "$MSG" error
        exit 1
    fi
done

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
DURATION_HUMAN=$(human_duration "$DURATION")
SIZE_TOTAL=$(du -sh "$DEST" 2>/dev/null | awk '{print $1}')
log "=== Бэкап успешно завершён $(NOW), занял ${DURATION} сек (${DURATION_HUMAN}), размер: ${SIZE_TOTAL} ==="

MSG="🟢 <b>Бэкап HA выполнен</b>

Данные успешно сохранены на TrueNAS.

Хост: <code>${HOSTNAME_SHORT}</code>
Время: <code>$(NOW)</code>
Заняло: <code>${DURATION_HUMAN}</code>
Размер: <code>${SIZE_TOTAL}</code>"
send_telegram "$MSG" success

exit 0
