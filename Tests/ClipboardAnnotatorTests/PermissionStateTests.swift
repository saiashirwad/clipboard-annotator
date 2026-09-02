import XCTest
@testable import ClipboardAnnotator

@MainActor
final class PermissionStateTests: XCTestCase {
    private enum TestError: Error {
        case failed
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
        func incrementAndGet() -> Int {
            value += 1
            return value
        }
    }

    private actor AccessibilityGate {
        private var continuations: [CheckedContinuation<AccessibilityPermissionState, Never>] = []

        func next() async -> AccessibilityPermissionState {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        var count: Int { continuations.count }

        func resume(at index: Int, with value: AccessibilityPermissionState) {
            continuations[index].resume(returning: value)
        }
    }

    private func services(
        accessibility: AccessibilityPermissionState = .granted,
        requestAccessibility: Bool = true,
        microphone: MicrophonePermissionState = .granted,
        requestMicrophone: Bool = true,
        modelReady: Bool = true,
        downloadModel: @escaping @Sendable () async throws -> Void = {}
    ) -> PermissionServices {
        PermissionServices(
            accessibilityStatus: { accessibility },
            requestAccessibility: { requestAccessibility },
            microphoneStatus: { microphone },
            requestMicrophone: { requestMicrophone },
            voiceModelIsReady: { modelReady },
            downloadVoiceModel: downloadModel,
            openAccessibilitySettings: {},
            openMicrophoneSettings: {}
        )
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous test work")
    }

    func testReadinessMatrixRequiresAccessibilityForTextAndAllVoiceRequirements() async {
        let accessibilityStates: [AccessibilityPermissionState] = [.notGranted, .granted]
        let microphoneStates: [MicrophonePermissionState] = [
            .notDetermined, .denied, .restricted, .granted,
        ]

        for accessibility in accessibilityStates {
            for microphone in microphoneStates {
                for modelReady in [false, true] {
                    let state = PermissionState(services: services(
                        accessibility: accessibility,
                        microphone: microphone,
                        modelReady: modelReady
                    ))
                    state.refresh()
                    await state.waitForIdle()

                    XCTAssertEqual(
                        state.isTextCaptureReady,
                        accessibility == .granted
                    )
                    XCTAssertEqual(
                        state.isVoiceReady,
                        accessibility == .granted && microphone == .granted && modelReady
                    )
                    state.teardown()
                }
            }
        }
    }

    func testRefreshPublishesAllServiceValues() async {
        let state = PermissionState(services: services(
            accessibility: .notGranted,
            microphone: .restricted,
            modelReady: false
        ))

        state.refresh()
        XCTAssertEqual(state.accessibility, .checking)
        await state.waitForIdle()

        XCTAssertEqual(state.accessibility, .notGranted)
        XCTAssertEqual(state.microphone, .restricted)
        XCTAssertEqual(state.localVoiceModel, .notDownloaded)
    }

    func testOverlappingRefreshRejectsOlderResultEvenWhenItIgnoresCancellation() async {
        let gate = AccessibilityGate()
        var injected = services()
        injected.accessibilityStatus = { await gate.next() }
        let state = PermissionState(services: injected)

        state.refresh()
        await waitUntil { await gate.count == 1 }
        state.refresh()
        await waitUntil { await gate.count == 2 }

        await gate.resume(at: 1, with: .granted)
        await state.waitForIdle()
        XCTAssertEqual(state.accessibility, .granted)

        state.refresh()
        await waitUntil { await gate.count == 3 }
        XCTAssertEqual(state.accessibility, .granted)
        await gate.resume(at: 2, with: .notGranted)
        await state.waitForIdle()
        XCTAssertEqual(state.accessibility, .notGranted)

        await gate.resume(at: 0, with: .granted)
        await Task.yield()
        XCTAssertEqual(state.accessibility, .notGranted)
    }

    func testAccessibilityAndMicrophoneRequestsPublishSuccessAndDenial() async {
        let granted = PermissionState(services: services(
            accessibility: .notGranted,
            requestAccessibility: true,
            microphone: .notDetermined,
            requestMicrophone: true
        ))
        granted.refresh()
        await granted.waitForIdle()
        granted.requestAccessibility()
        await granted.waitForIdle()
        granted.requestMicrophone()
        await granted.waitForIdle()
        XCTAssertEqual(granted.accessibility, .granted)
        XCTAssertEqual(granted.microphone, .granted)

        let denied = PermissionState(services: services(
            accessibility: .notGranted,
            requestAccessibility: false,
            microphone: .notDetermined,
            requestMicrophone: false
        ))
        denied.refresh()
        await denied.waitForIdle()
        denied.requestAccessibility()
        await denied.waitForIdle()
        denied.requestMicrophone()
        await denied.waitForIdle()
        XCTAssertEqual(denied.accessibility, .notGranted)
        XCTAssertEqual(denied.microphone, .denied)
    }

    func testLocalVoiceModelReadinessIncludesFilesPersistedAcrossLaunch() async {
        let downloaded = LocalVoiceTranscriber(modelsAreDownloaded: { true })
        let absent = LocalVoiceTranscriber(modelsAreDownloaded: { false })

        let downloadedIsReady = await downloaded.isReady()
        let absentIsReady = await absent.isReady()

        XCTAssertTrue(downloadedIsReady)
        XCTAssertFalse(absentIsReady)
    }

    func testModelDownloadFailureCanRetryAndSucceed() async {
        let attempts = Counter()
        let state = PermissionState(services: services(
            modelReady: false,
            downloadModel: {
                let attempt = await attempts.incrementAndGet()
                if attempt == 1 { throw TestError.failed }
            }
        ))

        state.refresh()
        await state.waitForIdle()
        state.downloadModel()
        XCTAssertEqual(state.localVoiceModel, .downloading)
        await state.waitForIdle()
        XCTAssertEqual(state.localVoiceModel, .failed)

        state.downloadModel()
        await state.waitForIdle()
        XCTAssertEqual(state.localVoiceModel, .ready)
        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 2)
    }

