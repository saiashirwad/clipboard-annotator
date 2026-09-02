import AppKit
import ClipboardAnnotatorDomain
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var profileEditor: ProfileEditorState
    let onSelectProfile: (UUID) -> Void

    @State private var trusted = PermissionCheck.isTrusted
    @State private var microphoneAuthorized = PermissionCheck.isMicrophoneAuthorized
    @State private var voiceModelState: VoiceModelState = .checking
    @State private var voiceModelDownloadID: UUID?

    init(
        settings: AppSettings,
        profileEditor: ProfileEditorState,
        onSelectProfile: @escaping (UUID) -> Void
    ) {
        _settings = Bindable(wrappedValue: settings)
        _profileEditor = Bindable(wrappedValue: profileEditor)
        self.onSelectProfile = onSelectProfile
    }

    var body: some View {
        Form {
            profileSection

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

            Section("Capture behavior") {
                Toggle("Paste straight into the app you are in", isOn: $settings.pasteDirectly)
                Toggle("Return focus to the previous app after saving", isOn: $settings.restoreFocusAfterSave)
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
                Text("Permissions and voice model")
            } footer: {
                Text("Accessibility reads selected text. The microphone is only used while you hold the voice shortcut. The voice model stays on this Mac.")
            }

            Section("App") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 760)
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

    private var profileSection: some View {
        Section {
            Picker(
                "Active profile",
                selection: Binding(
                    get: { profileEditor.editedProfileID },
                    set: { onSelectProfile($0) }
                )
            ) {
                ForEach(profileEditor.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }

            TextField("Profile name", text: $profileEditor.draft.name)
                .accessibilityLabel("Profile name")

            VStack(alignment: .leading, spacing: 5) {
                Text("Preamble")
                    .font(.callout)
                TextEditor(text: $profileEditor.draft.preamble)
                    .font(.body)
                    .frame(minHeight: 86)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.25))
                    }
                    .accessibilityLabel("Profile preamble")
            }

            Toggle("Include a date heading", isOn: $profileEditor.draft.includeHeading)
            Toggle("Include application", isOn: $profileEditor.draft.includeApplication)
            Toggle("Include window title", isOn: $profileEditor.draft.includeWindow)
            Toggle("Include link or working directory", isOn: $profileEditor.draft.includeLink)
            Toggle("Include timestamps", isOn: $profileEditor.draft.includeTimestamps)
            Toggle(
                "Clear the current session after copying or pasting",
                isOn: $profileEditor.draft.clearSessionAfterExport
            )

            HStack {
                Button("Delete…", role: .destructive, action: deleteProfile)
                    .disabled(!profileEditor.canDelete || profileEditor.isDirty)
                    .help(profileEditor.isDirty ? "Save or revert changes before deleting." : "Delete this profile")
                Button("New Profile…") {
                    _ = ProfileDialogs.saveAsNew(profileEditor)
                }

                Spacer()

                if profileEditor.isDirty {
                    Button("Revert", action: profileEditor.revert)
                    Button("Save to “\(profileEditor.storedProfile?.name ?? "Profile")”", action: saveProfile)
                        .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("The active profile shapes copied Markdown. Profile edits do not take effect until you save them.")
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

    private func saveProfile() {
        do {
            try profileEditor.save()
        } catch {
            ProfileDialogs.showError(error)
        }
    }

    private func deleteProfile() {
        ProfileDialogs.delete(profileEditor)
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

@MainActor
enum ProfileDialogs {
    static func resolvePendingSelection(_ editor: ProfileEditorState) -> Bool {
        guard editor.pendingProfileID != nil else { return true }
        guard let decision = dirtyDecision(for: editor) else {
            editor.cancelPendingSelection()
            return false
        }
        return resolve(decision, editor: editor, closesWindow: false)
    }

    static func shouldClose(_ editor: ProfileEditorState) -> Bool {
        guard editor.isDirty else { return true }
        guard let decision = dirtyDecision(for: editor) else { return false }
        return resolve(decision, editor: editor, closesWindow: true)
    }

    @discardableResult
    static func saveAsNew(_ editor: ProfileEditorState) -> Bool {
        guard let name = requestNewName(for: editor) else { return false }
        do {
            _ = try editor.saveAsNew(named: name)
            return true
        } catch {
            showError(error)
            return false
        }
    }

    static func delete(_ editor: ProfileEditorState) {
        guard let stored = editor.storedProfile else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(stored.name)”?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try editor.delete()
        } catch {
            showError(error)
        }
    }

    static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Profile Change Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func dirtyDecision(
        for editor: ProfileEditorState
    ) -> ProfileEditorState.DirtyDecision? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to “\(editor.draft.name)”?"
        alert.informativeText = "Choose what to do with this profile draft."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Save as New…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            guard let name = requestNewName(for: editor) else { return nil }
            return .saveAsNew(name: name)
        case .alertThirdButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private static func resolve(
        _ decision: ProfileEditorState.DirtyDecision,
        editor: ProfileEditorState,
        closesWindow: Bool
    ) -> Bool {
        do {
            if closesWindow {
                return try editor.resolveClose(decision)
            }
            return try editor.resolvePendingSelection(decision)
        } catch {
            showError(error)
            if !closesWindow { editor.cancelPendingSelection() }
            return false
        }
    }

    private static func requestNewName(for editor: ProfileEditorState) -> String? {
        var proposedName = "\(editor.draft.name) Copy"
        while true {
            let alert = NSAlert()
            alert.messageText = "New Profile"
            alert.informativeText = "Enter a unique profile name."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(string: proposedName)
            field.placeholderString = "Profile name"
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            proposedName = field.stringValue
            do {
                return try editor.validatedNewProfileName(proposedName)
            } catch {
                showError(error)
            }
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
