#!/bin/bash
# Health Check для агентов экзокортекса

set -euo pipefail

LOG_DIR="$HOME/logs/health-check"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE_WORKSPACE_SH="$SCRIPT_DIR/resolve-workspace.sh"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE=$(date '+%Y-%m-%d')
HOUR=$(date +%H)
DOW=$(date +%u)
NOW_EPOCH=$(date +%s)
LOG_FILE="$LOG_DIR/$DATE.log"
ENV_FILE="$HOME/.config/aist/env"
STATE_DIR="$HOME/.local/state/exocortex"
STATUS_DIR="$STATE_DIR/status"
eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"
CANONICAL_MEMORY_DIR="$WORKSPACE_DIR/memory"
OPENING_CONTRACT_CHECK_PATH="$WORKSPACE_DIR/FMT-exocortex-template/roles/synchronizer/scripts/opening-contract-check.sh"
RUNTIME_ARBITER_PATH="$WORKSPACE_DIR/FMT-exocortex-template/roles/synchronizer/scripts/runtime-arbiter.sh"
RUNTIME_POLICY_FILE="$WORKSPACE_DIR/DS-strategy/current/RUNTIME-POLICY.env"
RUNTIME_MODE_FILE="$WORKSPACE_DIR/DS-strategy/current/RUNTIME-MODE.md"
OBSIDIAN_VAULT_DIR="${OBSIDIAN_VAULT_DIR:-$HOME/Documents/Творческий конвеер}"
SELECTION_BOARD_DIR="$OBSIDIAN_VAULT_DIR/Доска выбора"
SELECTION_BOARD_BEACON_FILE="$SELECTION_BOARD_DIR/00-Сводка доски выбора.md"
STRATEGIST_BOARD_DIR="$OBSIDIAN_VAULT_DIR/Доска стратега"
STRATEGIST_BOARD_BEACON_FILE="$STRATEGIST_BOARD_DIR/00-Свежесть доски стратега.md"
OBSIDIAN_FLEETING_DIR="${OBSIDIAN_FLEETING_DIR:-$OBSIDIAN_VAULT_DIR/1. Исчезающие заметки}"
OBSIDIAN_FLEETING_ARCHIVE_DIR="${OBSIDIAN_FLEETING_ARCHIVE_DIR:-$OBSIDIAN_VAULT_DIR/System/Архив исчезающих заметок}"
EXOCORTEX_CAPTURES_FILE="${EXOCORTEX_CAPTURES_FILE:-$WORKSPACE_DIR/DS-strategy/inbox/captures.md}"
OBSIDIAN_INTAKE_LOG_FILE="$HOME/logs/extractor/launchd-obsidian-fleeting-intake.log"
OBSIDIAN_INTAKE_LABEL="com.extractor.obsidian-fleeting-intake"

mkdir -p "$LOG_DIR"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

notify_macos() {
    local title="$1"
    local message="$2"
    message=$(printf '%s' "$message" | tr '"' "'" | tr '\n' ' ')
    printf 'display notification "%s" with title "%s" sound name "Basso"' "$message" "$title" | osascript 2>/dev/null || true
}

notify_telegram() {
    local message="$1"
    local notify_script="$FMT_EXOCORTEX_DIR/roles/synchronizer/scripts/notify.sh"

    if [ -x "$notify_script" ]; then
        NOTIFY_TEXT="$message" "$notify_script" synchronizer health-check > /dev/null 2>&1 && return 0
    fi

    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TELEGRAM_CHAT_ID" \
            --data-urlencode "text=$message" \
            -d "parse_mode=HTML" > /dev/null 2>&1 || true
    fi
}

format_epoch() {
    local ts="$1"
    if [ -z "$ts" ] || [ "$ts" -le 0 ]; then
        echo ""
        return
    fi
    date -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo ""
}

timestamp_to_epoch() {
    local ts="$1"
    [ -n "$ts" ] || {
        echo 0
        return
    }
    date -j -f '%Y-%m-%d %H:%M:%S' "$ts" '+%s' 2>/dev/null || date -d "$ts" '+%s' 2>/dev/null || echo 0
}

