import Foundation

/// Pure parser for one SSE `data:` payload from the Anthropic Messages API
/// (`POST /v1/messages`, `stream:true`). Factored out for unit testing.
public enum AnthropicStreamParser {
    public enum Parsed: Equatable {
        case text(String)      // content_block_delta / text_delta
        case thinking(String)  // content_block_delta / thinking_delta
        case done              // message_stop
        case refusal           // stop_reason == "refusal"
        case apiError(String)
    }

    /// `line` is the JSON after the `data:` prefix has been stripped.
    public static func parse(dataJSON line: String) -> Parsed? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[DONE]",
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch obj["type"] as? String {
        case "content_block_delta":
            let delta = obj["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta": return (delta?["text"] as? String).map(Parsed.text)
            case "thinking_delta": return (delta?["thinking"] as? String).map(Parsed.thinking)
            default: return nil
            }
        case "message_delta":
            let delta = obj["delta"] as? [String: Any]
            if (delta?["stop_reason"] as? String) == "refusal" { return .refusal }
            return nil
        case "message_stop":
            return .done
        case "error":
            let message = (obj["error"] as? [String: Any])?["message"] as? String
            return .apiError(message ?? "unknown error")
        default:
            return nil
        }
    }
}

/// Claude via a first-party `ANTHROPIC_API_KEY`. Raw HTTP (there is no official
/// Anthropic Swift SDK). Per the Messages API: `x-api-key` + `anthropic-version`,
/// no `temperature` (rejected on Opus 4.8 / Sonnet 5), `thinking` omitted so a
/// short rewrite runs without reasoning latency.
public struct AnthropicRewriter: Rewriting {
    public let config: ProseConfig
    private let session: URLSession
    private let endpoint = "https://api.anthropic.com/v1/messages"

    public init(config: ProseConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private struct Msg: Encodable { let role: String; let content: String }
    private struct Body: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Msg]
        let stream: Bool
    }

    public func rewrite(
        _ text: String,
        onEvent: @escaping @Sendable (RewriteEvent) -> Void
    ) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RewriteError.emptyInput }
        guard let key = config.apiKey, !key.isEmpty else { throw ProviderError.missingKey("Claude (API key)") }

        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = config.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONEncoder().encode(Body(
            model: config.model,
            max_tokens: 2048,
            system: config.composedSystemPrompt,
            messages: [Msg(role: "user", content: input)],
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
            guard let parsed = AnthropicStreamParser.parse(dataJSON: json) else { continue }
            switch parsed {
            case .text(let t): result += t; onEvent(.content(t))
            case .thinking(let t): onEvent(.thinking(t))
            case .refusal: throw RewriteError.api("Claude declined this request (refusal).")
            case .apiError(let m): throw RewriteError.api(m)
            case .done: break streamLoop
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RewriteError.emptyResponse }
        return trimmed
    }
}
