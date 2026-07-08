#if canImport(AppKit)
import AppKit

/// C-compatible CGEventTap callback (no Swift context capture). 34 == pressure.
private func proseTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Log the actual force fields on every event so we can see whether a
    // force-click ever surfaces stage>=2 or an elevated pressure anywhere.
    let ns = NSEvent(cgEvent: event)
    let stage = ns?.stage ?? -1
    let nsPressure = ns.map { String(format: "%.2f", $0.pressure) } ?? "?"
    let mouseField = String(format: "%.2f", event.getDoubleValueField(.mouseEventPressure))
    let name: String
    switch type.rawValue {
    case 34: name = "pressure"
    case UInt32(CGEventType.leftMouseDown.rawValue): name = "leftMouseDown"
    case UInt32(CGEventType.leftMouseDragged.rawValue): name = "leftMouseDragged"
    default: name = "type\(type.rawValue)"
    }
    Log.write("  [CGtap \(name)] stage=\(stage) nsPressure=\(nsPressure) mouseField=\(mouseField)")
    return Unmanaged.passUnretained(event)
}

/// The menu-bar (LSUIElement/accessory) application. Owns the status item, the
/// triggers, and the pipeline. No Dock icon, no main window.
@MainActor
public final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let config: ProseConfig
    private var statusItem: NSStatusItem?
    private var pipeline: RewritePipeline?
    private var triggers: [TriggerSource] = []
    private var forceClick: ForceClickTrigger?
    private var trustTimer: Timer?
    private var recordMonitors: [Any] = []
    private var recordTap: CFMachPort?

    public init(config: ProseConfig) {
        self.config = config
        super.init()
    }

    /// Boot the app run loop as a menu-bar accessory.
    public static func launch(config: ProseConfig) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MenuBarApp(config: config)
        app.delegate = delegate
        objc_setAssociatedObject(app, "prose.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
        fatalError("NSApplication.run returned")
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.startSession("Prose launch — accessibility=\(Permissions.isAccessibilityTrusted) policy=\(NSApp.activationPolicy().rawValue)")
        setupStatusItem()

        let presenter = PanelPresenter()
        let capture = CompositeCapture([AXSelectionCapture(), ClipboardCopyCapture()])
        let rewriter = OllamaRewriter(config: config)
        let pipeline = RewritePipeline(capture: capture, rewriter: rewriter, presenter: presenter)
        self.pipeline = pipeline

        if config.forceClickEnabled {
            let fc = ForceClickTrigger()
            self.forceClick = fc
            armForceClick()
            triggers.append(fc)
        }
        let hotkey = HotkeyTrigger(config: config.hotkey)
        hotkey.start { [weak pipeline] in
            Log.write("trigger: hotkey (\(self.config.hotkey.label)) fired")
            pipeline?.run()
        }
        Log.write("hotkey trigger registered: \(config.hotkey.label)")
        triggers.append(hotkey)

        let suppressUI = ProcessInfo.processInfo.environment["PROSE_SUPPRESS_AX_PROMPT"] == "1"
        if !suppressUI {
            showWelcomeIfNeeded()
            if !Permissions.isAccessibilityTrusted {
                Permissions.ensureAccessibility(prompt: true)
                // A CGEventTap created while untrusted stays dead; re-arm it the
                // moment the user grants Accessibility, so no relaunch is needed.
                startTrustPolling()
            }
        }

        if let seconds = ProcessInfo.processInfo.environment["PROSE_SMOKE_EXIT_SECONDS"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    /// (Re)install the force-click detectors bound to the current pipeline. Called
    /// at launch and again once Accessibility is granted (so the tap gets trust).
    private func armForceClick() {
        guard let fc = forceClick, let pipeline else { return }
        fc.stop()
        fc.start { [weak pipeline] in
            Log.write("trigger: force-click fired")
            pipeline?.run()
        }
        Log.write("force-click armed: nsEvent=\(fc.globalMonitorInstalled) cgTap=\(fc.tapInstalled) trusted=\(Permissions.isAccessibilityTrusted)")
    }

    private func startTrustPolling() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard Permissions.isAccessibilityTrusted else { return }
                timer.invalidate()
                self.trustTimer = nil
                Log.write("accessibility granted at runtime → re-arming force-click")
                self.armForceClick()
            }
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Prose") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "✨"
            }
            button.toolTip = "Prose — rewrite selection (\(config.hotkey.label))"
        }
        item.isVisible = true
        Log.write("statusItem: button=\(item.button != nil) hasImage=\(item.button?.image != nil) frame=\(item.button?.frame ?? .zero)")

        let menu = NSMenu()
        menu.addItem(action("Rewrite Selection  (\(config.hotkey.label))", #selector(triggerNow)))
        menu.addItem(.separator())

        let backend = (config.apiKey?.isEmpty == false) ? "cloud" : "local"
        menu.addItem(disabled: "Model: \(config.model)  [\(backend)]")
        menu.addItem(action(
            Permissions.isAccessibilityTrusted ? "Accessibility: granted ✓" : "⚠️ Grant Accessibility…",
            #selector(openAccessibility)
        ))
        menu.addItem(.separator())
        menu.addItem(action("Record force-click test (20s)", #selector(recordForceClickTest)))
        menu.addItem(action("Open Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Prose", #selector(quit), key: "q"))

        item.menu = menu
        statusItem = item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Welcome

    private func showWelcomeIfNeeded() {
        let trusted = Permissions.isAccessibilityTrusted
        let welcomed = UserDefaults.standard.bool(forKey: "prose.welcomed")
        // Nag until setup is complete; once trusted and welcomed, stay quiet.
        guard !trusted || !welcomed else { return }
        UserDefaults.standard.set(true, forKey: "prose.welcomed")

        let alert = NSAlert()
        alert.messageText = "Prose is running ✨"
        let axLine = trusted
            ? "Accessibility: granted ✓"
            : "⚠️ Accessibility is NOT granted yet — it's required to read your selection and to trigger on force-click. Grant it, then relaunch."
        alert.informativeText = """
            Select text in any app, then force-click it — or press \(config.hotkey.label) — to get a clearer rewrite.

            The ✨ icon lives in your menu bar (it may be hidden behind the notch if your menu bar is full). Use it to trigger a rewrite or quit.

            \(axLine)

            Diagnostics log: ~/Library/Logs/Prose.log
            """
        NSApp.activate(ignoringOtherApps: true)
        if !trusted {
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { openAccessibility() }
        } else {
            alert.addButton(withTitle: "Got it")
            alert.runModal()
        }
    }

    // MARK: Actions

    @objc private func triggerNow() { pipeline?.run() }

    @objc private func openAccessibility() {
        Permissions.ensureAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    /// Install raw monitors + a CGEventTap and log every pressure/mouse event for
    /// 20s. Because this runs inside the AX-trusted app, it reveals the truth about
    /// whether force-click is delivered globally — which an untrusted CLI cannot.
    @objc private func recordForceClickTest() {
        Log.write("── RECORD force-click test (20s) — accessibility=\(Permissions.isAccessibilityTrusted) ──")
        let originalImage = statusItem?.button?.image
        statusItem?.button?.image = nil
        statusItem?.button?.title = "◉ REC"

        let p = NSEvent.addGlobalMonitorForEvents(matching: [.pressure]) { e in
            Log.write("  [NSEvent pressure] stage=\(e.stage) pressure=\(String(format: "%.2f", e.pressure))")
        }
        let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { e in
            Log.write("  [NSEvent leftMouseDown] stage=\(e.stage)")
        }
        recordMonitors = [p, m].compactMap { $0 }

        let mask: CGEventMask = (1 << 34)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                       options: .listenOnly, eventsOfInterest: mask,
                                       callback: proseTapCallback, userInfo: nil) {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            recordTap = tap
            Log.write("  CGEventTap installed")
        } else {
            Log.write("  CGEventTap FAILED (needs Accessibility)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self else { return }
            self.recordMonitors.forEach { NSEvent.removeMonitor($0) }
            self.recordMonitors = []
            if let t = self.recordTap { CGEvent.tapEnable(tap: t, enable: false) }
            self.recordTap = nil
            self.statusItem?.button?.title = ""
            self.statusItem?.button?.image = originalImage
            Log.write("── RECORD done ── (force-click a few times above? check the lines)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
#endif
