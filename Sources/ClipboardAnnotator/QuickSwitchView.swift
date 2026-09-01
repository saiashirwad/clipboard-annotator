import ClipboardAnnotatorDomain
import SwiftUI

struct QuickSwitchView: View {
    let store: AnnotationStore
    let onSwitch: (UUID) -> Void
    let onClose: () -> Void

    @State private var state = QuickSwitchState()
    @FocusState private var pickerFocused: Bool

    private var facts: SessionUIFacts {
        SessionUIFacts(
            sessions: store.sessions,
            currentSessionID: store.currentSessionID,
            lastCleared: store.lastCleared
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Switch Session")
                .font(.headline)

            Picker("Session", selection: selection) {
                ForEach(facts.sessions) { session in
                    Text("\(session.name)  (\(session.annotationCount))")
                        .tag(session.id)
                }
            }
            .focused($pickerFocused)

            HStack {
                Button("New…", action: createSession)
                Button("Rename…", action: renameSelectedSession)
                    .disabled(state.selectedSession(in: facts) == nil)
                Button("Delete…", action: deleteSelectedSession)
                    .disabled(!facts.canDelete || state.selectedSession(in: facts) == nil)

                Spacer()

                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Switch") {
                    guard let sessionID = state.selectedSessionID else { return }
                    onSwitch(sessionID)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.selectedSessionID == nil)
            }

            if let error = store.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(annotationStoreErrorMessage(error))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if store.hasPendingMutations {
                        Button("Retry") { store.retryPendingMutations() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 390, height: 190, alignment: .topLeading)
        .onAppear {
            state.synchronize(with: facts)
            DispatchQueue.main.async { pickerFocused = true }
        }
        .onChange(of: store.sessions) {
            state.synchronize(with: facts)
        }
        .onChange(of: store.currentSessionID) {
            state.selectCurrent(from: facts)
        }
    }

    private var selection: Binding<UUID> {
        Binding(
            get: { state.selectedSessionID ?? facts.currentSessionID },
            set: { _ = state.choose($0, from: facts) }
        )
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

    private func renameSelectedSession() {
        guard let sessionID = state.selectedSessionID else { return }
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

    private func deleteSelectedSession() {
        guard let sessionID = state.selectedSessionID else { return }
        let sessions = store.sessions
        guard SessionDialogs.confirmsDelete(
            sessionID: sessionID,
            sessions: sessions,
            lastCleared: store.lastCleared
        ) else { return }
        store.mutate(.deleteSession(sessionID: sessionID))
    }
}
