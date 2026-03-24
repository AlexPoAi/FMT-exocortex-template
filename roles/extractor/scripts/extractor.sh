#!/bin/bash
# Knowledge Extractor Agent Runner
# Запускает Claude Code с заданным процессом KE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="/Users/alexander/Github"
PROMPTS_DIR="$REPO_DIR/prompts"
LOG_DIR="/Users/alexander/logs/extractor"
ENV_FILE="/Users/alexander/.config/aist/env"
DEFAULT_CLAUDE_PATH="/opt/homebrew/bin/claude"

AI_CLI_PROMPT_FLAG="${AI_CLI_PROMPT_FLAG:--p}"
AI_CLI_MODEL="${AI_CLI_MODEL:-}"
AI_CLI_EXTRA_FLAGS="${AI_CLI_EXTRA_FLAGS:---dangerously-skip-permissions --allowedTools Read,Write,Edit,Glob,Grep,Bash}"

mkdir -p "$LOG_DIR"

DATE=$(date +%Y-%m-%d)
HOUR=$(date +%H)
LOG_FILE="$LOG_DIR/$DATE.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

notify() {
    local title="$1"
    local message="$2"
    printf 'display notification "%s" with title "%s"' "$message" "$title" | osascript 2>/dev/null || true
}

notify_telegram() {
    local scenario="$1"
    local notify_script="$WORKSPACE/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh"
    if [ -f "$notify_script" ]; then
        "$notify_script" extractor "$scenario" >> "$LOG_FILE" 2>&1 || true
    fi
}

load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        source "$ENV_FILE"
        set +a
    fi
}

resolve_claude_path() {
    if [ -n "${AI_CLI:-}" ]; then
        echo "$AI_CLI"
        return
    fi
    if [ -n "${CLAUDE_PATH:-}" ] && [ -x "${CLAUDE_PATH}" ]; then
        echo "$CLAUDE_PATH"
        return
    fi
    if [ -x "$DEFAULT_CLAUDE_PATH" ]; then
        echo "$DEFAULT_CLAUDE_PATH"
        return
    fi
    if command -v claude >/dev/null 2>&1; then
        command -v claude
        return
    fi
    return 1
}

preflight_check() {
    local resolved_cli="$1"

    if [ ! -x "$resolved_cli" ]; then
        log "ERROR: Claude CLI not executable: $resolved_cli"
        return 11
    fi

    if [ ! -f "$HOME/.claude/settings.json" ]; then
        log "ERROR: ~/.claude/settings.json not found"
        return 12
    fi

    if [ ! -f "$HOME/.config/aist/anthropic_auth_helper.sh" ]; then
        log "ERROR: anthropic_auth_helper.sh not found"
        return 13
    fi

    if [ ! -x "$HOME/.config/aist/anthropic_auth_helper.sh" ]; then
        log "ERROR: anthropic_auth_helper.sh is not executable"
        return 14
    fi

    if [ ! -f "$ENV_FILE" ]; then
        log "ERROR: env file not found: $ENV_FILE"
        return 15
    fi

    load_env

    if ! "$HOME/.config/aist/anthropic_auth_helper.sh" >/dev/null 2>&1; then
        log "ERROR: auth helper failed"
        return 16
    fi

    return 0
}

build_claude_args() {
    local args=()

    if [ -n "$AI_CLI_EXTRA_FLAGS" ]; then
        # shellcheck disable=SC2206
        args=($AI_CLI_EXTRA_FLAGS)
    fi

    if [ -n "$AI_CLI_MODEL" ]; then
        args+=(--model "$AI_CLI_MODEL")
    fi

    printf '%s\n' "${args[@]}"
}

