import Foundation

/// Every supported change to a session document.
public enum SessionDocumentMutation: Equatable, Sendable {
    case createSession(Session)
    case renameSession(sessionID: UUID, name: String)
    case switchSession(sessionID: UUID)
    case deleteSession(sessionID: UUID)
    case addAnnotation(sessionID: UUID, annotation: Annotation)
    case updateAnnotationNote(sessionID: UUID, annotationID: UUID, note: String)
    case updateAnnotationProvenance(
        sessionID: UUID,
        annotationID: UUID,
        expectedApplication: ApplicationIdentity,
        provenance: Provenance
    )
    case removeAnnotation(sessionID: UUID, annotationID: UUID)

    /// Moves an annotation to a final zero-based index in its session.
    case moveAnnotation(sessionID: UUID, annotationID: UUID, destinationIndex: Int)
    case clearSession(sessionID: UUID)
    case undoClear
}

/// The result of applying a pure document mutation.
public enum SessionDocumentMutationResult: Equatable, Sendable {
    case applied(StoreDocument)
    case noOp
    case rejected(String)
}

public struct SessionDocumentValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Pure session document rules. This type has no UI or persistence dependency.
public enum SessionDocumentMutations {
    /// Trims a name and returns its case-, diacritic-, and width-insensitive key.
    public static func normalizedSessionName(_ name: String) -> String? {
        name.normalizedSessionName
    }

    public static func validate(_ document: StoreDocument) throws {
        guard document.version == StoreDocument.currentVersion else {
            throw SessionDocumentValidationError("unsupported document version: \(document.version)")
        }
        guard !document.sessions.isEmpty else {
            throw SessionDocumentValidationError("sessions must not be empty")
        }
        guard Set(document.sessions.map(\.id)).count == document.sessions.count else {
            throw SessionDocumentValidationError("session IDs must be unique")
        }
        guard document.sessions.contains(where: { $0.id == document.currentSessionID }) else {
            throw SessionDocumentValidationError("currentSessionID must identify a session")
        }

        var names = Set<String>()
        for session in document.sessions {
            let trimmed = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard session.name == trimmed, let nameKey = normalizedSessionName(session.name) else {
                throw SessionDocumentValidationError("session names must be trimmed and nonempty")
            }
            guard names.insert(nameKey).inserted else {
                throw SessionDocumentValidationError("session names must be unique")
            }
            guard Set(session.entries.map(\.id)).count == session.entries.count else {
                throw SessionDocumentValidationError("annotation IDs must be unique within a session")
            }
        }

        if let batch = document.lastCleared {
            guard !batch.entries.isEmpty else {
                throw SessionDocumentValidationError("lastCleared must not be empty")
            }
            guard document.sessions.contains(where: { $0.id == batch.sessionID }) else {
                throw SessionDocumentValidationError("lastCleared must identify a session")
            }
            guard Set(batch.entries.map(\.id)).count == batch.entries.count else {
                throw SessionDocumentValidationError("lastCleared annotation IDs must be unique")
            }
        }
    }

