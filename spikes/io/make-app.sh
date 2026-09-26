#!/bin/sh
# Wraps the yapio CLI in a minimal .app bundle so that, when started with `open`, it is its own
# TCC "responsible process" (prompts and System Settings entries say "yapio", not the terminal).
# Usage: ./make-app.sh && open -W --stdout "$PWD/.local/out.txt" --stderr "$PWD/.local/err.txt" .local/yapio.app --args systap
set -eu
cd "$(dirname "$0")"
swift build
app=.local/yapio.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/debug/yapio "$app/Contents/MacOS/yapio"
cp Support/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "built $app"