file_mtime_epoch() {
    local file="$1"
    [ -f "$file" ] || {
        echo 0
        return
    }
    stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || echo 0
}

task_reference_ts() {
    if [ -n "${END_TS:-}" ]; then
        echo "$END_TS"
    else
        echo "${UPDATED_AT:-}"
    fi
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
            age=$(( NOW_EPOCH - ref_epoch ))
            [ "$age" -lt "$budget" ]
            ;;
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
            return 1
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

task_should_be_marked_missed_window() {
    local task="$1"

    case "$task" in
        strategist-morning)
            (( 10#$HOUR >= 22 )) && [ ! -f "$STATE_DIR/${task}-$DATE" ]
            ;;
        *)
            return 1
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

check_protocol_contract() {
    local missing=0

    if [ -L "$CANONICAL_MEMORY_DIR" ] && [ ! -e "$CANONICAL_MEMORY_DIR" ]; then
        ERRORS+=("🔴 Canonical memory path broken: $CANONICAL_MEMORY_DIR")
        log "ОШИБКА: broken symlink for canonical memory path: $CANONICAL_MEMORY_DIR"
        return
    fi

    if [ ! -d "$CANONICAL_MEMORY_DIR" ]; then
        ERRORS+=("🔴 Canonical memory path missing: $CANONICAL_MEMORY_DIR")
        log "ОШИБКА: canonical memory path missing: $CANONICAL_MEMORY_DIR"
        return
    fi

    for protocol in protocol-open.md protocol-work.md protocol-close.md; do
        if [ ! -f "$CANONICAL_MEMORY_DIR/$protocol" ]; then
            ERRORS+=("🔴 Canonical protocol missing: memory/$protocol")
            log "ОШИБКА: canonical protocol missing: $CANONICAL_MEMORY_DIR/$protocol"
            missing=1
        fi
    done

    if [ "$missing" -eq 0 ]; then
        log "ОК: canonical protocol routes resolved from $CANONICAL_MEMORY_DIR"
    fi
}

check_opening_contract() {
    local tmp_output rc

    if [ ! -x "$OPENING_CONTRACT_CHECK_PATH" ]; then
        WARNINGS+=("🟡 Opening contract check missing: $OPENING_CONTRACT_CHECK_PATH")
        log "ВНИМАНИЕ: opening contract check missing: $OPENING_CONTRACT_CHECK_PATH"
        return
    fi

    tmp_output=$(mktemp)
    rc=0
    if ! bash "$OPENING_CONTRACT_CHECK_PATH" >"$tmp_output" 2>&1; then
        rc=$?
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            OK\ *)
                log "ОК: ${line#OK }"
                ;;
            WARN\ *)
                WARNINGS+=("🟡 Opening contract: ${line#WARN }")
                log "ВНИМАНИЕ: opening contract ${line#WARN }"
                ;;
            ERROR\ *)
                ERRORS+=("🔴 Opening contract: ${line#ERROR }")
                log "ОШИБКА: opening contract ${line#ERROR }"
                ;;
            *)
                log "INFO: opening contract $line"
                ;;
        esac
    done <"$tmp_output"

    rm -f "$tmp_output"

    case "$rc" in
        0|1|2) ;;
        *)
            WARNINGS+=("🟡 Opening contract check exited unexpectedly: rc=$rc")
            log "ВНИМАНИЕ: opening contract check exited unexpectedly: rc=$rc"
            ;;
    esac
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
            return
        fi
    fi

    if [ "$task" = "strategist-week-review" ]; then
        week_file="$STATE_DIR/${task}-W$(date +%V)"
        if [ -f "$week_file" ]; then
            marker_ts="$(cat "$week_file")"
            marker_epoch=$(timestamp_to_epoch "$marker_ts")
            if [ "$marker_epoch" -gt "${current_epoch:-0}" ]; then
                STATUS="success"
                EXIT_CODE="0"
                UPDATED_AT="$marker_ts"
                END_TS="$marker_ts"
                SUMMARY="derived from fresh weekly marker"
                return
            fi
        fi
    fi

    if [ "$task" = "extractor-inbox-check" ] && [ -f "$STATE_DIR/${task}-last" ]; then
        marker_ts="$(format_epoch "$(cat "$STATE_DIR/${task}-last")")"
        marker_epoch=$(timestamp_to_epoch "$marker_ts")
        if [ "$marker_epoch" -gt "${current_epoch:-0}" ]; then
            STATUS="success"
            EXIT_CODE="0"
            UPDATED_AT="$marker_ts"
            END_TS="$marker_ts"
            SUMMARY="derived from fresh interval marker"
        fi
    fi
}

