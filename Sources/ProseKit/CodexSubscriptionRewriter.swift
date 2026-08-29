import Foundation

/// Codex via your **ChatGPT subscription** — shells out to the logged-in `codex`
/// CLI (`codex exec`). No API key. `config.model` maps to `codex -m` (empty =
/// the CLI default). Codex has no temperature; reasoning effort is pinned to
/// `low` because a rewrite needs none and a user's config default (often
/// `xhigh`) makes every rewrite slow.
public struct CodexSubscriptionRewriter: Rewriting {
    public let config: ProseConfig
    public init(config: ProseConfig) { self.config = config }

    /// Flags that turn `codex exec` into a plain model call — the Codex twin of
    /// `ClaudeSubscriptionRewriter.isolationArgs`, chosen against the same
    /// failure classes (a baseline run fired six hooks, hit an MCP `AuthRequired`
    /// transport error, and ran at the config's `xhigh` reasoning effort):
    /// - `--ignore-user-config`: skip `~/.codex/config.toml`, which is where MCP
    ///   servers, hooks and the reasoning default come from. Auth still comes
    ///   from `CODEX_HOME`, so the ChatGPT login is kept.
    /// - `--ephemeral`: no session files on disk for every rewrite.
    /// - `--sandbox read-only`: nothing the model runs can write anywhere.
    /// - `--skip-git-repo-check`: we run in a scratch directory, not a repo.
    /// - `--color never`: no ANSI escapes in anything we parse.
    /// - `-c model_reasoning_effort=low`: fast.
    /// The rewrite is read from `-o <file>` (the agent's last message), never
    /// from stdout — the same lesson as the Claude JSON envelope.
    static let isolationArgs: [String] = [
        "--ignore-user-config",
        "--ephemeral",
        "--sandbox", "read-only",
        "--skip-git-repo-check",
        "--color", "never",
        "-c", "model_reasoning_effort=low",
    ]

    public func rewrite(
        _ text: String,
        onEvent: @escaping @Sendable (RewriteEvent) -> Void
    ) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RewriteError.emptyInput }

        guard let codex = await CLIEnvironment.resolve("codex") else {
            throw RewriteError.api("`codex` CLI not found. Install Codex (npm i -g @openai/codex) and run `codex login` once.")
        }

        onEvent(.thinking("running codex…"))
        let prompt = config.composedSystemPrompt
            + "\n\nRewrite the following text to improve it. Output ONLY the rewritten text — no preamble, no explanation, no quotes. Do not run commands or use tools; answer directly.\n\n---\n"
            + input

        // Scratch dir: a neutral cwd (no AGENTS.md leaks in) that also holds the
        // output file; removed afterwards.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("prose-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outFile = scratch.appendingPathComponent("last-message.txt")

        var args = ["exec", prompt, "-C", scratch.path, "-o", outFile.path] + Self.isolationArgs
        if !config.model.isEmpty { args += ["-m", config.model] }

        let run: (stdout: String, stderr: String, code: Int32)
        do {
            run = try await Subprocess.run(
                codex, args, cwd: scratch,
                environment: await CLIEnvironment.environment(for: codex),
                timeout: config.requestTimeout)
        } catch let timeout as Subprocess.TimedOut {
            throw RewriteError.api("codex CLI timed out after \(Int(timeout.seconds))s (requestTimeout).")
        }
        let lastMessage = try? String(contentsOf: outFile, encoding: .utf8)
        let result = try Self.extractResult(
            lastMessage: lastMessage, stdout: run.stdout, stderr: run.stderr, exitCode: run.code)
        emitInWordChunks(result, onEvent)
        return result
    }

    // MARK: - Result extraction

    /// The `-o` file is the source of truth. stdout (the final message under
    /// `--color never`) is only a fallback on a clean exit; on failure the
    /// message is dug out of stderr.
    static func extractResult(lastMessage: String?, stdout: String, stderr: String, exitCode: Int32) throws -> String {
        let message = (lastMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }
        if exitCode == 0 {
            let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else { throw RewriteError.emptyResponse }
            return fallback
        }
        throw RewriteError.api("codex CLI failed (exit \(exitCode)): \(errorMessage(fromStderr: stderr))")
    }

    /// codex reports API failures as `ERROR: {"type":"error",…,"error":{"message":…}}`
    /// lines on stderr; pull the message out, else fall back to the last line.
    static func errorMessage(fromStderr stderr: String) -> String {
        let lines = stderr.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.reversed() where line.hasPrefix("ERROR") {
            guard let brace = line.firstIndex(of: "{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line[brace...].utf8)) as? [String: Any]
            else { continue }
            if let message = (obj["error"] as? [String: Any])?["message"] as? String ?? obj["message"] as? String {
                return message
            }
        }
        return String((lines.last ?? "no output").prefix(300))
    }
}
