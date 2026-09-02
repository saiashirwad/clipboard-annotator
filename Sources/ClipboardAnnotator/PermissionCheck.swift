import AppKit
import ApplicationServices
import AVFoundation

enum PermissionCheck {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Returns true if we can read selections. If not, points the user at the
    /// right pane in System Settings.
    @discardableResult
    @MainActor
    static func ensureAccessibility(promptSystemDialog: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }

        if promptSystemDialog {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        let alert = NSAlert()
        alert.messageText = "Clipboard Annotator needs Accessibility access"
        alert.informativeText = """
        It reads the text you have highlighted in other apps. Turn it on in \
        System Settings → Privacy & Security → Accessibility, then press the \
        capture shortcut again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
        return false
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static var isMicrophoneAuthorized: Bool {
        microphonePermissionState == .granted
    }

    static var microphonePermissionState: MicrophonePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    static func openHeliumAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}
