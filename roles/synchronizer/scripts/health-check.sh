#!/bin/bash
# Health Check для агентов экзокортекса

set -euo pipefail

LOG_DIR="$HOME/logs/health-check"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE=$(date '+%Y-%m-%d')
HOUR=$(date +%H)
DOW=$(date +%u)
NOW_EPOCH=$(date +%s)
LOG_FILE="$LOG_DIR/$DATE.log"
ENV_FILE="$HOME/.config/aist/env"
STATE_DIR="$HOME/.local/state/exocortex"
STATUS_DIR="$STATE_DIR/status"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/Github}"
CANONICAL_MEMORY_DIR="$WORKSPACE_DIR/memory"

mkdir -p "$LOG_DIR"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

notify_macos() {
    local title="$1"
    local message="$2"
    message=$(printf '%s' "$message" | tr '"' "'" | tr '\n' ' ')
    printf 'display notification "%s" with title "%s" sound name "Basso"' "$message" "$title" | osascript 2>/dev/null || true
}

notify_telegram() {
    local message="$1"
    local notify_script="$HOME/Github/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh"

    if [ -x "$notify_script" ]; then
        NOTIFY_TEXT="$message" "$notify_script" synchronizer health-check > /dev/null 2>&1 && return 0
    fi

    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TELEGRAM_CHAT_ID" \
            --data-urlencode "text=$message" \
            -d "parse_mode=HTML" > /dev/null 2>&1 || true
    fi
}

format_epoch() {
    local ts="$1"
    if [ -z "$ts" ] || [ "$ts" -le 0 ]; then
        echo ""
        return
    fi
    date -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo ""
}

timestamp_to_epoch() {
    local ts="$1"
    [ -n "$ts" ] || {
        echo 0
        return
    }
    date -j -f '%Y-%m-%d %H:%M:%S' "$ts" '+%s' 2>/dev/null || date -d "$ts" '+%s' 2>/dev/null || echo 0
}

task_reference_ts() {
    if [ -n "${END_TS:-}" ]; then
        echo "$END_TS"
    else
        echo "${UPDATED_AT:-}"
    fi
}

task_status_is_current() {
    local task="$1"
    local ref_ts="$2"
    local ref_date ref_epoch age budget

    ref_date=$(printf '%s' "$ref_ts" | cut -d' ' -f1)

    case "$task" in
        strategist-note-review|strategist-week-review)
            budget="${STALENESS_BUDGET_SEC:-$(default_staleness_budget_for "$task")}"
            ref_epoch=$(timestamp_to_epoch "$ref_ts")
            [ "$ref_epoch" -gt 0 ] || return 1
            age=$(( NOW_EPOCH - ref_epoch ))
            [ "$age" -lt "$budget" ]
            ;;
        extractor-inbox-check)
            if ! (( 10#$HOUR >= 7 && 10#$HOUR <= 23 )); then
                [ "$ref_date" = "$DATE" ]
                return
            fi
            ref_epoch=$(timestamp_to_epoch "$ref_ts")
            [ "$ref_epoch" -gt 0 ] || return 1
            age=$(( NOW_EPOCH - ref_epoch ))
            [ "$age" -lt 10800 ]
            ;;
        *)
            [ "$ref_date" = "$DATE" ]
            ;;
    esac
}

task_missing_is_expected() {
    local task="$1"

    case "$task" in
        strategist-morning)
            [ "$HOUR" -lt 4 ]
            ;;
        strategist-note-review)
            [ "$HOUR" -lt 22 ]
            ;;
        strategist-week-review)
            [ "$DOW" -ne 1 ]
            ;;
        synchronizer-daily-report)
            [ "$HOUR" -lt 6 ] && [ ! -f "$STATE_DIR/strategist-morning-$DATE" ]
            ;;
        extractor-inbox-check)
            ! (( 10#$HOUR >= 7 && 10#$HOUR <= 23 ))
            ;;
        *)
            return 1
            ;;
    esac
}

default_staleness_budget_for() {
    case "$1" in
        extractor-inbox-check) echo 10800 ;;
        strategist-week-review) echo 604800 ;;
        strategist-note-review) echo 86400 ;;
        strategist-morning|synchronizer-code-scan|synchronizer-daily-report) echo 86400 ;;
        *) echo 43200 ;;
    esac
}

check_protocol_contract() {
    local missing=0

    if [ -L "$CANONICAL_MEMORY_DIR" ] && [ ! -e "$CANONICAL_MEMORY_DIR" ]; then
        ERRORS+=("🔴 Canonical memory path broken: $CANONICAL_MEMORY_DIR")
        log "ОШИБКА: broken symlink for canonical memory path: $CANONICAL_MEMORY_DIR"
        return
    fi

    if [ ! -d "$CANONICAL_MEMORY_DIR" ]; then
        ERRORS+=("🔴 Canonical memory path missing: $CANONICAL_MEMORY_DIR")
        log "ОШИБКА: canonical memory path missing: $CANONICAL_MEMORY_DIR"
        return
    fi

    for protocol in protocol-open.md protocol-work.md protocol-close.md; do
        if [ ! -f "$CANONICAL_MEMORY_DIR/$protocol" ]; then
            ERRORS+=("🔴 Canonical protocol missing: memory/$protocol")
            log "ОШИБКА: canonical protocol missing: $CANONICAL_MEMORY_DIR/$protocol"
            missing=1
        fi
    done

    if [ "$missing" -eq 0 ]; then
        log "ОК: canonical protocol routes resolved from $CANONICAL_MEMORY_DIR"
    fi
}

