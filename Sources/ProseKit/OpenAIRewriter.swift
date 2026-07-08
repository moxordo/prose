import Foundation

/// Pure parser for one SSE `data:` payload from the OpenAI Chat Completions API
/// (`POST /v1/chat/completions`, `stream:true`).
public enum OpenAIStreamParser {
    public enum Parsed: Equatable {
        case text(String)
        case done            // "[DONE]" sentinel
        case apiError(String)
    }

    /// `line` is the JSON (or `[DONE]`) after the `data:` prefix is stripped.
    public static func parse(dataJSON line: String) -> Parsed? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "[DONE]" { return .done }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let err = obj["error"] as? [String: Any] {
            return .apiError(err["message"] as? String ?? "unknown error")
        }
        let choices = obj["choices"] as? [[String: Any]]
        let delta = choices?.first?["delta"] as? [String: Any]
        if let content = delta?["content"] as? String, !content.isEmpty {
            return .text(content)
        }
        return nil
    }
}

/// OpenAI / ChatGPT via `OPENAI_API_KEY`. Raw HTTP, SSE streaming. Temperature is
/// omitted (some models reject non-default values); model is user-configurable.
public struct OpenAIRewriter: Rewriting {
    public let config: ProseConfig
    private let session: URLSession
    private let endpoint = "https://api.openai.com/v1/chat/completions"

    public init(config: ProseConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private struct Msg: Encodable { let role: String; let content: String }
    private struct Body: Encodable {
        let model: String
        let messages: [Msg]
        let stream: Bool
    }

    public func rewrite(
        _ text: String,
        onEvent: @escaping @Sendable (RewriteEvent) -> Void
    ) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RewriteError.emptyInput }
        guard let key = config.apiKey, !key.isEmpty else { throw ProviderError.missingKey("OpenAI") }

        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = config.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(Body(
            model: config.model,
            messages: [
                Msg(role: "system", content: config.composedSystemPrompt),
                Msg(role: "user", content: input),
            ],
            stream: true
        ))

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var detail = ""
            for try await line in bytes.lines { detail += line; if detail.count > 500 { break } }
            throw RewriteError.http(status: http.statusCode, message: detail)
        }

        var result = ""
        streamLoop: for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = String(line.dropFirst("data:".count))
            guard let parsed = OpenAIStreamParser.parse(dataJSON: json) else { continue }
            switch parsed {
            case .text(let t): result += t; onEvent(.content(t))
            case .apiError(let m): throw RewriteError.api(m)
            case .done: break streamLoop
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RewriteError.emptyResponse }
        return trimmed
    }
}
