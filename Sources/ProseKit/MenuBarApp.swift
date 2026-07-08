#if canImport(AppKit)
import AppKit

/// The menu-bar (LSUIElement/accessory) application. Owns the status item, the
/// triggers, and the pipeline. No Dock icon, no main window.
@MainActor
public final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let config: ProseConfig
    private var statusItem: NSStatusItem?
    private var pipeline: RewritePipeline?
    private var triggers: [TriggerSource] = []

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
        // Keep a strong ref alive for the app lifetime.
        objc_setAssociatedObject(app, "prose.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
        fatalError("NSApplication.run returned")
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        let presenter = PanelPresenter()
        let capture = CompositeCapture([AXSelectionCapture(), ClipboardCopyCapture()])
        let rewriter = OllamaRewriter(config: config)
        let pipeline = RewritePipeline(capture: capture, rewriter: rewriter, presenter: presenter)
        self.pipeline = pipeline

        if config.forceClickEnabled {
            let forceClick = ForceClickTrigger()
            forceClick.start { [weak pipeline] in pipeline?.run() }
            triggers.append(forceClick)
        }
        let hotkey = HotkeyTrigger(config: config.hotkey)
        hotkey.start { [weak pipeline] in pipeline?.run() }
        triggers.append(hotkey)

        // Suppress the system Accessibility prompt during automated smoke tests.
        let suppressPrompt = ProcessInfo.processInfo.environment["PROSE_SUPPRESS_AX_PROMPT"] == "1"
        if !Permissions.isAccessibilityTrusted && !suppressPrompt {
            Permissions.ensureAccessibility(prompt: true)
        }

        // Smoke-test hook: exit cleanly after a moment so a headless launch can
        // confirm the app boots without hanging the run loop forever.
        if let seconds = ProcessInfo.processInfo.environment["PROSE_SMOKE_EXIT_SECONDS"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                NSApp.terminate(nil)
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Prose")

        let menu = NSMenu()
        let rewriteItem = NSMenuItem(
            title: "Rewrite Selection (\(config.hotkey.label))",
            action: #selector(triggerNow), keyEquivalent: ""
        )
        rewriteItem.target = self
        menu.addItem(rewriteItem)
        menu.addItem(.separator())

        let backend = (config.apiKey?.isEmpty == false) ? "cloud" : "local"
        menu.addItem(disabled: "Model: \(config.model)  [\(backend)]")
        menu.addItem(disabled: "Endpoint: \(config.normalizedBaseURL)")

        let axItem = NSMenuItem(
            title: Permissions.isAccessibilityTrusted ? "Accessibility: granted ✓" : "Grant Accessibility…",
            action: #selector(openAccessibility), keyEquivalent: ""
        )
        axItem.target = self
        menu.addItem(axItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Prose", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func triggerNow() { pipeline?.run() }

    @objc private func openAccessibility() {
        Permissions.ensureAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
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
