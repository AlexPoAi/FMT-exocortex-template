#!/bin/bash
# scheduler.sh — центральный диспетчер агентов экзокортекса
#
# Вызывается launchd (com.exocortex.scheduler) в нужные моменты.
# Состояние: ~/.local/state/exocortex/ (маркеры запуска + status artifacts)
#
# Использование:
#   scheduler.sh dispatch    — проверить расписание и запустить что нужно
#   scheduler.sh status      — показать состояние всех агентов

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$HOME/.local/state/exocortex"
STATUS_DIR="$STATE_DIR/status"
LOG_DIR="$HOME/logs/synchronizer"
LOG_FILE="$LOG_DIR/scheduler-$(date +%Y-%m-%d).log"

ROLES_DIR="$HOME/Github/FMT-exocortex-template/roles"
NOTIFY_SH="$SCRIPT_DIR/notify.sh"

# Role runner discovery: reads runner path from role.yaml, fallback to convention
get_role_runner() {
    local role="$1"
    local yaml="$ROLES_DIR/$role/role.yaml"
    if [ -f "$yaml" ]; then
        local runner
        runner=$(grep '^runner:' "$yaml" | sed 's/runner: *//' | tr -d '"' | tr -d "'")
        [ -n "$runner" ] && echo "$ROLES_DIR/$role/$runner" && return
    fi
    echo "$ROLES_DIR/$role/scripts/$role.sh"
}

STRATEGIST_SH="$(get_role_runner strategist)"
EXTRACTOR_SH="$(get_role_runner extractor)"

HOUR=$(date +%H)
DOW=$(date +%u)
DATE=$(date +%Y-%m-%d)
WEEK=$(date +%V)
NOW=$(date +%s)
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"

mkdir -p "$STATE_DIR" "$STATUS_DIR" "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scheduler] $1" | tee -a "$LOG_FILE"
}

escape_value() {
    printf '%s' "$1" | tr '\n' ' ' | sed 's/["\\]/\\&/g'
}

timestamp_to_epoch() {
    local ts="$1"
    [ -n "$ts" ] || {
        echo 0
        return
    }
    date -j -f '%Y-%m-%d %H:%M:%S' "$ts" '+%s' 2>/dev/null || date -d "$ts" '+%s' 2>/dev/null || echo 0
}

task_status_is_current() {
    local task="$1"
    local ref_ts="$2"
    local ref_date ref_epoch age

    ref_date=$(printf '%s' "$ref_ts" | cut -d' ' -f1)

    case "$task" in
        extractor-inbox-check)
            if ! (( 10#$HOUR >= 7 && 10#$HOUR <= 23 )); then
                [ "$ref_date" = "$DATE" ]
                return
            fi
            ref_epoch=$(timestamp_to_epoch "$ref_ts")
            [ "$ref_epoch" -gt 0 ] || return 1
            age=$(( NOW - ref_epoch ))
            [ "$age" -lt 10800 ]
            ;;
        *)
            [ "$ref_date" = "$DATE" ]
            ;;
    esac
}

status_file_for() {
    local task="$1"
    echo "$STATUS_DIR/${task}.status"
}

get_status_value() {
    local key="$1"
    local status_file="$2"
    [ -f "$status_file" ] || return 0
    awk -F= -v wanted="$key" '$1 == wanted {
        value=$0
        sub(/^[^=]+="/, "", value)
        sub(/"$/, "", value)
        print value
        exit
    }' "$status_file"
}

write_status() {
    local task="$1"
    local run_id="$2"
    local status="$3"
    local exit_code="$4"
    local summary="$5"
    local start_ts="$6"
    local end_ts="$7"
    local log_path="$8"
    local evidence_status="${9:-unknown}"
    local evidence_summary="${10:-}"
    local error_summary="${11:-}"
    local staleness_budget_sec="${12:-$(default_staleness_budget_for "$task")}"
    local produced_artifacts="${13:-}"
    local completed_window="${14:-false}"
    local status_file prev_last_success prev_last_failure last_success_at last_failure_at
    status_file=$(status_file_for "$task")

    prev_last_success=$(get_status_value "LAST_SUCCESS_AT" "$status_file")
    prev_last_failure=$(get_status_value "LAST_FAILURE_AT" "$status_file")
    last_success_at="$prev_last_success"
    last_failure_at="$prev_last_failure"

    case "$status" in
        success)
            last_success_at="$end_ts"
            ;;
        auth_failed|billing_failed|model_unavailable|network_failed|timed_out|preflight_failed|failed|stale_lock)
            last_failure_at="$end_ts"
            ;;
    esac

    cat > "$status_file" <<EOF
