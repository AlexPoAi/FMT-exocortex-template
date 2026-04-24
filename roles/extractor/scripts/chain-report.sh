#!/bin/bash
# chain-report.sh — финальный отчёт по всей цепочке после сессии стратегирования
# Показывает backlog по knowledge/task/manual-review потокам

SESSION_FILE="${1:-}"
DS_STRATEGY="$HOME/Github/DS-strategy"
CREATIV="${OBSIDIAN_VAULT_DIR:-$HOME/Documents/Творческий конвеер}"
CAPTURES="$DS_STRATEGY/inbox/captures.md"
INBOX_TASKS="$DS_STRATEGY/inbox/INBOX-TASKS.md"
PROCESSED="$DS_STRATEGY/inbox/processed-sessions"
PENDING="$DS_STRATEGY/inbox/pending-sessions"
REPORTS="$DS_STRATEGY/inbox/extraction-reports"
MANUAL_REVIEW="$CREATIV/2. Черновики/00-Ручной разбор"
REPORT_FILE="$REPORTS/$(date +%Y-%m-%d)-chain-report.md"

mkdir -p "$REPORTS"
: > "$REPORT_FILE"

out() { echo "$1" | tee -a "$REPORT_FILE"; }
count_md() {
    local dir="$1"
    if [ -d "$dir" ]; then
        find "$dir" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' '
    else
        echo 0
    fi
}

pending_sessions=$(count_md "$PENDING")
processed_sessions=$(count_md "$PROCESSED")
manual_review_count=$(find "$MANUAL_REVIEW" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
pending_reports=$(grep -l '^status: pending-review' "$REPORTS"/*.md 2>/dev/null | wc -l | tr -d ' ')
pending_captures=0
processed_captures=0
analyzed_captures=0
all_captures=0
if [ -f "$CAPTURES" ]; then
    all_captures=$(grep '^### ' "$CAPTURES" 2>/dev/null | wc -l | tr -d ' ')
    processed_captures=$(grep '\[processed' "$CAPTURES" 2>/dev/null | wc -l | tr -d ' ')
    analyzed_captures=$(grep '\[analyzed' "$CAPTURES" 2>/dev/null | wc -l | tr -d ' ')
    pending_captures=$((all_captures - processed_captures - analyzed_captures))
    if [ "$pending_captures" -lt 0 ]; then
        pending_captures=0
    fi
fi

today=$(date +%Y-%m-%d)
tasks_today=$(grep '^## \[Задачи из сессии ' "$INBOX_TASKS" 2>/dev/null | grep "$today" | wc -l | tr -d ' ')

out ""
out "════════════════════════════════════════════════════════════"
out "📋 ОТЧЁТ ЦЕПОЧКИ СТРАТЕГИРОВАНИЯ $(date '+%d.%m.%Y %H:%M')"
out "════════════════════════════════════════════════════════════"
out ""
out "① ТВОРЧЕСКИЙ КОНВЕЙЕР"
if [ -n "$SESSION_FILE" ] && [ -f "$SESSION_FILE" ]; then
    fname=$(basename "$SESSION_FILE")
    fsize=$(wc -c < "$SESSION_FILE")
    out "   ✅ Файл сессии создан: $fname"
    out "   📄 Размер: $fsize байт"
else
    last=$(ls -t "$PROCESSED"/*.md 2>/dev/null | head -1)
    if [ -n "$last" ]; then
        out "   ✅ Последняя сессия: $(basename "$last")"
    else
        out "   ⚠️  Файл сессии не найден"
    fi
fi
out ""
out "② ОЧЕРЕДЬ СЕССИЙ (knowledge + tasks)"
out "   • Pending sessions: $pending_sessions"
out "   • Processed sessions: $processed_sessions"
if [ "$pending_sessions" -gt 0 ]; then
    find "$PENDING" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | head -5 | while read -r file; do
        out "   → waiting: $(basename "$file")"
    done
fi
out ""
out "③ KNOWLEDGE STREAM (captures → extraction reports)"
out "   • Всего captures: $all_captures"
out "   • Pending captures: $pending_captures"
out "   • Pending extraction reports: $pending_reports"
if [ -f "$CAPTURES" ]; then
    grep '^### ' "$CAPTURES" 2>/dev/null | head -10 | sed 's/^### /   → /' | while read -r line; do
        out "$line"
    done
fi
out ""
out "④ TASK STREAM (session-tasks → INBOX-TASKS.md)"
out "   • Секций задач за сегодня: $tasks_today"
if [ -f "$INBOX_TASKS" ]; then
    grep -n "\[source: сессия" "$INBOX_TASKS" 2>/dev/null | tail -5 | while read -r line; do
        out "   → $line"
    done
fi
out ""
out "⑤ MANUAL-REVIEW / НЕРАЗОБРАННОЕ"
out "   • Ручной разбор в Obsidian vault: $manual_review_count"
if [ "$manual_review_count" -gt 0 ]; then
    find "$MANUAL_REVIEW" -type f -name '*.md' 2>/dev/null | sort | head -10 | while read -r file; do
        rel_path=${file#"$CREATIV/"}
        out "   → $rel_path"
    done
fi
out ""
out "════════════════════════════════════════════════════════════"
out "✅ ЦЕПОЧКА СТРАТЕГИРОВАНИЯ ЗАВЕРШЕНА"
out ""
out "Инварианты проверки:"
out "  1. каждая заметка либо в проекте, либо в manual-review, либо в error"
out "  2. каждая сессия даёт knowledge stream и task stream"
out "  3. backlog виден по counts, без silent skip"
out ""
out "Ручные команды:"
out "  Обработать очередь:  bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/session-watcher.sh"
out "  Проверить inbox:     bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/extractor.sh inbox-check"
out "  Посмотреть captures: cat ~/Github/DS-strategy/inbox/captures.md"
out "  Посмотреть задачи:   cat ~/Github/DS-strategy/inbox/INBOX-TASKS.md"
out "  Посмотреть лог:      cat ~/logs/extractor/$(date +%Y-%m-%d).log"
out "════════════════════════════════════════════════════════════"
out ""
out "📁 Отчёт сохранён: $REPORT_FILE"
