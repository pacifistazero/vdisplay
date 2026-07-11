#!/usr/bin/env bash
# Stop and remove the menu-bar LaunchAgent (leaves ~/.local/bin binaries in place).
set -euo pipefail

LABEL="com.vdisplay.bar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "✅ LaunchAgent removed. Binaries remain in ~/.local/bin (delete manually if you like)."
