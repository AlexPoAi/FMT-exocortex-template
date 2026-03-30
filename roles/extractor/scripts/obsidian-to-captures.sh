#!/bin/bash
# obsidian-to-captures.sh — Obsidian «Исчезающие заметки» → captures.md
#
# Запускается автоматически через sync_obsidian.sh (hook) или вручную.
# Берёт .md файлы из Obsidian и добавляет их содержимое в captures.md
# как capture-кандидаты для обработки Knowledge Extractor (R2).
#
# ВАЖНО: Этот скрипт не анализирует и не классифицирует знания.
# Он только переносит сырые заметки в captures.md с минимальной структурой.
# Дальнейший анализ выполняет Claude-агент (Knowledge Extractor).

set -euo pipefail

NOCLOUD_DIR="${HOME}/Documents/creativ-convector.nocloud"
INBOX_DIR="${NOCLOUD_DIR}/1. Исчезающие заметки"
CAPTURES_FILE="${HOME}/Github/DS-strategy/inbox/captures.md"
DS_STRATEGY_DIR="${HOME}/Github/DS-strategy"
LOG_DIR="${HOME}/logs/extractor"
LOG_FILE="${LOG_DIR}/$(date +%Y-%m-%d).log"
MARKER_DIR="${HOME}/.local/state/exocortex/obsidian-imported"
DATE=$(date +%Y-%m-%d)

mkdir -p "$LOG_DIR" "$MARKER_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [obsidian-to-captures] $1" | tee -a "$LOG_FILE"
}

# Проверить что captures.md существует
if [ ! -f "$CAPTURES_FILE" ]; then
    log "ERROR: captures.md не найден: $CAPTURES_FILE"
    exit 1
fi

# Проверить что папка Исчезающих заметок существует
if [ ! -d "$INBOX_DIR" ]; then
    log "Папка 'Исчезающие заметки' не найдена: $INBOX_DIR"
    exit 0
fi

ADDED=0

# Обработать каждый .md файл в Исчезающих заметках
while IFS= read -r -d '' FILE; do
    FILENAME=$(basename "$FILE")
    # Маркер: MD5 от имени файла + даты последнего изменения
    FILE_MTIME=$(stat -f '%m' "$FILE" 2>/dev/null || stat -c '%Y' "$FILE" 2>/dev/null || echo "0")
    MARKER_KEY=$(echo "${FILENAME}_${FILE_MTIME}" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "${FILENAME}_${FILE_MTIME}" | md5 2>/dev/null || echo "${FILENAME}_${FILE_MTIME}")
    MARKER_FILE="$MARKER_DIR/${MARKER_KEY}"

    # Пропустить уже импортированные файлы
    if [ -f "$MARKER_FILE" ]; then
        log "Пропускаем (уже импортирован): $FILENAME"
        continue
    fi

    # Читаем содержимое файла
    CONTENT=$(cat "$FILE" 2>/dev/null || echo "")
    if [ -z "$CONTENT" ]; then
        log "Пропускаем пустой файл: $FILENAME"
        continue
    fi

    # Заголовок — имя файла без расширения
    TITLE="${FILENAME%.md}"

    log "Добавляем в captures: $FILENAME"

    # Добавляем в captures.md после маркера
    # Используем Python для безопасной вставки многострочного текста
    python3 - <<PYEOF
import sys

captures_file = "$CAPTURES_FILE"
marker = "<!-- Captures добавляются ниже этой строки -->"
title = """$TITLE"""
content = open("$FILE").read().strip()
source_date = "$DATE"

# Формируем capture-кандидат
capture = f"""
### {title} [source: Obsidian {source_date}]
**Домен:** _требует классификации_
**Тип:** _требует классификации_
**Контент:**
{content}
"""

# Вставляем в файл
with open(captures_file, 'r', encoding='utf-8') as f:
    text = f.read()

if marker not in text:
    print(f"ERROR: маркер не найден в captures.md")
    sys.exit(1)

new_text = text.replace(marker, marker + capture)

with open(captures_file, 'w', encoding='utf-8') as f:
    f.write(new_text)

print(f"OK: добавлен capture '{title}'")
PYEOF

    # Ставим маркер что файл импортирован
    echo "$DATE" > "$MARKER_FILE"
    ADDED=$((ADDED + 1))

done < <(find "$INBOX_DIR" -name "*.md" -print0)

if [ "$ADDED" -eq 0 ]; then
    log "Новых заметок не найдено"
    exit 0
fi

log "Добавлено $ADDED новых capture-кандидатов в captures.md"

# Коммитим captures.md
cd "$DS_STRATEGY_DIR"
git pull --rebase origin main >> "$LOG_FILE" 2>&1 || true
git add inbox/captures.md
if git diff --cached --quiet; then
    log "Нет изменений для коммита"
else
    git commit -m "obsidian-import: $ADDED заметок из Obsidian [${DATE}]" >> "$LOG_FILE" 2>&1
    git push origin main >> "$LOG_FILE" 2>&1
    log "Запушено в GitHub: $ADDED captures"
fi

exit 0
