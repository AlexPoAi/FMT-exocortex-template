#!/bin/bash
# daily-report.sh — ежедневный отчёт работы scheduler
#
# Формирует отчёт: что должно было сработать, что сработало, что нет.
#
# Если DS-agent-workspace/ существует → пишет туда (scheduler/reports/).
# Иначе → DS-strategy/current/ (обратная совместимость).
#
# Использование:
#   daily-report.sh           # сформировать отчёт за сегодня
#   daily-report.sh --dry-run # показать отчёт, не записывать

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.local/state/exocortex"
STATUS_DIR="$STATE_DIR/status"
LOG_DIR="$HOME/logs/synchronizer"
STRATEGY_DIR="$HOME/Github/DS-strategy"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/Github}"
CANONICAL_MEMORY_DIR="$WORKSPACE_DIR/memory"
RUNTIME_ARBITER_PATH="$WORKSPACE_DIR/FMT-exocortex-template/roles/synchronizer/scripts/runtime-arbiter.sh"
RUNTIME_POLICY_FILE="$WORKSPACE_DIR/DS-strategy/current/RUNTIME-POLICY.env"
RUNTIME_MODE_FILE="$WORKSPACE_DIR/DS-strategy/current/RUNTIME-MODE.md"

# Agent Workspace: если существует — отчёты идут туда
AGENT_WORKSPACE="$HOME/Github/DS-agent-workspace"
if [ -d "$AGENT_WORKSPACE/.git" ]; then
    REPORT_DIR="$AGENT_WORKSPACE/scheduler/reports"
    ARCHIVE_DIR="$AGENT_WORKSPACE/scheduler/reports/archive"
    COMMIT_DIR="$AGENT_WORKSPACE"
    COMMIT_ADD_PATHS=("scheduler/reports/")
else
    REPORT_DIR="$STRATEGY_DIR/current"
    ARCHIVE_DIR="$STRATEGY_DIR/archive/scheduler-reports"
    COMMIT_DIR="$STRATEGY_DIR"
    COMMIT_ADD_PATHS=("current/SchedulerReport"*.md "archive/scheduler-reports/")
fi

DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)
HOUR=$(date +%H)
WEEK=$(date +%V)

DRY_RUN=false
REFRESH_STATUS_ARTIFACTS=false
COMMIT_STRATEGY_ARTIFACTS=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            ;;
        --refresh-status-artifacts)
            REFRESH_STATUS_ARTIFACTS=true
            ;;
        --commit-strategy-artifacts)
            COMMIT_STRATEGY_ARTIFACTS=true
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

REPORT_FILE="$REPORT_DIR/SchedulerReport $DATE.md"
SCHEDULER_LOG="$LOG_DIR/scheduler-$DATE.log"
STRATEGIST_LOG="$HOME/logs/strategist/$DATE.log"
AGENTS_STATUS_FILE="$STRATEGY_DIR/current/AGENTS-STATUS.md"
SESSION_OPEN_FILE="$STRATEGY_DIR/current/SESSION-OPEN (Экран открытия сессии).md"

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$STRATEGY_DIR/current"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [daily-report] $1"
}

check_ran() {
    local marker="$1"
    if [ -f "$STATE_DIR/$marker-$DATE" ]; then
        cat "$STATE_DIR/$marker-$DATE"
        return 0
    fi
    return 1
}

check_ran_week() {
    local marker="$1"
    if [ -f "$STATE_DIR/$marker-W$WEEK" ]; then
        cat "$STATE_DIR/$marker-W$WEEK"
        return 0
    fi
    return 1
}

check_interval() {
    local marker="$1-last"
    if [ -f "$STATE_DIR/$marker" ]; then
        local ts ago
        ts=$(cat "$STATE_DIR/$marker")
        ago=$(( $(date +%s) - ts ))
        echo "${ago} сек назад"
        return 0
    fi
    return 1
}

timestamp_to_epoch() {
    local ts="$1"
    [ -n "$ts" ] || {
        echo 0
        return
    }
    date -j -f '%Y-%m-%d %H:%M:%S' "$ts" '+%s' 2>/dev/null || date -d "$ts" '+%s' 2>/dev/null || echo 0
}

