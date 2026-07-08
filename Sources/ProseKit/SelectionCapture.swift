import Foundation
#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif

/// Obtains the text the user currently has selected in the frontmost app.
public protocol SelectionCapturing: Sendable {
    /// Returns the selection, or nil if nothing usable could be captured.
    func capturedSelection() async -> String?
}

/// Test double: always returns a fixed string.
public struct FixedTextCapture: SelectionCapturing {
    public let text: String?
    public init(_ text: String?) { self.text = text }
    public func capturedSelection() async -> String? {
        guard let t = text, !t.isEmpty else { return nil }
        return t
    }
}

/// Reads whatever is already on the general pasteboard. No synthetic copy, no
/// permissions — handy for tests and for a "rewrite my clipboard" mode.
public struct PasteboardReadCapture: SelectionCapturing {
    public init() {}
    public func capturedSelection() async -> String? {
        #if canImport(AppKit)
        let s = NSPasteboard.general.string(forType: .string)
        return (s?.isEmpty ?? true) ? nil : s
        #else
        return nil
        #endif
    }
}

/// Tries each strategy in order, returning the first non-empty result.
/// Production capture is `CompositeCapture([AXSelectionCapture, ClipboardCopyCapture])`.
public struct CompositeCapture: SelectionCapturing {
    public let strategies: [SelectionCapturing]
    public init(_ strategies: [SelectionCapturing]) { self.strategies = strategies }
    public func capturedSelection() async -> String? {
        for strategy in strategies {
            if let text = await strategy.capturedSelection(), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

#if canImport(AppKit)

/// Reads `kAXSelectedTextAttribute` from the system-wide focused UI element.
/// Clean (no clipboard side effects) but not all apps expose it — Terminal,
/// Chromium/Electron surfaces often return nothing, which is why it's paired
/// with `ClipboardCopyCapture` in a `CompositeCapture`.
public struct AXSelectionCapture: SelectionCapturing {
    public init() {}

    public func capturedSelection() async -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused else {
            return nil
        }
        // Force-cast is safe: the AX API returns AXUIElement for this attribute.
        let element = focusedElement as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else {
            return nil
        }
        return text
    }
}

/// Universal fallback: snapshot the pasteboard, post a synthetic ⌘C, read the
/// copied text, then restore the original pasteboard so the user's clipboard is
/// left untouched. Requires Accessibility (to post the synthetic keystroke).
public struct ClipboardCopyCapture: SelectionCapturing {
    /// How long to wait for the target app to service the ⌘C.
    public let pollInterval: Duration
    public let maxAttempts: Int

    public init(pollInterval: Duration = .milliseconds(15), maxAttempts: Int = 40) {
        self.pollInterval = pollInterval
        self.maxAttempts = maxAttempts
    }

    public func capturedSelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = Pasteboard.snapshot(pasteboard)
        let startChangeCount = pasteboard.changeCount

        Keyboard.postComboC()

        var copied: String?
        for _ in 0..<maxAttempts {
            try? await Task.sleep(for: pollInterval)
            if pasteboard.changeCount != startChangeCount {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        // Restore the user's original clipboard regardless of outcome.
        Pasteboard.restore(snapshot, to: pasteboard)

        guard let text = copied, !text.isEmpty else { return nil }
        return text
    }
}

/// Pasteboard save/restore helpers.
public enum Pasteboard {
    public static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    public static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.compactMap { dict in
            guard !dict.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Replace the pasteboard with a single plain-text string.
    public static func setString(_ string: String, on pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

/// Synthetic keystroke helpers via CGEvent. Requires Accessibility trust.
public enum Keyboard {
    // Carbon virtual key codes.
    static let kVK_ANSI_C: CGKeyCode = 8
    static let kVK_ANSI_V: CGKeyCode = 9

    public static func postCombo(_ key: CGKeyCode, flags: CGEventFlags = .maskCommand) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    public static func postComboC() { postCombo(kVK_ANSI_C) }
    public static func postComboV() { postCombo(kVK_ANSI_V) }
}

#endif
