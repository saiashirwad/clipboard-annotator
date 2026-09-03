import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Sendpoint

@MainActor
final class VoiceShortcutSettingsTests: XCTestCase {
    func testFreshSettingsUseOptionSpaceForVoice() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.voiceCaptureCombo, .optionSpace)
    }

    func testStoredVoiceShortcutIsNeverReplacedByTheNewDefault() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let deliberate = KeyCombo(keyCode: UInt16(kVK_ANSI_E), modifiers: [.control, .command])
        defaults.set(try JSONEncoder().encode(deliberate), forKey: "voiceCaptureCombo")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.voiceCaptureCombo, deliberate)
    }

    func testVoiceRegistrationResetOnlyFollowsAnActualComboChange() {
        XCTAssertFalse(AppDelegate.voiceShortcutChanged(from: nil, to: .optionSpace))
        XCTAssertFalse(AppDelegate.voiceShortcutChanged(from: .optionSpace, to: .optionSpace))
        XCTAssertTrue(AppDelegate.voiceShortcutChanged(
            from: .optionSpace,
            to: KeyCombo(keyCode: UInt16(kVK_ANSI_E), modifiers: [.control, .command])
        ))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SendpointVoiceShortcutTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
