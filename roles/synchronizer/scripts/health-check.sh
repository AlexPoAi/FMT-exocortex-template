#!/bin/bash
# Health Check для агентов экзокортекса
# Проверяет статус агентов и отправляет уведомления при ошибках

set -e

# Конфигурация
LOG_DIR="$HOME/logs/health-check"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE=$(date '+%Y-%m-%d')
LOG_FILE="$LOG_DIR/$DATE.log"
ENV_FILE="$HOME/.config/aist/env"

# Создаём папку для логов
mkdir -p "$LOG_DIR"

# Загрузка переменных окружения (для Telegram)
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
    printf 'display notification "%s" with title "%s" sound name "Basso"' "$message" "$title" | osascript 2>/dev/null || true
}

notify_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TELEGRAM_CHAT_ID" \
            -d "text=🚨 Exocortex Health Check Alert

$message

Time: $TIMESTAMP" \
            -d "parse_mode=HTML" > /dev/null 2>&1 || true
    fi
}

# Массив для сбора ошибок
ERRORS=()

log "=== Health Check Started ==="

# 1. Проверка статуса агентов через launchctl
log "Checking agent status..."

AGENTS=(
    "com.exocortex.scheduler"
    "com.extractor.inbox-check"
    "com.extractor.session-watcher"
    "com.strategist.morning"
    "com.strategist.weekreview"
)

for agent in "${AGENTS[@]}"; do
    status=$(launchctl list | grep "$agent" || echo "")
    if [ -z "$status" ]; then
        ERRORS+=("❌ Agent $agent is NOT running")
        log "ERROR: Agent $agent is NOT running"
    else
        exit_code=$(echo "$status" | awk '{print $1}')
        if [ "$exit_code" != "0" ] && [ "$exit_code" != "-" ]; then
            ERRORS+=("⚠️ Agent $agent exited with code $exit_code")
            log "WARNING: Agent $agent exited with code $exit_code"
        else
            log "OK: Agent $agent is running"
        fi
    fi
done

# 2. Проверка логов на критические ошибки
log "Checking logs for errors..."

# Проверяем логи за последние 2 часа
CRITICAL_ERRORS=(
    "OAuth token has expired"
    "API Error: 401"
    "Failed to authenticate"
    "authentication_error"
)

for log_dir in "$HOME/logs/strategist" "$HOME/logs/extractor"; do
    if [ -d "$log_dir" ]; then
        latest_log=$(ls -t "$log_dir"/*.log 2>/dev/null | head -1)
        if [ -n "$latest_log" ]; then
            for error_pattern in "${CRITICAL_ERRORS[@]}"; do
                # Проверяем только последние 100 строк (примерно последние 2 часа)
                if tail -100 "$latest_log" | grep -q "$error_pattern"; then
                    ERRORS+=("🔴 Critical error in $(basename $log_dir): $error_pattern")
                    log "CRITICAL: Found '$error_pattern' in $latest_log"
                fi
            done
        fi
    fi
done

# 3. Проверка времени последнего успешного запуска
log "Checking last successful run times..."

# Strategist должен был запуститься сегодня в 4:00
STRATEGIST_LOG="$HOME/logs/strategist/$DATE.log"
if [ -f "$STRATEGIST_LOG" ]; then
    if grep -q "Completed scenario" "$STRATEGIST_LOG"; then
        log "OK: Strategist ran successfully today"
    else
        # Проверяем был ли запуск вообще
        if grep -q "Starting scenario" "$STRATEGIST_LOG"; then
            ERRORS+=("⚠️ Strategist started but did not complete today")
            log "WARNING: Strategist started but did not complete"
        fi
    fi
else
    # Если сегодня ещё рано (до 4:00), проверяем вчерашний лог
    current_hour=$(date +%H)
    if [ "$current_hour" -lt 4 ]; then
        yesterday=$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d '1 day ago' '+%Y-%m-%d')
        STRATEGIST_LOG_YESTERDAY="$HOME/logs/strategist/$yesterday.log"
        if [ ! -f "$STRATEGIST_LOG_YESTERDAY" ] || ! grep -q "Completed scenario" "$STRATEGIST_LOG_YESTERDAY"; then
            ERRORS+=("⚠️ Strategist did not run successfully yesterday")
            log "WARNING: Strategist did not run successfully yesterday"
        fi
    else
        ERRORS+=("⚠️ Strategist has not run today (expected at 4:00)")
        log "WARNING: Strategist has not run today"
    fi
fi

# Extractor должен запускаться каждые 3 часа
EXTRACTOR_LOG="$HOME/logs/extractor/$DATE.log"
if [ -f "$EXTRACTOR_LOG" ]; then
    # Проверяем был ли запуск в последние 4 часа
    last_run=$(tail -50 "$EXTRACTOR_LOG" | grep "Starting process" | tail -1 | cut -d']' -f1 | tr -d '[')
    if [ -n "$last_run" ]; then
        last_run_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_run" "+%s" 2>/dev/null || echo "0")
        current_epoch=$(date "+%s")
        hours_since=$((($current_epoch - $last_run_epoch) / 3600))

        if [ "$hours_since" -gt 4 ]; then
            ERRORS+=("⚠️ Extractor last ran $hours_since hours ago (expected every 3h)")
            log "WARNING: Extractor last ran $hours_since hours ago"
        else
            log "OK: Extractor ran $hours_since hours ago"
        fi
    fi
fi

# 4. Итоговый отчёт
log "=== Health Check Completed ==="

if [ ${#ERRORS[@]} -eq 0 ]; then
    log "✅ All systems operational"
    exit 0
else
    log "❌ Found ${#ERRORS[@]} issue(s)"

    # Формируем сообщение для уведомления
    ERROR_MESSAGE="Found ${#ERRORS[@]} issue(s):

"
    for error in "${ERRORS[@]}"; do
        ERROR_MESSAGE+="$error
"
    done

    # Отправляем уведомления
    notify_macos "⚠️ Exocortex Health Check" "Found ${#ERRORS[@]} issue(s). Check logs for details."
    notify_telegram "$ERROR_MESSAGE"

    log "Notifications sent"
    exit 1
fi
