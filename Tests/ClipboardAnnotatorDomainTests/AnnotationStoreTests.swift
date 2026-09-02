import Foundation
import XCTest
@testable import ClipboardAnnotatorDomain

@MainActor
final class AnnotationStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

    func testLoadsExistingDocumentWithoutReplacingOrCommittingIt() async throws {
        let original = document(name: "Existing")
        let recorder = CommitRecorder()
        let persistence = StorePersistence(
            load: { original },
            commit: { document in await recorder.record(document) }
        )

        let store = try await AnnotationStore(persistence: persistence)

        XCTAssertEqual(store.currentSessionID, sessionID)
        XCTAssertEqual(store.currentSession, original.sessions[0])
        XCTAssertEqual(store.currentEntries, [])
        XCTAssertNil(store.lastCleared)
        let commits = await recorder.documents()
        XCTAssertEqual(commits, [])
    }

    func testSessionsExposeAReadOnlyCommittedSnapshot() async throws {
        let first = document(name: "First").sessions[0]
        let second = Session(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            name: "Second",
            createdAt: now
        )
        let original = StoreDocument(
            sessions: [first, second],
            currentSessionID: second.id
        )
        let store = try await AnnotationStore(
            persistence: StorePersistence(load: { original }, commit: { _ in })
        )

        XCTAssertEqual(store.sessions, [first, second])
    }

    func testFirstLoadCommitsDefaultBeforeStoreIsReturned() async throws {
        let recorder = CommitRecorder()
        let persistence = StorePersistence(
            load: { nil },
            commit: { document in await recorder.record(document) }
        )
        let defaultSession = Session(id: sessionID, name: "Default", createdAt: now)

        let store = try await AnnotationStore(
            persistence: persistence,
            defaultSession: defaultSession
        )

        XCTAssertEqual(store.currentSession, defaultSession)
        let commits = await recorder.documents()
        XCTAssertEqual(commits, [
            StoreDocument(sessions: [defaultSession], currentSessionID: sessionID)
        ])
    }

    func testFailingInitialDefaultCommitDoesNotReturnAStore() async {
        let persistence = StorePersistence(
            load: { nil },
            commit: { _ in throw TestFailure.failed }
        )

        do {
            _ = try await AnnotationStore(persistence: persistence)
            XCTFail("Expected the initial commit to fail")
        } catch {
            XCTAssertEqual(String(describing: error), "failed")
        }
    }

    func testFailedCommitDoesNotPublishCandidate() async throws {
        let original = document()
        let persistence = StorePersistence(
            load: { original },
            commit: { _ in throw TestFailure.failed }
        )
        var callbackCount = 0
        let store = try await AnnotationStore(persistence: persistence) {
            callbackCount += 1
        }
        let added = annotation(note: "not committed")

        store.mutate(.addAnnotation(sessionID: sessionID, annotation: added))
        await store.waitForIdle()

        XCTAssertEqual(store.currentEntries, [])
        XCTAssertEqual(store.currentSession, original.sessions[0])
        XCTAssertEqual(store.error, .commitFailed("failed"))
        XCTAssertEqual(callbackCount, 0)
    }

    func testCommitFailureRetainsFailedAndLaterMutationsUntilExplicitRetry() async throws {
        let original = document()
        let recorder = AttemptRecorder(failingAttempts: [1])
        let persistence = StorePersistence(
            load: { original },
            commit: { document in try await recorder.commit(document) }
        )
        var callbackCount = 0
        let store = try await AnnotationStore(persistence: persistence) {
            callbackCount += 1
        }
        let first = annotation(note: "first")
        let second = annotation(note: "second")

        store.mutate(.addAnnotation(sessionID: sessionID, annotation: first))
        store.mutate(.addAnnotation(sessionID: sessionID, annotation: second))
        await store.waitForIdle()

        XCTAssertEqual(store.currentEntries, [])
        XCTAssertEqual(store.error, .commitFailed("failed"))
        XCTAssertTrue(store.hasPendingMutations)
        XCTAssertEqual(callbackCount, 0)
        var attempts = await recorder.documents()
        XCTAssertEqual(attempts.map { $0.sessions[0].entries.map(\.note) }, [["first"]])

        store.retryPendingMutations()
        await store.waitForIdle()

        XCTAssertEqual(store.currentEntries, [first, second])
        XCTAssertNil(store.error)
        XCTAssertFalse(store.hasPendingMutations)
        XCTAssertEqual(callbackCount, 2)
        attempts = await recorder.documents()
        XCTAssertEqual(attempts.map { $0.sessions[0].entries.map(\.note) }, [
            ["first"],
            ["first"],
            ["first", "second"],
        ])
    }

    func testRapidMutationsCommitInOrderWithoutLostUpdates() async throws {
        let original = document()
        let recorder = CommitRecorder(delayNanoseconds: 5_000_000)
        let persistence = StorePersistence(
            load: { original },
            commit: { document in try await recorder.recordAfterDelay(document) }
        )
        let store = try await AnnotationStore(persistence: persistence)
        let annotations = [annotation(note: "one"), annotation(note: "two"), annotation(note: "three")]

        for annotation in annotations {
            store.mutate(.addAnnotation(sessionID: sessionID, annotation: annotation))
        }
        await store.waitForIdle()

        XCTAssertEqual(store.currentEntries, annotations)
        let commits = await recorder.documents()
        XCTAssertEqual(commits.map { $0.sessions[0].entries.map(\.note) }, [
            ["one"],
            ["one", "two"],
            ["one", "two", "three"],
        ])
        let maximumInFlightCommitCount = await recorder.maximumInFlightCommitCount()
        XCTAssertEqual(maximumInFlightCommitCount, 1)
    }

    func testSessionTargetStaysStableAcrossQueuedSessionSwitches() async throws {
        let original = document(name: "First")
        let recorder = CommitRecorder()
        let persistence = StorePersistence(
            load: { original },
            commit: { document in await recorder.record(document) }
        )
        let store = try await AnnotationStore(persistence: persistence)
        let second = Session(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            name: "Second",
            createdAt: now
        )
        let capturedForFirst = annotation(note: "captured for First")

        store.mutate(.createSession(second))
        store.mutate(.addAnnotation(sessionID: sessionID, annotation: capturedForFirst))
        await store.waitForIdle()

        XCTAssertEqual(store.currentSessionID, second.id)
        XCTAssertEqual(store.currentEntries, [])

        store.mutate(.switchSession(sessionID: sessionID))
        await store.waitForIdle()
        XCTAssertEqual(store.currentEntries, [capturedForFirst])
    }

    func testCallbackRunsOnlyAfterCommitAndPublishedStateIsVisible() async throws {
        let original = document()
        let commitStarted = expectation(description: "commit started")
        let gate = AsyncGate()
        let persistence = StorePersistence(
            load: { original },
            commit: { _ in
                commitStarted.fulfill()
                await gate.wait()
            }
        )
        var callbackSnapshots: [[Annotation]] = []
        var store: AnnotationStore!
        store = try await AnnotationStore(persistence: persistence) {
            callbackSnapshots.append(store.currentEntries)
        }
        let added = annotation(note: "committed")

        store.mutate(.addAnnotation(sessionID: sessionID, annotation: added))
        await fulfillment(of: [commitStarted], timeout: 1)
        XCTAssertEqual(store.currentEntries, [])
        XCTAssertEqual(callbackSnapshots, [])

        await gate.open()
        await store.waitForIdle()
        XCTAssertEqual(store.currentEntries, [added])
        XCTAssertEqual(callbackSnapshots, [[added]])
    }

    func testNoteAndProvenanceOnlyUpdatesPreserveEachOtherInBothQueueOrders() async throws {
        let base = annotation(note: "Original note")
        let original = StoreDocument(
            sessions: [Session(id: sessionID, name: "First", entries: [base], createdAt: now)],
            currentSessionID: sessionID
        )
        let enriched = Provenance(
            application: base.provenance.application,
            windowTitle: "Focused window",
            url: URL(string: "https://example.com")
        )

        for noteFirst in [true, false] {
            let store = try await AnnotationStore(persistence: StorePersistence(
                load: { original },
                commit: { _ in }
            ))
            let noteMutation = SessionDocumentMutation.updateAnnotationNote(
                sessionID: sessionID,
                annotationID: base.id,
                note: "Edited note"
            )
            let provenanceMutation = SessionDocumentMutation.updateAnnotationProvenance(
                sessionID: sessionID,
                annotationID: base.id,
                expectedApplication: base.provenance.application,
                provenance: enriched
            )
            if noteFirst {
                store.mutate(noteMutation)
                store.mutate(provenanceMutation)
            } else {
                store.mutate(provenanceMutation)
                store.mutate(noteMutation)
            }
            await store.waitForIdle()

            XCTAssertEqual(store.currentEntries.first?.note, "Edited note")
            XCTAssertEqual(store.currentEntries.first?.provenance, enriched)
            XCTAssertEqual(store.currentEntries.first?.subject, base.subject)
            XCTAssertEqual(store.currentEntries.first?.createdAt, base.createdAt)
            store.teardown()
        }
    }

    func testClearBeforeLateProvenanceThenUndoRestoresEnrichment() async throws {
        let original = document()
        let store = try await AnnotationStore(persistence: StorePersistence(
            load: { original },
            commit: { _ in }
        ))
        let base = annotation(note: "Keep")
        let enriched = Provenance(
            application: base.provenance.application,
            windowTitle: "Focused window"
        )

        store.mutate(.addAnnotation(sessionID: sessionID, annotation: base))
        store.mutate(.clearSession(sessionID: sessionID))
        store.mutate(.updateAnnotationProvenance(
            sessionID: sessionID,
            annotationID: base.id,
            expectedApplication: base.provenance.application,
            provenance: enriched
        ))
        store.mutate(.undoClear)
        await store.waitForIdle()

        XCTAssertEqual(store.currentEntries.count, 1)
        XCTAssertEqual(store.currentEntries.first?.id, base.id)
        XCTAssertEqual(store.currentEntries.first?.provenance, enriched)
        store.teardown()
    }

    func testTeardownReleasesWaitersWhenPersistenceIgnoresCancellation() async throws {
        let original = document()
        let commitStarted = expectation(description: "commit started")
        let commitReturned = expectation(description: "commit returned")
        let attempts = CommitAttemptCounter()
        let gate = AsyncGate()
        let persistence = StorePersistence(
            load: { original },
            commit: { _ in
                _ = await attempts.begin()
                commitStarted.fulfill()
                await gate.wait()
                commitReturned.fulfill()
            }
        )
        var callbackCount = 0
        let store = try await AnnotationStore(persistence: persistence) {
            callbackCount += 1
        }

        store.mutate(.addAnnotation(sessionID: sessionID, annotation: annotation(note: "in flight")))
        await fulfillment(of: [commitStarted], timeout: 1)
        store.mutate(.addAnnotation(sessionID: sessionID, annotation: annotation(note: "queued")))
        let idleWaiter = Task { await store.waitForIdle() }
        await Task.yield()

        store.teardown()
        store.teardown()
        await idleWaiter.value

        XCTAssertTrue(store.isTornDown)
        XCTAssertFalse(store.hasPendingMutations)
        XCTAssertEqual(store.currentEntries, [])
        XCTAssertEqual(callbackCount, 0)
        var commitAttemptCount = await attempts.count()
        XCTAssertEqual(commitAttemptCount, 1)

        store.mutate(.addAnnotation(sessionID: sessionID, annotation: annotation(note: "late")))
        XCTAssertEqual(store.error, .tornDown)

        await gate.open()
        await fulfillment(of: [commitReturned], timeout: 1)
        commitAttemptCount = await attempts.count()
        XCTAssertEqual(commitAttemptCount, 1)
        XCTAssertEqual(store.currentEntries, [])
        XCTAssertEqual(callbackCount, 0)
    }

    private func document(name: String = "First") -> StoreDocument {
        StoreDocument(
            sessions: [Session(id: sessionID, name: name, createdAt: now)],
            currentSessionID: sessionID
        )
    }

    private func annotation(note: String) -> Annotation {
        Annotation(
            subject: .standalone,
            note: note,
            provenance: Provenance(application: ApplicationIdentity(name: "Tests")),
            createdAt: now
        )
    }
}

