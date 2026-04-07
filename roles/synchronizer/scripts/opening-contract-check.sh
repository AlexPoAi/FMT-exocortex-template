#!/bin/bash
# opening-contract-check.sh — проверка opening-contract и canonical MEMORY route

set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/Github}"
CANONICAL_MEMORY_FILE="$WORKSPACE_DIR/memory/MEMORY.md"
ROOT_MEMORY_FILE="$WORKSPACE_DIR/MEMORY.md"

legacy_pattern='Прочитать `?MEMORY\.md|Сравнить с `?MEMORY\.md|Вывести таблицу РП из `?MEMORY\.md|Проверить MEMORY\.md'

critical_files=(
    "$WORKSPACE_DIR/CLAUDE.md"
    "$WORKSPACE_DIR/FMT-exocortex-template/memory/protocol-open.md"
    "$WORKSPACE_DIR/FMT-exocortex-template/memory/checklists.md"
    "$WORKSPACE_DIR/DS-strategy/exocortex/protocol-open.md"
    "$WORKSPACE_DIR/DS-strategy/exocortex/memory/protocol-open.md"
    "$WORKSPACE_DIR/DS-strategy/exocortex/checklists.md"
    "$WORKSPACE_DIR/DS-strategy/exocortex/memory/checklists.md"
    "$WORKSPACE_DIR/DS-agent-workspace/agency/agents/strategist.md"
)

errors=()
warnings=()

if [ ! -f "$CANONICAL_MEMORY_FILE" ]; then
    errors+=("canonical_memory_missing:$CANONICAL_MEMORY_FILE")
fi

if [ ! -e "$ROOT_MEMORY_FILE" ]; then
    warnings+=("root_memory_alias_missing:$ROOT_MEMORY_FILE")
elif [ ! -L "$ROOT_MEMORY_FILE" ]; then
    warnings+=("root_memory_alias_not_symlink:$ROOT_MEMORY_FILE")
elif [ "$(cd "$(dirname "$ROOT_MEMORY_FILE")" && pwd -P)/$(basename "$(readlink "$ROOT_MEMORY_FILE")")" = "" ] 2>/dev/null; then
    warnings+=("root_memory_alias_unresolved:$ROOT_MEMORY_FILE")
fi

if [ -e "$ROOT_MEMORY_FILE" ] && [ -f "$CANONICAL_MEMORY_FILE" ]; then
    root_resolved=$(ROOT_MEMORY_FILE="$ROOT_MEMORY_FILE" CANONICAL_MEMORY_FILE="$CANONICAL_MEMORY_FILE" python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["ROOT_MEMORY_FILE"])
canonical = Path(os.environ["CANONICAL_MEMORY_FILE"])
print("same" if root.exists() and root.resolve() == canonical.resolve() else "different")
PY
)
    if [ "$root_resolved" != "same" ]; then
        warnings+=("root_memory_alias_target_mismatch:$ROOT_MEMORY_FILE")
    fi
fi

for file in "${critical_files[@]}"; do
    if [ ! -f "$file" ]; then
        errors+=("opening_contract_file_missing:$file")
        continue
    fi

    if grep -nE "$legacy_pattern" "$file" >/tmp/opening-contract-grep.log 2>/dev/null; then
        match=$(head -1 /tmp/opening-contract-grep.log)
        errors+=("legacy_memory_wording:$file:$match")
    fi
done

rm -f /tmp/opening-contract-grep.log

if [ "${#errors[@]}" -gt 0 ]; then
    printf 'ERROR %s\n' "${errors[@]}"
    exit 2
fi

if [ "${#warnings[@]}" -gt 0 ]; then
    printf 'WARN %s\n' "${warnings[@]}"
    exit 1
fi

printf 'OK canonical_memory_route:%s\n' "$CANONICAL_MEMORY_FILE"
printf 'OK root_memory_alias:%s\n' "$ROOT_MEMORY_FILE"
printf 'OK opening_contract_files:%s\n' "${#critical_files[@]}"
