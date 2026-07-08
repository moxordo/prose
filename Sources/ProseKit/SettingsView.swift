#if canImport(AppKit)
import SwiftUI

/// Editor for how Prose rewrites text: hard Rules + soft Preferences (plus model
/// and creativity). One item per line. Saving persists to config.json (key stays
/// in the Keychain) and rebuilds the pipeline so changes apply to the next rewrite.
@MainActor
public struct SettingsView: View {
    static let customTag = "__custom__"

    @State private var provider: LLMProvider
    @State private var apiKey: String = ""
    @State private var rulesText: String
    @State private var preferencesText: String
    /// The selected preset (or `customTag`); `customModel` holds a typed id.
    @State private var modelChoice: String
    @State private var customModel: String
    @State private var temperature: Double

    private let baseConfig: ProseConfig
    private let onSave: (ProseConfig) -> Void
    private let onClose: () -> Void

    public init(
        config: ProseConfig,
        onSave: @escaping (ProseConfig) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.baseConfig = config
        _provider = State(initialValue: config.provider)
        _rulesText = State(initialValue: config.rules.joined(separator: "\n"))
        _preferencesText = State(initialValue: config.preferences.joined(separator: "\n"))
        if config.model.isEmpty {
            _modelChoice = State(initialValue: config.provider.defaultModel)
            _customModel = State(initialValue: "")
        } else if config.provider.modelPresets.contains(config.model) {
            _modelChoice = State(initialValue: config.model)
            _customModel = State(initialValue: "")
        } else {
            _modelChoice = State(initialValue: Self.customTag)
            _customModel = State(initialValue: config.model)
        }
        _temperature = State(initialValue: config.temperature)
        self.onSave = onSave
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prose Preferences").font(.headline)
                Text("Shape how your text gets rewritten. One item per line.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            providerSection

            Divider()

            section(
                "Rules",
                subtitle: "Hard constraints the model must always follow.",
                text: $rulesText
            )
            section(
                "Preferences",
                subtitle: "Soft guidance applied when it improves the text.",
                text: $preferencesText
            )

            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Picker("Model", selection: $modelChoice) {
                            ForEach(provider.modelPresets, id: \.self) { Text($0).tag($0) }
                            Text("Custom…").tag(Self.customTag)
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        if modelChoice == Self.customTag {
                            TextField("model id", text: $customModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Creativity: \(temperature, specifier: "%.2f")")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $temperature, in: 0...1).frame(width: 140)
                }
            }

            Divider()

            HStack {
                Button("Reset to Defaults", action: resetDefaults)
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    @ViewBuilder private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backend").font(.system(size: 13, weight: .semibold))
            Picker("Provider", selection: $provider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            .onChange(of: provider) { _, newValue in
                modelChoice = newValue.defaultModel
                customModel = ""
                apiKey = ""
            }

            if provider.needsKey {
                HStack(spacing: 8) {
                    SecureField(keyPlaceholder, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                    if keyAlreadyStored {
                        Text("stored ✓").font(.caption).foregroundStyle(.green)
                    }
                }
                Text("Stored in the Keychain, never in config.json. Leave blank to keep the current key.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Uses the signed-in `claude` CLI (your subscription) — no API key needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var keyPlaceholder: String {
        switch provider {
        case .anthropicAPI: return "Paste your ANTHROPIC_API_KEY"
        case .openai: return "Paste your OPENAI_API_KEY"
        case .ollama: return "Ollama Cloud key (blank for local)"
        case .claudeSubscription: return ""
        }
    }

    private var keyAlreadyStored: Bool {
        guard let service = provider.keychainService else { return false }
        return Keychain.read(service: service) != nil
    }

    private func section(_ title: String, subtitle: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 92)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private func resetDefaults() {
        rulesText = ProseConfig.defaultRules.joined(separator: "\n")
        preferencesText = ProseConfig.defaultPreferences.joined(separator: "\n")
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        var updated = baseConfig
        updated.provider = provider
        updated.rules = lines(rulesText)
        updated.preferences = lines(preferencesText)
        updated.model = modelChoice == Self.customTag
            ? customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            : modelChoice
        updated.temperature = temperature

        // Persist a freshly-entered key into the provider's Keychain service.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, let service = provider.keychainService {
            Keychain.write(key, service: service)
        }
        onSave(updated)
        onClose()
    }
}
#endif
