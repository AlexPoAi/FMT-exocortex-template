#!/bin/bash
# Session Watcher — следит за pending-sessions/, запускает session-import + session-tasks
# Запускается launchd каждые 5 минут из чистой среды (без CLAUDECODE)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IWE_TEMPLATE_DIR="${IWE_TEMPLATE:-$HOME/Github/FMT-exocortex-template}"
RESOLVE_WORKSPACE_SH="$IWE_TEMPLATE_DIR/roles/synchronizer/scripts/resolve-workspace.sh"
if [ ! -x "$RESOLVE_WORKSPACE_SH" ]; then
    RESOLVE_WORKSPACE_SH="$(cd "$SCRIPT_DIR/../../synchronizer/scripts" && pwd)/resolve-workspace.sh"
fi
eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"

PENDING_DIR="$WORKSPACE_DIR/DS-strategy/inbox/pending-sessions"
PROCESSED_DIR="$WORKSPACE_DIR/DS-strategy/inbox/processed-sessions"
ARCHIVE_PROCESSED_DIR="$WORKSPACE_DIR/DS-strategy/archive/notes/processed-sessions"
OBSIDIAN_VAULT_DIR="${OBSIDIAN_VAULT_DIR:-$HOME/Documents/Творческий конвеер}"
SESSION_DIR="$OBSIDIAN_VAULT_DIR/Сессия стратегирования"
LEGACY_SESSION_DIR="$OBSIDIAN_VAULT_DIR/System/Сессии стратегирования"
if [ -x "${IWE_RUNTIME:-}/roles/extractor/scripts/extractor.sh" ]; then
    EXTRACTOR="${IWE_RUNTIME}/roles/extractor/scripts/extractor.sh"
else
    EXTRACTOR="$WORKSPACE_DIR/FMT-exocortex-template/roles/extractor/scripts/extractor.sh"
fi
CHAIN_REPORT="$IWE_TEMPLATE_DIR/roles/extractor/scripts/chain-report.sh"
LOG_DIR="$HOME/logs/extractor"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR" "$PROCESSED_DIR" "$PENDING_DIR"

unset CLAUDECODE

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [session-watcher] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [session-watcher] $1"
}

is_session_candidate() {
    local fname="$1"

    case "$fname" in
        "Сессия стратегирования "*.md) ;;
        *) return 1 ;;
    esac

    case "$fname" in
        *"raw input"*.md|*"ОТЧЁТ "*".md"|*"АНАЛИЗ "*".md") return 1 ;;
    esac

    return 0
}

queue_obsidian_sessions() {
    local source_dir="$1"
    local queued=0

    [ -d "$source_dir" ] || return 0

    while IFS= read -r session_file; do
        [ -f "$session_file" ] || continue
        local fname
        fname=$(basename "$session_file")

        if ! is_session_candidate "$fname"; then
            continue
        fi

        if [ -f "$PENDING_DIR/$fname" ] || [ -f "$PROCESSED_DIR/$fname" ] || [ -f "$ARCHIVE_PROCESSED_DIR/$fname" ]; then
            continue
        fi

        cp "$session_file" "$PENDING_DIR/$fname"
        queued=$((queued + 1))
        log "queued from Obsidian: $fname"
    done < <(find "$source_dir" -type f -name '*.md' | sort)

    if [ "$queued" -gt 0 ]; then
        log "queued $queued session file(s) from Obsidian into pending-sessions/"
    fi
}

queue_obsidian_sessions "$SESSION_DIR"
queue_obsidian_sessions "$LEGACY_SESSION_DIR"

pending=$(find "$PENDING_DIR" -maxdepth 1 -type f -name "*.md" 2>/dev/null | sort || true)
if [ -z "$pending" ]; then
    exit 0
fi

log "Найдены файлы в очереди: $(echo "$pending" | wc -l | tr -d ' ')"

for session_file in "$PENDING_DIR"/*.md; do
    [ -f "$session_file" ] || continue
    fname=$(basename "$session_file")
    log "Обрабатываю: $fname"

    export SESSION_IMPORT_FILE="$session_file"

    bash "$EXTRACTOR" session-import >> "$LOG_FILE" 2>&1
    import_status=$?

    if [ $import_status -ne 0 ]; then
        log "❌ Ошибка session-import: $fname (код $import_status)"
        continue
    fi

    bash "$EXTRACTOR" session-tasks >> "$LOG_FILE" 2>&1
    tasks_status=$?

    if [ $tasks_status -ne 0 ]; then
        log "❌ Ошибка session-tasks: $fname (код $tasks_status)"
        continue
    fi

    mv "$session_file" "$PROCESSED_DIR/$fname"
    log "✅ Готово: $fname -> processed-sessions/ (knowledge + tasks)"
    bash "$CHAIN_REPORT" "$PROCESSED_DIR/$fname" | tee -a "$LOG_FILE"
done
