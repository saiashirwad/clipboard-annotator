import XCTest
@testable import ClipboardAnnotator

final class VoiceCaptureLifecycleTests: XCTestCase {
    private func identity(_ value: UInt8 = 1) -> VoiceCaptureIdentity {
        func id(_ tail: UInt8) -> UUID {
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value, tail))
        }
        return VoiceCaptureIdentity(
            captureID: id(1),
            annotationID: id(2),
            sessionID: id(3)
        )
    }

    func testReleaseDuringSelectionIsRetainedUntilAlreadyStartedRecordingCanTranscribe() {
        let identity = identity()
        var lifecycle = VoiceCaptureLifecycle(identity: identity)

        XCTAssertEqual(lifecycle.recordingStarted(for: identity), .none)
        XCTAssertEqual(lifecycle.release(for: identity), .none)
        XCTAssertEqual(
            lifecycle.phase,
            .selecting(releaseRequested: true, recordingStarted: true)
        )
        XCTAssertEqual(lifecycle.selectionCompleted(for: identity), .beginTranscription)
        XCTAssertEqual(lifecycle.phase, .transcribing(.transcribing))
    }

    func testReleaseDuringSelectionWithoutRecordingDismissesAndRejectsLateStartup() {
        let identity = identity()
        var lifecycle = VoiceCaptureLifecycle(identity: identity)

        XCTAssertEqual(lifecycle.release(for: identity), .dismiss)
        XCTAssertEqual(lifecycle.phase, .dismissed)
        XCTAssertEqual(lifecycle.selectionCompleted(for: identity), .none)
        XCTAssertEqual(lifecycle.recordingStarted(for: identity), .none)
        XCTAssertEqual(lifecycle.phase, .dismissed)
    }

    func testReleaseDuringStartupDismissesAndRejectsLateRecordingStart() {
        let identity = identity()
        var lifecycle = VoiceCaptureLifecycle(identity: identity)

        XCTAssertEqual(lifecycle.selectionCompleted(for: identity), .none)
        XCTAssertEqual(lifecycle.phase, .starting)
        XCTAssertEqual(lifecycle.release(for: identity), .dismiss)
        XCTAssertEqual(lifecycle.phase, .dismissed)
        XCTAssertEqual(lifecycle.recordingStarted(for: identity), .none)
        XCTAssertEqual(lifecycle.phase, .dismissed)
    }

    func testNormalReleaseBeginsTranscriptionExactlyOnce() {
        let identity = identity()
        var lifecycle = VoiceCaptureLifecycle(identity: identity)
        _ = lifecycle.selectionCompleted(for: identity)
        _ = lifecycle.recordingStarted(for: identity)

        XCTAssertEqual(lifecycle.phase, .recording)
        XCTAssertEqual(lifecycle.release(for: identity), .beginTranscription)
        XCTAssertEqual(lifecycle.release(for: identity), .none)
        XCTAssertEqual(lifecycle.phase, .transcribing(.transcribing))
    }

    func testCancelIsIdempotentInEveryPhase() {
        let identity = identity()
        let failureID = UUID()
        var lifecycles: [VoiceCaptureLifecycle] = []

        lifecycles.append(VoiceCaptureLifecycle(identity: identity))

        var starting = VoiceCaptureLifecycle(identity: identity)
        _ = starting.selectionCompleted(for: identity)
        lifecycles.append(starting)

        var recording = starting
        _ = recording.recordingStarted(for: identity)
        lifecycles.append(recording)

        var transcribing = recording
        _ = transcribing.release(for: identity)
        lifecycles.append(transcribing)

        var preparingModel = transcribing
        preparingModel.modelPreparationBegan(for: identity)
        lifecycles.append(preparingModel)

        var failed = recording
        _ = failed.fail(for: identity, message: "Failed", failureID: failureID)
        lifecycles.append(failed)

        for index in lifecycles.indices {
            XCTAssertEqual(lifecycles[index].cancel(), .dismiss)
            XCTAssertEqual(lifecycles[index].phase, .dismissed)
            XCTAssertEqual(lifecycles[index].cancel(), .none)
        }
    }

    func testStaleLifecycleEventsCannotChangePhase() {
        let identity = identity(1)
        let staleIdentity = self.identity(2)
        var lifecycle = VoiceCaptureLifecycle(identity: identity)

        XCTAssertEqual(lifecycle.release(for: staleIdentity), .none)
        XCTAssertEqual(lifecycle.selectionCompleted(for: staleIdentity), .none)
        XCTAssertEqual(lifecycle.recordingStarted(for: staleIdentity), .none)
        XCTAssertEqual(
            lifecycle.fail(for: staleIdentity, message: "stale", failureID: UUID()),
            .none
        )
        XCTAssertEqual(lifecycle.phase, .selecting(releaseRequested: false, recordingStarted: false))

        _ = lifecycle.recordingStarted(for: identity)
        _ = lifecycle.selectionCompleted(for: identity)
        _ = lifecycle.release(for: identity)
        XCTAssertEqual(lifecycle.transcriptionSucceeded(for: staleIdentity), .none)
        XCTAssertEqual(lifecycle.phase, .transcribing(.transcribing))
    }

    func testFailureTimeoutMustMatchCaptureAndFailureIdentity() {
        let identity = identity(1)
        let staleIdentity = self.identity(2)
        let failureID = UUID()
        var lifecycle = VoiceCaptureLifecycle(identity: identity)
        _ = lifecycle.fail(for: identity, message: "No speech was found.", failureID: failureID)

        XCTAssertEqual(
            lifecycle.failureTimeout(for: staleIdentity, failureID: failureID),
            .none
        )
        XCTAssertEqual(
            lifecycle.failureTimeout(for: identity, failureID: UUID()),
            .none
        )
        XCTAssertEqual(
            lifecycle.phase,
            .failed(message: "No speech was found.", failureID: failureID)
        )
        XCTAssertEqual(
            lifecycle.failureTimeout(for: identity, failureID: failureID),
            .dismiss
        )
        XCTAssertEqual(lifecycle.phase, .dismissed)
    }
}

