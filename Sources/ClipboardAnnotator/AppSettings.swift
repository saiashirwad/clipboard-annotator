import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var captureCombo: KeyCombo { didSet { persist(captureCombo, key: "captureCombo"); onHotKeysChanged?() } }
    @Published var voiceCaptureCombo: KeyCombo { didSet { persist(voiceCaptureCombo, key: "voiceCaptureCombo"); onHotKeysChanged?() } }
    @Published var copyCombo: KeyCombo { didSet { persist(copyCombo, key: "copyCombo"); onHotKeysChanged?() } }
    @Published var stackCombo: KeyCombo { didSet { persist(stackCombo, key: "stackCombo"); onHotKeysChanged?() } }
    @Published var clearCombo: KeyCombo { didSet { persist(clearCombo, key: "clearCombo"); onHotKeysChanged?() } }

    @Published var includeSource: Bool { didSet { defaults.set(includeSource, forKey: "includeSource") } }
    @Published var includeHeading: Bool { didSet { defaults.set(includeHeading, forKey: "includeHeading") } }
    @Published var clearAfterCopy: Bool { didSet { defaults.set(clearAfterCopy, forKey: "clearAfterCopy") } }
    @Published var pasteDirectly: Bool { didSet { defaults.set(pasteDirectly, forKey: "pasteDirectly"); onHotKeysChanged?() } }
    @Published var restoreFocusAfterSave: Bool { didSet { defaults.set(restoreFocusAfterSave, forKey: "restoreFocusAfterSave") } }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("ClipboardAnnotator: login item change failed — \(error)")
            }
        }
    }

    /// Called when a shortcut changes so the app can re-register.
    var onHotKeysChanged: (() -> Void)?

    private init() {
        captureCombo = AppSettings.read("captureCombo", from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .command])
        voiceCaptureCombo = AppSettings.read("voiceCaptureCombo", from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_ANSI_E), modifiers: [.control, .command])
        copyCombo = AppSettings.read("copyCombo", from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_ANSI_V), modifiers: [.control, .command])
        stackCombo = AppSettings.read("stackCombo", from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_ANSI_S), modifiers: [.control, .command])
        clearCombo = AppSettings.read("clearCombo", from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_Delete), modifiers: [.control, .command])

        includeSource = defaults.object(forKey: "includeSource") as? Bool ?? true
        includeHeading = defaults.object(forKey: "includeHeading") as? Bool ?? true
        clearAfterCopy = defaults.object(forKey: "clearAfterCopy") as? Bool ?? false
        pasteDirectly = defaults.object(forKey: "pasteDirectly") as? Bool ?? true
        restoreFocusAfterSave = defaults.object(forKey: "restoreFocusAfterSave") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func persist(_ combo: KeyCombo, key: String) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: key)
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}
