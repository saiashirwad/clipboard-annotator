import AppKit
import ClipboardAnnotatorDomain
import SwiftUI

/// A floating panel that can take keyboard focus and, crucially, does **not**
/// hide when another app takes over. That is what lets Wispr Flow, Hex, or any
/// other dictation tool run on top of it while the note field stays alive.
final class CapturePanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        guard let onClose else {
            super.performClose(sender)
            return
        }
        self.onClose = nil
        onClose()
    }
}

@MainActor
final class CaptureController {
    private var panel: CapturePanel?
    private var model: CaptureModel?
    private var keyMonitor: Any?
    private var voicePanel: CapturePanel?
    private var voiceModel: VoiceCaptureModel?
    private var voiceKeyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var voiceStartupTask: Task<Void, Never>?
    private var voiceTranscriptionTask: Task<Void, Never>?
    private var voiceFailureTask: Task<Void, Never>?
    private let provenanceProbe: ProvenanceProbe
    private lazy var provenanceWork = PendingProvenanceWorkOwner(
        probe: provenanceProbe,
        lateUpdate: { [weak self] mutation in self?.applyLateProvenance(mutation) }
    )

    private enum Lifecycle {
        case awaitingStore
        case ready(AnnotationStore)
        case tornDown
    }

    private let panelWidth: CGFloat = 460
    private let panelHeight: CGFloat = 340
    private let settings: AppSettings
    private let permissionState: PermissionState
    var onAccessibilityRequired: (() -> Void)?
    var onStatusChange: (() -> Void)?
    private var lifecycle: Lifecycle = .awaitingStore

    private var store: AnnotationStore? {
        guard case let .ready(store) = lifecycle else { return nil }
        return store
    }

    init(
        settings: AppSettings,
        permissionState: PermissionState,
        provenanceProbe: ProvenanceProbe = .live()
    ) {
        self.settings = settings
        self.permissionState = permissionState
        self.provenanceProbe = provenanceProbe
    }

    func configure(store: AnnotationStore) {
        switch lifecycle {
        case .awaitingStore:
            lifecycle = .ready(store)
        case let .ready(existingStore):
            precondition(existingStore === store, "CaptureController cannot change stores")
        case .tornDown:
            break
        }
    }

    var isOpen: Bool { panel != nil || voiceModel != nil }

    func beginCapture() {
        guard let store, !store.isTornDown else { NSSound.beep(); return }
        if isOpen {
            // Second press while open: just bring it back to the front.
            NSApp.activate(ignoringOtherApps: true)
            (panel ?? voicePanel)?.makeKeyAndOrderFront(nil)
            return
        }

        guard permissionState.isTextCaptureReady else {
            onAccessibilityRequired?()
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        let context = AnnotationCaptureContext(sessionID: store.currentSessionID)
        let captured = SelectionCapture.capture()
        let target = context.target(captured: captured)
        provenanceWork.start(for: target)
        present(target)
    }

    /// Starts a capture and a microphone recording together. `endVoiceCapture`
    /// is called by the matching global-hotkey release event.
    func beginVoiceCapture() {
        guard let store, !store.isTornDown else { NSSound.beep(); return }
        guard permissionState.isTextCaptureReady else {
            onAccessibilityRequired?()
            return
        }

        if isOpen {
            NSSound.beep()
            return
        }

        let context = AnnotationCaptureContext(sessionID: store.currentSessionID)
        let model = VoiceCaptureModel(context: context)

        // Install the lifecycle owner before selection capture. The clipboard
        // fallback runs the main run loop, so the matching key-up can arrive
        // while this synchronous call is still in progress.
        voiceModel = model
        previousApp = NSWorkspace.shared.frontmostApplication

        var recordingStartError: Error?
        if VoiceAnnotationService.shared.isMicrophoneAuthorized {
            let identity = model.identity
            do {
                try VoiceAnnotationService.shared.startRecording()
                guard isCurrentVoiceCapture(model, identity: identity),
                      case .selecting = model.phase
                else {
                    VoiceAnnotationService.shared.discardRecording()
                    return
                }
                _ = model.recordingStarted()
            } catch {
                recordingStartError = error
            }
        }

        let captured = SelectionCapture.capture()
        guard voiceModel === model, model.phase != .dismissed else {
            VoiceAnnotationService.shared.discardRecording()
            return
        }

        model.setCapturedSelection(captured, context: context)
        if let target = model.target {
            provenanceWork.start(for: target)
        }
        presentVoice(model)
        let selectionAction = model.selectionCompleted()

        if let recordingStartError {
            Diag.log("voice recording failed: \(recordingStartError.localizedDescription)")
            showVoiceFailure("Couldn’t start recording.", for: model)
            return
        }

        runVoiceAction(selectionAction, for: model)
        if case .starting = model.phase {
            startVoiceRecording(for: model)
        }
    }

    func endVoiceCapture() {
        guard let model = voiceModel else { return }
        runVoiceAction(model.release(), for: model)
    }

    private func present(_ target: AnnotationCaptureTarget) {
        let captured = target.captured
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.onClose = { [weak self] in self?.dismiss(returnFocus: true) }
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

        let model = CaptureModel(target: target)
        self.model = model
        let view = CaptureView(
            model: model,
            onRetry: { [weak self] in self?.retryTypedSave() },
            onSaveToCurrentSession: { [weak self] in self?.saveTypedCaptureToCurrentSession() },
            onDiscard: { [weak self] in self?.discardTypedCapture() }
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

    private func presentVoice(_ model: VoiceCaptureModel) {
        guard let captured = model.captured else { return }
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.onClose = { [weak self] in self?.teardownVoice(returnFocus: true) }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: VoiceCaptureView(
            model: model,
            meter: VoiceAnnotationService.shared.levelMeter
        ))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        positionVoiceOverlay(panel, for: captured)
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

    private func positionVoiceOverlay(_ panel: NSPanel, for captured: CapturedSelection) {
        let screen = captured.screenRect.flatMap(screenContaining(quartzRect:))
            ?? screenContaining(point: NSEvent.mouseLocation)
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        // The overlay view carries its own shadow padding, so sit a little
        // lower than the capsule should visually land.
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 4
        )
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
                if self.model?.canBeginCommit == true {
                    self.commit()
                }
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
                self.teardownVoice(returnFocus: true)
                return nil
            }
            return event
        }
    }

