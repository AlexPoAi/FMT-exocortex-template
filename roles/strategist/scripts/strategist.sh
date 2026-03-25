#!/bin/bash
# Strategist (Стратег) Agent Runner
# Запускает Claude Code с заданным сценарием

set -euo pipefail

# Предотвращаем сон пока скрипт работает (macOS)
if [[ "$(uname)" == "Darwin" ]]; then
    caffeinate -diu -w $$ &
fi

# macOS не имеет GNU timeout — perl fallback
if ! command -v timeout &>/dev/null; then
    timeout() {
        local duration="$1"; shift
        perl -e '
            use POSIX ":sys_wait_h";
            my $timeout = shift @ARGV;
            my $pid = fork();
            if ($pid == 0) { exec @ARGV; die "exec failed: $!"; }
            eval {
                local $SIG{ALRM} = sub { kill "TERM", $pid; die "timeout\n"; };
                alarm $timeout;
                waitpid($pid, 0);
                alarm 0;
            };
            if ($@ && $@ eq "timeout\n") { waitpid($pid, WNOHANG); exit 124; }
            exit ($? >> 8);
        ' "$duration" "$@"
    }
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$HOME/Github/DS-strategy"
PROMPTS_DIR="$REPO_DIR/prompts"
LOG_DIR="$HOME/logs/strategist"
ENV_FILE="$HOME/.config/aist/env"
DEFAULT_CLAUDE_PATH="/opt/homebrew/bin/claude"

AI_CLI_PROMPT_FLAG="${AI_CLI_PROMPT_FLAG:--p}"
AI_CLI_MODEL="${AI_CLI_MODEL:-}"
AI_CLI_EXTRA_FLAGS="${AI_CLI_EXTRA_FLAGS:---dangerously-skip-permissions --allowedTools Read,Write,Edit,Glob,Grep,Bash}"

mkdir -p "$LOG_DIR"

DAY_OF_WEEK=$(date +%u)
DATE=$(date +%Y-%m-%d)
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
    "$HOME/Github/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh" strategist "$scenario" >> "$LOG_FILE" 2>&1 || true
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

fetch_wakatime_data() {
    local mode="$1"
    local fetch_script="$SCRIPT_DIR/fetch-wakatime.sh"
    if [ -x "$fetch_script" ]; then
        "$fetch_script" "$mode" 2>/dev/null || echo "(WakaTime данные недоступны)"
    else
        echo "(fetch-wakatime.sh не найден)"
    fi
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

DAY_CLOSE_TIMEOUT_SECONDS="600"
MORNING_TIMEOUT_SECONDS="1800"
NOTE_REVIEW_TIMEOUT_SECONDS="1800"
WEEK_REVIEW_TIMEOUT_SECONDS="1800"
SESSION_PREP_TIMEOUT_SECONDS="1800"
DAY_PLAN_TIMEOUT_SECONDS="1800"

timeout_for_command() {
    case "$1" in
        day-close) echo "$DAY_CLOSE_TIMEOUT_SECONDS" ;;
        note-review) echo "$NOTE_REVIEW_TIMEOUT_SECONDS" ;;
        week-review) echo "$WEEK_REVIEW_TIMEOUT_SECONDS" ;;
        session-prep) echo "$SESSION_PREP_TIMEOUT_SECONDS" ;;
        day-plan) echo "$DAY_PLAN_TIMEOUT_SECONDS" ;;
        morning) echo "$MORNING_TIMEOUT_SECONDS" ;;
        *) echo "0" ;;
    esac
}

run_claude_with_timeout() {
    local timeout_seconds="$1"
    local output_file="$2"
    local resolved_cli="$3"
    local prompt_flag="$4"
    local prompt_text="$5"
    shift 5

    local -a args=("$@")
    local rc=0

    if [ "$timeout_seconds" -le 0 ]; then
        "$resolved_cli" "${args[@]}" "$prompt_flag" "$prompt_text" >> "$output_file" 2>&1
        return $?
    fi

    timeout "$timeout_seconds" "$resolved_cli" "${args[@]}" "$prompt_flag" "$prompt_text" >> "$output_file" 2>&1 || rc=$?

    if [ $rc -eq 124 ]; then
        echo "TIMEOUT: strategist scenario exceeded ${timeout_seconds}s and was terminated" >> "$output_file"
    fi

    return $rc
}

