#!/bin/bash
# Build a universal ClaudeBar.app and zip it into dist/ as a GitHub release asset.
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
