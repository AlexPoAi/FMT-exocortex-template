#!/bin/bash
# Knowledge Extractor Agent Runner
# Запускает AI CLI provider с заданным процессом KE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
RESOLVE_WORKSPACE_SH="$HOME/Github/FMT-exocortex-template/roles/synchronizer/scripts/resolve-workspace.sh"
if [ ! -x "$RESOLVE_WORKSPACE_SH" ]; then
    RESOLVE_WORKSPACE_SH="$(cd "$SCRIPT_DIR/../../synchronizer/scripts" && pwd)/resolve-workspace.sh"
fi
eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"
WORKSPACE_ROOT="$WORKSPACE_DIR"
WORKSPACE="$WORKSPACE_ROOT"
PROMPTS_DIR="$REPO_DIR/prompts"
LOG_DIR="$HOME/logs/extractor"
STATE_DIR="$HOME/.local/state/exocortex"
LOCK_DIR="$STATE_DIR/locks"
STATUS_DIR="$STATE_DIR/status"
ENV_FILE="$HOME/.config/aist/env"
DEFAULT_CLAUDE_PATH="${CLAUDE_PATH:-$(command -v claude 2>/dev/null || echo /usr/local/bin/claude)}"

AI_CLI_PROMPT_FLAG="${AI_CLI_PROMPT_FLAG:--p}"
AI_CLI_MODEL="${AI_CLI_MODEL:-}"
AI_CLI_PRIMARY_MODEL="${AI_CLI_PRIMARY_MODEL:-${AI_CLI_MODEL:-claude-haiku-4-5}}"
AI_CLI_FALLBACK_MODEL="${AI_CLI_FALLBACK_MODEL:-claude-sonnet-4-6}"
AI_CLI_PROVIDER_PRIMARY="${AI_CLI_PROVIDER_PRIMARY:-auto}"
AI_CLI_PROVIDER_FALLBACK="${AI_CLI_PROVIDER_FALLBACK:-codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.4}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-1200}"
AI_CLI_EXTRA_FLAGS="${AI_CLI_EXTRA_FLAGS:-}"
if [ -z "$AI_CLI_EXTRA_FLAGS" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        AI_CLI_EXTRA_FLAGS="--allowedTools Read,Write,Edit,Glob,Grep,Bash"
    else
        AI_CLI_EXTRA_FLAGS="--dangerously-skip-permissions --allowedTools Read,Write,Edit,Glob,Grep,Bash"
    fi
fi
RUNTIME_ARBITER_PATH="$FMT_EXOCORTEX_DIR/roles/synchronizer/scripts/runtime-arbiter.sh"

mkdir -p "$LOG_DIR"
mkdir -p "$LOCK_DIR"
mkdir -p "$STATUS_DIR"

DATE=$(date +%Y-%m-%d)
HOUR=$(date +%H)
LOG_FILE="$LOG_DIR/$DATE.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

acquire_lock() {
    local lock_name="$1"
    local lock_path="$LOCK_DIR/$lock_name.lock"

    if mkdir "$lock_path" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_path/pid"
        EXTRACTOR_ACTIVE_LOCK_PATH="$lock_path"
        trap 'if [ -n "${EXTRACTOR_ACTIVE_LOCK_PATH:-}" ]; then rm -rf "$EXTRACTOR_ACTIVE_LOCK_PATH"; fi' EXIT
        return 0
    fi

    local existing_pid=""
    if [ -f "$lock_path/pid" ]; then
        existing_pid=$(cat "$lock_path/pid" 2>/dev/null || true)
    fi

    if [ -n "$existing_pid" ] && ! kill -0 "$existing_pid" 2>/dev/null; then
        rm -rf "$lock_path"
        if mkdir "$lock_path" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_path/pid"
            EXTRACTOR_ACTIVE_LOCK_PATH="$lock_path"
            trap 'if [ -n "${EXTRACTOR_ACTIVE_LOCK_PATH:-}" ]; then rm -rf "$EXTRACTOR_ACTIVE_LOCK_PATH"; fi' EXIT
            log "WARN: removed stale extractor lock $lock_name (pid=$existing_pid)"
            return 0
        fi
    fi

    log "SKIP: $lock_name already running${existing_pid:+ (pid=$existing_pid)}"
    return 1
}

# macOS не имеет GNU timeout — используем perl fallback
if ! command -v timeout >/dev/null 2>&1; then
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

notify() {
    local title="$1"
    local message="$2"
    # macOS: osascript, Linux: notify-send, fallback: silent
    printf 'display notification "%s" with title "%s"' "$message" "$title" | osascript 2>/dev/null \
        || notify-send "$title" "$message" 2>/dev/null \
        || true
}

notify_telegram() {
    local scenario="$1"
    local notify_script="$WORKSPACE/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh"
    if [ -f "$notify_script" ]; then
        "$notify_script" extractor "$scenario" >> "$LOG_FILE" 2>&1 || true
    fi
}

shell_quote() {
    python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "${1:-}"
}

write_status_artifact() {
    local task="$1"
    local status="$2"
    local exit_code="$3"
    local summary="${4:-}"
    local evidence_status="${5:-reported}"
    local evidence_summary="${6:-reported by extractor runner}"
    local error_summary="${7:-}"
    local completed_window="${8:-false}"
    local status_file previous_last_success previous_last_failure now_ts run_id

    [ -n "$task" ] || return 0

    status_file="$STATUS_DIR/${task}.status"
    previous_last_success=""
    previous_last_failure=""

    if [ -f "$status_file" ]; then
        # shellcheck disable=SC1090
        source "$status_file"
        previous_last_success="${LAST_SUCCESS_AT:-}"
        previous_last_failure="${LAST_FAILURE_AT:-}"
    fi

    now_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    run_id="$(date '+%Y%m%d-%H%M%S')-$$"

    if [ "$status" = "success" ]; then
        previous_last_success="$now_ts"
    fi

    if [ "$status" = "failed" ] || [ "$status" = "timeout" ] || [ "$status" = "auth_failed" ]; then
        previous_last_failure="$now_ts"
    fi

    cat > "$status_file" <<EOF
TASK_NAME=$(shell_quote "$task")
RUN_ID=$(shell_quote "$run_id")
STATUS=$(shell_quote "$status")
EXIT_CODE=$(shell_quote "$exit_code")
SUMMARY=$(shell_quote "$summary")
START_TS=$(shell_quote "${SCENARIO_STARTED_AT:-$now_ts}")
END_TS=$(shell_quote "$now_ts")
LAST_STARTED_AT=$(shell_quote "${SCENARIO_STARTED_AT:-$now_ts}")
LAST_FINISHED_AT=$(shell_quote "$now_ts")
LAST_SUCCESS_AT=$(shell_quote "$previous_last_success")
LAST_FAILURE_AT=$(shell_quote "$previous_last_failure")
EVIDENCE_STATUS=$(shell_quote "$evidence_status")
EVIDENCE_SUMMARY=$(shell_quote "$evidence_summary")
ERROR_SUMMARY=$(shell_quote "$error_summary")
STALENESS_BUDGET_SEC="10800"
PRODUCED_ARTIFACTS=""
COMPLETED_WINDOW=$(shell_quote "$completed_window")
LOG_PATH=$(shell_quote "$LOG_FILE")
UPDATED_AT=$(shell_quote "$now_ts")
EOF
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

resolve_codex_path() {
    local candidate

    if [ -n "${CODEX_PATH:-}" ] && [ -x "${CODEX_PATH:-}" ]; then
        printf '%s\n' "$CODEX_PATH"
        return 0
    fi

    candidate=$(command -v codex 2>/dev/null || true)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    for candidate in \
        "/Applications/Codex.app/Contents/Resources/codex" \
        "/usr/local/bin/codex" \
        "/opt/homebrew/bin/codex" \
        "$HOME/.local/bin/codex"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    candidate=$(find "$HOME/.vscode/extensions" -maxdepth 5 -type f -name codex 2>/dev/null | sort | tail -n 1)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

has_codex_fallback() {
    [ "${AI_CLI_PROVIDER_FALLBACK}" = "codex" ] && resolve_codex_path >/dev/null 2>&1
}

uses_codex_as_primary() {
    [ "${AI_CLI_PROVIDER_PRIMARY}" = "codex" ] && resolve_codex_path >/dev/null 2>&1
}

resolve_provider_primary_choice() {
    if [ "${AI_CLI_PROVIDER_PRIMARY}" != "auto" ]; then
        printf '%s\n' "$AI_CLI_PROVIDER_PRIMARY"
        return
    fi

    if [ -x "$RUNTIME_ARBITER_PATH" ]; then
        # shellcheck disable=SC1090
        source <(bash "$RUNTIME_ARBITER_PATH" --env)
        if [ -n "${AI_CLI_PROVIDER_PRIMARY_RESOLVED:-}" ] && [ "$AI_CLI_PROVIDER_PRIMARY_RESOLVED" != "unavailable" ]; then
            printf '%s\n' "$AI_CLI_PROVIDER_PRIMARY_RESOLVED"
            return
        fi
    fi

    if resolve_claude_path >/dev/null 2>&1; then
        printf '%s\n' "claude"
    elif resolve_codex_path >/dev/null 2>&1; then
        printf '%s\n' "codex"
    else
        printf '%s\n' "claude"
    fi
}

preflight_check() {
    local resolved_cli="$1"

    if [ ! -x "$resolved_cli" ]; then
        log "ERROR: Claude-compatible CLI not executable: $resolved_cli"
        return 11
    fi

    if [ ! -f "$HOME/.claude/settings.json" ]; then
        log "ERROR: ~/.claude/settings.json not found"
        return 12
    fi

    if [ ! -f "$ENV_FILE" ]; then
        log "ERROR: env file not found: $ENV_FILE"
        return 15
    fi

    load_env

    if ! "$resolved_cli" auth status >/tmp/extractor-auth-status.log 2>&1; then
        log "ERROR: claude auth status failed"
        return 16
    fi

    if ! grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true' /tmp/extractor-auth-status.log 2>/dev/null; then
        log "ERROR: Claude auth is not logged in"
        return 17
    fi

    return 0
}

claude_reauth_hint() {
    local cli_name
    cli_name=$(basename "${CLAUDE_PATH:-$DEFAULT_CLAUDE_PATH}")
    [ -n "$cli_name" ] || cli_name="claude"
    printf '%s\n' "$cli_name auth login"
}

build_claude_args() {
    local model="$1"
    local args=()

    if [ -n "$AI_CLI_EXTRA_FLAGS" ]; then
        # shellcheck disable=SC2206
        args=($AI_CLI_EXTRA_FLAGS)
    fi

    if [ -n "$model" ]; then
        args+=(--model "$model")
    fi

    printf '%s\n' "${args[@]}"
}

sanitize_model() {
    local model="$1"
    [ -n "$model" ] || return 1

    case "$model" in
        *opus*)
            log "WARN: Opus model requested but prohibited by runtime policy: $model"
            return 1
            ;;
        *)
            printf '%s\n' "$model"
            ;;
    esac
}

build_model_candidates() {
    local primary fallback candidate
    local seen=""

    primary=$(sanitize_model "$AI_CLI_PRIMARY_MODEL" 2>/dev/null || true)
    fallback=$(sanitize_model "$AI_CLI_FALLBACK_MODEL" 2>/dev/null || true)

    for candidate in "$primary" "$fallback"; do
        [ -n "$candidate" ] || continue
        case " $seen " in
            *" $candidate "*) continue ;;
        esac
        seen="$seen $candidate"
        printf '%s\n' "$candidate"
    done
}