classify_runtime_failure() {
    local tmp_out="$1"

    if grep -Eq 'authentication_error|OAuth token has expired|API Error: 401|Failed to authenticate|ANTHROPIC_AUTH_TOKEN is not set|invalid_grant' "$tmp_out" 2>/dev/null; then
        echo "auth_failed"
        return
    fi

    if grep -Eq 'insufficient balance|预扣费额度失败|quota|credit balance|billing' "$tmp_out" 2>/dev/null; then
        echo "billing_failed"
        return
    fi

    if grep -Eq 'No available Claude accounts support the requested model|requested model' "$tmp_out" 2>/dev/null; then
        echo "model_unavailable"
        return
    fi

    if grep -Eq 'ECONNRESET|Unable to connect to API|timed out|ENOTFOUND|socket hang up' "$tmp_out" 2>/dev/null; then
        echo "network_failed"
        return
    fi

    if grep -Eq 'TIMEOUT: strategist scenario exceeded|TIMEOUT_WRAPPER_ERROR' "$tmp_out" 2>/dev/null; then
        echo "timed_out"
        return
    fi

    if grep -Eq 'No such file or directory|command not found|Permission denied' "$tmp_out" 2>/dev/null; then
        echo "preflight_failed"
        return
    fi

    echo "failed"
}

failure_notification_text() {
    case "$1" in
        auth_failed) echo "проверь helper, env и refresh токена" ;;
        billing_failed) echo "проверь баланс и квоты API" ;;
        model_unavailable) echo "проверь доступную модель или убери жёсткий --model" ;;
        network_failed) echo "проверь сеть или доступ к API" ;;
        timed_out) echo "сценарий завис или превысил лимит времени" ;;
        preflight_failed) echo "проверь CLI, файлы и права доступа" ;;
        *) echo "проверь лог сценария" ;;
    esac
}

