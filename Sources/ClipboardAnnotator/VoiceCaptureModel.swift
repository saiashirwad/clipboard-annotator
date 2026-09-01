import Observation

@MainActor
@Observable
final class VoiceCaptureModel {
    var state: VoiceState = .idle

    let target: AnnotationCaptureTarget

    var captured: CapturedSelection { target.captured }

    init(target: AnnotationCaptureTarget) {
        self.target = target
    }
}
