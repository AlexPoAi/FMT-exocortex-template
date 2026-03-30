#!/bin/bash
# unprocessed-notes-check.sh — проверка необработанных заметок
#
# Сканирует творческий конвейер и выявляет:
# - Заметки >3 дней без обработки (🔴)
# - Заметки в очереди (🟡)
# - Обработанные заметки (🟢)
#
# Обновляет: DS-strategy/current/UNPROCESSED-NOTES-REPORT.md
# Отправляет алерт в Telegram если есть красные флаги

set -euo pipefail

CONVECTOR_DIR="$HOME/Github/creativ-convector"
REPORT_FILE="$HOME/Github/DS-strategy/current/UNPROCESSED-NOTES-REPORT.md"
STATE_DIR="$HOME/.local/state/exocortex"

mkdir -p "$STATE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [unprocessed-check] $1"
}

# Проверить существование творческого конвейера
if [ ! -d "$CONVECTOR_DIR" ]; then
    log "ERROR: creativ-convector не найден в $CONVECTOR_DIR"
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

# Отчёт о необработанных заметках

> Система защиты: отслеживание заметок, которые не распределены по Pack

---

## Статус-флаги

| Флаг | Значение | Действие |
|------|----------|----------|
| 🟢 | Обработана | Распределена в Pack, создана карточка |
| 🟡 | В работе | Extractor обрабатывает, ждёт распределения |
| 🔴 | Требует внимания | >3 дней не обработана, нужна ручная проверка |

---

## Необработанные заметки

"

# Сканировать папку "1. Исчезающие заметки"
inbox_dir="$CONVECTOR_DIR/1. Исчезающие заметки"
if [ -d "$inbox_dir" ]; then
    while IFS= read -r -d '' file; do
        filename=$(basename "$file")
        mtime=$(stat -f %m "$file" 2>/dev/null || echo 0)
        now=$(date +%s)
        days_old=$(( (now - mtime) / 86400 ))

        if (( days_old > 3 )); then
            report+="
### $((red_count + 1)). 🔴 $filename
- **Источник:** Obsidian ($days_old дней назад)
- **Статус:** Не распределена
- **Дней в очереди:** $days_old
- **Действие:** ⚠️ ТРЕБУЕТ ВНИМАНИЯ — ручная проверка и распределение
"
            ((red_count++))
        else
            report+="
### $((yellow_count + 1)). 🟡 $filename
- **Источник:** Obsidian ($(date -r "$mtime" +%d.%m))
- **Статус:** В очереди Extractor
- **Дней в очереди:** $days_old
- **Действие:** Ждёт обработки
"
            ((yellow_count++))
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

## Алгоритм защиты

1. **Ежедневно (08:00):** Extractor сканирует inbox
2. **Если заметка >3 дней:** Флаг → 🔴 (красный)
3. **Если красный флаг:** Отправить алерт в Telegram
4. **Ручная проверка:** Пользователь подтверждает распределение

---

**Обновлено:** $(date '+%Y-%m-%d %H:%M')
"

# Сохранить отчёт
echo "$report" > "$REPORT_FILE"
log "Отчёт сохранён: $REPORT_FILE"

# Отправить алерт в Telegram если есть красные флаги
if (( red_count > 0 )); then
    log "ALERT: Найдено $red_count необработанных заметок (>3 дней)"

    # Отправить в Telegram (если токен настроен)
    if [ -f "$HOME/.config/exocortex/telegram-token" ]; then
        token=$(cat "$HOME/.config/exocortex/telegram-token")
        chat_id=$(cat "$HOME/.config/exocortex/telegram-chat-id" 2>/dev/null || echo "")

        if [ -n "$chat_id" ]; then
            msg="🔴 *Необработанные заметки*\n\nНайдено $red_count заметок старше 3 дней в Obsidian.\n\nДействие: проверить и распределить вручную."
            curl -s -X POST "https://api.telegram.org/bot$token/sendMessage" \
                -d "chat_id=$chat_id" \
                -d "text=$msg" \
                -d "parse_mode=Markdown" >/dev/null 2>&1 || true
        fi
    fi
fi

log "Проверка завершена: 🟢 $green_count, 🟡 $yellow_count, 🔴 $red_count"
exit 0
