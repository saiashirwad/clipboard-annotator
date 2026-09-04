import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Sendpoint

@MainActor
final class ShortcutCollisionTests: XCTestCase {
    func testDuplicateShortcutIsRejectedBeforePersistence() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let oldClear = settings.clearCombo
        let oldStoredClear = defaults.data(forKey: "clearCombo")

        XCTAssertThrowsError(try settings.setShortcut(settings.copyCombo, for: .clear)) {
            XCTAssertEqual($0 as? ShortcutConflict, .duplicate(.copy))
        }
        XCTAssertEqual(settings.clearCombo, oldClear)
        XCTAssertEqual(defaults.data(forKey: "clearCombo"), oldStoredClear)
    }

    func testFixedMainMenuShortcutsAreRejected() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let closeWindow = KeyCombo(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command])
        let undo = KeyCombo(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command])

        XCTAssertEqual(
            settings.shortcutConflict(for: closeWindow, excluding: .clear),
            .reserved("Close Window (⌘W)")
        )
        XCTAssertEqual(
            settings.shortcutConflict(for: undo, excluding: .clear),
            .reserved("Undo (⌘Z)")
        )
        XCTAssertThrowsError(try settings.setShortcut(closeWindow, for: .clear))
        XCTAssertThrowsError(try settings.setShortcut(undo, for: .clear))
    }

    func testOptionCommandPrefixIsReservedForVoice() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let prefixed = KeyCombo(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.option, .command]
        )

        XCTAssertEqual(
            settings.shortcutConflict(for: prefixed, excluding: .switchSession),
            .reserved("Voice note (⌥⌘)")
        )
        XCTAssertThrowsError(try settings.setShortcut(prefixed, for: .switchSession))
    }

    func testStalePersistedConflictsRemainVisibleToRegistrationValidation() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let reserved = KeyCombo(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command])
        let duplicate = KeyCombo(keyCode: UInt16(kVK_ANSI_S), modifiers: [.control, .command])
        defaults.set(try JSONEncoder().encode(reserved), forKey: "clearCombo")
        defaults.set(try JSONEncoder().encode(duplicate), forKey: "copyCombo")
        defaults.set(try JSONEncoder().encode(duplicate), forKey: "stackCombo")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(
            settings.shortcutConflict(for: settings.clearCombo, excluding: .clear),
            .reserved("Undo (⌘Z)")
        )
        XCTAssertEqual(
            settings.shortcutConflict(for: settings.copyCombo, excluding: .copy),
            .duplicate(.stack)
        )
        XCTAssertEqual(
            settings.shortcutRegistrationIssues,
            [
                .conflict(slot: .copy, combo: duplicate, reason: .duplicate(.stack)),
                .conflict(slot: .stack, combo: duplicate, reason: .duplicate(.copy)),
                .conflict(slot: .clear, combo: reserved, reason: .reserved("Undo (⌘Z)")),
            ]
        )
    }

    func testCarbonRegistrationFailureIsReturned() {
        let status: Int32 = -9876
        let center = HotKeyCenter(registerEvent: { _, _, _ in (status, nil) })

        let result = center.register(
            name: "test",
            combo: KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .command]),
            action: {}
        )

        XCTAssertEqual(result, .failed(status))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SendpointShortcutCollisionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
