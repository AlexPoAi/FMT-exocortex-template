#!/bin/bash
# Build a compact recovery brief for Strategist weekly/session-prep flows.

set -euo pipefail

WORKSPACE_ROOT="${1:-$HOME/Github}"
STRATEGY_DIR="$WORKSPACE_ROOT/DS-strategy"
CURRENT_DIR="$STRATEGY_DIR/current"
OUTPUT_FILE="$CURRENT_DIR/RECOVERY-BRIEF.md"

mkdir -p "$CURRENT_DIR"

latest_catalog="$(ls -1t "$STRATEGY_DIR"/inbox/RECOVERY-CATALOG-LOST-INPUTS-*.md 2>/dev/null | head -n 1 || true)"

if [ -z "$latest_catalog" ] || [ ! -f "$latest_catalog" ]; then
    cat > "$OUTPUT_FILE" <<EOF
---
type: recovery-brief
date: $(date +%Y-%m-%d)
status: no-catalog
source: none
owner: Strategist
---

# Recovery Brief

Каталог recovery не найден. Отдельных recovery-элементов для weekly/session-prep не обнаружено.
EOF
    echo "$OUTPUT_FILE"
    exit 0
fi

catalog_date="$(basename "$latest_catalog" | sed -E 's/^RECOVERY-CATALOG-LOST-INPUTS-([0-9-]+)\.md$/\1/')"

{
    cat <<EOF
---
type: recovery-brief
date: $(date +%Y-%m-%d)
status: active
source: $(basename "$latest_catalog")
owner: Strategist
---

# Recovery Brief

Источник: \`inbox/$(basename "$latest_catalog")\`
Дата каталога: \`$catalog_date\`

## Элементы, требующие weekly/governance verdict

EOF

    awk -F'|' '
        /^\| [0-9]+ / {
            gsub(/^[ \t`]+|[ \t`]+$/, "", $3);
            gsub(/^[ \t`]+|[ \t`]+$/, "", $4);
            gsub(/^[ \t`]+|[ \t`]+$/, "", $5);
            gsub(/^[ \t`]+|[ \t`]+$/, "", $6);
            if ($5 ~ /new|needs source recovery|active/) {
                printf("- %s\n", $3);
                printf("  - Источник: %s\n", $4);
                printf("  - Статус recovery: %s\n", $5);
                printf("  - Что уже сделано: %s\n", $6);
                printf("  - Требуется verdict: WeekPlan / backlog / keep in recovery\n");
            }
        }
    ' "$latest_catalog"

    cat <<'EOF'

## Инструкция для Strategist

- Не игнорируй элементы выше при weekly/session-prep.
- Для каждого элемента дай явный verdict:
  - `→ WeekPlan`
  - `→ INBOX backlog`
  - `→ keep in recovery`
- Если элемент уже tracked, не дублируй его без новой причины.
EOF
} > "$OUTPUT_FILE"

echo "$OUTPUT_FILE"
