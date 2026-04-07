#!/bin/bash
# Strategist (Стратег) Agent Runner
# Запускает Claude Code с заданным сценарием

set -e

# Предотвращаем сон: -i (idle, работает на батарее) -d (display) -u (user activity)
# Флаг -s (system sleep) не используем — он НЕ работает на батарее (OBC может переключить профиль)
caffeinate -diu -w $$ &

# Конфигурация
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE_ROOT="$HOME/Github"
if [ ! -d "$WORKSPACE_ROOT/DS-strategy/.git" ]; then
    WORKSPACE_ROOT="$HOME/IWE"
fi
WORKSPACE="$WORKSPACE_ROOT/DS-strategy"
PROMPTS_DIR="$REPO_DIR/prompts"
LOG_DIR="$HOME/logs/strategist"
CLAUDE_PATH="${CLAUDE_PATH:-$HOME/.local/bin/claude}"
CLAUDE_TIMEOUT=1800  # 30 мин — защита от зависания Claude CLI
AI_CLI_PRIMARY_MODEL="${AI_CLI_PRIMARY_MODEL:-${AI_CLI_MODEL:-claude-haiku-4-5}}"
AI_CLI_FALLBACK_MODEL="${AI_CLI_FALLBACK_MODEL:-claude-sonnet-4-6}"
GITHUB_USER="$(git -C "$WORKSPACE" remote get-url origin 2>/dev/null | sed 's|git@github.com:|https://github.com/|' | sed 's|https://github.com/||' | cut -d/ -f1 | head -1)"
[ -n "$GITHUB_USER" ] || GITHUB_USER="AlexPoAi"

# Template placeholders may survive in repo mode; prefer a real local Claude path.
if [ ! -x "$CLAUDE_PATH" ]; then
    CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"
fi

if [ -z "$CLAUDE_PATH" ] || [ ! -x "$CLAUDE_PATH" ]; then
    echo "ERROR: Claude CLI not found. Expected \$HOME/.local/bin/claude or command -v claude" >&2
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

# Определяем день недели и тип сценария
DAY_OF_WEEK=$(date +%u)  # 1=Mon, 7=Sun
DATE=$(date +%Y-%m-%d)

# Лог файл
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

notify_telegram_text() {
    local scenario="$1"
    local text="$2"
    NOTIFY_TEXT="$text" "$HOME/Github/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh" strategist "$scenario" >> "$LOG_FILE" 2>&1 || true
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

resolve_command_path() {
    local command_file="$1"

    case "$command_file" in
        day-close)
            printf '%s\n' "$HOME/Github/FMT-exocortex-template/memory/protocol-close.md"
            ;;
        day-plan)
            printf '%s\n' "$HOME/Github/FMT-exocortex-template/memory/protocol-open.md"
            ;;
        *)
            printf '%s\n' "$PROMPTS_DIR/$command_file.md"
            ;;
    esac
}

