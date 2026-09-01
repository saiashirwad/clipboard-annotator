import ClipboardAnnotatorDomain
import Foundation
import XCTest
@testable import ClipboardAnnotator

final class SessionUITests: XCTestCase {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!

    func testSessionFactsExposeMenuAndPickerNamesCountsAndCurrentCheckmark() {
        let sessions = [
            Session(id: firstID, name: "Reading", entries: [annotation("One")]),
            Session(id: secondID, name: "Writing", entries: [annotation("Two"), annotation("Three")]),
        ]

        let facts = SessionUIFacts(
            sessions: sessions,
            currentSessionID: secondID,
            lastCleared: nil
        )

        XCTAssertEqual(facts.sessions.map(\.name), ["Reading", "Writing"])
        XCTAssertEqual(facts.sessions.map(\.annotationCount), [1, 2])
        XCTAssertEqual(facts.sessions.map(\.isCurrent), [false, true])
        XCTAssertEqual(facts.currentTitle, "Writing — 2 annotations")
        XCTAssertTrue(facts.canDelete)
    }

    func testSingleSessionCannotBeDeleted() {
        let facts = SessionUIFacts(
            sessions: [Session(id: firstID, name: "Only")],
            currentSessionID: firstID,
            lastCleared: nil
        )

        XCTAssertFalse(facts.canDelete)

        let cleared = [annotation("Cleared")]
        let deletion = SessionDeletionFacts(
            sessionID: firstID,
            sessions: [
                Session(id: firstID, name: "Cleared"),
                Session(id: secondID, name: "Other"),
            ],
            lastCleared: ClearedBatch(sessionID: firstID, entries: cleared)
        )
        XCTAssertTrue(deletion.requiresConfirmation)
        XCTAssertTrue(deletion.includesUndoBatch)
        XCTAssertEqual(deletion.annotationCount, 1)
    }

    func testUndoFactsIdentifyANoncurrentSourceSession() {
        let cleared = [annotation("One"), annotation("Two")]
        let facts = SessionUIFacts(
            sessions: [
                Session(id: firstID, name: "Reading"),
                Session(id: secondID, name: "Writing"),
            ],
            currentSessionID: secondID,
            lastCleared: ClearedBatch(sessionID: firstID, entries: cleared)
        )

        XCTAssertEqual(facts.undo?.sessionID, firstID)
        XCTAssertEqual(facts.undo?.title, "Undo Clear in Reading (2)")
    }

    func testNameDraftTrimsAndRejectsBlankOrFoldedDuplicates() {
        let sessions = [Session(id: firstID, name: "Résumé")]

        XCTAssertEqual(
            SessionNameDraft(text: "  New Notes  ", excludedSessionID: nil)
                .validation(sessions: sessions),
            .valid("New Notes")
        )
        XCTAssertEqual(
            SessionNameDraft(text: " \n ", excludedSessionID: nil)
                .validation(sessions: sessions),
            .invalid("Enter a session name.")
        )
        for duplicate in ["résumé", "RESUME", "ＲＥＳＵＭＥ"] {
            XCTAssertEqual(
                SessionNameDraft(text: duplicate, excludedSessionID: nil)
                    .validation(sessions: sessions),
                .invalid("A session with that name already exists.")
            )
        }
    }

    func testRenameDraftExcludesCapturedSessionButNotOtherSessions() {
        let sessions = [
            Session(id: firstID, name: "Reading"),
            Session(id: secondID, name: "Writing"),
        ]

        XCTAssertEqual(
            SessionNameDraft(text: " reading ", excludedSessionID: firstID)
                .validation(sessions: sessions),
            .valid("reading")
        )
        XCTAssertEqual(
            SessionNameDraft(text: "WRITING", excludedSessionID: firstID)
                .validation(sessions: sessions),
            .invalid("A session with that name already exists.")
        )
    }

    func testQuickSwitchStateKeepsExplicitSelectionAndFallsBackAfterDeletion() {
        let both = SessionUIFacts(
            sessions: [
                Session(id: firstID, name: "Reading"),
                Session(id: secondID, name: "Writing"),
            ],
            currentSessionID: firstID,
            lastCleared: nil
        )
        var state = QuickSwitchState()
        state.synchronize(with: both)
        XCTAssertEqual(state.selectedSessionID, firstID)
        XCTAssertEqual(state.choose(secondID, from: both), secondID)
        XCTAssertEqual(state.selectedSessionID, secondID)
        XCTAssertNil(state.choose(UUID(), from: both))
        XCTAssertEqual(state.selectedSessionID, secondID)
        state.selectCurrent(from: both)
        XCTAssertEqual(state.selectedSessionID, firstID)
        _ = state.choose(secondID, from: both)

        let afterDeletion = SessionUIFacts(
            sessions: [Session(id: firstID, name: "Reading")],
            currentSessionID: firstID,
            lastCleared: nil
        )
        state.synchronize(with: afterDeletion)
        XCTAssertEqual(state.selectedSessionID, firstID)
    }

    private func annotation(_ note: String) -> Annotation {
        Annotation(
            subject: .standalone,
            note: note,
            provenance: Provenance(application: ApplicationIdentity(name: "Test"))
        )
    }
}
