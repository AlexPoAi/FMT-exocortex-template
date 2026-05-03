#!/bin/bash
# Pull Telegram captures from GitHub before local Strategist/Extractor read them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE_WORKSPACE_SH="$SCRIPT_DIR/resolve-workspace.sh"

if [ -f "$RESOLVE_WORKSPACE_SH" ]; then
    eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"
fi

WORKSPACE_ROOT="${1:-${WORKSPACE_DIR:-${IWE_WORKSPACE:-$HOME/Github}}}"
STRATEGY_DIR="${DS_STRATEGY_LOCAL_PATH:-$WORKSPACE_ROOT/DS-strategy}"
CAPTURES_FILE="$STRATEGY_DIR/inbox/captures.md"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/exocortex}"
LOCK_DIR="$STATE_DIR/locks"
LOCK_PATH="$LOCK_DIR/telegram-captures-sync.lock"
LOG_FILE="${TELEGRAM_CAPTURES_SYNC_LOG_FILE:-$HOME/logs/synchronizer/telegram-captures-sync-$(date +%Y-%m-%d).log}"

mkdir -p "$(dirname "$LOG_FILE")" "$LOCK_DIR"

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [telegram-captures-sync] $1"
    printf '%s\n' "$line" >> "$LOG_FILE"
    if [ "${TELEGRAM_CAPTURES_SYNC_QUIET:-0}" != "1" ]; then
        printf '%s\n' "$line"
    fi
}

acquire_lock() {
    local waited=0

    while ! mkdir "$LOCK_PATH" 2>/dev/null; do
        if [ ! -e "$LOCK_PATH" ]; then
            log "ERROR: cannot create sync lock: $LOCK_PATH"
            return 76
        fi

        local existing_pid=""
        if [ -f "$LOCK_PATH/pid" ]; then
            existing_pid="$(cat "$LOCK_PATH/pid" 2>/dev/null || true)"
        fi

        if [ -n "$existing_pid" ] && ! kill -0 "$existing_pid" 2>/dev/null; then
            rm -rf "$LOCK_PATH"
            continue
        fi

        if [ "$waited" -ge 60 ]; then
            log "ERROR: sync lock is busy >60s${existing_pid:+ (pid=$existing_pid)}"
            return 75
        fi

        sleep 1
        waited=$((waited + 1))
    done

    printf '%s\n' "$$" > "$LOCK_PATH/pid"
    trap 'rm -rf "$LOCK_PATH"' EXIT
}

if [ "${TELEGRAM_CAPTURES_PRE_SYNC:-1}" = "0" ]; then
    log "SKIP: disabled by TELEGRAM_CAPTURES_PRE_SYNC=0"
    exit 0
fi

if [ ! -d "$STRATEGY_DIR/.git" ]; then
    log "ERROR: DS-strategy git repo not found: $STRATEGY_DIR"
    exit 20
fi

acquire_lock

before_head="$(git -C "$STRATEGY_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
log "pull --rebase --autostash origin/main for $STRATEGY_DIR (before=$before_head)"

if ! git -C "$STRATEGY_DIR" pull --rebase --autostash origin main >> "$LOG_FILE" 2>&1; then
    conflicts="$(git -C "$STRATEGY_DIR" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ' || true)"
    log "ERROR: DS-strategy pull failed${conflicts:+; conflicts: $conflicts}"
    exit 21
fi

after_head="$(git -C "$STRATEGY_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

if [ ! -f "$CAPTURES_FILE" ]; then
    log "ERROR: captures file missing after sync: $CAPTURES_FILE"
    exit 22
fi

capture_headers="$(grep -E '^### ' "$CAPTURES_FILE" 2>/dev/null | grep -vE '^### \[Название знания\]$' || true)"
total_captures="$(printf '%s\n' "$capture_headers" | sed '/^$/d' | wc -l | tr -d ' ')"
pending_captures="$(printf '%s\n' "$capture_headers" | grep -vE '\[(analyzed|processed|duplicate|defer|rejected)([][:space:]]|$)' | sed '/^$/d' | wc -l | tr -d ' ')"

log "OK: DS-strategy synced (after=$after_head, total=$total_captures, pending=$pending_captures)"