check_runtime_contract() {
    load_runtime_status

    if [ ! -f "$RUNTIME_POLICY_FILE" ]; then
        WARNINGS+=("🟡 Runtime policy file missing: $RUNTIME_POLICY_FILE")
        log "ВНИМАНИЕ: runtime policy file missing: $RUNTIME_POLICY_FILE"
    fi

    if [ "$RUNTIME_ARBITER_STATUS" != "available" ]; then
        WARNINGS+=("🟡 Runtime arbiter unavailable: $RUNTIME_ARBITER_PATH")
        log "ВНИМАНИЕ: runtime arbiter unavailable: $RUNTIME_ARBITER_PATH"
        return
    fi

    log "ОК: runtime arbiter provider=$RUNTIME_PROVIDER_PRIMARY reason=$RUNTIME_PROVIDER_REASON codex=$RUNTIME_CODEX_STATUS claude=$RUNTIME_CLAUDE_STATUS local=$RUNTIME_LOCAL_STATUS cloud-rag=$RUNTIME_CLOUD_RAG_STATUS"

    if [ "$RUNTIME_PROVIDER_PRIMARY" = "unavailable" ]; then
        ERRORS+=("🔴 Runtime arbiter: no available AI provider")
        log "ОШИБКА: runtime arbiter resolved no available provider"
    fi

    if [ "$RUNTIME_CODEX_STATUS" != "available" ] && [ "$RUNTIME_CLAUDE_STATUS" != "available" ]; then
        ERRORS+=("🔴 Provider plane degraded: Codex and Claude both unavailable")
        log "ОШИБКА: both Codex and Claude unavailable"
    elif [ "$RUNTIME_CODEX_STATUS" != "available" ] || [ "$RUNTIME_CLAUDE_STATUS" != "available" ]; then
        WARNINGS+=("🟡 Provider plane degraded: codex=$RUNTIME_CODEX_STATUS, claude=$RUNTIME_CLAUDE_STATUS")
        log "ВНИМАНИЕ: provider plane partially degraded: codex=$RUNTIME_CODEX_STATUS, claude=$RUNTIME_CLAUDE_STATUS"
    fi

    if [ ! -f "$RUNTIME_MODE_FILE" ]; then
        WARNINGS+=("🟡 Runtime mode artifact missing: $RUNTIME_MODE_FILE")
        log "ВНИМАНИЕ: runtime mode artifact missing: $RUNTIME_MODE_FILE"
    else
        log "ОК: runtime mode artifact present: $RUNTIME_MODE_FILE"
    fi
}

check_legacy_launchd_conflicts() {
    local loaded=""

    if ! command -v launchctl >/dev/null 2>&1; then
        log "INFO: launchctl недоступен, проверка legacy launchd конфликтов пропущена"
        return
    fi

    if launchctl list | grep -q 'com.strategist.morning'; then
        loaded="$loaded com.strategist.morning"
    fi

    if launchctl list | grep -q 'com.strategist.weekreview'; then
        loaded="$loaded com.strategist.weekreview"
    fi

    loaded=$(printf '%s' "$loaded" | xargs 2>/dev/null || true)

    if [ -n "$loaded" ]; then
        ERRORS+=("🔴 Legacy Strategist launchd jobs loaded alongside scheduler: $loaded")
        log "ОШИБКА: legacy Strategist launchd jobs loaded alongside scheduler: $loaded"
    else
        log "ОК: legacy Strategist launchd jobs are not loaded"
    fi
}

