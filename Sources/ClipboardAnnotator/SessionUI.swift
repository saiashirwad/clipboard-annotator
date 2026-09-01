import AppKit
import ClipboardAnnotatorDomain
import Foundation

struct SessionItemFacts: Equatable, Identifiable {
    let id: UUID
    let name: String
    let annotationCount: Int
    let isCurrent: Bool

    var countLabel: String {
        "\(annotationCount) annotation\(annotationCount == 1 ? "" : "s")"
    }
}

struct SessionUndoFacts: Equatable {
    let sessionID: UUID
    let sessionName: String
    let annotationCount: Int
    let isCurrentSession: Bool

    var title: String {
        let count = "\(annotationCount)"
        return isCurrentSession
            ? "Undo Clear (\(count))"
            : "Undo Clear in \(sessionName) (\(count))"
    }
}

struct SessionDeletionFacts: Equatable {
    let liveAnnotationCount: Int
    let clearedAnnotationCount: Int

    init(sessionID: UUID, sessions: [Session], lastCleared: ClearedBatch?) {
        liveAnnotationCount = sessions.first(where: { $0.id == sessionID })?.entries.count ?? 0
        clearedAnnotationCount = lastCleared?.sessionID == sessionID
            ? lastCleared?.entries.count ?? 0
            : 0
    }

    var annotationCount: Int { liveAnnotationCount + clearedAnnotationCount }
    var includesUndoBatch: Bool { clearedAnnotationCount > 0 }
    var requiresConfirmation: Bool { annotationCount > 0 }
}

struct SessionUIFacts: Equatable {
    let sessions: [SessionItemFacts]
    let currentSessionID: UUID
    let undo: SessionUndoFacts?

    init(sessions: [Session], currentSessionID: UUID, lastCleared: ClearedBatch?) {
        self.sessions = sessions.map {
            SessionItemFacts(
                id: $0.id,
                name: $0.name,
                annotationCount: $0.entries.count,
                isCurrent: $0.id == currentSessionID
            )
        }
        self.currentSessionID = currentSessionID

        if
            let lastCleared,
            let session = sessions.first(where: { $0.id == lastCleared.sessionID })
        {
            undo = SessionUndoFacts(
                sessionID: session.id,
                sessionName: session.name,
                annotationCount: lastCleared.entries.count,
                isCurrentSession: session.id == currentSessionID
            )
        } else {
            undo = nil
        }
    }

    var current: SessionItemFacts? {
        sessions.first(where: { $0.id == currentSessionID })
    }

    var currentTitle: String {
        guard let current else { return "Session Unavailable" }
        return "\(current.name) — \(current.countLabel)"
    }

    var canDelete: Bool { sessions.count > 1 }

    func session(id: UUID) -> SessionItemFacts? {
        sessions.first(where: { $0.id == id })
    }
}

enum SessionNameValidation: Equatable {
    case valid(String)
    case invalid(String)
}

struct SessionNameDraft: Equatable {
    var text: String
    let excludedSessionID: UUID?

    func validation(sessions: [Session]) -> SessionNameValidation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = SessionDocumentMutations.normalizedSessionName(trimmed) else {
            return .invalid("Enter a session name.")
        }
        let duplicate = sessions.contains {
            $0.id != excludedSessionID
                && SessionDocumentMutations.normalizedSessionName($0.name) == normalized
        }
        guard !duplicate else {
            return .invalid("A session with that name already exists.")
        }
        return .valid(trimmed)
    }
}

struct QuickSwitchState: Equatable {
    private(set) var selectedSessionID: UUID?

    init(selectedSessionID: UUID? = nil) {
        self.selectedSessionID = selectedSessionID
    }

    mutating func synchronize(with facts: SessionUIFacts) {
        guard
            let selectedSessionID,
            facts.session(id: selectedSessionID) != nil
        else {
            self.selectedSessionID = facts.currentSessionID
            return
        }
    }

    mutating func choose(_ sessionID: UUID, from facts: SessionUIFacts) -> UUID? {
        guard facts.session(id: sessionID) != nil else { return nil }
        selectedSessionID = sessionID
        return sessionID
    }

    mutating func selectCurrent(from facts: SessionUIFacts) {
        selectedSessionID = facts.currentSessionID
    }

    func selectedSession(in facts: SessionUIFacts) -> SessionItemFacts? {
        guard let selectedSessionID else { return nil }
        return facts.session(id: selectedSessionID)
    }
}

@MainActor
enum SessionDialogs {
    static func requestNewSessionName(sessions: [Session]) -> String? {
        requestName(
            title: "New Session",
            prompt: "Enter a name for the new session.",
            initialValue: "",
            sessions: sessions,
            excluding: nil
        )
    }

    static func requestRenamedSessionName(sessionID: UUID, sessions: [Session]) -> String? {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            showMessage("The session no longer exists.")
            return nil
        }
        return requestName(
            title: "Rename Session",
            prompt: "Enter a new name for “\(session.name)”.",
            initialValue: session.name,
            sessions: sessions,
            excluding: sessionID
        )
    }

    static func confirmsDelete(
        sessionID: UUID,
        sessions: [Session],
        lastCleared: ClearedBatch?
    ) -> Bool {
        guard sessions.count > 1 else {
            showMessage("The last session cannot be deleted.")
            return false
        }
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            showMessage("The session no longer exists.")
            return false
        }
        let deletion = SessionDeletionFacts(
            sessionID: sessionID,
            sessions: sessions,
            lastCleared: lastCleared
        )
        guard deletion.requiresConfirmation else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(session.name)”?"
        let undoWarning = deletion.includesUndoBatch
            ? " Cleared annotations waiting to be undone will also be deleted."
            : ""
        let count = deletion.annotationCount
        alert.informativeText = "This will delete \(count) annotation\(count == 1 ? "" : "s").\(undoWarning) This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func validateForEnqueue(
        _ name: String,
        excluding sessionID: UUID?,
        sessions: [Session]
    ) -> String? {
        switch SessionNameDraft(text: name, excludedSessionID: sessionID)
            .validation(sessions: sessions)
        {
        case let .valid(trimmed):
            return trimmed
        case let .invalid(message):
            showMessage(message)
            return nil
        }
    }

    static func showMessage(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Session Change Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func requestName(
        title: String,
        prompt: String,
        initialValue: String,
        sessions: [Session],
        excluding excludedSessionID: UUID?
    ) -> String? {
        var value = initialValue
        var validationMessage: String?

        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = validationMessage ?? prompt
            alert.addButton(withTitle: title == "New Session" ? "Create" : "Rename")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(string: value)
            field.placeholderString = "Session name"
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            value = field.stringValue
            switch SessionNameDraft(text: value, excludedSessionID: excludedSessionID)
                .validation(sessions: sessions)
            {
            case let .valid(name):
                return name
            case let .invalid(message):
                validationMessage = message
            }
        }
    }
}

func annotationStoreErrorMessage(_ error: AnnotationStoreError) -> String {
    switch error {
    case let .mutationRejected(message):
        return message
    case let .commitFailed(message):
        return "Could not save the session change: \(message)"
    case .tornDown:
        return "Session storage is no longer available."
    }
}
