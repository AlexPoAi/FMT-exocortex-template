#!/bin/bash
# daily-report.sh — ежедневный отчёт работы scheduler и стартовый экран открытия сессии

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.local/state/exocortex"
STATUS_DIR="$STATE_DIR/status"
LOG_DIR="$HOME/logs/synchronizer"
STRATEGY_DIR="/Users/alexander/Github/DS-strategy"
REPORT_DIR="$STRATEGY_DIR/current"
ARCHIVE_DIR="$STRATEGY_DIR/archive/scheduler-reports"

DATE=$(date +%Y-%m-%d)
TIME_NOW=$(date +%Y-%m-%d\ %H:%M:%S)
HOUR=$(date +%H)
DOW=$(date +%u)
WEEK=$(date +%V)
NOW_EPOCH=$(date +%s)

MODE="write"
case "${1:-}" in
    --dry-run)
        MODE="dry-run"
        ;;
    --session-open)
        MODE="session-open"
        ;;
    --session-open-hook)
        MODE="session-open-hook"
        ;;
esac

REPORT_FILE="$REPORT_DIR/SchedulerReport $DATE.md"
STATUS_FILE="$REPORT_DIR/AGENTS-STATUS.md"
OPEN_SCREEN_FILE="$REPORT_DIR/SESSION-OPEN (Экран открытия сессии).md"
SCHEDULER_LOG="$LOG_DIR/scheduler-$DATE.log"

mkdir -p "$ARCHIVE_DIR" "$REPORT_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [daily-report] $1"
}

format_epoch() {
    local ts="$1"
    if [ "$ts" -le 0 ]; then
        echo "—"
        return
    fi
    date -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "—"
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
    if [ -n "${LAST_FINISHED_AT:-}" ]; then
        echo "$LAST_FINISHED_AT"
    elif [ -n "${END_TS:-}" ]; then
        echo "$END_TS"
    else
        echo "${UPDATED_AT:-}"
    fi
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
            age=$(( NOW_EPOCH - ref_epoch ))
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

load_status() {
    local task="$1"
    local file="$STATUS_DIR/${task}.status"

    TASK_NAME="$task"
    STATUS="missing"
    EXIT_CODE=""
    SUMMARY="status artifact missing"
    START_TS=""
    END_TS=""
    LAST_STARTED_AT=""
    LAST_FINISHED_AT=""
    LAST_SUCCESS_AT=""
    LAST_FAILURE_AT=""
    EVIDENCE_STATUS="unknown"
    EVIDENCE_SUMMARY=""
    ERROR_SUMMARY=""
    STALENESS_BUDGET_SEC="$(default_staleness_budget_for "$task")"
    PRODUCED_ARTIFACTS=""
    LOG_PATH="$SCHEDULER_LOG"
    UPDATED_AT=""

    if [ -f "$file" ]; then
        . "$file"
    elif [ -f "$STATE_DIR/${task}-$DATE" ]; then
        STATUS="success"
        UPDATED_AT="$DATE $(cat "$STATE_DIR/${task}-$DATE")"
        END_TS="$UPDATED_AT"
        LAST_FINISHED_AT="$UPDATED_AT"
        LAST_SUCCESS_AT="$UPDATED_AT"
        EVIDENCE_STATUS="legacy"
        EVIDENCE_SUMMARY="derived from legacy daily marker"
        SUMMARY="derived from legacy daily marker"
    elif [ "$task" = "extractor-inbox-check" ] && [ -f "$STATE_DIR/${task}-last" ]; then
        STATUS="success"
        UPDATED_AT="$(format_epoch "$(cat "$STATE_DIR/${task}-last")")"
        END_TS="$UPDATED_AT"
        LAST_FINISHED_AT="$UPDATED_AT"
        LAST_SUCCESS_AT="$UPDATED_AT"
        EVIDENCE_STATUS="legacy"
        EVIDENCE_SUMMARY="derived from legacy interval marker"
        SUMMARY="derived from legacy interval marker"
    fi

    local ref_ts
    ref_ts=$(task_reference_ts)
    if [ "$STATUS" != "missing" ] && ! task_status_is_current "$task" "$ref_ts"; then
        STATUS="stale"
        EXIT_CODE=""
        SUMMARY="status artifact from previous window"
    fi

    if [ "$STATUS" = "success" ] && [ "${EVIDENCE_STATUS:-unknown}" != "verified" ] && [ "${EVIDENCE_STATUS:-unknown}" != "legacy" ]; then
        STATUS="failed"
        EXIT_CODE="65"
        ERROR_SUMMARY="success without verified operational evidence"
        SUMMARY="success without verified operational evidence"
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

render_evidence_label() {
    case "$1" in
        verified) echo "подтверждено" ;;
        legacy) echo "legacy-маркер" ;;
        pending) echo "в процессе" ;;
        failed) echo "не подтверждено" ;;
        weak) echo "слабое подтверждение" ;;
        *) echo "нет evidence" ;;
    esac
}

