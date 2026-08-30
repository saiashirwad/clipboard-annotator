import Combine

@MainActor
final class VoiceCaptureModel: ObservableObject {
    @Published var state: VoiceState = .idle

    let captured: CapturedSelection

    init(captured: CapturedSelection) {
        self.captured = captured
    }
}
