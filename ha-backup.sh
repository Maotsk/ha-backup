#!/bin/bash
set -euo pipefail

CONF_BACKUP="/root/.ha-backup.conf"
LOCK_FILE="/run/ha-backup.lock"

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
# Защита от параллельного запуска
# =========================================================

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "ОШИБКА: другой экземпляр ha-backup уже запущен" >&2
    exit 1
fi

# =========================================================
# Логирование
# =========================================================

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
}

NOW() {
    date +'%Y-%m-%d %H:%M:%S'
}

HOSTNAME_SHORT=$(hostname)

# =========================================================
# Очистка старых логов
# =========================================================

cleanup_old_logs() {
    local days="${LOG_RETENTION_DAYS:-7}"
    local count

    count=$(
        find "$LOGDIR" \
            -maxdepth 1 \
            -type f \
            -name 'ha-backup-*.log' \
            -mtime +"$days" \
            2>/dev/null |
        wc -l
    )

    if [ "$count" -gt 0 ]; then
        find "$LOGDIR" \
            -maxdepth 1 \
            -type f \
            -name 'ha-backup-*.log' \
            -mtime +"$days" \
            -delete \
            2>/dev/null || true

        echo "$(NOW) Удалено старых логов: $count (старше ${days} дней)" >> "$LOGFILE"
    fi
}

# =========================================================
# Форматирование времени
# =========================================================

human_duration() {
    local sec="$1"
    local hours=$((sec / 3600))
    local minutes=$(((sec % 3600) / 60))
    local seconds=$((sec % 60))

    if [ "$hours" -gt 0 ]; then
        echo "${hours} ч ${minutes} мин ${seconds} сек"
    elif [ "$minutes" -gt 0 ]; then
        echo "${minutes} мин ${seconds} сек"
    else
        echo "${seconds} сек"
    fi
}

# =========================================================
# HTML escape для Telegram
# =========================================================

html_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g'
}

# =========================================================
# Telegram
# =========================================================

send_telegram_raw() {
    local text="$1"
    local silent="${2:-false}"

    if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        log "TG: пропуск — токен или chat_id не заданы"
        return 0
    fi

    local curl_args=(
        --silent
        --show-error
        --fail
        --request POST
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    )

    if [ -n "${TG_PROXY:-}" ]; then
        curl_args+=(-x "$TG_PROXY")
    fi

    curl_args+=(
        --data-urlencode "chat_id=${TG_CHAT_ID}"
        --data-urlencode "text=${text}"
        --data-urlencode "parse_mode=HTML"
        --data-urlencode "disable_notification=${silent}"
        --max-time 20
    )

    local response

    if ! response=$(curl "${curl_args[@]}" 2>&1); then
        log "TG: ошибка curl: $response"
        return 1
    fi

    log "TG: silent=${silent} response=${response}"

    if ! printf '%s' "$response" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
        log "TG: API вернул ошибку"
        return 1
    fi

    return 0
}

send_telegram() {
    local text="$1"
    local type="$2"

    if [ "$type" = "success" ]; then
        [ "${TG_NOTIFY_SUCCESS}" = "true" ] ||
            {
                log "TG: success отключён"
                return 0
            }

        send_telegram_raw "$text" "${TG_SILENT_SUCCESS}" || true

    elif [ "$type" = "error" ]; then
        [ "${TG_NOTIFY_ERROR}" = "true" ] ||
            {
                log "TG: error отключён"
                return 0
            }

        send_telegram_raw "$text" "${TG_SILENT_ERROR}" || true
    fi
}

# =========================================================
# Проверка CIFS mount
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

FSTYPE=$(findmnt -n -o FSTYPE --target "$MOUNTPOINT" 2>/dev/null | tail -1)

if [ "$FSTYPE" != "cifs" ]; then
    log "ОШИБКА: $MOUNTPOINT имеет тип '$FSTYPE', ожидался cifs"

    MSG="🔴 <b>Бэкап HA не выполнен</b>

<b>Что случилось:</b>
Папка <code>${MOUNTPOINT}</code> не подключена к сетевой шаре.
Сейчас это просто локальная папка на SD-карте.

<b>Последствия:</b>
Бэкап остановлен, чтобы данные не записались
на локальный накопитель.

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

TOTAL_FILES=0
TOTAL_BYTES=0
COMPLETED_JOBS=0

# =========================================================
# Backup jobs
# =========================================================

for job in "${JOBS[@]}"; do

    IFS='|' read -r SRC DST EXCL DEL <<< "$job"

    TARGET="$DEST$DST"

    if [ ! -e "$SRC" ]; then
        log "ПРЕДУПРЕЖДЕНИЕ: $SRC не существует, пропущено"
        continue
    fi

    # -----------------------------------------------------
    # Защита от rsync --delete на пустом источнике
    # -----------------------------------------------------

    if [ "$DEL" = "yes" ]; then

        if [ -d "$SRC" ]; then
            SOURCE_COUNT=$(
                find "$SRC" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -print \
                    -quit \
                    2>/dev/null |
                wc -l
            )

            if [ "$SOURCE_COUNT" -eq 0 ]; then

                log "ОШИБКА: источник $SRC пуст, --delete запрещён"

                MSG="🔴 <b>Бэкап HA остановлен</b>

