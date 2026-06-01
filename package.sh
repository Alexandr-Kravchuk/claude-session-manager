#!/bin/bash
# Build ClaudeBar.app and install it to /Applications
set -e
cd "$(dirname "$0")"

APP_NAME="ClaudeBar"
BUNDLE_ID="com.claudebar.app"
APP_PATH="/Applications/$APP_NAME.app"

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
