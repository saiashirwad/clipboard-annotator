import AppKit
import SwiftUI

enum PermissionCapabilityScope: Equatable {
    case setup
    case voice
    case accessibility

    var showsAccessibility: Bool {
        switch self {
        case .setup, .accessibility: true
        case .voice: false
        }
    }

    var showsMicrophone: Bool {
        switch self {
        case .setup, .voice: true
        case .accessibility: false
        }
    }

    var showsInputMonitoring: Bool {
        switch self {
        case .setup, .voice: true
        case .accessibility: false
        }
    }

    var showsVoiceModel: Bool {
        switch self {
        case .setup, .voice: true
        case .accessibility: false
        }
    }
}

struct SetupView: View {
    @Bindable var settings: AppSettings
    @Bindable var permissionState: PermissionState
    let onShowAccessibilityHelper: () -> Void
    let onShowInputMonitoringHelper: () -> Void
    let onComplete: () -> Void

    init(
        settings: AppSettings,
        permissionState: PermissionState,
        onShowAccessibilityHelper: @escaping () -> Void,
        onShowInputMonitoringHelper: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        _settings = Bindable(wrappedValue: settings)
        _permissionState = Bindable(wrappedValue: permissionState)
        self.onShowAccessibilityHelper = onShowAccessibilityHelper
        self.onShowInputMonitoringHelper = onShowInputMonitoringHelper
        self.onComplete = onComplete
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("Set Up Sendpoint")
                        .font(.largeTitle.weight(.semibold))
                    Text("Select text anywhere, hold \(VoiceModifierShortcut.displayString), and say what you think. Sendpoint keeps the passage and your words together in a stack you can copy out as one prompt.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 24)

                PermissionCapabilityList(
                    permissionState: permissionState,
                    onShowAccessibilityHelper: onShowAccessibilityHelper,
                    onShowInputMonitoringHelper: onShowInputMonitoringHelper,
                    scope: .setup
                )

                shortcutGuide

                VStack(spacing: 14) {
                    Label {
                        Text("Selected text, notes, audio, transcription, and voice-model work stay on this Mac.")
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Button(primaryButtonTitle) {
                        settings.completeSetup()
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!permissionState.isVoiceReady)
                    .keyboardShortcut(.defaultAction)

                    if !permissionState.isVoiceReady {
                        Text("Finish the three steps above to start using Sendpoint.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 24)
            }
            .padding(30)
            .frame(width: 640)
        }
        .frame(width: 640, height: 620)
        .scrollIndicators(.automatic)
    }

    private var primaryButtonTitle: String {
        "Start Using Sendpoint"
    }

    private var shortcutGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How to use it")
                .font(.headline)
            SettingsCard {
                HowToRow(
                    icon: "hand.raised.fill",
                    lead: "Hold",
                    sentence: "Speak, then release to save.",
                    keycap: VoiceModifierShortcut.displayString
                )
                SettingsDivider()
                HowToRow(
                    icon: "hand.tap.fill",
                    lead: "Tap",
                    sentence: "Talk as long as you like, tap again to save.",
                    keycap: VoiceModifierShortcut.displayString
                )
                SettingsDivider()
                HowToRow(
                    icon: "escape",
                    lead: "Esc",
                    sentence: "Discard the recording."
                )
                SettingsDivider()
                HowToRow(
                    icon: "square.and.pencil",
                    lead: "Type instead",
                    sentence: "For when you can't talk out loud.",
                    keycap: settings.captureCombo.displayString
                )
            }
        }
    }
}

struct PermissionCapabilityList: View {
    @Bindable var permissionState: PermissionState
    let onShowAccessibilityHelper: () -> Void
    let onShowInputMonitoringHelper: () -> Void
    let scope: PermissionCapabilityScope

