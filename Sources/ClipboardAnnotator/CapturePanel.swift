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
    private var voicePanel: CapturePanel?
    private var voiceModel: VoiceCaptureModel?
    private var voiceKeyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var voiceKeyIsHeld = false
    private var voiceStartTask: Task<Void, Never>?
    private var voiceFinishTask: Task<Void, Never>?

    private let panelWidth: CGFloat = 460
    private let panelHeight: CGFloat = 260

    private init() {}

    var isOpen: Bool { panel != nil || voicePanel != nil }

    func beginCapture() {
        if isOpen {
            // Second press while open: just bring it back to the front.
            NSApp.activate(ignoringOtherApps: true)
            (panel ?? voicePanel)?.makeKeyAndOrderFront(nil)
            return
        }

        guard PermissionCheck.ensureAccessibility() else { return }

        previousApp = NSWorkspace.shared.frontmostApplication
        let captured = SelectionCapture.capture()
        present(captured)
    }

    /// Starts a capture and a microphone recording together. `endVoiceCapture`
    /// is called by the matching global-hotkey release event.
    func beginVoiceCapture() {
        guard PermissionCheck.ensureAccessibility() else { return }

        if isOpen {
            NSSound.beep()
            return
        }

        voiceKeyIsHeld = true
        previousApp = NSWorkspace.shared.frontmostApplication

        // Start before the selection fallback. That fallback must wait for the
        // physical modifiers to lift before it can copy text from some apps.
        if VoiceAnnotationService.shared.isMicrophoneAuthorized {
            do {
                try VoiceAnnotationService.shared.startRecording()
            } catch {
                Diag.log("voice recording failed: \(error.localizedDescription)")
            }
        }
        let captured = SelectionCapture.capture()
        presentVoice(captured)
        if VoiceAnnotationService.shared.isRecording {
            voiceModel?.state = .recording
        } else {
            startVoiceRecording()
        }
    }

    func endVoiceCapture() {
        voiceKeyIsHeld = false
        guard voicePanel != nil, voiceModel != nil else { return }

        guard VoiceAnnotationService.shared.isRecording else { return }
        finishVoiceCapture()
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

    private func presentVoice(_ captured: CapturedSelection) {
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let model = VoiceCaptureModel(captured: captured)
        voiceModel = model
        panel.contentView = NSHostingView(rootView: VoiceCaptureView(model: model))
        position(panel, near: captured.screenRect)
        voicePanel = panel
        installVoiceKeyMonitor()

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

    private func installVoiceKeyMonitor() {
        voiceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.voicePanel, event.window === panel else { return event }
            if event.keyCode == 53 { // escape
                self.dismissVoice(returnFocus: true)
                return nil
            }
            return event
        }
    }

    // MARK: - Finish

    private func startVoiceRecording() {
        guard let voiceModel else { return }
        voiceModel.state = .idle
        voiceStartTask?.cancel()

        if VoiceAnnotationService.shared.isMicrophoneAuthorized {
            do {
                try VoiceAnnotationService.shared.startRecording()
                voiceModel.state = .recording
            } catch {
                voiceModel.state = .failed(error.localizedDescription)
                Diag.log("voice recording failed: \(error.localizedDescription)")
            }
            return
        }

        voiceStartTask = Task { [weak self, weak voiceModel] in
            guard let self, let voiceModel else { return }
            guard await VoiceAnnotationService.shared.requestMicrophoneAccess() else {
                guard self.voiceModel === voiceModel, self.voicePanel != nil else { return }
                voiceModel.state = .failed("Microphone access is not allowed.")
                return
            }
            guard !Task.isCancelled, self.voiceModel === voiceModel, self.voicePanel != nil else { return }
            guard self.voiceKeyIsHeld else {
                voiceModel.state = .failed("Hold the voice shortcut again to record.")
                return
            }

            do {
                try VoiceAnnotationService.shared.startRecording()
                guard self.voiceModel === voiceModel, self.voicePanel != nil else {
                    VoiceAnnotationService.shared.discardRecording()
                    return
                }
                voiceModel.state = .recording
            } catch {
                guard self.voiceModel === voiceModel, self.voicePanel != nil else { return }
                voiceModel.state = .failed(error.localizedDescription)
                Diag.log("voice recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func finishVoiceCapture() {
        guard let voiceModel, voicePanel != nil, VoiceAnnotationService.shared.isRecording else { return }
        voiceModel.state = .transcribing
        voiceFinishTask?.cancel()

        voiceFinishTask = Task { [weak self, weak voiceModel] in
            guard let self, let voiceModel else { return }

            // This tells the user why their first annotation takes longer.
            if !(await VoiceAnnotationService.shared.isVoiceModelReady()) {
                guard self.voiceModel === voiceModel, self.voicePanel != nil else { return }
                voiceModel.state = .preparingModel
            }

            do {
                let transcript = try await VoiceAnnotationService.shared.stopAndTranscribe()
                guard self.voiceModel === voiceModel, self.voicePanel != nil else { return }
                guard !transcript.isEmpty else {
                    voiceModel.state = .failed("No speech was found.")
                    return
                }

                AnnotationStore.shared.add(
                    Annotation(
                        quote: voiceModel.captured.text,
                        note: transcript,
                        sourceApp: voiceModel.captured.appName,
                        sourceURL: nil
                    )
                )
                Diag.log("saved voice annotation, note=\(transcript.prefix(30).debugDescription)")
                self.dismissVoice(returnFocus: true)
            } catch {
                guard self.voiceModel === voiceModel, self.voicePanel != nil else { return }
                voiceModel.state = .failed(error.localizedDescription)
                Diag.log("voice transcription failed: \(error.localizedDescription)")
            }
        }
    }

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

    private func dismissVoice(returnFocus: Bool) {
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceFinishTask?.cancel()
        voiceFinishTask = nil
        VoiceAnnotationService.shared.discardRecording()
        voiceKeyIsHeld = false
        if let voiceKeyMonitor { NSEvent.removeMonitor(voiceKeyMonitor) }
        voiceKeyMonitor = nil
        voicePanel?.orderOut(nil)
        voicePanel?.contentView = nil
        voicePanel = nil
        voiceModel = nil

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