render_verdict_badge() {
    case "$1" in
        green) echo "🟢" ;;
        yellow) echo "🟡" ;;
        red) echo "🔴" ;;
        *) echo "⚪" ;;
    esac
}

check_file_freshness() {
    local path="$1"
    local budget="$2"
    [ -f "$path" ] || return 1
    local ts=0 age=999999999
    ts=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo 0)
    [ "$ts" -gt 0 ] || return 1
    age=$(( NOW_EPOCH - ts ))
    [ "$age" -le "$budget" ]
}

status_to_verdict() {
    case "$1" in
        success|skipped) echo "green" ;;
        running|stale) echo "yellow" ;;
        missing|auth_failed|billing_failed|model_unavailable|network_failed|timed_out|preflight_failed|failed|stale_lock) echo "red" ;;
        *) echo "yellow" ;;
    esac
}

component_line() {
    local label="$1"
    local state="$2"
    printf -- '- %s: **%s %s**\n' "$label" "$(render_verdict_badge "$state")" "$state"
}

build_evidence_problem_card() {
    local title="$1"
    local problem="$2"
    local evidence="$3"
    local impact="$4"
    local action="$5"
    printf '### %s\n- Проблема: %s\n- Доказательство: %s\n- Влияние: %s\n- Действие: %s\n\n' "$title" "$problem" "$evidence" "$impact" "$action"
}

    case "$1" in
        success) echo "✅" ;;
        skipped) echo "⏭️" ;;
        running) echo "🟦" ;;
        stale) echo "🟡" ;;
        auth_failed|billing_failed|model_unavailable|network_failed|timed_out|preflight_failed|failed|stale_lock) echo "❌" ;;
        *) echo "⚪" ;;
    esac
}

render_status_label() {
    case "$1" in
        success) echo "успех" ;;
        skipped) echo "пропущено по правилам" ;;
        running) echo "в процессе" ;;
        stale) echo "устаревший статус" ;;
        auth_failed) echo "ошибка авторизации" ;;
        billing_failed) echo "ошибка баланса или квоты" ;;
        model_unavailable) echo "недоступна запрошенная модель" ;;
        network_failed) echo "сетевая ошибка API" ;;
        timed_out) echo "превышен лимит времени" ;;
        preflight_failed) echo "ошибка предварительной проверки" ;;
        stale_lock) echo "зависшая блокировка" ;;
        failed) echo "ошибка" ;;
        *) echo "нет статуса" ;;
    esac
}

task_title() {
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

task_status_display() {
    local task="$1"
    load_status "$task"
    printf '%s %s' "$(render_status_badge "$STATUS")" "$(render_status_label "$STATUS")"
}

component_badge() {
    case "$1" in
        ok|loaded|fresh) echo "🟢" ;;
        warning|stale) echo "🟡" ;;
        broken|not_loaded|missing) echo "🔴" ;;
        *) echo "⚪" ;;
    esac
}

