import Foundation

/// Minimal async subprocess runner.
enum Subprocess {
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil) async throws
        -> (stdout: String, stderr: String, code: Int32)
    {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = cwd }
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                // Rewrites are short, so reading after exit won't deadlock the pipe.
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (
                    String(decoding: out, as: UTF8.self),
                    String(decoding: err, as: UTF8.self),
                    proc.terminationStatus
                ))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Claude via your **subscription** — shells out to the logged-in `claude` CLI
/// (Claude Code / the agent SDK), which authenticates with your Claude.ai OAuth
/// session. No API key or per-token billing; uses whatever plan you're signed
/// into. `config.model` maps to `claude --model` (accepts `sonnet`/`opus`/`haiku`
/// or a full model id; empty = the CLI default).
public struct ClaudeSubscriptionRewriter: Rewriting {
    public let config: ProseConfig
    public init(config: ProseConfig) { self.config = config }

    public func rewrite(
        _ text: String,
        onEvent: @escaping @Sendable (RewriteEvent) -> Void
    ) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RewriteError.emptyInput }

        guard let claude = try await Self.resolveClaudePath() else {
            throw RewriteError.api("`claude` CLI not found. Install Claude Code and run `claude` once to sign in.")
        }

        onEvent(.thinking("running claude…"))
        let prompt = config.composedSystemPrompt
            + "\n\nRewrite the following text to improve it. Output ONLY the rewritten text — no preamble, no explanation, no quotes.\n\n---\n"
            + input

        var args = ["-p", prompt, "--output-format", "text"]
        if !config.model.isEmpty { args += ["--model", config.model] }

        // Run in a neutral cwd so a project's CLAUDE.md doesn't leak into the prompt.
        let (out, err, code) = try await Subprocess.run(
            claude, args, cwd: FileManager.default.temporaryDirectory)
        guard code == 0 else {
            throw RewriteError.api("claude CLI failed (exit \(code)): \(err.prefix(300))")
        }
        let result = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw RewriteError.emptyResponse }

        // No token stream from `--output-format text`; emit in word chunks so the
        // panel still animates.
        var emitted = ""
        for word in result.split(separator: " ", omittingEmptySubsequences: false) {
            let chunk = (emitted.isEmpty ? "" : " ") + word
            emitted += chunk
            onEvent(.content(chunk))
        }
        return result
    }

    static func resolveClaudePath() async throws -> String? {
        // Prefer the login shell's PATH (picks up nvm / homebrew / custom installs).
        if let (out, _, code) = try? await Subprocess.run("/bin/zsh", ["-lc", "command -v claude"]) {
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in [
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
        ] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