TASK_NAME="$task"
RUN_ID="$run_id"
STATUS="$status"
EXIT_CODE="$exit_code"
SUMMARY="$(escape_value "$summary")"
START_TS="$start_ts"
END_TS="$end_ts"
LAST_STARTED_AT="$start_ts"
LAST_FINISHED_AT="$end_ts"
LAST_SUCCESS_AT="$last_success_at"
LAST_FAILURE_AT="$last_failure_at"
EVIDENCE_STATUS="$evidence_status"
EVIDENCE_SUMMARY="$(escape_value "$evidence_summary")"
ERROR_SUMMARY="$(escape_value "$error_summary")"
STALENESS_BUDGET_SEC="$staleness_budget_sec"
PRODUCED_ARTIFACTS="$(escape_value "$produced_artifacts")"
COMPLETED_WINDOW="$completed_window"
LOG_PATH="$log_path"
UPDATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
}

classify_failure() {
    local tmp_out="$1"

    if grep -Eq 'ANTHROPIC_AUTH_TOKEN is not set|apiKeyHelper|authentication_error|OAuth token has expired|API Error: 401|Failed to authenticate|helper.*not.*set|invalid_grant' "$tmp_out" 2>/dev/null; then
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

    if grep -Eq 'TIMEOUT: strategist scenario exceeded|TIMEOUT_WRAPPER_ERROR' "$tmp_out" 2>/dev/null; then
        echo "timed_out"
        return
    fi

    if grep -Eq 'ECONNRESET|Unable to connect to API|timed out|ENOTFOUND|socket hang up' "$tmp_out" 2>/dev/null; then
        echo "network_failed"
        return
    fi

    if grep -Eq 'No such file or directory|command not found|Permission denied' "$tmp_out" 2>/dev/null; then
        echo "preflight_failed"
        return
    fi

    echo "failed"
}

mark_task_state() {
    local task="$1"
    local state_kind="$2"
    case "$state_kind" in
        daily)
            echo "$(date '+%H:%M:%S')" > "$STATE_DIR/$task-$DATE"
            ;;
        weekly)
            echo "$DATE $(date '+%H:%M:%S')" > "$STATE_DIR/$task-W$WEEK"
            ;;
        interval)
            echo "$NOW" > "$STATE_DIR/$task-last"
            ;;
    esac
}

default_staleness_budget_for() {
    case "$1" in
        extractor-inbox-check) echo 10800 ;;
        strategist-week-review) echo 604800 ;;
        strategist-note-review) echo 86400 ;;
        strategist-morning|synchronizer-code-scan|synchronizer-daily-report) echo 86400 ;;
        *) echo 43200 ;;
    esac
}

