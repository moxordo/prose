import XCTest
@testable import ProseKit

/// Live integration test against a real Ollama backend. Skipped unless
/// `PROSE_LIVE_OLLAMA=1` so the default `swift test` needs no network.
///
///   Local:  PROSE_LIVE_OLLAMA=1 PROSE_OLLAMA_URL=http://localhost:11434 PROSE_MODEL=llama3.2:3b swift test
///   Cloud:  PROSE_LIVE_OLLAMA=1 PROSE_OLLAMA_URL=https://ollama.com PROSE_MODEL=gemma3:27b PROSE_OLLAMA_KEY=… swift test
@MainActor
final class LiveOllamaTests: XCTestCase {
    func testRealRewriteProducesNonEmptyChangedText() async throws {
        guard ProcessInfo.processInfo.environment["PROSE_LIVE_OLLAMA"] == "1" else {
            throw XCTSkip("set PROSE_LIVE_OLLAMA=1 (and PROSE_OLLAMA_URL/PROSE_MODEL[/PROSE_OLLAMA_KEY]) to run")
        }
        let config = ConfigLoader.load()
        let rewriter = OllamaRewriter(config: config)

        let input = "i has real bad grammar here and it dont read good at all"
        let output = try await rewriter.rewrite(input)

        XCTAssertFalse(output.isEmpty, "expected a non-empty rewrite")
        XCTAssertNotEqual(
            output.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            input.lowercased(),
            "expected the rewrite to differ from the input"
        )
    }

    func testStreamingDeltasReconstructFullText() async throws {
        guard ProcessInfo.processInfo.environment["PROSE_LIVE_OLLAMA"] == "1" else {
            throw XCTSkip("set PROSE_LIVE_OLLAMA=1 to run")
        }
        let config = ConfigLoader.load()
        let rewriter = OllamaRewriter(config: config)

        // Collect deltas through the pipeline + CapturePresenter, which run on
        // the main actor in order — so `streamed` must equal `finished`.
        let presenter = CapturePresenter()
        let pipeline = RewritePipeline(
            capture: FixedTextCapture("make this sentence clearer please and thank you"),
            rewriter: rewriter,
            presenter: presenter
        )
        await pipeline.runAndWait()

        XCTAssertNil(presenter.error)
        XCTAssertNotNil(presenter.finished)
        XCTAssertEqual(presenter.streamed, presenter.finished)
    }
}