private enum TestFailure: Error, CustomStringConvertible {
    case failed

    var description: String { "failed" }
}

private actor AttemptRecorder {
    private let failingAttempts: Set<Int>
    private var attemptedDocuments: [StoreDocument] = []

    init(failingAttempts: Set<Int>) {
        self.failingAttempts = failingAttempts
    }

    func commit(_ document: StoreDocument) throws {
        attemptedDocuments.append(document)
        if failingAttempts.contains(attemptedDocuments.count) {
            throw TestFailure.failed
        }
    }

    func documents() -> [StoreDocument] {
        attemptedDocuments
    }
}

private actor CommitRecorder {
    private var committed: [StoreDocument] = []
    private var inFlightCommitCount = 0
    private var maximumInFlightCount = 0
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func record(_ document: StoreDocument) {
        committed.append(document)
    }

    func recordAfterDelay(_ document: StoreDocument) async throws {
        inFlightCommitCount += 1
        maximumInFlightCount = max(maximumInFlightCount, inFlightCommitCount)
        defer { inFlightCommitCount -= 1 }
        try await Task.sleep(nanoseconds: delayNanoseconds)
        committed.append(document)
    }

    func documents() -> [StoreDocument] {
        committed
    }

    func maximumInFlightCommitCount() -> Int {
        maximumInFlightCount
    }
}

private actor CommitAttemptCounter {
    private var value = 0

    func begin() -> Int {
        value += 1
        return value
    }

    func count() -> Int {
        value
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}
