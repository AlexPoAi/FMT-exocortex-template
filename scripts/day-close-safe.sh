#!/bin/bash
# day-close-safe.sh — auth-independent entrypoint для Day Close
# Запускает механические шаги Day Close без slash-route и без cloud auth зависимости.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FMT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVE_WORKSPACE_SH="$FMT_ROOT/roles/synchronizer/scripts/resolve-workspace.sh"

if [ ! -f "$RESOLVE_WORKSPACE_SH" ]; then
  echo "[day-close-safe] ERROR: resolve-workspace.sh not found: $RESOLVE_WORKSPACE_SH" >&2
  exit 1
fi

eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"

WORKSPACE="${WORKSPACE_DIR:-$HOME/Github}"
DAY_CLOSE_SCRIPT="$WORKSPACE/FMT-exocortex-template/scripts/day-close.sh"

if [ ! -x "$DAY_CLOSE_SCRIPT" ]; then
  echo "[day-close-safe] ERROR: day-close.sh not executable: $DAY_CLOSE_SCRIPT" >&2
  exit 1
fi

echo "[day-close-safe] Starting auth-independent Day Close mechanical steps"
bash "$DAY_CLOSE_SCRIPT"
echo "[day-close-safe] Done"
echo "[day-close-safe] Next: complete remaining protocol-close checklist items manually in current agent context"
