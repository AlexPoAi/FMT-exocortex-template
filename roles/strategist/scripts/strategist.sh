#!/bin/bash
# Strategist (Стратег) Agent Runner
# Запускает AI CLI provider с заданным сценарием

set -e

# Предотвращаем сон только на macOS
if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -diu -w $$ &
fi

# Конфигурация
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
RESOLVE_WORKSPACE_SH="$HOME/Github/FMT-exocortex-template/roles/synchronizer/scripts/resolve-workspace.sh"
if [ ! -f "$RESOLVE_WORKSPACE_SH" ]; then
    RESOLVE_WORKSPACE_SH="$(cd "$SCRIPT_DIR/../../synchronizer/scripts" && pwd)/resolve-workspace.sh"
fi
eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"
WORKSPACE_ROOT="$WORKSPACE_DIR"
WORKSPACE="$WORKSPACE_ROOT/DS-strategy"
if [ -d "$FMT_EXOCORTEX_DIR/roles/strategist/prompts" ]; then
    PROMPTS_DIR="$FMT_EXOCORTEX_DIR/roles/strategist/prompts"
else
    PROMPTS_DIR="$REPO_DIR/prompts"
fi
LOG_DIR="$HOME/logs/strategist"
STATE_DIR="$HOME/.local/state/exocortex"
STATUS_DIR="$STATE_DIR/status"
CLAUDE_PATH="${CLAUDE_PATH:-$HOME/.local/bin/claude}"
CLAUDE_TIMEOUT=1800  # 30 мин — защита от зависания Claude-compatible CLI
AI_CLI_PRIMARY_MODEL="${AI_CLI_PRIMARY_MODEL:-${AI_CLI_MODEL:-gpt-5.4}}"
AI_CLI_FALLBACK_MODEL="${AI_CLI_FALLBACK_MODEL:-claude-sonnet-4-6}"
AI_CLI_PROVIDER_PRIMARY="${AI_CLI_PROVIDER_PRIMARY:-codex}"
AI_CLI_PROVIDER_FALLBACK="${AI_CLI_PROVIDER_FALLBACK:-codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.4}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-1200}"
CODEX_MODEL_WEEK_REVIEW="${CODEX_MODEL_WEEK_REVIEW:-gpt-5.4-mini}"
CODEX_TIMEOUT_WEEK_REVIEW="${CODEX_TIMEOUT_WEEK_REVIEW:-600}"
RUNTIME_ARBITER_PATH="$FMT_EXOCORTEX_DIR/roles/synchronizer/scripts/runtime-arbiter.sh"
GITHUB_USER="$(git -C "$WORKSPACE" remote get-url origin 2>/dev/null | sed 's|git@github.com:|https://github.com/|' | sed 's|https://github.com/||' | cut -d/ -f1 | head -1)"
[ -n "$GITHUB_USER" ] || GITHUB_USER="AlexPoAi"

# Template placeholders may survive in repo mode; prefer a real local Claude-compatible path.
if [ ! -x "$CLAUDE_PATH" ]; then
    CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"
fi

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

CODEX_PATH="$(resolve_codex_path 2>/dev/null || true)"

if [ -n "$CLAUDE_PATH" ] && [ ! -x "$CLAUDE_PATH" ]; then
    CLAUDE_PATH=""
fi

if [ -n "$CODEX_PATH" ] && [ ! -x "$CODEX_PATH" ]; then
    CODEX_PATH=""
fi

if [ -z "$CLAUDE_PATH" ] && [ -z "$CODEX_PATH" ]; then
    echo "ERROR: Neither Codex CLI nor Claude-compatible CLI is available." >&2
    exit 1
fi

# macOS не имеет GNU timeout — используем perl fallback
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

# Создаём папку для логов
mkdir -p "$LOG_DIR"
mkdir -p "$STATUS_DIR"

# Определяем день недели и тип сценария
DAY_OF_WEEK=$(date +%u)  # 1=Mon, 7=Sun
DATE=$(date +%Y-%m-%d)
ISO_WEEK=$(date +%V)
ISO_YEAR=$(date +%G)

# Лог файл
LOG_FILE="$LOG_DIR/$DATE.log"
RECOVERY_BRIEF_SCRIPT="$SCRIPT_DIR/build-recovery-brief.sh"
RECOVERY_WEEKPLAN_SYNC_SCRIPT="$SCRIPT_DIR/sync-recovery-into-weekplan.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

persist_provider_output() {
    local provider="$1"
    local scenario="$2"
    local stdout_file="$3"
    local message_file="${4:-}"
    local out_dir base stdout_copy message_copy

    out_dir="$LOG_DIR/raw/$DATE"
    mkdir -p "$out_dir"

    base="$(date '+%H%M%S')-${scenario}-${provider}"
    stdout_copy="$out_dir/${base}.stdout.log"
    cp "$stdout_file" "$stdout_copy" 2>/dev/null || true

    if [ -n "$message_file" ] && [ -s "$message_file" ]; then
        message_copy="$out_dir/${base}.message.txt"
        cp "$message_file" "$message_copy" 2>/dev/null || true
        printf '%s|%s\n' "$stdout_copy" "$message_copy"
        return 0
    fi

    printf '%s|\n' "$stdout_copy"
}