task_reference_ts() {
    if [ -n "${END_TS:-}" ]; then
        echo "$END_TS"
    else
        echo "${UPDATED_AT:-}"
    fi
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

task_status_is_current() {
    local task="$1"
    local ref_ts="$2"
    local ref_date ref_epoch age budget

    ref_date=$(printf '%s' "$ref_ts" | cut -d' ' -f1)

    case "$task" in
        strategist-note-review|strategist-week-review)
            budget="${STALENESS_BUDGET_SEC:-$(default_staleness_budget_for "$task")}"
            ref_epoch=$(timestamp_to_epoch "$ref_ts")
            [ "$ref_epoch" -gt 0 ] || return 1
            age=$(( $(date +%s) - ref_epoch ))
            [ "$age" -lt "$budget" ]
            ;;
        extractor-inbox-check)
            if ! (( 10#$HOUR >= 7 && 10#$HOUR <= 23 )); then
                [ "$ref_date" = "$DATE" ]
                return
            fi
            ref_epoch=$(timestamp_to_epoch "$ref_ts")
            [ "$ref_epoch" -gt 0 ] || return 1
            age=$(( $(date +%s) - ref_epoch ))
            [ "$age" -lt 10800 ]
            ;;
        *)
            [ "$ref_date" = "$DATE" ]
            ;;
    esac
}

task_missing_is_expected() {
    local task="$1"

    case "$task" in
        strategist-morning)
            [ "$HOUR" -lt 4 ]
            ;;
        strategist-note-review)
            [ "$HOUR" -lt 22 ]
            ;;
        strategist-week-review)
            [ "$DOW" -ne 1 ]
            ;;
        synchronizer-daily-report)
            [ "$HOUR" -lt 6 ] && [ ! -f "$STATE_DIR/strategist-morning-$DATE" ]
            ;;
        extractor-inbox-check)
            ! (( 10#$HOUR >= 7 && 10#$HOUR <= 23 ))
            ;;
        *)
            return 1
            ;;
    esac
}

status_updated_epoch() {
    local ref_ts
    ref_ts=$(task_reference_ts)
    timestamp_to_epoch "$ref_ts"
}

apply_legacy_marker_override() {
    local task="$1"
    local current_epoch marker_epoch marker_ts marker_file week_file

    current_epoch=$(status_updated_epoch)

    marker_file="$STATE_DIR/${task}-$DATE"
    if [ -f "$marker_file" ]; then
        marker_ts="$DATE $(cat "$marker_file")"
        marker_epoch=$(timestamp_to_epoch "$marker_ts")
        if [ "$marker_epoch" -gt "${current_epoch:-0}" ]; then
            STATUS="success"
            EXIT_CODE="0"
            UPDATED_AT="$marker_ts"
            END_TS="$marker_ts"
            SUMMARY="derived from fresh daily marker"
            EVIDENCE_STATUS="derived"
            EVIDENCE_SUMMARY="fresh daily marker"
            return
        fi
    fi

    if [ "$task" = "strategist-week-review" ]; then
        week_file="$STATE_DIR/${task}-W$WEEK"
        if [ -f "$week_file" ]; then
            marker_ts="$(cat "$week_file")"
            marker_epoch=$(timestamp_to_epoch "$marker_ts")
            if [ "$marker_epoch" -gt "${current_epoch:-0}" ]; then
                STATUS="success"
                EXIT_CODE="0"
                UPDATED_AT="$marker_ts"
                END_TS="$marker_ts"
                SUMMARY="derived from fresh weekly marker"
                EVIDENCE_STATUS="derived"
                EVIDENCE_SUMMARY="fresh weekly marker"
                return
            fi
        fi
    fi

    if [ "$task" = "extractor-inbox-check" ] && [ -f "$STATE_DIR/${task}-last" ]; then
        marker_ts="$(date -r "$(cat "$STATE_DIR/${task}-last")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
        marker_epoch=$(timestamp_to_epoch "$marker_ts")
        if [ "$marker_epoch" -gt "${current_epoch:-0}" ]; then
            STATUS="success"
            EXIT_CODE="0"
            UPDATED_AT="$marker_ts"
            END_TS="$marker_ts"
            SUMMARY="derived from fresh interval marker"
            EVIDENCE_STATUS="derived"
            EVIDENCE_SUMMARY="fresh interval marker"
        fi
    fi
}