    // MARK: - Finish

    private func startVoiceRecording(for model: VoiceCaptureModel) {
        guard isCurrentVoiceCapture(model),
              case .starting = model.phase
        else { return }

        voiceStartupTask?.cancel()

        if VoiceAnnotationService.shared.isMicrophoneAuthorized {
            startAuthorizedVoiceRecording(for: model)
            return
        }

        let identity = model.identity
        voiceStartupTask = Task { [weak self, weak model] in
            guard let self, let model else { return }
            let allowed = await VoiceAnnotationService.shared.requestMicrophoneAccess()
            guard !Task.isCancelled,
                  self.isCurrentVoiceCapture(model, identity: identity),
                  case .starting = model.phase
            else { return }
            self.voiceStartupTask = nil

            guard allowed else {
                self.showVoiceFailure("Microphone access is not allowed.", for: model)
                return
            }
            self.startAuthorizedVoiceRecording(for: model)
        }
    }

    private func startAuthorizedVoiceRecording(for model: VoiceCaptureModel) {
        guard isCurrentVoiceCapture(model),
              case .starting = model.phase
        else { return }

        let identity = model.identity
        do {
            try VoiceAnnotationService.shared.startRecording()
            guard isCurrentVoiceCapture(model, identity: identity),
                  case .starting = model.phase
            else {
                VoiceAnnotationService.shared.discardRecording()
                return
            }
            runVoiceAction(model.recordingStarted(), for: model)
        } catch {
            Diag.log("voice recording failed: \(error.localizedDescription)")
            showVoiceFailure("Couldn’t start recording.", for: model)
        }
    }

    private func runVoiceAction(_ action: VoiceCaptureAction, for model: VoiceCaptureModel) {
        guard voiceModel === model else { return }
        switch action {
        case .beginTranscription:
            guard isCurrentVoiceCapture(model) else { return }
            finishVoiceCapture(for: model)
        case .dismiss:
            teardownVoice(returnFocus: true)
        case .none, .saveAndDismiss:
            break
        }
    }

