import AppKit
import SendpointDomain
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case profiles
    case shortcuts
    case capture
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profiles: "Profiles"
        case .shortcuts: "Shortcuts"
        case .capture: "Capture"
        case .permissions: "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .profiles: "text.quote"
        case .shortcuts: "keyboard"
        case .capture: "cursorarrow.click.2"
        case .permissions: "checkmark.shield"
        }
    }

    var tint: Color {
        switch self {
        case .profiles: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .shortcuts: Color(red: 0.36, green: 0.36, blue: 0.40)
        case .capture: Color(red: 0.20, green: 0.68, blue: 0.40)
        case .permissions: Color(red: 0.95, green: 0.55, blue: 0.16)
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var profileEditor: ProfileEditorState
    @Bindable var permissionState: PermissionState
    let onSelectProfile: (UUID) -> Void
    let onShowAccessibilityHelper: () -> Void
    let onRunSetup: () -> Void

    @State private var tab: SettingsTab = .profiles
    @State private var newProfile: NewProfileDraft?

    private struct NewProfileDraft: Equatable {
        var name: String
        var problem: String?
    }

    static let size = CGSize(width: 780, height: 620)
    private static let sidebarWidth: CGFloat = 200
    private static let titleBarHeight: CGFloat = 52

    init(
        settings: AppSettings,
        profileEditor: ProfileEditorState,
        permissionState: PermissionState,
        onSelectProfile: @escaping (UUID) -> Void,
        onShowAccessibilityHelper: @escaping () -> Void,
        onRunSetup: @escaping () -> Void
    ) {
        _settings = Bindable(wrappedValue: settings)
        _profileEditor = Bindable(wrappedValue: profileEditor)
        _permissionState = Bindable(wrappedValue: permissionState)
        self.onSelectProfile = onSelectProfile
        self.onShowAccessibilityHelper = onShowAccessibilityHelper
        self.onRunSetup = onRunSetup
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $tab, topInset: Self.titleBarHeight)
                .frame(width: Self.sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                Text(tab.title)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .frame(height: Self.titleBarHeight)
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .profiles: profilesTab
                        case .shortcuts: shortcutsTab
                        case .capture: captureTab
                        case .permissions: permissionsTab
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .id(tab)
                }
                .scrollIndicators(.automatic)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea()
        .overlayScrollers()
    }

    // MARK: - Profiles

    private var profilesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            profileChips
            profileEditorPane
        }
    }

    private var profileChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCaption("Active profile")
            HStack(spacing: 6) {
                ForEach(profileEditor.profiles) { profile in
                    ProfileChip(
                        name: profile.name,
                        isSelected: profile.id == profileEditor.editedProfileID,
                        isDirty: profile.id == profileEditor.editedProfileID && profileEditor.isDirty
                    ) {
                        onSelectProfile(profile.id)
                    }
                }
                Button {
                    newProfile = NewProfileDraft(name: "\(profileEditor.draft.name) Copy")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New profile from this draft…")
                .accessibilityLabel("New profile")
                .popover(
                    isPresented: Binding(
                        get: { newProfile != nil },
                        set: { if !$0 { newProfile = nil } }
                    ),
                    arrowEdge: .bottom
                ) {
                    NewProfilePopover(
                        name: Binding(
                            get: { newProfile?.name ?? "" },
                            set: { newProfile?.name = $0; newProfile?.problem = nil }
                        ),
                        problem: newProfile?.problem,
                        onCommit: createProfile
                    )
                }
            }
            Text("The selected profile is active and shapes what Copy produces.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileEditorPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProfileNameField(text: $profileEditor.draft.name) {
                Button(action: deleteProfile) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!profileEditor.canDelete || profileEditor.isDirty)
                .help(profileEditor.isDirty
                    ? "Save or revert changes before deleting."
                    : "Delete this profile…")
                .accessibilityLabel("Delete profile")
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsCaption("Preamble")
                TextEditor(text: $profileEditor.draft.preamble)
                    .font(.body)
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(minHeight: 140, maxHeight: 140)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .accessibilityLabel("Profile preamble")
                Text("Placed above the notes. Tell the model how to read them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsCaption("Include with each note")
                SettingsCard {
                    SettingsToggleRow("Date heading", isOn: $profileEditor.draft.includeHeading)
                    Divider().padding(.leading, 14)
                    SettingsToggleRow("Application", isOn: $profileEditor.draft.includeApplication)
                    Divider().padding(.leading, 14)
                    SettingsToggleRow("Window title", isOn: $profileEditor.draft.includeWindow)
                    Divider().padding(.leading, 14)
                    SettingsToggleRow("Link or working directory", isOn: $profileEditor.draft.includeLink)
                    Divider().padding(.leading, 14)
                    SettingsToggleRow("Timestamps", isOn: $profileEditor.draft.includeTimestamps)
                }
            }

            SettingsCard {
                SettingsToggleRow(
                    "Clear the session after copying or pasting",
                    subtitle: "Start fresh once the notes have left the app.",
                    isOn: $profileEditor.draft.clearSessionAfterExport
                )
            }

            saveBar
        }
        .animation(.snappy(duration: 0.22), value: profileEditor.isDirty)
    }

    @ViewBuilder
    private var saveBar: some View {
        if profileEditor.isDirty {
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.tint)
                Text("Unsaved changes")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Revert", action: profileEditor.revert)
                Button("Save", action: saveProfile)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                shortcutRow(
                    icon: "text.viewfinder",
                    title: "Capture selection",
                    detail: "Opens the note box for the text you have selected.",
                    combo: $settings.captureCombo
                )
                Divider().padding(.leading, 56)
                shortcutRow(
                    icon: "mic.fill",
                    title: "Voice annotation",
                    detail: "Hold to speak, release to transcribe and save.",
                    combo: $settings.voiceCaptureCombo
                )
                Divider().padding(.leading, 56)
                shortcutRow(
                    icon: "doc.on.clipboard",
                    title: "Copy all as Markdown",
                    detail: "Everything in the session, shaped by the active profile.",
                    combo: $settings.copyCombo
                )
                Divider().padding(.leading, 56)
                shortcutRow(
                    icon: "square.stack.3d.up",
                    title: "Show stack",
                    detail: "Opens the window with all your annotations.",
                    combo: $settings.stackCombo
                )
                Divider().padding(.leading, 56)
                shortcutRow(
                    icon: "arrow.left.arrow.right",
                    title: "Switch session",
                    detail: "Jump between sessions, or create one by typing its name.",
                    combo: $settings.switchSessionCombo
                )
                Divider().padding(.leading, 56)
                shortcutRow(
                    icon: "trash",
                    title: "Clear the current session",
                    detail: "Undoable from the menu bar, or with ⌘Z in the stack window.",
                    combo: $settings.clearCombo
                )
            }
            Text("Click a shortcut, then press the keys you want. Press esc to keep the old one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func shortcutRow(
        icon: String,
        title: String,
        detail: String,
        combo: Binding<KeyCombo>
    ) -> some View {
        HStack(spacing: 14) {
            SettingsIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            KeyRecorder(combo: combo)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Capture

    private var captureTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsCaption("After copying")
                SettingsCard {
                    SettingsToggleRow(
                        "Paste straight into the app you are in",
                        subtitle: "The Markdown lands where your cursor is, without a separate paste.",
                        isOn: $settings.pasteDirectly
                    )
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsCaption("After saving a note")
                SettingsCard {
                    SettingsToggleRow(
                        "Return to the previous app",
                        subtitle: "Hands focus back to where you were reading.",
                        isOn: $settings.restoreFocusAfterSave
                    )
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsCaption("Startup")
                SettingsCard {
                    SettingsToggleRow(
                        "Launch at login",
                        subtitle: "Keeps the shortcuts ready as soon as you sign in.",
                        isOn: $settings.launchAtLogin
                    )
                }
            }
        }
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionCapabilityList(
                permissionState: permissionState,
                onShowAccessibilityHelper: onShowAccessibilityHelper
            )
            SettingsCard {
                SettingsRow(
                    "Setup assistant",
                    subtitle: "Walk through the permissions and the voice model again."
                ) {
                    Button("Run Setup Again…", action: onRunSetup)
                }
            }
            Label {
                Text("Accessibility is required for capture. Voice annotations are optional. The voice model is a one-time 460 MB download from Hugging Face, and audio and transcription never leave this Mac.")
            } icon: {
                Image(systemName: "lock.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

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

    private func createProfile() {
        guard let draft = newProfile else { return }
        do {
            let name = try profileEditor.validatedNewProfileName(draft.name)
            _ = try profileEditor.saveAsNew(named: name)
            newProfile = nil
        } catch {
            newProfile?.problem = error.localizedDescription
            NSSound.beep()
        }
    }
}

/// A small anchored prompt: type a name, press Return.
private struct NewProfilePopover: View {
    @Binding var name: String
    let problem: String?
    let onCommit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New profile from the current draft")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(onCommit)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                ShortcutHint(keys: "↩", label: "Create")
            }
        }
        .padding(12)
        .frame(width: 240)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}

// MARK: - Building blocks

/// The source list on the left, with a coloured tile per section.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    let topInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: topInset)
            ForEach(SettingsTab.allCases) { tab in
                SettingsSidebarRow(tab: tab, isSelected: tab == selection) {
                    selection = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab.tint)
                    )
                    .shadow(color: tab.tint.opacity(0.35), radius: 2, y: 1)
                    .accessibilityHidden(true)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected
                    ? Color.accentColor
                    : Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ProfileChip: View {
    let name: String
    let isSelected: Bool
    let isDirty: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if isDirty {
                    Circle()
                        .fill(isSelected ? Color.white : Color.accentColor)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The profile's name, set as an editable title rather than a form field.
private struct ProfileNameField<Accessory: View>: View {
    @Binding var text: String
    @ViewBuilder let accessory: () -> Accessory
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                TextField("Profile name", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .focused($focused)
                    .accessibilityLabel("Profile name")
                accessory()
            }
            Rectangle()
                .fill(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1))
                .frame(height: 1)
        }
        .padding(.horizontal, 2)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

/// A raised, bordered group of rows.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, subtitle == nil ? 9 : 11)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct SettingsIcon: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 30, height: 30)
            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
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
