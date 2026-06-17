#!/bin/bash
# Build a universal ClaudeBar.app and zip it into dist/ — AD-HOC SIGNED ONLY.
# For an actual published release use ./notarize-release.sh (Developer ID + notarize +
# staple); shipping this ad-hoc zip would regress new users to a Gatekeeper warning.
# Usage: VERSION=x.y.z ./release.sh
set -e
cd "$(dirname "$0")"

if [ -z "$VERSION" ]; then
    echo "Usage: VERSION=x.y.z ./release.sh" >&2
    exit 1
fi

APP_PATH="dist/ClaudeBar.app" VERSION="$VERSION" ./package.sh

ZIP_PATH="dist/ClaudeBar-$VERSION-macos-universal.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent dist/ClaudeBar.app "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH"

echo ""
echo "✓ $ZIP_PATH"
echo "  Publish: gh release create v$VERSION \"$ZIP_PATH\" --title \"ClaudeBar $VERSION\""
