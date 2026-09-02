import AppKit
import SwiftUI

/// The typed capture draft and its inline save recovery controls.
struct CaptureView: View {
    @Bindable var model: CaptureModel
    let onRetry: () -> Void
    let onSaveToCurrentSession: () -> Void
    let onDiscard: () -> Void

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
            saveStatus
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
                .disabled(model.isNoteFrozen)

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
    private var saveStatus: some View {
        switch model.savePhase {
        case .editing, .dismissed:
            EmptyView()
        case .pendingCommit:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case let .retryableCommitFailure(_, message):
            statusRow(message: message, color: .red) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        case let .targetUnavailable(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Save to Current Session", action: onSaveToCurrentSession)
                        .buttonStyle(.borderedProminent)
                    Button("Discard", role: .destructive, action: onDiscard)
                }
            }
        case let .terminalSaveFailure(message):
            statusRow(message: message, color: .red) {
                Button("Discard", role: .destructive, action: onDiscard)
            }
        case .committed:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        }
    }

    private func statusRow<Actions: View>(
        message: String,
        color: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.callout)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
    }
}