    private func finishVoiceCapture(for model: VoiceCaptureModel) {
        guard isCurrentVoiceCapture(model),
              case .transcribing = model.phase,
              voiceTranscriptionTask == nil
        else { return }

        voiceStartupTask?.cancel()
        voiceStartupTask = nil
        let identity = model.identity

        voiceTranscriptionTask = Task { [weak self, weak model] in
            guard let self, let model else { return }

            let modelIsReady = await VoiceAnnotationService.shared.isVoiceModelReady()
            guard !Task.isCancelled,
                  self.isCurrentVoiceCapture(model, identity: identity),
                  case .transcribing = model.phase
            else { return }
            if !modelIsReady {
                model.modelPreparationBegan()
            }

            do {
                let transcript = try await VoiceAnnotationService.shared.stopAndTranscribe()
                guard !Task.isCancelled,
                      self.isCurrentVoiceCapture(model, identity: identity),
                      case .transcribing = model.phase,
                      let target = model.target,
                      self.target(target, matches: identity)
                else { return }
                guard let note = transcript.nonblank else {
                    self.voiceTranscriptionTask = nil
                    self.showVoiceFailure("No speech was found.", for: model)
                    return
                }

                guard let annotation = CaptureAnnotationPolicy.annotation(
                    for: target,
                    note: note
                ) else {
                    self.voiceTranscriptionTask = nil
                    self.showVoiceFailure("No speech was found.", for: model)
                    return
                }
                guard let store = self.store, !store.isTornDown else {
                    self.teardownVoice(returnFocus: true)
                    return
                }
                guard store.sessions.contains(where: { $0.id == identity.sessionID }) else {
                    self.voiceTranscriptionTask = nil
                    self.showVoiceFailure("The original session is no longer available.", for: model)
                    return
                }
                guard model.transcriptionSucceeded() == .saveAndDismiss else { return }

                let savedAnnotation = self.provenanceWork.annotationForSave(
                    annotation,
                    target: target
                )
                self.voiceTranscriptionTask = nil
                store.mutate(.addAnnotation(
                    sessionID: identity.sessionID,
                    annotation: savedAnnotation
                ))
                Diag.log("saved voice annotation")
                self.teardownVoice(returnFocus: true)
            } catch is CancellationError {
                // The one teardown path owns cleanup after cancellation.
            } catch {
                guard !Task.isCancelled,
                      self.isCurrentVoiceCapture(model, identity: identity),
                      case .transcribing = model.phase
                else { return }
                self.voiceTranscriptionTask = nil
                Diag.log("voice transcription failed: \(error.localizedDescription)")
                self.showVoiceFailure("Couldn’t transcribe that audio.", for: model)
            }
        }
    }

    private func showVoiceFailure(_ message: String, for model: VoiceCaptureModel) {
        guard isCurrentVoiceCapture(model) else { return }
        let failureID = UUID()
        model.fail(message: message, failureID: failureID)

        guard case let .failed(_, currentFailureID) = model.phase,
              currentFailureID == failureID
        else { return }

        voiceStartupTask?.cancel()
        voiceStartupTask = nil
        voiceTranscriptionTask?.cancel()
        voiceTranscriptionTask = nil
        VoiceAnnotationService.shared.discardRecording()
        voiceFailureTask?.cancel()

        let identity = model.identity
        voiceFailureTask = Task { [weak self, weak model] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled,
                  let self, let model,
                  self.isCurrentVoiceCapture(model, identity: identity)
            else { return }
            self.voiceFailureTask = nil
            self.runVoiceAction(model.failureTimeout(failureID: failureID), for: model)
        }
    }

    private func isCurrentVoiceCapture(
        _ model: VoiceCaptureModel,
        identity: VoiceCaptureIdentity? = nil
    ) -> Bool {
        guard voiceModel === model, model.phase != .dismissed else { return false }
        if let identity, model.identity != identity { return false }
        if let target = model.target, !self.target(target, matches: model.identity) { return false }
        return true
    }

    private func target(_ target: AnnotationCaptureTarget, matches identity: VoiceCaptureIdentity) -> Bool {
        target.captureID == identity.captureID
            && target.annotationID == identity.annotationID
            && target.sessionID == identity.sessionID
    }

    /// Saves the panel that is actually on screen. Nothing else can trigger it.
    private func commit() {
        guard let model, panel != nil,
              model.canBeginCommit,
              let annotation = CaptureAnnotationPolicy.annotation(
                for: model.target,
                note: model.note
              ),
              let store,
              !store.isTornDown
        else {
            NSSound.beep()
            return
        }

        let savedAnnotation = provenanceWork.annotationForSave(
            annotation,
            target: model.target
        )
        guard let request = model.beginCommit(
            annotation: savedAnnotation,
            destinationSessionID: model.target.sessionID
        ) else {
            NSSound.beep()
            return
        }
        enqueueTypedSave(request, model: model, store: store)
    }

