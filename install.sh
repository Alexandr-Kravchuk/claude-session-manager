#!/bin/bash
# Install ClaudeBar to ~/.local/bin and set up Login Item (LaunchAgent)
set -e
cd "$(dirname "$0")"

BINARY_DIR="$HOME/.local/bin"
BINARY_PATH="$BINARY_DIR/ClaudeBar"
PLIST_PATH="$HOME/Library/LaunchAgents/com.claudebar.app.plist"

# Pre-flight: require Xcode >= $MIN_XCODE. Command Line Tools alone can ship a
# broken SwiftPM manifest library, which makes `swift build` fail at link time.
# 15.0 is the minimum that provides Swift 5.9 (this package's swift-tools-version).
MIN_XCODE="15.0"
DEVDIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEVDIR" != *"/Xcode"*.app/* ]]; then
    echo "✗ Xcode $MIN_XCODE+ required (xcode-select points to: ${DEVDIR:-<none>})"
    echo "  Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi
XCODE_VER="$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')"
if [[ -z "$XCODE_VER" || "$(printf '%s\n%s\n' "$MIN_XCODE" "$XCODE_VER" | sort -V | head -1)" != "$MIN_XCODE" ]]; then
    echo "✗ Xcode $MIN_XCODE+ required (found: ${XCODE_VER:-unknown})"
    exit 1
fi

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
