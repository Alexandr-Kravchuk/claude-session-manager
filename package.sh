#!/bin/bash
# Build ClaudeBar.app and install it to /Applications
set -e
cd "$(dirname "$0")"

APP_NAME="ClaudeBar"
BUNDLE_ID="com.claudebar.app"
APP_PATH="/Applications/$APP_NAME.app"

echo "→ Building release binary..."
swift build -c release

echo "→ Creating app bundle..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp .build/release/ClaudeBar "$APP_PATH/Contents/MacOS/ClaudeBar"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeBar</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
PLIST

echo "→ Code signing (ad-hoc)..."
codesign --sign - --force --deep "$APP_PATH"

echo ""
echo "✓ /Applications/ClaudeBar.app is ready"
echo ""
echo "  Launch: open /Applications/ClaudeBar.app"
echo "  Or:     double-click it in Finder → Applications"