    init(
        permissionState: PermissionState,
        onShowAccessibilityHelper: @escaping () -> Void,
        onShowInputMonitoringHelper: @escaping () -> Void,
        scope: PermissionCapabilityScope = .setup
    ) {
        _permissionState = Bindable(wrappedValue: permissionState)
        self.onShowAccessibilityHelper = onShowAccessibilityHelper
        self.onShowInputMonitoringHelper = onShowInputMonitoringHelper
        self.scope = scope
    }

    var body: some View {
        if scope.showsVoiceModel {
            capabilityRows
                .task {
                    await permissionState.watchVoiceModel()
                }
        } else {
            capabilityRows
        }
    }

    @ViewBuilder
    private var capabilityRows: some View {
        SettingsCard {
            if scope.showsAccessibility {
                accessibilityRow
            }
            if scope.showsInputMonitoring {
                if scope.showsAccessibility {
                    SettingsDivider()
                }
                inputMonitoringRow
            }
            if scope.showsMicrophone {
                if scope.showsAccessibility || scope.showsInputMonitoring {
                    SettingsDivider()
                }
                microphoneRow
            }
            if scope.showsVoiceModel {
                if scope.showsAccessibility || scope.showsInputMonitoring || scope.showsMicrophone {
                    SettingsDivider()
                }
                voiceModelRow
            }
        }
    }

    private var accessibilityRow: some View {
        CapabilityRow(
            icon: "text.viewfinder",
            title: "Accessibility",
            reason: "Lets Sendpoint read the text you select. Needed for every note.",
            status: accessibilityStatus,
            actionTitle: accessibilityActionTitle,
            showsProgress: permissionState.accessibility == .checking,
            action: performAccessibilityAction
        )
    }

    private var microphoneRow: some View {
        CapabilityRow(
            icon: "mic",
            title: "Microphone",
            reason: "Needed for voice notes. Sendpoint only listens while a voice note is open.",
            status: microphoneStatus,
            actionTitle: microphoneActionTitle,
            showsProgress: permissionState.microphone == .checking,
            action: performMicrophoneAction
        )
    }

    private var inputMonitoringRow: some View {
        CapabilityRow(
            icon: "keyboard",
            title: "Input Monitoring",
            reason: "Lets Sendpoint recognize \(VoiceModifierShortcut.displayString) in any app.",
            status: inputMonitoringStatus,
            actionTitle: inputMonitoringActionTitle,
            showsProgress: permissionState.inputMonitoring == .checking,
            action: performInputMonitoringAction
        )
    }

    private var voiceModelRow: some View {
        CapabilityRow(
            icon: "waveform",
            title: "Local voice model",
            reason: voiceModelReason,
            status: voiceModelStatus,
            actionTitle: voiceModelActionTitle,
            showsProgress: voiceModelIsDownloading,
            action: performVoiceModelAction
        )
    }

    private var voiceModelReason: String {
        if case .ready = permissionState.localVoiceModel {
            return "Speech to text with Parakeet v3, on this Mac."
        }
        return "Speech to text with Parakeet v3. One-time 460 MB download."
    }

    private var accessibilityStatus: CapabilityStatus {
        switch permissionState.accessibility {
        case .checking: .neutral("Checking…")
        case .notGranted: .attention("Required")
        case .granted: .ready("Granted")
        }
    }

    private var microphoneStatus: CapabilityStatus {
        switch permissionState.microphone {
        case .checking: .neutral("Checking…")
        case .notDetermined: .neutral("Not enabled")
        case .denied: .attention("Denied")
        case .restricted: .attention("Restricted")
        case .granted: .ready("Granted")
        }
    }

    private var inputMonitoringStatus: CapabilityStatus {
        switch permissionState.inputMonitoring {
        case .checking: .neutral("Checking…")
        case .notGranted: .attention("Required")
        case .granted: .ready("Granted")
        }
    }