run_claude() {
    local command_file="$1"
    local extra_args="${2:-}"
    local command_path="$PROMPTS_DIR/$command_file.md"

    if [ ! -f "$command_path" ]; then
        log "ERROR: Command file not found: $command_path"
        exit 1
    fi

    local resolved_cli
    resolved_cli=$(resolve_claude_path) || {
        log "ERROR: Claude CLI not found"
        notify "🔴 Экзокортекс: Claude CLI не найден" "Extractor/$command_file не может стартовать: claude не найден"
        return 11
    }

    if ! preflight_check "$resolved_cli"; then
        local code=$?
        notify "🔴 Экзокортекс: preflight failed" "Extractor/$command_file не стартовал: проверь helper/env/claude"
        return "$code"
    fi

    local prompt
    prompt=$(cat "$command_path")

    if [ -n "$extra_args" ]; then
        prompt="$prompt

## Дополнительный контекст

$extra_args"
    fi

    local -a claude_args=()
    while IFS= read -r arg; do
        [ -n "$arg" ] && claude_args+=("$arg")
    done < <(build_claude_args)

    log "Starting process: $command_file"
    log "Command file: $command_path"
    log "Claude path: $resolved_cli"

    cd "$WORKSPACE"
    unset CLAUDECODE

    local tmp_out
    tmp_out=$(mktemp)
    set +e
    "$resolved_cli" "${claude_args[@]}" \
        "$AI_CLI_PROMPT_FLAG" "$prompt" \
        > "$tmp_out" 2>&1
    local exit_code=$?
    set -e
    cat "$tmp_out" >> "$LOG_FILE"

    if grep -Eq 'authentication_error|OAuth token has expired|API Error: 401|Failed to authenticate|ANTHROPIC_AUTH_TOKEN is not set' "$tmp_out" 2>/dev/null; then
        log "CRITICAL: Auth failed via helper/env/custom API"
        notify "🔴 Экзокортекс: auth failure" "Агент $command_file упал: проверь ~/.config/aist/env и helper"
        notify_telegram "$command_file"
        rm -f "$tmp_out"
        return 17
    fi
    rm -f "$tmp_out"

    if [ $exit_code -ne 0 ]; then
        log "ERROR: claude exited with code $exit_code for $command_file"
        notify "⚠️ Экзокортекс: ошибка агента" "extractor/$command_file завершился с кодом $exit_code"
        return $exit_code
    fi

    log "Completed process: $command_file"

    local strategy_dir="$WORKSPACE/DS-strategy"
    if [ -d "$strategy_dir/.git" ]; then
        git -C "$strategy_dir" reset --quiet 2>/dev/null || true
        git -C "$strategy_dir" add inbox/captures.md inbox/extraction-reports/ inbox/INBOX-TASKS.md >> "$LOG_FILE" 2>&1 || true
        if ! git -C "$strategy_dir" diff --cached --quiet 2>/dev/null; then
            git -C "$strategy_dir" commit -m "inbox-check: extraction report $DATE" >> "$LOG_FILE" 2>&1 \
                && log "Committed DS-strategy" \
                || log "WARN: git commit failed"
        else
            log "No new changes to commit in DS-strategy"
        fi

        if ! git -C "$strategy_dir" diff --quiet origin/main..HEAD 2>/dev/null; then
            git -C "$strategy_dir" push >> "$LOG_FILE" 2>&1 && log "Pushed DS-strategy" || log "WARN: git push failed"
        fi
    fi

    notify "KE: $command_file" "Процесс завершён"
}

is_work_hours() {
    local hour
    hour=$(date +%H)
    [ "$hour" -ge 7 ] && [ "$hour" -le 23 ]
}

load_env

case "${1:-}" in
    "inbox-check")
        if ! is_work_hours; then
            log "SKIP: inbox-check outside work hours ($HOUR:00)"
            exit 0
        fi

        CAPTURES_FILE="$WORKSPACE/DS-strategy/inbox/captures.md"
        if [ -f "$CAPTURES_FILE" ]; then
            PENDING=$(grep -c '^### ' "$CAPTURES_FILE" 2>/dev/null) || PENDING=0
            PROCESSED=$(grep -c '\[processed' "$CAPTURES_FILE" 2>/dev/null) || PROCESSED=0
            ANALYZED=$(grep -c '\[analyzed' "$CAPTURES_FILE" 2>/dev/null) || ANALYZED=0
            ACTUAL_PENDING=$((PENDING - PROCESSED - ANALYZED))

            if [ "$ACTUAL_PENDING" -le 0 ]; then
                log "SKIP: No pending captures in inbox (total=$PENDING, processed=$PROCESSED, analyzed=$ANALYZED)"
                exit 0
            fi

            log "Found $ACTUAL_PENDING pending captures in inbox"
        else
            log "SKIP: captures.md not found"
            exit 0
        fi

        run_claude "inbox-check"
        notify_telegram "inbox-check"
        ;;
    "audit")
        log "Running knowledge audit"
        run_claude "knowledge-audit"
        notify_telegram "audit"
        ;;
    "session-close")
        log "Running session-close extraction"
        run_claude "session-close"
        ;;
    "session-import")
        log "Running session-import extraction"
        run_claude "session-import"
        notify_telegram "session-import"
        ;;
    "session-tasks")
        log "Running session-tasks extraction"
        run_claude "session-tasks"
        STRATEGY_DIR="$WORKSPACE/DS-strategy"
        if [ -d "$STRATEGY_DIR/.git" ]; then
            git -C "$STRATEGY_DIR" add inbox/INBOX-TASKS.md >> "$LOG_FILE" 2>&1 || true
            if ! git -C "$STRATEGY_DIR" diff --cached --quiet 2>/dev/null; then
                git -C "$STRATEGY_DIR" commit -m "session-tasks: tasks extracted $DATE" >> "$LOG_FILE" 2>&1 \
                    && log "Committed INBOX-TASKS.md" \
                    || log "WARN: git commit failed"
                git -C "$STRATEGY_DIR" push >> "$LOG_FILE" 2>&1 && log "Pushed DS-strategy" || log "WARN: git push failed"
            fi
        fi
        notify_telegram "session-tasks"
        ;;
    "on-demand")
        log "Running on-demand extraction"
        run_claude "on-demand"
        ;;
    "archive-review")
        log "Running archive-review"
        run_claude "archive-review"
        notify_telegram "archive-review"
        ;;
    *)
        echo "Usage: $0 <process>"
        exit 1
        ;;
esac

log "Done"
