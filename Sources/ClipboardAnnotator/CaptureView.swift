import AppKit
import SwiftUI

/// Just the quote and a box to write in. Esc cancels, ⌘↩ saves; the panel
/// handles both, so nothing here needs a button.
struct CaptureView: View {
    @Bindable var model: CaptureModel
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var noteFocused: Bool
    @State private var quoteHeight: CGFloat = 0

    private let quoteMaxHeight: CGFloat = 150

    private var quote: String {
        model.captured.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !quote.isEmpty {
                quoteBlock
            }
            noteEditor
            voiceStatus
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.async { noteFocused = true }
        }
    }

    private var quoteBlock: some View {
        ScrollView {
            Text(quote)
                .font(.callout)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .overlayScrollers()
        .frame(height: min(max(quoteHeight, 32), quoteMaxHeight))
        .insetSurface()
        .onPreferenceChange(HeightKey.self) { quoteHeight = $0 }
    }

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.note)
                .font(.body)
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
                .focused($noteFocused)
                .frame(minHeight: 84)
                .overlayScrollers()

            if model.note.isEmpty {
                Text("Add a note…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var voiceStatus: some View {
        switch model.voiceState {
        case .idle:
            EmptyView()
        case .recording:
            Label("Listening… Release the shortcut to save.", systemImage: "mic.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        case .preparingModel:
            Label("Downloading the local voice model…", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .font(.footnote)
        case .transcribing:
            Label("Transcribing on this Mac…", systemImage: "waveform")
                .foregroundStyle(.secondary)
                .font(.footnote)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.footnote)
        }
    }
}
