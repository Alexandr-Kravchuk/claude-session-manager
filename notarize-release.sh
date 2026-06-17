#!/bin/bash
# Build a universal ClaudeBar.app, sign it with the Developer ID cert, notarize via Apple,
# staple the ticket, and zip it as the GitHub release asset.
#
# Reproduces the (previously unscripted) signed+notarized release flow used through v2.1.1.
# Requires ~/secrets/adac-release.env exporting:
#   MAC_CERT_P12, MAC_CERT_PASSWORD, APPLE_API_KEY (.p8 path), APPLE_API_KEY_ID, APPLE_API_ISSUER
#
# Usage: VERSION=x.y.z ./notarize-release.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${VERSION:?Usage: VERSION=x.y.z ./notarize-release.sh}"
set -a; source ~/secrets/adac-release.env; set +a

APP="dist/ClaudeBar.app"
ASSET="dist/ClaudeBar-$VERSION-macos-universal.zip"
NOTARIZE_ZIP="dist/ClaudeBar-notarize.zip"

# --- 1. Build the universal app (package.sh ad-hoc signs; we re-sign below) ---
echo "→ Building universal app v$VERSION…"
VERSION="$VERSION" APP_PATH="$APP" ./package.sh >/dev/null

# --- 2. Import the Developer ID cert into a throwaway keychain ---
KC="$HOME/Library/Keychains/claudebar-release-$$.keychain-db"
KCPASS="rel-$$"
ORIG_KEYCHAINS=$(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"$//')
cleanup() {
  # Restore the original keychain search list and delete the temp keychain.
  security list-keychains -d user -s $ORIG_KEYCHAINS >/dev/null 2>&1 || true
  security delete-keychain "$KC" >/dev/null 2>&1 || true
  rm -f "$NOTARIZE_ZIP"
}
trap cleanup EXIT

echo "→ Importing signing certificate…"
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$MAC_CERT_P12" -k "$KC" -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
# Prepend the temp keychain to the search list so codesign can find the identity.
security list-keychains -d user -s "$KC" $ORIG_KEYCHAINS >/dev/null

IDENT=$(security find-identity -v -p codesigning "$KC" | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"$/\1/')
[ -n "$IDENT" ] || { echo "✗ No Developer ID Application identity in the cert" >&2; exit 1; }
echo "  identity: $IDENT"

# --- 3. Re-sign with Developer ID, hardened runtime, secure timestamp ---
echo "→ Signing…"
codesign --force --deep --options runtime --timestamp --sign "$IDENT" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- 4. Notarize ---
echo "→ Submitting to Apple notary (waits for result)…"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait

# --- 5. Staple + final asset zip ---
echo "→ Stapling…"
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP"

rm -f "$ASSET"
ditto -c -k --keepParent "$APP" "$ASSET"
shasum -a 256 "$ASSET"
echo ""
echo "✓ $ASSET (signed + notarized + stapled)"
