#!/bin/bash
# notify.sh — единый dispatch уведомлений экзокортекса
#
# Использование:
#   notify.sh <agent> <scenario>
#
# Примеры:
#   notify.sh strategist day-plan
#   notify.sh extractor inbox-check
#
# Шаблоны: templates/<agent>.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
ENV_FILE="$HOME/.config/aist/env"
RESOLVE_WORKSPACE_SH="$SCRIPT_DIR/resolve-workspace.sh"

if [ -x "$RESOLVE_WORKSPACE_SH" ]; then
    eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"
fi

AVAILABLE=$(ls "$TEMPLATES_DIR"/*.sh 2>/dev/null | xargs -I{} basename {} .sh | tr '\n' '|' | sed 's/|$//')
AGENT="${1:?Ошибка: укажи агента (${AVAILABLE:-нет шаблонов})}"
SCENARIO="${2:?Ошибка: укажи сценарий}"

# Загрузка env
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Проверка env vars
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "SKIP: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set (configure ~/.config/aist/env)"
    exit 0
fi

# Отправка в Telegram
send_telegram() {
    local text="$1"
    local buttons="${2:-[]}"

    text="${text:0:4000}"

    local escaped_text
    escaped_text=$(printf '%s' "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

    local json_body
    if [ "$buttons" = "[]" ]; then
        json_body=$(printf '{"chat_id":"%s","text":%s,"parse_mode":"HTML","disable_web_page_preview":true}' \
            "$TELEGRAM_CHAT_ID" "$escaped_text")
    else
        json_body=$(printf '{"chat_id":"%s","text":%s,"parse_mode":"HTML","disable_web_page_preview":true,"reply_markup":{"inline_keyboard":%s}}' \
            "$TELEGRAM_CHAT_ID" "$escaped_text" "$buttons")
    fi

    local response
    local curl_proxy_args=()
    if [ -n "${TELEGRAM_PROXY:-}" ]; then
        curl_proxy_args=(--proxy "$TELEGRAM_PROXY")
    elif [ -n "${ALL_PROXY:-}" ]; then
        curl_proxy_args=(--proxy "$ALL_PROXY")
    fi

    response=$(curl -s "${curl_proxy_args[@]}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$json_body")

    local ok
    ok=$(echo "$response" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("ok",""))' 2>/dev/null || echo "")

    if [ "$ok" = "True" ]; then
        echo "Telegram notification sent: $AGENT/$SCENARIO"
    else
        # Fallback: retry without parse_mode to avoid HTML parser failures
        # (e.g. "Bad Request: can't parse entities").
        local json_body_plain
        if [ "$buttons" = "[]" ]; then
            json_body_plain=$(printf '{"chat_id":"%s","text":%s,"disable_web_page_preview":true}' \
                "$TELEGRAM_CHAT_ID" "$escaped_text")
        else
            json_body_plain=$(printf '{"chat_id":"%s","text":%s,"disable_web_page_preview":true,"reply_markup":{"inline_keyboard":%s}}' \
                "$TELEGRAM_CHAT_ID" "$escaped_text" "$buttons")
        fi

        local response_plain
        response_plain=$(curl -s "${curl_proxy_args[@]}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$json_body_plain")

        local ok_plain
        ok_plain=$(echo "$response_plain" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("ok",""))' 2>/dev/null || echo "")

        if [ "$ok_plain" = "True" ]; then
            echo "Telegram notification sent (plain fallback): $AGENT/$SCENARIO"
        else
            echo "Telegram send FAILED: $AGENT/$SCENARIO"
            echo "Response (html): $response"
            echo "Response (plain): $response_plain"
        fi
    fi
}

# Загружаем шаблон агента
TEMPLATE="$TEMPLATES_DIR/$AGENT.sh"
if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template not found: $TEMPLATE" >&2
    exit 1
fi

rendered_template="$TEMPLATE"
if grep -qE '\{\{[A-Z_]+\}\}' "$TEMPLATE" 2>/dev/null; then
    tmp_template=$(mktemp)

    workspace_val="${WORKSPACE_DIR:-$HOME/Github}"
    home_val="${HOME_DIR:-$HOME}"
    gov_repo_val="${IWE_GOVERNANCE_REPO:-DS-strategy}"
    iwe_template_val="${IWE_TEMPLATE:-$workspace_val/FMT-exocortex-template}"
    iwe_runtime_val="${IWE_RUNTIME:-$workspace_val/.iwe-runtime}"
    github_user_val="${GITHUB_USER:-AlexPoAi}"
    claude_slug_val="${CLAUDE_PROJECT_SLUG:-$(echo "$workspace_val" | tr '/' '-')}"

    esc() { printf '%s' "$1" | sed 's/[&|]/\\&/g'; }

    sed \
        -e "s|{{WORKSPACE_DIR}}|$(esc "$workspace_val")|g" \
        -e "s|{{HOME_DIR}}|$(esc "$home_val")|g" \
        -e "s|{{GOVERNANCE_REPO}}|$(esc "$gov_repo_val")|g" \
        -e "s|{{IWE_TEMPLATE}}|$(esc "$iwe_template_val")|g" \
        -e "s|{{IWE_RUNTIME}}|$(esc "$iwe_runtime_val")|g" \
        -e "s|{{GITHUB_USER}}|$(esc "$github_user_val")|g" \
        -e "s|{{CLAUDE_PROJECT_SLUG}}|$(esc "$claude_slug_val")|g" \
        "$TEMPLATE" > "$tmp_template"

    rendered_template="$tmp_template"
fi

source "$rendered_template"
[ "$rendered_template" != "$TEMPLATE" ] && rm -f "$rendered_template"

MESSAGE=$(build_message "$SCENARIO")
BUTTONS=$(build_buttons "$SCENARIO" 2>/dev/null || echo "[]")

if [ -n "$MESSAGE" ]; then
    send_telegram "$MESSAGE" "$BUTTONS"
else
    echo "Empty message for $AGENT/$SCENARIO, skip"
fi
