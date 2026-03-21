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
            -d "text=🚨 Exocortex Health Check Alert

$message

Time: $TIMESTAMP" \
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

log "=== Health Check Started ==="

if launchctl list | grep -q 'com.exocortex.scheduler'; then
    log "OK: scheduler launchd job is loaded"
else
    ERRORS+=("❌ Scheduler launchd job is NOT loaded")
    log "ERROR: Scheduler launchd job is NOT loaded"
fi

if launchctl list | grep -q 'com.exocortex.health-check'; then
    log "OK: health-check launchd job is loaded"
else
    ERRORS+=("⚠️ Health-check launchd job is NOT loaded")
    log "WARNING: Health-check launchd job is NOT loaded"
fi

if [ -x "$HOME/.config/aist/anthropic_auth_helper.sh" ] && "$HOME/.config/aist/anthropic_auth_helper.sh" >/dev/null 2>&1; then
    log "OK: auth helper works"
else
    ERRORS+=("🔴 Auth helper/env is broken")
    log "CRITICAL: auth helper/env is broken"
fi

for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
    load_status "$task"
    case "$task:$STATUS" in
        strategist-note-review:missing|strategist-week-review:missing)
            log "INFO: $task has no status yet for current schedule window"
            ;;
        *:success|*:skipped|*:running)
            log "OK: $task status=$STATUS"
            ;;
        *)
            ERRORS+=("❌ $task status=$STATUS (${SUMMARY:-no summary})")
            log "ERROR: $task status=$STATUS summary=${SUMMARY:-no summary}"
            ;;
    esac
done

log "=== Health Check Completed ==="

if [ ${#ERRORS[@]} -eq 0 ]; then
    log "✅ All systems operational"
    exit 0
fi

log "❌ Found ${#ERRORS[@]} issue(s)"
ERROR_MESSAGE="Found ${#ERRORS[@]} issue(s):

"
for error in "${ERRORS[@]}"; do
    ERROR_MESSAGE+="$error
"
done

notify_macos "⚠️ Exocortex Health Check" "Found ${#ERRORS[@]} issue(s). Check AGENTS-STATUS.md"
notify_telegram "$ERROR_MESSAGE"
log "Notifications sent"
exit 1