    private func retryTypedSave() {
        guard let model, panel != nil,
              let store, !store.isTornDown,
              model.retryPendingCommit()
        else {
            NSSound.beep()
            return
        }
        store.retryPendingMutations()
        onStatusChange?()
    }

    private func saveTypedCaptureToCurrentSession() {
        guard let model, panel != nil,
              let store, !store.isTornDown
        else {
            NSSound.beep()
            return
        }

        guard let request = model.beginRetarget(
            destinationSessionID: store.currentSessionID
        ) else {
            NSSound.beep()
            return
        }
        // This is the only retarget path. Stop the old provenance route before
        // using the same frozen annotation in the current committed session.
        provenanceWork.abandon(for: model.target)
        enqueueTypedSave(request, model: model, store: store)
    }

    private func discardTypedCapture() {
        guard let model, panel != nil,
              model.discard() == .abandonProvenance
        else {
            NSSound.beep()
            return
        }
        provenanceWork.abandon(for: model.target)
        dismiss(returnFocus: true)
        onStatusChange?()
    }

    private func enqueueTypedSave(
        _ request: CaptureSaveRequest,
        model: CaptureModel,
        store: AnnotationStore
    ) {
        store.mutate(.addAnnotation(
            sessionID: request.identity.destinationSessionID,
            annotation: request.annotation
        ), outcome: { [weak self, weak store, model] outcome in
            guard let self else { return }
            let destinationStillExists = store?.sessions.contains {
                $0.id == request.identity.destinationSessionID
            } ?? false
            let action = model.receive(
                outcome,
                for: request.identity,
                destinationStillExists: destinationStillExists
            )
            if CaptureSaveOutcomeRouting.abandonsProvenance(after: outcome) {
                // The exact add left the queue. Abandon its route even if the
                // user already hid the panel and the model ignored the outcome.
                self.provenanceWork.abandon(for: model.target)
            }
            self.onStatusChange?()

            guard self.model === model, self.panel != nil else { return }
            if action == .dismiss {
                Diag.log("saved annotation")
                self.dismiss(returnFocus: true)
            }
        })
        onStatusChange?()
    }

    func dismiss(returnFocus: Bool) {
        if let model,
           model.dismiss() == .abandonProvenance {
            provenanceWork.abandon(for: model.target)
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.onClose = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model = nil

        if returnFocus, settings.restoreFocusAfterSave,
           let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    /// The only voice teardown path. It is safe to call more than once.
    private func teardownVoice(returnFocus: Bool) {
        if let target = voiceModel?.target {
            provenanceWork.cancelBeforeSave(for: target)
        }
        _ = voiceModel?.cancel()
        voiceStartupTask?.cancel()
        voiceStartupTask = nil
        voiceTranscriptionTask?.cancel()
        voiceTranscriptionTask = nil
        voiceFailureTask?.cancel()
        voiceFailureTask = nil
        VoiceAnnotationService.shared.discardRecording()

        if let voiceKeyMonitor { NSEvent.removeMonitor(voiceKeyMonitor) }
        voiceKeyMonitor = nil
        voicePanel?.onClose = nil
        voicePanel?.orderOut(nil)
        voicePanel?.contentView = nil
        voicePanel = nil
        voiceModel = nil

        if returnFocus, settings.restoreFocusAfterSave,
           let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func applyLateProvenance(_ mutation: SessionDocumentMutation) {
        guard let store, !store.isTornDown,
              case let .updateAnnotationProvenance(
                  sessionID,
                  annotationID,
                  expectedApplication,
                  provenance
              ) = mutation,
              provenance.application == expectedApplication,
              let session = store.sessions.first(where: { $0.id == sessionID })
        else { return }

        if let existing = session.entries.first(where: { $0.id == annotationID }),
           existing.provenance.application != expectedApplication {
            return
        }
        // A missing live entry can still be an in-flight add or the exact entry
        // in lastCleared. The Domain mutation resolves both without resurrection.
        store.mutate(mutation)
    }

    /// Cancels every task and closes every panel owned by this controller.
    func teardown() {
        if case .tornDown = lifecycle { return }
        lifecycle = .tornDown
        onAccessibilityRequired = nil
        onStatusChange = nil
        provenanceWork.teardown()
        dismiss(returnFocus: false)
        teardownVoice(returnFocus: false)
    }
}

extension Notification.Name {
    static let captureWillPresent = Notification.Name("ClipboardAnnotator.captureWillPresent")
}
