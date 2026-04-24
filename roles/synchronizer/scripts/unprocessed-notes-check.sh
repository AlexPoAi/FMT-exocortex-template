#!/bin/bash
# unprocessed-notes-check.sh — проверка необработанных заметок
#
# Сканирует творческий конвейер и выявляет:
# - Заметки, не поставленные в очередь (🔴)
# - Заметки, уже поставленные в очередь backlog (🟡)
# - Обработанные заметки (🟢)
#
# Обновляет: DS-strategy/current/UNPROCESSED-NOTES-REPORT.md
# Отправляет алерт в Telegram если есть красные флаги

set -euo pipefail

CONVECTOR_DIR="${OBSIDIAN_VAULT_DIR:-$HOME/Documents/Творческий конвеер}"
REPORT_FILE="$HOME/Github/DS-strategy/current/UNPROCESSED-NOTES-REPORT.md"
INBOX_TASKS_FILE="$HOME/Github/DS-strategy/inbox/INBOX-TASKS.md"
STATE_DIR="$HOME/.local/state/exocortex"
ENV_FILE="$HOME/.config/aist/env"
LEGACY_TOKEN_FILE="$HOME/.config/exocortex/telegram-token"
LEGACY_CHAT_ID_FILE="$HOME/.config/exocortex/telegram-chat-id"
NOTIFY_SCRIPT="$HOME/Github/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh"

mkdir -p "$STATE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [unprocessed-check] $1"
}

# Проверить существование Obsidian vault
if [ ! -d "$CONVECTOR_DIR" ]; then
    log "ERROR: Obsidian vault не найден в $CONVECTOR_DIR"
    exit 1
fi

# Сканировать заметки
unprocessed_count=0
red_count=0
yellow_count=0
green_count=0

report="---
type: unprocessed-notes-report
created: $(date +%Y-%m-%d)
updated: $(date +%Y-%m-%d)
---

# Отчёт по очереди заметок

> Система защиты: ни одна мысль не теряется; каждая заметка должна быть либо в очереди backlog, либо в обработке.

---

## Статус-флаги

| Флаг | Значение | Действие |
|------|----------|----------|
| 🟢 | Обработана | Уже разобрана и зафиксирована |
| 🟡 | В очереди | Поставлена в backlog/приоритеты, ждёт своей очереди |
| 🔴 | Требует маршрутизации | Ещё не поставлена в очередь, нужен backlog-route |

---

## Заметки в очереди и на маршрутизации

"

slugify() {
    local value="$1"
    # shellcheck disable=SC2001
    value=$(printf '%s' "$value" | sed 's/\.md$//' | tr '[:upper:]' '[:lower:]')
    # shellcheck disable=SC2001
    value=$(printf '%s' "$value" | sed 's/[^a-zа-я0-9]/ /g' | tr -s ' ')
    printf '%s' "$value"
}

note_is_queued_in_backlog() {
    local filename="$1"
    local stem slug token

    [ -f "$INBOX_TASKS_FILE" ] || return 1
    stem=$(printf '%s' "$filename" | sed 's/\.md$//')
    slug=$(slugify "$stem")

    # 1) точное вхождение названия заметки
    if rg -qi --fixed-strings "$stem" "$INBOX_TASKS_FILE"; then
        return 0
    fi

    # 2) fallback: первое осмысленное слово из slug
    token=$(printf '%s' "$slug" | awk '{for(i=1;i<=NF;i++) if(length($i)>=5){print $i; exit}}')
    if [ -n "$token" ] && rg -qi --fixed-strings "$token" "$INBOX_TASKS_FILE"; then
        return 0
    fi

    return 1
}

# Сканировать папку "1. Исчезающие заметки"
inbox_dir="$CONVECTOR_DIR/1. Исчезающие заметки"
if [ -d "$inbox_dir" ]; then
    while IFS= read -r -d '' file; do
        filename=$(basename "$file")
        mtime=$(stat -f %m "$file" 2>/dev/null || echo 0)
        now=$(date +%s)
        days_old=$(( (now - mtime) / 86400 ))

        if note_is_queued_in_backlog "$filename"; then
            report+="
### $((yellow_count + 1)). 🟡 $filename
- **Источник:** Obsidian ($days_old дней назад)
- **Статус:** Поставлена в очередь backlog
- **Дней в очереди:** $days_old
- **Действие:** Ждёт приоритизированного исполнения
"
            ((yellow_count++))
        else
            if (( days_old > 3 )); then
                report+="
