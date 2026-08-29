import Foundation

/// Minimal async subprocess runner.
enum Subprocess {
    static func run(
        _ executable: String, _ args: [String], cwd: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> (stdout: String, stderr: String, code: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = cwd }
            if let environment { process.environment = environment }
            // Close stdin: the `claude` CLI otherwise waits ~3s for piped input.
            process.standardInput = FileHandle.nullDevice
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

    /// Flags that turn `claude -p` into a plain model call. Each one closes a
    /// real failure seen in the panel:
    /// - `--output-format json`: the rewrite arrives in a `result` envelope, so
    ///   anything else the CLI prints to stdout can't be mistaken for it.
    /// - `--strict-mcp-config` (with no `--mcp-config`): zero MCP servers. Their
    ///   startup chatter ("Client.listTools() called but server does not
    ///   advertise tools capability") leaked straight into the rewrite.
    /// - `--tools ""`: no built-in tools; a rewrite needs none.
    /// - `--setting-sources ""`: ignore settings files, which is where hooks and
    ///   plugins come from — a hook that needs `node` fails under the GUI PATH
    ///   and takes the whole run down. (`--bare` would do this too, but it also
    ///   skips the keychain, so the subscription login isn't found.)
    /// - `--no-session-persistence`: don't write a transcript under
    ///   `~/.claude/projects` for every rewrite.
    static let isolationArgs: [String] = [
        "--output-format", "json",
        "--strict-mcp-config",
        "--tools", "",
        "--setting-sources", "",
        "--no-session-persistence",
    ]

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

        var args = ["-p", prompt] + Self.isolationArgs
        if !config.model.isEmpty { args += ["--model", config.model] }

        // Run in a neutral cwd so a project's CLAUDE.md doesn't leak into the prompt.
        let (out, err, code) = try await Subprocess.run(
            claude, args, cwd: FileManager.default.temporaryDirectory,
            environment: await Self.processEnvironment())
        let result = try Self.extractResult(stdout: out, stderr: err, exitCode: code)

        // No token stream from `-p`; emit in word chunks so the panel still animates.
        var emitted = ""
        for word in result.split(separator: " ", omittingEmptySubsequences: false) {
            let chunk = (emitted.isEmpty ? "" : " ") + word
            emitted += chunk
            onEvent(.content(chunk))
        }
        return result
    }

    // MARK: - Result envelope

    struct Envelope: Decodable {
        let type: String?
        let isError: Bool?
        let result: String?
        enum CodingKeys: String, CodingKey { case type, isError = "is_error", result }
    }

    /// Pull the rewrite out of `--output-format json` stdout. Prefers the
    /// envelope over the exit code: a non-zero exit with a good envelope (e.g. a
    /// failing hook) still yields the text, and a zero exit with `is_error`
    /// (e.g. "Not logged in") still surfaces the message.
    static func extractResult(stdout: String, stderr: String, exitCode: Int32) throws -> String {
        if let envelope = parseEnvelope(stdout) {
            let text = (envelope.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if envelope.isError == true {
                throw RewriteError.api("claude CLI: \(text.isEmpty ? "unknown error" : text)")
            }
            guard !text.isEmpty else { throw RewriteError.emptyResponse }
            return text
        }
        guard exitCode == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RewriteError.api("claude CLI failed (exit \(exitCode)): \(detail.prefix(300))")
        }
        throw RewriteError.api("claude CLI returned no result: \(stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
    }

    /// The envelope is one JSON line, but stray lines can surround it
    /// (MCP/hook chatter on stdout), so scan lines from the end.
    static func parseEnvelope(_ stdout: String) -> Envelope? {
        let decoder = JSONDecoder()
        func decode(_ s: Substring) -> Envelope? {
            guard let e = try? decoder.decode(Envelope.self, from: Data(s.utf8)), e.type == "result" else { return nil }
            return e
        }
        if let whole = decode(Substring(stdout)) { return whole }
        for line in stdout.split(separator: "\n").reversed() {
            if let e = decode(line) { return e }
        }
        return nil
    }

    // MARK: - Environment

    /// The GUI app inherits a bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so
    /// anything `claude` spawns can't find nvm/homebrew binaries. Hand it the
    /// login shell's PATH instead; resolved once per process.
    static func processEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let path = await loginShellPATH() { env["PATH"] = path }
        return env
    }

    private actor PathCache {
        static let shared = PathCache()
        var value: String?
        func set(_ v: String) { value = v }
    }

    static func loginShellPATH() async -> String? {
        if let cached = await PathCache.shared.value { return cached }
        guard let (out, _, code) = try? await Subprocess.run("/bin/zsh", ["-lc", "printf %s \"$PATH\""]),
              code == 0 else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        await PathCache.shared.set(path)
        return path
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
