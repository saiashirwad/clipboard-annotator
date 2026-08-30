import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var trusted = PermissionCheck.isTrusted

    var body: some View {
        Form {
            Section {
                shortcutRow("Capture selection", combo: $settings.captureCombo)
                shortcutRow("Copy all as Markdown", combo: $settings.copyCombo)
                shortcutRow("Show stack", combo: $settings.stackCombo)
                shortcutRow("Clear the stack", combo: $settings.clearCombo)
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Clearing is undoable — use Undo Clear in the menu bar, or ⌘Z in the stack window.")
            }

            Section {
                Toggle("Include a date heading", isOn: $settings.includeHeading)
                Toggle("Include source app and time", isOn: $settings.includeSource)
                Toggle("Clear the stack after copying", isOn: $settings.clearAfterCopy)
                Toggle("Paste straight into the app you are in", isOn: $settings.pasteDirectly)
            } header: {
                Text("Markdown output")
            } footer: {
                Text("On, \(settings.copyCombo.displayString) copies the Markdown and then sends ⌘V. Off, it only copies.")
            }

            Section("Behaviour") {
                Toggle("Return focus to the previous app after saving", isOn: $settings.restoreFocusAfterSave)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section {
                LabeledContent("Accessibility") {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(trusted ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(trusted ? "Granted" : "Not granted")
                                .foregroundStyle(trusted ? .primary : .secondary)
                        }
                        Button("Open System Settings…") { PermissionCheck.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Needed to read the text you have highlighted in other apps.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = PermissionCheck.isTrusted
        }
    }

    private func shortcutRow(_ title: String, combo: Binding<KeyCombo>) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyRecorder(combo: combo)
                .frame(width: 120, height: 24)
                .fixedSize()
        }
    }
}
