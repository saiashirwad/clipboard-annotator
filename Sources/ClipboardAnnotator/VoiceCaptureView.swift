import SwiftUI

/// A short-lived status panel for press-and-hold voice annotations.
struct VoiceCaptureView: View {
    @ObservedObject var model: VoiceCaptureModel

    var body: some View {
        VStack(spacing: 14) {
            if case let .failed(message) = model.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                Text("Press Escape to close")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VoiceWaveform(active: model.state != .idle)
                Text(statusText)
                    .font(.headline)
                Text("Press Escape to cancel")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(22)
        .background(.regularMaterial)
        .ignoresSafeArea()
    }

    private var statusText: String {
        switch model.state {
        case .recording:
            return "Listening…"
        case .preparingModel:
            return "Preparing the voice model…"
        case .transcribing:
            return "Transcribing…"
        case .idle, .failed:
            return "Starting voice annotation…"
        }
    }
}

private struct VoiceWaveform: View {
    let active: Bool
    @State private var animate = false

    private let heights: [CGFloat] = [18, 32, 48, 36, 56, 30, 20]

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(heights.indices, id: \.self) { index in
                bar(at: index)
            }
        }
        .frame(height: 58)
        .onAppear { animate = true }
        .onChange(of: active) { _, isActive in
            animate = isActive
        }
    }

    private func bar(at index: Int) -> some View {
        let duration = 0.48 + Double(index % 3) * 0.12
        let delay = Double(index) * 0.05
        return Capsule()
            .fill(Color.accentColor.gradient)
            .frame(width: 7, height: heights[index])
            .scaleEffect(y: active && animate ? 1 : 0.28, anchor: .center)
            .animation(
                .easeInOut(duration: duration)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: animate
            )
    }
}
