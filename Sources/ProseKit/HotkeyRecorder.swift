#if canImport(AppKit)
import AppKit
import SwiftUI
import Carbon.HIToolbox

public extension HotkeyConfig {
    /// Build a `HotkeyConfig` from a captured key event. Returns nil for a combo
    /// without a ⌘/⌥/⌃ modifier (rejected — a global hotkey needs one).
    static func from(event: NSEvent) -> HotkeyConfig? {
        let f = event.modifierFlags
        return make(
            keyCode: UInt32(event.keyCode),
            control: f.contains(.control),
            option: f.contains(.option),
            shift: f.contains(.shift),
            command: f.contains(.command),
            keyName: keyName(for: event.keyCode, characters: event.charactersIgnoringModifiers)
        )
    }

    /// Display glyph for a virtual key code (special keys mapped; otherwise the
    /// unmodified character, uppercased).
    static func keyName(for keyCode: UInt16, characters: String?) -> String {
        let specials: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "␣", kVK_Delete: "⌫",
            kVK_Escape: "⎋", kVK_ANSI_KeypadEnter: "⌤", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = specials[Int(keyCode)] { return s }
        if let c = characters, !c.isEmpty, c != " " { return c.uppercased() }
        return "·"
    }
}

/// A bordered field that records the next key combination — the Alfred pattern.
/// Click to arm, press a combo to set it, ⎋ to cancel. Overrides both `keyDown`
/// and `performKeyEquivalent` so ⌘-combos are captured too (they'd otherwise be
/// swallowed as menu key-equivalents).
final class KeyRecorderButton: NSButton {
    var onChange: ((HotkeyConfig) -> Void)?
    var hotkey: HotkeyConfig { didSet { updateTitle() } }

    private var recording = false {
        didSet {
            updateTitle()
            window?.makeFirstResponder(recording ? self : nil)
        }
    }

    init(hotkey: HotkeyConfig) {
        self.hotkey = hotkey
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func clicked() { recording.toggle() }

    private func updateTitle() {
        title = recording ? "Type a shortcut…  ⎋ to cancel" : hotkey.label
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        guard recording, capture(event) else { super.keyDown(with: event); return }
    }

    /// Returns true if the event was consumed.
    private func capture(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // ⎋ with no modifiers cancels recording.
        if Int(event.keyCode) == kVK_Escape, mods.isEmpty {
            recording = false
            return true
        }
        if let hk = HotkeyConfig.from(event: event) {
            hotkey = hk
            onChange?(hk)
            recording = false
            return true
        }
        // Modifier-less combo: reject but consume so it doesn't type while armed.
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }
}

/// SwiftUI wrapper (module-internal — used by SettingsView).
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: HotkeyConfig
    init(hotkey: Binding<HotkeyConfig>) { self._hotkey = hotkey }

    func makeNSView(context: Context) -> KeyRecorderButton {
        let button = KeyRecorderButton(hotkey: hotkey)
        button.onChange = { context.coordinator.hotkey.wrappedValue = $0 }
        return button
    }

    func updateNSView(_ nsView: KeyRecorderButton, context: Context) {
        if nsView.hotkey != hotkey { nsView.hotkey = hotkey }
    }

    func makeCoordinator() -> Coordinator { Coordinator(hotkey: $hotkey) }

    final class Coordinator {
        var hotkey: Binding<HotkeyConfig>
        init(hotkey: Binding<HotkeyConfig>) { self.hotkey = hotkey }
    }
}
#endif
