import AppKit
import ClipboardAnnotatorDomain
import SwiftUI

struct StackView: View {
    let store: AnnotationStore
    @Bindable var settings: AppSettings

    @State private var showingMarkdown = false
    @State private var justCopied = false

    private var entries: [ClipboardAnnotatorDomain.Annotation] { store.currentEntries }
    private var facts: SessionUIFacts {
        SessionUIFacts(
            sessions: store.sessions,
            currentSessionID: store.currentSessionID,
            lastCleared: store.lastCleared
        )
    }
    private var undoCount: Int { facts.undo?.annotationCount ?? 0 }
    private var currentSessionWasCleared: Bool {
        facts.undo?.sessionID == store.currentSessionID
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionBar
            Divider()

            Group {
                if entries.isEmpty && !currentSessionWasCleared {
                    emptyState
                } else if entries.isEmpty {
                    clearedState
                } else if showingMarkdown {
                    markdownPreview
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = store.error {
                Divider()
                errorBanner(error)
            }

            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 340)
    }

    private var sessionBar: some View {
        let renderedSession = store.currentSession
        let renderedSessionID = renderedSession.id

        return HStack(spacing: 8) {
            Picker(
                "Session",
                selection: Binding(
                    get: { store.currentSessionID },
                    set: { store.mutate(.switchSession(sessionID: $0)) }
                )
            ) {
                ForEach(facts.sessions) { session in
                    Text("\(session.name) (\(session.annotationCount))")
                        .tag(session.id)
                }
            }
            .frame(maxWidth: 240)

            Spacer()

            Button("New…", action: createSession)
            Button("Rename…") { renameSession(sessionID: renderedSessionID) }
            Button("Delete…") { deleteSession(sessionID: renderedSessionID) }
                .disabled(!facts.canDelete)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

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
                Text("\(undoCount) annotation\(undoCount == 1 ? "" : "s") set aside.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                store.mutate(.undoClear)
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
        let renderedSession = store.currentSession
        let renderedSessionID = renderedSession.id
        let renderedEntries = renderedSession.entries

        return List {
            ForEach(Array(renderedEntries.enumerated()), id: \.element.id) { index, entry in
                StackRow(
                    index: index,
                    entry: entry,
                    onNoteChanged: { note in
                        store.mutate(.updateAnnotationNote(
                            sessionID: renderedSessionID,
                            annotationID: entry.id,
                            note: note
                        ))
                    },
                    onDelete: {
                        store.mutate(.removeAnnotation(
                            sessionID: renderedSessionID,
                            annotationID: entry.id
                        ))
                    }
                )
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
                .listRowSeparator(.visible)
            }
            .onMove { offsets, destination in
                let ids = renderedEntries.map(\.id)
                for move in AnnotationMoveMapping.moves(
                    annotationIDs: ids,
                    from: offsets,
                    to: destination
                ) {
                    store.mutate(.moveAnnotation(
                        sessionID: renderedSessionID,
                        annotationID: move.annotationID,
                        destinationIndex: move.destinationIndex
                    ))
                }
            }
            .onDelete { offsets in
                let ids = offsets.compactMap {
                    renderedEntries.indices.contains($0) ? renderedEntries[$0].id : nil
                }
                for id in ids {
                    store.mutate(.removeAnnotation(
                        sessionID: renderedSessionID,
                        annotationID: id
                    ))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var markdownPreview: some View {
        ScrollView {
            Text(CurrentSessionExport.markdown(store: store, settings: settings))
                .font(.system(.callout, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    private var footer: some View {
        let renderedSession = store.currentSession
        let renderedSessionID = renderedSession.id

        return HStack(spacing: 8) {
            Text("\(renderedSession.name): \(entries.count) annotation\(entries.count == 1 ? "" : "s")")
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
            .disabled(entries.isEmpty)

            if let undo = facts.undo {
                Button(undo.title) {
                    store.mutate(.undoClear)
                }
                .keyboardShortcut("z", modifiers: [.command])
            }

            Button("Clear \(renderedSession.name)") {
                store.mutate(.clearSession(sessionID: renderedSessionID))
            }
            .keyboardShortcut(.delete, modifiers: [.control, .command])
            .disabled(entries.isEmpty)

            Button {
                if CurrentSessionExport.copy(store: store, settings: settings) {
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
                }
            } label: {
                Label(
                    justCopied ? "Copied" : "Copy Markdown",
                    systemImage: justCopied ? "checkmark" : "doc.on.clipboard"
                )
                .frame(minWidth: 108)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .buttonStyle(.borderedProminent)
            .disabled(entries.isEmpty)
            .animation(.easeOut(duration: 0.15), value: justCopied)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func errorBanner(_ error: AnnotationStoreError) -> some View {
        HStack(spacing: 8) {
            Text(annotationStoreErrorMessage(error))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if store.hasPendingMutations {
                Button("Retry") { store.retryPendingMutations() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private func createSession() {
        let sessions = store.sessions
        guard
            let draft = SessionDialogs.requestNewSessionName(sessions: sessions),
            let name = SessionDialogs.validateForEnqueue(
                draft,
                excluding: nil,
                sessions: store.sessions
            )
        else { return }
        store.mutate(.createSession(Session(name: name)))
    }

    private func renameSession(sessionID: UUID) {
        let sessions = store.sessions
        guard
            let draft = SessionDialogs.requestRenamedSessionName(
                sessionID: sessionID,
                sessions: sessions
            ),
            let name = SessionDialogs.validateForEnqueue(
                draft,
                excluding: sessionID,
                sessions: store.sessions
            )
        else { return }
        store.mutate(.renameSession(sessionID: sessionID, name: name))
    }

    private func deleteSession(sessionID: UUID) {
        let sessions = store.sessions
        guard SessionDialogs.confirmsDelete(
            sessionID: sessionID,
            sessions: sessions,
            lastCleared: store.lastCleared
        ) else { return }
        store.mutate(.deleteSession(sessionID: sessionID))
    }

}

private struct StackRow: View {
    let index: Int
    let entry: ClipboardAnnotatorDomain.Annotation
    let onNoteChanged: (String) -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var quote: String {
        guard case let .selection(quote) = entry.subject else { return "" }
        return quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(Color.primary.opacity(0.07)))

                Text(entry.provenance.application.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

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
                        onNoteChanged(newValue)
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
