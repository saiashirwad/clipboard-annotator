import XCTest
@testable import Sendpoint

final class AutomaticSelectionTrackerTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_000)

    func testDragCopiedTextCanBeTakenByMatchingProcessAndPasteboardRevision() {
        var tracker = AutomaticSelectionTracker()
        tracker.mouseDown(processIdentifier: 42, pasteboardChangeCount: 10)
        tracker.mouseDragged()
        let request = tracker.mouseUp()

        XCTAssertNotNil(request)
        XCTAssertTrue(tracker.settle(
            request!,
            text: "Prime Agent output",
            pasteboardChangeCount: 11,
            now: capturedAt
        ))
        XCTAssertEqual(
            tracker.takeCandidate(
                processIdentifier: 42,
                pasteboardChangeCount: 11,
                now: capturedAt.addingTimeInterval(1)
            ),
            "Prime Agent output"
        )
        XCTAssertNil(tracker.takeCandidate(
            processIdentifier: 42,
            pasteboardChangeCount: 11,
            now: capturedAt.addingTimeInterval(1)
        ))
    }

    func testClickWithoutDragDoesNotCreateCandidate() {
        var tracker = AutomaticSelectionTracker()
        tracker.mouseDown(processIdentifier: 42, pasteboardChangeCount: 10)

        XCTAssertNil(tracker.mouseUp())
        XCTAssertNil(tracker.takeCandidate(
            processIdentifier: 42,
            pasteboardChangeCount: 10,
            now: capturedAt
        ))
    }

    func testUnchangedOrEmptyPasteboardDoesNotCreateCandidate() {
        var unchanged = AutomaticSelectionTracker()
        unchanged.mouseDown(processIdentifier: 42, pasteboardChangeCount: 10)
        unchanged.mouseDragged()
        let unchangedRequest = unchanged.mouseUp()!
        XCTAssertFalse(unchanged.settle(
            unchangedRequest,
            text: "old clipboard text",
            pasteboardChangeCount: 10,
            now: capturedAt
        ))

        var empty = AutomaticSelectionTracker()
        empty.mouseDown(processIdentifier: 42, pasteboardChangeCount: 10)
        empty.mouseDragged()
        let emptyRequest = empty.mouseUp()!
        XCTAssertFalse(empty.settle(
            emptyRequest,
            text: "  \n",
            pasteboardChangeCount: 11,
            now: capturedAt
        ))
    }

    func testCandidateRejectsWrongProcessChangedPasteboardAndExpiredValue() {
        func makeTracker() -> AutomaticSelectionTracker {
            var tracker = AutomaticSelectionTracker()
            tracker.mouseDown(processIdentifier: 42, pasteboardChangeCount: 10)
            tracker.mouseDragged()
            let request = tracker.mouseUp()!
            XCTAssertTrue(tracker.settle(
                request,
                text: "selection",
                pasteboardChangeCount: 11,
                now: capturedAt
            ))
            return tracker
        }

        var wrongProcess = makeTracker()
        XCTAssertNil(wrongProcess.takeCandidate(
            processIdentifier: 99,
            pasteboardChangeCount: 11,
            now: capturedAt
        ))

        var changedPasteboard = makeTracker()
        XCTAssertNil(changedPasteboard.takeCandidate(
            processIdentifier: 42,
            pasteboardChangeCount: 12,
            now: capturedAt
        ))

        var expired = makeTracker()
        XCTAssertNil(expired.takeCandidate(
            processIdentifier: 42,
            pasteboardChangeCount: 11,
            now: capturedAt.addingTimeInterval(16)
        ))
    }


    func testPendingSettlementCanObserveDelayedClipboardWrite() {
        var tracker = AutomaticSelectionTracker()
        tracker.mouseDown(processIdentifier: 42, pasteboardChangeCount: 10)
        tracker.mouseDragged()
        let request = tracker.mouseUp()!

        XCTAssertFalse(tracker.settle(
            request,
            text: "old clipboard text",
            pasteboardChangeCount: 10,
            now: capturedAt
        ))
        XCTAssertTrue(tracker.settlePending(
            text: "delayed selection",
            pasteboardChangeCount: 11,
            now: capturedAt.addingTimeInterval(0.15)
        ))
        XCTAssertEqual(tracker.takeCandidate(
            processIdentifier: 42,
            pasteboardChangeCount: 11,
            now: capturedAt.addingTimeInterval(0.15)
        ), "delayed selection")
    }

    func testAbandonedSettlementRejectsLaterClipboardChange() {
        var tracker = AutomaticSelectionTracker()
        tracker.mouseDown(processIdentifier: 42, pasteboardChangeCount: 10)
        tracker.mouseDragged()
        let request = tracker.mouseUp()!

        tracker.abandon(request)

        XCTAssertFalse(tracker.settlePending(
            text: "unrelated later copy",
            pasteboardChangeCount: 11,
            now: capturedAt
        ))
        XCTAssertNil(tracker.takeCandidate(
            processIdentifier: 42,
            pasteboardChangeCount: 11,
            now: capturedAt
        ))
    }

    func testNewDragRejectsLateSettlementFromEarlierDrag() {
        var tracker = AutomaticSelectionTracker()
        tracker.mouseDown(processIdentifier: 42, pasteboardChangeCount: 10)
        tracker.mouseDragged()
        let staleRequest = tracker.mouseUp()!

        tracker.mouseDown(processIdentifier: 42, pasteboardChangeCount: 11)
        tracker.mouseDragged()
        let currentRequest = tracker.mouseUp()!

        XCTAssertFalse(tracker.settle(
            staleRequest,
            text: "stale",
            pasteboardChangeCount: 12,
            now: capturedAt
        ))
        XCTAssertTrue(tracker.settle(
            currentRequest,
            text: "current",
            pasteboardChangeCount: 12,
            now: capturedAt
        ))
        XCTAssertEqual(tracker.takeCandidate(
            processIdentifier: 42,
            pasteboardChangeCount: 12,
            now: capturedAt
        ), "current")
    }

    func testTeardownIsIdempotentAndRejectsLateEvents() {
        var tracker = AutomaticSelectionTracker()
        tracker.mouseDown(processIdentifier: 42, pasteboardChangeCount: 10)
        tracker.mouseDragged()
        let request = tracker.mouseUp()!

        tracker.teardown()
        tracker.teardown()
        XCTAssertFalse(tracker.settle(
            request,
            text: "late",
            pasteboardChangeCount: 11,
            now: capturedAt
        ))

        tracker.mouseDown(processIdentifier: 42, pasteboardChangeCount: 11)
        tracker.mouseDragged()
        XCTAssertNil(tracker.mouseUp())
        XCTAssertNil(tracker.takeCandidate(
            processIdentifier: 42,
            pasteboardChangeCount: 11,
            now: capturedAt
        ))
    }
}
