import AppKit
import SendpointDomain
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case voice
    case shortcuts
    case profiles
    case capture
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voice: "Voice"
        case .shortcuts: "Shortcuts"
        case .profiles: "Templates"
        case .capture: "General"
        case .permissions: "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .voice: "mic.fill"
        case .shortcuts: "keyboard.fill"
        case .profiles: "text.quote"
        case .capture: "gearshape.fill"
        case .permissions: "checkmark.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .voice: Color(red: 0.95, green: 0.32, blue: 0.28)
        case .shortcuts: Color(red: 0.36, green: 0.36, blue: 0.40)
        case .profiles: Color(red: 0.55, green: 0.36, blue: 0.96)
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
    let onShowInputMonitoringHelper: () -> Void
    let onRunSetup: () -> Void

    @State private var tab: SettingsTab = .voice
    @State private var newProfile: NewProfileDraft?
    @State private var shortcutFeedback: String?

    private struct NewProfileDraft: Equatable {
        var name: String
        var problem: String?
    }

    /// The smallest the window goes; it can be dragged larger.
    static let size = CGSize(width: 780, height: 620)
    private static let sidebarWidth: CGFloat = 200
    private static let titleBarHeight: CGFloat = 52
    /// Cards stop stretching past this so a wide window stays readable.
    private static let contentMaxWidth: CGFloat = 760

    /// One sentence for the voice shortcut, used wherever it is listed.
    static let voiceNoteDetail = "Select text, then hold to speak, or tap to start and tap again to save."

    init(
        settings: AppSettings,
        profileEditor: ProfileEditorState,
        permissionState: PermissionState,
        onSelectProfile: @escaping (UUID) -> Void,
        onShowAccessibilityHelper: @escaping () -> Void,
        onShowInputMonitoringHelper: @escaping () -> Void,
        onRunSetup: @escaping () -> Void
    ) {
        _settings = Bindable(wrappedValue: settings)
        _profileEditor = Bindable(wrappedValue: profileEditor)
        _permissionState = Bindable(wrappedValue: permissionState)
        self.onSelectProfile = onSelectProfile
        self.onShowAccessibilityHelper = onShowAccessibilityHelper
        self.onShowInputMonitoringHelper = onShowInputMonitoringHelper
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
                    VStack(alignment: .leading, spacing: 14) {
                        if !settings.shortcutRegistrationIssues.isEmpty {
                            shortcutRegistrationIssues
                        }
                        switch tab {
                        case .voice: voiceTab
                        case .shortcuts: shortcutsTab
                        case .profiles: profilesTab
                        case .capture: captureTab
                        case .permissions: permissionsTab
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: Self.contentMaxWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
                    .id(tab)
                }
                .scrollIndicators(.automatic)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(
            minWidth: Self.size.width, maxWidth: .infinity,
            minHeight: Self.size.height, maxHeight: .infinity
        )
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
            SettingsCaption("Active template")
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
            }
            Text("The active template shapes the Markdown when you export a stack.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileEditorPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProfileNameField(text: $profileEditor.draft.name) {
                profileTitleActions
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsCaption("Instructions for the AI")
                TextEditor(text: $profileEditor.draft.preamble)
                    .font(.body)
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(minHeight: 140, maxHeight: 140)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .accessibilityLabel("Template instructions")
                Text("Goes above your notes when you export them. Tell the AI what to do with them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Include with each note") {
                SettingsCard {
                    SettingsToggleRow("Date heading", isOn: $profileEditor.draft.includeHeading)
                    SettingsDivider(pastIcon: false)
                    SettingsToggleRow("Application", isOn: $profileEditor.draft.includeApplication)
                    SettingsDivider(pastIcon: false)
                    SettingsToggleRow("Window title", isOn: $profileEditor.draft.includeWindow)
                    SettingsDivider(pastIcon: false)
                    SettingsToggleRow("Link or working directory", isOn: $profileEditor.draft.includeLink)
                    SettingsDivider(pastIcon: false)
                    SettingsToggleRow("Timestamps", isOn: $profileEditor.draft.includeTimestamps)
                }
            }

            SettingsCard {
                SettingsToggleRow(
                    settings.stackExportMode.clearAfterTitle,
                    subtitle: "Start fresh once the notes have left the app.",
                    isOn: $profileEditor.draft.clearSessionAfterExport
                )
            }
        }
        .animation(.snappy(duration: 0.22), value: profileEditor.isDirty)
    }

    /// Save and Revert appear beside the name while there are changes;
    /// New and Delete are always there. Everything shares one baseline.
    private var profileTitleActions: some View {
        HStack(spacing: 8) {
            if profileEditor.isDirty {
                HStack(spacing: 6) {
                    Button("Revert", action: profileEditor.revert)
                    Button("Save", action: saveProfile)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                }
                .controlSize(.small)
                .transition(.opacity)
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 2)
                    .transition(.opacity)
            }
            CircleIconButton("plus", help: "New template from this draft…", label: "New template") {
                newProfile = NewProfileDraft(name: "\(profileEditor.draft.name) Copy")
            }
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
            CircleIconButton(
                "trash",
                help: profileEditor.isDirty
                    ? "Save or revert changes before deleting."
                    : "Delete this template…",
                label: "Delete template",
                action: deleteProfile
            )
            .disabled(!profileEditor.canDelete || profileEditor.isDirty)
        }
    }

    // MARK: - Shortcuts

    private var shortcutRegistrationIssues: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Shortcut unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.orange)
                ForEach(settings.shortcutRegistrationIssues) { issue in
                    Text("• \(issue.id.title): \(issue.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsMetrics.rowInset)
        }
    }

    private var voiceTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection("How it works") {
                SettingsCard {
                    SettingsIconRow(icon: "mic.fill", title: "Voice note", detail: Self.voiceNoteDetail) {
                        StaticKeycap(VoiceModifierShortcut.displayString)
                    }
                    SettingsDivider()
                    HowToRow(icon: "hand.raised.fill", lead: "Hold", sentence: "Speak, then release to save.")
                    SettingsDivider()
                    HowToRow(icon: "hand.tap.fill", lead: "Tap", sentence: "Talk as long as you like, tap again to save.")
                    SettingsDivider()
                    HowToRow(icon: "escape", lead: "Esc", sentence: "Discard the recording.")
                }
            }
            SettingsSection("Needed for voice") {
                PermissionCapabilityList(
                    permissionState: permissionState,
                    onShowAccessibilityHelper: onShowAccessibilityHelper,
                    onShowInputMonitoringHelper: onShowInputMonitoringHelper,
                    scope: .voice
                )
            }
            shortcutFeedbackView
        }
    }

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection("Making notes") {
                SettingsCard {
                    SettingsIconRow(icon: "mic.fill", title: "Voice note", detail: Self.voiceNoteDetail) {
                        StaticKeycap(VoiceModifierShortcut.displayString)
                    }
                    SettingsDivider()
                    shortcutRow(
                        icon: "square.and.pencil",
                        title: "Typed note",
                        detail: "Opens a note box for the selected text. For when you can't talk.",
                        slot: .capture
                    )
                }
            }
            SettingsSection("Your stack") {
                SettingsCard {
                    shortcutRow(
                        icon: "doc.on.clipboard",
                        title: settings.stackExportMode.shortcutTitle,
                        detail: settings.stackExportMode.shortcutDetail,
                        slot: .copy
                    )
                    SettingsDivider()
                    shortcutRow(
                        icon: "square.stack.3d.up",
                        title: "Show stack",
                        detail: "Opens the window with all your notes.",
                        slot: .stack
                    )
                    SettingsDivider()
                    shortcutRow(
                        icon: "arrow.left.arrow.right",
                        title: "Switch stack",
                        detail: "Jump between stacks, or make a new one by typing its name.",
                        slot: .switchSession
                    )
                    SettingsDivider()
                    shortcutRow(
                        icon: "trash",
                        title: "Clear stack",
                        detail: "Empties the current stack. Undo with ⌘Z in the stack window.",
                        slot: .clear
                    )
                }
            }
            shortcutFeedbackView
            Text("Click a shortcut, then press the keys you want. Press Escape to keep the old one. Some system shortcuts may not be available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func shortcutRow(
        icon: String,
        title: String,
        detail: String,
        slot: ShortcutSlot
    ) -> some View {
        SettingsIconRow(icon: icon, title: title, detail: detail) {
            KeyRecorder(combo: shortcutBinding(for: slot))
                .fixedSize()
        }
    }

    @ViewBuilder
    private var shortcutFeedbackView: some View {
        if let shortcutFeedback {
            Label(shortcutFeedback, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcutBinding(for slot: ShortcutSlot) -> Binding<KeyCombo> {
        Binding(
            get: { settings.combo(for: slot) },
            set: { proposed in
                do {
                    try settings.setShortcut(proposed, for: slot)
                    shortcutFeedback = nil
                } catch {
                    shortcutFeedback = error.localizedDescription
                }
            }
        )
    }

    // MARK: - Capture

    private var captureTab: some View {
        SettingsSection("Behavior") {
            SettingsCard {
                SettingsToggleRow(
                    "Paste straight into the app you are in",
                    subtitle: "The Markdown lands where your cursor is, without a separate paste.",
                    isOn: $settings.pasteDirectly
                )
                SettingsDivider(pastIcon: false)
                SettingsToggleRow(
                    "Return to the previous app after saving",
                    subtitle: "Hands focus back to where you were reading.",
                    isOn: $settings.restoreFocusAfterSave
                )
                SettingsDivider(pastIcon: false)
                SettingsToggleRow(
                    "Launch at login",
                    subtitle: "Keeps the shortcuts ready as soon as you sign in.",
                    isOn: $settings.launchAtLogin
                )
            }
        }
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection("Needed for every note") {
                PermissionCapabilityList(
                    permissionState: permissionState,
                    onShowAccessibilityHelper: onShowAccessibilityHelper,
                    onShowInputMonitoringHelper: onShowInputMonitoringHelper,
                    scope: .accessibility
                )
            }
            SettingsSection("Setup") {
                SettingsCard {
                    SettingsRow(
                        "Setup assistant",
                        subtitle: "Walk through permissions and the voice model again."
                    ) {
                        Button("Run Setup Again…", action: onRunSetup)
                    }
                }
            }
            Label {
                Text("Text, audio, and transcription never leave this Mac.")
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
/// A small anchored prompt: type a name, press Return.
private struct NewProfilePopover: View {
    @Binding var name: String
    let problem: String?
    let onCommit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New template from the current draft")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Template name", text: $name)
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

/// A round, quiet icon button for secondary actions beside a title.
private struct CircleIconButton: View {
    let icon: String
    let help: String
    let label: String
    let action: () -> Void

    init(_ icon: String, help: String, label: String, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(label)
    }
}

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
        .background(SidebarMaterial().ignoresSafeArea())
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
                SidebarTile(icon: tab.icon, tint: tab.tint)
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

/// A coloured tile in the System Settings idiom: a soft top-lit gradient
/// over the tint, a hairline rim that catches the light, and a white glyph.
private struct SidebarTile: View {
    let icon: String
    let tint: Color

    private let shape = RoundedRectangle(cornerRadius: 6.5, style: .continuous)

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            .frame(width: 24, height: 24)
            .background(
                shape.fill(tint)
                    .overlay(
                        shape.fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.0), .black.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            )
            .clipShape(shape)
            .accessibilityHidden(true)
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
                TextField("Template name", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .focused($focused)
                    .accessibilityLabel("Template name")
                accessory()
            }
            .frame(minHeight: 30)
            Rectangle()
                .fill(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1))
                .frame(height: 1)
        }
        .padding(.horizontal, 2)
        .animation(.easeOut(duration: 0.15), value: focused)
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
        alert.messageText = "Couldn't Change Template"
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
        alert.informativeText = "Choose what to do with this template."
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
            alert.messageText = "New Template"
            alert.informativeText = "Enter a unique template name."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(string: proposedName)
            field.placeholderString = "Template name"
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
