import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var trusted = PermissionCheck.isTrusted
    @State private var microphoneAuthorized = PermissionCheck.isMicrophoneAuthorized
    @State private var voiceModelState: VoiceModelState = .checking
    @State private var voiceModelDownloadID: UUID?

    var body: some View {
        Form {
            Section {
                shortcutRow("Capture selection", combo: $settings.captureCombo)
                shortcutRow("Hold to make a voice annotation", combo: $settings.voiceCaptureCombo)
                shortcutRow("Copy all as Markdown", combo: $settings.copyCombo)
                shortcutRow("Show stack", combo: $settings.stackCombo)
                shortcutRow("Switch session", combo: $settings.switchSessionCombo)
                shortcutRow("Clear the current session", combo: $settings.clearCombo)
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Hold the voice shortcut while you speak. Release it to transcribe and save. Clearing is undoable — use Undo Clear in the menu bar, or ⌘Z in the stack window.")
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
                LabeledContent("Microphone") {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(microphoneAuthorized ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(microphoneAuthorized ? "Granted" : "Not granted")
                                .foregroundStyle(microphoneAuthorized ? .primary : .secondary)
                        }
                        Button("Open System Settings…") { PermissionCheck.openMicrophoneSettings() }
                            .controlSize(.small)
                    }
                }
                LabeledContent("Local voice model") {
                    voiceModelControl
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Accessibility reads selected text. The microphone is only used while you hold the voice shortcut. The voice model stays on this Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await refreshVoiceModelState()
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            ) {
                guard !Task.isCancelled else { return }
                trusted = PermissionCheck.isTrusted
                microphoneAuthorized = PermissionCheck.isMicrophoneAuthorized
            }
        }
        .task(id: voiceModelDownloadID) {
            guard let voiceModelDownloadID else { return }
            await downloadVoiceModel(id: voiceModelDownloadID)
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

    @ViewBuilder
    private var voiceModelControl: some View {
        switch voiceModelState {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .notDownloaded:
            Button("Download…") { downloadVoiceModel() }
                .controlSize(.small)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading…")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Button("Retry download…") { downloadVoiceModel() }
                .controlSize(.small)
        }
    }

    private func refreshVoiceModelState() async {
        voiceModelState = await VoiceAnnotationService.shared.isVoiceModelReady() ? .ready : .notDownloaded
    }

    private func downloadVoiceModel() {
        voiceModelState = .downloading
        voiceModelDownloadID = UUID()
    }

    private func downloadVoiceModel(id: UUID) async {
        do {
            try await VoiceAnnotationService.shared.downloadVoiceModel()
            try Task.checkCancellation()
            guard voiceModelDownloadID == id else { return }
            voiceModelState = .ready
            voiceModelDownloadID = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, voiceModelDownloadID == id else { return }
            voiceModelState = .failed
            voiceModelDownloadID = nil
        }
    }
}

private enum VoiceModelState {
    case checking
    case notDownloaded
    case downloading
    case ready
    case failed
}
