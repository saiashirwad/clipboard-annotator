import AppKit
import SwiftUI

struct StackView: View {
    @ObservedObject var store: AnnotationStore
    @ObservedObject var settings: AppSettings

    @State private var showingMarkdown = false
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if store.entries.isEmpty && store.lastCleared.isEmpty {
                    emptyState
                } else if store.entries.isEmpty {
                    clearedState
                } else if showingMarkdown {
                    markdownPreview
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 340)
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "quote.opening")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)

            VStack(spacing: 5) {
                Text("Nothing captured yet")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 5) {
                    Text("Highlight text in any app, then press")
                    Keycap(settings.captureCombo.displayString, size: 12)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var clearedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)

            VStack(spacing: 5) {
                Text("Stack cleared")
                    .font(.title3.weight(.semibold))
                Text("\(store.lastCleared.count) annotation\(store.lastCleared.count == 1 ? "" : "s") set aside.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                store.undoClear()
            } label: {
                HStack(spacing: 6) {
                    Text("Undo Clear")
                    Keycap("⌘Z")
                }
            }
            .keyboardShortcut("z", modifiers: [.command])
        }
        .padding()
    }

    private var list: some View {
        List {
            ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                StackRow(
                    index: index,
                    entry: entry,
                    onUpdate: { store.update($0) },
                    onDelete: { store.remove(ids: [entry.id]) }
                )
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
                .listRowSeparator(.visible)
            }
            .onMove { store.move(from: $0, to: $1) }
            .onDelete { offsets in
                let ids = Set(offsets.map { store.entries[$0].id })
                store.remove(ids: ids)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var markdownPreview: some View {
        ScrollView {
            Text(store.markdown(includeSource: settings.includeSource, includeHeading: settings.includeHeading))
                .font(.system(.callout, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(store.entries.count) annotation\(store.entries.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Picker("View", selection: $showingMarkdown) {
                Text("List").tag(false)
                Text("Markdown").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(store.entries.isEmpty)

            if !store.lastCleared.isEmpty {
                Button("Undo Clear (\(store.lastCleared.count))") {
                    store.undoClear()
                }
                .keyboardShortcut("z", modifiers: [.command])
            }

            Button("Clear") {
                store.clear()
            }
            .keyboardShortcut(.delete, modifiers: [.control, .command])
            .disabled(store.entries.isEmpty)

            Button {
                if store.copyMarkdownToPasteboard() {
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
                }
            } label: {
                Label(justCopied ? "Copied" : "Copy Markdown",
                      systemImage: justCopied ? "checkmark" : "doc.on.clipboard")
                    .frame(minWidth: 108)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .buttonStyle(.borderedProminent)
            .disabled(store.entries.isEmpty)
            .animation(.easeOut(duration: 0.15), value: justCopied)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

// MARK: - Row

private struct StackRow: View {
    let index: Int
    let entry: Annotation
    let onUpdate: (Annotation) -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var quote: String {
        entry.quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(Color.primary.opacity(0.07)))

                if let app = entry.sourceApp {
                    Text(app)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove")
                .opacity(hovering ? 1 : 0)
            }

            if !quote.isEmpty {
                Text(quote)
                    .font(.callout)
                    .lineSpacing(1)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField(
                "Add a note…",
                text: Binding(
                    get: { entry.note },
                    set: { newValue in
                        var updated = entry
                        updated.note = newValue
                        onUpdate(updated)
                    }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...6)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
