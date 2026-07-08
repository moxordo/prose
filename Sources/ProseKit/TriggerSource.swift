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

/// C-compatible tap callback for the force-click CGEventTap. Recovers the
/// trigger via `refcon` and forwards the pressure stage.
private func forceClickTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let trigger = Unmanaged<ForceClickTrigger>.fromOpaque(refcon).takeUnretainedValue()
    // The system disables taps that time out or on fast user input — re-arm.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        trigger.reenableTap()
        return Unmanaged.passUnretained(event)
    }
    if type.rawValue == 34, let ns = NSEvent(cgEvent: event) {
        let stage = ns.stage
        Task { @MainActor in trigger.handleStage(stage, source: "cgtap") }
    }
    return Unmanaged.passUnretained(event)
}

/// Detects a Force Touch "force click" — a deep press crossing into pressure
/// **stage 2** — anywhere on the system. Ships TWO detectors because global
/// force-click delivery is genuinely unreliable:
///
///  1. `NSEvent` global `.pressure` monitor — simple, but frequently never fires
///     in non-Cocoa apps.
///  2. `CGEventTap` on the pressure event (type 34) — lower level, needs
///     Accessibility, and is the path that usually *does* deliver globally.
///
/// Whichever fires first wins; a shared debounce collapses duplicates so one deep
/// press == one trigger. `HotkeyTrigger` (⌥⌘R) remains the guaranteed fallback.
public final class ForceClickTrigger: TriggerSource {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var handler: (@MainActor () -> Void)?
    private var lastStage: Int = 0
    private var lastFire: Date = .distantPast
    private let debounce: TimeInterval

    public private(set) var globalMonitorInstalled = false
    public private(set) var tapInstalled = false

    public init(debounce: TimeInterval = 0.6) {
        self.debounce = debounce
    }

    public func start(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler

        let mask: NSEvent.EventTypeMask = [.pressure]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleStage(event.stage, source: "nsevent")
        }
        globalMonitorInstalled = (globalMonitor != nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleStage(event.stage, source: "nsevent-local")
            return event
        }

        installTap()
    }

    private func installTap() {
        let mask: CGEventMask = (1 << 34) // NSEventType.pressure
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: forceClickTapCallback, userInfo: refcon
        ) else {
            tapInstalled = false
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapSource = source
        tapInstalled = true
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    public func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tapSource, .commonModes) }
        globalMonitor = nil
        localMonitor = nil
        tap = nil
        tapSource = nil
        handler = nil
    }

    /// Fire only on the upward transition into stage 2, debounced across sources.
    fileprivate func handleStage(_ stage: Int, source: String) {
        defer { lastStage = stage }
        guard stage >= 2, lastStage < 2 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFire) > debounce else { return }
        lastFire = now
        Log.write("force-click detected via \(source) (stage \(stage))")
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
