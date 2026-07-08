#!/usr/bin/env bash
# Prose uninstaller. Removes the app and resets its Accessibility grant.
# Leaves your config + Keychain key in place unless you pass --purge.
set -euo pipefail

BUNDLE_ID="com.moxordo.prose"
say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

say "Quitting Prose…"
pkill -f "Prose.app/Contents/MacOS/prose" 2>/dev/null || true

say "Removing ~/Applications/Prose.app"
rm -rf "$HOME/Applications/Prose.app"

say "Resetting Accessibility grant"
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true

if [ "${1:-}" = "--purge" ]; then
  say "Purging config + Keychain key"
  rm -rf "$HOME/.config/prose"
  security delete-generic-password -s prose-ollama-api-key >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Logs/Prose.log"
else
  echo "Kept your config + Keychain key. To remove them too:"
  echo "    rm -rf ~/.config/prose"
  echo "    security delete-generic-password -s prose-ollama-api-key"
fi

say "Done."
