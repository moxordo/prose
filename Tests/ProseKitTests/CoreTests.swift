import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import ProseKit

// MARK: - Stream parser (the trickiest pure logic — reasoning vs content)

final class OllamaStreamParserTests: XCTestCase {
    func testContentDelta() {
        let line = #"{"model":"gemma3:27b","created_at":"t","message":{"role":"assistant","content":"Le"},"done":false}"#
        XCTAssertEqual(OllamaStreamParser.parse(line: line),
                       .chunk(thinking: nil, content: "Le", done: false))
    }

    func testThinkingDeltaHasEmptyContent() {
        // Reasoning models (gpt-oss) stream `thinking` with empty `content`.
        let line = #"{"message":{"role":"assistant","content":"","thinking":"We"},"done":false}"#
        XCTAssertEqual(OllamaStreamParser.parse(line: line),
                       .chunk(thinking: "We", content: "", done: false))
    }

    func testDoneLine() {
        let line = #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#
        XCTAssertEqual(OllamaStreamParser.parse(line: line),
                       .chunk(thinking: nil, content: "", done: true))
    }

    func testApiError() {
        let line = #"{"error":"model 'nope' not found"}"#
        XCTAssertEqual(OllamaStreamParser.parse(line: line),
                       .apiError("model 'nope' not found"))
    }

    func testBlankAndMalformedAreIgnored() {
        XCTAssertNil(OllamaStreamParser.parse(line: ""))
        XCTAssertNil(OllamaStreamParser.parse(line: "   "))
        XCTAssertNil(OllamaStreamParser.parse(line: "not json at all"))
    }
}

// MARK: - Anthropic + OpenAI SSE parsers

