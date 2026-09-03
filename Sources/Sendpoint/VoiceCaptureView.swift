import SwiftUI

/// The press-and-hold voice overlay: a dark glass capsule with a live
/// waveform while the microphone is open, and a travelling wave while the
/// transcript is being made.
struct VoiceCaptureView: View {
    @Bindable var model: VoiceCaptureModel
    let meter: VoiceLevelMeter
    let shortcut: KeyCombo

    init(
        model: VoiceCaptureModel,
        meter: VoiceLevelMeter,
        shortcut: KeyCombo = .optionSpace
    ) {
        self.model = model
        self.meter = meter
        self.shortcut = shortcut
    }

    var body: some View {
        HStack(spacing: 12) {
            indicator
            Waveform(mode: waveformMode, samples: meter.samples)
                .frame(width: 128, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isFailure ? Color.orange : Color.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .frame(height: 54)
        .background(Capsule().fill(.regularMaterial))
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
        .padding(28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice note: \(title)")
        .accessibilityValue(subtitle ?? "")
    }

    // MARK: - Indicator

    @ViewBuilder
    private var indicator: some View {
        switch model.phase {
        case .recording, .selecting, .starting:
            PulsingDot(color: .red)
        case .transcribing:
            SpinningArc()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18, height: 18)
        case .dismissed:
            Color.clear.frame(width: 18, height: 18)
        }
    }

    // MARK: - Copy

    // Reading the selection happens while the microphone is already open, so
    // the overlay never mentions it: from the user's side it is all listening.
    private var waveformMode: Waveform.Mode {
        switch model.phase {
        case .recording, .selecting(_, recordingStarted: true): .live
        case .transcribing: .busy
        case .failed: .flat
        case .selecting, .starting, .dismissed: .idle
        }
    }

    private var title: String {
        switch model.phase {
        case .selecting, .starting, .recording: "Listening"
        case .transcribing(.preparingModel): "Preparing voice model"
        case .transcribing(.transcribing): "Transcribing"
        case let .failed(message, _): message
        case .dismissed: ""
        }
    }

    private var subtitle: String? {
        switch model.phase {
        case .selecting, .starting, .recording:
            model.isLatched
                ? "Tap \(shortcut.displayString) again to save · Esc to discard"
                : "Release to save · Esc to discard"
        case .transcribing(.preparingModel): "First time only"
        case .transcribing(.transcribing): "Saving to your stack"
        case .failed, .dismissed: nil
        }
    }

    private var isFailure: Bool {
        if case .failed = model.phase { return true }
        return false
    }
}

/// Bars that scroll with live loudness, ripple while waiting, and sweep
/// while busy.
private struct Waveform: View {
    enum Mode: Equatable {
        case idle
        case live
        case busy
        case flat
    }

    let mode: Mode
    let samples: [Float]

    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: mode == .flat)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                let count = Int((size.width + gap) / (barWidth + gap))
                let heights = barHeights(count: count, time: time)
                for (index, fraction) in heights.enumerated() {
                    let height = max(3, size.height * CGFloat(fraction))
                    let x = CGFloat(index) * (barWidth + gap)
                    let rect = CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    canvas.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color(for: index, of: count, fraction: fraction))
                    )
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: samples)
    }

    private func barHeights(count: Int, time: TimeInterval) -> [Double] {
        switch mode {
        case .live:
            let recent = samples.suffix(count)
            let padding = Array(repeating: Float(0), count: max(0, count - recent.count))
            return (padding + recent).map { level in
                let shaped = pow(Double(level), 1.15)
                return 0.12 + 0.88 * shaped
            }
        case .idle:
            return (0..<count).map { index -> Double in
                let phase: Double = time * 2.4 + Double(index) * 0.45
                let ripple: Double = (1 + sin(phase)) / 2
                return 0.12 + 0.05 * ripple
            }
        case .busy:
            let center: Double = Double(count - 1) / 2
            let spread: Double = Double(count) * 0.32
            return (0..<count).map { index -> Double in
                let position: Double = Double(index)
                let phase: Double = time * 5.5 - position * 0.42
                let wave: Double = (1 + sin(phase)) / 2
                let distance: Double = (position - center) / spread
                let envelope: Double = exp(-(distance * distance))
                return 0.12 + 0.7 * wave * envelope
            }
        case .flat:
            return Array(repeating: 0.12, count: count)
        }
    }

    private func color(for index: Int, of count: Int, fraction: Double) -> Color {
        switch mode {
        case .live:
            return Color.white.opacity(0.45 + 0.55 * fraction)
        case .busy:
            return Color.white.opacity(0.35 + 0.6 * fraction)
        case .idle:
            return Color.white.opacity(0.35)
        case .flat:
            return Color.orange.opacity(0.6)
        }
    }
}

private struct PulsingDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = (1 + sin(t * 3.2)) / 2
            ZStack {
                Circle()
                    .fill(color.opacity(0.28 * (1 - pulse)))
                    .frame(width: 18, height: 18)
                    .scaleEffect(0.6 + 0.6 * pulse)
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
            }
            .frame(width: 18, height: 18)
        }
    }
}

private struct SpinningArc: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.68)
                .stroke(
                    AngularGradient(
                        colors: [.white.opacity(0), .white],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees((t * 220).truncatingRemainder(dividingBy: 360)))
                .frame(width: 18, height: 18)
        }
    }
}