    func testScopedAccessibilityRefreshDoesNotRestartAndIsOwnedByIdleAndTeardown() async {
        let gate = AccessibilityGate()
        let microphoneCalls = Counter()
        var injected = services()
        injected.accessibilityStatus = { await gate.next() }
        injected.microphoneStatus = {
            await microphoneCalls.increment()
            return .granted
        }
        let state = PermissionState(services: injected)

        state.refreshAccessibility()
        state.refreshAccessibility()
        await waitUntil { await gate.count == 1 }
        let microphoneCallCount = await microphoneCalls.value
        XCTAssertEqual(microphoneCallCount, 0)

        let idleCompletions = Counter()
        let waiter = Task {
            await state.waitForIdle()
            await idleCompletions.increment()
        }
        await Task.yield()
        let completionsBeforeResume = await idleCompletions.value
        XCTAssertEqual(completionsBeforeResume, 0)

        await gate.resume(at: 0, with: .granted)
        await waiter.value
        XCTAssertEqual(state.accessibility, .granted)
        let completionsAfterResume = await idleCompletions.value
        XCTAssertEqual(completionsAfterResume, 1)

        state.refreshAccessibility()
        await waitUntil { await gate.count == 2 }
        state.teardown()
        state.teardown()
        await gate.resume(at: 1, with: .notGranted)
        await Task.yield()
        XCTAssertEqual(state.accessibility, .granted)
    }

    func testActionsRouteFromLivePermissionStates() async {
        let state = PermissionState(services: services(
            accessibility: .notGranted,
            requestAccessibility: false,
            microphone: .notDetermined,
            modelReady: false
        ))

        state.refresh()
        await state.waitForIdle()
        XCTAssertEqual(state.accessibilityAction, .requestAccessibility)
        XCTAssertEqual(state.microphoneAction, .requestMicrophone)
        XCTAssertEqual(state.localVoiceModelAction, .downloadVoiceModel)

        state.requestAccessibility()
        await state.waitForIdle()
        XCTAssertEqual(state.accessibilityAction, .showAccessibilityHelper)

        let blocked = PermissionState(services: services(
            microphone: .restricted,
            modelReady: true
        ))
        blocked.refresh()
        await blocked.waitForIdle()
        XCTAssertNil(blocked.accessibilityAction)
        XCTAssertEqual(blocked.microphoneAction, .openMicrophoneSettings)
        XCTAssertNil(blocked.localVoiceModelAction)
    }

    func testTeardownIsIdempotentAndRejectsLateRefreshResult() async {
        let gate = AccessibilityGate()
        var injected = services()
        injected.accessibilityStatus = { await gate.next() }
        let state = PermissionState(services: injected)

        state.refresh()
        await waitUntil { await gate.count == 1 }
        state.teardown()
        state.teardown()
        await gate.resume(at: 0, with: .granted)
        await Task.yield()

        XCTAssertEqual(state.accessibility, .checking)
        XCTAssertFalse(state.isTextCaptureReady)
        state.refresh()
        state.requestAccessibility()
        state.requestMicrophone()
        state.downloadModel()
        await state.waitForIdle()
        XCTAssertEqual(state.accessibility, .checking)
        XCTAssertEqual(state.localVoiceModel, .checking)
    }
}
