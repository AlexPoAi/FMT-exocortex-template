#!/bin/bash
# PreCompact checkpoint reminder hook
# Event: PreCompact
# Read-only: reminds the agent to save a checkpoint before context compaction.

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT_DIR="${CWD:-$(pwd)}"
CHECKPOINT_FILE="$PROJECT_DIR/.claude/checkpoint.md"

cat <<'EOF'
{"additionalContext": "⚠️ PRECOMPACT: Контекст будет сжат. Перед продолжением прочитай .claude/checkpoint.md если он есть. Запиши в него: (1) Над каким РП работаешь, (2) Что осталось сделать, (3) Какой протокол выполняешь и на каком шаге, (4) Незавершённые шаги протокола (включая верификацию)."}
EOF
exit 0
