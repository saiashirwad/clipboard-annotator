import XCTest
@testable import Sendpoint

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

    private actor ModelDownloadGate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var progress: (@Sendable (Double) -> Void)?
        private(set) var count = 0

        func run(progress: @escaping @Sendable (Double) -> Void) async throws {
            count += 1
            self.progress = progress
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func report(_ fraction: Double) {
            progress?(fraction)
        }

        func succeed() {
            continuation?.resume()
            continuation = nil
        }

        func fail(_ error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private actor MicrophoneRequestGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private(set) var count = 0

        func next() async -> Bool {
            count += 1
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(with granted: Bool) {
            continuation?.resume(returning: granted)
            continuation = nil
        }
    }

    private final class BoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Bool

        init(_ value: Bool) {
            storedValue = value
        }

        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedValue
            }
            set {
                lock.lock()
                storedValue = newValue
                lock.unlock()
            }
        }
    }

    private func services(
        accessibility: AccessibilityPermissionState = .granted,
        requestAccessibility: Bool = true,
        inputMonitoring: InputMonitoringPermissionState = .granted,
        requestInputMonitoring: Bool = true,
        microphone: MicrophonePermissionState = .granted,
        requestMicrophone: Bool = true,
        modelReady: Bool = true,
        modelFilesExist: (@Sendable () -> Bool)? = nil,
        downloadModel: @escaping @Sendable (
            _ onProgress: @escaping @Sendable (Double) -> Void
        ) async throws -> Void = { _ in }
    ) -> PermissionServices {
        PermissionServices(
            accessibilityStatus: { accessibility },
            requestAccessibility: { requestAccessibility },
            inputMonitoringStatus: { inputMonitoring },
            requestInputMonitoring: { requestInputMonitoring },
            microphoneStatus: { microphone },
            requestMicrophone: { requestMicrophone },
            voiceModelFilesExist: modelFilesExist ?? { modelReady },
            downloadVoiceModel: downloadModel,
            openAccessibilitySettings: {},
            openInputMonitoringSettings: {},
            openMicrophoneSettings: {}
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () async -> Bool
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
            for inputMonitoring in [InputMonitoringPermissionState.notGranted, .granted] {
                for microphone in microphoneStates {
                    for modelReady in [false, true] {
                        let state = PermissionState(services: services(
                            accessibility: accessibility,
                            inputMonitoring: inputMonitoring,
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
                            accessibility == .granted
                                && inputMonitoring == .granted
                                && microphone == .granted
                                && modelReady
                        )
                        state.teardown()
                    }
                }
            }
        }
    }

    func testRefreshPublishesAllServiceValues() async {
        let state = PermissionState(services: services(
            accessibility: .notGranted,
            inputMonitoring: .notGranted,
            microphone: .restricted,
            modelReady: false
        ))

        state.refresh()
        XCTAssertEqual(state.accessibility, .checking)
        await state.waitForIdle()

        XCTAssertEqual(state.accessibility, .notGranted)
        XCTAssertEqual(state.inputMonitoring, .notGranted)
        XCTAssertEqual(state.microphone, .restricted)
        XCTAssertEqual(state.localVoiceModel, .notDownloaded)
    }

    func testInitSeedsVoiceModelFromDiskWithoutRefresh() {
        let downloaded = PermissionState(services: services(modelReady: true))
        let absent = PermissionState(services: services(modelReady: false))

        XCTAssertEqual(downloaded.localVoiceModel, .ready)
        XCTAssertEqual(absent.localVoiceModel, .notDownloaded)
        downloaded.teardown()
        absent.teardown()
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

    func testPermissionRequestsPublishSuccessAndDenial() async {
        let granted = PermissionState(services: services(
            accessibility: .notGranted,
            requestAccessibility: true,
            inputMonitoring: .notGranted,
            requestInputMonitoring: true,
            microphone: .notDetermined,
            requestMicrophone: true
        ))
        granted.refresh()
        await granted.waitForIdle()
        granted.requestAccessibility()
        await granted.waitForIdle()
        granted.requestInputMonitoring()
        await granted.waitForIdle()
        granted.requestMicrophone()
        await granted.waitForIdle()
        XCTAssertEqual(granted.accessibility, .granted)
        XCTAssertEqual(granted.inputMonitoring, .granted)
        XCTAssertEqual(granted.microphone, .granted)

        let denied = PermissionState(services: services(
            accessibility: .notGranted,
            requestAccessibility: false,
            inputMonitoring: .notGranted,
            requestInputMonitoring: false,
            microphone: .notDetermined,
            requestMicrophone: false
        ))
        denied.refresh()
        await denied.waitForIdle()
        denied.requestAccessibility()
        await denied.waitForIdle()
        denied.requestInputMonitoring()
        await denied.waitForIdle()
        denied.requestMicrophone()
        await denied.waitForIdle()
        XCTAssertEqual(denied.accessibility, .notGranted)
        XCTAssertEqual(denied.inputMonitoring, .notGranted)
        XCTAssertEqual(denied.microphone, .denied)
    }

    func testRefreshDuringMicrophoneRequestKeepsCheckingState() async {
        let accessibilityGate = AccessibilityGate()
        let microphoneRequestGate = MicrophoneRequestGate()
        let microphoneStatusCalls = Counter()
        var injected = services(microphone: .notDetermined)
        injected.accessibilityStatus = { await accessibilityGate.next() }
        injected.microphoneStatus = {
            let call = await microphoneStatusCalls.incrementAndGet()
            return call == 1 ? .notDetermined : .denied
        }
        injected.requestMicrophone = { await microphoneRequestGate.next() }
        let state = PermissionState(services: injected)

        state.refresh()
        await waitUntil { await accessibilityGate.count == 1 }
        await accessibilityGate.resume(at: 0, with: .granted)
        await state.waitForIdle()
        XCTAssertEqual(state.microphone, .notDetermined)

        state.requestMicrophone()
        await waitUntil { await microphoneRequestGate.count == 1 }
        state.refresh()
        await waitUntil {
            let accessibilityCount = await accessibilityGate.count
            let microphoneCount = await microphoneStatusCalls.value
            return accessibilityCount == 2 && microphoneCount == 2
        }
        await accessibilityGate.resume(at: 1, with: .notGranted)
        await waitUntil { state.accessibility == .notGranted }

        XCTAssertEqual(state.microphone, .checking)

        await microphoneRequestGate.resume(with: true)
        await state.waitForIdle()
        XCTAssertEqual(state.microphone, .granted)
        state.teardown()
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
            downloadModel: { _ in
                let attempt = await attempts.incrementAndGet()
                if attempt == 1 { throw TestError.failed }
            }
        ))

        state.refresh()
        await state.waitForIdle()
        state.downloadModel()
        XCTAssertEqual(state.localVoiceModel, .downloading(progress: nil))
        await state.waitForIdle()
        XCTAssertEqual(state.localVoiceModel, .failed(.other))

        state.downloadModel()
        await state.waitForIdle()
        XCTAssertEqual(state.localVoiceModel, .ready)
        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 2)
    }

    func testRefreshDuringDownloadKeepsDownloadingState() async {
        let files = BoolBox(false)
        let gate = ModelDownloadGate()
        let microphoneCalls = Counter()
        var injected = services(
            modelFilesExist: { files.value },
            downloadModel: { progress in
                try await gate.run(progress: progress)
            }
        )
        injected.microphoneStatus = {
            await microphoneCalls.increment()
            return .granted
        }
        let state = PermissionState(services: injected)

        state.downloadModel()
        await waitUntil { await gate.count == 1 }
        state.refresh()
        await waitUntil { await microphoneCalls.value == 1 }

        XCTAssertEqual(state.localVoiceModel, .downloading(progress: nil))
        XCTAssertNil(state.localVoiceModelAction)

        await gate.succeed()
        await state.waitForIdle()
        XCTAssertEqual(state.localVoiceModel, .ready)
        state.teardown()
    }

    func testModelReadyNotificationPublishesCaptureTimePreparation() {
        let files = BoolBox(false)
        let state = PermissionState(services: services(
            modelFilesExist: { files.value }
        ))
        XCTAssertEqual(state.localVoiceModel, .notDownloaded)

        files.value = true
        NotificationCenter.default.post(name: .voiceModelDidBecomeReady, object: nil)

        XCTAssertEqual(state.localVoiceModel, .ready)
        state.teardown()
    }

    func testReadyNotificationDuringOwnedDownloadKeepsItsCompletionPath() async {
        let files = BoolBox(false)
        let gate = ModelDownloadGate()
        let state = PermissionState(services: services(
            modelFilesExist: { files.value },
            downloadModel: { progress in
                try await gate.run(progress: progress)
            }
        ))
        state.downloadModel()
        await waitUntil { await gate.count == 1 }

        NotificationCenter.default.post(name: .voiceModelDidBecomeReady, object: nil)
        XCTAssertEqual(state.localVoiceModel, .ready)
        await gate.succeed()
        await state.waitForIdle()

        state.refreshVoiceModel()
        XCTAssertEqual(state.localVoiceModel, .notDownloaded)
        state.teardown()
    }

    func testReadyNotificationWinsOverOwnedDownloadFailure() async {
        let files = BoolBox(false)
        let gate = ModelDownloadGate()
        let state = PermissionState(services: services(
            modelFilesExist: { files.value },
            downloadModel: { progress in
                try await gate.run(progress: progress)
            }
        ))
        state.downloadModel()
        await waitUntil { await gate.count == 1 }

        files.value = true
        NotificationCenter.default.post(name: .voiceModelDidBecomeReady, object: nil)
        await gate.fail(TestError.failed)
        await state.waitForIdle()

        XCTAssertEqual(state.localVoiceModel, .ready)
        state.teardown()
    }

    func testVisibleWatcherPicksUpDiskChangesBothWays() async {
        let files = BoolBox(false)
        let state = PermissionState(services: services(
            modelFilesExist: { files.value }
        ))
        let watcher = Task {
            await state.watchVoiceModel(interval: .milliseconds(1))
        }

        files.value = true
        await waitUntil { state.localVoiceModel == .ready }
        files.value = false
        await waitUntil { state.localVoiceModel == .notDownloaded }

        watcher.cancel()
        await watcher.value
        state.teardown()
    }

    func testFailedDownloadSurvivesRefreshAndRecoversWhenFilesAppear() async {
        let files = BoolBox(false)
        let state = PermissionState(services: services(
            modelFilesExist: { files.value },
            downloadModel: { _ in throw TestError.failed }
        ))

        state.downloadModel()
        await state.waitForIdle()
        XCTAssertEqual(state.localVoiceModel, .failed(.other))

        state.refresh()
        await state.waitForIdle()
        XCTAssertEqual(state.localVoiceModel, .failed(.other))

        files.value = true
        state.refreshVoiceModel()
        XCTAssertEqual(state.localVoiceModel, .ready)
        state.teardown()
    }

    func testDownloadProgressIsClampedAndLateProgressIsRejected() async {
        let gate = ModelDownloadGate()
        let state = PermissionState(services: services(
            modelReady: false,
            downloadModel: { progress in
                try await gate.run(progress: progress)
            }
        ))
        state.downloadModel()
        await waitUntil { await gate.count == 1 }

        await gate.report(-0.25)
        await waitUntil { state.localVoiceModel == .downloading(progress: 0) }
        await gate.report(1.25)
        await waitUntil { state.localVoiceModel == .downloading(progress: 1) }

        state.teardown()
        await gate.report(0.5)
        NotificationCenter.default.post(name: .voiceModelDidBecomeReady, object: nil)
        await Task.yield()
        XCTAssertEqual(state.localVoiceModel, .downloading(progress: 1))

        await gate.succeed()
        await Task.yield()
        XCTAssertEqual(state.localVoiceModel, .downloading(progress: 1))
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
            inputMonitoring: .notGranted,
            requestInputMonitoring: false,
            microphone: .notDetermined,
            modelReady: false
        ))

        state.refresh()
        await state.waitForIdle()
        XCTAssertEqual(state.accessibilityAction, .requestAccessibility)
        XCTAssertEqual(state.inputMonitoringAction, .requestInputMonitoring)
        XCTAssertEqual(state.microphoneAction, .requestMicrophone)
        XCTAssertEqual(state.localVoiceModelAction, .downloadVoiceModel)

        state.requestAccessibility()
        await state.waitForIdle()
        XCTAssertEqual(state.accessibilityAction, .showAccessibilityHelper)
        state.requestInputMonitoring()
        await state.waitForIdle()
        XCTAssertEqual(state.inputMonitoringAction, .showInputMonitoringHelper)

        let blocked = PermissionState(services: services(
            microphone: .restricted,
            modelReady: true
        ))
        blocked.refresh()
        await blocked.waitForIdle()
        XCTAssertNil(blocked.accessibilityAction)
        XCTAssertNil(blocked.inputMonitoringAction)
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
        state.requestInputMonitoring()
        state.requestMicrophone()
        state.downloadModel()
        await state.waitForIdle()
        XCTAssertEqual(state.accessibility, .checking)
        XCTAssertEqual(state.localVoiceModel, .ready)
    }
}