run_claude() {
    local command_file="$1"
    local command_path
    command_path=$(resolve_command_path "$command_file")

    if [ ! -f "$command_path" ]; then
        log "ERROR: Command file not found: $command_path"
        exit 1
    fi

    # Читаем содержимое команды
    local prompt
    prompt=$(python3 - "$command_path" "$WORKSPACE_ROOT" "$HOME" "$GITHUB_USER" <<'PY'
import sys
from pathlib import Path

path, workspace_dir, home_dir, github_user = sys.argv[1:5]
text = Path(path).read_text(encoding="utf-8")
text = text.replace("{{WORKSPACE_DIR}}", workspace_dir)
text = text.replace("{{HOME_DIR}}", home_dir)
text = text.replace("{{GITHUB_USER}}", github_user)
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

    cd "$WORKSPACE"

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
        timeout "$CLAUDE_TIMEOUT" "$CLAUDE_PATH" --dangerously-skip-permissions \
            --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
            --model "$attempt_model" \
            -p "$prompt" \
            > "$tmp_out" 2>&1 || rc=$?
        cat "$tmp_out" >> "$LOG_FILE"

        if grep -Eq 'authentication_error|OAuth token has expired|API Error: 401|Failed to authenticate|ANTHROPIC_AUTH_TOKEN is not set|API key is disabled' "$tmp_out" 2>/dev/null; then
            log "CRITICAL: Auth failed for scenario: $command_file — требуется claude /login"
            notify "🔴 Экзокортекс: AUTH FAILURE" "Стратег/$command_file: токен истёк. Запусти: claude /login"
            notify_telegram_text "auth-failure" "🔴 <b>Strategist auth failure</b>\n\nСценарий: <b>$command_file</b>\nДействие: выполнить <code>claude /login</code> и повторить запуск."
            rm -f "$tmp_out"
            return 1
        fi

        if [ "$rc" -eq 0 ]; then
            rm -f "$tmp_out"
            log "Completed scenario: $command_file"
            log "Scenario result: $command_file status=success exit_code=0 model=$attempt_model"
            break
        fi

        if [ "$attempt_index" -lt "$total_attempts" ] && is_model_unavailable_error "$tmp_out"; then
            local next_model="${model_candidates[$attempt_index]}"
            log "WARN: model unavailable for $command_file on $attempt_model — falling back to $next_model"
            rm -f "$tmp_out"
            continue
        fi

        rm -f "$tmp_out"
        if [ "$rc" -eq 124 ]; then
            log "ERROR: Claude CLI timed out after ${CLAUDE_TIMEOUT}s for scenario: $command_file (model=$attempt_model)"
            log "Scenario result: $command_file status=timeout exit_code=$rc model=$attempt_model"
            return 124
        fi

        log "ERROR: Claude CLI exited with code $rc for scenario: $command_file (model=$attempt_model)"
        log "Scenario result: $command_file status=failed exit_code=$rc model=$attempt_model"
        return "$rc"
    done

    # Push changes to GitHub (чтобы бот мог читать через API)
    if git -C "$WORKSPACE" diff --quiet origin/main..HEAD 2>/dev/null; then
        log "No unpushed commits"
    else
        git -C "$WORKSPACE" pull --rebase >> "$LOG_FILE" 2>&1 && log "Pulled (rebase)" || log "WARN: pull --rebase failed"
        git -C "$WORKSPACE" push >> "$LOG_FILE" 2>&1 && log "Pushed to GitHub" || log "WARN: git push failed"
    fi

    # Очистить staging area после Claude сессии (предотвращает staging leak в следующие скрипты)
    # НЕ трогаем working tree — только unstage orphaned changes
    git -C "$WORKSPACE" reset --quiet 2>/dev/null || true
    log "Cleared staging area after Claude session"

    # macOS notification
    local summary
    summary=$(tail -5 "$LOG_FILE" | grep -v '^\[' | head -3)
    notify "Стратег: $command_file" "$summary"
}

# Проверка: уже запускался ли сценарий сегодня
already_ran_today() {
    local scenario="$1"
    [ -f "$LOG_FILE" ] && grep -q "Completed scenario: $scenario" "$LOG_FILE"
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
            exit 2  # non-zero → scheduler won't mark_done
        fi

        log "WARN: stale lock detected for $scenario — removing $lockfile"
        rm -rf "$lockfile"
    fi

    if ! mkdir "$lockfile" 2>/dev/null; then
        log "SKIP: $scenario already running (lock exists: $lockfile)"
        exit 2
    fi
    echo "$$" > "$pidfile"
    # Auto-cleanup lock on exit
    trap "rm -f '$pidfile' 2>/dev/null; rmdir '$lockfile' 2>/dev/null" EXIT
}

# Читаем strategy_day из конфига (L4 Personal)
RHYTHM_CONFIG="$HOME/.claude/projects/-Users-$(whoami)-IWE/memory/day-rhythm-config.yaml"
STRATEGY_DAY_NAME=$(grep 'strategy_day:' "$RHYTHM_CONFIG" 2>/dev/null | awk '{print $2}' || echo "monday")
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
            exit 0
        fi

        if [ "$DAY_OF_WEEK" -eq "$STRATEGY_DAY_NUM" ]; then
            log "Strategy day ($STRATEGY_DAY_NAME): running session prep"
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
        if already_ran_today "week-review"; then
            log "SKIP: week-review already completed today"
            exit 0
        fi
        log "Sunday: running week review"
        run_claude "week-review"
        # Fallback push for Knowledge Index (week-review creates a post there)
        KI_REPO="$HOME/IWE/DS-Knowledge-Index"
        if git -C "$KI_REPO" log --oneline -1 --since="1 hour ago" --grep="week-review" 2>/dev/null | grep -q .; then
            git -C "$KI_REPO" push >> "$LOG_FILE" 2>&1 && log "Pushed Knowledge Index (fallback)" || log "WARN: KI push failed"
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
        # Canary: count bold notes before (exclude 🔄 — deferred ideas stay bold by design)
        FLEETING="$WORKSPACE/inbox/fleeting-notes.md"
        BOLD_BEFORE=$(grep -c '^\*\*' "$FLEETING" 2>/dev/null || echo 0)
        BOLD_NEW_BEFORE=$(grep '^\*\*' "$FLEETING" 2>/dev/null | grep -v '🔄' | grep -c '.' || echo 0)
        log "Canary: $BOLD_BEFORE bold total ($BOLD_NEW_BEFORE new, $(( BOLD_BEFORE - BOLD_NEW_BEFORE )) deferred 🔄)"

        run_claude "note-review"

        # Canary: count bold notes after — only NEW bold (without 🔄) should decrease
        BOLD_AFTER=$(grep -c '^\*\*' "$FLEETING" 2>/dev/null || echo 0)
        BOLD_NEW_AFTER=$(grep '^\*\*' "$FLEETING" 2>/dev/null | grep -v '🔄' | grep -c '.' || echo 0)
        log "Canary: $BOLD_AFTER bold total ($BOLD_NEW_AFTER new)"
        NON_BOLD=$(grep -c '^[^*#>-]' "$FLEETING" 2>/dev/null || echo 0)
        log "Non-bold content lines: $NON_BOLD"
        if [ "$BOLD_NEW_AFTER" -ge "$BOLD_NEW_BEFORE" ] && [ "$BOLD_NEW_BEFORE" -gt 0 ]; then
            log "WARN: Note-Review Step 10 may have failed — new bold notes did not decrease ($BOLD_NEW_BEFORE → $BOLD_NEW_AFTER)"
        fi

        # Deterministic cleanup: archive non-bold, non-🔄 notes (safety net for LLM Step 10)
        log "Running deterministic cleanup..."
        CLEANUP_OUTPUT=$(python3 "$SCRIPT_DIR/cleanup-processed-notes.py" 2>&1) || true
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
                if ! NOTIFY_TEXT="$ALERT_TEXT" "$HOME/Github/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh" strategist note-review-canary >> "$LOG_FILE" 2>&1; then
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
        echo ""
        echo "Scenarios:"
        echo "  morning           - 4:00 EET daily (session-prep on Mon, day-plan others)"
        echo "  note-review       - 23:00 EET daily (review fleeting notes + clean inbox)"
        echo "  week-review       - Sunday 19:00 EET review for club"
        echo "  session-prep      - Manual session prep (headless preparation)"
        echo "  strategy-session  - Manual strategy session (interactive with user)"
        echo "  day-plan          - Manual day plan"
        echo "  day-close         - Manual day close (update WeekPlan + MEMORY + backup)"
        exit 1
        ;;
esac

log "Done"
