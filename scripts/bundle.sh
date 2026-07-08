#!/bin/bash
# Assemble Prose.app from the SPM build and ad-hoc codesign it.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/${CONFIG}/prose"
APP="dist/Prose.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/prose"
cp scripts/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature (stable identity so Accessibility grant sticks across rebuilds
# is best-effort with "-"; for a durable grant, sign with a real identity).
echo "▸ codesigning (ad-hoc)…"
codesign --force --sign - --identifier com.andykim.prose "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/  /' || true

echo "▸ built $APP"
echo "  run:   open $APP        (or: \"$APP/Contents/MacOS/prose\")"
echo "  then:  grant Accessibility in System Settings → Privacy & Security → Accessibility"
