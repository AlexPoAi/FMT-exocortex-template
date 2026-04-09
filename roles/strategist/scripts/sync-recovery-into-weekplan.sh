#!/bin/bash
# Sync recovery brief into the current WeekPlan as a deterministic triage section.

set -euo pipefail

WORKSPACE_ROOT="${1:-$HOME/Github}"
STRATEGY_DIR="$WORKSPACE_ROOT/DS-strategy"
CURRENT_DIR="$STRATEGY_DIR/current"
WEEKPLAN_FILE="$(ls -1 "$CURRENT_DIR"/WeekPlan\ W*.md 2>/dev/null | head -n 1 || true)"
RECOVERY_BRIEF="$CURRENT_DIR/RECOVERY-BRIEF.md"

if [ -z "$WEEKPLAN_FILE" ] || [ ! -f "$WEEKPLAN_FILE" ]; then
    echo "WeekPlan not found in $CURRENT_DIR" >&2
    exit 1
fi

if [ ! -f "$RECOVERY_BRIEF" ]; then
    echo "Recovery brief not found: $RECOVERY_BRIEF" >&2
    exit 1
fi

python3 - "$WEEKPLAN_FILE" "$RECOVERY_BRIEF" <<'PY'
from pathlib import Path
import re
import sys

weekplan_path = Path(sys.argv[1])
brief_path = Path(sys.argv[2])

weekplan = weekplan_path.read_text()
brief = brief_path.read_text()

items = []
current = None
for line in brief.splitlines():
    if line.startswith("## Инструкция для Strategist"):
        break
    if line.startswith("- "):
        if current:
            items.append(current)
        current = {"title": line[2:].strip()}
    elif current and line.strip().startswith("- Источник:"):
        current["source"] = line.split(":", 1)[1].strip()
    elif current and line.strip().startswith("- Статус recovery:"):
        current["status"] = line.split(":", 1)[1].strip()
    elif current and line.strip().startswith("- Что уже сделано:"):
        current["done"] = line.split(":", 1)[1].strip()
if current:
    items.append(current)

def verdict_for(item):
    title = item.get("title", "").lower()
    status = item.get("status", "").lower()
    if "переезд" in title:
        return "→ INBOX backlog", "стратегический owner-backlog, нужен отдельный strategic WP, но не обязателен в текущем WeekPlan W15"
    if "сайт по продаже кофе" in title or "канал продаж" in title:
        return "→ INBOX backlog", "growth backlog уже возвращён в INBOX; нужен discovery и отдельный growth WP, а не тихая потеря"
    if "ии ассистенты" in title or "needs source recovery" in status:
        return "→ keep in recovery", "контекст источника пока не восстановлен, в WeekPlan рано поднимать как полноценный РП"
    return "→ keep in recovery", "недостаточно контекста для прямого weekly lift"

lines = [
    "### ♻️ Recovery return loop",
    "| Элемент | Verdict | Обоснование |",
    "|--------|---------|-------------|",
]

if items:
    for item in items:
        verdict, rationale = verdict_for(item)
        title = item.get("title", "")
        lines.append(f"| {title} | {verdict} | {rationale} |")
else:
    lines.append("| — | → keep in recovery | Активных recovery-элементов не найдено |")

section = "\n".join(lines)

pattern = re.compile(
    r"(### ⏸️ Отложить \(Low / блокеры\)\n.*?(?:\n\|.*?)*\n(?:\|.*\n)*)(\n---\n)",
    re.S
)

replacement = r"\1\n" + section + r"\2"

if "### ♻️ Recovery return loop" in weekplan:
    weekplan = re.sub(
        r"\n### ♻️ Recovery return loop\n.*?(?=\n---\n)",
        "\n" + section,
        weekplan,
        flags=re.S,
    )
else:
    weekplan, count = pattern.subn(replacement, weekplan, count=1)
    if count == 0:
        strategic_match = re.search(r"\n## Стратегическая сверка W[0-9]+\n", weekplan)
        if strategic_match:
            weekplan = (
                weekplan[:strategic_match.start()]
                + "\n" + section + "\n\n---\n"
                + weekplan[strategic_match.start():]
            )
        else:
            weekplan += "\n\n" + section + "\n"

weekplan_path.write_text(weekplan)
PY

echo "$WEEKPLAN_FILE"
