#!/bin/bash
# daily-report.sh — ежедневный отчёт работы scheduler

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.local/state/exocortex"
STATUS_DIR="$STATE_DIR/status"
LOG_DIR="$HOME/logs/synchronizer"
STRATEGY_DIR="/Users/alexander/Github/DS-strategy"
REPORT_DIR="$STRATEGY_DIR/current"
ARCHIVE_DIR="$STRATEGY_DIR/archive/scheduler-reports"

DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)
WEEK=$(date +%V)

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

REPORT_FILE="$REPORT_DIR/SchedulerReport $DATE.md"
STATUS_FILE="$REPORT_DIR/AGENTS-STATUS.md"
SCHEDULER_LOG="$LOG_DIR/scheduler-$DATE.log"

mkdir -p "$ARCHIVE_DIR" "$REPORT_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [daily-report] $1"
}

load_status() {
    local task="$1"
    local file="$STATUS_DIR/${task}.status"

    TASK_NAME="$task"
    STATUS="missing"
    EXIT_CODE=""
    SUMMARY="status artifact missing"
    START_TS=""
    END_TS=""
    LOG_PATH="$SCHEDULER_LOG"
    UPDATED_AT=""

    if [ -f "$file" ]; then
        . "$file"
    elif [ -f "$STATE_DIR/${task}-$DATE" ]; then
        STATUS="success"
        UPDATED_AT="$(cat "$STATE_DIR/${task}-$DATE")"
        END_TS="$UPDATED_AT"
        SUMMARY="derived from legacy daily marker"
    elif [ "$task" = "extractor-inbox-check" ] && [ -f "$STATE_DIR/${task}-last" ]; then
        STATUS="success"
        UPDATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
        END_TS="$UPDATED_AT"
        SUMMARY="derived from legacy interval marker"
    fi
}

render_status_badge() {
    case "$1" in
        success) echo "✅" ;;
        skipped) echo "⏭️" ;;
        running) echo "🟦" ;;
        auth_failed|preflight_failed|failed|stale_lock) echo "❌" ;;
        *) echo "⚪" ;;
    esac
}

render_status_label() {
    case "$1" in
        success) echo "успех" ;;
        skipped) echo "пропущено по правилам" ;;
        running) echo "в процессе" ;;
        auth_failed) echo "auth failure" ;;
        preflight_failed) echo "preflight failure" ;;
        stale_lock) echo "stale lock" ;;
        failed) echo "ошибка" ;;
        *) echo "нет статуса" ;;
    esac
}

append_row() {
    local index="$1"
    local title="$2"
    local task="$3"
    load_status "$task"
    local emoji label time_ref
    emoji=$(render_status_badge "$STATUS")
    label=$(render_status_label "$STATUS")
    time_ref="${END_TS:-${UPDATED_AT:-—}}"
    printf '| %s | %s | **%s %s** | %s |\n' "$index" "$title" "$emoji" "$label" "$time_ref"
}

build_problem_cards() {
    local output=""
    for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
        load_status "$task"
        case "$task:$STATUS" in
            strategist-week-review:missing)
                ;;
            *:success|*:skipped|*:running)
                ;;
            *)
                output+="### ${TASK_NAME}\n"
                output+="- Статус: $(render_status_label "$STATUS")\n"
                output+="- Обновлено: ${UPDATED_AT:-—}\n"
                output+="- Exit code: ${EXIT_CODE:-—}\n"
                output+="- Причина: ${SUMMARY:-—}\n"
                output+="- Лог: ${LOG_PATH:-—}\n\n"
                ;;
        esac
    done
    printf '%b' "$output"
}

build_agents_status() {
    local scheduler_state="not loaded"
    if launchctl list | grep -q 'com.exocortex.scheduler'; then
        scheduler_state="loaded"
    fi

    local health_state="not loaded"
    if launchctl list | grep -q 'com.exocortex.health-check'; then
        health_state="loaded"
    fi

    local auth_state="broken"
    if "$HOME/.config/aist/anthropic_auth_helper.sh" >/dev/null 2>&1; then
        auth_state="ok"
    fi

    cat <<EOF
# AGENTS-STATUS

- Scheduler: **$scheduler_state**
- Health-check: **$health_state**
- Auth helper: **$auth_state**
- Updated: **$(date '+%Y-%m-%d %H:%M:%S')**

## Tasks
- strategist-morning: **$(load_status strategist-morning; render_status_label "$STATUS")**
- strategist-note-review: **$(load_status strategist-note-review; render_status_label "$STATUS")**
- strategist-week-review: **$(load_status strategist-week-review; render_status_label "$STATUS")**
- synchronizer-code-scan: **$(load_status synchronizer-code-scan; render_status_label "$STATUS")**
- synchronizer-daily-report: **$(load_status synchronizer-daily-report; render_status_label "$STATUS")**
- extractor-inbox-check: **$(load_status extractor-inbox-check; render_status_label "$STATUS")**
EOF
}

generate_report() {
    local failed_cards
    failed_cards=$(build_problem_cards)
    local headline="🟢 Среда готова к работе"
    if [ -n "$failed_cards" ]; then
        headline="🔴 Требуется внимание"
    fi

    cat <<EOF
---
type: scheduler-report
date: $DATE
week: W$WEEK
agent: Синхронизатор
---

# Отчёт планировщика: $DATE

## $headline

## Результаты

| # | Задача | Статус | Время |
|---|--------|--------|-------|
$(append_row 1 "Сканирование кода" synchronizer-code-scan)
$(append_row 2 "Стратег утренний" strategist-morning)
$(append_row 3 "Разбор заметок" strategist-note-review)
$(append_row 4 "Обзор недели" strategist-week-review)
$(append_row 5 "Проверка входящих" extractor-inbox-check)
$(append_row 6 "Отчёт планировщика" synchronizer-daily-report)

## Проблемы и действия

$(if [ -n "$failed_cards" ]; then printf '%s' "$failed_cards"; else printf 'Нет активных проблем. ✅\n'; fi)
EOF
}

archive_old_reports() {
    local count=0
    for old_report in "$REPORT_DIR"/SchedulerReport\ 20*.md; do
        [ -f "$old_report" ] || continue
        local basename
        basename=$(basename "$old_report")
        [[ "$basename" == *"$DATE"* ]] && continue
        mv "$old_report" "$ARCHIVE_DIR/" 2>/dev/null || true
        log "Archived: $basename"
        count=$((count + 1))
    done
}

log "=== Daily Report Started ==="
REPORT=$(generate_report)
AGENTS_STATUS=$(build_agents_status)

if [ "$DRY_RUN" = true ]; then
    echo "$REPORT"
    echo
    echo "$AGENTS_STATUS"
    log "DRY RUN — отчёты не записаны"
else
    echo "$REPORT" > "$REPORT_FILE"
    echo "$AGENTS_STATUS" > "$STATUS_FILE"
    log "Report written: $REPORT_FILE"
    log "Agent status written: $STATUS_FILE"

    cd "$STRATEGY_DIR"
    git pull --rebase --quiet 2>/dev/null || log "WARN: pull --rebase failed (offline?)"
    git reset --quiet 2>/dev/null || true

    archive_old_reports

    git add "current/SchedulerReport"*.md "current/AGENTS-STATUS.md" 2>/dev/null || true
    git add "archive/scheduler-reports/" 2>/dev/null || true

    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "auto: scheduler report $DATE" --quiet || log "WARN: commit failed"
        git push --quiet 2>/dev/null || log "WARN: push failed"
        log "Committed and pushed"
    else
        log "No changes to commit"
    fi
fi

log "=== Daily Report Completed ==="
