import SwiftUI

/// A compact status panel for press-and-hold voice annotations.
struct VoiceCaptureView: View {
    @Bindable var model: VoiceCaptureModel

    var body: some View {
        HStack(spacing: 9) {
            statusIcon
            Text(statusText)
                .font(.footnote)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(isFailure ? Color.orange : Color.primary)
        }
        .frame(width: 184, alignment: .leading)
        .frame(minHeight: 34)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .accessibilityLabel("Voice annotation: \(statusText)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.phase {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .transcribing(.preparingModel):
            ProgressView()
                .controlSize(.small)
        case .transcribing:
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
        case .selecting, .starting:
            ProgressView()
                .controlSize(.small)
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
        case .dismissed:
            EmptyView()
        }
    }

    private var statusText: String {
        switch model.phase {
        case .selecting:
            return "Reading selection…"
        case .starting:
            return "Starting microphone…"
        case .recording:
            return "Listening… Release to save."
        case .transcribing(.preparingModel):
            return "Preparing voice model…"
        case .transcribing(.transcribing):
            return "Transcribing…"
        case let .failed(message, _):
            return message
        case .dismissed:
            return ""
        }
    }

    private var isFailure: Bool {
        if case .failed = model.phase { return true }
        return false
    }
}