run_claude() {
    local command_file="$1"
    local command_path="$PROMPTS_DIR/$command_file.md"
    local run_started_at run_started_epoch
    run_started_at="$(date '+%Y-%m-%d %H:%M:%S')"
    run_started_epoch=$(date +%s)

    if [ ! -f "$command_path" ]; then
        log "ERROR: Command file not found: $command_path"
        exit 1
    fi

    local resolved_cli
    resolved_cli=$(resolve_claude_path) || {
        log "ERROR: Claude CLI not found"
        notify "🔴 Экзокортекс: Claude CLI не найден" "Strategist/$command_file не может стартовать: claude не найден"
        return 11
    }

    if ! preflight_check "$resolved_cli"; then
        local code=$?
        notify "🔴 Экзокортекс: preflight failed" "Strategist/$command_file не стартовал: проверь helper/env/claude"
        return "$code"
    fi

    local prompt
    prompt=$(cat "$command_path")

    if echo "$prompt" | grep -q '{{WAKATIME_DAY}}'; then
        log "Fetching WakaTime data (day mode)"
        local waka_day
        waka_day=$(fetch_wakatime_data "day")
        prompt="${prompt//\{\{WAKATIME_DAY\}\}/$waka_day}"
    fi
    if echo "$prompt" | grep -q '{{WAKATIME_WEEK}}'; then
        log "Fetching WakaTime data (week mode)"
        local waka_week
        waka_week=$(fetch_wakatime_data "week")
        prompt="${prompt//\{\{WAKATIME_WEEK\}\}/$waka_week}"
    fi

    local tmp_out
    local timeout_seconds
    local run_finished_epoch elapsed_seconds
    local -a claude_args=()
    tmp_out=$(mktemp)
    while IFS= read -r arg; do
        [ -n "$arg" ] && claude_args+=("$arg")
    done < <(build_claude_args)
    timeout_seconds=$(timeout_for_command "$command_file")

    log "Starting scenario: $command_file"
    log "Command file: $command_path"
    log "Claude path: $resolved_cli"
    if [ "$timeout_seconds" -gt 0 ]; then
        log "Runtime budget: ${timeout_seconds}s"
    else
        log "Runtime budget: unlimited"
    fi

    cd "$WORKSPACE"
    unset CLAUDECODE
    set +e
    run_claude_with_timeout "$timeout_seconds" "$tmp_out" "$resolved_cli" "$AI_CLI_PROMPT_FLAG" "$prompt" "${claude_args[@]}"
    local exit_code=$?
    set -e
    cat "$tmp_out" >> "$LOG_FILE"

    local failure_kind=""
    run_finished_epoch=$(date +%s)
    elapsed_seconds=$(( run_finished_epoch - run_started_epoch ))
    if [ $exit_code -ne 0 ]; then
        failure_kind=$(classify_runtime_failure "$tmp_out")
        case "$failure_kind" in
            auth_failed)
                log "CRITICAL: Auth failed via helper/env/custom API"
                ;;
            billing_failed)
                log "CRITICAL: Billing/quota failure while running $command_file"
                ;;
            model_unavailable)
                log "CRITICAL: Requested Claude model unavailable for current account/runtime"
                ;;
            network_failed)
                log "CRITICAL: Network/API connectivity failure while running $command_file"
                ;;
            timed_out)
                log "CRITICAL: Scenario $command_file exceeded time limit (${timeout_seconds}s)"
                ;;
            preflight_failed)
                log "CRITICAL: Preflight/runtime prerequisites failed while running $command_file"
                ;;
        esac
        log "Scenario result: $command_file status=$failure_kind exit_code=$exit_code elapsed=${elapsed_seconds}s started_at=$run_started_at"
        notify "⚠️ Экзокортекс: ошибка агента" "strategist/$command_file: $(failure_notification_text "$failure_kind")"
        notify_telegram "$command_file"
        rm -f "$tmp_out"
        return $exit_code
    fi

    rm -f "$tmp_out"

    log "Completed scenario: $command_file"
    log "Scenario result: $command_file status=success exit_code=0 elapsed=${elapsed_seconds}s started_at=$run_started_at"

    if git -C "$WORKSPACE" diff --quiet origin/main..HEAD 2>/dev/null; then
        log "No unpushed commits"
    else
        git -C "$WORKSPACE" pull --rebase >> "$LOG_FILE" 2>&1 && log "Pulled (rebase)" || log "WARN: pull --rebase failed"
        git -C "$WORKSPACE" push >> "$LOG_FILE" 2>&1 && log "Pushed to GitHub" || log "WARN: git push failed"
    fi

    git -C "$WORKSPACE" reset --quiet 2>/dev/null || true
    log "Cleared staging area after Claude session"

    local summary
    summary=$(tail -5 "$LOG_FILE" | grep -v '^\[' | head -3)
    notify "Стратег: $command_file" "$summary"
}

already_ran_today() {
    local scenario="$1"
    [ -f "$LOG_FILE" ] && grep -q "Completed scenario: $scenario" "$LOG_FILE"
}

LOCK_DIR="$LOG_DIR/locks"
mkdir -p "$LOCK_DIR"

acquire_lock() {
    local scenario="$1"
    local lockfile="$LOCK_DIR/${scenario}.${DATE}.lock"
    if ! mkdir "$lockfile" 2>/dev/null; then
        log "SKIP: $scenario already running (lock exists: $lockfile)"
        exit 2
    fi
    trap "rmdir '$lockfile' 2>/dev/null" EXIT
}

