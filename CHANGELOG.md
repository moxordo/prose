# Changelog

All notable changes to Prose are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] — 2026-08-31

### Added
- **Codex backend** (`codex-subscription`): rewrites through the signed-in `codex` CLI on a ChatGPT plan. Model presets from the local Codex catalog (`gpt-5.6-sol` default).
- **Reset & re-grant** for Accessibility (dialog button + menu item): runs `tccutil reset Accessibility com.moxordo.prose` and re-prompts, for grants left stale by a rebuild.
- Launch log records the code-signature kind, so a stale grant is diagnosable.
- `CHANGELOG.md`, CI (build + test + bundle on macOS), single version source (`ProseVersion`).

### Changed
- **Claude backend** now runs `claude -p` in isolation: `--output-format json --strict-mcp-config --tools "" --setting-sources "" --no-session-persistence`; the rewrite is read from the JSON `result` envelope. MCP-server chatter no longer leaks into the panel, and Claude Code hooks/plugins no longer run (or fail) per rewrite.
- Both CLI backends run with an augmented `PATH` (login shell ∪ nvm/volta/bun/`~/.local/bin`, tool's own directory first) and a watchdog bound to `requestTimeout`; stdin is closed; pipes are drained concurrently.
- `install.sh` / `bundle.sh` sign with your Apple Development / Developer ID identity when available (`PROSE_SIGN_IDENTITY` overrides), so the Accessibility grant survives rebuilds. Ad-hoc fallback carries an identifier-based requirement.
- Provider errors are labelled `Provider error:` (was `Ollama error:` for every backend).
- Launch dialog explains the stale-grant case instead of asking for a relaunch.

## [0.1.0] — 2026-07-09

### Added
- Menu-bar app: select text in any app, press ⌥⌘R (or force-click) → streamed rewrite in a floating panel with Dismiss ⎋ / Copy ⌘C / Replace ⌘↩.
- Backends: Claude (subscription CLI or API key), Ollama (local or ollama.com), OpenAI.
- Editable **Rules** (hard) and **Preferences** (soft) that shape the system prompt; model picker; creativity slider.
- Configurable hotkey with an Alfred-style recorder.
- Force-click trigger (best-effort) with auto re-arm when Accessibility is granted.
- `install.sh` / `uninstall.sh` build-from-source installer; CLI: `selftest`, `config`, `diagnose`, `snapshot`.

[Unreleased]: https://github.com/moxordo/prose/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/moxordo/prose/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/moxordo/prose/releases/tag/v0.1.0