    public static func applying(
        _ mutation: SessionDocumentMutation,
        to source: StoreDocument
    ) -> SessionDocumentMutationResult {
        do {
            try validate(source)
        } catch {
            return .rejected("The session document is invalid: \(error)")
        }

        var document = source
        switch mutation {
        case var .createSession(session):
            session.name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedSessionName(session.name) != nil else {
                return .rejected("Session names must not be empty.")
            }
            guard !document.sessions.contains(where: { $0.id == session.id }) else {
                return .rejected("A session with that identifier already exists.")
            }
            guard isUnique(session.name, in: document.sessions) else {
                return .rejected("Session names must be unique.")
            }
            guard Set(session.entries.map(\.id)).count == session.entries.count else {
                return .rejected("Annotation identifiers must be unique within a session.")
            }
            document.sessions.append(session)
            document.currentSessionID = session.id

        case let .renameSession(sessionID, name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedSessionName(trimmed) != nil else {
                return .rejected("Session names must not be empty.")
            }
            guard let index = sessionIndex(sessionID, in: document) else {
                return .rejected("The session no longer exists.")
            }
            guard isUnique(trimmed, in: document.sessions, excluding: sessionID) else {
                return .rejected("Session names must be unique.")
            }
            guard document.sessions[index].name != trimmed else { return .noOp }
            document.sessions[index].name = trimmed

        case let .switchSession(sessionID):
            guard sessionIndex(sessionID, in: document) != nil else {
                return .rejected("The session no longer exists.")
            }
            guard document.currentSessionID != sessionID else { return .noOp }
            document.currentSessionID = sessionID

        case let .deleteSession(sessionID):
            guard let index = sessionIndex(sessionID, in: document) else {
                return .rejected("The session no longer exists.")
            }
            guard document.sessions.count > 1 else {
                return .rejected("The last session cannot be deleted.")
            }
            document.sessions.remove(at: index)
            if document.currentSessionID == sessionID {
                document.currentSessionID = document.sessions[min(index, document.sessions.count - 1)].id
            }
            if document.lastCleared?.sessionID == sessionID {
                document.lastCleared = nil
            }

        case let .addAnnotation(sessionID, annotation):
            guard let sessionIndex = sessionIndex(sessionID, in: document) else {
                return .rejected("The target session no longer exists.")
            }
            guard !document.sessions[sessionIndex].entries.contains(where: { $0.id == annotation.id }) else {
                return .rejected("The annotation already exists.")
            }
            document.sessions[sessionIndex].entries.append(annotation)

        case let .updateAnnotationNote(sessionID, annotationID, note):
            guard let sessionIndex = sessionIndex(sessionID, in: document),
                  let annotationIndex = document.sessions[sessionIndex].entries.firstIndex(where: {
                      $0.id == annotationID
                  })
            else { return .noOp }
            guard document.sessions[sessionIndex].entries[annotationIndex].note != note else {
                return .noOp
            }
            document.sessions[sessionIndex].entries[annotationIndex].note = note

        case let .updateAnnotationProvenance(
            sessionID,
            annotationID,
            expectedApplication,
            provenance
        ):
            guard provenance.application == expectedApplication,
                  let sessionIndex = sessionIndex(sessionID, in: document)
            else { return .noOp }

            if let annotationIndex = document.sessions[sessionIndex].entries.firstIndex(where: {
                $0.id == annotationID
            }) {
                guard document.sessions[sessionIndex].entries[annotationIndex].provenance.application
                        == expectedApplication,
                      document.sessions[sessionIndex].entries[annotationIndex].provenance != provenance
                else { return .noOp }
                document.sessions[sessionIndex].entries[annotationIndex].provenance = provenance
            } else {
                guard document.lastCleared?.sessionID == sessionID,
                      let annotationIndex = document.lastCleared?.entries.firstIndex(where: {
                          $0.id == annotationID
                      }),
                      document.lastCleared?.entries[annotationIndex].provenance.application
                        == expectedApplication,
                      document.lastCleared?.entries[annotationIndex].provenance != provenance
                else { return .noOp }
                document.lastCleared?.entries[annotationIndex].provenance = provenance
            }

        case let .removeAnnotation(sessionID, annotationID):
            guard let sessionIndex = sessionIndex(sessionID, in: document) else {
                return .rejected("The target session no longer exists.")
            }
            guard let annotationIndex = document.sessions[sessionIndex].entries.firstIndex(where: {
                $0.id == annotationID
            }) else {
                return .noOp
            }
            document.sessions[sessionIndex].entries.remove(at: annotationIndex)

        case let .moveAnnotation(sessionID, annotationID, destinationIndex):
            guard let sessionIndex = sessionIndex(sessionID, in: document) else {
                return .rejected("The target session no longer exists.")
            }
            var entries = document.sessions[sessionIndex].entries
            guard let sourceIndex = entries.firstIndex(where: { $0.id == annotationID }) else {
                return .rejected("The annotation no longer exists.")
            }
            guard entries.indices.contains(destinationIndex) else {
                return .rejected("The destination is outside the session.")
            }
            guard sourceIndex != destinationIndex else { return .noOp }
            let annotation = entries.remove(at: sourceIndex)
            entries.insert(annotation, at: destinationIndex)
            document.sessions[sessionIndex].entries = entries

        case let .clearSession(sessionID):
            guard let sessionIndex = sessionIndex(sessionID, in: document) else {
                return .rejected("The target session no longer exists.")
            }
            let entries = document.sessions[sessionIndex].entries
            guard !entries.isEmpty else { return .noOp }
            document.lastCleared = ClearedBatch(sessionID: sessionID, entries: entries)
            document.sessions[sessionIndex].entries.removeAll()

        case .undoClear:
            guard let batch = document.lastCleared else { return .noOp }
            guard let sessionIndex = sessionIndex(batch.sessionID, in: document) else {
                return .rejected("The cleared session no longer exists.")
            }
            let clearedIDs = Set(batch.entries.map(\.id))
            let entriesAddedAfterClear = document.sessions[sessionIndex].entries.filter {
                !clearedIDs.contains($0.id)
            }
            document.sessions[sessionIndex].entries = batch.entries + entriesAddedAfterClear
            document.lastCleared = nil
        }

        do {
            try validate(document)
        } catch {
            return .rejected("The mutation would create an invalid session document: \(error)")
        }
        return .applied(document)
    }

    private static func sessionIndex(_ id: UUID, in document: StoreDocument) -> Int? {
        document.sessions.firstIndex(where: { $0.id == id })
    }

    private static func isUnique(
        _ name: String,
        in sessions: [Session],
        excluding excludedID: UUID? = nil
    ) -> Bool {
        guard let normalized = normalizedSessionName(name) else { return false }
        return !sessions.contains {
            $0.id != excludedID && normalizedSessionName($0.name) == normalized
        }
    }
}