    private var voiceModelStatus: CapabilityStatus {
        switch permissionState.localVoiceModel {
        case .notDownloaded: .neutral("Not downloaded")
        case let .downloading(progress):
            .neutral(progress.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…")
        case .ready: .ready("Downloaded")
        case .failed(.offline): .attention("No internet connection")
        case .failed(.other): .attention("Download failed")
        }
    }

    private var voiceModelIsDownloading: Bool {
        if case .downloading = permissionState.localVoiceModel {
            return true
        }
        return false
    }

    private var accessibilityActionTitle: String? {
        switch permissionState.accessibilityAction {
        case .requestAccessibility: "Grant Access…"
        case .showAccessibilityHelper: "Finish Setup…"
        default: nil
        }
    }

    private var microphoneActionTitle: String? {
        switch permissionState.microphoneAction {
        case .requestMicrophone: "Allow Microphone…"
        case .openMicrophoneSettings: "Open System Settings…"
        default: nil
        }
    }

    private var inputMonitoringActionTitle: String? {
        switch permissionState.inputMonitoringAction {
        case .requestInputMonitoring: "Grant Access…"
        case .showInputMonitoringHelper: "Finish Setup…"
        default: nil
        }
    }

    private var voiceModelActionTitle: String? {
        guard permissionState.localVoiceModelAction == .downloadVoiceModel else { return nil }
        if case .failed = permissionState.localVoiceModel { return "Retry Download…" }
        return "Download Model…"
    }

    private func performAccessibilityAction() {
        switch permissionState.accessibilityAction {
        case .requestAccessibility:
            permissionState.requestAccessibility()
            onShowAccessibilityHelper()
        case .showAccessibilityHelper:
            onShowAccessibilityHelper()
        default:
            break
        }
    }

    private func performMicrophoneAction() {
        switch permissionState.microphoneAction {
        case .requestMicrophone:
            permissionState.requestMicrophone()
        case .openMicrophoneSettings:
            permissionState.openMicrophoneSettings()
        default:
            break
        }
    }

    private func performInputMonitoringAction() {
        switch permissionState.inputMonitoringAction {
        case .requestInputMonitoring:
            permissionState.requestInputMonitoring()
            onShowInputMonitoringHelper()
        case .showInputMonitoringHelper:
            onShowInputMonitoringHelper()
        default:
            break
        }
    }

    private func performVoiceModelAction() {
        guard permissionState.localVoiceModelAction == .downloadVoiceModel else { return }
        permissionState.downloadModel()
    }

}

private enum CapabilityStatus {
    case neutral(String)
    case attention(String)
    case ready(String)

    var title: String {
        switch self {
        case let .neutral(title), let .attention(title), let .ready(title): title
        }
    }

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .attention: .orange
        case .ready: .green
        }
    }

    /// Ready reads quietly once everything is in place; only trouble is loud.
    var textColor: Color {
        switch self {
        case .neutral, .ready: .secondary
        case .attention: .orange
        }
    }
}

private struct CapabilityRow: View {
    let icon: String
    let title: String
    let reason: String
    let status: CapabilityStatus
    let actionTitle: String?
    let showsProgress: Bool
    let action: () -> Void

    var body: some View {
        SettingsIconRow(icon: icon, title: title, detail: reason) {
            VStack(alignment: .trailing, spacing: 7) {
                statusLabel
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 5) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else if case .ready = status {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
            }
            Text(status.title)
                .font(.callout)
                .foregroundStyle(status.textColor)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private enum Lifecycle {
        case active
        case tornDown
    }

    private let window: NSWindow
    private var lifecycle: Lifecycle = .active

    init(
        settings: AppSettings,
        permissionState: PermissionState,
        onShowAccessibilityHelper: @escaping () -> Void,
        onShowInputMonitoringHelper: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Sendpoint"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView(
            settings: settings,
            permissionState: permissionState,
            onShowAccessibilityHelper: onShowAccessibilityHelper,
            onShowInputMonitoringHelper: onShowInputMonitoringHelper,
            onComplete: onComplete
        ))
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 640, height: 600))
        window.center()
        self.window = window
        super.init()
        window.delegate = self
    }

    func show() {
        guard lifecycle == .active else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard lifecycle == .active else { return }
        window.orderOut(nil)
        window.close()
    }

    func teardown() {
        guard lifecycle == .active else { return }
        lifecycle = .tornDown
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }
}