<b>Причина:</b>
Источник <code>${SRC}</code> оказался пустым.

Для безопасности операция <code>rsync --delete</code>
не выполнена.

<b>Это защита от случайного удаления бэкапа.</b>

Хост: <code>${HOSTNAME_SHORT}</code>
Время: <code>$(NOW)</code>"

                send_telegram "$MSG" error
                exit 1
            fi
        fi
    fi

    mkdir -p "$TARGET"

    RSYNC_OPTS=(
        -a
        -v
        --stats
    )

    if [ "$BW_LIMIT" != "0" ]; then
        RSYNC_OPTS+=(--bwlimit="$BW_LIMIT")
    fi

    if [ -n "$EXCL" ]; then
        IFS=',' read -ra EXCL_ARR <<< "$EXCL"

        for e in "${EXCL_ARR[@]}"; do
            RSYNC_OPTS+=(--exclude="$e")
        done
    fi

    if [ "$DEL" = "yes" ]; then
        RSYNC_OPTS+=(--delete)
    fi

    log "rsync $SRC -> $TARGET [excl='${EXCL:-нет}' delete=${DEL:-no} bw=${BW_LIMIT}]"

    JOB_LOG="$LOGDIR/.rsync-job-$$.log"

    if rsync "${RSYNC_OPTS[@]}" "$SRC" "$TARGET" > "$JOB_LOG" 2>&1; then

        cat "$JOB_LOG" >> "$LOGFILE"

        JOB_STATS=$(
            grep -E \
                'Number of regular files transferred|Total transferred file size|Number of files|Number of created files' \
                "$JOB_LOG" |
            tr '\n' '; ' |
            sed 's/; $//'
        )

        log "OK: $SRC"
        log "Статистика: ${JOB_STATS:-нет данных}"

        JOB_FILES=$(
            awk -F': ' '/Number of regular files transferred/ {gsub(/,/,"",$2); print $2}' "$JOB_LOG" |
            tail -1
        )

        JOB_BYTES=$(
            awk -F': ' '/Total transferred file size/ {
                gsub(/ bytes/,"",$2)
                gsub(/,/,"",$2)
                print $2
            }' "$JOB_LOG" |
            tail -1
        )

        if [[ "$JOB_FILES" =~ ^[0-9]+$ ]]; then
            TOTAL_FILES=$((TOTAL_FILES + JOB_FILES))
        fi

        if [[ "$JOB_BYTES" =~ ^[0-9]+$ ]]; then
            TOTAL_BYTES=$((TOTAL_BYTES + JOB_BYTES))
        fi

        COMPLETED_JOBS=$((COMPLETED_JOBS + 1))

    else

        RC=$?

        cat "$JOB_LOG" >> "$LOGFILE"

        ERR_TAIL=$(tail -5 "$JOB_LOG" | html_escape)

        log "ОШИБКА: rsync $SRC код $RC"

        MSG="🔴 <b>Бэкап HA прерван</b>

<b>Что случилось:</b>
Во время копирования данных произошла ошибка.
Копирование остановлено.

<b>Последствия:</b>
Часть файлов может быть не скопирована.
Следующий запуск продолжит работу.

Хост: <code>${HOSTNAME_SHORT}</code>
Время: <code>$(NOW)</code>
Что копировалось: <code>${SRC}</code>
Код ошибки: <code>${RC}</code>

<b>Последние строки лога:</b>
<pre>${ERR_TAIL}</pre>"

        rm -f "$JOB_LOG"

        send_telegram "$MSG" error
        exit 1
    fi

    rm -f "$JOB_LOG"

done

# =========================================================
# Финальная статистика
# =========================================================

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
DURATION_HUMAN=$(human_duration "$DURATION")

SIZE_TOTAL=$(du -sh "$DEST" 2>/dev/null | awk '{print $1}')

if [ "$TOTAL_BYTES" -gt 0 ]; then
    TRANSFERRED_HUMAN=$(numfmt --to=iec "$TOTAL_BYTES")
else
    TRANSFERRED_HUMAN="0"
fi

log "=== Бэкап успешно завершён $(NOW) ==="
log "Задач выполнено: ${COMPLETED_JOBS}/${#JOBS[@]}"
log "Файлов передано: ${TOTAL_FILES}"
log "Данных передано: ${TRANSFERRED_HUMAN}"
log "Размер backup: ${SIZE_TOTAL:-неизвестно}"
log "Время выполнения: ${DURATION_HUMAN}"

MSG="🟢 <b>Бэкап HA выполнен</b>

Данные успешно сохранены на TrueNAS.

Хост: <code>${HOSTNAME_SHORT}</code>
Время: <code>$(NOW)</code>

Задач: <code>${COMPLETED_JOBS}/${#JOBS[@]}</code>
Файлов передано: <code>${TOTAL_FILES}</code>
Данных передано: <code>${TRANSFERRED_HUMAN}</code>
Размер backup: <code>${SIZE_TOTAL:-неизвестно}</code>
Заняло: <code>${DURATION_HUMAN}</code>"

send_telegram "$MSG" success

exit 0
