import Foundation
#if canImport(AppKit)
import AppKit
import ApplicationServices
import Security
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

    // MARK: Code signature — why a grant can go stale

    /// macOS keys the Accessibility grant to the app's *designated requirement*.
    /// For an ad-hoc signature that is `cdhash H"…"` — this exact binary — so
    /// every rebuild invalidates the grant while System Settings still shows
    /// Prose as ON. A certificate-backed signature (see scripts/codesign.sh) is
    /// stable across rebuilds.
    public struct Signature: Equatable {
        public let adHoc: Bool
        public let summary: String
    }

    public static let signature: Signature = {
        #if canImport(AppKit)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return Signature(adHoc: true, summary: "unknown")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return Signature(adHoc: true, summary: "unknown")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return Signature(adHoc: true, summary: "unsigned") }
        let flags = dict[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return Signature(adHoc: true, summary: "ad-hoc")
        }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
           let name = SecCertificateCopySubjectSummary(leaf) as String? {
            return Signature(adHoc: false, summary: name)
        }
        return Signature(adHoc: false, summary: "signed")
        #else
        return Signature(adHoc: true, summary: "unknown")
        #endif
    }()

    /// Drop the (possibly stale) Accessibility entry so the next prompt is a
    /// clean one. `tccutil` works unprivileged for our own bundle id.
    @discardableResult
    public static func resetAccessibilityGrant(bundleID: String) -> Bool {
        #if canImport(AppKit)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
        #else
        return false
        #endif
    }
}
