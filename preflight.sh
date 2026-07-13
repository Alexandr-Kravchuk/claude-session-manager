#!/bin/bash
# Pre-flight: require Apple Swift >= $MIN_SWIFT. Universal packaging builds each
# architecture separately and combines them with lipo, so current Command Line Tools
# work without SwiftPM's multi-arch xcbuild integration from the full Xcode bundle.
# Sourced by build scripts; `exit 1` here aborts the caller.
MIN_SWIFT="5.9"
SWIFT_VER="$(swift --version 2>/dev/null | sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
if [[ -z "$SWIFT_VER" ]]; then
    echo "✗ Apple Swift $MIN_SWIFT+ required (swift was not found)"
    exit 1
fi
if [[ "$(printf '%s\n%s\n' "$MIN_SWIFT" "$SWIFT_VER" | sort -V | head -1)" != "$MIN_SWIFT" ]]; then
    echo "✗ Apple Swift $MIN_SWIFT+ required (found: $SWIFT_VER)"
    exit 1
fi
