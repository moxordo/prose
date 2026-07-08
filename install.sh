#!/usr/bin/env bash
# Prose installer.
#
#   curl -fsSL https://raw.githubusercontent.com/moxordo/prose/main/install.sh | bash
#
# Builds the app FROM SOURCE on your machine (swift build) — deliberately: we
# can't notarize, and a downloaded prebuilt binary would be quarantined by
# Gatekeeper. A locally built app has no quarantine flag and just runs.
#
# What it does:
#   1. Builds Prose.app -> ~/Applications
#   2. Writes a default config -> ~/.config/prose/config.json  (if absent)
#   3. Stores your Ollama Cloud API key in the Keychain          (if interactive)
#   4. Launches the app (grant Accessibility when prompted)
set -euo pipefail

REPO="moxordo/prose"
BRANCH="main"
BUNDLE_ID="com.moxordo.prose"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "macOS only."
command -v swift >/dev/null 2>&1 || fail "swift not found — install Xcode Command Line Tools: xcode-select --install"

# Locate sources: local checkout if run from the repo, otherwise fetch tarball.
SRC=""
CLEANUP=""
if [ -f "${BASH_SOURCE[0]:-/dev/null}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/Package.swift" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  say "Installing from local checkout: $SRC"
else
  TMP="$(mktemp -d)"
  CLEANUP="$TMP"
  say "Fetching $REPO@$BRANCH"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$TMP"
  SRC="$TMP/$(ls "$TMP" | head -1)"
fi

# 1. Build.
say "Building (swift build -c release) — first build downloads nothing, ~15s…"
( cd "$SRC" && swift build -c release )

# 2. Assemble the .app bundle into ~/Applications.
APP="$HOME/Applications/Prose.app"
say "Installing -> $APP"
pkill -f "Prose.app/Contents/MacOS/prose" 2>/dev/null || true
sleep 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/.build/release/prose" "$APP/Contents/MacOS/prose"
cp "$SRC/scripts/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true

# 3. Default config (cloud + gemma3:27b) if the user has none.
CFG="$HOME/.config/prose/config.json"
if [ ! -f "$CFG" ]; then
  say "Writing default config -> $CFG"
  mkdir -p "$(dirname "$CFG")"
  cat > "$CFG" <<'JSON'
{
  "ollamaBaseURL": "https://ollama.com",
  "model": "gemma3:27b",
  "forceClickEnabled": true
}
JSON
  chmod 600 "$CFG"
fi

# 4. Ollama Cloud API key -> Keychain (only when interactive and not already set).
if ! security find-generic-password -s prose-ollama-api-key >/dev/null 2>&1; then
  if [ -t 0 ]; then
    printf 'Enter your Ollama Cloud API key (https://ollama.com — or blank to use a local model): '
    read -rs KEY; echo
    if [ -n "${KEY:-}" ]; then
      security add-generic-password -a "$USER" -s prose-ollama-api-key -w "$KEY" -U
      say "Stored API key in the Keychain."
    else
      say "No key entered. Point config at a local Ollama, or add a key later (see README)."
    fi
  else
    say "No Ollama key found. Add one later:"
    echo "    security add-generic-password -a \"\$USER\" -s prose-ollama-api-key -w '<key>' -U"
  fi
fi

say "Launching Prose…"
open "$APP"
[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"

say "Done."
echo "    • Grant Accessibility when prompted (System Settings → Privacy & Security → Accessibility)."
echo "    • Trigger: select text anywhere → ⌥⌘R (or force-click)."
echo "    • Preferences: menu-bar ✨ → Preferences…  (⌘,)"
echo "    • Logs: ~/Library/Logs/Prose.log"