log_provider_output_summary() {
    local provider="$1"
    local scenario="$2"
    local stdout_file="$3"
    local message_file="${4:-}"
    local exit_code="${5:-0}"
    local stored stdout_copy message_copy

    stored="$(persist_provider_output "$provider" "$scenario" "$stdout_file" "$message_file")"
    stdout_copy="${stored%%|*}"
    message_copy="${stored#*|}"

    log "Provider output archived: $stdout_copy"
    [ -n "$message_copy" ] && log "Provider last message archived: $message_copy"

    if [ "$exit_code" -ne 0 ]; then
        log "Provider output tail for $provider/$scenario:"
        tail -n 20 "$stdout_file" 2>/dev/null | while IFS= read -r line; do
            log "  $line"
        done
        if [ -n "$message_file" ] && [ -s "$message_file" ]; then
            log "Provider last message tail for $provider/$scenario:"
            tail -n 10 "$message_file" 2>/dev/null | while IFS= read -r line; do
                log "  $line"
            done
        fi
    fi
}

refresh_recovery_brief() {
    if [ -x "$RECOVERY_BRIEF_SCRIPT" ]; then
        local brief_path
        brief_path=$("$RECOVERY_BRIEF_SCRIPT" "$WORKSPACE_ROOT" 2>>"$LOG_FILE" || true)
        if [ -n "$brief_path" ] && [ -f "$brief_path" ]; then
            log "Recovery brief refreshed: $brief_path"
            return 0
        fi
        log "WARN: recovery brief refresh did not produce a file"
        return 1
    fi

    log "WARN: recovery brief script missing or not executable: $RECOVERY_BRIEF_SCRIPT"
    return 1
}

refresh_recovery_weekplan_context() {
    if [ -x "$RECOVERY_WEEKPLAN_SYNC_SCRIPT" ]; then
        local target_path
        target_path=$("$RECOVERY_WEEKPLAN_SYNC_SCRIPT" "$WORKSPACE_ROOT" 2>>"$LOG_FILE" || true)
        if [ -n "$target_path" ] && [ -f "$target_path" ]; then
            log "Recovery synced into WeekPlan: $target_path"
            return 0
        fi
        log "WARN: recovery sync did not produce a WeekPlan path"
        return 1
    fi

    log "WARN: recovery weekplan sync script missing or not executable: $RECOVERY_WEEKPLAN_SYNC_SCRIPT"
    return 1
}

status_task_for_scenario() {
    case "$1" in
        morning|session-prep|day-plan) echo "strategist-morning" ;;
        note-review) echo "strategist-note-review" ;;
        week-review) echo "strategist-week-review" ;;
        *) echo "" ;;
    esac
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
    local evidence_summary="${6:-reported by strategist runner}"
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

    if [ "$status" = "failed" ] || [ "$status" = "timeout" ] || [ "$status" = "auth_failed" ] || [ "$status" = "unsupported_path" ]; then
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
STALENESS_BUDGET_SEC=$(shell_quote "${SCENARIO_STALENESS_BUDGET:-86400}")
PRODUCED_ARTIFACTS=''
COMPLETED_WINDOW=$(shell_quote "$completed_window")
LOG_PATH=$(shell_quote "$LOG_FILE")
UPDATED_AT=$(shell_quote "$now_ts")
EOF
}

start_status_tracking() {
    SCENARIO_STATUS_TASK="$(status_task_for_scenario "$1")"
    SCENARIO_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
    case "$SCENARIO_STATUS_TASK" in
        strategist-week-review) SCENARIO_STALENESS_BUDGET=604800 ;;
        *) SCENARIO_STALENESS_BUDGET=86400 ;;
    esac
    write_status_artifact "$SCENARIO_STATUS_TASK" "running" "" "scenario started" "reported" "scenario started by strategist runner" "" "false"
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

notify_telegram_text() {
    local scenario="$1"
    local text="$2"
    NOTIFY_TEXT="$text" "$FMT_EXOCORTEX_DIR/roles/synchronizer/scripts/notify.sh" strategist "$scenario" >> "$LOG_FILE" 2>&1 || true
}

has_codex_fallback() {
    [ "${AI_CLI_PROVIDER_FALLBACK}" = "codex" ] && [ -n "$CODEX_PATH" ] && [ -x "$CODEX_PATH" ]
}

uses_codex_as_primary() {
    [ "${AI_CLI_PROVIDER_PRIMARY}" = "codex" ] && [ -n "$CODEX_PATH" ] && [ -x "$CODEX_PATH" ]
}

load_runtime_arbiter_env() {
    local tmp_env

    [ -x "$RUNTIME_ARBITER_PATH" ] || return 1

    tmp_env=$(mktemp)
    if ! bash "$RUNTIME_ARBITER_PATH" --env >"$tmp_env"; then
        rm -f "$tmp_env"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$tmp_env"
    rm -f "$tmp_env"
}

