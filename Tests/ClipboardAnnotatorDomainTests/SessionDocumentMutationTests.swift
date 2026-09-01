import Foundation
import XCTest
@testable import ClipboardAnnotatorDomain

final class SessionDocumentMutationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!

    func testCreateRenameSwitchAndDeletePreserveDocumentRules() {
        let initial = document()
        let second = Session(id: secondID, name: "  Second  ", createdAt: now)
        let created = applied(.createSession(second), to: initial)
        XCTAssertEqual(created.sessions.map(\.name), ["First", "Second"])
        XCTAssertEqual(created.currentSessionID, secondID)

        let renamed = applied(
            .renameSession(sessionID: firstID, name: "  Renamed  "),
            to: created
        )
        XCTAssertEqual(renamed.sessions[0].name, "Renamed")
        let switched = applied(.switchSession(sessionID: firstID), to: renamed)
        XCTAssertEqual(switched.currentSessionID, firstID)

        let deleted = applied(.deleteSession(sessionID: firstID), to: switched)
        XCTAssertEqual(deleted.sessions.map(\.id), [secondID])
        XCTAssertEqual(deleted.currentSessionID, secondID)
        XCTAssertEqual(
            SessionDocumentMutations.applying(.deleteSession(sessionID: secondID), to: deleted),
            .rejected("The last session cannot be deleted.")
        )
    }

    func testDeletingCurrentSelectsFollowingSessionThenPreviousSession() {
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let initial = StoreDocument(
            sessions: [
                Session(id: firstID, name: "First", createdAt: now),
                Session(id: secondID, name: "Second", createdAt: now),
                Session(id: thirdID, name: "Third", createdAt: now),
            ],
            currentSessionID: secondID
        )

        let deletedMiddle = applied(.deleteSession(sessionID: secondID), to: initial)
        XCTAssertEqual(deletedMiddle.sessions.map(\.id), [firstID, thirdID])
        XCTAssertEqual(deletedMiddle.currentSessionID, thirdID)

        let deletedLast = applied(.deleteSession(sessionID: thirdID), to: deletedMiddle)
        XCTAssertEqual(deletedLast.sessions.map(\.id), [firstID])
        XCTAssertEqual(deletedLast.currentSessionID, firstID)
    }

    func testDeletingNoncurrentSessionPreservesCurrentSession() {
        let initial = StoreDocument(
            sessions: [
                Session(id: firstID, name: "First", createdAt: now),
                Session(id: secondID, name: "Second", createdAt: now),
            ],
            currentSessionID: secondID
        )

        let deleted = applied(.deleteSession(sessionID: firstID), to: initial)

        XCTAssertEqual(deleted.sessions.map(\.id), [secondID])
        XCTAssertEqual(deleted.currentSessionID, secondID)
    }

    func testDeletingSessionThatOriginatedLastClearDiscardsUndoBatch() {
        let cleared = annotation(id: UUID(), note: "cleared")
        let initial = StoreDocument(
            sessions: [
                Session(id: firstID, name: "First", createdAt: now),
                Session(id: secondID, name: "Second", createdAt: now),
            ],
            currentSessionID: secondID,
            lastCleared: ClearedBatch(sessionID: firstID, entries: [cleared])
        )

        let deleted = applied(.deleteSession(sessionID: firstID), to: initial)

        XCTAssertNil(deleted.lastCleared)
        XCTAssertEqual(deleted.currentSessionID, secondID)
    }

    func testNamesAreCaseDiacriticAndWidthInsensitive() {
        let initial = document(name: "Résumé")
        let conflictingNames = ["résumé", "RESUME", "ＲＥＳＵＭＥ"]

        for name in conflictingNames {
            XCTAssertEqual(
                SessionDocumentMutations.applying(
                    .createSession(Session(id: UUID(), name: name, createdAt: now)),
                    to: initial
                ),
                .rejected("Session names must be unique.")
            )
        }

        let second = applied(
            .createSession(Session(id: secondID, name: "Other", createdAt: now)),
            to: initial
        )
        XCTAssertEqual(
            SessionDocumentMutations.applying(
                .renameSession(sessionID: secondID, name: " ＲＥＳＵＭＥ "),
                to: second
            ),
            .rejected("Session names must be unique.")
        )
    }

    func testAnnotationAddUpdateMoveAndRemoveUseStableIDs() {
        let one = annotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!, note: "one")
        let two = annotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!, note: "two")
        let three = annotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!, note: "three")
        var changedTwo = two
        changedTwo.note = "changed"

        var result = applied(.addAnnotation(sessionID: firstID, annotation: one), to: document())
        result = applied(.addAnnotation(sessionID: firstID, annotation: two), to: result)
        result = applied(.addAnnotation(sessionID: firstID, annotation: three), to: result)
        result = applied(.updateAnnotation(sessionID: firstID, annotation: changedTwo), to: result)
        result = applied(
            .moveAnnotation(sessionID: firstID, annotationID: one.id, destinationIndex: 2),
            to: result
        )
        XCTAssertEqual(result.sessions[0].entries.map(\.id), [two.id, three.id, one.id])
        XCTAssertEqual(result.sessions[0].entries[0].note, "changed")

        result = applied(.removeAnnotation(sessionID: firstID, annotationID: three.id), to: result)
        XCTAssertEqual(result.sessions[0].entries.map(\.id), [two.id, one.id])
        XCTAssertEqual(
            SessionDocumentMutations.applying(
                .removeAnnotation(sessionID: firstID, annotationID: three.id),
                to: result
            ),
            .noOp
        )
    }

    func testMoveDestinationIsFinalIndexAndMustReferToAnExistingSlot() {
        let one = annotation(id: UUID(), note: "one")
        let two = annotation(id: UUID(), note: "two")
        let three = annotation(id: UUID(), note: "three")
        let session = Session(
            id: firstID,
            name: "First",
            entries: [one, two, three],
            createdAt: now
        )
        let initial = StoreDocument(sessions: [session], currentSessionID: firstID)

        let movedDown = applied(
            .moveAnnotation(sessionID: firstID, annotationID: one.id, destinationIndex: 2),
            to: initial
        )
        XCTAssertEqual(movedDown.sessions[0].entries.map(\.id), [two.id, three.id, one.id])

        let movedUp = applied(
            .moveAnnotation(sessionID: firstID, annotationID: one.id, destinationIndex: 0),
            to: movedDown
        )
        XCTAssertEqual(movedUp.sessions[0].entries.map(\.id), [one.id, two.id, three.id])
        XCTAssertEqual(
            SessionDocumentMutations.applying(
                .moveAnnotation(
                    sessionID: firstID,
                    annotationID: one.id,
                    destinationIndex: initial.sessions[0].entries.endIndex
                ),
                to: initial
            ),
            .rejected("The destination is outside the session.")
        )
    }

    func testMissingUpdateDefersButMissingSessionRejects() {
        let missing = annotation(id: UUID(), note: "late")
        XCTAssertEqual(
            SessionDocumentMutations.applying(
                .updateAnnotation(sessionID: firstID, annotation: missing),
                to: document()
            ),
            .deferred
        )
        XCTAssertEqual(
            SessionDocumentMutations.applying(
                .updateAnnotation(sessionID: secondID, annotation: missing),
                to: document()
            ),
            .rejected("The target session no longer exists.")
        )
    }

    func testClearCanBeUndoneAfterSwitchingSessions() {
        let old = annotation(id: UUID(), note: "old")
        let first = Session(id: firstID, name: "First", entries: [old], createdAt: now)
        let second = Session(id: secondID, name: "Second", createdAt: now)
        let initial = StoreDocument(sessions: [first, second], currentSessionID: firstID)

        let cleared = applied(.clearSession(sessionID: firstID), to: initial)
        XCTAssertTrue(cleared.sessions[0].entries.isEmpty)
        let switched = applied(.switchSession(sessionID: secondID), to: cleared)
        let restored = applied(.undoClear, to: switched)

        XCTAssertEqual(restored.currentSessionID, secondID)
        XCTAssertEqual(restored.sessions[0].entries, [old])
        XCTAssertNil(restored.lastCleared)
    }

    func testUndoPlacesClearedBatchBeforeLaterEntriesAndReplacesDuplicateIDs() {
        let old = annotation(id: UUID(), note: "old")
        let later = annotation(id: UUID(), note: "later")
        let first = Session(id: firstID, name: "First", entries: [old], createdAt: now)
        let initial = StoreDocument(sessions: [first], currentSessionID: firstID)
        let cleared = applied(.clearSession(sessionID: firstID), to: initial)
        let withLater = applied(.addAnnotation(sessionID: firstID, annotation: later), to: cleared)
        var replacement = old
        replacement.note = "duplicate added after clear"
        let withDuplicate = applied(
            .addAnnotation(sessionID: firstID, annotation: replacement),
            to: withLater
        )

        let restored = applied(.undoClear, to: withDuplicate)
        XCTAssertEqual(restored.sessions[0].entries, [old, later])
    }

    func testValidationRejectsDuplicateSessionAnnotationAndClearedBatchIDs() {
        let one = annotation(id: UUID(), note: "one")
        let duplicateSessionIDs = StoreDocument(
            sessions: [
                Session(id: firstID, name: "First", createdAt: now),
                Session(id: firstID, name: "Second", createdAt: now),
            ],
            currentSessionID: firstID
        )
        XCTAssertThrowsError(try SessionDocumentMutations.validate(duplicateSessionIDs)) {
            XCTAssertEqual(
                ($0 as? SessionDocumentValidationError)?.message,
                "session IDs must be unique"
            )
        }

        let duplicateAnnotationIDs = StoreDocument(
            sessions: [
                Session(id: firstID, name: "First", entries: [one, one], createdAt: now)
            ],
            currentSessionID: firstID
        )
        XCTAssertThrowsError(try SessionDocumentMutations.validate(duplicateAnnotationIDs)) {
            XCTAssertEqual(
                ($0 as? SessionDocumentValidationError)?.message,
                "annotation IDs must be unique within a session"
            )
        }

        let duplicateClearedIDs = StoreDocument(
            sessions: [Session(id: firstID, name: "First", createdAt: now)],
            currentSessionID: firstID,
            lastCleared: ClearedBatch(sessionID: firstID, entries: [one, one])
        )
        XCTAssertThrowsError(try SessionDocumentMutations.validate(duplicateClearedIDs)) {
            XCTAssertEqual(
                ($0 as? SessionDocumentValidationError)?.message,
                "lastCleared annotation IDs must be unique"
            )
        }
    }

    func testValidationRejectsInvalidCurrentSessionAndDuplicateFoldedNames() {
        XCTAssertThrowsError(
            try SessionDocumentMutations.validate(
                StoreDocument(sessions: [Session(name: "First")], currentSessionID: UUID())
            )
        )
        XCTAssertThrowsError(
            try SessionDocumentMutations.validate(
                StoreDocument(
                    sessions: [
                        Session(id: firstID, name: "Café"),
                        Session(id: secondID, name: "ＣＡＦＥ"),
                    ],
                    currentSessionID: firstID
                )
            )
        )
    }

    private func document(name: String = "First") -> StoreDocument {
        StoreDocument(
            sessions: [Session(id: firstID, name: name, createdAt: now)],
            currentSessionID: firstID
        )
    }

    private func annotation(id: UUID, note: String) -> Annotation {
        Annotation(
            id: id,
            subject: .standalone,
            note: note,
            provenance: Provenance(application: ApplicationIdentity(name: "Tests")),
            createdAt: now
        )
    }

    private func applied(
        _ mutation: SessionDocumentMutation,
        to document: StoreDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> StoreDocument {
        let result = SessionDocumentMutations.applying(mutation, to: document)
        guard case let .applied(candidate) = result else {
            XCTFail("Expected applied mutation, got \(result)", file: file, line: line)
            return document
        }
        return candidate
    }
}
