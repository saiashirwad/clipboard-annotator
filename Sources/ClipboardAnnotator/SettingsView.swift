import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var trusted = PermissionCheck.isTrusted

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Capture selection") {
                    KeyRecorder(combo: $settings.captureCombo).frame(width: 130, height: 24)
                }
                LabeledContent("Copy all as Markdown") {
                    KeyRecorder(combo: $settings.copyCombo).frame(width: 130, height: 24)
                }
                LabeledContent("Show stack") {
                    KeyRecorder(combo: $settings.stackCombo).frame(width: 130, height: 24)
                }
                LabeledContent("Clear the stack") {
                    KeyRecorder(combo: $settings.clearCombo).frame(width: 130, height: 24)
                }
                Text("Clearing is undoable — use Undo Clear in the menu bar, or ⌘Z in the stack window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Markdown output") {
                Toggle("Include a date heading", isOn: $settings.includeHeading)
                Toggle("Include source app and time", isOn: $settings.includeSource)
                Toggle("Clear the stack after copying", isOn: $settings.clearAfterCopy)
                Toggle("Paste straight into the app you are in", isOn: $settings.pasteDirectly)
                Text("On, \(settings.copyCombo.displayString) copies the Markdown and then sends ⌘V. Off, it only copies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle("Return focus to the previous app after saving", isOn: $settings.restoreFocusAfterSave)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        Label(
                            trusted ? "Granted" : "Not granted",
                            systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(trusted ? Color.green : Color.orange)
                        Button("Open Settings") { PermissionCheck.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
                Text("Needed to read the text you have highlighted in other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = PermissionCheck.isTrusted
        }
    }
}
