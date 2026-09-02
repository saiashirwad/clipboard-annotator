import Foundation

struct VoiceCaptureIdentity: Equatable, Sendable {
    let captureID: UUID
    let annotationID: UUID
    let sessionID: UUID
}

enum VoiceTranscriptionStage: Equatable, Sendable {
    case preparingModel
    case transcribing
}

enum VoiceCapturePhase: Equatable, Sendable {
    case selecting(releaseRequested: Bool, recordingStarted: Bool)
    case starting
    case recording
    case transcribing(VoiceTranscriptionStage)
    case failed(message: String, failureID: UUID)
    case dismissed
}

enum VoiceCaptureAction: Equatable, Sendable {
    case none
    case beginTranscription
    case dismiss
    case saveAndDismiss
}

/// A pure state machine for one press-and-hold voice capture.
/// Every delayed event carries the identity of the capture that created it.
struct VoiceCaptureLifecycle: Equatable, Sendable {
    let identity: VoiceCaptureIdentity
    private(set) var phase: VoiceCapturePhase = .selecting(
        releaseRequested: false,
        recordingStarted: false
    )

    mutating func recordingStarted(for eventIdentity: VoiceCaptureIdentity) -> VoiceCaptureAction {
        guard eventIdentity == identity else { return .none }
        switch phase {
        case let .selecting(releaseRequested, _):
            phase = .selecting(releaseRequested: releaseRequested, recordingStarted: true)
            return .none
        case .starting:
            phase = .recording
            return .none
        default:
            return .none
        }
    }

    mutating func selectionCompleted(for eventIdentity: VoiceCaptureIdentity) -> VoiceCaptureAction {
        guard eventIdentity == identity,
              case let .selecting(releaseRequested, recordingStarted) = phase
        else { return .none }

        if recordingStarted {
            if releaseRequested {
                phase = .transcribing(.transcribing)
                return .beginTranscription
            }
            phase = .recording
        } else {
            phase = .starting
        }
        return .none
    }

    mutating func release(for eventIdentity: VoiceCaptureIdentity) -> VoiceCaptureAction {
        guard eventIdentity == identity else { return .none }
        switch phase {
        case .selecting(_, recordingStarted: true):
            phase = .selecting(releaseRequested: true, recordingStarted: true)
            return .none
        case .selecting(_, recordingStarted: false), .starting:
            phase = .dismissed
            return .dismiss
        case .recording:
            phase = .transcribing(.transcribing)
            return .beginTranscription
        case .transcribing, .failed, .dismissed:
            return .none
        }
    }

    mutating func modelPreparationBegan(for eventIdentity: VoiceCaptureIdentity) {
        guard eventIdentity == identity,
              case .transcribing = phase
        else { return }
        phase = .transcribing(.preparingModel)
    }

    @discardableResult
    mutating func fail(
        for eventIdentity: VoiceCaptureIdentity,
        message: String,
        failureID: UUID
    ) -> VoiceCaptureAction {
        guard eventIdentity == identity else { return .none }
        switch phase {
        case .dismissed, .failed:
            return .none
        case .selecting, .starting, .recording, .transcribing:
            phase = .failed(message: message, failureID: failureID)
            return .none
        }
    }

    mutating func transcriptionSucceeded(for eventIdentity: VoiceCaptureIdentity) -> VoiceCaptureAction {
        guard eventIdentity == identity,
              case .transcribing = phase
        else { return .none }
        phase = .dismissed
        return .saveAndDismiss
    }

    mutating func failureTimeout(
        for eventIdentity: VoiceCaptureIdentity,
        failureID: UUID
    ) -> VoiceCaptureAction {
        guard eventIdentity == identity,
              case let .failed(_, currentFailureID) = phase,
              currentFailureID == failureID
        else { return .none }
        phase = .dismissed
        return .dismiss
    }

    mutating func cancel() -> VoiceCaptureAction {
        guard phase != .dismissed else { return .none }
        phase = .dismissed
        return .dismiss
    }
}