load_status() {
    local task="$1"
    local file="$STATUS_DIR/${task}.status"

    TASK_NAME="$task"
    STATUS="missing"
    EXIT_CODE=""
    SUMMARY="status artifact missing"
    UPDATED_AT=""
    EVIDENCE_STATUS=""
    EVIDENCE_SUMMARY=""

    if [ -f "$file" ]; then
        . "$file"
    elif [ -f "$STATE_DIR/${task}-$DATE" ]; then
        STATUS="success"
        UPDATED_AT="$DATE $(cat "$STATE_DIR/$task-$DATE")"
        SUMMARY="derived from legacy daily marker"
        EVIDENCE_STATUS="derived"
        EVIDENCE_SUMMARY="legacy marker"
    elif [ "$task" = "extractor-inbox-check" ] && [ -f "$STATE_DIR/${task}-last" ]; then
        STATUS="success"
        UPDATED_AT="$(date -r "$(cat "$STATE_DIR/${task}-last")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
        SUMMARY="derived from legacy interval marker"
        EVIDENCE_STATUS="derived"
        EVIDENCE_SUMMARY="legacy interval marker"
    fi

    apply_legacy_marker_override "$task"

    local ref_ts
    ref_ts=$(task_reference_ts)
    if [ "$STATUS" != "missing" ] && ! task_status_is_current "$task" "$ref_ts"; then
        STATUS="stale"
        EXIT_CODE=""
        SUMMARY="status artifact from previous window"
    fi

    if [ "$STATUS" = "stale" ] && task_missing_is_expected "$task"; then
        STATUS="missing"
        SUMMARY="task not scheduled in current window"
    fi
}

task_display_name() {
    case "$1" in
        strategist-morning) echo "Стратег: открытие дня" ;;
        strategist-note-review) echo "Стратег: разбор заметок" ;;
        strategist-week-review) echo "Стратег: обзор недели" ;;
        synchronizer-code-scan) echo "Синхронизатор: сканирование кода" ;;
        synchronizer-daily-report) echo "Синхронизатор: отчёт планировщика" ;;
        extractor-inbox-check) echo "Экстрактор: проверка входящих" ;;
        *) echo "$1" ;;
    esac
}

task_human_status() {
    case "$1" in
        success) echo "✅ успех" ;;
        running) echo "🔵 выполняется" ;;
        skipped) echo "⚪️ пропущен по правилу" ;;
        stale) echo "🟡 устаревший или неполный статус" ;;
        missing) echo "⚪️ нет статуса" ;;
        failed) echo "🔴 ошибка" ;;
        *) echo "🟡 $1" ;;
    esac
}

protocol_contract_status() {
    if [ -L "$CANONICAL_MEMORY_DIR" ] && [ ! -e "$CANONICAL_MEMORY_DIR" ]; then
        echo "broken"
        return
    fi

    if [ ! -d "$CANONICAL_MEMORY_DIR" ]; then
        echo "missing"
        return
    fi

    for protocol in protocol-open.md protocol-work.md protocol-close.md; do
        if [ ! -f "$CANONICAL_MEMORY_DIR/$protocol" ]; then
            echo "missing"
            return
        fi
    done

    echo "ok"
}

load_runtime_status() {
    RUNTIME_ARBITER_STATUS="missing"
    RUNTIME_PROVIDER_PRIMARY="unavailable"
    RUNTIME_PROVIDER_REASON="runtime_arbiter_missing"
    RUNTIME_CODEX_STATUS="unknown"
    RUNTIME_CODEX_REASON="not_checked"
    RUNTIME_CLAUDE_STATUS="unknown"
    RUNTIME_CLAUDE_REASON="not_checked"
    RUNTIME_LOCAL_STATUS="unknown"
    RUNTIME_LOCAL_REASON="not_checked"
    RUNTIME_CLOUD_RAG_STATUS="unknown"
    RUNTIME_CLOUD_RAG_REASON="not_checked"
    RUNTIME_POLICY_RESOLVED="unknown"
    RUNTIME_CLOUD_TAKEOVER_SCOPE="unknown"
    RUNTIME_CLOUD_BOT_DECLARED="unknown"

    if [ ! -x "$RUNTIME_ARBITER_PATH" ]; then
        return
    fi

    local tmp_env
    tmp_env=$(mktemp)
    if bash "$RUNTIME_ARBITER_PATH" --env > "$tmp_env" 2>/dev/null; then
        # shellcheck disable=SC1090
        source "$tmp_env"
        RUNTIME_ARBITER_STATUS="available"
        RUNTIME_PROVIDER_PRIMARY="${AI_CLI_PROVIDER_PRIMARY_RESOLVED:-unavailable}"
        RUNTIME_PROVIDER_REASON="${AI_CLI_PROVIDER_PRIMARY_REASON:-unknown}"
        RUNTIME_CODEX_STATUS="${AI_CLI_CODEX_STATUS:-unknown}"
        RUNTIME_CODEX_REASON="${AI_CLI_CODEX_REASON:-unknown}"
        RUNTIME_CLAUDE_STATUS="${AI_CLI_CLAUDE_STATUS:-unknown}"
        RUNTIME_CLAUDE_REASON="${AI_CLI_CLAUDE_REASON:-unknown}"
        RUNTIME_LOCAL_STATUS="${AI_RUNTIME_LOCAL_CONTROL:-unknown}"
        RUNTIME_LOCAL_REASON="${AI_RUNTIME_LOCAL_REASON:-unknown}"
        RUNTIME_CLOUD_RAG_STATUS="${AI_RUNTIME_CLOUD_RAG_STATUS:-unknown}"
        RUNTIME_CLOUD_RAG_REASON="${AI_RUNTIME_CLOUD_RAG_REASON:-unknown}"
        RUNTIME_POLICY_RESOLVED="${AI_RUNTIME_POLICY_RESOLVED:-unknown}"
        RUNTIME_CLOUD_TAKEOVER_SCOPE="${AI_RUNTIME_CLOUD_TAKEOVER_SCOPE:-unknown}"
        RUNTIME_CLOUD_BOT_DECLARED="${AI_RUNTIME_CLOUD_BOT_DECLARED:-unknown}"
    fi
    rm -f "$tmp_env"
}

