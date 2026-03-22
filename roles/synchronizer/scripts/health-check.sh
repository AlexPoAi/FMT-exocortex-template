#!/bin/bash
# Health Check для агентов экзокортекса

set -euo pipefail

LOG_DIR="$HOME/logs/health-check"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE=$(date '+%Y-%m-%d')
LOG_FILE="$LOG_DIR/$DATE.log"
ENV_FILE="$HOME/.config/aist/env"
STATE_DIR="$HOME/.local/state/exocortex"
STATUS_DIR="$STATE_DIR/status"

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
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TELEGRAM_CHAT_ID" \
            -d "text=🚨 Проверка здоровья экзокортекса\n\n$message\n\nВремя: $TIMESTAMP" \
            -d "parse_mode=HTML" > /dev/null 2>&1 || true
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
        UPDATED_AT="$(cat "$STATE_DIR/${task}-$DATE")"
        SUMMARY="derived from legacy daily marker"
    elif [ "$task" = "extractor-inbox-check" ] && [ -f "$STATE_DIR/${task}-last" ]; then
        STATUS="success"
        UPDATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
        SUMMARY="derived from legacy interval marker"
    fi
}

ERRORS=()
WARNINGS=()

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

for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
    load_status "$task"
    case "$task:$STATUS" in
        strategist-note-review:missing|strategist-week-review:missing)
            log "НЕТ СТАТУСА: $task ещё не должен был запускаться в текущем окне"
            ;;
        *:success|*:skipped|*:running)
            log "ОК: $task status=$STATUS"
            ;;
        *)
            WARNINGS+=("🟡 $task: $(printf '%s' "$STATUS" | sed 's/auth_failed/ошибка авторизации/; s/billing_failed/ошибка баланса или квоты/; s/model_unavailable/недоступна запрошенная модель/; s/network_failed/сетевая ошибка API/; s/timed_out/превышен лимит времени/; s/preflight_failed/ошибка предварительной проверки/; s/failed/ошибка/; s/missing/нет статуса/; s/stale_lock/зависшая блокировка/') (${SUMMARY:-без описания})")
            log "ВНИМАНИЕ: $task status=$STATUS summary=${SUMMARY:-no summary}"
            ;;
    esac
done

log "=== Проверка здоровья завершена ==="

if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
    log "✅ Среда исправна"
    exit 0
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    log "❌ Найдено ${#ERRORS[@]} критических проблем и ${#WARNINGS[@]} предупреждений"
else
    log "⚠️ Найдено ${#WARNINGS[@]} предупреждений"
fi

MESSAGE=""
if [ ${#ERRORS[@]} -gt 0 ]; then
    MESSAGE+="Критические проблемы:\n\n"
    for error in "${ERRORS[@]}"; do
        MESSAGE+="$error\n"
    done
    MESSAGE+="\n"
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    MESSAGE+="Предупреждения:\n\n"
    for warning in "${WARNINGS[@]}"; do
        MESSAGE+="$warning\n"
    done
fi

notify_macos "Экзокортекс: проверка среды" "Проверь AGENTS-STATUS.md и экран открытия сессии"
notify_telegram "$MESSAGE"
log "Уведомления отправлены"

if [ ${#ERRORS[@]} -gt 0 ]; then
    exit 1
fi

exit 0