enum PermissionHelperKind {
    case accessibility
    case inputMonitoring

    var name: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var settingsPath: String {
        "Privacy & Security → \(name)"
    }

    @MainActor
    func isGranted(in state: PermissionState) -> Bool {
        switch self {
        case .accessibility: state.accessibility == .granted
        case .inputMonitoring: state.inputMonitoring == .granted
        }
    }

    @MainActor
    func refresh(_ state: PermissionState) {
        switch self {
        case .accessibility: state.refreshAccessibility()
        case .inputMonitoring: state.refreshInputMonitoring()
        }
    }

    @MainActor
    func openSettings(_ state: PermissionState) {
        switch self {
        case .accessibility: state.openAccessibilitySettings()
        case .inputMonitoring: state.openInputMonitoringSettings()
        }
    }
}

private struct PermissionHelperView: View {
    @Bindable var permissionState: PermissionState
    let kind: PermissionHelperKind
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sendpoint")
                        .font(.title2.weight(.semibold))
                    Label(
                        kind.isGranted(in: permissionState)
                            ? "\(kind.name) granted"
                            : "\(kind.name) needs a manual grant",
                        systemImage: kind.isGranted(in: permissionState)
                            ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(kind.isGranted(in: permissionState) ? .green : .orange)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Finish in System Settings")
                    .font(.headline)
                Text("1. Open \(kind.settingsPath).")
                Text("2. Turn on Sendpoint in the app list.")
                Text("3. Return here. This window closes when access is granted.")
            }

            HStack {
                Button("Close", action: onClose)
                Spacer()
                Button("Open \(kind.name) Settings…", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}

@MainActor
final class PermissionHelperWindowController: NSObject, NSWindowDelegate {
    private enum Lifecycle {
        case hidden
        case visible
        case tornDown
    }

    private let permissionState: PermissionState
    private let kind: PermissionHelperKind
    private let window: NSWindow
    private var lifecycle: Lifecycle = .hidden
    private var pollingTask: Task<Void, Never>?

    init(permissionState: PermissionState, kind: PermissionHelperKind) {
        self.permissionState = permissionState
        self.kind = kind
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 310),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(kind.name) Setup"
        window.isReleasedWhenClosed = false
        self.window = window
        super.init()
        window.contentView = NSHostingView(rootView: PermissionHelperView(
            permissionState: permissionState,
            kind: kind,
            onOpenSettings: { [weak permissionState] in
                guard let permissionState else { return }
                kind.openSettings(permissionState)
            },
            onClose: { [weak self] in self?.close() }
        ))
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 470, height: 310))
        window.center()
        window.delegate = self
    }

    func show() {
        guard lifecycle != .tornDown else { return }
        lifecycle = .visible
        kind.refresh(permissionState)
        startPolling()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        close(closingWindow: false)
    }

    func teardown() {
        guard lifecycle != .tornDown else { return }
        lifecycle = .tornDown
        pollingTask?.cancel()
        pollingTask = nil
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        close(closingWindow: true)
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while let self, self.lifecycle == .visible {
                guard !Task.isCancelled else { return }
                self.kind.refresh(self.permissionState)
                do {
                    try await Task.sleep(for: .milliseconds(700))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.lifecycle == .visible else { return }
                if self.kind.isGranted(in: self.permissionState) {
                    self.close()
                    return
                }
            }
        }
    }

    private func close(closingWindow: Bool) {
        guard lifecycle == .visible else { return }
        lifecycle = .hidden
        pollingTask?.cancel()
        pollingTask = nil
        guard !closingWindow else { return }
        window.orderOut(nil)
        window.close()
    }
}
