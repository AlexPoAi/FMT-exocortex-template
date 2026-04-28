#!/bin/bash
# Session Watcher — следит за pending-sessions/, запускает session-import + session-tasks
# Запускается launchd каждые 5 минут из чистой среды (без CLAUDECODE)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE_WORKSPACE_SH="$HOME/Github/FMT-exocortex-template/roles/synchronizer/scripts/resolve-workspace.sh"
if [ ! -x "$RESOLVE_WORKSPACE_SH" ]; then
    RESOLVE_WORKSPACE_SH="$(cd "$SCRIPT_DIR/../../synchronizer/scripts" && pwd)/resolve-workspace.sh"
fi
eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"

PENDING_DIR="$WORKSPACE_DIR/DS-strategy/inbox/pending-sessions"
PROCESSED_DIR="$WORKSPACE_DIR/DS-strategy/inbox/processed-sessions"
EXTRACTOR="$WORKSPACE_DIR/FMT-exocortex-template/roles/extractor/scripts/extractor.sh"
LOG_DIR="$HOME/logs/extractor"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR" "$PROCESSED_DIR"

# Снимаем блокировку вложенных сессий Claude Code
unset CLAUDECODE

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [session-watcher] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [session-watcher] $1"
}

# Проверяем есть ли файлы в очереди. `find` не роняет watcher при пустой очереди.
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
    log "✅ Готово: $fname → processed-sessions/ (knowledge + tasks)"
    bash "$(dirname "$0")/chain-report.sh" "$PROCESSED_DIR/$fname" | tee -a "$LOG_FILE"
done
