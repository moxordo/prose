import Foundation

/// Which LLM backend produces the rewrite. Each provider resolves its API key
/// from its own Keychain service + env vars, and has its own default model.
public enum LLMProvider: String, Codable, Sendable, CaseIterable {
    case claudeSubscription = "claude-subscription"  // via the logged-in `claude` CLI (agent SDK / OAuth)
    case anthropicAPI = "anthropic"                  // via ANTHROPIC_API_KEY
    case ollama                                      // local or ollama.com (key)
    case openai                                      // ChatGPT / OpenAI

    public var displayName: String {
        switch self {
        case .claudeSubscription: return "Claude (subscription · CLI)"
        case .anthropicAPI: return "Claude (API key)"
        case .ollama: return "Ollama (local / cloud)"
        case .openai: return "OpenAI / ChatGPT"
        }
    }

    public var defaultModel: String {
        switch self {
        case .claudeSubscription: return "sonnet"       // `claude --model` alias; "" also works
        case .anthropicAPI: return "claude-opus-4-8"
        case .ollama: return "gemma3:27b"
        case .openai: return "gpt-4o"
        }
    }

    /// Keychain service holding this provider's key, or nil if it needs no key.
    public var keychainService: String? {
        switch self {
        case .claudeSubscription: return nil
        case .anthropicAPI: return "prose-anthropic-api-key"
        case .ollama: return "prose-ollama-api-key"
        case .openai: return "prose-openai-api-key"
        }
    }

    /// Env vars consulted (in order) for this provider's key.
    public var envVarNames: [String] {
        switch self {
        case .claudeSubscription: return []
        case .anthropicAPI: return ["PROSE_ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]
        case .ollama: return ["PROSE_OLLAMA_KEY", "OLLAMA_API_KEY"]
        case .openai: return ["PROSE_OPENAI_KEY", "OPENAI_API_KEY"]
        }
    }

    public var needsKey: Bool { keychainService != nil }
}

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
    /// Which LLM backend to use.
    public var provider: LLMProvider
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
    /// Hard constraints the model MUST follow (injected into the system prompt).
    public var rules: [String]
    /// Soft stylistic preferences applied when they improve the text.
    public var preferences: [String]

    public init(
        provider: LLMProvider = .ollama,
        ollamaBaseURL: String = "http://localhost:11434",
        model: String = "llama3.2:3b",
        apiKey: String? = nil,
        temperature: Double = 0.3,
        systemPrompt: String = ProseConfig.defaultSystemPrompt,
        requestTimeout: Double = 60,
        hotkey: HotkeyConfig = .default,
        forceClickEnabled: Bool = true,
        rules: [String] = ProseConfig.defaultRules,
        preferences: [String] = ProseConfig.defaultPreferences
    ) {
        self.provider = provider
        self.ollamaBaseURL = ollamaBaseURL
        self.model = model
        self.apiKey = apiKey
        self.temperature = temperature
        self.systemPrompt = systemPrompt
        self.requestTimeout = requestTimeout
        self.hotkey = hotkey
        self.forceClickEnabled = forceClickEnabled
        self.rules = rules
        self.preferences = preferences
    }

    public static let `default` = ProseConfig()

    /// Sensible starting rules/preferences (editable in Settings).
    public static let defaultRules = [
        "Keep the original language. If the text mixes languages, infer and adapt to the user's own style.",
    ]
    public static let defaultPreferences = [
        "Shorter is normally better.",
        "If a shorter expression or explanation is closer to the lingua franca of the domain, suggest it.",
        "Infer the context the text will appear in and fit that register.",
    ]

    private enum CodingKeys: String, CodingKey {
        case provider, ollamaBaseURL, model, apiKey, temperature, systemPrompt, requestTimeout, hotkey, forceClickEnabled, rules, preferences
    }

    /// Lenient decoding: every field is optional in JSON and falls back to the
    /// built-in default, so a `config.json` can specify just `ollamaBaseURL` and
    /// `model` without tripping the decoder.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProseConfig.default
        self.provider = try c.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? d.provider
        self.ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? d.ollamaBaseURL
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
        self.requestTimeout = try c.decodeIfPresent(Double.self, forKey: .requestTimeout) ?? d.requestTimeout
        self.hotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey) ?? d.hotkey
        self.forceClickEnabled = try c.decodeIfPresent(Bool.self, forKey: .forceClickEnabled) ?? d.forceClickEnabled
        self.rules = try c.decodeIfPresent([String].self, forKey: .rules) ?? d.rules
        self.preferences = try c.decodeIfPresent([String].self, forKey: .preferences) ?? d.preferences
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

    /// The full system prompt sent to the model: the base editing instruction
    /// plus the user's Rules (hard) and Preferences (soft).
    public var composedSystemPrompt: String {
        var parts = [systemPrompt]
        let cleanRules = rules.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cleanPrefs = preferences.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleanRules.isEmpty {
            parts.append("Follow these RULES strictly:\n" + cleanRules.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !cleanPrefs.isEmpty {
            parts.append("Apply these PREFERENCES when they improve the text:\n" + cleanPrefs.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
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
        // Resolve the active provider's API key. Precedence: file value (already
        // applied) > provider env vars > provider Keychain service. Keys never
        // land in config.json; the Keychain is their secure home.
        if config.apiKey?.isEmpty ?? true {
            for name in config.provider.envVarNames {
                if let v = environment[name], !v.isEmpty { config.apiKey = v; break }
            }
        }
        if (config.apiKey?.isEmpty ?? true), let service = config.provider.keychainService {
            config.apiKey = Keychain.read(service: service)
        }
        return config
    }

    /// Persist config to disk. The API key is deliberately stripped — it lives in
    /// the Keychain, never in plaintext config.json.
    @discardableResult
    public static func save(_ config: ProseConfig, to path: URL? = nil) -> Bool {
        var toWrite = config
        toWrite.apiKey = nil
        let url = path ?? defaultPath
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(toWrite).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Exposed for testing. Non-secret fields only; the API key is resolved
    /// per-provider in `load()`.
    public static func applyEnvironment(_ env: [String: String], to config: inout ProseConfig) {
        if let v = env["PROSE_PROVIDER"], let p = LLMProvider(rawValue: v) { config.provider = p }
        if let v = env["PROSE_OLLAMA_URL"], !v.isEmpty { config.ollamaBaseURL = v }
        if let v = env["PROSE_OLLAMA_MODEL"] ?? env["PROSE_MODEL"], !v.isEmpty { config.model = v }
        if let v = env["PROSE_TEMPERATURE"], let d = Double(v) { config.temperature = d }
        if let v = env["PROSE_TIMEOUT"], let d = Double(v) { config.requestTimeout = d }
        if let v = env["PROSE_SYSTEM_PROMPT"], !v.isEmpty { config.systemPrompt = v }
    }
}
