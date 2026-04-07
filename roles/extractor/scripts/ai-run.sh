#!/bin/bash
# ai-run.sh — запуск extractor из текущей AI CLI сессии
# Снимает блокировку вложенных сессий через unset CLAUDECODE
#
# Использование:
#   bash ai-run.sh inbox-check
#   bash ai-run.sh session-import
#   bash ai-run.sh session-watcher

EXTRACTOR="$HOME/Github/FMT-exocortex-template/roles/extractor/scripts/extractor.sh"
LOG_DIR="$HOME/logs/extractor"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ai-run] $1" | tee -a "$LOG_FILE"
}

unset CLAUDECODE

if [ -z "${1:-}" ]; then
    echo "Использование:"
    echo "  bash ai-run.sh inbox-check       — проверить inbox и распределить по PACK"
    echo "  bash ai-run.sh session-import    — обработать очередь сессий"
    echo "  bash ai-run.sh session-watcher   — запустить session-watcher вручную"
    exit 0
fi

case "$1" in
    "inbox-check"|"session-import"|"on-demand"|"session-close"|"archive-review")
        log "Запуск: $1"
        bash "$EXTRACTOR" "$1"
        status=$?
        if [ $status -eq 0 ]; then
            log "✅ $1 завершён успешно"
        else
            log "❌ $1 завершился с ошибкой (код $status)"
        fi
        ;;
    "session-watcher")
        log "Запуск session-watcher"
        bash "$HOME/Github/FMT-exocortex-template/roles/extractor/scripts/session-watcher.sh"
        ;;
    *)
        log "Неизвестная команда: $1"
        echo "Неизвестная команда: $1"
        exit 1
        ;;
esac