check_strategist_notify_contract() {
    local template="$WORKSPACE_DIR/FMT-exocortex-template/roles/synchronizer/scripts/templates/strategist.sh"
    local rendered_template="$template"
    local tmp_template=""
    local message=""

    if [ ! -f "$template" ]; then
        WARNINGS+=("🟡 Strategist notify template missing: $template")
        log "ВНИМАНИЕ: strategist notify template missing: $template"
        return
    fi

    if grep -qE '\{\{[A-Z_]+\}\}' "$template" 2>/dev/null; then
        tmp_template=$(mktemp)
        workspace_val="${WORKSPACE_DIR:-$HOME/Github}"
        home_val="${HOME_DIR:-$HOME}"
        gov_repo_val="${IWE_GOVERNANCE_REPO:-DS-strategy}"
        iwe_template_val="${IWE_TEMPLATE:-$workspace_val/FMT-exocortex-template}"
        iwe_runtime_val="${IWE_RUNTIME:-$workspace_val/.iwe-runtime}"
        github_user_val="${GITHUB_USER:-AlexPoAi}"
        claude_slug_val="${CLAUDE_PROJECT_SLUG:-$(echo "$workspace_val" | tr '/' '-')}"

        esc() { printf '%s' "$1" | sed 's/[&|]/\\&/g'; }

        sed \
            -e "s|{{WORKSPACE_DIR}}|$(esc "$workspace_val")|g" \
            -e "s|{{HOME_DIR}}|$(esc "$home_val")|g" \
            -e "s|{{GOVERNANCE_REPO}}|$(esc "$gov_repo_val")|g" \
            -e "s|{{IWE_TEMPLATE}}|$(esc "$iwe_template_val")|g" \
            -e "s|{{IWE_RUNTIME}}|$(esc "$iwe_runtime_val")|g" \
            -e "s|{{GITHUB_USER}}|$(esc "$github_user_val")|g" \
            -e "s|{{CLAUDE_PROJECT_SLUG}}|$(esc "$claude_slug_val")|g" \
            "$template" > "$tmp_template"
        rendered_template="$tmp_template"
    fi

    message=$(bash -lc "source '$rendered_template' && build_message week-review" 2>/dev/null || true)
    [ -n "$tmp_template" ] && rm -f "$tmp_template"

    if [ -z "$message" ]; then
        ERRORS+=("🔴 Strategist notify contract broken: week-review template returned empty message")
        log "ОШИБКА: strategist notify contract broken: week-review template returned empty message"
    else
        log "ОК: strategist notify template builds week-review message"
    fi
}

human_layer_selection_status() {
    if [ ! -d "$SELECTION_BOARD_DIR" ]; then
        echo "missing"
        return
    fi

    if [ ! -f "$SELECTION_BOARD_BEACON_FILE" ]; then
        echo "missing"
        return
    fi

    if ! grep -q '^updated: '"$DATE"'$' "$SELECTION_BOARD_BEACON_FILE" 2>/dev/null; then
        echo "stale"
        return
    fi

    if grep -q '🟡 Ждут ручного решения: \*\*[1-9]' "$SELECTION_BOARD_BEACON_FILE" 2>/dev/null; then
        echo "needs_attention"
        return
    fi

    echo "ok"
}

human_layer_strategist_status() {
    local beacon_status

    if [ ! -d "$STRATEGIST_BOARD_DIR" ]; then
        echo "missing"
        return
    fi

    if [ ! -f "$STRATEGIST_BOARD_BEACON_FILE" ]; then
        echo "missing"
        return
    fi

    beacon_status="$(sed -n 's/^- Общий статус: \*\*\(.*\)\*\*$/\1/p' "$STRATEGIST_BOARD_BEACON_FILE" | head -n1)"
    case "$beacon_status" in
        свежо) echo "ok" ;;
        "требует внимания") echo "needs_attention" ;;
        устарело) echo "stale" ;;
        "ждёт ручного решения") echo "needs_attention" ;;
        *)
            if grep -q '^updated: '"$DATE"'$' "$STRATEGIST_BOARD_BEACON_FILE" 2>/dev/null; then
                echo "ok"
            else
                echo "stale"
            fi
            ;;
    esac
}

