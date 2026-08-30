#!/usr/bin/env bash
# Sign Prose.app with a STABLE identity so the Accessibility grant survives rebuilds.
#
# macOS keys TCC grants (Accessibility etc.) to the app's *designated
# requirement*. An ad-hoc signature's requirement is `cdhash H"…"` — a hash of
# this exact binary — so every rebuild silently invalidates the grant while
# System Settings still shows Prose as ON. A certificate-backed signature's
# requirement is identifier + certificate, which is stable across rebuilds.
#
# Identity selection:
#   1. $PROSE_SIGN_IDENTITY  (a name or SHA-1 from `security find-identity -v -p codesigning`)
#   2. the first valid "Apple Development" / "Developer ID Application" identity
#   3. ad-hoc, with an explicit identifier-based designated requirement (best-effort:
#      TCC may still bind to the cdhash; use "Reset & re-grant" in the app after a rebuild)
#
# Usage: scripts/codesign.sh <path/to/Prose.app>
set -euo pipefail
APP="${1:?usage: codesign.sh <App.app>}"
BUNDLE_ID="com.moxordo.prose"

identity="${PROSE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E -o '"(Apple Development|Developer ID Application)[^"]*"' | head -1 | tr -d '"' || true)"
fi

if [ -n "$identity" ]; then
  codesign --force --sign "$identity" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
  echo "signed with: $identity — Accessibility grant persists across rebuilds"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
  echo "signed ad-hoc (no code-signing identity found) — re-grant Accessibility after rebuilds if it stops working"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || true