collect_task_evidence() {
    local task="$1"
    local tmp_out="$2"
    local evidence_status="weak"
    local evidence_summary=""
    local produced_artifacts=""

    case "$task" in
        strategist-morning)
            if grep -Eq 'Completed scenario: (session-prep|day-plan)|Scenario result: (session-prep|day-plan) status=success' "$LOG_FILE"; then
                evidence_status="verified"
                evidence_summary="в логе подтверждён успешный сценарий открытия дня"
            else
                evidence_summary="нет подтверждения успешного сценария открытия дня в логе"
            fi
            ;;
        strategist-note-review)
            if grep -Eq 'Completed scenario: note-review|Scenario result: note-review status=success' "$LOG_FILE"; then
                evidence_status="verified"
                evidence_summary="в логе подтверждён успешный разбор заметок"
            else
                evidence_summary="нет подтверждения успешного note-review в логе"
            fi
            ;;
        strategist-week-review)
            if grep -Eq 'Completed scenario: week-review|Scenario result: week-review status=success' "$LOG_FILE"; then
                evidence_status="verified"
                evidence_summary="в логе подтверждён успешный weekly review"
            else
                evidence_summary="нет подтверждения weekly review в логе"
            fi
            ;;
        synchronizer-code-scan)
            if [ -s "$tmp_out" ]; then
                evidence_status="verified"
                evidence_summary="сканирование кода вернуло ненулевой вывод"
            else
                evidence_summary="сканирование завершилось без диагностического вывода"
            fi
            ;;
        synchronizer-daily-report)
            local report_file="$HOME/Github/DS-strategy/current/SchedulerReport $DATE.md"
            local agents_file="$HOME/Github/DS-strategy/current/AGENTS-STATUS.md"
            local open_file="$HOME/Github/DS-strategy/current/SESSION-OPEN (Экран открытия сессии).md"
            if [ -s "$report_file" ] && [ -s "$agents_file" ] && [ -s "$open_file" ]; then
                evidence_status="verified"
                evidence_summary="созданы все артефакты daily-report"
                produced_artifacts="current/SchedulerReport $DATE.md;current/AGENTS-STATUS.md;current/SESSION-OPEN (Экран открытия сессии).md"
            else
                evidence_summary="не все артефакты daily-report созданы"
            fi
            ;;
        extractor-inbox-check)
            if grep -Eq 'Inbox-Check|inbox-check|CO\.' "$tmp_out"; then
                evidence_status="verified"
                evidence_summary="экстрактор оставил следы обработки inbox"
            else
                evidence_summary="нет следов обработки inbox в выводе"
            fi
            ;;
        *)
            evidence_status="weak"
            evidence_summary="для задачи не настроен evidence collector"
            ;;
    esac

    printf '%s\n%s\n%s\n' "$evidence_status" "$evidence_summary" "$produced_artifacts"
}

run_task() {
    local task="$1"
    local state_kind="$2"
    shift 2

    local start_ts end_ts tmp_out exit_code summary status evidence_status evidence_summary produced_artifacts error_summary
    start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    tmp_out=$(mktemp)

    write_status "$task" "$RUN_ID" "running" "" "started by scheduler" "$start_ts" "" "$LOG_FILE" "pending" "выполняется" "" "$(default_staleness_budget_for "$task")" ""

    set +e
    "$@" > "$tmp_out" 2>&1
    exit_code=$?
    set -e

    cat "$tmp_out" >> "$LOG_FILE"

    if [ "$exit_code" -eq 0 ]; then
        end_ts="$(date '+%Y-%m-%d %H:%M:%S')"
        summary="completed successfully"
        local evidence_output
        evidence_output="$(collect_task_evidence "$task" "$tmp_out")"
        evidence_status="$(printf '%s\n' "$evidence_output" | sed -n '1p')"
        evidence_summary="$(printf '%s\n' "$evidence_output" | sed -n '2p')"
        produced_artifacts="$(printf '%s\n' "$evidence_output" | sed -n '3p')"
        [ -n "$evidence_status" ] || evidence_status="weak"
        [ -n "$evidence_summary" ] || evidence_summary="нет подтверждённого evidence"

        if [ "$evidence_status" = "verified" ]; then
            write_status "$task" "$RUN_ID" "success" "0" "$summary" "$start_ts" "$end_ts" "$LOG_FILE" "$evidence_status" "$evidence_summary" "" "$(default_staleness_budget_for "$task")" "$produced_artifacts"
            mark_task_state "$task" "$state_kind"
            rm -f "$tmp_out"
            return 0
        fi

        error_summary="exit code 0 without operational evidence"
        write_status "$task" "$RUN_ID" "failed" "65" "task completed without evidence" "$start_ts" "$end_ts" "$LOG_FILE" "$evidence_status" "$evidence_summary" "$error_summary" "$(default_staleness_budget_for "$task")" "$produced_artifacts"
        rm -f "$tmp_out"
        return 65
    fi

    status=$(classify_failure "$tmp_out")
    summary=$(tail -20 "$tmp_out" | tr '\n' ' ' | sed 's/  */ /g')
    [ -n "$summary" ] || summary="task failed"
    end_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    error_summary="$summary"
    write_status "$task" "$RUN_ID" "$status" "$exit_code" "$summary" "$start_ts" "$end_ts" "$LOG_FILE" "failed" "операционное evidence не подтверждено" "$error_summary" "$(default_staleness_budget_for "$task")" ""
    rm -f "$tmp_out"
    return "$exit_code"
}

