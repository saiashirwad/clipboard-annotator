import ClipboardAnnotatorDomain
import Foundation
import XCTest
@testable import ClipboardAnnotator

final class RuntimeCutoverTests: XCTestCase {
    func testTypedSelectionWithoutNoteIsRejectedAtCaptureBoundary() {
        let context = AnnotationCaptureContext(sessionID: UUID())
        let target = context.target(captured: CapturedSelection(
            text: "Selected text",
            appName: "Reader",
            appBundleID: "com.example.reader",
            screenRect: nil
        ))

        XCTAssertNil(CaptureAnnotationPolicy.annotation(for: target, note: "  \n "))
    }

    func testCaptureContextSuppliedIdentifiersSessionAndDateSurviveTargetConstruction() throws {
        let sessionID = UUID()
        let captureID = UUID()
        let annotationID = UUID()
        let createdAt = Date(timeIntervalSince1970: 123)
        let context = AnnotationCaptureContext(
            sessionID: sessionID,
            captureID: captureID,
            annotationID: annotationID,
            createdAt: createdAt
        )
        let target = context.target(captured: CapturedSelection(
            text: " quote ",
            appName: "Reader",
            appBundleID: "com.example.reader",
            screenRect: nil
        ))

        let annotation = try XCTUnwrap(
            CaptureAnnotationPolicy.annotation(for: target, note: "  My note  ")
        )
        XCTAssertEqual(target.sessionID, sessionID)
        XCTAssertEqual(target.captureID, captureID)
        XCTAssertEqual(target.annotationID, annotationID)
        XCTAssertEqual(target.createdAt, createdAt)
        XCTAssertEqual(annotation.id, annotationID)
        XCTAssertEqual(annotation.createdAt, createdAt)
        XCTAssertEqual(annotation.note, "My note")
        XCTAssertEqual(annotation.provenance.application.name, "Reader")
        XCTAssertEqual(annotation.provenance.application.bundleID, "com.example.reader")
        XCTAssertEqual(annotation.subject, .selection(quote: " quote "))
    }

    func testOutputProfileProjectionPreservesCurrentToggles() {
        let profile = OutputProfileProjection.profile(
            includeSource: true,
            includeHeading: false,
            clearAfterCopy: true
        )

        XCTAssertTrue(profile.includeApplication)
        XCTAssertTrue(profile.includeLink)
        XCTAssertTrue(profile.includeTimestamps)
        XCTAssertFalse(profile.includeWindow)
        XCTAssertFalse(profile.includeHeading)
        XCTAssertTrue(profile.clearSessionAfterExport)
        XCTAssertEqual(profile.preamble, "")
    }

    func testMoveMappingProducesDomainFinalIndexesForSwiftUIDestination() {
        let ids = (0..<4).map { _ in UUID() }
        let moves = AnnotationMoveMapping.moves(
            annotationIDs: ids,
            from: IndexSet(integer: 0),
            to: 3
        )

        XCTAssertEqual(apply(moves, to: ids), [ids[1], ids[2], ids[0], ids[3]])
    }

    func testMoveMappingHandlesMultipleRows() {
        let ids = (0..<5).map { _ in UUID() }
        let moves = AnnotationMoveMapping.moves(
            annotationIDs: ids,
            from: IndexSet([1, 2]),
            to: 5
        )

        XCTAssertEqual(apply(moves, to: ids), [ids[0], ids[3], ids[4], ids[1], ids[2]])
    }

    @MainActor
    func testClipboardWriteFailureDoesNotClear() async throws {
        let annotation = Annotation(
            subject: .standalone,
            note: "Keep me",
            provenance: Provenance(application: ApplicationIdentity(name: "Reader"))
        )
        let session = Session(name: "Default", entries: [annotation])
        let persistence = StorePersistence(load: { nil }, commit: { _ in })
        let store = try await AnnotationStore(persistence: persistence, defaultSession: session)
        var attemptedText = ""
        var profile = Profile.plain
        profile.clearSessionAfterExport = true

        let copied = CurrentSessionExport.copy(store: store, profile: profile) { text in
            attemptedText = text
            return false
        }
        await store.waitForIdle()

        XCTAssertFalse(copied)
        XCTAssertFalse(attemptedText.isEmpty)
        XCTAssertEqual(store.currentEntries, [annotation])
        store.teardown()
    }

    private func apply(
        _ moves: [AnnotationMoveMapping.Move],
        to source: [UUID]
    ) -> [UUID] {
        var result = source
        for move in moves {
            let sourceIndex = result.firstIndex(of: move.annotationID)!
            let id = result.remove(at: sourceIndex)
            result.insert(id, at: move.destinationIndex)
        }
        return result
    }
}
