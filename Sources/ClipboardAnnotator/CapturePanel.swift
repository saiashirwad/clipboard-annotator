import AppKit
import SwiftUI

/// A floating panel that can take keyboard focus and, crucially, does **not**
/// hide when another app takes over. That is what lets Wispr Flow, Hex, or any
/// other dictation tool run on top of it while the note field stays alive.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private var panel: CapturePanel?
    private var model: CaptureModel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    private let panelWidth: CGFloat = 460
    private let panelHeight: CGFloat = 260

    private init() {}

    var isOpen: Bool { panel != nil }

    func beginCapture() {
        if isOpen {
            // Second press while open: just bring it back to the front.
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        guard PermissionCheck.ensureAccessibility() else { return }

        previousApp = NSWorkspace.shared.frontmostApplication
        let captured = SelectionCapture.capture()
        present(captured)
    }

    private func present(_ captured: CapturedSelection) {
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 380, height: 220)
        panel.animationBehavior = .utilityWindow

        let model = CaptureModel(captured: captured, stackCount: AnnotationStore.shared.entries.count)
        self.model = model
        let view = CaptureView(
            model: model,
            onSave: { [weak self] in self?.commit() },
            onCancel: { [weak self] in self?.dismiss(returnFocus: true) }
        )
        // The hosting view fills the whole frame, title-bar strip included, so
        // the material runs edge to edge under the transparent title bar.
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        position(panel, near: captured.screenRect)

        self.panel = panel
        installKeyMonitor()

        // Synchronous: the stack window must be out of the way before we
        // activate, or activating drags it forward with the panel.
        NotificationCenter.default.post(name: .captureWillPresent, object: nil)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Placement

    private func position(_ panel: NSPanel, near selectionRect: CGRect?) {
        let size = panel.frame.size
        var origin: NSPoint

        if let rect = selectionRect, let screen = screenContaining(quartzRect: rect) {
            // Quartz rects are top-left origin; flip into AppKit coordinates.
            let flippedY = flipY(quartzRect: rect)
            origin = NSPoint(x: rect.midX - size.width / 2, y: flippedY - size.height - 12)
            if origin.y < screen.visibleFrame.minY + 8 {
                origin.y = flippedY + rect.height + 12
            }
        } else {
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 16)
        }

        let screen = screenContaining(point: NSPoint(x: origin.x + size.width / 2, y: origin.y))
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    private func flipY(quartzRect rect: CGRect) -> CGFloat {
        // Quartz global space is anchored at the top-left of the primary display.
        guard let primary = NSScreen.screens.first else { return rect.minY }
        return primary.frame.maxY - rect.minY
    }

    private func screenContaining(quartzRect rect: CGRect) -> NSScreen? {
        let point = NSPoint(x: rect.midX, y: flipY(quartzRect: rect))
        return screenContaining(point: point)
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn && event.modifierFlags.contains(.command) {
                self.commit()
                return nil
            }
            if event.keyCode == 53 { // escape
                self.dismiss(returnFocus: true)
                return nil
            }
            return event
        }
    }

    // MARK: - Finish

    /// Saves the panel that is actually on screen. Nothing else can trigger it.
    private func commit() {
        guard let model, panel != nil else { return }
        save(captured: model.captured, note: model.note)
    }

    private func save(captured: CapturedSelection, note: String) {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuote = captured.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty || !trimmedQuote.isEmpty else {
            dismiss(returnFocus: true)
            return
        }
        AnnotationStore.shared.add(
            Annotation(
                quote: captured.text,
                note: trimmedNote,
                sourceApp: captured.appName,
                sourceURL: nil
            )
        )
        Diag.log("saved annotation, note=\(trimmedNote.prefix(30).debugDescription) quote=\(captured.text.count) chars")
        dismiss(returnFocus: true)
    }

    func dismiss(returnFocus: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model = nil

        if returnFocus, AppSettings.shared.restoreFocusAfterSave,
           let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }
}

extension Notification.Name {
    static let captureWillPresent = Notification.Name("ClipboardAnnotator.captureWillPresent")
}
