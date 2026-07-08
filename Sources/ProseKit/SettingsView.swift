#if canImport(AppKit)
import SwiftUI

/// Editor for how Prose rewrites text: hard Rules + soft Preferences (plus model
/// and creativity). One item per line. Saving persists to config.json (key stays
/// in the Keychain) and rebuilds the pipeline so changes apply to the next rewrite.
@MainActor
public struct SettingsView: View {
    @State private var rulesText: String
    @State private var preferencesText: String
    @State private var model: String
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
        _rulesText = State(initialValue: config.rules.joined(separator: "\n"))
        _preferencesText = State(initialValue: config.preferences.joined(separator: "\n"))
        _model = State(initialValue: config.model)
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
                    TextField("gemma3:27b", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Creativity: \(temperature, specifier: "%.2f")")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $temperature, in: 0...1).frame(width: 160)
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
        updated.rules = lines(rulesText)
        updated.preferences = lines(preferencesText)
        updated.model = model.trimmingCharacters(in: .whitespaces).isEmpty
            ? baseConfig.model
            : model.trimmingCharacters(in: .whitespaces)
        updated.temperature = temperature
        onSave(updated)
        onClose()
    }
}
#endif
