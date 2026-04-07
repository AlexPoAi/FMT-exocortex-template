#!/bin/bash
# claude-run.sh — legacy wrapper, сохраняется для обратной совместимости.
# Канонический entrypoint теперь: ai-run.sh

exec "$HOME/Github/FMT-exocortex-template/roles/extractor/scripts/ai-run.sh" "$@"