check_human_layer_contract() {
    local selection_status strategist_status

    selection_status="$(human_layer_selection_status)"
    strategist_status="$(human_layer_strategist_status)"

    case "$selection_status" in
        ok)
            log "ОК: human-layer selection board beacon свежий"
            ;;
        needs_attention)
            WARNINGS+=("🟡 Human layer: Доска выбора ждёт ручного решения")
            log "ВНИМАНИЕ: human-layer selection board ждёт ручного решения"
            ;;
        stale)
            WARNINGS+=("🟡 Human layer: Доска выбора устарела")
            log "ВНИМАНИЕ: human-layer selection board stale"
            ;;
        missing)
            WARNINGS+=("🟡 Human layer: missing beacon для Доски выбора")
            log "ВНИМАНИЕ: human-layer selection board beacon missing"
            ;;
    esac

    case "$strategist_status" in
        ok)
            log "ОК: human-layer strategist board свежий"
            ;;
        needs_attention)
            WARNINGS+=("🟡 Human layer: Доска стратега требует внимания")
            log "ВНИМАНИЕ: human-layer strategist board requires attention"
            ;;
        stale)
            WARNINGS+=("🟡 Human layer: Доска стратега устарела")
            log "ВНИМАНИЕ: human-layer strategist board stale"
            ;;
        missing)
            WARNINGS+=("🟡 Human layer: missing beacon для Доски стратега")
            log "ВНИМАНИЕ: human-layer strategist board beacon missing"
            ;;
    esac
}

check_obsidian_contour() {
    local stale_sec=172800
    local log_epoch age imported_line

    if [ -d "$OBSIDIAN_VAULT_DIR" ]; then
        log "ОК: Obsidian vault доступен: $OBSIDIAN_VAULT_DIR"
    else
        ERRORS+=("🔴 Obsidian vault missing: $OBSIDIAN_VAULT_DIR")
        log "ОШИБКА: Obsidian vault missing: $OBSIDIAN_VAULT_DIR"
        return
    fi

    if [ -d "$OBSIDIAN_FLEETING_DIR" ]; then
        log "ОК: Obsidian fleeting dir доступен: $OBSIDIAN_FLEETING_DIR"
    else
        WARNINGS+=("🟡 Obsidian fleeting dir missing: $OBSIDIAN_FLEETING_DIR")
        log "ВНИМАНИЕ: Obsidian fleeting dir missing: $OBSIDIAN_FLEETING_DIR"
    fi

    if [ -d "$OBSIDIAN_FLEETING_ARCHIVE_DIR" ]; then
        log "ОК: Obsidian archive dir доступен: $OBSIDIAN_FLEETING_ARCHIVE_DIR"
    else
        WARNINGS+=("🟡 Obsidian archive dir missing: $OBSIDIAN_FLEETING_ARCHIVE_DIR")
        log "ВНИМАНИЕ: Obsidian archive dir missing: $OBSIDIAN_FLEETING_ARCHIVE_DIR"
    fi

    if [ -f "$EXOCORTEX_CAPTURES_FILE" ]; then
        log "ОК: captures file доступен: $EXOCORTEX_CAPTURES_FILE"
    else
        ERRORS+=("🔴 captures file missing: $EXOCORTEX_CAPTURES_FILE")
        log "ОШИБКА: captures file missing: $EXOCORTEX_CAPTURES_FILE"
    fi

    if command -v launchctl >/dev/null 2>&1; then
        if launchctl list | grep -q "$OBSIDIAN_INTAKE_LABEL"; then
            log "ОК: launchd intake job loaded: $OBSIDIAN_INTAKE_LABEL"
        else
            WARNINGS+=("🟡 launchd intake job not loaded: $OBSIDIAN_INTAKE_LABEL")
            log "ВНИМАНИЕ: launchd intake job not loaded: $OBSIDIAN_INTAKE_LABEL"
        fi
    fi

    if [ -f "$OBSIDIAN_INTAKE_LOG_FILE" ]; then
        log_epoch=$(file_mtime_epoch "$OBSIDIAN_INTAKE_LOG_FILE")
        if [ "$log_epoch" -gt 0 ]; then
            age=$((NOW_EPOCH - log_epoch))
            if [ "$age" -le "$stale_sec" ]; then
                log "ОК: Obsidian intake log свежий ($(format_epoch "$log_epoch"))"
            else
                WARNINGS+=("🟡 Obsidian intake log stale: $OBSIDIAN_INTAKE_LOG_FILE")
                log "ВНИМАНИЕ: Obsidian intake log stale: $OBSIDIAN_INTAKE_LOG_FILE (last $(format_epoch "$log_epoch"))"
            fi
        fi

        imported_line=$(tail -n 20 "$OBSIDIAN_INTAKE_LOG_FILE" 2>/dev/null | grep -E 'imported=' | tail -n1 || true)
        if [ -n "$imported_line" ]; then
            log "ОК: intake activity marker: $imported_line"
        else
            WARNINGS+=("🟡 Obsidian intake log has no recent imported marker")
            log "ВНИМАНИЕ: Obsidian intake log has no recent imported marker"
        fi
    else
        WARNINGS+=("🟡 Obsidian intake log missing: $OBSIDIAN_INTAKE_LOG_FILE")
        log "ВНИМАНИЕ: Obsidian intake log missing: $OBSIDIAN_INTAKE_LOG_FILE"
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
    LOG_PATH=""

    if [ -f "$file" ]; then
        . "$file"
    elif [ -f "$STATE_DIR/${task}-$DATE" ]; then
        STATUS="success"
        UPDATED_AT="$DATE $(cat "$STATE_DIR/${task}-$DATE")"
        SUMMARY="derived from legacy daily marker"
    elif [ "$task" = "extractor-inbox-check" ] && [ -f "$STATE_DIR/${task}-last" ]; then
        STATUS="success"
        UPDATED_AT="$(format_epoch "$(cat "$STATE_DIR/${task}-last")")"
        SUMMARY="derived from legacy interval marker"
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

    if task_should_be_marked_missed_window "$task"; then
        STATUS="missed_window"
        EXIT_CODE=""
        SUMMARY="today execution window missed; next recovery is next scheduled run"
    fi
}

