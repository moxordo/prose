import Foundation

/// Wires the four stages together: trigger → capture → rewrite → present.
///
/// The network call runs off the main actor (in a detached task) while rewrite
/// events flow back through an `AsyncStream`, which the main actor drains in FIFO
/// order — so streamed deltas never arrive scrambled and the UI stays responsive.
@MainActor
public final class RewritePipeline {
    public let capture: SelectionCapturing
    public let rewriter: Rewriting
    public let presenter: ResultPresenting

    private var isRunning = false

    public init(capture: SelectionCapturing, rewriter: Rewriting, presenter: ResultPresenting) {
        self.capture = capture
        self.rewriter = rewriter
        self.presenter = presenter
    }

    /// Fire-and-forget entry point for triggers.
    public func run() {
        Task { await runAndWait() }
    }

    /// Awaitable entry point — used by triggers (indirectly) and by tests.
    /// Re-entrancy guarded: a second trigger while one is in flight is ignored.
    public func runAndWait() async {
        guard !isRunning else { Log.write("pipeline: ignored (already running)"); return }
        isRunning = true
        defer { isRunning = false }

        Log.write("pipeline: triggered — capturing selection…")
        guard let selection = await capture.capturedSelection(),
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.write("pipeline: no selection captured → noSelection()")
            presenter.noSelection()
            return
        }

        Log.write("pipeline: captured \(selection.count) chars; rewriting…")
        presenter.begin(original: selection)

        let rewriter = self.rewriter
        let (stream, continuation) = AsyncStream<RewriteEvent>.makeStream()
        let work = Task.detached { () -> Result<String, Error> in
            do {
                let full = try await rewriter.rewrite(selection) { event in
                    continuation.yield(event)
                }
                continuation.finish()
                return .success(full)
            } catch {
                continuation.finish()
                return .failure(error)
            }
        }

        for await event in stream {
            switch event {
            case .thinking:
                presenter.thinking()
            case .content(let delta):
                presenter.append(delta)
            }
        }

        switch await work.value {
        case .success(let full):
            Log.write("pipeline: rewrite ok (\(full.count) chars)")
            presenter.finish(full: full)
        case .failure(let error):
            Log.write("pipeline: rewrite FAILED — \(error.localizedDescription)")
            presenter.fail(error)
        }
    }
}
