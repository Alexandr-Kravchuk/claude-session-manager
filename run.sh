#!/bin/bash
# Build, install, and launch ClaudeBar in the background.
# Uses single native arch for speed (vs. universal in package.sh / release.sh).
set -e
cd "$(dirname "$0")"

source "$(dirname "$0")/preflight.sh"

APP_NAME="ClaudeBar"
BUNDLE_ID="com.claudebar.app"
APP_PATH="/Applications/$APP_NAME.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "dev")"

pkill -x ClaudeBar 2>/dev/null || true
sleep 0.3

swift build -c release 2>&1 | tail -3
BIN=".build/release/$APP_NAME"

# Install / refresh app bundle
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp "Sources/ClaudeBar/Assets/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
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

codesign --sign - --force --deep "$APP_PATH" 2>/dev/null

nohup "$APP_PATH/Contents/MacOS/$APP_NAME" > /tmp/claudebar.log 2>&1 &
echo "ClaudeBar started (PID $!)"