ERRORS=()
WARNINGS=()
STALE=()

# Человекочитаемые имена агентов
agent_display_name() {
    case "$1" in
        strategist-morning)       echo "Утренний брифинг" ;;
        strategist-note-review)   echo "Ревью заметок" ;;
        strategist-week-review)   echo "Недельное ревью" ;;
        synchronizer-code-scan)   echo "Сканер кода" ;;
        synchronizer-daily-report) echo "Дневной отчёт" ;;
        extractor-inbox-check)    echo "Проверка inbox" ;;
        *)                        echo "$1" ;;
    esac
}

log "=== Проверка здоровья запущена ==="

if command -v launchctl >/dev/null 2>&1; then
    if launchctl list | grep -q 'com.exocortex.scheduler'; then
        log "ОК: планировщик загружен (launchd)"
    else
        ERRORS+=("🔴 Планировщик экзокортекса не загружен")
        log "ОШИБКА: планировщик экзокортекса не загружен (launchd)"
    fi

    if launchctl list | grep -q 'com.exocortex.health-check'; then
        log "ОК: проверка среды загружена (launchd)"
    else
        WARNINGS+=("🟡 Проверка среды не загружена")
        log "ВНИМАНИЕ: проверка среды не загружена (launchd)"
    fi
elif command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet com.exocortex.scheduler.timer; then
        log "ОК: планировщик загружен (systemd)"
    else
        ERRORS+=("🔴 Планировщик экзокортекса не загружен")
        log "ОШИБКА: планировщик экзокортекса не загружен (systemd)"
    fi

    if systemctl is-active --quiet com.exocortex.health-check.timer; then
        log "ОК: проверка среды загружена (systemd)"
    else
        WARNINGS+=("🟡 Проверка среды не загружена")
        log "ВНИМАНИЕ: проверка среды не загружена (systemd)"
    fi