resolve_provider_primary_choice() {
    if [ "${AI_CLI_PROVIDER_PRIMARY}" != "auto" ]; then
        printf '%s\n' "$AI_CLI_PROVIDER_PRIMARY"
        return
    fi

    if load_runtime_arbiter_env; then
        if [ -n "${AI_CLI_PROVIDER_PRIMARY_RESOLVED:-}" ] && [ "$AI_CLI_PROVIDER_PRIMARY_RESOLVED" != "unavailable" ]; then
            printf '%s\n' "$AI_CLI_PROVIDER_PRIMARY_RESOLVED"
            return
        fi
    fi

    if [ -n "$CODEX_PATH" ] && [ -x "$CODEX_PATH" ]; then
        printf '%s\n' "codex"
    elif [ -n "$CLAUDE_PATH" ] && [ -x "$CLAUDE_PATH" ]; then
        printf '%s\n' "claude"
    else
        printf '%s\n' "claude"
    fi
}

fail_day_close_headless() {
    local message="day-close requires an interactive protocol-close session and is no longer supported via headless strategist.sh. Use the canonical close route instead."
    log "ERROR: $message"
    log "Scenario result: day-close status=unsupported_path exit_code=19 route=protocol-close-interactive"
    write_status_artifact "$(status_task_for_scenario "day-close")" "unsupported_path" "19" "$message" "reported" "headless route rejected" "$message" "false"
    printf '%s\n' "$message" >&2
    return 19
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
    grep -Eqi 'model_unavailable|model unavailable|model_not_found|invalid model|unsupported model|not available on (this|your) account|requested model is not available|no model named|API Error: 503.*model|overloaded_error|API Error: 400 .*"code":"E005".*"Invalid request"|invalid_request_error' "$output_file" 2>/dev/null
}

is_provider_runtime_error() {
    local output_file="$1"
    grep -Eqi 'API Error: 5[0-9]{2}|Internal server error|service unavailable|upstream connect error|gateway timeout|bad gateway|temporarily unavailable|E015' "$output_file" 2>/dev/null
}

count_bold_notes() {
    local file="$1"
    [ -f "$file" ] || {
        printf '0\n'
        return
    }
    awk '/^\*\*/ {count++} END {print count+0}' "$file"
}

count_new_bold_notes() {
    local file="$1"
    [ -f "$file" ] || {
        printf '0\n'
        return
    }
    awk '/^\*\*/ && $0 !~ /🔄/ {count++} END {print count+0}' "$file"
}

count_non_bold_content_lines() {
    local file="$1"
    [ -f "$file" ] || {
        printf '0\n'
        return
    }
    awk '/^[^*#>-]/ {count++} END {print count+0}' "$file"
}

claude_reauth_hint() {
    local cli_name="${CLAUDE_PATH##*/}"
    [ -n "$cli_name" ] || cli_name="claude"
    printf '%s\n' "$cli_name auth login"
}

