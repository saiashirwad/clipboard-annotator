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

    func testModifierStateEmitsEachEdgeOnceAndResetReportsAnActivePress() {
        var state = VoiceModifierShortcutState()

        XCTAssertEqual(state.update(isPressed: true), .pressed)
        XCTAssertNil(state.update(isPressed: true))
        XCTAssertTrue(state.reset())
        XCTAssertFalse(state.reset())
        XCTAssertNil(state.update(isPressed: false))
        XCTAssertEqual(state.update(isPressed: true), .pressed)
        XCTAssertEqual(state.update(isPressed: false), .released)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SendpointVoiceShortcutTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
