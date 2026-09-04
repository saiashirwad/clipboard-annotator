import XCTest
@testable import Sendpoint

@MainActor
final class InputDeviceChoiceTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let usb = AudioInputDevice(id: 77, uid: "AppleUSBAudioEngine:Yeti", name: "Yeti")

    func testNoPreferenceFollowsTheSystemDefault() {
        XCTAssertNil(InputDeviceChoice.resolve(preferredUID: nil, available: [builtIn, usb]))
    }

    func testConnectedPreferenceIsChosen() {
        XCTAssertEqual(InputDeviceChoice.resolve(preferredUID: usb.uid, available: [builtIn, usb]), usb)
    }

    func testUnpluggedPreferenceFallsBackToTheSystemDefault() {
        XCTAssertNil(InputDeviceChoice.resolve(preferredUID: usb.uid, available: [builtIn]))
    }

    func testPreferredMicrophonePersistsAcrossSettingsInstances() {
        let suite = "InputDeviceChoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        XCTAssertNil(first.inputDeviceUID)
        first.setInputDevice(uid: usb.uid, name: usb.name)

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.inputDeviceUID, usb.uid)
        XCTAssertEqual(second.inputDeviceName, usb.name)

        second.setInputDevice(uid: nil, name: "ignored")
        let third = AppSettings(defaults: defaults)
        XCTAssertNil(third.inputDeviceUID)
        XCTAssertNil(third.inputDeviceName)
    }
}
