#!/bin/bash
# WP Gate reminder hook
# Event: UserPromptSubmit
# Read-only: returns additionalContext and does not modify files.

cat <<'EOF'
{"additionalContext": "⛔ WP GATE: Перед обработкой этого сообщения — проверь: (1) Если это новая задача — пройди WP Gate: Read memory/protocol-open.md. (2) Если продолжение работы над тем же РП — продолжай. (3) Если вопрос перерастает в работу — эскалируй."}
EOF
exit 0
