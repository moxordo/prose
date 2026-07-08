import Foundation

/// Presents the lifecycle of a rewrite to the user. All calls are on the main actor.
@MainActor
public protocol ResultPresenting: AnyObject {
    /// A trigger fired but nothing usable was selected.
    func noSelection()
    /// Capture succeeded; a rewrite is starting for `original`.
    func begin(original: String)
    /// The model is reasoning (reasoning models only) before producing content.
    func thinking()
    /// A chunk of rewritten text arrived.
    func append(_ delta: String)
    /// The rewrite finished; `full` is the complete text.
    func finish(full: String)
    /// The rewrite failed.
    func fail(_ error: Error)
}

/// Records every callback for assertions in tests.
@MainActor
public final class CapturePresenter: ResultPresenting {
    public private(set) var noSelectionCount = 0
    public private(set) var original: String?
    public private(set) var thinkingCount = 0
    public private(set) var deltas: [String] = []
    public private(set) var finished: String?
    public private(set) var error: Error?

    public init() {}

    public var streamed: String { deltas.joined() }

    public func noSelection() { noSelectionCount += 1 }
    public func begin(original: String) { self.original = original }
    public func thinking() { thinkingCount += 1 }
    public func append(_ delta: String) { deltas.append(delta) }
    public func finish(full: String) { finished = full }
    public func fail(_ error: Error) { self.error = error }
}

/// Streams to stdout — the presenter used by `prose selftest`.
@MainActor
public final class StdoutPresenter: ResultPresenting {
    private let showOriginal: Bool
    /// True if the rewrite failed or nothing was selected — for CLI exit codes.
    public private(set) var failed = false
    public init(showOriginal: Bool = true) { self.showOriginal = showOriginal }

    // Write everything through the same unbuffered handles so the streamed
    // deltas never race ahead of the headers (mixing print() with FileHandle
    // writes interleaves incorrectly because stdio is line-buffered).
    private func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
    private func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

    public func noSelection() {
        failed = true
        err("prose: nothing selected\n")
    }
    public func begin(original: String) {
        if showOriginal {
            out("── original ──\n\(original)\n── rewrite ──\n")
        }
    }
    public func thinking() {
        err(".")
    }
    public func append(_ delta: String) {
        out(delta)
    }
    public func finish(full: String) {
        out("\n")  // trailing newline after the stream
    }
    public func fail(_ error: Error) {
        failed = true
        err("\nprose error: \(error.localizedDescription)\n")
    }
}
