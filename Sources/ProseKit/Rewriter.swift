import Foundation

/// A streamed event from a rewrite.
public enum RewriteEvent: Sendable, Equatable {
    /// Reasoning tokens (e.g. gpt-oss). NOT part of the final rewrite — drives a
    /// "thinking…" UI state only.
    case thinking(String)
    /// A chunk of the actual rewritten text. Append these to build the result.
    case content(String)
}

public enum RewriteError: LocalizedError, Equatable {
    case badURL(String)
    case http(status: Int, message: String)
    case api(String)
    case emptyResponse
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .badURL(let u): return "Invalid Ollama base URL: \(u)"
        case .http(let s, let m):
            return "Ollama returned HTTP \(s)\(m.isEmpty ? "" : ": \(m)")"
        case .api(let m): return "Ollama error: \(m)"
        case .emptyResponse: return "The model returned an empty rewrite."
        case .emptyInput: return "No text was selected."
        }
    }
}

/// Turns a piece of text into an improved rewrite.
public protocol Rewriting: Sendable {
    /// Streams the rewrite. `onEvent` may be invoked on any thread/task; UI
    /// callers must hop to the main actor themselves. Returns the full rewrite.
    func rewrite(
        _ text: String,
        onEvent: @escaping @Sendable (RewriteEvent) -> Void
    ) async throws -> String
}

public extension Rewriting {
    /// Convenience: rewrite without observing the stream.
    func rewrite(_ text: String) async throws -> String {
        try await rewrite(text, onEvent: { _ in })
    }
}

// MARK: - Ollama wire types

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatOptions: Encodable {
    let temperature: Double
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let options: ChatOptions
}

/// Pure, side-effect-free parser for one NDJSON line of an Ollama `/api/chat`
/// stream. Factored out so the streaming logic is unit-testable without a socket.
public enum OllamaStreamParser {
    public enum Parsed: Equatable {
        /// One streamed chunk. `thinking`/`content` are independently optional
        /// because reasoning models emit `thinking` with empty `content`.
        case chunk(thinking: String?, content: String?, done: Bool)
        case apiError(String)
    }

    public static func parse(line: String) -> Parsed? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? String { return .apiError(err) }
        let message = obj["message"] as? [String: Any]
        let content = message?["content"] as? String
        let thinking = message?["thinking"] as? String
        let done = (obj["done"] as? Bool) ?? false
        return .chunk(thinking: thinking, content: content, done: done)
    }
}

/// Backend-agnostic Ollama client. Works against a local server
/// (`http://localhost:11434`) or Ollama Cloud (`https://ollama.com` + bearer key)
/// with no code change — only `ProseConfig` differs.
public struct OllamaRewriter: Rewriting {
    public let config: ProseConfig
    private let session: URLSession

    public init(config: ProseConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func rewrite(
        _ text: String,
        onEvent: @escaping @Sendable (RewriteEvent) -> Void
    ) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RewriteError.emptyInput }
        guard let url = URL(string: config.normalizedBaseURL + "/api/chat") else {
            throw RewriteError.badURL(config.ollamaBaseURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body = ChatRequest(
            model: config.model,
            messages: [
                ChatMessage(role: "system", content: config.composedSystemPrompt),
                ChatMessage(role: "user", content: input),
            ],
            stream: true,
            options: ChatOptions(temperature: config.temperature)
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Drain a little of the error body for a useful message.
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count > 500 { break }
            }
            throw RewriteError.http(status: http.statusCode, message: detail)
        }

        var result = ""
        streamLoop: for try await line in bytes.lines {
            guard let parsed = OllamaStreamParser.parse(line: line) else { continue }
            switch parsed {
            case .apiError(let message):
                throw RewriteError.api(message)
            case .chunk(let thinking, let content, let done):
                if let t = thinking, !t.isEmpty { onEvent(.thinking(t)) }
                if let c = content, !c.isEmpty {
                    result += c
                    onEvent(.content(c))
                }
                if done { break streamLoop }
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RewriteError.emptyResponse }
        return trimmed
    }
}

/// Deterministic test double — no network. Emits the configured output in a few
/// chunks so streaming consumers are exercised.
public struct StubRewriter: Rewriting {
    public let transform: @Sendable (String) -> String
    public let emitThinking: Bool

    public init(emitThinking: Bool = false, transform: @escaping @Sendable (String) -> String) {
        self.transform = transform
        self.emitThinking = emitThinking
    }

    /// Default: uppercase-first, collapse whitespace — a visible, deterministic change.
    public static let capitalizing = StubRewriter { input in
        let collapsed = input.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.prefix(1).uppercased() + collapsed.dropFirst()
    }

    public func rewrite(
        _ text: String,
        onEvent: @escaping @Sendable (RewriteEvent) -> Void
    ) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RewriteError.emptyInput }
        if emitThinking { onEvent(.thinking("considering…")) }
        let output = transform(input)
        // Emit in word chunks to simulate streaming.
        var emitted = ""
        for word in output.split(separator: " ", omittingEmptySubsequences: false) {
            let chunk = (emitted.isEmpty ? "" : " ") + word
            emitted += chunk
            onEvent(.content(chunk))
        }
        return output
    }
}
