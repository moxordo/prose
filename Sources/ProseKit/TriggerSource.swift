import Foundation
#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox
#endif

/// Emits "the user wants a rewrite now" signals. The pipeline subscribes to one
/// or more of these; they are the only OS-hardware-coupled part of the app, so
/// they're kept behind a protocol with a programmatic test double.
public protocol TriggerSource: AnyObject {
    /// Begin emitting. `handler` is always called on the main actor.
    func start(_ handler: @escaping @MainActor () -> Void)
    func stop()
}

/// Test/CLI trigger: fire manually via `fire()`.
public final class ProgrammaticTrigger: TriggerSource {
    private var handler: (@MainActor () -> Void)?
    public init() {}
    public func start(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    public func stop() { handler = nil }

    public func fire() {
        let h = handler
        Task { @MainActor in h?() }
    }
}

#if canImport(AppKit)

/// Detects a Force Touch "force click" — a deep press that crosses into
/// pressure **stage 2** — anywhere on the system via a global event monitor.
///
/// Caveats baked into the design:
///  • Global monitors are passive observers; they cannot consume the event, so
///    the OS "Look Up" behavior may also fire. That's acceptable for a utility.
///  • Pressure delivery to global monitors isn't guaranteed in every non-Cocoa
///    surface, which is why `HotkeyTrigger` exists as a permission-light backup.
///  • We debounce on the 1→2 stage transition so one deep press == one trigger.
public final class ForceClickTrigger: TriggerSource {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var handler: (@MainActor () -> Void)?
    private var lastStage: Int = 0
    private var lastFire: Date = .distantPast
    private let debounce: TimeInterval

    public init(debounce: TimeInterval = 0.6) {
        self.debounce = debounce
    }

    public func start(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        let mask: NSEvent.EventTypeMask = [.pressure]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePressure(event)
        }
        // A local monitor lets force-click work while our own panel is key too.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePressure(event)
            return event
        }
    }

    public func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        handler = nil
    }

    private func handlePressure(_ event: NSEvent) {
        let stage = event.stage
        defer { lastStage = stage }
        // Fire only on the upward transition into stage 2 (the force-click detent).
        guard stage >= 2, lastStage < 2 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFire) > debounce else { return }
        lastFire = now
        let h = handler
        Task { @MainActor in h?() }
    }
}

/// Global hotkey via Carbon `RegisterEventHotKey`. Notably this does NOT require
/// Accessibility permission, so it's the reliable fallback trigger. Default ⌥⌘R.
public final class HotkeyTrigger: TriggerSource {
    private let config: HotkeyConfig
    private var handler: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature = OSType(0x50524F53) // 'PROS'

    public init(config: HotkeyConfig) {
        self.config = config
    }

    public func start(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Trampoline: Carbon calls a C function; we recover self via userData.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let trigger = Unmanaged<HotkeyTrigger>.fromOpaque(userData).takeUnretainedValue()
                let h = trigger.handler
                Task { @MainActor in h?() }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    public func stop() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let handler = eventHandler { RemoveEventHandler(handler); eventHandler = nil }
        self.handler = nil
    }
}

#endif
