#!/bin/bash
# Build ClaudeBar.app (universal arm64 + x86_64) and install it to /Applications.
# Override VERSION and APP_PATH for release packaging (see release.sh).
set -e
cd "$(dirname "$0")"

APP_NAME="ClaudeBar"
BUNDLE_ID="com.claudebar.app"
VERSION="${VERSION:-1.0}"
APP_PATH="${APP_PATH:-/Applications/$APP_NAME.app}"

source "$(dirname "$0")/preflight.sh"

echo "→ Building universal release binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "→ Creating app bundle..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"

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

echo "→ Code signing (ad-hoc)..."
codesign --sign - --force --deep "$APP_PATH"

echo ""
echo "✓ $APP_PATH is ready (version $VERSION, $(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME"))"
echo ""
echo "  Launch: open \"$APP_PATH\""
