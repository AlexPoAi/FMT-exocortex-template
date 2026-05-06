#!/bin/bash
# Extractor: установка launchd-агентов inbox-check + session-watcher
# inbox-check: каждые 3 часа
# session-watcher: каждые 5 минут
# WP-273 Этап 2: plist берётся из $IWE_RUNTIME (Generated runtime, F).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLE_NAME="$(basename "$SCRIPT_DIR")"
PLIST_DIR="$HOME/Library/LaunchAgents"

# Resolve PLIST source (Generated runtime → workspace fallback → FMT legacy)
if [ -n "${IWE_RUNTIME:-}" ] && [ -d "$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd" ]; then
    PLIST_SRC_DIR="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd"
    EXTRACTOR_TARGET="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/extractor.sh"
WATCHER_TARGET="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/session-watcher.sh"
    INTAKE_TARGET="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/obsidian-fleeting-intake.sh"
elif [ -n "${IWE_WORKSPACE:-}" ] && [ -d "$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd" ]; then
    PLIST_SRC_DIR="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd"
    EXTRACTOR_TARGET="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/extractor.sh"
    WATCHER_TARGET="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/session-watcher.sh"
    INTAKE_TARGET="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/obsidian-fleeting-intake.sh"
else
    PLIST_SRC_DIR="$SCRIPT_DIR/scripts/launchd"
    EXTRACTOR_TARGET="$SCRIPT_DIR/scripts/extractor.sh"
    WATCHER_TARGET="$SCRIPT_DIR/scripts/session-watcher.sh"
    INTAKE_TARGET="$SCRIPT_DIR/scripts/obsidian-fleeting-intake.sh"
    echo "  ⚠ Legacy mode: используются плейсхолдеры из FMT-substituted (запустите setup.sh ≥0.29.0 для архитектуры F)"
fi

install_agent() {
    local label="$1"
    local plist_name="$2"
    local plist_src="$PLIST_SRC_DIR/$plist_name"
    local plist_dst="$PLIST_DIR/$plist_name"

    echo "Installing $label..."
    echo "  PLIST_SRC: $plist_src"

    if [ ! -f "$plist_src" ]; then
        echo "ERROR: $plist_src not found"
        exit 1
    fi

    if grep -qE '\{\{[A-Z_]+\}\}' "$plist_src" 2>/dev/null; then
        echo "ERROR: $plist_src содержит незаменённые плейсхолдеры:" >&2
        grep -oE '\{\{[A-Z_]+\}\}' "$plist_src" | sort -u | sed 's/^/  /' >&2
        echo "" >&2
        echo "Возможные причины:" >&2
        echo "  1. IWE_RUNTIME не экспортирован → 'source ~/.zshenv' или 'source ~/.iwe-paths'" >&2
        echo "  2. .iwe-runtime/ ещё не создан → 'bash \$IWE_TEMPLATE/setup/build-runtime.sh'" >&2
        echo "  3. Старый clone до WP-273 Этап 2 → 'bash \$IWE_TEMPLATE/scripts/migrate-to-runtime-target.sh'" >&2
        exit 2
    fi

    launchctl unload "$plist_dst" 2>/dev/null || true
    cp "$plist_src" "$plist_dst"
    launchctl load "$plist_dst"
}

# Делаем скрипты исполняемыми (runtime path)
if [ -f "$EXTRACTOR_TARGET" ]; then
    chmod +x "$EXTRACTOR_TARGET"
fi
if [ -f "$WATCHER_TARGET" ]; then
    chmod +x "$WATCHER_TARGET"
fi
if [ -f "$INTAKE_TARGET" ]; then
    chmod +x "$INTAKE_TARGET"
fi

install_agent "Extractor launchd agent (inbox-check)" "com.extractor.inbox-check.plist"
install_agent "Extractor launchd agent (session-watcher)" "com.extractor.session-watcher.plist"
install_agent "Extractor launchd agent (obsidian-fleeting-intake)" "com.extractor.obsidian-fleeting-intake.plist"

echo "  ✓ Installed: com.extractor.inbox-check"
echo "  ✓ Installed: com.extractor.session-watcher"
echo "  ✓ Installed: com.extractor.obsidian-fleeting-intake"
echo "  ✓ Inbox interval: every 3 hours"
echo "  ✓ Watcher interval: every 5 minutes"
echo "  ✓ Obsidian fleeting intake interval: every 24 hours + on load"
echo "  ✓ Logs: ~/logs/extractor/"
echo ""
echo "Verify: launchctl list | grep extractor"
echo "Uninstall: launchctl unload $PLIST_DIR/com.extractor.inbox-check.plist && rm $PLIST_DIR/com.extractor.inbox-check.plist"
