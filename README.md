# Prose

A macOS menu-bar utility: **select text in any app, force-click, and a floating
panel shows an improved rewrite** (clearer prose) with Copy / Replace actions.
Backed by Ollama — your cloud subscription (`ollama.com`) or a local model.

Inspired by the built-in "Look Up" force-click gesture and tools like PopClip.

## Status

Built and verified end-to-end against **local (`llama3.2:3b`) and cloud
(`gemma3:27b` via your Ollama subscription)**. The entire capture→rewrite→present
pipeline plus the panel UI are automatically tested. The only step software
cannot perform for you is the **one-time Accessibility grant** (an OS security
boundary) — see [Setup](#setup).

## How it works

Four stages, each behind a protocol with a real implementation and a test double
— which is what makes an "app you can only test by force-clicking in Slack" into
one whose whole pipeline runs headlessly from the CLI:

| Stage | Production impl | Notes |
|---|---|---|
| **Trigger** | `ForceClickTrigger` (global `NSEvent .pressure`, stage 2) + `HotkeyTrigger` (⌥⌘R, Carbon) | Hotkey needs no Accessibility → reliable fallback |
| **Capture** | `AXSelectionCapture` → `ClipboardCopyCapture` (`CompositeCapture`) | AX first; synthetic-⌘C fallback with pasteboard save/restore covers Terminal/Electron |
| **Rewrite** | `OllamaRewriter` (streaming `/api/chat`) | Backend-agnostic: base URL + optional bearer. Thinking-aware (handles reasoning models) |
| **Present** | `PanelPresenter` (non-activating `NSPanel` + SwiftUI) | Non-activating so focus stays in the source app for Replace |

The network call runs off the main actor; rewrite deltas flow back through an
`AsyncStream` the main actor drains in order, so streamed text never scrambles.

## Setup

```bash
# 1. Build the app bundle
scripts/bundle.sh release          # → dist/Prose.app

# 2. Store your Ollama Cloud key in the Keychain (already done if you ran the installer)
security add-generic-password -a "$USER" -s prose-ollama-api-key -w '<your-key>' -U

# 3. Point config at your backend (default: cloud + gemma3:27b)
#    ~/.config/prose/config.json  — a minimal file works; missing fields default.
cat ~/.config/prose/config.json
# { "ollamaBaseURL": "https://ollama.com", "model": "gemma3:27b", "forceClickEnabled": true }

# 4. Launch, then grant Accessibility (one time, unavoidable OS step)
open dist/Prose.app
#    System Settings → Privacy & Security → Accessibility → enable Prose
```

Then: select text anywhere → **force-click** (or press **⌥⌘R**) → the panel appears.

### Backend config

Key resolution precedence: `PROSE_OLLAMA_KEY` / `OLLAMA_API_KEY` env → Keychain
(`prose-ollama-api-key`) → `apiKey` in config.json. The key never lives in
config.json.

- **Cloud:** `ollamaBaseURL: https://ollama.com`, a `-cloud`-capable model (e.g.
  `gemma3:27b`, `gpt-oss:120b`), key in Keychain.
- **Local:** install Ollama, `ollama pull llama3.2:3b`, set
  `ollamaBaseURL: http://localhost:11434`, `model: llama3.2:3b`, no key.

## CLI

```bash
prose run                 # launch menu-bar app (default)
prose selftest            # headless capture→rewrite→stdout (uses config backend)
prose selftest --local    # force local Ollama
prose selftest --text "…" # rewrite specific text
prose capture-test        # print current selection (needs Accessibility)
prose snapshot --out p.png # render the panel UI to a PNG
prose config              # show resolved config (key redacted)
```

## Testing

```bash
swift test                # 13 offline tests: parser, config, pipeline, pasteboard

# Live integration (opt-in, hits a real backend):
PROSE_LIVE_OLLAMA=1 PROSE_OLLAMA_URL=http://localhost:11434 PROSE_MODEL=llama3.2:3b swift test --filter LiveOllamaTests
PROSE_LIVE_OLLAMA=1 PROSE_OLLAMA_URL=https://ollama.com PROSE_MODEL=gemma3:27b PROSE_OLLAMA_KEY=… swift test --filter LiveOllamaTests
```

## Limitations & notes

- **Accessibility is mandatory and manual.** Global monitoring, reading other
  apps' selection, and synthetic ⌘C/⌘V all require it. No app can self-grant it.
- **Force-click detection is passive.** The global monitor can't consume the
  event, so macOS "Look Up" may also fire; and pressure delivery isn't guaranteed
  in every non-Cocoa surface — hence the ⌥⌘R fallback.
- **Not sandboxable** → not App Store; distribute as a notarized DMG (ad-hoc
  signing works locally; notarization is not yet wired up).
- Password/secure-input fields won't expose text (by design).
- Reasoning models (e.g. `gpt-oss:120b`) add latency; `gemma3:27b` streams
  immediately and is the default.
