#!/bin/bash
# Build and launch ClaudeBar in the background
set -e
cd "$(dirname "$0")"

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

pkill -x ClaudeBar 2>/dev/null || true
sleep 0.3

swift build -c release 2>&1 | tail -3
nohup .build/release/ClaudeBar > /tmp/claudebar.log 2>&1 &
echo "ClaudeBar started (PID $!)"