run_codex_provider() {
    local command_file="$1"
    local prompt="$2"
    local reason="${3:-claude_unavailable}"
    local tmp_out tmp_msg rc=0 codex_model codex_timeout

    if ! has_codex_fallback; then
        return 1
    fi

    codex_model="$CODEX_MODEL"
    codex_timeout="$CODEX_TIMEOUT"

    case "$command_file" in
        week-review)
            codex_model="$CODEX_MODEL_WEEK_REVIEW"
            codex_timeout="$CODEX_TIMEOUT_WEEK_REVIEW"
            prompt=$(cat <<EOF
[Системный контекст] Сегодня: ${DATE}. День недели №${DAY_OF_WEEK} (1=Пн..7=Вс). ЯЗЫК: отвечай ТОЛЬКО на русском.

Выполни УПРОЩЁННЫЙ fallback-сценарий week-review для роли Стратег.

Это не полный weekly workflow. Твоя задача только одна:
- обновить текущий WeekPlan в ${WORKSPACE}/current/
- записать краткую секцию итогов прошлой недели как вход для следующего session-prep

Жёсткие ограничения:
1. НЕ создавать пост для клуба
2. НЕ менять DS-Knowledge-Index
3. НЕ выполнять week-close / rotation MEMORY
4. НЕ трогать другие репозитории кроме чтения git log
5. НЕ делать лишних больших текстов

Что нужно сделать:
1. Найди текущий WeekPlan W*.md в ${WORKSPACE}/current/
2. Считай его source-of-truth файлом недели
3. По git log в ${WORKSPACE_ROOT}/* собери краткие итоги прошлой недели
4. Вставь или обнови секцию вида:

## Итоги W15

### Метрики
- РП: ...
- Коммитов: ...
- Активных дней: ...

### По репозиториям
Короткая таблица 3 колонки: репо / коммиты / главное

### РП
Короткая таблица: id / статус / комментарий

### Инсайты
- 2-4 пункта

### Carry-over
- 2-5 пунктов

### Фокус следующей недели
- 2-4 пункта

Важно:
- если данных не хватает, пиши честно и кратко
- результат должен быть компактным
- после обновления WeekPlan закоммить изменения только в DS-strategy
EOF
)
            ;;
    esac

    tmp_out=$(mktemp)
    tmp_msg=$(mktemp)

    log "WARN: falling back to Codex for $command_file (reason=$reason, model=$codex_model, timeout=${codex_timeout}s)"
    timeout "$codex_timeout" "$CODEX_PATH" exec \
        --skip-git-repo-check \
        -C "$WORKSPACE" \
        --output-last-message "$tmp_msg" \
        --sandbox danger-full-access \
        -m "$codex_model" \
        "$prompt" \
        > "$tmp_out" 2>&1 || rc=$?

    log_provider_output_summary "codex" "$command_file" "$tmp_out" "$tmp_msg" "$rc"

    rm -f "$tmp_out" "$tmp_msg"

    if [ "$rc" -eq 0 ]; then
        log "Completed scenario: $command_file"
        log "Scenario result: $command_file status=success exit_code=0 provider=codex model=$codex_model"
        write_status_artifact "$SCENARIO_STATUS_TASK" "success" "0" "completed successfully via codex" "verified" "scenario completed via codex provider" "" "true"
        return 0
    fi

    if [ "$rc" -eq 124 ]; then
        log "ERROR: Codex provider timed out after ${codex_timeout}s for scenario: $command_file"
        log "Scenario result: $command_file status=timeout exit_code=$rc provider=codex model=$codex_model"
        write_status_artifact "$SCENARIO_STATUS_TASK" "timeout" "$rc" "codex provider timed out" "reported" "codex provider timeout" "codex timeout for $command_file" "false"
        return 124
    fi

    log "ERROR: Codex provider exited with code $rc for scenario: $command_file"
    log "Scenario result: $command_file status=failed exit_code=$rc provider=codex model=$codex_model"
    write_status_artifact "$SCENARIO_STATUS_TASK" "failed" "$rc" "codex provider failed" "reported" "codex provider returned non-zero exit" "codex provider failed for $command_file" "false"
    return "$rc"
}

resolve_command_path() {
    local command_file="$1"

    case "$command_file" in
        day-close)
            printf '%s\n' "$FMT_EXOCORTEX_DIR/memory/protocol-close.md"
            ;;
        *)
            printf '%s\n' "$PROMPTS_DIR/$command_file.md"
            ;;
    esac
}

resolve_knowledge_index_dir() {
    local candidate

    for candidate in \
        "$WORKSPACE_ROOT/DS-Knowledge-Index" \
        "$HOME/IWE/DS-Knowledge-Index"
    do
        if [ -d "$candidate/.git" ] || [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    for candidate in "$WORKSPACE_ROOT"/DS-Knowledge-Index* "$HOME/IWE"/DS-Knowledge-Index*; do
        [ -e "$candidate" ] || continue
        if [ -d "$candidate/.git" ] || [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

run_claude() {
    local command_file="$1"
    local command_path
    local knowledge_index_dir
    local knowledge_index_repo
    command_path=$(resolve_command_path "$command_file")
    knowledge_index_dir=$(resolve_knowledge_index_dir || true)
    [ -n "$knowledge_index_dir" ] || knowledge_index_dir="$WORKSPACE_ROOT/DS-Knowledge-Index"
    knowledge_index_repo="$(basename "$knowledge_index_dir")"

    if [ ! -f "$command_path" ]; then
        log "ERROR: Command file not found: $command_path"
        exit 1
    fi

    # Читаем содержимое команды
    local prompt
    prompt=$(python3 - "$command_path" "$WORKSPACE_ROOT" "$HOME" "$GITHUB_USER" "$knowledge_index_dir" "$knowledge_index_repo" <<'PY'
import sys
from pathlib import Path

path, workspace_dir, home_dir, github_user, knowledge_index_dir, knowledge_index_repo = sys.argv[1:7]
text = Path(path).read_text(encoding="utf-8")
o = "{" + "{"
c = "}" + "}"
text = text.replace(f"{o}WORKSPACE_DIR{c}", workspace_dir)
text = text.replace(f"{o}HOME_DIR{c}", home_dir)
text = text.replace(f"{o}GITHUB_USER{c}", github_user)
text = text.replace(f"{o}KNOWLEDGE_INDEX_DIR{c}", knowledge_index_dir)
text = text.replace(f"{o}KNOWLEDGE_INDEX_REPO{c}", knowledge_index_repo)
print(text)
PY
)

    # Inject current date + day of week (prevents LLM calendar arithmetic errors)
    local ru_date_context
    ru_date_context=$(python3 -c "
import datetime
days = ['Понедельник','Вторник','Среда','Четверг','Пятница','Суббота','Воскресенье']
months = ['января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря']
d = datetime.date.today()
print(f'{d.day} {months[d.month-1]} {d.year}, {days[d.weekday()]}')
")
    prompt="[Системный контекст] Сегодня: ${ru_date_context}. ISO: ${DATE}. День недели №${DAY_OF_WEEK} (1=Пн..7=Вс). ЯЗЫК: отвечай ТОЛЬКО на русском. Украинский, английский и другие языки запрещены.

${prompt}"

    log "Starting scenario: $command_file"
    log "Command file: $command_path"
    log "Date context: $ru_date_context"
    start_status_tracking "$command_file"

    cd "$WORKSPACE"

    AI_CLI_PROVIDER_PRIMARY="$(resolve_provider_primary_choice)"

    if [ "${STRATEGIST_WEEK_REVIEW_FORCE_CLAUDE:-0}" = "1" ] && [ "${STRATEGIST_ALLOW_LEGACY_CLAUDE_OVERRIDE:-0}" = "1" ] && [ "$command_file" = "week-review" ] && [ -n "$CLAUDE_PATH" ] && [ -x "$CLAUDE_PATH" ]; then
        AI_CLI_PROVIDER_PRIMARY="claude"
        AI_CLI_PRIMARY_MODEL="claude-haiku-4-5"
        AI_CLI_FALLBACK_MODEL="claude-sonnet-4-6"
        log "Week-review override: legacy Claude debug path enabled via STRATEGIST_WEEK_REVIEW_FORCE_CLAUDE=1 + STRATEGIST_ALLOW_LEGACY_CLAUDE_OVERRIDE=1"
    elif [ "${STRATEGIST_WEEK_REVIEW_FORCE_CLAUDE:-0}" = "1" ] && [ "$command_file" = "week-review" ]; then
        log "WARN: ignored STRATEGIST_WEEK_REVIEW_FORCE_CLAUDE=1 because legacy Claude override now requires STRATEGIST_ALLOW_LEGACY_CLAUDE_OVERRIDE=1"
    fi

    if uses_codex_as_primary; then
        if run_codex_provider "$command_file" "$prompt" "primary_provider"; then
            return 0
        fi
        log "WARN: Codex primary failed for $command_file — falling back to Claude provider"
    fi

    if [ -z "$CLAUDE_PATH" ] || [ ! -x "$CLAUDE_PATH" ]; then
        log "WARN: Claude CLI unavailable for $command_file"
        if has_codex_fallback; then
            run_codex_provider "$command_file" "$prompt" "claude_cli_missing"
            return $?
        fi
        log "ERROR: Claude CLI not found and Codex fallback unavailable"
        return 11
    fi

    local -a model_candidates=()
    local candidate
    while IFS= read -r candidate; do
        [ -n "$candidate" ] && model_candidates+=("$candidate")
    done < <(build_model_candidates)

    if [ "${#model_candidates[@]}" -eq 0 ]; then
        log "ERROR: no allowed Claude models configured for strategist"
        return 18
    fi

    local rc=0
    local attempt_model=""
    local tmp_out=""
    local attempt_index=0
    local total_attempts="${#model_candidates[@]}"

    for attempt_model in "${model_candidates[@]}"; do
        attempt_index=$((attempt_index + 1))
        rc=0
        tmp_out=$(mktemp)

        log "Model attempt $attempt_index/$total_attempts for $command_file: $attempt_model"
        if [ "$(id -u)" -eq 0 ]; then
            timeout "$CLAUDE_TIMEOUT" "$CLAUDE_PATH" \
                --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
                --model "$attempt_model" \
                -p "$prompt" \
                > "$tmp_out" 2>&1 || rc=$?
        else
            timeout "$CLAUDE_TIMEOUT" "$CLAUDE_PATH" --dangerously-skip-permissions \
                --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
                --model "$attempt_model" \
                -p "$prompt" \
                > "$tmp_out" 2>&1 || rc=$?
        fi
        log_provider_output_summary "claude" "$command_file" "$tmp_out" "" "$rc"

        if grep -Eq 'authentication_error|OAuth token has expired|API Error: 401|Failed to authenticate|ANTHROPIC_AUTH_TOKEN is not set|API key is disabled|Not logged in .*Please run /login' "$tmp_out" 2>/dev/null; then
            log "CRITICAL: Claude-compatible provider auth failed for scenario: $command_file"
            if has_codex_fallback; then
                rm -f "$tmp_out"
                run_codex_provider "$command_file" "$prompt" "claude_auth_failed"
                return $?
            fi
            local relogin_hint
            relogin_hint=$(claude_reauth_hint)
            notify "🔴 Экзокортекс: provider auth failure" "Стратег/$command_file: Claude-compatible auth истёк. Запусти: $relogin_hint"
            notify_telegram_text "auth-failure" "🔴 <b>Strategist provider auth failure</b>\n\nСценарий: <b>$command_file</b>\nProvider path: <code>${CLAUDE_PATH:-missing}</code>\nДействие: выполнить <code>$relogin_hint</code> и повторить запуск."
            write_status_artifact "$SCENARIO_STATUS_TASK" "auth_failed" "1" "claude-compatible auth failed" "reported" "provider auth failure detected" "auth failed for $command_file" "false"
            rm -f "$tmp_out"
            return 1
        fi

        if [ "$rc" -eq 0 ]; then
            rm -f "$tmp_out"
            log "Completed scenario: $command_file"
            log "Scenario result: $command_file status=success exit_code=0 model=$attempt_model"
            write_status_artifact "$SCENARIO_STATUS_TASK" "success" "0" "completed successfully" "verified" "scenario completed successfully" "" "true"
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

        if is_provider_runtime_error "$tmp_out"; then
            if has_codex_fallback; then
                log "WARN: Claude-compatible provider runtime failure for $command_file on $attempt_model — falling back to Codex"
                rm -f "$tmp_out"
                run_codex_provider "$command_file" "$prompt" "claude_provider_runtime_failure"
                return $?
            fi
        fi

        rm -f "$tmp_out"
        if [ "$rc" -eq 124 ]; then
            log "ERROR: Claude-compatible provider timed out after ${CLAUDE_TIMEOUT}s for scenario: $command_file (model=$attempt_model)"
            log "Scenario result: $command_file status=timeout exit_code=$rc model=$attempt_model"
            write_status_artifact "$SCENARIO_STATUS_TASK" "timeout" "$rc" "claude-compatible provider timed out" "reported" "provider timeout" "timeout for $command_file" "false"
            return 124
        fi

        log "ERROR: Claude-compatible provider exited with code $rc for scenario: $command_file (model=$attempt_model)"
        log "Scenario result: $command_file status=failed exit_code=$rc model=$attempt_model"
        write_status_artifact "$SCENARIO_STATUS_TASK" "failed" "$rc" "claude-compatible provider failed" "reported" "provider returned non-zero exit" "failure for $command_file" "false"
        return "$rc"
    done

    # Push changes to GitHub (чтобы бот мог читать через API)
    if git -C "$WORKSPACE" diff --quiet origin/main..HEAD 2>/dev/null; then
        log "No unpushed commits"
    else
        git -C "$WORKSPACE" pull --rebase >> "$LOG_FILE" 2>&1 && log "Pulled (rebase)" || log "WARN: pull --rebase failed"
        git -C "$WORKSPACE" push >> "$LOG_FILE" 2>&1 && log "Pushed to GitHub" || log "WARN: git push failed"
    fi

    # Очистить staging area после AI CLI сессии (предотвращает staging leak в следующие скрипты)
    # НЕ трогаем working tree — только unstage orphaned changes
    git -C "$WORKSPACE" reset --quiet 2>/dev/null || true
    log "Cleared staging area after AI CLI session"

    # macOS notification
    local summary
    summary=$(tail -5 "$LOG_FILE" | grep -v '^\[' | head -3)
    notify "Стратег: $command_file" "$summary"
}

# Проверка: уже запускался ли сценарий сегодня
already_ran_today() {
    local scenario="$1"
    local status_file task status end_ts

    task="$(status_task_for_scenario "$scenario")"
    status_file="$STATUS_DIR/${task}.status"

    if [ -n "$task" ] && [ -f "$status_file" ]; then
        # shellcheck disable=SC1090
        source "$status_file"
        status="${STATUS:-}"
        end_ts="${END_TS:-}"
        if [ "$status" = "success" ] && [ -n "$end_ts" ] && [ "${end_ts%% *}" = "$DATE" ]; then
            return 0
        fi
    fi

    [ -f "$LOG_FILE" ] && grep -q "Completed scenario: $scenario" "$LOG_FILE"
}

already_ran_this_week() {
    local scenario="$1"
    local status_file task status end_ts end_date end_week end_year

    task="$(status_task_for_scenario "$scenario")"
    status_file="$STATUS_DIR/${task}.status"

    if [ -n "$task" ] && [ -f "$status_file" ]; then
        # shellcheck disable=SC1090
        source "$status_file"
        status="${STATUS:-}"
        end_ts="${END_TS:-}"
        end_date="${end_ts%% *}"
        if [ "$status" = "success" ] && [ -n "$end_date" ]; then
            end_week="$(date -j -f '%Y-%m-%d' "$end_date" '+%V' 2>/dev/null || true)"
            end_year="$(date -j -f '%Y-%m-%d' "$end_date" '+%G' 2>/dev/null || true)"
            if [ "$end_week" = "$ISO_WEEK" ] && [ "$end_year" = "$ISO_YEAR" ]; then
                return 0
            fi
        fi
    fi

    return 1
}

# File-based lock to prevent concurrent execution (RunAtLoad + CalendarInterval race)
LOCK_DIR="$LOG_DIR/locks"
mkdir -p "$LOCK_DIR"

acquire_lock() {
    local scenario="$1"
    local lockfile="$LOCK_DIR/${scenario}.${DATE}.lock"
    local pidfile="$lockfile/pid"

    if [ -d "$lockfile" ]; then
        local existing_pid=""
        if [ -f "$pidfile" ]; then
            existing_pid=$(cat "$pidfile" 2>/dev/null || true)
        fi

        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
            log "SKIP: $scenario already running (lock exists: $lockfile, pid=$existing_pid)"
            write_status_artifact "$(status_task_for_scenario "$scenario")" "running" "2" "another strategist process holds the scenario lock" "reported" "live lock detected" "" "false"
            exit 2  # non-zero → scheduler won't mark_done
        fi

        log "WARN: stale lock detected for $scenario — removing $lockfile"
        rm -rf "$lockfile"
    fi

    if ! mkdir "$lockfile" 2>/dev/null; then
        log "SKIP: $scenario already running (lock exists: $lockfile)"
        write_status_artifact "$(status_task_for_scenario "$scenario")" "running" "2" "another strategist process holds the scenario lock" "reported" "lock directory already exists" "" "false"
        exit 2
    fi
    echo "$$" > "$pidfile"
    # Auto-cleanup lock on exit
    trap "rm -f '$pidfile' 2>/dev/null; rmdir '$lockfile' 2>/dev/null" EXIT
}

# Читаем strategy_day из конфига (L4 Personal)
resolve_rhythm_config() {
    local candidates=(
        "$WORKSPACE_ROOT/memory/day-rhythm-config.yaml"
        "$WORKSPACE_ROOT/FMT-exocortex-template/memory/day-rhythm-config.yaml"
        "$HOME/.claude/projects/-Users-$(whoami)-Github/memory/day-rhythm-config.yaml"
        "$HOME/.claude/projects/-Users-$(whoami)-Github-DS-strategy/memory/day-rhythm-config.yaml"
        "$HOME/.claude/projects/-Users-$(whoami)-IWE/memory/day-rhythm-config.yaml"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

RHYTHM_CONFIG="$(resolve_rhythm_config || true)"
if [ -n "$RHYTHM_CONFIG" ]; then
    STRATEGY_DAY_NAME=$(grep 'strategy_day:' "$RHYTHM_CONFIG" 2>/dev/null | awk '{print $2}' | head -1)
fi
[ -n "${STRATEGY_DAY_NAME:-}" ] || STRATEGY_DAY_NAME="monday"
log "Strategy day config: ${RHYTHM_CONFIG:-missing} -> ${STRATEGY_DAY_NAME}"
# Конвертируем имя дня в номер (1=Mon..7=Sun)
case "$STRATEGY_DAY_NAME" in
    monday)    STRATEGY_DAY_NUM=1 ;;
    tuesday)   STRATEGY_DAY_NUM=2 ;;
    wednesday) STRATEGY_DAY_NUM=3 ;;
    thursday)  STRATEGY_DAY_NUM=4 ;;
    friday)    STRATEGY_DAY_NUM=5 ;;
    saturday)  STRATEGY_DAY_NUM=6 ;;
    sunday)    STRATEGY_DAY_NUM=7 ;;
    *)         STRATEGY_DAY_NUM=1 ;;  # fallback: monday
esac

# Определяем какой сценарий запускать
case "$1" in
    "morning")
        # Определяем нужный сценарий: strategy_day → session-prep, иначе → day-plan
        if [ "$DAY_OF_WEEK" -eq "$STRATEGY_DAY_NUM" ]; then
            SCENARIO="session-prep"
        else
            SCENARIO="day-plan"
        fi

        # Защита от повторного запуска (RunAtLoad + CalendarInterval race condition)
        acquire_lock "$SCENARIO"
        if already_ran_today "$SCENARIO"; then
            log "SKIP: $SCENARIO already completed today"
            write_status_artifact "$(status_task_for_scenario "$SCENARIO")" "success" "0" "already completed earlier today" "verified" "same-day completion detected before rerun" "" "true"
            exit 0
        fi

        if [ "$DAY_OF_WEEK" -eq "$STRATEGY_DAY_NUM" ]; then
            log "Strategy day ($STRATEGY_DAY_NAME): running session prep"
            refresh_recovery_brief || true
            refresh_recovery_weekplan_context || true
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
        acquire_lock "week-review"
        if already_ran_this_week "week-review"; then
            log "SKIP: week-review already completed in current week-window"
            SCENARIO_STALENESS_BUDGET=604800
            write_status_artifact "$(status_task_for_scenario "week-review")" "success" "0" "already completed earlier this week-window" "verified" "same-week completion detected before rerun" "" "true"
            exit 0
        fi
        if [ "$DAY_OF_WEEK" -eq 1 ]; then
            log "Monday weekly window: running week review"
        else
            log "Manual/unscheduled: running week review"
        fi
        run_claude "week-review"
        # Fallback push for Knowledge Index (week-review creates a post there)
        KI_REPO="$(resolve_knowledge_index_dir || true)"
        if [ -n "$KI_REPO" ] && git -C "$KI_REPO" log --oneline -1 --since="1 hour ago" --grep="week-review" 2>/dev/null | grep -q .; then
            git -C "$KI_REPO" push >> "$LOG_FILE" 2>&1 && log "Pushed Knowledge Index (fallback)" || log "WARN: KI push failed"
        fi
        notify_telegram "week-review"
        ;;
    "session-prep")
        log "Manual: running session prep"
        refresh_recovery_brief || true
        refresh_recovery_weekplan_context || true
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
        # Canary: count bold notes before (exclude 🔄 — deferred ideas stay bold by design)
        FLEETING="$WORKSPACE/inbox/fleeting-notes.md"
        if [ ! -f "$FLEETING" ]; then
            log "WARN: fleeting-notes.md not found at $FLEETING — note-review canary will use zero counts"
        fi
        BOLD_BEFORE=$(count_bold_notes "$FLEETING")
        BOLD_NEW_BEFORE=$(count_new_bold_notes "$FLEETING")
        log "Canary: $BOLD_BEFORE bold total ($BOLD_NEW_BEFORE new, $(( BOLD_BEFORE - BOLD_NEW_BEFORE )) deferred 🔄)"

        run_claude "note-review"

        # Canary: count bold notes after — only NEW bold (without 🔄) should decrease
        BOLD_AFTER=$(count_bold_notes "$FLEETING")
        BOLD_NEW_AFTER=$(count_new_bold_notes "$FLEETING")
        log "Canary: $BOLD_AFTER bold total ($BOLD_NEW_AFTER new)"
        NON_BOLD=$(count_non_bold_content_lines "$FLEETING")
        log "Non-bold content lines: $NON_BOLD"
        if [ "$BOLD_NEW_AFTER" -ge "$BOLD_NEW_BEFORE" ] && [ "$BOLD_NEW_BEFORE" -gt 0 ]; then
            log "WARN: Note-Review Step 10 may have failed — new bold notes did not decrease ($BOLD_NEW_BEFORE → $BOLD_NEW_AFTER)"
        fi

        # Deterministic cleanup: archive non-bold, non-🔄 notes (safety net for LLM Step 10)
        log "Running deterministic cleanup..."
        CLEANUP_OUTPUT=$("$SCRIPT_DIR/cleanup-processed-notes.sh" 2>&1) || true
        log "Cleanup: $CLEANUP_OUTPUT"

        # If cleanup made changes, commit and push
        if ! git -C "$WORKSPACE" diff --quiet -- inbox/fleeting-notes.md archive/notes/Notes-Archive.md 2>/dev/null; then
            git -C "$WORKSPACE" add inbox/fleeting-notes.md archive/notes/Notes-Archive.md
            git -C "$WORKSPACE" commit -m "chore: auto-cleanup processed notes from fleeting-notes.md" >> "$LOG_FILE" 2>&1 || true
            git -C "$WORKSPACE" pull --rebase >> "$LOG_FILE" 2>&1 && log "Cleanup: pulled (rebase)" || log "WARN: cleanup pull --rebase failed"
            git -C "$WORKSPACE" push >> "$LOG_FILE" 2>&1 && log "Cleanup: pushed" || log "WARN: cleanup push failed"
        else
            log "Cleanup: no changes to commit"
        fi

        # Alert if LLM failed AND cleanup was needed (only for NEW bold, not deferred 🔄)
        if [ "$BOLD_NEW_AFTER" -ge "$BOLD_NEW_BEFORE" ] && [ "$BOLD_NEW_BEFORE" -gt 0 ]; then
            ENV_FILE="$HOME/.config/aist/env"
            if [ -f "$ENV_FILE" ]; then
                set -a; source "$ENV_FILE"; set +a
                ALERT_TEXT="⚠️ <b>Note-Review canary</b>: Step 10 не сработал ($BOLD_NEW_BEFORE → $BOLD_NEW_AFTER new bold). Deterministic cleanup applied."
                if ! NOTIFY_TEXT="$ALERT_TEXT" "$FMT_EXOCORTEX_DIR/roles/synchronizer/scripts/notify.sh" strategist note-review-canary >> "$LOG_FILE" 2>&1; then
                    ALERT_JSON=$(printf '%s' "$ALERT_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
                    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                        -H "Content-Type: application/json" \
                        -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":${ALERT_JSON},\"parse_mode\":\"HTML\"}" >> "$LOG_FILE" 2>&1 || true
                fi
            fi
        fi

        notify_telegram "note-review"
        ;;
    "day-close")
        log "Manual: day-close requested via strategist"
        fail_day_close_headless
        ;;
    "strategy-session")
        log "Manual: running strategy session (interactive)"
        run_claude "strategy-session"
        ;;
    *)
        echo "Usage: $0 {morning|note-review|week-review|session-prep|strategy-session|day-plan|day-close}"
        echo ""
        echo "Scenarios:"
        echo "  morning           - 4:00 EET daily (session-prep on Mon, day-plan others)"
        echo "  note-review       - 23:00 EET daily (review fleeting notes + clean inbox)"
        echo "  week-review       - Monday 00:00 local weekly review for club"
        echo "  session-prep      - Manual session prep (headless preparation)"
        echo "  strategy-session  - Manual strategy session (interactive with user)"
        echo "  day-plan          - Manual day plan"
        echo "  day-close         - Unsupported in headless strategist; use canonical protocol-close route"
        exit 1
        ;;
esac

log "Done"