component_label() {
    case "$1" in
        ok) echo "исправен" ;;
        loaded) echo "загружен" ;;
        fresh) echo "свежие" ;;
        warning) echo "требует внимания" ;;
        stale) echo "устарели" ;;
        broken) echo "ошибка" ;;
        not_loaded) echo "не загружен" ;;
        missing) echo "отсутствуют" ;;
        *) echo "нет статуса" ;;
    esac
}

bool_state() {
    if [ "$1" = true ]; then
        echo "$2"
    else
        echo "$3"
    fi
}

latest_status_mtime() {
    local latest=0
    local found=false
    shopt -s nullglob
    for f in "$STATUS_DIR"/*.status; do
        [ -f "$f" ] || continue
        local ts=0
        ts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
        if [ "$ts" -gt "$latest" ]; then
            latest="$ts"
            found=true
        fi
    done
    shopt -u nullglob

    if [ "$found" = false ]; then
        echo 0
    else
        echo "$latest"
    fi
}

format_epoch() {
    local ts="$1"
    if [ "$ts" -le 0 ]; then
        echo "—"
        return
    fi
    date -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "—"
}

probe_environment() {
    SCHEDULER_STATE="red"
    HEALTH_STATE="red"
    AUTH_STATE="red"
    STATUS_ARTIFACTS_STATE="red"
    STATUS_ARTIFACTS_UPDATED_AT="—"
    STATUS_ARTIFACTS_AGE=""
    CREATIVE_CONVEYOR_STATE="red"
    DRIVE_SYNC_STATE="red"
    SESSION_WATCHER_STATE="red"
    CHAIN_REPORT_STATE="red"
    GOOGLE_DRIVE_STATE="red"
    STRATEGIST_OPERABILITY_STATE="red"
    EXTRACTOR_OPERABILITY_STATE="red"
    MANAGER_COLLECTION_STATE="yellow"
    RUNTIME_SCRIPTS_STATE="red"
    SECRETS_LAYER_STATE="red"

    if launchctl list | grep -q 'com.exocortex.scheduler'; then
        SCHEDULER_STATE="green"
    fi

    if launchctl list | grep -q 'com.exocortex.health-check'; then
        HEALTH_STATE="green"
    fi

    if [ -x "$HOME/.config/aist/anthropic_auth_helper.sh" ] && "$HOME/.config/aist/anthropic_auth_helper.sh" >/dev/null 2>&1; then
        AUTH_STATE="green"
    fi

    local latest_status_ts
    latest_status_ts=$(latest_status_mtime)
    STATUS_ARTIFACTS_UPDATED_AT=$(format_epoch "$latest_status_ts")
    if [ "$latest_status_ts" -gt 0 ]; then
        STATUS_ARTIFACTS_AGE=$(( NOW_EPOCH - latest_status_ts ))
        if [ "$STATUS_ARTIFACTS_AGE" -gt 43200 ]; then
            STATUS_ARTIFACTS_STATE="yellow"
        else
            STATUS_ARTIFACTS_STATE="green"
        fi
    fi

    if [ -d "$HOME/Github/creativ-convector/.git" ] && check_file_freshness "$HOME/Library/Logs/sync_obsidian.log" 21600; then
        CREATIVE_CONVEYOR_STATE="green"
    elif [ -d "$HOME/Github/creativ-convector/.git" ]; then
        CREATIVE_CONVEYOR_STATE="yellow"
    fi

    if [ -x "$HOME/Github/creativ-convector/.github/scripts/sync_obsidian.sh" ] && [ -d "$HOME/Documents/creativ-convector.nocloud" ] && check_file_freshness "$HOME/Library/Logs/sync_obsidian.log" 21600; then
        DRIVE_SYNC_STATE="green"
    elif [ -x "$HOME/Github/creativ-convector/.github/scripts/sync_obsidian.sh" ] && [ -d "$HOME/Documents/creativ-convector.nocloud" ]; then
        DRIVE_SYNC_STATE="yellow"
    fi

    if launchctl list | grep -q 'com.extractor.session-watcher'; then
        SESSION_WATCHER_STATE="green"
    elif [ -x "$HOME/Github/FMT-exocortex-template/roles/extractor/scripts/session-watcher.sh" ]; then
        SESSION_WATCHER_STATE="yellow"
    fi

    if check_file_freshness "$HOME/Github/DS-strategy/inbox/extraction-reports/$(date +%Y-%m-%d)-chain-report.md" 86400; then
        CHAIN_REPORT_STATE="green"
    elif ls "$HOME/Github/DS-strategy/inbox/extraction-reports/"*.md >/dev/null 2>&1; then
        CHAIN_REPORT_STATE="yellow"
    fi

    if [ -f "$HOME/Github/VK-offee/knowledge-base/sync-reports/sync-$DATE.md" ]; then
        GOOGLE_DRIVE_STATE="green"
    elif ls "$HOME/Github/VK-offee/knowledge-base/sync-reports/"sync-*.md >/dev/null 2>&1; then
        GOOGLE_DRIVE_STATE="yellow"
    fi

    load_status "strategist-morning"
    STRATEGIST_OPERABILITY_STATE=$(status_to_verdict "$STATUS")

    load_status "extractor-inbox-check"
    EXTRACTOR_OPERABILITY_STATE=$(status_to_verdict "$STATUS")

    if [ -f "$HOME/Github/DS-strategy/inbox/captures.md" ]; then
        MANAGER_COLLECTION_STATE="green"
    fi

    if [ -x "$SCRIPT_DIR/health-check.sh" ] && [ -x "$SCRIPT_DIR/scheduler.sh" ] && [ -x "$HOME/.config/aist/anthropic_auth_helper.sh" ]; then
        RUNTIME_SCRIPTS_STATE="green"
    elif [ -x "$SCRIPT_DIR/health-check.sh" ] || [ -x "$SCRIPT_DIR/scheduler.sh" ] || [ -x "$HOME/.config/aist/anthropic_auth_helper.sh" ]; then
        RUNTIME_SCRIPTS_STATE="yellow"
    fi

    if [ -f "$HOME/.config/aist/env" ] && [ -x "$HOME/.config/aist/anthropic_auth_helper.sh" ]; then
        SECRETS_LAYER_STATE="green"
    elif [ -f "$HOME/.config/aist/env" ] || [ -x "$HOME/.config/aist/anthropic_auth_helper.sh" ]; then
        SECRETS_LAYER_STATE="yellow"
    fi
}

append_row() {
    local index="$1"
    local task="$2"
    load_status "$task"
    local emoji label time_ref
    emoji=$(render_status_badge "$STATUS")
    label=$(render_status_label "$STATUS")
    time_ref="${END_TS:-${UPDATED_AT:-—}}"
    printf '| %s | %s | **%s %s** | %s |\n' "$index" "$(task_title "$task")" "$emoji" "$label" "$time_ref"
}

build_problem_cards() {
    local output=""
    for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
        load_status "$task"
        if [ "$STATUS" = "missing" ] && task_missing_is_expected "$task"; then
            continue
        fi
        case "$STATUS" in
            success|skipped|running)
                ;;
            *)
                output+="$(build_evidence_problem_card \
                    "$(task_title "$task")" \
                    "$(render_status_label "$STATUS")" \
                    "evidence=$(render_evidence_label "${EVIDENCE_STATUS:-unknown}"), summary=${EVIDENCE_SUMMARY:-${SUMMARY:-—}}, updated=${UPDATED_AT:-—}" \
                    "задача не может считаться truthful green" \
                    "проверить ${LOG_PATH:-лог} и восстановить operational evidence")"
                ;;
        esac
    done
    printf '%b' "$output"
}

build_environment_cards() {
    local output=""

    [ "$SCHEDULER_STATE" = "green" ] || output+="$(build_evidence_problem_card "Планировщик экзокортекса" "не подтверждена готовность" "launchctl verdict=$SCHEDULER_STATE" "утренний runtime не гарантирован" "проверить com.exocortex.scheduler через launchctl")"
    [ "$HEALTH_STATE" = "green" ] || output+="$(build_evidence_problem_card "Проверка среды" "не подтверждена" "launchctl verdict=$HEALTH_STATE" "деградации среды могут остаться незамеченными" "проверить com.exocortex.health-check")"
    [ "$AUTH_STATE" = "green" ] || output+="$(build_evidence_problem_card "Помощник авторизации" "helper/env слой не подтверждён" "anthropic_auth_helper verdict=$AUTH_STATE" "агенты не смогут честно выполнять сценарии" "проверить ~/.config/aist/env и anthropic_auth_helper.sh")"

    case "$STATUS_ARTIFACTS_STATE" in
        red) output+="$(build_evidence_problem_card "Статус-артефакты" "отсутствуют" "нет свежих *.status" "утренний экран не имеет источника истины" "запустить scheduler или daily-report")" ;;
        yellow) output+="$(build_evidence_problem_card "Статус-артефакты" "устарели" "последнее обновление: ${STATUS_ARTIFACTS_UPDATED_AT:-—}" "green не может считаться доказанным" "обновить снимок среды")" ;;
    esac

    [ "$DRIVE_SYNC_STATE" = "green" ] || output+="$(build_evidence_problem_card "Связка накопитель ↔ Obsidian" "контур не подтверждён" "sync_obsidian.log verdict=$DRIVE_SYNC_STATE" "сбор заметок может быть неполным" "проверить зеркало ~/Documents/creativ-convector.nocloud и sync_obsidian.sh")"
    [ "$SESSION_WATCHER_STATE" = "green" ] || output+="$(build_evidence_problem_card "Наблюдатель импортов сессий" "контур не подтверждён" "session-watcher verdict=$SESSION_WATCHER_STATE" "pending-sessions могут зависнуть" "проверить com.extractor.session-watcher")"
    [ "$CHAIN_REPORT_STATE" = "green" ] || output+="$(build_evidence_problem_card "Chain-report экстрактора" "нет свежего отчёта цепочки" "chain-report verdict=$CHAIN_REPORT_STATE" "невозможно доказать проход от сессии к captures/PACK" "проверить extraction-reports и session-import цепочку")"
    [ "$GOOGLE_DRIVE_STATE" = "green" ] || output+="$(build_evidence_problem_card "Google Drive sync" "нет свежего отчёта синхронизации" "sync report verdict=$GOOGLE_DRIVE_STATE" "внешние документы могли не попасть в Pack" "проверить sync_google_drive_v2.py и knowledge-base/sync-reports")"

    printf '%b' "$output"
}

evaluate_brain_state() {
    local failed_cards="$1"
    local env_cards="$2"

    BRAIN_STATE="green"
    BRAIN_BADGE="🟢"
    BRAIN_LABEL="готов к работе"
    OPENING_MODE="Обычное открытие дня разрешено."

    if [ "$AUTH_STATE" != "green" ] || [ "$SCHEDULER_STATE" != "green" ] || [ "$STATUS_ARTIFACTS_STATE" = "red" ] || [ "$STRATEGIST_OPERABILITY_STATE" = "red" ]; then
        BRAIN_STATE="red"
        BRAIN_BADGE="🔴"
        BRAIN_LABEL="обычное открытие заблокировано"
        OPENING_MODE="Сначала устранить критический сбой среды."
        return
    fi

    if [ "$HEALTH_STATE" != "green" ] || [ "$STATUS_ARTIFACTS_STATE" = "yellow" ] || [ -n "$failed_cards" ] || [ -n "$env_cards" ] || [ "$EXTRACTOR_OPERABILITY_STATE" != "green" ] || [ "$DRIVE_SYNC_STATE" != "green" ] || [ "$GOOGLE_DRIVE_STATE" != "green" ]; then
        BRAIN_STATE="yellow"
        BRAIN_BADGE="🟡"
        BRAIN_LABEL="требует внимания"
        OPENING_MODE="Продолжать только после явного подтверждения пользователя."
    fi
}

build_agents_status() {
    probe_environment
    local failed_cards env_cards
    failed_cards=$(build_problem_cards)
    env_cards=$(build_environment_cards)
    evaluate_brain_state "$failed_cards" "$env_cards"

    cat <<EOF
# Статус агентов

- Мозг экзокортекса: **$BRAIN_BADGE $BRAIN_LABEL**
- Планировщик: **$(component_badge "$SCHEDULER_STATE") $(component_label "$SCHEDULER_STATE")**
- Проверка среды: **$(component_badge "$HEALTH_STATE") $(component_label "$HEALTH_STATE")**
- Помощник авторизации: **$(component_badge "$AUTH_STATE") $(component_label "$AUTH_STATE")**
- Статус-артефакты: **$(component_badge "$STATUS_ARTIFACTS_STATE") $(component_label "$STATUS_ARTIFACTS_STATE")**
- Обновлено: **$TIME_NOW**

## Задачи
- $(task_title strategist-morning): **$(task_status_display strategist-morning)**
- $(task_title strategist-note-review): **$(task_status_display strategist-note-review)**
- $(task_title strategist-week-review): **$(task_status_display strategist-week-review)**
- $(task_title synchronizer-code-scan): **$(task_status_display synchronizer-code-scan)**
- $(task_title synchronizer-daily-report): **$(task_status_display synchronizer-daily-report)**
- $(task_title extractor-inbox-check): **$(task_status_display extractor-inbox-check)**
EOF
}

build_session_open_screen() {
    probe_environment
    local failed_cards env_cards attention_cards
    failed_cards=$(build_problem_cards)
    env_cards=$(build_environment_cards)
    attention_cards="${env_cards}${failed_cards}"
    evaluate_brain_state "$failed_cards" "$env_cards"

    cat <<EOF
# Экзокортекс: открытие сессии

## $BRAIN_BADGE Мозг экзокортекса — $BRAIN_LABEL

- Режим открытия: **$OPENING_MODE**
- Время проверки: **$TIME_NOW**
- Последнее обновление статус-артефактов: **$STATUS_ARTIFACTS_UPDATED_AT**

## Приборная панель среды

- Планировщик: **$(component_badge "$SCHEDULER_STATE") $(component_label "$SCHEDULER_STATE")**
- Проверка среды: **$(component_badge "$HEALTH_STATE") $(component_label "$HEALTH_STATE")**
- Помощник авторизации: **$(component_badge "$AUTH_STATE") $(component_label "$AUTH_STATE")**
- Статус-артефакты: **$(component_badge "$STATUS_ARTIFACTS_STATE") $(component_label "$STATUS_ARTIFACTS_STATE")**

## Критические связки среды

- Творческий конвейер: **$(component_badge "$CREATIVE_CONVEYOR_STATE") $(component_label "$CREATIVE_CONVEYOR_STATE")**
- Накопитель ↔ Obsidian: **$(component_badge "$DRIVE_SYNC_STATE") $(component_label "$DRIVE_SYNC_STATE")**
- Импорт сессий экстрактора: **$(component_badge "$SESSION_WATCHER_STATE") $(component_label "$SESSION_WATCHER_STATE")**
- Ключевые runtime-скрипты: **$(component_badge "$RUNTIME_SCRIPTS_STATE") $(component_label "$RUNTIME_SCRIPTS_STATE")**
- Секреты и helper-слой: **$(component_badge "$SECRETS_LAYER_STATE") $(component_label "$SECRETS_LAYER_STATE")**

## Задачи агентов

- $(task_title strategist-morning): **$(task_status_display strategist-morning)**
- $(task_title strategist-note-review): **$(task_status_display strategist-note-review)**
- $(task_title strategist-week-review): **$(task_status_display strategist-week-review)**
- $(task_title synchronizer-code-scan): **$(task_status_display synchronizer-code-scan)**
- $(task_title synchronizer-daily-report): **$(task_status_display synchronizer-daily-report)**
- $(task_title extractor-inbox-check): **$(task_status_display extractor-inbox-check)**

## Что требует внимания

$(if [ -n "$attention_cards" ]; then printf '%s' "$attention_cards"; else printf 'Активных проблем нет. Среда готова к работе. ✅\n'; fi)

## Обязательный ритуал согласования

1. Проверить WP Gate и найти РП недели.
2. Объявить: **Роль / Работа / РП / Метод / Оценка / Модель**.
3. Дождаться явного подтверждения пользователя.
4. Только после этого переходить к чтению файлов, поиску и реализации.
EOF
}

generate_report() {
    probe_environment
    local failed_cards env_cards attention_cards headline
    failed_cards=$(build_problem_cards)
    env_cards=$(build_environment_cards)
    attention_cards="${env_cards}${failed_cards}"
    evaluate_brain_state "$failed_cards" "$env_cards"

    headline="$BRAIN_BADGE Среда: $BRAIN_LABEL"

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
$(append_row 1 strategist-morning)
$(append_row 2 strategist-note-review)
$(append_row 3 strategist-week-review)
$(append_row 4 synchronizer-code-scan)
$(append_row 5 synchronizer-daily-report)
$(append_row 6 extractor-inbox-check)

## Проблемы и действия

$(if [ -n "$attention_cards" ]; then printf '%s' "$attention_cards"; else printf 'Нет активных проблем. ✅\n'; fi)
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

emit_session_open_hook_json() {
    local payload prompt open_screen
    payload=$(cat)
    prompt=$(printf '%s' "$payload" | jq -r '.prompt // .user_prompt // .userPrompt // .text // .message // .content // ""' 2>/dev/null || printf '')

    if ! printf '%s' "$prompt" | grep -Eiq '(^|[^[:alpha:]])(открывай день|начинаем работу|открывай рабочую сессию|открывай сессию|давай начинаем рабочую сессию|начинаем рабочую сессию)([^[:alpha:]]|$)'; then
        exit 0
    fi

    open_screen=$(build_session_open_screen)
    jq -n \
        --arg systemMessage "$open_screen" \
        --arg additionalContext "Пользователь запустил открытие рабочей сессии. Сначала покажи стартовый экран состояния экзокортекса, затем проведи ритуал согласования. Не переходи к задачам и не начинай исследование до явного подтверждения пользователя." \
        '{systemMessage:$systemMessage,hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$additionalContext}}'
}

REPORT=$(generate_report)
OPEN_SCREEN=$(build_session_open_screen)
AGENTS_STATUS=$(build_agents_status)

case "$MODE" in
    dry-run)
        echo "$REPORT"
        echo
        echo "$AGENTS_STATUS"
        echo
        echo "$OPEN_SCREEN"
        log "DRY RUN — отчёты не записаны"
        ;;
    session-open)
        echo "$OPEN_SCREEN"
        ;;
    session-open-hook)
        emit_session_open_hook_json
        ;;
    write)
        log "=== Daily Report Started ==="
        echo "$REPORT" > "$REPORT_FILE"
        echo "$AGENTS_STATUS" > "$STATUS_FILE"
        echo "$OPEN_SCREEN" > "$OPEN_SCREEN_FILE"
        log "Report written: $REPORT_FILE"
        log "Agent status written: $STATUS_FILE"
        log "Session open screen written: $OPEN_SCREEN_FILE"

        cd "$STRATEGY_DIR"
        git pull --rebase --quiet 2>/dev/null || log "WARN: pull --rebase failed (offline?)"
        git reset --quiet 2>/dev/null || true

        archive_old_reports

        git add "current/SchedulerReport"*.md "current/AGENTS-STATUS.md" "current/SESSION-OPEN (Экран открытия сессии).md" 2>/dev/null || true
        git add "archive/scheduler-reports/" 2>/dev/null || true

        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "auto: scheduler report $DATE" --quiet || log "WARN: commit failed"
            git push --quiet 2>/dev/null || log "WARN: push failed"
            log "Committed and pushed"
        else
            log "No changes to commit"
        fi
        log "=== Daily Report Completed ==="
        ;;
esac