load_status() {
    local task="$1"
    local file="$STATUS_DIR/${task}.status"

    TASK_NAME="$task"
    STATUS="missing"
    EXIT_CODE=""
    SUMMARY="status artifact missing"
    UPDATED_AT=""
    LOG_PATH=""

    if [ -f "$file" ]; then
        . "$file"
    elif [ -f "$STATE_DIR/${task}-$DATE" ]; then
        STATUS="success"
        UPDATED_AT="$DATE $(cat "$STATE_DIR/${task}-$DATE")"
        SUMMARY="derived from legacy daily marker"
    elif [ "$task" = "extractor-inbox-check" ] && [ -f "$STATE_DIR/${task}-last" ]; then
        STATUS="success"
        UPDATED_AT="$(format_epoch "$(cat "$STATE_DIR/${task}-last")")"
        SUMMARY="derived from legacy interval marker"
    fi

    local ref_ts
    ref_ts=$(task_reference_ts)
    if [ "$STATUS" != "missing" ] && ! task_status_is_current "$task" "$ref_ts"; then
        STATUS="stale"
        EXIT_CODE=""
        SUMMARY="status artifact from previous window"
    fi
}

ERRORS=()
WARNINGS=()
STALE=()

# Человекочитаемые имена агентов
agent_display_name() {
    case "$1" in
        strategist-morning)       echo "Утренний брифинг" ;;
        strategist-note-review)   echo "Ревью заметок" ;;
        strategist-week-review)   echo "Недельное ревью" ;;
        synchronizer-code-scan)   echo "Сканер кода" ;;
        synchronizer-daily-report) echo "Дневной отчёт" ;;
        extractor-inbox-check)    echo "Проверка inbox" ;;
        *)                        echo "$1" ;;
    esac
}

log "=== Проверка здоровья запущена ==="

if launchctl list | grep -q 'com.exocortex.scheduler'; then
    log "ОК: планировщик загружен"
else
    ERRORS+=("🔴 Планировщик экзокортекса не загружен")
    log "ОШИБКА: планировщик экзокортекса не загружен"
fi

if launchctl list | grep -q 'com.exocortex.health-check'; then
    log "ОК: проверка среды загружена"
else
    WARNINGS+=("🟡 Проверка среды не загружена")
    log "ВНИМАНИЕ: проверка среды не загружена"
fi

if [ -x "$HOME/.config/aist/anthropic_auth_helper.sh" ] && "$HOME/.config/aist/anthropic_auth_helper.sh" >/dev/null 2>&1; then
    log "ОК: помощник авторизации исправен"
else
    ERRORS+=("🔴 Помощник авторизации или env-слой сломан")
    log "ОШИБКА: помощник авторизации или env-слой сломан"
fi

check_protocol_contract

for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
    load_status "$task"

    if [ "$STATUS" = "missing" ] && task_missing_is_expected "$task"; then
        log "НЕТ СТАТУСА: $task ещё не должен был запускаться в текущем окне"
        continue
    fi

    case "$STATUS" in
        success|skipped|running)
            log "ОК: $task status=$STATUS"
            ;;
        stale)
            STALE+=("$(agent_display_name "$task")")
            log "УСТАРЕЛ: $task (норма после перезагрузки)"
            ;;
        *)
            human_status=$(printf '%s' "$STATUS" | sed \
                -e 's/auth_failed/ошибка авторизации/' \
                -e 's/billing_failed/ошибка баланса или квоты/' \
                -e 's/model_unavailable/недоступна запрошенная модель/' \
                -e 's/network_failed/сетевая ошибка API/' \
                -e 's/timed_out/превышен лимит времени/' \
                -e 's/preflight_failed/ошибка предварительной проверки/' \
                -e 's/failed/ошибка запуска/' \
                -e 's/missing/нет статуса/' \
                -e 's/stale_lock/зависшая блокировка/')
            WARNINGS+=("$(agent_display_name "$task") — ${human_status}")
            log "ВНИМАНИЕ: $task status=$STATUS summary=${SUMMARY:-no summary}"
            ;;
    esac
done

log "=== Проверка здоровья завершена ==="

if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ] && [ ${#STALE[@]} -eq 0 ]; then
    log "✅ Среда исправна"
    exit 0
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    log "❌ Найдено ${#ERRORS[@]} критических проблем и ${#WARNINGS[@]} предупреждений"
else
    log "⚠️ Найдено ${#WARNINGS[@]} предупреждений, ${#STALE[@]} устаревших"
fi

MESSAGE="⚠️ Экзокортекс — $(date '+%H:%M')\n\n"

if [ ${#ERRORS[@]} -gt 0 ]; then
    MESSAGE+="🔴 Критично (${#ERRORS[@]}):\n"
    for error in "${ERRORS[@]}"; do
        MESSAGE+="• ${error}\n"
    done
    MESSAGE+="\n"
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    MESSAGE+="🟡 Требует внимания (${#WARNINGS[@]}):\n"
    for warning in "${WARNINGS[@]}"; do
        MESSAGE+="• ${warning}\n"
    done
    MESSAGE+="\n"
fi

if [ ${#STALE[@]} -gt 0 ]; then
    stale_list=$(printf '%s, ' "${STALE[@]}")
    stale_list="${stale_list%, }"
    MESSAGE+="💤 Норма после перезагрузки (${#STALE[@]}):\n"
    MESSAGE+="${stale_list}\n"
    MESSAGE+="→ Обновятся при следующем запуске\n"
fi

notify_macos "Экзокортекс: проверка среды" "Проверь AGENTS-STATUS.md и экран открытия сессии"
notify_telegram "$MESSAGE"
log "Уведомления отправлены"

if [ ${#ERRORS[@]} -gt 0 ]; then
    exit 1
fi

exit 0
