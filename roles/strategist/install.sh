#!/bin/bash
# Install Strategist entrypoints without re-enabling legacy launchd jobs
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$HOME/Library/LaunchAgents"
SYNC_INSTALL="$HOME/Github/FMT-exocortex-template/roles/synchronizer/install.sh"

echo "Installing Strategist runtime compatibility layer..."

# Unload legacy strategist jobs if present
launchctl unload "$TARGET_DIR/com.strategist.morning.plist" 2>/dev/null || true
launchctl unload "$TARGET_DIR/com.strategist.weekreview.plist" 2>/dev/null || true

# Remove copied legacy plists if they are still present in LaunchAgents
rm -f "$TARGET_DIR/com.strategist.morning.plist" "$TARGET_DIR/com.strategist.weekreview.plist"

# Keep manual entrypoint executable
chmod +x "$SCRIPT_DIR/scripts/strategist.sh"

echo "Legacy com.strategist.* launchd jobs removed."
echo "Source-of-truth for scheduled Strategist runs is com.exocortex.scheduler."

if [ -x "$SYNC_INSTALL" ]; then
    echo "To (re)install the scheduled runtime, run:"
    echo "  bash $SYNC_INSTALL"
else
    echo "Synchronizer installer not found at: $SYNC_INSTALL"
fi

echo "Current loaded jobs:"
launchctl list | grep -E 'exocortex|strategist' || true
