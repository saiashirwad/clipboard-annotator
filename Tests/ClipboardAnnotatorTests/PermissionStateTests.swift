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
        downloadModel: @escaping @Sendable () async throws -> Void = {},
        heliumInstalled: Bool = false,
        helium: HeliumAutomationPermissionState = .notInstalled,
        requestHelium: Bool = true,
        heliumStatusCall: (@Sendable () async -> HeliumAutomationPermissionState)? = nil
    ) -> PermissionServices {
        PermissionServices(
            accessibilityStatus: { accessibility },
            requestAccessibility: { requestAccessibility },
            microphoneStatus: { microphone },
            requestMicrophone: { requestMicrophone },
            voiceModelIsReady: { modelReady },
            downloadVoiceModel: downloadModel,
            heliumIsInstalled: { heliumInstalled },
            heliumAutomationStatus: heliumStatusCall ?? { helium },
            requestHeliumAutomation: { requestHelium },
            openAccessibilitySettings: {},
            openMicrophoneSettings: {},
            openHeliumAutomationSettings: {}
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
                        modelReady: modelReady,
                        heliumInstalled: true,
                        helium: .denied
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
            modelReady: false,
            heliumInstalled: true,
            helium: .notDetermined
        ))

        state.refresh()
        XCTAssertEqual(state.accessibility, .checking)
        await state.waitForIdle()

        XCTAssertEqual(state.accessibility, .notGranted)
        XCTAssertEqual(state.microphone, .restricted)
        XCTAssertEqual(state.localVoiceModel, .notDownloaded)
        XCTAssertTrue(state.heliumInstalled)
        XCTAssertEqual(state.heliumAutomation, .notDetermined)
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
            requestAccessibility: true,
            requestMicrophone: true
        ))
        granted.requestAccessibility()
        await granted.waitForIdle()
        granted.requestMicrophone()
        await granted.waitForIdle()
        XCTAssertEqual(granted.accessibility, .granted)
        XCTAssertEqual(granted.microphone, .granted)

        let denied = PermissionState(services: services(
            requestAccessibility: false,
            requestMicrophone: false
        ))
        denied.requestAccessibility()
        await denied.waitForIdle()
        denied.requestMicrophone()
        await denied.waitForIdle()
        XCTAssertEqual(denied.accessibility, .notGranted)
        XCTAssertEqual(denied.microphone, .denied)
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

    func testHeliumAbsentSkipsAutomationAndNeverBlocksReadiness() async {
        let statusCalls = Counter()
        let absent = PermissionState(services: services(
            heliumInstalled: false,
            heliumStatusCall: {
                await statusCalls.increment()
                return .granted
            }
        ))

        absent.refresh()
        await absent.waitForIdle()
        XCTAssertFalse(absent.heliumInstalled)
        XCTAssertEqual(absent.heliumAutomation, .notInstalled)
        let statusCallCount = await statusCalls.value
        XCTAssertEqual(statusCallCount, 0)
        XCTAssertTrue(absent.isTextCaptureReady)
        XCTAssertTrue(absent.isVoiceReady)

        absent.requestHeliumAutomation()
        await absent.waitForIdle()
        XCTAssertEqual(absent.heliumAutomation, .notInstalled)

        let denied = PermissionState(services: services(
            heliumInstalled: true,
            helium: .denied
        ))
        denied.refresh()
        await denied.waitForIdle()
        XCTAssertEqual(denied.heliumAutomation, .denied)
        XCTAssertTrue(denied.isTextCaptureReady)
        XCTAssertTrue(denied.isVoiceReady)
    }

    func testHeliumRequestPublishesSuccessAndDenial() async {
        let granted = PermissionState(services: services(
            heliumInstalled: true,
            helium: .notDetermined,
            requestHelium: true
        ))
        granted.refresh()
        await granted.waitForIdle()
        granted.requestHeliumAutomation()
        await granted.waitForIdle()
        XCTAssertEqual(granted.heliumAutomation, .granted)

        let denied = PermissionState(services: services(
            heliumInstalled: true,
            helium: .notDetermined,
            requestHelium: false
        ))
        denied.refresh()
        await denied.waitForIdle()
        denied.requestHeliumAutomation()
        await denied.waitForIdle()
        XCTAssertEqual(denied.heliumAutomation, .denied)
        XCTAssertTrue(denied.isTextCaptureReady)
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
        state.requestHeliumAutomation()
        await state.waitForIdle()
        XCTAssertEqual(state.accessibility, .checking)
        XCTAssertEqual(state.localVoiceModel, .checking)
    }
}
