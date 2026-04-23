#!/bin/bash
# send-telegram.sh — простой transport-скрипт для отправки текста и медиа в Telegram
#
# Примеры:
#   send-telegram.sh text "Привет"
#   send-telegram.sh photo /path/to/file.png "Подпись"
#   send-telegram.sh document /path/to/file.pdf "Документ"

set -euo pipefail

ENV_FILE="${HOME}/.config/aist/env"

usage() {
    cat <<'EOF'
Usage:
  send-telegram.sh text "<message>"
  send-telegram.sh photo <file_path> ["caption"]
  send-telegram.sh document <file_path> ["caption"]
EOF
}

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
THREAD_ID="${TELEGRAM_MESSAGE_THREAD_ID:-}"

if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID missing in $ENV_FILE" >&2
    exit 1
fi

MODE="${1:-}"
if [ -z "$MODE" ]; then
    usage >&2
    exit 1
fi
shift || true

send_text() {
    local text="${1:-}"
    if [ -z "$text" ]; then
        echo "ERROR: text message is required" >&2
        exit 1
    fi

    local escaped_text
    escaped_text=$(printf '%s' "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

    local payload
    if [ -n "$THREAD_ID" ]; then
        payload=$(printf '{"chat_id":"%s","message_thread_id":%s,"text":%s,"parse_mode":"HTML","disable_web_page_preview":true}' \
            "$CHAT_ID" "$THREAD_ID" "$escaped_text")
    else
        payload=$(printf '{"chat_id":"%s","text":%s,"parse_mode":"HTML","disable_web_page_preview":true}' \
            "$CHAT_ID" "$escaped_text")
    fi

    curl -fsS -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload"
}

send_media() {
    local endpoint="$1"
    local field_name="$2"
    local file_path="${3:-}"
    local caption="${4:-}"

    if [ -z "$file_path" ]; then
        echo "ERROR: file path is required" >&2
        exit 1
    fi

    if [ ! -f "$file_path" ]; then
        echo "ERROR: file not found: $file_path" >&2
        exit 1
    fi

    local curl_args=(
        -fsS
        -X POST "https://api.telegram.org/bot${TOKEN}/${endpoint}"
        -F "chat_id=${CHAT_ID}"
        -F "${field_name}=@${file_path}"
    )

    if [ -n "$THREAD_ID" ]; then
        curl_args+=(-F "message_thread_id=${THREAD_ID}")
    fi

    if [ -n "$caption" ]; then
        curl_args+=(-F "caption=${caption}")
    fi

    curl "${curl_args[@]}"
}

case "$MODE" in
    text)
        send_text "${1:-}"
        ;;
    photo)
        send_media "sendPhoto" "photo" "${1:-}" "${2:-}"
        ;;
    document)
        send_media "sendDocument" "document" "${1:-}" "${2:-}"
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
