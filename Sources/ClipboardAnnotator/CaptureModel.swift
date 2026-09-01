import ClipboardAnnotatorDomain
import Foundation
import Observation

/// IDs and time captured before selection reading or recording can delay us.
struct AnnotationCaptureContext {
    let captureID: UUID
    let sessionID: UUID
    let annotationID: UUID
    let createdAt: Date

    init(
        sessionID: UUID,
        captureID: UUID = UUID(),
        annotationID: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.captureID = captureID
        self.sessionID = sessionID
        self.annotationID = annotationID
        self.createdAt = createdAt
    }

    func target(captured: CapturedSelection) -> AnnotationCaptureTarget {
        AnnotationCaptureTarget(context: self, captured: captured)
    }
}

/// Immutable values captured when a panel starts. Delayed saves must use this
/// target instead of whichever session or application is current later.
struct AnnotationCaptureTarget {
    let captureID: UUID
    let sessionID: UUID
    let annotationID: UUID
    let captured: CapturedSelection
    let application: ApplicationIdentity
    let createdAt: Date

    init(context: AnnotationCaptureContext, captured: CapturedSelection) {
        self.captureID = context.captureID
        self.sessionID = context.sessionID
        self.annotationID = context.annotationID
        self.captured = captured
        self.application = ApplicationIdentity(
            name: captured.appName?.nonblank ?? "Unknown Application",
            bundleID: captured.appBundleID
        )
        self.createdAt = context.createdAt
    }
}

/// Applies the note policy at the boundary between capture UI and the store.
enum CaptureAnnotationPolicy {
    static func annotation(
        for target: AnnotationCaptureTarget,
        note: String
    ) -> ClipboardAnnotatorDomain.Annotation? {
        guard let note = note.nonblank else { return nil }

        let subject: Subject
        if target.captured.text.nonblank != nil {
            subject = .selection(quote: target.captured.text)
        } else {
            subject = .standalone
        }

        return ClipboardAnnotatorDomain.Annotation(
            id: target.annotationID,
            subject: subject,
            note: note,
            provenance: Provenance(application: target.application),
            createdAt: target.createdAt
        )
    }
}

/// State for one capture, owned by the controller rather than the view.
@MainActor
@Observable
final class CaptureModel {
    var note = ""
    var expanded = false

    let target: AnnotationCaptureTarget
    let stackCount: Int

    var captured: CapturedSelection { target.captured }

    init(target: AnnotationCaptureTarget, stackCount: Int) {
        self.target = target
        self.stackCount = stackCount
    }
}
