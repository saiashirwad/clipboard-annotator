import AudioToolbox
import AVFoundation
import Foundation
import Observation

/// Live loudness of the chosen microphone, for the level meter on the Voice
/// tab. Runs only while that tab is on screen; nothing is written anywhere.
@MainActor
@Observable
final class InputLevelMonitor {
    /// 0…1 on the same speech-centred scale as `VoiceLevelMeter`.
    private(set) var level: Float = 0
    private(set) var isRunning = false

    @ObservationIgnored private var engine: AVAudioEngine?

    func start(preferredUID: String?) {
        stop()
        guard PermissionCheck.isMicrophoneAuthorized else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device = InputDeviceChoice.resolve(
            preferredUID: preferredUID,
            available: AudioInputDeviceQuery.allInputs()
        ) {
            _ = AudioInputDeviceQuery.select(device, on: input)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            let sample = VoiceLevelMeter.level(of: buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Rise instantly, fall gently, like the system meter.
                self.level = max(sample, self.level * 0.82)
            }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Diag.log("input level monitor failed to start: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        isRunning = true
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRunning = false
        level = 0
    }
}
