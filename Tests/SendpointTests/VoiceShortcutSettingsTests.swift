import ApplicationServices
import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Sendpoint

@MainActor
final class VoiceShortcutSettingsTests: XCTestCase {
    func testFixedVoiceShortcutRequiresExactOptionCommandFlags() {
        XCTAssertEqual(VoiceModifierShortcut.displayString, "⌥⌘")
        XCTAssertTrue(VoiceModifierShortcut.isPressed(flags: [.maskAlternate, .maskCommand]))
        XCTAssertFalse(VoiceModifierShortcut.isPressed(flags: [.maskAlternate]))
        XCTAssertFalse(VoiceModifierShortcut.isPressed(
            flags: [.maskAlternate, .maskCommand, .maskShift]
        ))
    }

    func testStoredKeyBasedVoiceShortcutIsRemoved() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.option])
        defaults.set(try JSONEncoder().encode(old), forKey: "voiceCaptureCombo")

        _ = AppSettings(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "voiceCaptureCombo"))
    }

    func testModifierStateArmsBeforeStartingAHeldGesture() {
        var state = VoiceModifierShortcutState()

        XCTAssertEqual(
            state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 10),
            .startArming
        )
        XCTAssertNil(state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 10.1))
        XCTAssertEqual(state.armingDelayElapsed(), .pressed(at: 10))
        XCTAssertEqual(
            state.flagsChanged(flags: [.maskCommand], timestamp: 10.4),
            .released(at: 10.4)
        )
    }

    func testModifierStatePreservesAQuickCleanTap() {
        var state = VoiceModifierShortcutState()

        XCTAssertEqual(
            state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 20),
            .startArming
        )
        XCTAssertEqual(
            state.flagsChanged(flags: [.maskAlternate], timestamp: 20.1),
            .tapped(pressedAt: 20, releasedAt: 20.1)
        )
        XCTAssertNil(state.armingDelayElapsed())
        XCTAssertNil(state.flagsChanged(flags: [], timestamp: 20.2))
        XCTAssertEqual(
            state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 21),
            .startArming
        )
    }

    func testModifierStateSuppressesHyperUntilEveryModifierIsReleased() {
        var state = VoiceModifierShortcutState()

        XCTAssertEqual(
            state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 30),
            .startArming
        )
        XCTAssertEqual(
            state.flagsChanged(
                flags: [.maskControl, .maskAlternate, .maskShift, .maskCommand],
                timestamp: 30.01
            ),
            .cancelArming
        )
        XCTAssertNil(state.armingDelayElapsed())
        XCTAssertNil(state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 30.02))
        XCTAssertNil(state.flagsChanged(flags: [.maskCommand], timestamp: 30.03))
        XCTAssertNil(state.flagsChanged(flags: [], timestamp: 30.04))
        XCTAssertEqual(
            state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 31),
            .startArming
        )
    }

    func testModifierStateDoesNotArmWhileHyperIsBeingReleased() {
        var state = VoiceModifierShortcutState()

        XCTAssertNil(state.flagsChanged(
            flags: [.maskControl, .maskAlternate, .maskShift, .maskCommand],
            timestamp: 35
        ))
        XCTAssertNil(state.flagsChanged(
            flags: [.maskAlternate, .maskCommand],
            timestamp: 35.01
        ))
        XCTAssertNil(state.flagsChanged(flags: [], timestamp: 35.02))
        XCTAssertEqual(
            state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 36),
            .startArming
        )
    }

    func testModifierStateSuppressesAKeyBasedShortcut() {
        var state = VoiceModifierShortcutState()

        XCTAssertEqual(
            state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 40),
            .startArming
        )
        XCTAssertEqual(state.keyDown(), .cancelArming)
        XCTAssertNil(state.armingDelayElapsed())
        XCTAssertNil(state.flagsChanged(flags: [], timestamp: 40.1))
        XCTAssertEqual(
            state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 41),
            .startArming
        )
    }

    func testModifierStateInterruptsAnActiveGestureWhenAnotherKeyArrives() {
        var state = VoiceModifierShortcutState()

        _ = state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 50)
        _ = state.armingDelayElapsed()

        XCTAssertEqual(state.keyDown(), .interrupted)
        XCTAssertFalse(state.reset())
    }

    func testModifierStateResetReportsOnlyAnActiveGesture() {
        var state = VoiceModifierShortcutState()

        _ = state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 60)
        XCTAssertFalse(state.reset())
        _ = state.flagsChanged(flags: [.maskAlternate, .maskCommand], timestamp: 61)
        _ = state.armingDelayElapsed()
        XCTAssertTrue(state.reset())
        XCTAssertFalse(state.reset())
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SendpointVoiceShortcutTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