build_agents_status() {
    local strategist="🟢 зелёный"
    local extractor="🟢 зелёный"
    local scheduler="🟢 зелёный"
    local sync="🟢 зелёный"
    local auth="🟢 зелёный"
    local brain="🟢 зелёный"
    local protocol_contract="🟢 зелёный"
    local runtime_plane="🟢 зелёный"
    local updated
    updated="$(date '+%Y-%m-%d %H:%M')"
    load_runtime_status

    case "$(protocol_contract_status)" in
        ok) ;;
        *)
            protocol_contract="🔴 требует внимания"
            brain="🟡 требует внимания"
            ;;
    esac

    case "$RUNTIME_ARBITER_STATUS" in
        available) ;;
        *)
            runtime_plane="🟡 требует внимания"
            brain="🟡 требует внимания"
            ;;
    esac

    if [ "$RUNTIME_PROVIDER_PRIMARY" = "unavailable" ]; then
        runtime_plane="🔴 требует внимания"
        brain="🔴 требует внимания"
    elif [ "$RUNTIME_CODEX_STATUS" != "available" ] || [ "$RUNTIME_CLAUDE_STATUS" != "available" ]; then
        [ "$runtime_plane" = "🟢 зелёный" ] && runtime_plane="🟡 требует внимания"
        [ "$brain" = "🟢 зелёный" ] && brain="🟡 требует внимания"
    fi

    for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
        load_status "$task"

        if [ "$STATUS" = "missing" ] && task_missing_is_expected "$task"; then
            continue
        fi

        case "$task" in
            strategist-*)
                case "$STATUS" in
                    failed|missing)
                        strategist="🔴 требует внимания"
                        brain="🟡 требует внимания"
                        ;;
                    stale)
                        [ "$strategist" = "🟢 зелёный" ] && strategist="🟡 требует внимания"
                        brain="🟡 требует внимания"
                        ;;
                esac
                ;;
            synchronizer-*)
                case "$STATUS" in
                    failed|missing)
                        scheduler="🔴 требует внимания"
                        sync="🔴 требует внимания"
                        brain="🟡 требует внимания"
                        ;;
                    stale)
                        [ "$scheduler" = "🟢 зелёный" ] && scheduler="🟡 требует внимания"
                        [ "$sync" = "🟢 зелёный" ] && sync="🟡 требует внимания"
                        brain="🟡 требует внимания"
                        ;;
                esac
                ;;
            extractor-*)
                case "$STATUS" in
                    failed|missing)
                        extractor="🔴 требует внимания"
                        brain="🟡 требует внимания"
                        ;;
                    stale)
                        [ "$extractor" = "🟢 зелёный" ] && extractor="🟡 требует внимания"
                        brain="🟡 требует внимания"
                        ;;
                esac
                ;;
        esac
    done

    cat <<EOF
# Статус агентов