final class SharedAsyncPreparationTests: XCTestCase {
    private enum TestError: Error {
        case failed
    }

    private actor CallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
        func incrementAndGet() -> Int {
            value += 1
            return value
        }
    }

    func testConcurrentCallersShareOnePreparationTask() async throws {
        let preparation = SharedAsyncPreparation<Int>()
        let calls = CallCounter()
        let factory: @Sendable () async throws -> Int = {
            await calls.increment()
            try await Task.sleep(for: .milliseconds(40))
            return 42
        }

        async let first = preparation.value(prepare: factory)
        async let second = preparation.value(prepare: factory)
        async let third = preparation.value(prepare: factory)

        let values = try await [first, second, third]
        let initialCallCount = await calls.value
        let isPrepared = await preparation.isPrepared()
        let cachedValue = try await preparation.value(prepare: factory)
        let finalCallCount = await calls.value

        XCTAssertEqual(values, [42, 42, 42])
        XCTAssertEqual(initialCallCount, 1)
        XCTAssertTrue(isPrepared)
        XCTAssertEqual(cachedValue, 42)
        XCTAssertEqual(finalCallCount, 1)
    }

    func testFailedPreparationClearsInFlightStateAndLaterCallRetriesOnce() async throws {
        let preparation = SharedAsyncPreparation<Int>()
        let calls = CallCounter()
        let factory: @Sendable () async throws -> Int = {
            let attempt = await calls.incrementAndGet()
            if attempt == 1 { throw TestError.failed }
            return 42
        }

        do {
            _ = try await preparation.value(prepare: factory)
            XCTFail("The first preparation should fail")
        } catch TestError.failed {
            // Expected. A later caller must be able to start a new task.
        }

        let isPreparedAfterFailure = await preparation.isPrepared()
        let retriedValue = try await preparation.value(prepare: factory)
        let cachedValue = try await preparation.value(prepare: factory)
        let callCount = await calls.value

        XCTAssertFalse(isPreparedAfterFailure)
        XCTAssertEqual(retriedValue, 42)
        XCTAssertEqual(cachedValue, 42)
        XCTAssertEqual(callCount, 2)
    }
}
