#!/usr/bin/env bash
# setup-vps-agent-runtime.sh — installs Exocortex scheduler runtime on Linux VPS (systemd)

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "❌ Этот скрипт предназначен только для Linux VPS (systemd)."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/systemd"

WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/Github}"
TARGET_USER="${TARGET_USER:-$USER}"
INTERVAL_MINUTES="${INTERVAL_MINUTES:-15}"
SYSTEMD_DIR="/etc/systemd/system"
ENV_FILE="/etc/default/exocortex-scheduler"
SERVICE_NAME="com.exocortex.scheduler.service"
TIMER_NAME="com.exocortex.scheduler.timer"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        --user)
            TARGET_USER="$2"
            shift 2
            ;;
        --interval-minutes)
            INTERVAL_MINUTES="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--workspace /path] [--user username] [--interval-minutes 15]"
            exit 1
            ;;
    esac
done

if ! [[ "$INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || [ "$INTERVAL_MINUTES" -lt 5 ]; then
    echo "❌ --interval-minutes должен быть числом >= 5"
    exit 1
fi

if [ ! -d "$WORKSPACE_DIR/FMT-exocortex-template" ]; then
    echo "❌ Не найдено: $WORKSPACE_DIR/FMT-exocortex-template"
    exit 1
fi

if [ ! -d "$WORKSPACE_DIR/DS-strategy" ]; then
    echo "❌ Не найдено: $WORKSPACE_DIR/DS-strategy"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "❌ systemctl не найден. Нужен systemd."
    exit 1
fi

if [ ! -f "$TEMPLATE_DIR/$SERVICE_NAME.template" ] || [ ! -f "$TEMPLATE_DIR/$TIMER_NAME.template" ]; then
    echo "❌ Не найдены template-файлы systemd в $TEMPLATE_DIR"
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    echo "❌ sudo не найден. Установи sudo или запусти установку вручную от root."
    exit 1
fi

TMP_SERVICE="$(mktemp)"
TMP_TIMER="$(mktemp)"

sed \
    -e "s|{{USER}}|$TARGET_USER|g" \
    -e "s|{{WORKSPACE_DIR}}|$WORKSPACE_DIR|g" \
    "$TEMPLATE_DIR/$SERVICE_NAME.template" > "$TMP_SERVICE"

sed \
    -e "s|{{INTERVAL_MINUTES}}|$INTERVAL_MINUTES|g" \
    "$TEMPLATE_DIR/$TIMER_NAME.template" > "$TMP_TIMER"

echo "Installing systemd units..."
sudo cp "$TMP_SERVICE" "$SYSTEMD_DIR/$SERVICE_NAME"
sudo cp "$TMP_TIMER" "$SYSTEMD_DIR/$TIMER_NAME"

rm -f "$TMP_SERVICE" "$TMP_TIMER"

if sudo test ! -f "$ENV_FILE"; then
    sudo tee "$ENV_FILE" >/dev/null <<EOF
WORKSPACE_DIR=$WORKSPACE_DIR
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EXOCORTEX_RUNTIME_TARGET=vps
EXOCORTEX_DISABLE_LOCAL_DISPATCH=0
EOF
    echo "Created $ENV_FILE"
else
    echo "Keeping existing $ENV_FILE"
fi

echo "Reloading systemd..."
sudo systemctl daemon-reload
sudo systemctl enable --now "$TIMER_NAME"

echo ""
echo "✅ VPS runtime installed"
echo "Service: $SERVICE_NAME"
echo "Timer:   $TIMER_NAME (every ${INTERVAL_MINUTES}m)"
echo ""
echo "Check:"
echo "  sudo systemctl status $TIMER_NAME --no-pager"
echo "  sudo systemctl list-timers | grep com.exocortex.scheduler"
echo ""
echo "Manual run:"
echo "  sudo systemctl start $SERVICE_NAME"
