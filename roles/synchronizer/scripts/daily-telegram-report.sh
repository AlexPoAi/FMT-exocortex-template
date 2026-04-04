#!/bin/bash
# daily-telegram-report.sh — ежедневный отчёт в Telegram о статусе агентов и РП
#
# Отправляет в Telegram:
# - Статус всех агентов (базовые + нанятые)
# - Рабочие продукты в работе по ролям
# - Занятость агентов

set -euo pipefail

STRATEGY_DIR="$HOME/Github/DS-strategy"
AGENT_WORKSPACE="$HOME/Github/DS-agent-workspace"
STATE_DIR="$HOME/.local/state/exocortex"
LOG_DIR="$HOME/logs/synchronizer"
ENV_FILE="$HOME/.config/aist/env"
LEGACY_TOKEN_FILE="$HOME/.config/exocortex/telegram-token"
LEGACY_CHAT_ID_FILE="$HOME/.config/exocortex/telegram-chat-id"

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

# Построить сообщение
build_message() {
    local msg="📊 *Ежедневный отчёт экзокортекса*\n\n"

    msg+="🤖 *Статус агентов:*\n"
    msg+="$(get_agent_status | sed 's/^/• /')\n\n"

    local wp_count=$(get_workplan_status)
    msg+="📋 *Рабочие продукты:*\n"
    msg+="• В работе: $wp_count\n\n"

    local hired=$(get_hired_agents)
    msg+="👥 *Нанятые агенты:*\n"
    msg+="• Из агентства: $hired\n\n"

    msg+="⏰ *Время:* $(date '+%H:%M')\n"

    echo -e "$msg"
}

# Отправить в Telegram
send_telegram() {
    local msg="$1"

    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$msg" \
        -d "parse_mode=Markdown" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log "Отчёт отправлен в Telegram"
        touch "$STATE_DIR/telegram-report-$TODAY"
        return 0
    else
        log "ERROR: Ошибка отправки в Telegram"
        return 1
    fi
}

# Основной процесс
msg=$(build_message)
send_telegram "$msg"

exit 0