### $((red_count + 1)). 🔴 $filename
- **Источник:** Obsidian ($days_old дней назад)
- **Статус:** Не поставлена в очередь
- **Дней в очереди:** $days_old
- **Действие:** ⚠️ ТРЕБУЕТ МАРШРУТИЗАЦИИ — добавить в backlog/приоритеты
"
                ((red_count++))
            else
                report+="
### $((yellow_count + 1)). 🟡 $filename
- **Источник:** Obsidian ($(date -r "$mtime" +%d.%m))
- **Статус:** Новая, ожидает маршрутизации
- **Дней в очереди:** $days_old
- **Действие:** Ближайший inbox-check поставит в backlog
"
                ((yellow_count++))
            fi
        fi
        ((unprocessed_count++))
    done < <(find "$inbox_dir" -type f -name "*.md" -print0 2>/dev/null)
fi

# Сканировать папку "2. Черновики" для зелёных флагов
drafts_dir="$CONVECTOR_DIR/2. Черновики"
if [ -d "$drafts_dir" ]; then
    while IFS= read -r -d '' file; do
        ((green_count++))
    done < <(find "$drafts_dir" -type f -name "*.md" -print0 2>/dev/null)
fi

report+="

---

## Статистика

| Статус | Количество |
|--------|-----------|
| 🟢 Обработано | $green_count |
| 🟡 В работе | $yellow_count |
| 🔴 Требует внимания | $red_count |
| **Всего** | $((unprocessed_count + green_count)) |

---

## Покрытие очередью (контракт «каждая мысль сохранена»)

| Метрика | Значение |
|--------|----------|
| Всего мыслей | $((unprocessed_count + green_count)) |
| В очереди или обработано (🟢+🟡) | $((green_count + yellow_count)) |
| Без маршрутизации (🔴) | $red_count |

Правило: **каждая мысль должна быть либо в очереди, либо в выполненном контуре**.

---

## Алгоритм защиты

1. **Ежедневно:** Extractor сканирует входящие заметки
2. **Если заметка найдена в INBOX-TASKS:** статус 🟡 (в очереди backlog)
3. **Если заметка не найдена в backlog:** статус 🔴 (нужна маршрутизация)
4. **Красный флаг:** это не потеря, а сигнал, что мысль ещё не поставлена в очередь

---

**Обновлено:** $(date '+%Y-%m-%d %H:%M')
"

# Сохранить отчёт
echo "$report" > "$REPORT_FILE"
log "Отчёт сохранён: $REPORT_FILE"

# Отправить алерт в Telegram если есть красные флаги
if (( red_count > 0 )); then
    log "ALERT: Найдено $red_count заметок без backlog-маршрутизации"

    # Отправить в Telegram:
    # основной источник — ~/.config/aist/env
    # fallback на legacy ~/.config/exocortex/* оставляем на переходный период
    if [ -f "$ENV_FILE" ]; then
        set -a
        source "$ENV_FILE"
        set +a
    fi

    token="${TELEGRAM_BOT_TOKEN:-}"
    chat_id="${TELEGRAM_CHAT_ID:-}"

    if [ -z "$token" ] && [ -f "$LEGACY_TOKEN_FILE" ]; then
        token=$(cat "$LEGACY_TOKEN_FILE")
    fi

    if [ -z "$chat_id" ] && [ -f "$LEGACY_CHAT_ID_FILE" ]; then
        chat_id=$(cat "$LEGACY_CHAT_ID_FILE" 2>/dev/null || echo "")
    fi

    if [ -n "$token" ] && [ -n "$chat_id" ]; then
        if [ -x "$NOTIFY_SCRIPT" ]; then
            "$NOTIFY_SCRIPT" synchronizer unprocessed-notes-check >/dev/null 2>&1 || true
        else
            log "WARN: notify.sh not found or not executable: $NOTIFY_SCRIPT"
        fi
    else
        log "WARN: Telegram alert skipped — token/chat_id не найдены ни в ~/.config/aist/env, ни в legacy ~/.config/exocortex/"
    fi
fi

log "Проверка завершена: 🟢 $green_count, 🟡 $yellow_count, 🔴 $red_count"
exit 0
