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

// MARK: - Configuration

final class ConfigurationTests: XCTestCase {
    func testEnvironmentPrecedence() {
        var config = ProseConfig.default
        ConfigLoader.applyEnvironment([
            "PROSE_OLLAMA_URL": "https://ollama.com",
            "PROSE_MODEL": "gemma3:27b",
            "PROSE_OLLAMA_KEY": "secret",
            "PROSE_TEMPERATURE": "0.7",
        ], to: &config)
        XCTAssertEqual(config.ollamaBaseURL, "https://ollama.com")
        XCTAssertEqual(config.model, "gemma3:27b")
        XCTAssertEqual(config.apiKey, "secret")
        XCTAssertEqual(config.temperature, 0.7, accuracy: 0.0001)
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