# === Управление состоянием ===

ran_today() {
    [ -f "$STATE_DIR/$1-$DATE" ]
}

ran_this_week() {
    [ -f "$STATE_DIR/$1-W$WEEK" ]
}

last_run_seconds_ago() {
    local marker="$STATE_DIR/$1-last"
    if [ -f "$marker" ]; then
        local prev
        prev=$(cat "$marker")
        echo $(( NOW - prev ))
    else
        echo 999999
    fi
}

cleanup_state() {
    find "$STATE_DIR" -name "*-202*" -mtime +7 -delete 2>/dev/null || true
    find "$STATUS_DIR" -name "*.status" -mtime +14 -delete 2>/dev/null || true
}

pre_archive_dayplan() {
    local strategy_dir="$HOME/Github/DS-strategy"
    local archive_dir="$strategy_dir/archive/day-plans"
    local moved=0

    mkdir -p "$archive_dir"

    for dayplan in "$strategy_dir/current"/DayPlan\ 20*.md; do
        [ -f "$dayplan" ] || continue
        local fname
        fname=$(basename "$dayplan")
        if [[ "$fname" == *"$DATE"* ]]; then continue; fi
        git -C "$strategy_dir" mv "$dayplan" "$archive_dir/" 2>/dev/null || mv "$dayplan" "$archive_dir/"
        moved=$((moved + 1))
        log "pre-archive: moved $fname → archive/day-plans/"
    done

    if [ "$moved" -gt 0 ]; then
        git -C "$strategy_dir" pull --rebase 2>/dev/null || true
        git -C "$strategy_dir" add current/ archive/day-plans/ 2>/dev/null || true
        git -C "$strategy_dir" commit -m "chore: archive $moved old DayPlan(s)" 2>/dev/null || true
        git -C "$strategy_dir" push 2>/dev/null || true
        log "pre-archive: committed and pushed ($moved file(s))"
    fi
}

