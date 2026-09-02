import AVFoundation
import FluidAudio
import Foundation

/// Records one short clip and sends it to the same local Parakeet engine that
/// Hex uses. The model downloads only when the user asks for voice setup or
/// first makes a voice annotation. Neither the audio nor its transcript leaves the Mac.
@MainActor
final class VoiceAnnotationService {
    static let shared = VoiceAnnotationService()

    private let transcriber = LocalVoiceTranscriber()
    private var engine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?

    private init() {}

    var isRecording: Bool { engine?.isRunning == true }

    var isMicrophoneAuthorized: Bool {
        PermissionCheck.isMicrophoneAuthorized
    }

    func isVoiceModelReady() async -> Bool {
        await transcriber.isReady()
    }

    func downloadVoiceModel() async throws {
        try await transcriber.prepare()
    }

    func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func startRecording() throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceAnnotationError.noInputDevice
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-annotation-\(UUID().uuidString).caf")
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                Diag.log("voice audio write failed: \(error.localizedDescription)")
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        self.engine = engine
        recordingFile = file
        recordingURL = url
        Diag.log("voice recording started")
    }

    /// Stops the microphone before starting transcription, so its use stays
    /// limited to the time that the shortcut was held.
    func stopAndTranscribe() async throws -> String {
        try Task.checkCancellation()
        let url = try stopRecording()
        defer { try? FileManager.default.removeItem(at: url) }

        try Task.checkCancellation()
        let modelIsReady = await transcriber.isReady()
        try Task.checkCancellation()
        Diag.log(modelIsReady ? "voice transcription started" : "voice model download started")
        let transcript = try await transcriber.transcribe(url: url)
        try Task.checkCancellation()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func discardRecording() {
        guard isRecording || recordingURL != nil else { return }
        let url = try? stopRecording()
        if let url { try? FileManager.default.removeItem(at: url) }
        Diag.log("voice recording discarded")
    }

    private func stopRecording() throws -> URL {
        guard let engine, let url = recordingURL else {
            throw VoiceAnnotationError.noActiveRecording
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        recordingFile = nil // Flush the audio file before FluidAudio reads it.
        recordingURL = nil
        Diag.log("voice recording stopped")
        return url
    }
}

private enum VoiceAnnotationError: LocalizedError {
    case noInputDevice
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is available."
        case .noActiveRecording:
            return "Voice recording did not start."
        }
    }
}

actor LocalVoiceTranscriber {
    private let preparation = SharedAsyncPreparation<AsrManager>()
    private let modelsAreDownloaded: @Sendable () -> Bool

    init(modelsAreDownloaded: @escaping @Sendable () -> Bool = {
        AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v3),
            version: .v3
        )
    }) {
        self.modelsAreDownloaded = modelsAreDownloaded
    }

    func isReady() async -> Bool {
        await preparation.isPrepared() || modelsAreDownloaded()
    }

    func prepare() async throws {
        _ = try await transcriptionManager()
    }

    func transcribe(url: URL) async throws -> String {
        let manager = try await transcriptionManager()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &decoderState)
        Diag.log("voice transcription finished, chars=\(result.text.count)")
        return result.text
    }

    private func transcriptionManager() async throws -> AsrManager {
        try await preparation.value {
            // Parakeet TDT v3 is Hex's default, multilingual, on-device model.
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            return AsrManager(config: .init(), models: models)
        }
    }
}