- Мозг экзокортекса: **$brain**
- Планировщик: **$scheduler**
- Проверка среды: **🟢 зелёный**
- Помощник авторизации: **$auth**
- Canonical protocol route: **$protocol_contract**
- Runtime arbiter: **$runtime_plane**
- Статус-артефакты: **$sync**
- Стратег: **$strategist**
- Экстрактор: **$extractor**
- Обновлено: **$updated**

## Runtime

- Provider primary: **$RUNTIME_PROVIDER_PRIMARY**
- Provider reason: **$RUNTIME_PROVIDER_REASON**
- Codex: **$RUNTIME_CODEX_STATUS**
- Claude: **$RUNTIME_CLAUDE_STATUS**
- Runtime policy: **$RUNTIME_POLICY_RESOLVED**
- Local control plane: **$RUNTIME_LOCAL_STATUS**
- Cloud RAG: **$RUNTIME_CLOUD_RAG_STATUS**
- Cloud takeover scope: **$RUNTIME_CLOUD_TAKEOVER_SCOPE**
- Cloud bot runtime: **$RUNTIME_CLOUD_BOT_DECLARED**

## Задачи
EOF

    for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
        load_status "$task"
        printf -- "- %s: **%s**\n" "$(task_display_name "$task")" "$(task_human_status "$STATUS")"
    done
}

build_session_open() {
    local verdict_emoji="🟢"
    local verdict_label="Мозг экзокортекса — готов к работе"
    local verdict_color="🟢 green"
    local issues=""
    local stale_list=""
    local protocol_route_status="🟢 green"
    local runtime_plane_status="🟢 green"
    local provider_line="codex/claude availability unknown"
    local updated
    updated="$(date '+%Y-%m-%d %H:%M:%S')"
    load_runtime_status

    case "$(protocol_contract_status)" in
        ok) ;;
        broken)
            verdict_emoji="🔴"
            verdict_label="Мозг экзокортекса — требует внимания"
            verdict_color="🔴 red"
            protocol_route_status="🔴 red"
            issues="${issues}- Canonical protocol route broken: $CANONICAL_MEMORY_DIR\n"
            ;;
        missing)
            verdict_emoji="🔴"
            verdict_label="Мозг экзокортекса — требует внимания"
            verdict_color="🔴 red"
            protocol_route_status="🔴 red"
            issues="${issues}- Canonical protocol route incomplete: expected memory/protocol-open.md, memory/protocol-work.md, memory/protocol-close.md under $CANONICAL_MEMORY_DIR\n"
            ;;
    esac

    if [ "$RUNTIME_ARBITER_STATUS" != "available" ]; then
        [ "$verdict_emoji" = "🟢" ] && verdict_emoji="🟡"
        [ "$verdict_color" = "🟢 green" ] && verdict_color="🟡 yellow"
        [ "$verdict_label" = "Мозг экзокортекса — готов к работе" ] && verdict_label="Мозг экзокортекса — требует внимания"
        runtime_plane_status="🟡 yellow"
        issues="${issues}- Runtime arbiter unavailable: $RUNTIME_ARBITER_PATH\n"
    elif [ "$RUNTIME_PROVIDER_PRIMARY" = "unavailable" ]; then
        verdict_emoji="🔴"
        verdict_label="Мозг экзокортекса — требует внимания"
        verdict_color="🔴 red"
        runtime_plane_status="🔴 red"
        issues="${issues}- Runtime arbiter resolved no available provider\n"
    elif [ "$RUNTIME_CODEX_STATUS" != "available" ] || [ "$RUNTIME_CLAUDE_STATUS" != "available" ]; then
        [ "$verdict_emoji" = "🟢" ] && verdict_emoji="🟡"
        [ "$verdict_color" = "🟢 green" ] && verdict_color="🟡 yellow"
        [ "$verdict_label" = "Мозг экзокортекса — готов к работе" ] && verdict_label="Мозг экзокортекса — требует внимания"
        runtime_plane_status="🟡 yellow"
    fi

    provider_line="primary=$RUNTIME_PROVIDER_PRIMARY, codex=$RUNTIME_CODEX_STATUS, claude=$RUNTIME_CLAUDE_STATUS"

    for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
        load_status "$task"
        case "$STATUS" in
            failed)
                verdict_emoji="🔴"
                verdict_label="Мозг экзокортекса — требует внимания"
                verdict_color="🔴 red"
                issues="${issues}- $(task_display_name "$task"): ошибка\n"
                ;;
            missing)
                if ! task_missing_is_expected "$task"; then
                    verdict_emoji="🔴"
                    verdict_label="Мозг экзокортекса — требует внимания"
                    verdict_color="🔴 red"
                    issues="${issues}- $(task_display_name "$task"): нет статуса в текущем окне\n"
                fi
                ;;
            stale)
                [ "$verdict_emoji" = "🟢" ] && verdict_emoji="🟡"
                [ "$verdict_color" = "🟢 green" ] && verdict_color="🟡 yellow"
                [ "$verdict_label" = "Мозг экзокортекса — готов к работе" ] && verdict_label="Мозг экзокортекса — требует внимания"
                stale_list="${stale_list}- $(task_display_name "$task"): stale\n"
                ;;
        esac
    done

    cat <<EOF
