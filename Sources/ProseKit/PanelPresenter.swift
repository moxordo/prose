#if canImport(AppKit)
import AppKit
import SwiftUI

/// Observable state backing the rewrite panel.
@MainActor
public final class RewriteViewModel: ObservableObject {
    public enum Phase: Equatable { case thinking, streaming, done, error }

    @Published public var original: String = ""
    @Published public var rewrite: String = ""
    @Published public var phase: Phase = .thinking
    @Published public var errorText: String = ""

    public init() {}
}

/// The panel's SwiftUI content: original (dimmed) above the streaming rewrite,
/// with Copy / Replace / Dismiss actions.
struct RewritePanelView: View {
    @ObservedObject var model: RewriteViewModel
    let onCopy: () -> Void
    let onReplace: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.tint)
                Text("Prose")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                phaseIndicator
            }

            if !model.original.isEmpty {
                Text(model.original)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            Group {
                if model.phase == .error {
                    Text(model.errorText)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                } else {
                    ScrollView {
                        Text(model.rewrite.isEmpty ? " " : model.rewrite)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button(action: onDismiss) { buttonLabel("Dismiss", "⎋") }
                    .keyboardShortcut(.cancelAction)
                Button(action: onCopy) { buttonLabel("Copy", "⌘C") }
                    .keyboardShortcut("c", modifiers: [.command])
                    .disabled(model.phase != .done)
                Button(action: onReplace) { buttonLabel("Replace", "⌘↩") }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.phase != .done)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 420)
    }

    /// Button title with its keyboard shortcut shown dimmed alongside, the way
    /// macOS menu items surface shortcuts. Inherits the button's foreground color
    /// so it reads correctly on both plain and prominent (blue) buttons.
    private func buttonLabel(_ title: String, _ shortcut: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(shortcut)
                .font(.system(size: 11, weight: .semibold))
                .opacity(0.55)
        }
    }

    @ViewBuilder private var phaseIndicator: some View {
        switch model.phase {
        case .thinking:
            HStack(spacing: 4) { ProgressView().controlSize(.small); Text("thinking…").font(.system(size: 11)).foregroundStyle(.secondary) }
        case .streaming:
            HStack(spacing: 4) { ProgressView().controlSize(.small); Text("writing…").font(.system(size: 11)).foregroundStyle(.secondary) }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 12))
        }
    }
}

/// Borderless panels can't become key by default; this subclass opts in so the
/// panel can receive keyboard shortcuts (Esc / ⌘C / ⌘↩).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A floating panel that presents a rewrite near the cursor. It becomes key on
/// show so keyboard shortcuts work, and remembers the app you triggered from so
/// "Replace" reactivates it and pastes into the right place.
@MainActor
public final class PanelPresenter: NSObject, ResultPresenting {
    private var panel: NSPanel?
    private let model = RewriteViewModel()
    /// The app that was frontmost when the rewrite was triggered — Replace/Dismiss
    /// return focus here so ⌘V lands in the original app.
    private var sourceApp: NSRunningApplication?
    private var keyMonitor: Any?

    public override init() { super.init() }

    // MARK: ResultPresenting

    public func noSelection() {
        NSSound.beep()
    }

    public func begin(original: String) {
        // Capture the source app BEFORE we show/activate our own panel.
        sourceApp = NSWorkspace.shared.frontmostApplication
        model.original = original
        model.rewrite = ""
        model.errorText = ""
        model.phase = .thinking
        showPanel()
    }

    public func thinking() { model.phase = .thinking }

    public func append(_ delta: String) {
        if model.phase != .streaming { model.phase = .streaming }
        model.rewrite += delta
    }

    public func finish(full: String) {
        model.rewrite = full
        model.phase = .done
    }

    public func fail(_ error: Error) {
        model.errorText = error.localizedDescription
        model.phase = .error
    }

    // MARK: Panel plumbing

    private func showPanel() {
        let panel = existingOrNewPanel()
        positionNearCursor(panel)
        // Activate + make key so keyboard shortcuts reach the panel.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    // MARK: Keyboard shortcuts (Esc / ⌘C / ⌘↩)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns nil to consume the event, or the event to pass it through.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53:  // Esc → Dismiss
            dismiss()
            return nil
        case 36, 76:  // Return / keypad Enter → ⌘↩ Replace
            if cmd, model.phase == .done { replace(); return nil }
        default:  // ⌘C → Copy
            if cmd, event.charactersIgnoringModifiers?.lowercased() == "c", model.phase == .done {
                copyRewrite()
                return nil
            }
        }
        return event
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }
        let view = RewritePanelView(
            model: model,
            onCopy: { [weak self] in self?.copyRewrite() },
            onReplace: { [weak self] in self?.replace() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        panel.contentView = visualEffectWrapper(hosting)
        self.panel = panel
        return panel
    }

    private func visualEffectWrapper(_ content: NSView) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    private func positionNearCursor(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Place top-left just below-right of the cursor, clamped on-screen.
        var x = mouse.x + 12
        var y = mouse.y - size.height - 12
        x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
        y = min(max(visible.minY + 8, y), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Actions

    private func copyRewrite() {
        Pasteboard.setString(model.rewrite)
        dismiss()
    }

    private func replace() {
        Pasteboard.setString(model.rewrite)
        closePanel()
        // Return focus to the original app, then paste.
        sourceApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Keyboard.postComboV()
        }
    }

    public func dismiss() {
        closePanel()
        // Hand focus back to where the user was working.
        sourceApp?.activate()
    }

    private func closePanel() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    // MARK: Test hooks

    /// Render the panel offscreen for snapshot tests, without a live pipeline.
    public func renderForSnapshot(original: String, rewrite: String, phase: RewriteViewModel.Phase) -> NSImage? {
        model.original = original
        model.rewrite = rewrite
        model.phase = phase
        let panel = existingOrNewPanel()
        panel.layoutIfNeeded()
        guard let content = panel.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        content.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
#endif
