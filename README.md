# Prose

A macOS menu-bar utility: **select text in any app and press ⌥⌘R (or force-click) to get a clearer rewrite** in a floating panel, with Copy / Replace-in-place. Backed by Ollama — your cloud subscription (`ollama.com`) or a local model.

You teach it *your* style: editable **Rules** (hard constraints) and **Preferences** (soft guidance) that shape every rewrite.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/moxordo/prose/main/install.sh | bash
```

Builds from source on your machine (so Gatekeeper doesn't quarantine it) into `~/Applications/Prose.app`, writes a default config, and launches it. Then **grant Accessibility** when prompted (System Settings → Privacy & Security → Accessibility) — it's required to read your selection and post ⌘V.

Requirements: macOS 14+, Xcode Command Line Tools (`xcode-select --install`), and an [Ollama Cloud](https://ollama.com) key *or* a local Ollama.

Uninstall: `curl -fsSL https://raw.githubusercontent.com/moxordo/prose/main/uninstall.sh | bash` (add `--purge` to also drop config + key).

<details>
<summary>Manual / from a clone</summary>

```bash
git clone https://github.com/moxordo/prose && cd prose
./install.sh                 # build + install to ~/Applications + launch
# or just build the bundle without installing:
./scripts/bundle.sh release  # -> dist/Prose.app
```
</details>

## Use

1. Select text anywhere (Slack, Sublime, Terminal, a browser…).
2. Press **⌥⌘R** — or **force-click** the selection.
3. The panel streams a rewrite. Act with the mouse or keyboard:
   - **Esc** → Dismiss · **⌘C** → Copy · **⌘↩** → Replace in place

Everything lives under the menu-bar **✨** icon (which may hide behind the notch if your menu bar is full): trigger a rewrite, open **Preferences… (⌘,)**, or quit.

## Preferences — teach it your style

**Preferences… (⌘,)** opens an editor with two lists (one item per line):

- **Rules** — hard constraints the model must always follow. Default:
  - *Keep the original language. If the text mixes languages, infer and adapt to the user's own style.*
- **Preferences** — soft guidance applied when it improves the text. Defaults:
  - *Shorter is normally better.*
  - *If a shorter expression is closer to the lingua franca of the domain, suggest it.*
  - *Infer the context the text will appear in and fit that register.*

Plus the **model** and **creativity** (temperature). Saving writes `~/.config/prose/config.json` (your API key stays in the Keychain, never on disk) and applies to the next rewrite immediately.

## Backends (pluggable)

Pick a provider in **Preferences… (⌘,)** or via `config.json`'s `provider` field:

| Provider (`provider`) | Auth | Default model | Notes |
|---|---|---|---|
| **Claude — subscription** (`claude-subscription`) | The signed-in `claude` CLI (your Claude.ai OAuth) | `sonnet` | No API key, no per-token billing; shells out to Claude Code |
| **Claude — API key** (`anthropic`) | `ANTHROPIC_API_KEY` | `claude-opus-4-8` | Anthropic Messages API; no `temperature`, no thinking (fast) |
| **Ollama** (`ollama`) | optional key | `gemma3:27b` (cloud) / `llama3.2:3b` (local) | `ollamaBaseURL: https://ollama.com` + key, or `http://localhost:11434` |
| **OpenAI / ChatGPT** (`openai`) | `OPENAI_API_KEY` | `gpt-4o` | Chat Completions API |

**Key resolution** (per active provider): `PROSE_<PROVIDER>_KEY` / `<PROVIDER>_API_KEY` env → Keychain (`prose-<provider>-api-key`) → nothing. Keys live in the **Keychain**, never in config.json. Settings writes a pasted key into the right Keychain service automatically.

```jsonc
// ~/.config/prose/config.json — switch backend by changing "provider" + "model"
{ "provider": "claude-subscription", "model": "sonnet", "forceClickEnabled": true }
```

CLI: `prose selftest --provider anthropic --model claude-haiku-4-5 --text "…"`

## How it works

Four stages, each behind a protocol with a real implementation and a test double — so the whole pipeline runs headlessly from the CLI:

| Stage | Production impl | Notes |
|---|---|---|
| **Trigger** | `HotkeyTrigger` (⌥⌘R, Carbon) + `ForceClickTrigger` | Hotkey needs no Accessibility. Force-click uses an `NSEvent` monitor + `CGEventTap`; auto-re-arms when Accessibility is granted |
| **Capture** | `AXSelectionCapture` → `ClipboardCopyCapture` | AX first; synthetic-⌘C fallback with pasteboard save/restore covers Terminal/Electron |
| **Rewrite** | `makeRewriter(config)` → Ollama / Anthropic / OpenAI / Claude-CLI | Pluggable provider behind one `Rewriting` protocol; Rules + Preferences composed into the prompt |
| **Present** | `PanelPresenter` (key `NSPanel` + SwiftUI) | Streams the rewrite; Copy / Replace-in-place; returns focus to the source app |

## CLI

```bash
prose run                 # menu-bar app (default)
prose selftest [--local]  # headless capture→rewrite→stdout
prose config              # show resolved config (key redacted)
prose diagnose            # 20s force-click / event probe
prose snapshot --out p.png
```

## Development

```bash
swift build && swift test           # 18 offline tests
# live tests (opt-in):
PROSE_LIVE_OLLAMA=1 PROSE_OLLAMA_URL=https://ollama.com PROSE_MODEL=gemma3:27b PROSE_OLLAMA_KEY=… swift test --filter LiveOllamaTests
```

## Notes & limits

- **Accessibility is mandatory and manual** — no app can self-grant it.
- **Force-click** is best-effort: macOS doesn't broadcast pressure events globally, so ⌥⌘R is the reliable trigger. Diagnostics land in `~/Library/Logs/Prose.log`.
- Not sandboxed / not notarized → installs by building locally (no Gatekeeper quarantine).
- Password/secure-input fields won't expose text (by design).

## License

MIT © moxordo