dispatch() {
    log "dispatch started (hour=$HOUR, dow=$DOW)"
    local ran=0

    pre_archive_dayplan

    if [ "$DOW" = "1" ] && ! ran_this_week "strategist-week-review"; then
        log "→ strategist week-review (catch-up: hour=$HOUR)"
        if run_task "strategist-week-review" "weekly" "$STRATEGIST_SH" week-review; then
            :
        else
            log "WARN: strategist week-review failed (will retry next dispatch)"
        fi
        ran=1
    fi

    if (( 10#$HOUR >= 4 && 10#$HOUR < 22 )) && ! ran_today "strategist-morning"; then
        log "→ strategist morning (catch-up: hour=$HOUR)"
        if run_task "strategist-morning" "daily" "$STRATEGIST_SH" morning; then
            :
        else
            log "WARN: strategist morning failed (will retry next dispatch)"
        fi
        ran=1
    fi

    if (( 10#$HOUR >= 22 )) && ! ran_today "strategist-note-review"; then
        log "→ strategist note-review (catch-up: hour=$HOUR)"
        if run_task "strategist-note-review" "daily" "$STRATEGIST_SH" note-review; then
            :
        else
            log "WARN: strategist note-review failed (will retry next dispatch)"
        fi
        ran=1
    elif (( 10#$HOUR < 12 )); then
        local yesterday
        yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null || true)
        if [ -n "$yesterday" ] && [ ! -f "$STATE_DIR/strategist-note-review-$yesterday" ]; then
            log "→ strategist note-review (catch-up for yesterday $yesterday)"
            if run_task "strategist-note-review-catchup" "daily" "$STRATEGIST_SH" note-review; then
                echo "$(date '+%H:%M:%S') catch-up" > "$STATE_DIR/strategist-note-review-$yesterday"
            else
                log "WARN: strategist note-review catch-up failed"
            fi
            ran=1
        fi
    fi

    if ! ran_today "synchronizer-code-scan"; then
        log "→ synchronizer code-scan (hour=$HOUR)"
        if run_task "synchronizer-code-scan" "daily" "$SCRIPT_DIR/code-scan.sh"; then
            :
        else
            log "WARN: code-scan failed (will retry next dispatch)"
        fi
        ran=1
    fi

    if ! ran_today "synchronizer-daily-report"; then
        if ran_today "strategist-morning" || (( 10#$HOUR >= 6 )); then
            log "→ synchronizer daily-report (hour=$HOUR)"
            if run_task "synchronizer-daily-report" "daily" "$SCRIPT_DIR/daily-report.sh"; then
                :
            else
                log "WARN: daily-report failed (will retry next dispatch)"
            fi
            ran=1
        fi
    fi

    if (( 10#$HOUR >= 7 && 10#$HOUR <= 23 )); then
        local elapsed
        elapsed=$(last_run_seconds_ago "extractor-inbox-check")
        if [ "$elapsed" -ge 10800 ]; then
            log "→ extractor inbox-check (${elapsed}s since last)"
            if run_task "extractor-inbox-check" "interval" "$EXTRACTOR_SH" inbox-check; then
                :
            else
                log "WARN: extractor inbox-check failed (will retry next dispatch)"
            fi
            ran=1
        fi
    fi

    if [ "$ran" -eq 0 ]; then
        log "dispatch: nothing to run"
    fi

    cleanup_state
    log "dispatch completed"
}

show_status() {
    echo "=== Планировщик экзокортекса ==="
    echo "Дата: $DATE  Час: $HOUR  День недели: $DOW  Неделя: W$WEEK"
    echo ""

    echo "--- Запуски за сегодня ---"
    local daily_files
    daily_files=$(ls "$STATE_DIR"/*-"$DATE" 2>/dev/null || true)
    if [ -n "$daily_files" ]; then
        echo "$daily_files" | while read -r f; do
            echo "  $(basename "$f"): $(cat "$f")"
        done
    else
        echo "  нет запусков"
    fi

    echo ""
    echo "--- Интервальные маркеры ---"
    local interval_files
    interval_files=$(ls "$STATE_DIR"/*-last 2>/dev/null || true)
    if [ -n "$interval_files" ]; then
        echo "$interval_files" | while read -r f; do
            local ts ago
            ts=$(cat "$f")
            ago=$(( NOW - ts ))
            echo "  $(basename "$f"): ${ago}с назад"
        done
    else
        echo "  нет запусков"
    fi

    echo ""
    echo "--- Недельные маркеры ---"
    local week_files
    week_files=$(ls "$STATE_DIR"/*-W"$WEEK" 2>/dev/null || true)
    if [ -n "$week_files" ]; then
        echo "$week_files" | while read -r f; do
            echo "  $(basename "$f"): $(cat "$f")"
        done
    else
        echo "  нет запусков"
    fi

    echo ""
    echo "--- Последние статусы задач ---"
    local status_files
    status_files=$(ls "$STATUS_DIR"/*.status 2>/dev/null || true)
    if [ -n "$status_files" ]; then
        echo "$status_files" | while read -r f; do
            [ -f "$f" ] || continue
            . "$f"
            if task_status_is_current "$TASK_NAME" "${END_TS:-${UPDATED_AT:-}}"; then
                echo "  ${TASK_NAME}: ${STATUS} (обновлено ${UPDATED_AT})"
            else
                echo "  ${TASK_NAME}: stale (обновлено ${UPDATED_AT})"
            fi
        done
    else
        echo "  нет запусков"
    fi
}

case "${1:-}" in
    dispatch)
        dispatch
        ;;
    status)
        show_status
        ;;
    *)
        echo "Использование: scheduler.sh {dispatch|status}"
        echo ""
        echo "  dispatch  — проверить расписание и запустить нужных агентов"
        echo "  status    — показать текущее состояние всех агентов"
        exit 1
        ;;
esac
