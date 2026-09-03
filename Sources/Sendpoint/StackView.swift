import AppKit
import SendpointDomain
import SwiftUI

struct StackView: View {
    let store: AnnotationStore
    @Bindable var settings: AppSettings
    let onSelectProfile: (UUID) -> Void

    @State private var justCopied = false
    @State private var copyFeedbackID: UUID?

    private var entries: [SendpointDomain.Annotation] { store.currentEntries }
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
            header
            Divider()

            Group {
                if entries.isEmpty && !currentSessionWasCleared {
                    emptyState
                } else if entries.isEmpty {
                    clearedState
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
        .frame(minWidth: 640, minHeight: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .task(id: copyFeedbackID) {
            guard let copyFeedbackID else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard self.copyFeedbackID == copyFeedbackID else { return }
            justCopied = false
            self.copyFeedbackID = nil
        }
    }

    // MARK: - Header

    /// Sits in the title-bar strip: the session as a title, the profile as a
    /// quiet pill, and the one prominent action.
    private var header: some View {
        let renderedSession = store.currentSession
        let renderedSessionID = renderedSession.id

        return HStack(spacing: 10) {
            sessionMenu(renderedSession)

            Spacer(minLength: 12)

            profileMenu

            Button {
                if CurrentSessionExport.copy(store: store, settings: settings) {
                    justCopied = true
                    copyFeedbackID = UUID()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 10, weight: .semibold))
                    Text(justCopied ? "Copied" : "Copy")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .frame(minWidth: 74)
                .background(Capsule().fill(entries.isEmpty ? Color.accentColor.opacity(0.4) : Color.accentColor))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(entries.isEmpty)
            .animation(.easeOut(duration: 0.15), value: justCopied)
            .help("Copy this stack as Markdown, shaped by the active template (⇧⌘C)")
        }
        .padding(.leading, 84) // clear of the traffic lights
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(Color.primary.opacity(0.025))
        .id(renderedSessionID)
    }

    private func sessionMenu(_ session: Session) -> some View {
        Menu {
            Section("Stacks") {
                ForEach(facts.sessions) { item in
                    Button {
                        store.mutate(.switchSession(sessionID: item.id))
                    } label: {
                        if item.isCurrent {
                            Label("\(item.name) — \(item.annotationCount) note\(item.annotationCount == 1 ? "" : "s")", systemImage: "checkmark")
                        } else {
                            Text("\(item.name) — \(item.annotationCount) note\(item.annotationCount == 1 ? "" : "s")")
                        }
                    }
                }
            }
            Divider()
            Button("New Stack…", action: createSession)
            Button("Rename “\(session.name)”…") { renameSession(sessionID: session.id) }
            Button("Delete “\(session.name)”…", role: .destructive) {
                deleteSession(sessionID: session.id)
            }
            .disabled(!facts.canDelete)
        } label: {
            HStack(spacing: 6) {
                Text(session.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch, create, rename, or delete stacks")
    }

    private var profileMenu: some View {
        Menu {
            ForEach(settings.profiles) { profile in
                Button {
                    onSelectProfile(profile.id)
                } label: {
                    if profile.id == settings.activeProfileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                Text(settings.activeProfile.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Active template")
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
                    Text("Hold")
                    Keycap(settings.voiceCaptureCombo.displayString, size: 12)
                    Text("to speak and release to save, or tap it once to start and again to save")
                }
                HStack(spacing: 5) {
                    Text("Or press")
                    Keycap(settings.captureCombo.displayString, size: 12)
                    Text("to type a note about selected text")
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
                Text("\(undoCount) note\(undoCount == 1 ? "" : "s") set aside.")
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
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
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
        .safeAreaPadding(.vertical, 10)
        // macOS 26 extends the list's scroll view up under the title-bar
        // strip where the header lives, so scrolled rows would otherwise
        // paint over the header and the traffic lights.
        .clipped()
    }

    // MARK: - Footer

    private var footer: some View {
        let renderedSession = store.currentSession
        let renderedSessionID = renderedSession.id

        return HStack(spacing: 6) {
            Text("\(entries.count) note\(entries.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            if let undo = facts.undo {
                Button {
                    store.mutate(.undoClear)
                } label: {
                    Label(undo.title, systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: [.command])
            }

            Button {
                store.mutate(.clearSession(sessionID: renderedSessionID))
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [.control, .command])
            .disabled(entries.isEmpty)
            .help("Clear this stack. Undo with ⌘Z.")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Color.primary.opacity(0.025))
    }

    private func errorBanner(_ error: AnnotationStoreError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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
        .padding(.horizontal, 16)
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
    let entry: SendpointDomain.Annotation
    let onNoteChanged: (String) -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @FocusState private var noteFocused: Bool

    private var quote: String {
        guard case let .selection(quote) = entry.subject else { return "" }
        return quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tint)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))

                Text(entry.provenance.application.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let window = entry.provenance.windowTitle?.nonblank {
                    Text(window)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel("Remove note \(index + 1)")
                .opacity(hovering ? 1 : 0)
            }

            if !quote.isEmpty {
                HighlightedPassage(text: quote)
            }

            TextField(
                quote.isEmpty ? "Write a thought…" : "Add a note about this passage…",
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
            .lineSpacing(2)
            .lineLimit(1...8)
            .focused($noteFocused)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    noteFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A captured passage drawn the way a highlighter marks a page: the tint
/// follows the lines of text instead of boxing them.
private struct HighlightedPassage: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(marked)
            .font(.callout)
            .lineSpacing(5)
            .lineLimit(6)
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var marked: AttributedString {
        var attributed = AttributedString(text)
        attributed.backgroundColor = colorScheme == .dark
            ? Color(red: 1.0, green: 0.80, blue: 0.25).opacity(0.28)
            : Color(red: 1.0, green: 0.86, blue: 0.30).opacity(0.5)
        return attributed
    }
}