is_model_unavailable_error() {
    local output_file="$1"
    grep -Eqi 'model_unavailable|model unavailable|model_not_found|invalid model|unsupported model|not available on (this|your) account|requested model is not available|no model named|API Error: 503.*model|overloaded_error' "$output_file" 2>/dev/null
}

run_codex_provider() {
    local command_file="$1"
    local prompt="$2"
    local reason="${3:-claude_unavailable}"
    local resolved_codex
    local tmp_out tmp_msg rc=0

    resolved_codex=$(resolve_codex_path) || return 1
    tmp_out=$(mktemp)
    tmp_msg=$(mktemp)

    log "WARN: falling back to Codex for $command_file (reason=$reason, model=$CODEX_MODEL)"
    timeout "$CODEX_TIMEOUT" "$resolved_codex" exec \
        --skip-git-repo-check \
        -C "$WORKSPACE" \
        --output-last-message "$tmp_msg" \
        --sandbox danger-full-access \
        -m "$CODEX_MODEL" \
        "$prompt" \
        > "$tmp_out" 2>&1 || rc=$?

    cat "$tmp_out" >> "$LOG_FILE"
    if [ -s "$tmp_msg" ]; then
        printf '\n' >> "$LOG_FILE"
        cat "$tmp_msg" >> "$LOG_FILE"
        printf '\n' >> "$LOG_FILE"
    fi

    rm -f "$tmp_out" "$tmp_msg"

    if [ "$rc" -eq 0 ]; then
        log "Completed process: $command_file"
        log "Process result: $command_file status=success exit_code=0 provider=codex model=$CODEX_MODEL"
        return 0
    fi

    if [ "$rc" -eq 124 ]; then
        log "ERROR: Codex provider timed out after ${CODEX_TIMEOUT}s for $command_file"
        notify "⚠️ Экзокортекс: timeout Codex" "extractor/$command_file превысил лимит ${CODEX_TIMEOUT}s"
        return 124
    fi

    log "ERROR: Codex provider exited with code $rc for $command_file"
    notify "⚠️ Экзокортекс: ошибка Codex fallback" "extractor/$command_file завершился с кодом $rc"
    return "$rc"
}

