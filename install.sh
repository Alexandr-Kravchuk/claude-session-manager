#!/bin/bash
# Install ClaudeBar to ~/.local/bin and set up Login Item (LaunchAgent)
set -e
cd "$(dirname "$0")"

BINARY_DIR="$HOME/.local/bin"
BINARY_PATH="$BINARY_DIR/ClaudeBar"
PLIST_PATH="$HOME/Library/LaunchAgents/com.claudebar.app.plist"

echo "→ Building release binary..."
swift build -c release

echo "→ Installing to $BINARY_PATH..."
mkdir -p "$BINARY_DIR"
cp .build/release/ClaudeBar "$BINARY_PATH"
chmod +x "$BINARY_PATH"

echo "→ Writing LaunchAgent..."
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudebar.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/claudebar.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claudebar.log</string>
</dict>
</plist>
EOF

echo "→ Activating..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
pkill -x ClaudeBar 2>/dev/null || true
sleep 0.5
launchctl load "$PLIST_PATH"

echo ""
echo "✓ ClaudeBar installed and running"
echo "  Binary:      $BINARY_PATH"
echo "  LaunchAgent: $PLIST_PATH"
echo "  Logs:        /tmp/claudebar.log"
echo ""
echo "  To disable autostart:"
echo "  launchctl unload $PLIST_PATH"
