import SwiftUI

/// A short-lived status panel for press-and-hold voice annotations.
struct VoiceCaptureView: View {
    @ObservedObject var model: VoiceCaptureModel

    var body: some View {
        Group {
            if case let .failed(message) = model.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(message)
            } else {
                VoiceWaveform(active: model.state != .idle)
            }
        }
        .frame(width: 170, height: 46)
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .accessibilityLabel("Voice annotation")
    }
}

private struct VoiceWaveform: View {
    let active: Bool
    @State private var animate = false

    private let heights: [CGFloat] = [12, 20, 28, 22, 30, 18, 12]

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(heights.indices, id: \.self) { index in
                bar(at: index)
            }
        }
        .frame(height: 32)
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
