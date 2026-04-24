#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
STRATEGIST_SH=""

for candidate in \
    "$SCRIPT_DIR/FMT-exocortex-template/roles/strategist/scripts/strategist.sh" \
    "$(cd "$SCRIPT_DIR/.." && pwd)/roles/strategist/scripts/strategist.sh" \
    "$HOME/Github/FMT-exocortex-template/roles/strategist/scripts/strategist.sh"
do
    if [ -x "$candidate" ]; then
        STRATEGIST_SH="$candidate"
        break
    fi
done

if [ -z "$STRATEGIST_SH" ]; then
    echo "Unable to resolve strategist.sh" >&2
    exit 1
fi

exec "$STRATEGIST_SH" "$@"
