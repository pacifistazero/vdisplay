#!/usr/bin/env bash
# Build the tools, install them to ~/.local/bin, and register the menu-bar
# app as a LaunchAgent so it starts at login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.vdisplay.bar"
BIN_DIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "▸ Building release…"
( cd "$ROOT" && swift build -c release >/dev/null )
BUILD="$(cd "$ROOT" && swift build -c release --show-bin-path)"

echo "▸ Installing binaries to $BIN_DIR"
mkdir -p "$BIN_DIR"
cp "$BUILD/vdisplay" "$BIN_DIR/vdisplay"
cp "$BUILD/vdisplaybar" "$BIN_DIR/vdisplaybar"

echo "▸ Writing LaunchAgent $PLIST"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/vdisplaybar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>/tmp/vdisplaybar.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/vdisplaybar.log</string>
</dict>
</plist>
EOF

echo "▸ (Re)loading the LaunchAgent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "✅ Installed. The menu-bar app is running now and will start at every login."
echo "   Look for the display icon in your menu bar."
echo "   Uninstall with: scripts/uninstall-launchagent.sh"
