import ClipboardAnnotatorDomain
import Foundation
import XCTest
@testable import ClipboardAnnotator

final class ProvenanceProbeTests: XCTestCase {
    private let application = CapturedApplication(
        identity: ApplicationIdentity(name: "Example", bundleID: "com.example.app"),
        processIdentifier: 42
    )

    func testUnknownApplicationReturnsGenericBaselineWithoutCallingEnricher() async {
        let calls = Counter()
        let probe = ProvenanceProbe(
            genericLookup: { _ in ProvenanceFields(windowTitle: "Generic window") },
            enrichers: [
                "com.other.app": { _ in
                    await calls.increment()
                    return ProvenanceFields(url: URL(string: "https://example.com"))
                },
            ]
        )

        let result = await probe.probe(application)

        XCTAssertEqual(
            result,
            Provenance(application: application.identity, windowTitle: "Generic window")
        )
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testRegisteredEnrichmentMergesAndFailureFallsBackToBaseline() async {
        let directory = URL(fileURLWithPath: "/tmp/project")
        let page = URL(string: "https://example.com/article")!
        let merged = ProvenanceProbe(
            genericLookup: { _ in
                ProvenanceFields(windowTitle: "Generic window", workingDirectory: directory)
            },
            enrichers: [
                "com.example.app": { _ in
                    ProvenanceFields(windowTitle: "Active tab", url: page)
                },
            ]
        )
        let mergedResult = await merged.probe(application)
        XCTAssertEqual(
            mergedResult,
            Provenance(
                application: application.identity,
                windowTitle: "Active tab",
                url: page,
                workingDirectory: directory
            )
        )

        let failing = ProvenanceProbe(
            genericLookup: { _ in ProvenanceFields(windowTitle: "Generic window") },
            enrichers: ["com.example.app": { _ in throw TestError.denied }]
        )
        let failingResult = await failing.probe(application)
        XCTAssertEqual(
            failingResult,
            Provenance(application: application.identity, windowTitle: "Generic window")
        )
    }

    func testCancellationAfterGenericLookupStopsBeforeEnrichment() async {
        let calls = Counter()
        let probe = ProvenanceProbe(
            genericLookup: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return ProvenanceFields(windowTitle: "Generic window")
            },
            enrichers: [
                "com.example.app": { _ in
                    await calls.increment()
                    return ProvenanceFields(windowTitle: "Should not run")
                },
            ]
        )

        let result = await probe.probe(application)

        XCTAssertEqual(result, Provenance(application: application.identity))
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testCapturedProcessIdentityIsCheckedBeforeAndAfterEveryLookup() async {
        let genericCalls = Counter()
        let recycledDuringGeneric = ValidationSequence([true, false])
        let genericProbe = ProvenanceProbe(
            validateApplication: { _ in await recycledDuringGeneric.next() },
            genericLookup: { _ in
                await genericCalls.increment()
                return ProvenanceFields(windowTitle: "Wrong process")
            }
        )
        let genericResult = await genericProbe.probe(application)
        XCTAssertEqual(genericResult, Provenance(application: application.identity))
        let genericCallCount = await genericCalls.current()
        XCTAssertEqual(genericCallCount, 1)

        let enrichmentCalls = Counter()
        let recycledDuringEnrichment = ValidationSequence([true, true, true, false])
        let enrichmentProbe = ProvenanceProbe(
            validateApplication: { _ in await recycledDuringEnrichment.next() },
            genericLookup: { _ in ProvenanceFields(windowTitle: "Generic window") },
            enrichers: [
                "com.example.app": { _ in
                    await enrichmentCalls.increment()
                    return ProvenanceFields(windowTitle: "Wrong enrichment")
                },
            ]
        )
        let enrichmentResult = await enrichmentProbe.probe(application)
        XCTAssertEqual(
            enrichmentResult,
            Provenance(application: application.identity, windowTitle: "Generic window")
        )
        let enrichmentCallCount = await enrichmentCalls.current()
        XCTAssertEqual(enrichmentCallCount, 1)
    }

    func testEditorBundleRoutingCoversVSCodeCursorWindsurfVSCodiumZedAndCodeOSS() {
        let identifiers = ProvenanceProbe.codeEditorBundleIDs
        for bundleID in [
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            "com.todesktop.230313mzl4w4u92", "co.anysphere.cursor.nightly",
            "com.exafunction.windsurf", "com.vscodium.VSCodium",
            "dev.zed.Zed", "com.visualstudio.code.oss",
        ] {
            XCTAssertTrue(identifiers.contains(bundleID), bundleID)
        }
    }

    func testGhosttyPathParsingThroughInjectedEnricherKeepsGenericFallback() async {
        let ghostty = CapturedApplication(
            identity: ApplicationIdentity(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
            processIdentifier: 8
        )
        let valid = ProvenanceProbe(
            genericLookup: { _ in ProvenanceFields(windowTitle: "Terminal") },
            enrichers: [
                "com.mitchellh.ghostty": { _ in
                    ProvenanceFields(
                        workingDirectory: ProvenanceFileURLParser.absoluteFileURL(
                            "file:///tmp/project"
                        )
                    )
                },
            ]
        )
        let validResult = await valid.probe(ghostty)
        XCTAssertEqual(validResult.windowTitle, "Terminal")
        XCTAssertEqual(validResult.workingDirectory, URL(fileURLWithPath: "/tmp/project"))

        let unsafe = ProvenanceProbe(
            genericLookup: { _ in ProvenanceFields(windowTitle: "Terminal") },
            enrichers: [
                "com.mitchellh.ghostty": { _ in
                    ProvenanceFields(
                        workingDirectory: ProvenanceFileURLParser.absoluteFileURL(
                            "file://remote-host/tmp/private"
                        )
                    )
                },
            ]
        )
        let unsafeResult = await unsafe.probe(ghostty)
        XCTAssertEqual(
            unsafeResult,
            Provenance(application: ghostty.identity, windowTitle: "Terminal")
        )
    }

    func testHeliumResultParsingThroughInjectedEnricherAcceptsOnlyWebURL() async {
        let helium = CapturedApplication(
            identity: ApplicationIdentity(name: "Helium", bundleID: "net.imput.helium"),
            processIdentifier: 7
        )
        let valid = ProvenanceProbe(
            genericLookup: { _ in ProvenanceFields(windowTitle: "Helium") },
            enrichers: [
                "net.imput.helium": { _ in
                    HeliumActiveTabParser.fields(
                        from: "Article title\nhttps://example.com/story?item=1"
                    )
                },
            ]
        )
        let validResult = await valid.probe(helium)
        XCTAssertEqual(
            validResult,
            Provenance(
                application: helium.identity,
                windowTitle: "Article title",
                url: URL(string: "https://example.com/story?item=1")
            )
        )

        for unsafe in [
            "file:///tmp/private",
            "javascript:alert(1)",
            "relative/path",
            "https://user:password@example.com/private",
        ] {
            let fields = HeliumActiveTabParser.fields(from: "Title\n\(unsafe)")
            XCTAssertEqual(fields.windowTitle, "Title")
            XCTAssertNil(fields.url, unsafe)
        }
    }

    private enum TestError: Error { case denied }

    private actor Counter {
        private var count = 0
        func increment() { count += 1 }
        func current() -> Int { count }
        var value: Int { count }
    }

    private actor ValidationSequence {
        private var values: [Bool]

        init(_ values: [Bool]) {
            self.values = values
        }

        func next() -> Bool {
            values.isEmpty ? false : values.removeFirst()
        }
    }
}

@MainActor
final class PendingProvenanceWorkOwnerTests: XCTestCase {
    func testProbeCompletionBeforeSaveEnrichesInitialAnnotation() async throws {
        let gate = FieldsGate()
        var updates: [SessionDocumentMutation] = []
        let owner = makeOwner(gate: gate) { updates.append($0) }
        let target = makeTarget()
        owner.start(for: target)

        XCTAssertEqual(owner.pendingCount, 1)
        await gate.resolve(ProvenanceFields(windowTitle: "Focused window"))
        await owner.waitForIdle()

        let baseline = try XCTUnwrap(CaptureAnnotationPolicy.annotation(for: target, note: "Note"))
        let saved = owner.annotationForSave(baseline, target: target)

        XCTAssertEqual(saved.provenance.windowTitle, "Focused window")
        XCTAssertEqual(owner.pendingCount, 0)
        XCTAssertTrue(updates.isEmpty)
    }

    func testSaveBeforeProbeCompletionRetainsTaskAndRoutesExactLateUpdate() async throws {
        let gate = FieldsGate()
        var updates: [SessionDocumentMutation] = []
        let owner = makeOwner(gate: gate) { updates.append($0) }
        let target = makeTarget()
        owner.start(for: target)

        let baseline = try XCTUnwrap(CaptureAnnotationPolicy.annotation(for: target, note: "Note"))
        XCTAssertEqual(owner.annotationForSave(baseline, target: target), baseline)
        owner.cancelBeforeSave(for: target) // successful UI teardown must not cancel saved work
        XCTAssertEqual(owner.pendingTaskCount, 1)

        let enriched = Provenance(
            application: target.application,
            windowTitle: "Focused window",
            url: URL(string: "https://example.com")
        )
        await gate.resolve(ProvenanceFields(
            windowTitle: enriched.windowTitle,
            url: enriched.url
        ))
        await owner.waitForIdle()
        XCTAssertEqual(updates.count, 1)

        guard case let .updateAnnotationProvenance(
            sessionID,
            annotationID,
            expectedApplication,
            provenance
        ) = updates[0] else {
            return XCTFail("Expected exact provenance update")
        }
        XCTAssertEqual(sessionID, target.sessionID)
        XCTAssertEqual(annotationID, target.annotationID)
        XCTAssertEqual(expectedApplication, target.application)
        XCTAssertEqual(provenance, enriched)
        XCTAssertEqual(owner.pendingCount, 0)
    }

    func testLateUpdateUsesOriginalSessionAfterCommittedSessionSwitch() async throws {
        let original = Session(name: "Original")
        let other = Session(name: "Other")
        let document = StoreDocument(
            sessions: [original, other],
            currentSessionID: original.id
        )
        let store = try await AnnotationStore(persistence: StorePersistence(
            load: { document },
            commit: { _ in }
        ))
        let gate = FieldsGate()
        let owner = makeOwner(gate: gate) { store.mutate($0) }
        let target = makeTarget(sessionID: original.id)
        owner.start(for: target)

        let baseline = try XCTUnwrap(CaptureAnnotationPolicy.annotation(for: target, note: "Note"))
        let initial = owner.annotationForSave(baseline, target: target)
        store.mutate(.addAnnotation(sessionID: original.id, annotation: initial))
        store.mutate(.switchSession(sessionID: other.id))

        await gate.resolve(ProvenanceFields(windowTitle: "Original window"))
        await owner.waitForIdle()
        await store.waitForIdle()

        XCTAssertEqual(store.currentSessionID, other.id)
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == original.id })?.entries.first?.provenance.windowTitle,
            "Original window"
        )
        XCTAssertTrue(store.currentEntries.isEmpty)
        store.teardown()
    }

    func testLateUpdateDoesNotResurrectRemovedAnnotation() async throws {
        let original = Session(name: "Original")
        let document = StoreDocument(sessions: [original], currentSessionID: original.id)
        let store = try await AnnotationStore(persistence: StorePersistence(
            load: { document },
            commit: { _ in }
        ))
        let gate = FieldsGate()
        let owner = makeOwner(gate: gate) { store.mutate($0) }
        let target = makeTarget(sessionID: original.id)
        owner.start(for: target)

        let baseline = try XCTUnwrap(CaptureAnnotationPolicy.annotation(for: target, note: "Note"))
        let initial = owner.annotationForSave(baseline, target: target)
        store.mutate(.addAnnotation(sessionID: original.id, annotation: initial))
        store.mutate(.removeAnnotation(
            sessionID: original.id,
            annotationID: target.annotationID
        ))
        await store.waitForIdle()
        XCTAssertTrue(store.currentEntries.isEmpty)

        await gate.resolve(ProvenanceFields(windowTitle: "Late window"))
        await owner.waitForIdle()
        await store.waitForIdle()

        XCTAssertTrue(store.currentEntries.isEmpty)
        XCTAssertFalse(store.hasPendingMutations)
        store.teardown()
    }

    func testUnsavedCancelAndAppTeardownRejectLateResults() async {
        let firstGate = FieldsGate()
        var firstUpdates: [SessionDocumentMutation] = []
        let first = makeOwner(gate: firstGate) { firstUpdates.append($0) }
        let firstTarget = makeTarget()
        first.start(for: firstTarget)
        first.cancelBeforeSave(for: firstTarget)
        await firstGate.resolve(ProvenanceFields(windowTitle: "Late"))
        XCTAssertEqual(first.pendingCount, 0)
        XCTAssertTrue(firstUpdates.isEmpty)

        let secondGate = FieldsGate()
        var secondUpdates: [SessionDocumentMutation] = []
        let second = makeOwner(gate: secondGate) { secondUpdates.append($0) }
        let secondTarget = makeTarget()
        second.start(for: secondTarget)
        second.teardown()
        await secondGate.resolve(ProvenanceFields(windowTitle: "Late"))
        XCTAssertTrue(second.isTornDown)
        XCTAssertEqual(second.pendingCount, 0)
        XCTAssertTrue(secondUpdates.isEmpty)
    }

    func testStaleTargetCannotCancelOrMarkAnotherCaptureSaved() async throws {
        let gate = FieldsGate()
        var updates: [SessionDocumentMutation] = []
        let owner = makeOwner(gate: gate) { updates.append($0) }
        let target = makeTarget()
        owner.start(for: target)

        let staleContext = AnnotationCaptureContext(
            sessionID: UUID(),
            captureID: target.captureID,
            annotationID: UUID()
        )
        let staleTarget = staleContext.target(captured: CapturedSelection(
            text: "Different",
            appName: "Other",
            appBundleID: "com.example.other",
            processIdentifier: 99,
            screenRect: nil
        ))
        let staleAnnotation = try XCTUnwrap(
            CaptureAnnotationPolicy.annotation(for: staleTarget, note: "Stale")
        )
        XCTAssertEqual(
            owner.annotationForSave(staleAnnotation, target: staleTarget),
            staleAnnotation
        )
        owner.cancelBeforeSave(for: staleTarget)
        XCTAssertEqual(owner.pendingCount, 1)

        await gate.resolve(ProvenanceFields(windowTitle: "Original"))
        await owner.waitForIdle()
        XCTAssertTrue(updates.isEmpty)

        let original = try XCTUnwrap(CaptureAnnotationPolicy.annotation(for: target, note: "Real"))
        XCTAssertEqual(
            owner.annotationForSave(original, target: target).provenance.windowTitle,
            "Original"
        )
    }

    private func makeOwner(
        gate: FieldsGate,
        update: @escaping @MainActor (SessionDocumentMutation) -> Void
    ) -> PendingProvenanceWorkOwner {
        PendingProvenanceWorkOwner(
            probe: ProvenanceProbe(genericLookup: { _ in await gate.value() }),
            lateUpdate: update
        )
    }

    private func makeTarget(sessionID: UUID = UUID()) -> AnnotationCaptureTarget {
        AnnotationCaptureContext(sessionID: sessionID).target(captured: CapturedSelection(
            text: "Selection",
            appName: "Reader",
            appBundleID: "com.example.reader",
            processIdentifier: 42,
            screenRect: nil
        ))
    }

    private actor FieldsGate {
        private var result: ProvenanceFields?
        private var continuation: CheckedContinuation<ProvenanceFields, Never>?

        func value() async -> ProvenanceFields {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }

        func resolve(_ fields: ProvenanceFields) {
            guard result == nil else { return }
            result = fields
            continuation?.resume(returning: fields)
            continuation = nil
        }
    }
}