run_claude() {
    local command_file="$1"
    local extra_args="${2:-}"
    local command_path="$PROMPTS_DIR/$command_file.md"

    if [ ! -f "$command_path" ]; then
        log "ERROR: Command file not found: $command_path"
        exit 1
    fi

    local prompt
    if [ "$command_file" = "inbox-check" ]; then
        # Keep the runtime prompt short to avoid provider timeouts on scheduled runs.
        prompt="HEADLESS AUTOMATION MODE.
Run inbox-check end-to-end now.
Do not ask questions.
Do not print opening screen, ritual, or menus.
Do not wait for user input.
Do not run git commit or git push commands.
Read and follow the full algorithm from: $command_path
Use workspace root: $WORKSPACE
Create/update required artifacts now.
If there are no pending captures, finish with: NO_PENDING_CAPTURES"
    else
        prompt=$(cat "$command_path")
        # Resolve workspace placeholder for deterministic execution.
        prompt="${prompt//'{{WORKSPACE_DIR}}'/$WORKSPACE}"
    fi

    if [ -n "$extra_args" ]; then
        prompt="$prompt

## Дополнительный контекст

$extra_args"
    fi

    log "Starting process: $command_file"
    log "Command file: $command_path"

    cd "$WORKSPACE"
    unset CLAUDECODE

    AI_CLI_PROVIDER_PRIMARY="$(resolve_provider_primary_choice)"
    log "Provider primary resolved for $command_file: $AI_CLI_PROVIDER_PRIMARY"

    if [ "$AI_CLI_PROVIDER_PRIMARY" = "codex" ] && resolve_codex_path >/dev/null 2>&1; then
        if run_codex_provider "$command_file" "$prompt" "primary_provider"; then
            return 0
        fi
        log "WARN: Codex primary failed for $command_file — falling back to Claude provider"
    fi

    local resolved_cli
    resolved_cli=$(resolve_claude_path) || {
        log "ERROR: Claude-compatible CLI not found"
        if has_codex_fallback; then
            run_codex_provider "$command_file" "$prompt" "claude_cli_missing"
            return $?
        fi
        notify "🔴 Экзокортекс: AI CLI path missing" "Extractor/$command_file не может стартовать: Claude-compatible CLI не найден"
        return 11
    }

    if ! preflight_check "$resolved_cli"; then
        local code=$?
        if has_codex_fallback; then
            run_codex_provider "$command_file" "$prompt" "claude_preflight_failed"
            return $?
        fi
        notify "🔴 Экзокортекс: preflight failed" "Extractor/$command_file не стартовал: проверь helper/env и Claude-compatible CLI path"
        return "$code"
    fi

    log "Claude-compatible path: $resolved_cli"

    local -a model_candidates=()
    local candidate
    while IFS= read -r candidate; do
        [ -n "$candidate" ] && model_candidates+=("$candidate")
    done < <(build_model_candidates)

    if [ "${#model_candidates[@]}" -eq 0 ]; then
        log "ERROR: no allowed Claude models configured for extractor"
        return 18
    fi

    local exit_code=0
    local attempt_model=""
    local attempt_index=0
    local total_attempts="${#model_candidates[@]}"
    local tmp_out=""

    for attempt_model in "${model_candidates[@]}"; do
        local -a claude_args=()
        while IFS= read -r arg; do
            [ -n "$arg" ] && claude_args+=("$arg")
        done < <(build_claude_args "$attempt_model")

        attempt_index=$((attempt_index + 1))
        tmp_out=$(mktemp)
        log "Model attempt $attempt_index/$total_attempts for $command_file: $attempt_model"

        set +e
        "$resolved_cli" "${claude_args[@]}" \
            "$AI_CLI_PROMPT_FLAG" "$prompt" \
            > "$tmp_out" 2>&1
        exit_code=$?
        set -e
        cat "$tmp_out" >> "$LOG_FILE"

        if grep -Eq 'authentication_error|OAuth token has expired|API Error: 401|Failed to authenticate|ANTHROPIC_AUTH_TOKEN is not set' "$tmp_out" 2>/dev/null; then
            log "CRITICAL: Claude-compatible provider auth failed via helper/env/custom API"
            if has_codex_fallback; then
                rm -f "$tmp_out"
                run_codex_provider "$command_file" "$prompt" "claude_auth_failed"
                return $?
            fi
            local relogin_hint
            relogin_hint=$(claude_reauth_hint)
            notify "🔴 Экзокортекс: provider auth failure" "Агент $command_file упал: проверь ~/.config/aist/env, helper и $relogin_hint"
            notify_telegram "$command_file"
            rm -f "$tmp_out"
            return 17
        fi

        if [ "$exit_code" -eq 0 ]; then
            rm -f "$tmp_out"
            log "Completed process: $command_file"
            log "Process result: $command_file status=success exit_code=0 model=$attempt_model"
            break
        fi

        if is_model_unavailable_error "$tmp_out"; then
            if [ "$attempt_index" -lt "$total_attempts" ]; then
                local next_model="${model_candidates[$attempt_index]}"
                log "WARN: model unavailable for $command_file on $attempt_model — falling back to $next_model"
                rm -f "$tmp_out"
                continue
            fi

            if has_codex_fallback; then
                rm -f "$tmp_out"
                run_codex_provider "$command_file" "$prompt" "claude_models_unavailable"
                return $?
            fi
        fi

        rm -f "$tmp_out"
        if [ "$command_file" = "inbox-check" ] && has_codex_fallback; then
            log "WARN: claude failed for inbox-check (exit=$exit_code) — trying Codex fallback"
            run_codex_provider "$command_file" "$prompt" "claude_exit_${exit_code}"
            return $?
        fi
        log "ERROR: claude exited with code $exit_code for $command_file (model=$attempt_model)"
        notify "⚠️ Экзокортекс: ошибка агента" "extractor/$command_file завершился с кодом $exit_code"
        return $exit_code
    done

    local strategy_dir="$WORKSPACE/DS-strategy"
    if [ "$command_file" = "inbox-check" ]; then
        if ! verify_inbox_check_outputs; then
            local verification_code=$?
            notify "🔴 Экзокортекс: inbox-check verification failed" "Extractor/inbox-check не закрыл outcome-loop, проверь extraction report и created artifacts"
            return "$verification_code"
        fi
    fi

    if [ -d "$strategy_dir/.git" ]; then
        git -C "$strategy_dir" reset --quiet 2>/dev/null || true
        git -C "$strategy_dir" add \
            inbox/captures.md \
            inbox/extraction-reports/ \
            inbox/INBOX-TASKS.md \
            inbox/archive/ \
            inbox/RECOVERY-CATALOG-LOST-INPUTS-*.md \
            >> "$LOG_FILE" 2>&1 || true
        if ! git -C "$strategy_dir" diff --cached --quiet 2>/dev/null; then
            git -C "$strategy_dir" commit -m "inbox-check: routed outcomes $DATE" >> "$LOG_FILE" 2>&1 \
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

latest_inbox_report_for_date() {
    local target_date="$1"
    ls -1t "$WORKSPACE/DS-strategy/inbox/extraction-reports/${target_date}-inbox-check"*.md 2>/dev/null | head -n 1
}

count_report_outcomes() {
    local report_file="$1"
    local outcome="$2"
    grep -Ec "^\*\*Outcome:\*\* .*${outcome}\b" "$report_file" 2>/dev/null || true
}

report_processed_count() {
    local report_file="$1"
    awk -F': ' '/^processed:/ {print $2; exit}' "$report_file" 2>/dev/null
}

verify_inbox_check_outputs() {
    local strategy_dir="$WORKSPACE/DS-strategy"
    local captures_file="$strategy_dir/inbox/captures.md"
    local inbox_file="$strategy_dir/inbox/INBOX-TASKS.md"
    local archive_dir="$strategy_dir/inbox/archive/rejected"
    local archive_index="$strategy_dir/inbox/archive/index.md"
    local recovery_file="$strategy_dir/inbox/RECOVERY-CATALOG-LOST-INPUTS-$DATE.md"
    local report_file processed analyzed_count pack_count backlog_count recovery_count rejected_count
    local backlog_refs pack_refs

    report_file=$(latest_inbox_report_for_date "$DATE")
    if [ -z "$report_file" ] || [ ! -f "$report_file" ]; then
        log "ERROR: inbox-check verification failed: no extraction report found for $DATE"
        return 31
    fi

    processed=$(report_processed_count "$report_file")
    processed=${processed:-0}

    if [ "$processed" -gt 0 ] && ! grep -Eq '^\*\*Outcome:\*\* ' "$report_file"; then
        log "ERROR: inbox-check verification failed: report has processed=$processed but no explicit Outcome fields"
        return 32
    fi

    analyzed_count=$(grep -c "\[analyzed $DATE\]" "$captures_file" 2>/dev/null || true)
    if [ "$processed" -gt 0 ] && [ "$analyzed_count" -lt "$processed" ]; then
        log "ERROR: inbox-check verification failed: analyzed markers ($analyzed_count) < processed captures ($processed)"
        return 33
    fi

    pack_count=$(count_report_outcomes "$report_file" "pack_candidate")
    backlog_count=$(count_report_outcomes "$report_file" "backlog_task")
    recovery_count=$(count_report_outcomes "$report_file" "recovery_item")
    rejected_count=$(count_report_outcomes "$report_file" "rejected")

    if [ "$pack_count" -gt 0 ]; then
        pack_refs=$(grep -Fc "Extraction report $DATE" "$inbox_file" 2>/dev/null || true)
        if [ "$pack_refs" -lt "$pack_count" ]; then
            log "ERROR: inbox-check verification failed: pack_candidate outcomes=$pack_count but INBOX references=$pack_refs"
            return 34
        fi
    fi

    if [ "$backlog_count" -gt 0 ]; then
        backlog_refs=$(grep -Fc "extracted from inbox-check $DATE" "$inbox_file" 2>/dev/null || true)
        if [ "$backlog_refs" -lt "$backlog_count" ]; then
            log "ERROR: inbox-check verification failed: backlog_task outcomes=$backlog_count but INBOX backlog refs=$backlog_refs"
            return 35
        fi
    fi

    if [ "$recovery_count" -gt 0 ] && [ ! -f "$recovery_file" ]; then
        log "ERROR: inbox-check verification failed: recovery_item outcomes=$recovery_count but recovery catalog missing: $recovery_file"
        return 36
    fi

    if [ "$rejected_count" -gt 0 ]; then
        if [ ! -d "$archive_dir" ] || [ ! -f "$archive_index" ]; then
            log "ERROR: inbox-check verification failed: rejected outcomes require archive dir and index"
            return 37
        fi
    fi

    log "OK: inbox-check verification passed (processed=$processed, pack=$pack_count, backlog=$backlog_count, recovery=$recovery_count, rejected=$rejected_count)"
    return 0
}

load_env

case "${1:-}" in
    "inbox-check")
        SCENARIO_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
        if ! is_work_hours; then
            log "SKIP: inbox-check outside work hours ($HOUR:00)"
            write_status_artifact "extractor-inbox-check" "success" "0" "outside work hours" "verified" "runner skipped outside work hours by policy" "" "true"
            exit 0
        fi

        if ! acquire_lock "extractor-inbox-check"; then
            write_status_artifact "extractor-inbox-check" "running" "2" "another extractor process holds the scenario lock" "reported" "live lock detected" "" "false"
            exit 2
        fi

        CAPTURES_FILE="$WORKSPACE/DS-strategy/inbox/captures.md"
        if [ -f "$CAPTURES_FILE" ]; then
            PENDING=$(grep -c '^### ' "$CAPTURES_FILE" 2>/dev/null) || PENDING=0
            PROCESSED=$(grep -c '\[processed' "$CAPTURES_FILE" 2>/dev/null) || PROCESSED=0
            ANALYZED=$(grep -c '\[analyzed' "$CAPTURES_FILE" 2>/dev/null) || ANALYZED=0
            ACTUAL_PENDING=$((PENDING - PROCESSED - ANALYZED))

            if [ "$ACTUAL_PENDING" -le 0 ]; then
                log "SKIP: No pending captures in inbox (total=$PENDING, processed=$PROCESSED, analyzed=$ANALYZED)"
                write_status_artifact "extractor-inbox-check" "success" "0" "no pending captures in inbox" "verified" "runner checked inbox and found nothing pending" "" "true"
                exit 0
            fi

            log "Found $ACTUAL_PENDING pending captures in inbox"
        else
            log "SKIP: captures.md not found"
            write_status_artifact "extractor-inbox-check" "success" "0" "captures.md not found" "verified" "runner checked inbox source file and found no captures file" "" "true"
            exit 0
        fi

        if run_claude "inbox-check"; then
            write_status_artifact "extractor-inbox-check" "success" "0" "completed successfully" "verified" "inbox-check completed successfully" "" "true"
        else
            rc=$?
            write_status_artifact "extractor-inbox-check" "failed" "$rc" "extractor inbox-check failed" "reported" "runner returned non-zero exit" "inbox-check exit=$rc" "false"
            exit "$rc"
        fi
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
