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
                Button("Dismiss", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Copy", action: onCopy)
                    .keyboardShortcut("c", modifiers: [.command])
                    .disabled(model.phase != .done)
                Button("Replace", action: onReplace)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.phase != .done)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 420)
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

/// A non-activating floating panel that presents a rewrite near the cursor.
/// Non-activating is essential: it means we never steal focus from the app the
/// user selected text in, so "Replace" (synthetic ⌘V) lands in the right place.
@MainActor
public final class PanelPresenter: NSObject, ResultPresenting {
    private var panel: NSPanel?
    private let model = RewriteViewModel()

    public override init() { super.init() }

    // MARK: ResultPresenting

    public func noSelection() {
        NSSound.beep()
    }

    public func begin(original: String) {
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
        panel.orderFrontRegardless()
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }
        let view = RewritePanelView(
            model: model,
            onCopy: { [weak self] in self?.copy() },
            onReplace: { [weak self] in self?.replace() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
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

    private func copy() {
        Pasteboard.setString(model.rewrite)
    }

    private func replace() {
        Pasteboard.setString(model.rewrite)
        dismiss()
        // Give focus a beat to return to the source app, then paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Keyboard.postComboV()
        }
    }

    public func dismiss() {
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
