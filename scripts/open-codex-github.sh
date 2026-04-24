#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="${WORKSPACE_DIR:-}"

if [ -z "$ROOT_DIR" ]; then
    for candidate in \
        "$SCRIPT_DIR" \
        "$(cd "$SCRIPT_DIR/.." && pwd)" \
        "$HOME/Github"
    do
        if [ -d "$candidate/DS-strategy" ] && [ -d "$candidate/FMT-exocortex-template" ]; then
            ROOT_DIR="$candidate"
            break
        fi
    done
fi

if [ -z "$ROOT_DIR" ]; then
    echo "Unable to resolve Github workspace root" >&2
    exit 1
fi

WORKSPACE_FILE="$ROOT_DIR/Codex-Github.code-workspace"

if [ -f "$WORKSPACE_FILE" ]; then
    code -n "$WORKSPACE_FILE"
else
    code -n "$ROOT_DIR"
fi
