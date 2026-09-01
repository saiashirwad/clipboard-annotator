import Foundation
import Observation

@MainActor
@Observable
final class VoiceCaptureModel {
    private(set) var lifecycle: VoiceCaptureLifecycle
    private(set) var target: AnnotationCaptureTarget?

    var phase: VoiceCapturePhase { lifecycle.phase }
    var identity: VoiceCaptureIdentity { lifecycle.identity }
    var captured: CapturedSelection? { target?.captured }

    init(context: AnnotationCaptureContext) {
        lifecycle = VoiceCaptureLifecycle(identity: VoiceCaptureIdentity(
            captureID: context.captureID,
            annotationID: context.annotationID,
            sessionID: context.sessionID
        ))
    }

    func setCapturedSelection(_ captured: CapturedSelection, context: AnnotationCaptureContext) {
        guard target == nil,
              context.captureID == identity.captureID,
              context.annotationID == identity.annotationID,
              context.sessionID == identity.sessionID
        else { return }
        target = context.target(captured: captured)
    }

    func recordingStarted() -> VoiceCaptureAction {
        lifecycle.recordingStarted(for: identity)
    }

    func selectionCompleted() -> VoiceCaptureAction {
        lifecycle.selectionCompleted(for: identity)
    }

    func release() -> VoiceCaptureAction {
        lifecycle.release(for: identity)
    }

    func modelPreparationBegan() {
        lifecycle.modelPreparationBegan(for: identity)
    }

    @discardableResult
    func fail(message: String, failureID: UUID) -> VoiceCaptureAction {
        lifecycle.fail(for: identity, message: message, failureID: failureID)
    }

    func transcriptionSucceeded() -> VoiceCaptureAction {
        lifecycle.transcriptionSucceeded(for: identity)
    }

    func failureTimeout(failureID: UUID) -> VoiceCaptureAction {
        lifecycle.failureTimeout(for: identity, failureID: failureID)
    }

    func cancel() -> VoiceCaptureAction {
        lifecycle.cancel()
    }
}