# Экзокортекс: открытие сессии

## $verdict_emoji $verdict_label

- Режим открытия: **Продолжать только после явного подтверждения пользователя.**
- Итоговый verdict: **$verdict_color**
- Время проверки: **$updated**
- Последнее обновление статус-артефактов: **$updated**

## Приборная панель среды

- Планировщик: **🟢 green**
- Проверка среды: **🟢 green**
- Помощник авторизации: **🟢 green**
- Canonical protocol route: **$protocol_route_status**
- Runtime arbiter: **$runtime_plane_status**
- Статус-артефакты: **$( [ "$verdict_emoji" = "🔴" ] && echo "🔴 red" || [ "$verdict_emoji" = "🟡" ] && echo "🟡 yellow" || echo "🟢 green")**

## Runtime mode

- Provider plane: **$provider_line**
- Runtime policy: **$RUNTIME_POLICY_RESOLVED**
- Local control plane: **$RUNTIME_LOCAL_STATUS**
- Cloud RAG: **$RUNTIME_CLOUD_RAG_STATUS**
- Cloud takeover scope: **$RUNTIME_CLOUD_TAKEOVER_SCOPE**
- Cloud bot runtime: **$RUNTIME_CLOUD_BOT_DECLARED**

## Задачи агентов
EOF

    for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
        load_status "$task"
        printf -- "- %s: **%s**\n" "$(task_display_name "$task")" "$(task_human_status "$STATUS")"
    done

    if [ -n "$issues" ] || [ -n "$stale_list" ]; then
        printf "\n## Что требует внимания\n\n"
        [ -n "$issues" ] && printf "%b" "$issues"
        [ -n "$stale_list" ] && printf "%b" "$stale_list"
    fi

    cat <<'EOF'

## Обязательный ритуал согласования

1. Проверить WP Gate и найти РП недели.
2. Объявить: **Роль / Работа / РП / Метод / Оценка / Модель**.
3. Дождаться явного подтверждения пользователя.
4. Только после этого переходить к чтению файлов, поиску и реализации.
EOF
}

