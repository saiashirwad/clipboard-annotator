import XCTest
@testable import Sendpoint

final class VoiceTriggerMachineTests: XCTestCase {
    private let source = VoiceTriggerSource.hotKey

    func testShortPressLatchesAndSecondPressFinalizesOnce() {
        var machine = VoiceTriggerMachine()

        XCTAssertEqual(
            machine.handle(.hotKeyPressed(at: 10)),
            [.beginCapture(source: source), .setLatched(false)]
        )
        XCTAssertEqual(machine.state, .comboHeld(pressedAt: 10))

        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 10.349)), [.setLatched(true)])
        XCTAssertEqual(machine.state, .comboLatched)

        XCTAssertEqual(machine.handle(.hotKeyPressed(at: 11)), [.finishCapture(source: source)])
        XCTAssertEqual(machine.state, .awaitingComboRelease)
        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 11.1)), [])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.hotKeyPressed(at: 12)), [.beginCapture(source: source), .setLatched(false)])
    }

    func testThresholdIsInclusiveForHold() {
        var machine = VoiceTriggerMachine()
        _ = machine.handle(.hotKeyPressed(at: 20))

        XCTAssertEqual(
            machine.handle(.hotKeyReleased(at: 20 + VoiceTriggerTiming.tapHoldThreshold)),
            [.finishCapture(source: source)]
        )
        XCTAssertEqual(machine.state, .idle)
    }

    func testReleaseBeforePressAndDuplicateEventsAreIgnored() {
        var machine = VoiceTriggerMachine()

        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 30)), [])
        XCTAssertEqual(machine.handle(.hotKeyPressed(at: 31)), [.beginCapture(source: source), .setLatched(false)])
        XCTAssertEqual(machine.handle(.hotKeyPressed(at: 31.1)), [])
        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 30.9)), [])
        XCTAssertEqual(machine.state, .comboHeld(pressedAt: 31))
        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 31.35)), [.finishCapture(source: source)])
        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 31.4)), [])
        XCTAssertEqual(machine.handle(.hotKeyPressed(at: 31.5)), [.beginCapture(source: source), .setLatched(false)])
    }

    func testEscapeCancelsHoldAndConsumesItsPendingRelease() {
        var machine = VoiceTriggerMachine()
        _ = machine.handle(.hotKeyPressed(at: 40))

        XCTAssertEqual(machine.handle(.escape), [.cancelCapture(source: source)])
        XCTAssertEqual(machine.state, .awaitingComboRelease)
        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 40.1)), [])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.escape), [])
    }

    func testEscapeCancelsLatchedCapture() {
        var machine = VoiceTriggerMachine()
        _ = machine.handle(.hotKeyPressed(at: 50))
        _ = machine.handle(.hotKeyReleased(at: 50.1))

        XCTAssertEqual(machine.handle(.escape), [.cancelCapture(source: source)])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 50.2)), [])
    }

    func testCaptureEndingBeforeStartCannotStrandMachine() {
        var machine = VoiceTriggerMachine()
        _ = machine.handle(.hotKeyPressed(at: 60))

        XCTAssertEqual(machine.handle(.captureEnded(source: source)), [])
        XCTAssertEqual(machine.state, .awaitingComboRelease)
        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 60.1)), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testCaptureEndedWhileLatchedResetsMachineAndRejectsLateFinalization() {
        var machine = VoiceTriggerMachine()
        _ = machine.handle(.hotKeyPressed(at: 70))
        _ = machine.handle(.hotKeyReleased(at: 70.1))

        XCTAssertEqual(machine.handle(.captureEnded(source: source)), [])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.hotKeyPressed(at: 70.2)), [.beginCapture(source: source), .setLatched(false)])
    }

    func testShortcutChangeCancelsHeldCaptureAndRejectsOldRelease() {
        var machine = VoiceTriggerMachine()
        _ = machine.handle(.hotKeyPressed(at: 90))

        XCTAssertEqual(
            machine.handle(.shortcutConfigurationChanged),
            [.cancelCapture(source: source)]
        )
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 90.1)), [])
        XCTAssertEqual(
            machine.handle(.hotKeyPressed(at: 91)),
            [.beginCapture(source: source), .setLatched(false)]
        )
    }

    func testShortcutChangeCancelsLatchedCaptureWithoutSecondFinalization() {
        var machine = VoiceTriggerMachine()
        _ = machine.handle(.hotKeyPressed(at: 100))
        _ = machine.handle(.hotKeyReleased(at: 100.1))

        XCTAssertEqual(
            machine.handle(.shortcutConfigurationChanged),
            [.cancelCapture(source: source)]
        )
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.hotKeyPressed(at: 101)), [.beginCapture(source: source), .setLatched(false)])
    }

    func testShortcutChangeResetsAwaitingReleaseWithoutCancellingAgain() {
        var machine = VoiceTriggerMachine()
        _ = machine.handle(.hotKeyPressed(at: 110))
        _ = machine.handle(.escape)
        XCTAssertEqual(machine.state, .awaitingComboRelease)

        XCTAssertEqual(machine.handle(.shortcutConfigurationChanged), [])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.hotKeyReleased(at: 110.1)), [])
    }
}