case "${1:-}" in
    "morning")
        if [ "$DAY_OF_WEEK" -eq 1 ]; then
            SCENARIO="session-prep"
        else
            SCENARIO="day-plan"
        fi

        acquire_lock "$SCENARIO"
        if already_ran_today "$SCENARIO"; then
            log "SKIP: $SCENARIO already completed today"
            exit 0
        fi

        if [ "$DAY_OF_WEEK" -eq 1 ]; then
            log "Monday morning: running session prep"
            run_claude "session-prep"
            notify_telegram "session-prep"
        else
            log "Morning: running day plan"
            run_claude "day-plan"
            notify_telegram "day-plan"
        fi
        ;;
    "evening")
        log "Evening: running evening review"
        run_claude "evening"
        notify_telegram "evening"
        ;;
    "week-review")
        log "Sunday: running week review"
        run_claude "week-review"
        KI_REPO="$HOME/Github/DS-Knowledge-Index-alexander"
        if [ -d "$KI_REPO/.git" ]; then
            if git -C "$KI_REPO" log --oneline -1 --since="1 hour ago" --grep="week-review" 2>/dev/null | grep -q .; then
                git -C "$KI_REPO" push >> "$LOG_FILE" 2>&1 && log "Pushed Knowledge Index (fallback)" || log "WARN: KI push failed"
            fi
        fi
        notify_telegram "week-review"
        ;;
    "session-prep")
        log "Manual: running session prep"
        run_claude "session-prep"
        notify_telegram "session-prep"
        ;;
    "day-plan")
        log "Manual: running day plan"
        run_claude "day-plan"
        notify_telegram "day-plan"
        ;;
    "note-review")
        acquire_lock "note-review"
        log "Evening: running note review"
        FLEETING="$WORKSPACE/inbox/fleeting-notes.md"
        BOLD_BEFORE=$(grep -c '^\*\*' "$FLEETING" 2>/dev/null || echo 0)
        log "Canary: $BOLD_BEFORE bold notes before note-review"

        run_claude "note-review"

        BOLD_AFTER=$(grep -c '^\*\*' "$FLEETING" 2>/dev/null || echo 0)
        log "Canary: $BOLD_AFTER"
        NON_BOLD=$(grep -c '^[^*#>-]' "$FLEETING" 2>/dev/null || echo 0)
        log "Non-bold content lines: $NON_BOLD"
        if [ "$BOLD_AFTER" -ge "$BOLD_BEFORE" ] && [ "$BOLD_BEFORE" -gt 0 ]; then
            log "WARN: Note-Review Step 10 may have failed — bold notes did not decrease ($BOLD_BEFORE → $BOLD_AFTER)"
        fi

        log "Running deterministic cleanup..."
        CLEANUP_OUTPUT=$(bash "$SCRIPT_DIR/cleanup-processed-notes.sh" 2>&1) || true
        log "Cleanup: $CLEANUP_OUTPUT"

        if ! git -C "$WORKSPACE" diff --quiet -- inbox/fleeting-notes.md archive/notes/Notes-Archive.md 2>/dev/null; then
            git -C "$WORKSPACE" add inbox/fleeting-notes.md archive/notes/Notes-Archive.md
            git -C "$WORKSPACE" commit -m "chore: auto-cleanup processed notes from fleeting-notes.md" >> "$LOG_FILE" 2>&1 || true
            git -C "$WORKSPACE" pull --rebase >> "$LOG_FILE" 2>&1 && log "Cleanup: pulled (rebase)" || log "WARN: cleanup pull --rebase failed"
            git -C "$WORKSPACE" push >> "$LOG_FILE" 2>&1 && log "Cleanup: pushed" || log "WARN: cleanup push failed"
        else
            log "Cleanup: no changes to commit"
        fi

        if [ "$BOLD_AFTER" -ge "$BOLD_BEFORE" ] && [ "$BOLD_BEFORE" -gt 0 ]; then
            load_env
            if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
                ALERT_TEXT="⚠️ <b>Note-Review canary</b>: Step 10 не сработал ($BOLD_BEFORE → $BOLD_AFTER bold). Deterministic cleanup applied."
                ALERT_JSON=$(printf '%s' "$ALERT_TEXT" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
                ALERT_JSON="\"${ALERT_JSON}\""
                curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -H "Content-Type: application/json" \
                    -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":${ALERT_JSON},\"parse_mode\":\"HTML\"}" >> "$LOG_FILE" 2>&1 || true
            fi
        fi

        notify_telegram "note-review"
        ;;
    "day-close")
        acquire_lock "day-close"
        log "Manual: running day close"
        run_claude "day-close"
        notify_telegram "day-close"
        ;;
    "strategy-session")
        log "Manual: running strategy session (interactive)"
        run_claude "strategy-session"
        ;;
    *)
        echo "Usage: $0 {morning|note-review|week-review|session-prep|strategy-session|day-plan|day-close}"
        exit 1
        ;;
esac

log "Done"
