#!/bin/bash
# daily-telegram-report.sh — ежедневный отчёт в Telegram о статусе агентов и РП
#
# Отправляет в Telegram:
# - Статус всех агентов (базовые + нанятые)
# - Рабочие продукты в работе по ролям
# - Занятость агентов

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE_WORKSPACE_SH="$SCRIPT_DIR/resolve-workspace.sh"
eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"

STRATEGY_DIR="$DS_STRATEGY_DIR"
AGENT_WORKSPACE="$DS_AGENT_WORKSPACE_DIR"
STATE_DIR="$HOME/.local/state/exocortex"
LOG_DIR="$HOME/logs/synchronizer"
ENV_FILE="$HOME/.config/aist/env"
LEGACY_TOKEN_FILE="$HOME/.config/exocortex/telegram-token"
LEGACY_CHAT_ID_FILE="$HOME/.config/exocortex/telegram-chat-id"
NOTIFY_SCRIPT="$FMT_EXOCORTEX_DIR/roles/synchronizer/scripts/notify.sh"
DAILY_REPORT_SCRIPT="$FMT_EXOCORTEX_DIR/roles/synchronizer/scripts/daily-report.sh"

mkdir -p "$STATE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [daily-telegram] $1"
}

# Проверить, не запускался ли уже сегодня
TODAY=$(date +%Y-%m-%d)
if [ -f "$STATE_DIR/telegram-report-$TODAY" ]; then
    log "Отчёт уже отправлен сегодня"
    exit 0
fi

# Получить токен и chat_id:
# основной источник — ~/.config/aist/env
# fallback на legacy ~/.config/exocortex/* оставляем на переходный период
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [ -z "$TOKEN" ] && [ -f "$LEGACY_TOKEN_FILE" ]; then
    TOKEN=$(cat "$LEGACY_TOKEN_FILE")
fi

if [ -z "$CHAT_ID" ] && [ -f "$LEGACY_CHAT_ID_FILE" ]; then
    CHAT_ID=$(cat "$LEGACY_CHAT_ID_FILE" 2>/dev/null || echo "")
fi

if [ -z "$TOKEN" ]; then
    log "ERROR: Telegram token не найден ни в ~/.config/aist/env, ни в legacy ~/.config/exocortex/"
    exit 1
fi

if [ -z "$CHAT_ID" ]; then
    log "ERROR: Telegram chat_id не найден ни в ~/.config/aist/env, ни в legacy ~/.config/exocortex/"
    exit 1
fi

# Собрать статус агентов
get_agent_status() {
    local status_file="$STRATEGY_DIR/current/AGENTS-STATUS.md"
    if [ -f "$status_file" ]; then
        grep "🟢\|🟡\|🔴" "$status_file" | head -10
    fi
}

# Собрать РП в работе
get_workplan_status() {
    local wp_file
    wp_file=$(ls -t "$STRATEGY_DIR"/current/WeekPlan\ *.md 2>/dev/null | head -1)
    if [ -n "$wp_file" ] && [ -f "$wp_file" ]; then
        grep "in_progress\|pending" "$wp_file" | wc -l
    else
        echo "0"
    fi
}

# Собрать информацию о нанятых агентах
get_hired_agents() {
    if [ -d "$AGENT_WORKSPACE/agency" ]; then
        ls "$AGENT_WORKSPACE/agency/agents/" 2>/dev/null | wc -l
    else
        echo "0"
    fi
}

# Основной процесс
if [ ! -x "$NOTIFY_SCRIPT" ]; then
    log "ERROR: notify.sh not found or not executable: $NOTIFY_SCRIPT"
    exit 1
fi

if [ ! -x "$DAILY_REPORT_SCRIPT" ]; then
    log "ERROR: daily-report.sh not found or not executable: $DAILY_REPORT_SCRIPT"
    exit 1
fi

log "Refreshing runtime/opening artifacts before Telegram report"
if ! "$DAILY_REPORT_SCRIPT" --refresh-status-artifacts --commit-strategy-artifacts >> "$LOG_DIR/daily-report-$TODAY.log" 2>&1; then
    log "ERROR: failed to refresh runtime/opening artifacts before Telegram send"
    exit 1
fi

if "$NOTIFY_SCRIPT" synchronizer daily-telegram-report >/dev/null 2>&1; then
    log "Отчёт отправлен в Telegram"
    touch "$STATE_DIR/telegram-report-$TODAY"
else
    log "ERROR: Ошибка отправки в Telegram через notify.sh"
    exit 1
fi

exit 0