final class AnthropicStreamParserTests: XCTestCase {
    func testTextDelta() {
        let line = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        XCTAssertEqual(AnthropicStreamParser.parse(dataJSON: line), .text("Hello"))
    }
    func testThinkingDelta() {
        let line = #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        XCTAssertEqual(AnthropicStreamParser.parse(dataJSON: line), .thinking("hmm"))
    }
    func testMessageStop() {
        XCTAssertEqual(AnthropicStreamParser.parse(dataJSON: #"{"type":"message_stop"}"#), .done)
    }
    func testRefusal() {
        let line = #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#
        XCTAssertEqual(AnthropicStreamParser.parse(dataJSON: line), .refusal)
    }
    func testError() {
        let line = #"{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#
        XCTAssertEqual(AnthropicStreamParser.parse(dataJSON: line), .apiError("overloaded"))
    }
    func testPingAndDoneIgnored() {
        XCTAssertNil(AnthropicStreamParser.parse(dataJSON: #"{"type":"ping"}"#))
        XCTAssertNil(AnthropicStreamParser.parse(dataJSON: "[DONE]"))
        XCTAssertNil(AnthropicStreamParser.parse(dataJSON: ""))
    }
}

final class OpenAIStreamParserTests: XCTestCase {
    func testContentDelta() {
        let line = #"{"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(OpenAIStreamParser.parse(dataJSON: line), .text("Hello"))
    }
    func testDoneSentinel() {
        XCTAssertEqual(OpenAIStreamParser.parse(dataJSON: "[DONE]"), .done)
    }
    func testRoleOnlyDeltaIgnored() {
        let line = #"{"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertNil(OpenAIStreamParser.parse(dataJSON: line))
    }
    func testError() {
        let line = #"{"error":{"message":"bad key"}}"#
        XCTAssertEqual(OpenAIStreamParser.parse(dataJSON: line), .apiError("bad key"))
    }
}

// MARK: - Configuration

final class ConfigurationTests: XCTestCase {
    func testEnvironmentPrecedence() {
        var config = ProseConfig.default
        ConfigLoader.applyEnvironment([
            "PROSE_PROVIDER": "openai",
            "PROSE_OLLAMA_URL": "https://ollama.com",
            "PROSE_MODEL": "gpt-4o",
            "PROSE_TEMPERATURE": "0.7",
        ], to: &config)
        XCTAssertEqual(config.provider, .openai)
        XCTAssertEqual(config.ollamaBaseURL, "https://ollama.com")
        XCTAssertEqual(config.model, "gpt-4o")
        XCTAssertEqual(config.temperature, 0.7, accuracy: 0.0001)
    }

    func testProviderKeyResolvedFromEnvForActiveProvider() {
        let config = ConfigLoader.load(
            path: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
            environment: ["PROSE_PROVIDER": "anthropic", "ANTHROPIC_API_KEY": "sk-ant-test"]
        )
        XCTAssertEqual(config.provider, .anthropicAPI)
        XCTAssertEqual(config.apiKey, "sk-ant-test")
    }

    func testProviderDefaults() {
        XCTAssertEqual(LLMProvider.anthropicAPI.defaultModel, "claude-opus-4-8")
        XCTAssertEqual(LLMProvider.anthropicAPI.keychainService, "prose-anthropic-api-key")
        XCTAssertEqual(LLMProvider.openai.envVarNames, ["PROSE_OPENAI_KEY", "OPENAI_API_KEY"])
        XCTAssertTrue(LLMProvider.openai.needsKey)
        XCTAssertFalse(LLMProvider.claudeSubscription.needsKey)
        XCTAssertFalse(LLMProvider.codexSubscription.needsKey)
        XCTAssertEqual(LLMProvider.codexSubscription.rawValue, "codex-subscription")
        XCTAssertEqual(LLMProvider.codexSubscription.defaultModel, "gpt-5.6-sol")
        XCTAssertEqual(LLMProvider(rawValue: "codex-subscription"), .codexSubscription)
    }

    func testLenientPartialDecode() throws {
        let json = #"{"ollamaBaseURL":"https://ollama.com","model":"gemma3:27b"}"#
        let config = try JSONDecoder().decode(ProseConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.ollamaBaseURL, "https://ollama.com")
        XCTAssertEqual(config.model, "gemma3:27b")
        // Everything omitted falls back to defaults.
        XCTAssertEqual(config.temperature, ProseConfig.default.temperature)
        XCTAssertEqual(config.hotkey, HotkeyConfig.default)
        XCTAssertEqual(config.systemPrompt, ProseConfig.default.systemPrompt)
    }

    func testNormalizedBaseURLStripsSlashes() {
        var config = ProseConfig.default
        config.ollamaBaseURL = "https://ollama.com///"
        XCTAssertEqual(config.normalizedBaseURL, "https://ollama.com")
    }

    func testComposedSystemPromptIncludesRulesAndPreferences() {
        var config = ProseConfig.default
        config.systemPrompt = "BASE."
        config.rules = ["Keep the original language.", "  "]  // blank is dropped
        config.preferences = ["Shorter is better."]
        let prompt = config.composedSystemPrompt
        XCTAssertTrue(prompt.hasPrefix("BASE."))
        XCTAssertTrue(prompt.contains("Follow these RULES strictly:"))
        XCTAssertTrue(prompt.contains("- Keep the original language."))
        XCTAssertTrue(prompt.contains("Apply these PREFERENCES"))
        XCTAssertTrue(prompt.contains("- Shorter is better."))
        XCTAssertFalse(prompt.contains("-  \n"))  // blank rule not emitted
    }

    func testComposedSystemPromptOmitsEmptySections() {
        var config = ProseConfig.default
        config.systemPrompt = "BASE."
        config.rules = []
        config.preferences = []
        XCTAssertEqual(config.composedSystemPrompt, "BASE.")
    }

    func testSaveStripsApiKeyAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prose-test-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = ProseConfig.default
        config.apiKey = "SECRET-should-not-persist"
        config.rules = ["R1"]
        config.preferences = ["P1", "P2"]
        config.model = "gemma3:27b"
        XCTAssertTrue(ConfigLoader.save(config, to: url))

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("SECRET-should-not-persist"), "API key must never be written to disk")

        let reloaded = ConfigLoader.load(path: url, environment: [:])
        XCTAssertEqual(reloaded.rules, ["R1"])
        XCTAssertEqual(reloaded.preferences, ["P1", "P2"])
        XCTAssertEqual(reloaded.model, "gemma3:27b")
    }
}

// MARK: - Hotkey recording

final class HotkeyConfigTests: XCTestCase {
    func testMakeBuildsCarbonModifiersAndGlyphLabel() {
        let hk = HotkeyConfig.make(keyCode: 15, control: false, option: true, shift: false, command: true, keyName: "R")
        XCTAssertEqual(hk?.keyCode, 15)
        XCTAssertEqual(hk?.modifiers, HotkeyConfig.optionKey | HotkeyConfig.cmdKey)  // 2304
        XCTAssertEqual(hk?.label, "⌥⌘R")
        XCTAssertEqual(hk, HotkeyConfig.default)
    }

    func testMakeUsesCanonicalModifierOrder() {
        let hk = HotkeyConfig.make(keyCode: 49, control: true, option: true, shift: true, command: true, keyName: "␣")
        XCTAssertEqual(hk?.label, "⌃⌥⇧⌘␣")
        XCTAssertEqual(hk?.modifiers,
                       HotkeyConfig.controlKey | HotkeyConfig.optionKey | HotkeyConfig.shiftKey | HotkeyConfig.cmdKey)
    }

    func testMakeRejectsNoModifierOrShiftOnly() {
        XCTAssertNil(HotkeyConfig.make(keyCode: 15, control: false, option: false, shift: false, command: false, keyName: "R"))
        XCTAssertNil(HotkeyConfig.make(keyCode: 15, control: false, option: false, shift: true, command: false, keyName: "R"))
    }
}

// MARK: - Pipeline (capture → rewrite → present) with test doubles

/// A rewriter that always throws, for the failure path.
private struct FailingRewriter: Rewriting {
    struct Boom: Error {}
    func rewrite(_ text: String, onEvent: @escaping @Sendable (RewriteEvent) -> Void) async throws -> String {
        throw Boom()
    }
}

@MainActor
final class PipelineTests: XCTestCase {
    func testHappyPathStreamsInOrderAndFinishes() async {
        let presenter = CapturePresenter()
        let pipeline = RewritePipeline(
            capture: FixedTextCapture("hello    world"),
            rewriter: StubRewriter.capitalizing,
            presenter: presenter
        )
        await pipeline.runAndWait()
        XCTAssertEqual(presenter.original, "hello    world")
        XCTAssertEqual(presenter.finished, "Hello world")
        // The concatenation of streamed deltas equals the final text (ordering preserved).
        XCTAssertEqual(presenter.streamed, "Hello world")
        XCTAssertNil(presenter.error)
    }

    func testNoSelectionShortCircuits() async {
        let presenter = CapturePresenter()
        let pipeline = RewritePipeline(
            capture: FixedTextCapture(nil),
            rewriter: StubRewriter.capitalizing,
            presenter: presenter
        )
        await pipeline.runAndWait()
        XCTAssertEqual(presenter.noSelectionCount, 1)
        XCTAssertNil(presenter.finished)
        XCTAssertNil(presenter.original)
    }

    func testThinkingIsForwarded() async {
        let presenter = CapturePresenter()
        let rewriter = StubRewriter(emitThinking: true) { $0 }
        let pipeline = RewritePipeline(
            capture: FixedTextCapture("keep me"),
            rewriter: rewriter,
            presenter: presenter
        )
        await pipeline.runAndWait()
        XCTAssertGreaterThanOrEqual(presenter.thinkingCount, 1)
        XCTAssertEqual(presenter.finished, "keep me")
    }

    func testErrorIsReported() async {
        let presenter = CapturePresenter()
        let pipeline = RewritePipeline(
            capture: FixedTextCapture("boom"),
            rewriter: FailingRewriter(),
            presenter: presenter
        )
        await pipeline.runAndWait()
        XCTAssertNotNil(presenter.error)
        XCTAssertNil(presenter.finished)
    }
}

// MARK: - Pasteboard save/restore (uses a private named pasteboard, not the user's)

#if canImport(AppKit)
final class PasteboardTests: XCTestCase {
    func testSnapshotRestoreRoundTrip() {
        let pb = NSPasteboard(name: NSPasteboard.Name("prose.test.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let snapshot = Pasteboard.snapshot(pb)
        pb.clearContents()
        pb.setString("CLOBBERED", forType: .string)
        XCTAssertEqual(pb.string(forType: .string), "CLOBBERED")

        Pasteboard.restore(snapshot, to: pb)
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
        pb.releaseGlobally()
    }
}
#endif

// MARK: - Claude CLI result envelope (stdout is not the rewrite; the envelope is)

final class ClaudeSubscriptionRewriterTests: XCTestCase {
    private let envelope = #"{"type":"result","subtype":"success","is_error":false,"result":"Shorter.","session_id":"x"}"#

    func testCleanEnvelope() throws {
        XCTAssertEqual(try ClaudeSubscriptionRewriter.extractResult(stdout: envelope + "\n", stderr: "", exitCode: 0),
                       "Shorter.")
    }

    func testChatterAroundEnvelopeIsIgnored() throws {
        // The exact leak seen in the panel: MCP client warnings sharing stdout with the result.
        let noise = "Client.listTools() called but server does not advertise tools capability - returning empty list\n"
        let stdout = noise + envelope + "\n" + noise
        XCTAssertEqual(try ClaudeSubscriptionRewriter.extractResult(stdout: stdout, stderr: "", exitCode: 0),
                       "Shorter.")
    }

    func testEnvelopeWinsOverFailingExitCode() throws {
        // A failing SessionEnd hook exits non-zero after the rewrite already succeeded.
        XCTAssertEqual(try ClaudeSubscriptionRewriter.extractResult(
            stdout: envelope, stderr: "SessionEnd hook failed: node: command not found", exitCode: 1),
                       "Shorter.")
    }

    func testIsErrorSurfacesMessageEvenWithZeroExit() {
        let err = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
        XCTAssertThrowsError(try ClaudeSubscriptionRewriter.extractResult(stdout: err, stderr: "", exitCode: 0)) {
            XCTAssertEqual($0 as? RewriteError, .api("claude CLI: Not logged in · Please run /login"))
        }
    }

    func testNoEnvelopeFallsBackToStderrAndExitCode() {
        XCTAssertThrowsError(try ClaudeSubscriptionRewriter.extractResult(stdout: "", stderr: "boom", exitCode: 2)) {
            XCTAssertEqual($0 as? RewriteError, .api("claude CLI failed (exit 2): boom"))
        }
        XCTAssertThrowsError(try ClaudeSubscriptionRewriter.extractResult(stdout: "garbage", stderr: "", exitCode: 0))
    }

    func testEmptyResultIsEmptyResponse() {
        let empty = #"{"type":"result","is_error":false,"result":"  "}"#
        XCTAssertThrowsError(try ClaudeSubscriptionRewriter.extractResult(stdout: empty, stderr: "", exitCode: 0)) {
            XCTAssertEqual($0 as? RewriteError, .emptyResponse)
        }
    }

    func testIsolationArgsKeepTheCLIQuiet() {
        // Each flag closes a real failure (see the doc comment on isolationArgs).
        let args = ClaudeSubscriptionRewriter.isolationArgs
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(args.contains("--no-session-persistence"))
        for (flag, value) in [("--output-format", "json"), ("--tools", ""), ("--setting-sources", "")] {
            let i = try! XCTUnwrap(args.firstIndex(of: flag))
            XCTAssertEqual(args[i + 1], value, flag)
        }
        XCTAssertFalse(args.contains("--bare"), "--bare skips the keychain → subscription login is lost")
    }
}

// MARK: - Codex CLI result extraction (the -o file is the rewrite; stdout/stderr are not)

final class CodexSubscriptionRewriterTests: XCTestCase {
    func testLastMessageFileWins() throws {
        XCTAssertEqual(try CodexSubscriptionRewriter.extractResult(
            lastMessage: "Shorter.\n", stdout: "banner noise", stderr: "hook: SessionStart", exitCode: 0), "Shorter.")
        // A late failure after the message was written still yields the text.
        XCTAssertEqual(try CodexSubscriptionRewriter.extractResult(
            lastMessage: "Shorter.", stdout: "", stderr: "ERROR: hook failed", exitCode: 1), "Shorter.")
    }

    func testStdoutFallbackOnlyOnCleanExit() throws {
        XCTAssertEqual(try CodexSubscriptionRewriter.extractResult(
            lastMessage: nil, stdout: "Shorter.\n", stderr: "", exitCode: 0), "Shorter.")
        XCTAssertThrowsError(try CodexSubscriptionRewriter.extractResult(
            lastMessage: nil, stdout: "", stderr: "", exitCode: 0)) {
            XCTAssertEqual($0 as? RewriteError, .emptyResponse)
        }
    }

    func testApiErrorJSONIsSurfaced() {
        // Exact shape seen for an unsupported model on a ChatGPT account.
        let stderr = """
        OpenAI Codex v0.151.0
        ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'bogus' model is not supported when using Codex with a ChatGPT account."}}
        """
        XCTAssertThrowsError(try CodexSubscriptionRewriter.extractResult(
            lastMessage: nil, stdout: "", stderr: stderr, exitCode: 1)) {
            XCTAssertEqual($0 as? RewriteError,
                           .api("codex CLI failed (exit 1): The 'bogus' model is not supported when using Codex with a ChatGPT account."))
        }
    }

    func testPlainStderrFallsBackToLastLine() {
        XCTAssertEqual(CodexSubscriptionRewriter.errorMessage(fromStderr: "first\nnot logged in\n\n"), "not logged in")
        XCTAssertEqual(CodexSubscriptionRewriter.errorMessage(fromStderr: ""), "no output")
    }

    func testIsolationArgsKeepTheCLIQuiet() {
        let args = CodexSubscriptionRewriter.isolationArgs
        for flag in ["--ignore-user-config", "--ephemeral", "--skip-git-repo-check"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
        for (flag, value) in [("--sandbox", "read-only"), ("--color", "never"), ("-c", "model_reasoning_effort=low")] {
            let i = try! XCTUnwrap(args.firstIndex(of: flag))
            XCTAssertEqual(args[i + 1], value, flag)
        }
        XCTAssertFalse(args.contains { $0.hasPrefix("--dangerously") })
    }
}

// MARK: - CLI environment (what a GUI app's bare PATH can't see)

final class CLIEnvironmentTests: XCTestCase {
    private func makeFakeHome(alias: String?) throws -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("prose-home-\(UUID().uuidString)").path
        for v in ["v20.18.1", "v25.2.1"] {
            try FileManager.default.createDirectory(
                atPath: "\(home)/.nvm/versions/node/\(v)/bin", withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(atPath: "\(home)/.local/bin", withIntermediateDirectories: true)
        if let alias {
            try FileManager.default.createDirectory(atPath: "\(home)/.nvm/alias", withIntermediateDirectories: true)
            try alias.write(toFile: "\(home)/.nvm/alias/default", atomically: true, encoding: .utf8)
        }
        return home
    }

    func testNvmDefaultAliasComesFirstThenNewest() throws {
        let home = try makeFakeHome(alias: "20\n")
        XCTAssertEqual(CLIEnvironment.nvmBinDirs(home: home),
                       ["\(home)/.nvm/versions/node/v20.18.1/bin", "\(home)/.nvm/versions/node/v25.2.1/bin"])
        let noAlias = try makeFakeHome(alias: nil)
        XCTAssertEqual(CLIEnvironment.nvmBinDirs(home: noAlias).first, "\(noAlias)/.nvm/versions/node/v25.2.1/bin")
    }

    func testExtraToolDirsOnlyListsExistingOnes() throws {
        let home = try makeFakeHome(alias: nil)
        let dirs = CLIEnvironment.extraToolDirs(home: home)
        XCTAssertTrue(dirs.contains("\(home)/.local/bin"))
        XCTAssertFalse(dirs.contains("\(home)/.volta/bin"))
        XCTAssertEqual(dirs.filter { $0.contains("/.nvm/") }.count, 2)
    }

    func testToolsOwnDirectoryLeadsThePath() {
        XCTAssertEqual(CLIEnvironment.pathPrepending("/x/nvm/v20/bin/codex", to: "/usr/bin:/x/nvm/v20/bin:/bin"),
                       "/x/nvm/v20/bin:/usr/bin:/bin")
    }

    func testResolveFindsSystemTools() async {
        let sh = await CLIEnvironment.resolve("sh")
        XCTAssertEqual(sh, "/bin/sh")
        let missing = await CLIEnvironment.resolve("definitely-not-a-tool-\(UUID().uuidString)", fallbacks: ["/bin/ls"])
        XCTAssertEqual(missing, "/bin/ls")
    }
}

final class SubprocessTests: XCTestCase {
    func testWatchdogTerminatesAHungProcess() async {
        do {
            _ = try await Subprocess.run("/bin/sleep", ["30"], timeout: 0.3)
            XCTFail("expected a timeout")
        } catch let t as Subprocess.TimedOut {
            XCTAssertEqual(t.seconds, 0.3)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDrainsBothPipesAndReportsExitCode() async throws {
        let r = try await Subprocess.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 5)
        XCTAssertEqual(r.stdout, "out\n")
        XCTAssertEqual(r.stderr, "err\n")
        XCTAssertEqual(r.code, 3)
    }
}
