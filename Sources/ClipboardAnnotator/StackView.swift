import AppKit
import SwiftUI

struct StackView: View {
    @ObservedObject var store: AnnotationStore
    @ObservedObject var settings: AppSettings

    @State private var showingMarkdown = false
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty && store.lastCleared.isEmpty {
                emptyState
            } else if store.entries.isEmpty {
                clearedState
            } else if showingMarkdown {
                markdownPreview
            } else {
                list
            }
            Divider()
            toolbar
        }
        .frame(minWidth: 460, minHeight: 340)
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Nothing captured yet")
                .font(.headline)
            Text("Highlight text anywhere, then press \(settings.captureCombo.displayString).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var clearedState: some View {
        VStack(spacing: 10) {
            Text("Stack cleared")
                .font(.headline)
            Text("\(store.lastCleared.count) annotation\(store.lastCleared.count == 1 ? "" : "s") set aside.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Undo Clear") { store.undoClear() }
                .keyboardShortcut("z", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        List {
            ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                row(index: index, entry: entry)
            }
            .onMove { store.move(from: $0, to: $1) }
            .onDelete { offsets in
                let ids = Set(offsets.map { store.entries[$0].id })
                store.remove(ids: ids)
            }
        }
        .listStyle(.inset)
    }

    private func row(index: Int, entry: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                if let app = entry.sourceApp {
                    Text(app).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    store.remove(ids: [entry.id])
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            if !entry.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 3)
                    Text(entry.quote)
                        .font(.callout)
                        .lineLimit(4)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            TextField(
                "Note",
                text: Binding(
                    get: { entry.note },
                    set: { newValue in
                        var updated = entry
                        updated.note = newValue
                        store.update(updated)
                    }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...6)
        }
        .padding(.vertical, 6)
    }

    private var markdownPreview: some View {
        ScrollView {
            Text(store.markdown(includeSource: settings.includeSource, includeHeading: settings.includeHeading))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("\(store.entries.count) annotation\(store.entries.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Toggle("Markdown", isOn: $showingMarkdown)
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(store.entries.isEmpty)

            if !store.lastCleared.isEmpty {
                Button("Undo Clear (\(store.lastCleared.count))") {
                    store.undoClear()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .controlSize(.small)
            }

            Button("Clear") {
                store.clear()
            }
            .keyboardShortcut(.delete, modifiers: [.control, .command])
            .controlSize(.small)
            .disabled(store.entries.isEmpty)

            Button(justCopied ? "Copied ✓" : "Copy Markdown") {
                if store.copyMarkdownToPasteboard() {
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.entries.isEmpty)
        }
        .padding(10)
    }

}
