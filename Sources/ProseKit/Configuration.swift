import Foundation

/// User-facing configuration for Prose.
///
/// Resolution precedence (lowest → highest):
///   built-in defaults  <  ~/.config/prose/config.json  <  environment variables
///
/// The Ollama client is intentionally backend-agnostic: point `ollamaBaseURL`
/// at `http://localhost:11434` for a local model, or `https://ollama.com` (plus
/// `apiKey`) for the hosted Ollama Cloud / Turbo subscription. The wire protocol
/// (`POST /api/chat`, NDJSON stream) is identical for both.
public struct ProseConfig: Codable, Sendable, Equatable {
    public var ollamaBaseURL: String
    public var model: String
    /// Optional bearer token. Required only for Ollama Cloud (ollama.com).
    public var apiKey: String?
    public var temperature: Double
    public var systemPrompt: String
    public var requestTimeout: Double
    public var hotkey: HotkeyConfig
    /// When true the force-click (pressure stage 2) global trigger is armed.
    public var forceClickEnabled: Bool

    public init(
        ollamaBaseURL: String = "http://localhost:11434",
        model: String = "llama3.2:3b",
        apiKey: String? = nil,
        temperature: Double = 0.3,
        systemPrompt: String = ProseConfig.defaultSystemPrompt,
        requestTimeout: Double = 60,
        hotkey: HotkeyConfig = .default,
        forceClickEnabled: Bool = true
    ) {
        self.ollamaBaseURL = ollamaBaseURL
        self.model = model
        self.apiKey = apiKey
        self.temperature = temperature
        self.systemPrompt = systemPrompt
        self.requestTimeout = requestTimeout
        self.hotkey = hotkey
        self.forceClickEnabled = forceClickEnabled
    }

    public static let `default` = ProseConfig()

    private enum CodingKeys: String, CodingKey {
        case ollamaBaseURL, model, apiKey, temperature, systemPrompt, requestTimeout, hotkey, forceClickEnabled
    }

    /// Lenient decoding: every field is optional in JSON and falls back to the
    /// built-in default, so a `config.json` can specify just `ollamaBaseURL` and
    /// `model` without tripping the decoder.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProseConfig.default
        self.ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? d.ollamaBaseURL
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
        self.requestTimeout = try c.decodeIfPresent(Double.self, forKey: .requestTimeout) ?? d.requestTimeout
        self.hotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey) ?? d.hotkey
        self.forceClickEnabled = try c.decodeIfPresent(Bool.self, forKey: .forceClickEnabled) ?? d.forceClickEnabled
    }

    /// The editing instruction. Deliberately strict about returning ONLY the
    /// rewrite, so the panel never shows "Sure, here's an improved version:".
    public static let defaultSystemPrompt = """
        You are a precise copy editor. Rewrite the user's text to improve clarity, \
        flow, and concision while preserving the original meaning, tone, and intent. \
        Keep it roughly the same length unless brevity clearly helps. Do not add new \
        facts. Preserve any code, file paths, URLs, @mentions, and inline formatting \
        verbatim. Respond with ONLY the rewritten text — no preamble, no quotation \
        marks, no commentary.
        """

    /// Normalized base URL without a trailing slash.
    public var normalizedBaseURL: String {
        var s = ollamaBaseURL
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// A global hotkey described by a Carbon virtual key code + modifier mask.
/// Default: ⌥⌘R (Option-Command-R).
public struct HotkeyConfig: Codable, Sendable, Equatable {
    /// Carbon `kVK_*` virtual key code. `kVK_ANSI_R` == 15.
    public var keyCode: UInt32
    /// Carbon modifier flags: cmdKey(256) | optionKey(2048) | shiftKey(512) | controlKey(4096).
    public var modifiers: UInt32
    /// Human label for menus/logs, e.g. "⌥⌘R".
    public var label: String

    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    // cmdKey (0x0100) | optionKey (0x0800) = 0x0900 = 2304 ; kVK_ANSI_R = 15
    public static let `default` = HotkeyConfig(keyCode: 15, modifiers: 2304, label: "⌥⌘R")
}

public enum ConfigLoader {
    public static var defaultPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("prose", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Load config applying the documented precedence. Never throws — a missing
    /// or malformed file falls back to defaults so the app always starts.
    public static func load(
        path: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProseConfig {
        var config = ProseConfig.default
        let url = path ?? defaultPath
        if let data = try? Data(contentsOf: url),
           let fileConfig = try? JSONDecoder().decode(ProseConfig.self, from: data) {
            config = fileConfig
        }
        applyEnvironment(environment, to: &config)
        // API key resolution precedence: env / file value (already applied) > Keychain.
        // Keychain is the secure home for the Ollama Cloud key; it never lands in
        // config.json. Only consult it when nothing more specific was provided.
        if (config.apiKey?.isEmpty ?? true) {
            config.apiKey = Keychain.read()
        }
        return config
    }

    /// Exposed for testing.
    public static func applyEnvironment(_ env: [String: String], to config: inout ProseConfig) {
        if let v = env["PROSE_OLLAMA_URL"], !v.isEmpty { config.ollamaBaseURL = v }
        if let v = env["PROSE_OLLAMA_MODEL"] ?? env["PROSE_MODEL"], !v.isEmpty { config.model = v }
        if let v = env["PROSE_OLLAMA_KEY"] ?? env["OLLAMA_API_KEY"], !v.isEmpty { config.apiKey = v }
        if let v = env["PROSE_TEMPERATURE"], let d = Double(v) { config.temperature = d }
        if let v = env["PROSE_TIMEOUT"], let d = Double(v) { config.requestTimeout = d }
        if let v = env["PROSE_SYSTEM_PROMPT"], !v.isEmpty { config.systemPrompt = v }
    }
}
