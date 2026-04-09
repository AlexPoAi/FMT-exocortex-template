#!/bin/bash
# resolve-workspace.sh — canonical workspace/root resolver for local and VPS layouts

set -euo pipefail

if [ "${1:-}" = "--env" ]; then
    if [ -n "${WORKSPACE_DIR:-}" ] && [ -d "${WORKSPACE_DIR}/DS-strategy/.git" ]; then
        workspace_dir="$WORKSPACE_DIR"
    else
        workspace_dir=""
        for candidate in \
            "$HOME/Github" \
            "$HOME/IWE" \
            "$HOME" \
            "/root/Github" \
            "/root"
        do
            if [ -d "$candidate/DS-strategy/.git" ]; then
                workspace_dir="$candidate"
                break
            fi
        done
    fi

    if [ -z "$workspace_dir" ]; then
        echo "Unable to resolve workspace root containing DS-strategy/.git" >&2
        exit 1
    fi

    cat <<EOF
WORKSPACE_DIR="$workspace_dir"
DS_STRATEGY_DIR="$workspace_dir/DS-strategy"
FMT_EXOCORTEX_DIR="$workspace_dir/FMT-exocortex-template"
DS_AGENT_WORKSPACE_DIR="$workspace_dir/DS-agent-workspace"
EOF
    exit 0
fi

echo "Usage: $0 --env" >&2
exit 2