else
    WARNINGS+=("🟡 Не удалось определить планировщик среды: launchctl/systemctl недоступны")
    log "ВНИМАНИЕ: neither launchctl nor systemctl detected; scheduler bootstrap check skipped"
fi

check_protocol_contract
check_opening_contract
check_runtime_contract
check_legacy_launchd_conflicts
check_strategist_notify_contract
check_obsidian_contour
check_human_layer_contract

for task in strategist-morning strategist-note-review strategist-week-review synchronizer-code-scan synchronizer-daily-report extractor-inbox-check; do
    load_status "$task"

    if [ "$STATUS" = "missing" ] && task_missing_is_expected "$task"; then
        log "НЕТ СТАТУСА: $task ещё не должен был запускаться в текущем окне"
        continue
    fi

    case "$STATUS" in
        success|skipped|running)
            log "ОК: $task status=$STATUS"
            ;;
        stale)
            STALE+=("$(agent_display_name "$task")")
            log "УСТАРЕЛ: $task (норма после перезагрузки)"
            ;;
        missed_window)
            STALE+=("$(agent_display_name "$task") — окно на сегодня уже закрыто")
            log "ПРОПУЩЕНО ОКНО: $task (сегодняшнее окно уже закрыто, восстановление при следующем плановом запуске)"
            ;;
        *)
            human_status=$(printf '%s' "$STATUS" | sed \
                -e 's/auth_failed/ошибка авторизации/' \
                -e 's/billing_failed/ошибка баланса или квоты/' \
                -e 's/model_unavailable/недоступна запрошенная модель/' \
                -e 's/network_failed/сетевая ошибка API/' \
                -e 's/timed_out/превышен лимит времени/' \
                -e 's/preflight_failed/ошибка предварительной проверки/' \
                -e 's/failed/ошибка запуска/' \
                -e 's/missing/нет статуса/' \
                -e 's/stale_lock/зависшая блокировка/')
            WARNINGS+=("$(agent_display_name "$task") — ${human_status}")
            log "ВНИМАНИЕ: $task status=$STATUS summary=${SUMMARY:-no summary}"
            ;;
    esac
done

log "=== Проверка здоровья завершена ==="

if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ] && [ ${#STALE[@]} -eq 0 ]; then
    log "✅ Среда исправна"
    exit 0
fi

if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ] && [ ${#STALE[@]} -gt 0 ]; then
    stale_list=$(printf '%s, ' "${STALE[@]}")
    stale_list="${stale_list%, }"
    log "ℹ️ Только stale-статусы: $stale_list"
    log "Telegram-уведомление suppressed: stale-only health-check не должен перекрывать дневной отчёт"
    exit 0
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    log "❌ Найдено ${#ERRORS[@]} критических проблем и ${#WARNINGS[@]} предупреждений"
else
    log "⚠️ Найдено ${#WARNINGS[@]} предупреждений, ${#STALE[@]} устаревших"
fi

MESSAGE="⚠️ Экзокортекс — $(date '+%H:%M')\n\n"

if [ ${#ERRORS[@]} -gt 0 ]; then
    MESSAGE+="🔴 Критично (${#ERRORS[@]}):\n"
    for error in "${ERRORS[@]}"; do
        MESSAGE+="• ${error}\n"
    done
    MESSAGE+="\n"
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    MESSAGE+="🟡 Требует внимания (${#WARNINGS[@]}):\n"
    for warning in "${WARNINGS[@]}"; do
        MESSAGE+="• ${warning}\n"
    done
    MESSAGE+="\n"
fi

if [ ${#STALE[@]} -gt 0 ]; then
    stale_list=$(printf '%s, ' "${STALE[@]}")
    stale_list="${stale_list%, }"
    MESSAGE+="💤 Норма после перезагрузки (${#STALE[@]}):\n"
    MESSAGE+="${stale_list}\n"
    MESSAGE+="→ Обновятся при следующем запуске\n"
fi

notify_macos "Экзокортекс: проверка среды" "Проверь AGENTS-STATUS.md и экран открытия сессии"
notify_telegram "$MESSAGE"
log "Уведомления отправлены"

if [ ${#ERRORS[@]} -gt 0 ]; then
    exit 1
fi

exit 0