compute_traffic_light() {
    local color="GREEN"
    local issues=""

    if ! check_ran "synchronizer-code-scan" &>/dev/null; then
        color="RED"
        issues+="code-scan не запустился; "
    fi

    if (( 10#$HOUR >= 6 )) && ! check_ran "strategist-morning" &>/dev/null; then
        color="RED"
        issues+="strategist morning не запустился; "
    fi

    if [ -f "$SCHEDULER_LOG" ] && grep -q "push failed" "$SCHEDULER_LOG" 2>/dev/null; then
        if [ "$color" = "GREEN" ]; then color="YELLOW"; fi
        issues+="push failed (Mac оффлайн?); "
    fi

    if (( 10#$HOUR >= 23 )) && ! check_ran "strategist-note-review" &>/dev/null; then
        if [ "$color" = "GREEN" ]; then color="YELLOW"; fi
        issues+="note-review не запустился; "
    fi

    if [ "$DOW" = "1" ] && ! check_ran_week "strategist-week-review" &>/dev/null; then
        if [ "$color" = "GREEN" ]; then color="YELLOW"; fi
        issues+="week-review не запустился (Пн!); "
    fi

    local emoji label
    case "$color" in
        GREEN)  emoji="🟢"; label="Среда готова к работе" ;;
        YELLOW) emoji="🟡"; label="Среда работает с замечаниями" ;;
        RED)    emoji="🔴"; label="Критический сбой — требуется внимание" ;;
    esac

    echo "$emoji|$label|${issues:-нет}"
}

generate_report() {
    local report=""

    report+="---
type: scheduler-report
date: $DATE
week: W$WEEK
agent: Синхронизатор
---

# Отчёт планировщика: $DATE

"

    local tl_result tl_emoji tl_label tl_issues
    tl_result=$(compute_traffic_light)
    tl_emoji=$(echo "$tl_result" | cut -d'|' -f1)
    tl_label=$(echo "$tl_result" | cut -d'|' -f2)
    tl_issues=$(echo "$tl_result" | cut -d'|' -f3)

    report+="## $tl_emoji $tl_label

"
    if [ "$tl_issues" != "нет" ]; then
        report+="> **Замечания:** $tl_issues

"
    fi

    report+="## Результаты

| # | Задача | Статус | Время |
|---|--------|--------|-------|"

    # 1. Code-scan
    local cs_time
    if cs_time=$(check_ran "synchronizer-code-scan"); then
        report+="
| 1 | Сканирование кода | **✅** | $cs_time |"
    else
        report+="
| 1 | Сканирование кода | **❌** | — |"
    fi

    # 2. Стратег утренний
    local sm_time
    if sm_time=$(check_ran "strategist-morning"); then
        report+="
| 2 | Стратег утренний | **✅** | $sm_time |"
    else
        report+="
| 2 | Стратег утренний | **❌** | — |"
    fi

    # 3. Note-review (после 22:00)
    if (( 10#$HOUR >= 22 )); then
        local nr_time
        if nr_time=$(check_ran "strategist-note-review"); then
            report+="
| 3 | Разбор заметок | **✅** | $nr_time |"
        else
            report+="
| 3 | Разбор заметок | **❌** | — |"
        fi
    fi

    # 4. Week-review (Пн)
    if [ "$DOW" = "1" ]; then
        local wr_time
        if wr_time=$(check_ran_week "strategist-week-review"); then
            report+="
| 4 | Обзор недели | **✅** | $wr_time |"
        else
            report+="
| 4 | Обзор недели | **❌** | — |"
        fi
    fi

    # 5. Экстрактор inbox-check
    local ic_detail
    if ic_detail=$(check_interval "extractor-inbox-check"); then
        report+="
| 5 | Проверка входящих | **✅** | $ic_detail |"
    else
        report+="
| 5 | Проверка входящих | **❌** | — |"
    fi

    report+="

"

    load_runtime_status
    report+="## Runtime mode

- Provider primary: **$RUNTIME_PROVIDER_PRIMARY**
- Provider reason: **$RUNTIME_PROVIDER_REASON**
- Codex: **$RUNTIME_CODEX_STATUS** (\`$RUNTIME_CODEX_REASON\`)
- Claude: **$RUNTIME_CLAUDE_STATUS** (\`$RUNTIME_CLAUDE_REASON\`)
- Runtime policy: **$RUNTIME_POLICY_RESOLVED**
- Local control plane: **$RUNTIME_LOCAL_STATUS** (\`$RUNTIME_LOCAL_REASON\`)
- Cloud RAG: **$RUNTIME_CLOUD_RAG_STATUS** (\`$RUNTIME_CLOUD_RAG_REASON\`)
- Cloud takeover scope: **$RUNTIME_CLOUD_TAKEOVER_SCOPE**
- Cloud bot runtime: **$RUNTIME_CLOUD_BOT_DECLARED**
- Runtime policy file: **$( [ -f "$RUNTIME_POLICY_FILE" ] && echo "present" || echo "missing" )**
- Runtime mode artifact: **$( [ -f "$RUNTIME_MODE_FILE" ] && echo "present" || echo "missing" )**

"

    # Ошибки
    report+="## Ошибки и предупреждения
"
    local warnings=""
    if [ -f "$SCHEDULER_LOG" ]; then
        warnings=$(grep -E "WARN:|ERROR:|failed" "$SCHEDULER_LOG" 2>/dev/null | sed 's/^/- /' || true)
    fi

    if [ -n "$warnings" ]; then
        report+="
$warnings

**Что делать:**
"
        if echo "$warnings" | grep -q "push failed" 2>/dev/null; then
            report+="- **push failed:** Mac был оффлайн. Запусти \`cd $HOME/Github/DS-strategy && git pull --rebase && git push\`
"
        fi
    else
        report+="
Нет ошибок. ✅
"
    fi

    echo "$report"
}

refresh_runtime_mode_artifact() {
    if [ ! -x "$RUNTIME_ARBITER_PATH" ]; then
        log "WARN: runtime arbiter not executable: $RUNTIME_ARBITER_PATH"
        return 1
    fi

    if bash "$RUNTIME_ARBITER_PATH" >/dev/null 2>&1; then
        log "Runtime mode refreshed: $RUNTIME_MODE_FILE"
        return 0
    fi

    log "WARN: runtime arbiter refresh failed: $RUNTIME_ARBITER_PATH"
    return 1
}

write_status_artifacts() {
    build_agents_status > "$AGENTS_STATUS_FILE"
    log "Agents status written: $AGENTS_STATUS_FILE"
    build_session_open > "$SESSION_OPEN_FILE"
    log "Session open written: $SESSION_OPEN_FILE"
}

commit_strategy_artifacts() {
    if [ ! -d "$STRATEGY_DIR/.git" ]; then
        return 0
    fi

    git -C "$STRATEGY_DIR" add current/AGENTS-STATUS.md \
        'current/SESSION-OPEN (Экран открытия сессии).md' \
        current/RUNTIME-MODE.md 2>/dev/null || true

    if git -C "$STRATEGY_DIR" diff --cached --quiet 2>/dev/null; then
        log "No strategy artifact changes to commit"
        return 0
    fi

    if git -C "$STRATEGY_DIR" commit -m "auto: refresh opening artifacts $DATE" --quiet; then
        git -C "$STRATEGY_DIR" push --quiet 2>/dev/null || log "WARN: DS-strategy push failed — opening artifacts committed locally"
        log "Opening artifacts committed and pushed"
        return 0
    fi

    log "WARN: DS-strategy opening artifacts commit failed"
    return 1
}

archive_old_reports() {
    # WP-29: атомарная ротация — git mv staged отдельным коммитом,
    # fallback mv только если git mv упал (файл вне git-дерева).
    local count=0
    for old_report in "$REPORT_DIR"/SchedulerReport\ 20*.md; do
        [ -f "$old_report" ] || continue
        local basename
        basename=$(basename "$old_report")
        [[ "$basename" == *"$DATE"* ]] && continue
        if git -C "$COMMIT_DIR" mv "$old_report" "$ARCHIVE_DIR/" 2>/dev/null; then
            log "Staged for archive: $basename"
        else
            mv "$old_report" "$ARCHIVE_DIR/" 2>/dev/null || { log "WARN: mv failed for $basename — skipping"; continue; }
            log "Archived (fallback mv): $basename"
        fi
        count=$((count + 1))
    done

    if [ "$count" -gt 0 ]; then
        if ! git -C "$COMMIT_DIR" commit -m "chore: archive $count SchedulerReport(s) [$DATE]" --quiet 2>/dev/null; then
            log "ERROR: atomic archive commit failed — rolling back"
            git -C "$COMMIT_DIR" reset --quiet HEAD 2>/dev/null || true
            return 1
        fi
        log "Atomically archived and committed $count report(s)"
    fi
}

# === Main ===

log "=== Daily Report Started ==="

refresh_runtime_mode_artifact || true

if [ "$REFRESH_STATUS_ARTIFACTS" = true ]; then
    write_status_artifacts

    if [ "$COMMIT_STRATEGY_ARTIFACTS" = true ] && [ "$DRY_RUN" = false ]; then
        commit_strategy_artifacts || true
    fi

    log "=== Daily Report Completed ==="
    exit 0
fi

REPORT=$(generate_report)

if [ "$DRY_RUN" = true ]; then
    echo "$REPORT"
    log "DRY RUN — отчёт не записан"
else
    echo "$REPORT" > "$REPORT_FILE"
    log "Report written: $REPORT_FILE"
    write_status_artifacts

    cd "$COMMIT_DIR"
    git pull --rebase --quiet 2>/dev/null || log "INFO: pull --rebase skipped (offline or no changes)"
    git reset --quiet 2>/dev/null || true

    archive_old_reports

    for p in "${COMMIT_ADD_PATHS[@]}"; do
        git add "$p" 2>/dev/null || true
    done

    if ! git diff --cached --quiet 2>/dev/null; then
        if ! git commit -m "auto: scheduler report $DATE" --quiet; then
            log "ERROR: final commit failed — artifacts written but not committed"
            exit 1
        fi
        git push --quiet 2>/dev/null || log "WARN: push failed — committed locally but not pushed"
        log "Committed and pushed"
    else
        log "No changes to commit"
    fi

    commit_strategy_artifacts || true
fi

log "=== Daily Report Completed ==="
