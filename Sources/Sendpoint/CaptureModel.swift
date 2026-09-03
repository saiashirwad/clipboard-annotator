import SendpointDomain
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
    ) -> SendpointDomain.Annotation? {
        guard let note = note.nonblank else { return nil }

        let subject: Subject
        if target.captured.text.nonblank != nil {
            subject = .selection(quote: target.captured.text)
        } else {
            subject = .standalone
        }

        return SendpointDomain.Annotation(
            id: target.annotationID,
            subject: subject,
            note: note,
            provenance: Provenance(application: target.application),
            createdAt: target.createdAt
        )
    }
}

struct CaptureSaveIdentity: Equatable, Sendable {
    let captureID: UUID
    let annotationID: UUID
    let destinationSessionID: UUID
}

enum CaptureSavePhase: Equatable, Sendable {
    case editing
    case pendingCommit(CaptureSaveIdentity)
    case retryableCommitFailure(identity: CaptureSaveIdentity, message: String)
    case targetUnavailable(message: String)
    case terminalSaveFailure(message: String)
    case committed
    case dismissed
}

struct CaptureSaveRequest: Equatable, Sendable {
    let identity: CaptureSaveIdentity
    let annotation: SendpointDomain.Annotation
}

enum CaptureSaveOutcomeAction: Equatable, Sendable {
    case none
    case dismiss
    case abandonProvenance
}

enum CaptureSaveOutcomeRouting {
    static func abandonsProvenance(after outcome: AnnotationStoreMutationOutcome) -> Bool {
        switch outcome {
        case .noOp, .rejected, .cancelled:
            return true
        case .committed, .commitFailed:
            return false
        }
    }
}

/// State for one typed capture, owned by the controller rather than the view.
@MainActor
@Observable
final class CaptureModel {
    private var draftNote = ""
    var note: String {
        get { draftNote }
        set {
            guard case .editing = savePhase else { return }
            draftNote = newValue
        }
    }
    private(set) var savePhase: CaptureSavePhase = .editing
    private(set) var annotation: SendpointDomain.Annotation?

    let target: AnnotationCaptureTarget

    var captured: CapturedSelection { target.captured }

    var isNoteFrozen: Bool {
        if case .editing = savePhase { return false }
        return true
    }

    var canBeginCommit: Bool {
        if case .editing = savePhase { return true }
        return false
    }

    init(target: AnnotationCaptureTarget) {
        self.target = target
    }

    func beginCommit(
        annotation: SendpointDomain.Annotation,
        destinationSessionID: UUID
    ) -> CaptureSaveRequest? {
        guard case .editing = savePhase,
              self.annotation == nil,
              annotation.id == target.annotationID,
              annotation.provenance.application == target.application
        else { return nil }

        self.annotation = annotation
        let request = request(
            annotation: annotation,
            destinationSessionID: destinationSessionID
        )
        savePhase = .pendingCommit(request.identity)
        return request
    }

    func retryPendingCommit() -> Bool {
        guard case let .retryableCommitFailure(identity, _) = savePhase else {
            return false
        }
        savePhase = .pendingCommit(identity)
        return true
    }

    func beginRetarget(destinationSessionID: UUID) -> CaptureSaveRequest? {
        guard case .targetUnavailable = savePhase,
              let annotation
        else { return nil }

        let request = request(
            annotation: annotation,
            destinationSessionID: destinationSessionID
        )
        savePhase = .pendingCommit(request.identity)
        return request
    }

    func receive(
        _ outcome: AnnotationStoreMutationOutcome,
        for identity: CaptureSaveIdentity,
        destinationStillExists: Bool
    ) -> CaptureSaveOutcomeAction {
        guard currentIdentity == identity else { return .none }

        switch outcome {
        case .committed:
            savePhase = .committed
            return .dismiss
        case .noOp:
            savePhase = .terminalSaveFailure(message: "The note wasn’t saved.")
            return .none
        case let .rejected(message):
            let missingDestinationMessage = "That stack was deleted."
            savePhase = destinationStillExists
                ? .terminalSaveFailure(
                    message: "Couldn’t save the note: \(message)"
                )
                : .targetUnavailable(message: missingDestinationMessage)
            return .none
        case let .commitFailed(message):
            savePhase = .retryableCommitFailure(
                identity: identity,
                message: "Couldn’t save the note: \(message)"
            )
            return .none
        case .cancelled:
            savePhase = .terminalSaveFailure(message: "Saving was cancelled.")
            return .none
        }
    }

    func discard() -> CaptureSaveOutcomeAction {
        switch savePhase {
        case .targetUnavailable, .terminalSaveFailure:
            savePhase = .dismissed
        case .editing, .pendingCommit, .retryableCommitFailure, .committed, .dismissed:
            return .none
        }
        return .abandonProvenance
    }

    func dismiss() -> CaptureSaveOutcomeAction {
        let action: CaptureSaveOutcomeAction
        switch savePhase {
        case .editing, .targetUnavailable, .terminalSaveFailure:
            action = .abandonProvenance
        case .pendingCommit, .retryableCommitFailure, .committed:
            action = .none
        case .dismissed:
            return .none
        }
        savePhase = .dismissed
        return action
    }

    private var currentIdentity: CaptureSaveIdentity? {
        switch savePhase {
        case let .pendingCommit(identity), let .retryableCommitFailure(identity, _):
            return identity
        case .editing, .targetUnavailable, .terminalSaveFailure, .committed, .dismissed:
            return nil
        }
    }

    private func request(
        annotation: SendpointDomain.Annotation,
        destinationSessionID: UUID
    ) -> CaptureSaveRequest {
        CaptureSaveRequest(
            identity: CaptureSaveIdentity(
                captureID: target.captureID,
                annotationID: annotation.id,
                destinationSessionID: destinationSessionID
            ),
            annotation: annotation
        )
    }
}
