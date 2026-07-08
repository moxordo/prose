import Foundation
#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif

/// Accessibility permission is the one thing no software can grant itself — it is
/// the OS security boundary that gates global event monitoring, reading other
/// apps' AX attributes, and posting synthetic keystrokes. This helper only
/// *checks* and *prompts*; the user must toggle it in System Settings once.
public enum Permissions {
    public static var isAccessibilityTrusted: Bool {
        #if canImport(AppKit)
        return AXIsProcessTrusted()
        #else
        return false
        #endif
    }

    /// Checks trust, optionally showing the system prompt that deep-links to
    /// System Settings → Privacy & Security → Accessibility.
    @discardableResult
    public static func ensureAccessibility(prompt: Bool) -> Bool {
        #if canImport(AppKit)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
        #else
        return false
        #endif
    }
}
