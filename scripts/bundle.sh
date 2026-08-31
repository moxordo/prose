#!/bin/bash
# Assemble Prose.app from the SPM build and codesign it (scripts/codesign.sh picks
# a stable identity so the Accessibility grant survives rebuilds).
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
VERSION="$(grep -o 'current = "[^"]*"' Sources/ProseKit/Version.swift | cut -d'"' -f2)"
sed "s/__VERSION__/${VERSION:-0.0.0}/g" scripts/Info.plist > "$APP/Contents/Info.plist"

echo "▸ codesigning…"
bash scripts/codesign.sh "$APP" | sed 's/^/  /'

echo "▸ built $APP"
echo "  run:   open $APP        (or: \"$APP/Contents/MacOS/prose\")"
echo "  then:  grant Accessibility in System Settings → Privacy & Security → Accessibility"
