import AppKit
import SwiftUI

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var noteFocused: Bool

    private let collapsedLimit = 600

    private var quote: String {
        model.captured.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shownQuote: String {
        guard !model.expanded, quote.count > collapsedLimit else { return quote }
        return String(quote.prefix(collapsedLimit)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if quote.isEmpty {
                Text("No text selected — this will be saved as a standalone note.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                quoteBlock
            }

            noteEditor

            footer
        }
        .padding(14)
        .background(.regularMaterial)
        .onAppear {
            DispatchQueue.main.async { noteFocused = true }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            Text(model.captured.appName ?? "Selection")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if !quote.isEmpty {
                Text("· \(quote.count) chars")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if model.stackCount > 0 {
                Text("\(model.stackCount) in stack")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var quoteBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: 3)
                    Text(shownQuote)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }
            .frame(maxHeight: model.expanded ? 220 : 110)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))

            if quote.count > collapsedLimit {
                Button(model.expanded ? "Show less" : "Show all \(quote.count) characters") {
                    model.expanded.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.note)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .focused($noteFocused)
                .frame(minHeight: 80)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(noteFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1),
                                      lineWidth: 1)
                )

            if model.note.isEmpty {
                Text("What do you make of this? Dictate or type…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("⎋ cancel")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Save  ⌘↩", action: onSave)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var appIcon: NSImage? {
        guard let bundleID = model.captured.appBundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        return app.icon
    }
}
