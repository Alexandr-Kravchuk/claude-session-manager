#!/bin/bash
# Build and launch ClaudeBar in the background
set -e
cd "$(dirname "$0")"

source "$(dirname "$0")/preflight.sh"

pkill -x ClaudeBar 2>/dev/null || true
sleep 0.3

swift build -c release 2>&1 | tail -3
nohup .build/release/ClaudeBar > /tmp/claudebar.log 2>&1 &
echo "ClaudeBar started (PID $!)"
