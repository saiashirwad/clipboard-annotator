import AppKit
import SwiftUI

struct SetupView: View {
    @Bindable var settings: AppSettings
    @Bindable var permissionState: PermissionState
    let onShowAccessibilityHelper: () -> Void
    let onComplete: () -> Void

    init(
        settings: AppSettings,
        permissionState: PermissionState,
        onShowAccessibilityHelper: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        _settings = Bindable(wrappedValue: settings)
        _permissionState = Bindable(wrappedValue: permissionState)
        self.onShowAccessibilityHelper = onShowAccessibilityHelper
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Set Up Sendpoint")
                    .font(.largeTitle.weight(.semibold))
                Text("Capture selected text from any app. Accessibility enables capture; voice is optional.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 24)

            PermissionCapabilityList(
                permissionState: permissionState,
                onShowAccessibilityHelper: onShowAccessibilityHelper
            )

            VStack(spacing: 14) {
                Label {
                    Text("Selected text, notes, audio, transcription, provenance, and voice-model work stay on this Mac.")
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
                .disabled(!permissionState.isTextCaptureReady)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(30)
        .frame(width: 640)
    }

    private var primaryButtonTitle: String {
        permissionState.isVoiceReady ? "Continue" : "Use Text Capture for Now"
    }
}

struct PermissionCapabilityList: View {
    @Bindable var permissionState: PermissionState
    let onShowAccessibilityHelper: () -> Void

    init(
        permissionState: PermissionState,
        onShowAccessibilityHelper: @escaping () -> Void
    ) {
        _permissionState = Bindable(wrappedValue: permissionState)
        self.onShowAccessibilityHelper = onShowAccessibilityHelper
    }

    var body: some View {
        VStack(spacing: 0) {
            accessibilityRow
            Divider().padding(.leading, 46)
            microphoneRow
            Divider().padding(.leading, 46)
            voiceModelRow
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.65))
        }
        .task {
            await permissionState.watchVoiceModel()
        }
    }

    private var accessibilityRow: some View {
        CapabilityRow(
            icon: "text.viewfinder",
            title: "Accessibility",
            reason: "Reads the text you select in other apps. Required for capture.",
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
            reason: "Records only while you hold the voice shortcut. Optional.",
            status: microphoneStatus,
            actionTitle: microphoneActionTitle,
            showsProgress: permissionState.microphone == .checking,
            action: performMicrophoneAction
        )
    }

    private var voiceModelRow: some View {
        CapabilityRow(
            icon: "waveform",
            title: "Local voice model",
            reason: "Transcribes voice annotations on this Mac. Optional. A one-time 460 MB download.",
            status: voiceModelStatus,
            actionTitle: voiceModelActionTitle,
            showsProgress: voiceModelIsDownloading,
            action: performVoiceModelAction
        )
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
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 6) {
                    if showsProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                    }
                    Text(status.title)
                        .font(.callout)
                        .foregroundStyle(status.color)
                }

                if let actionTitle {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
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

private struct AccessibilityHelperView: View {
    @Bindable var permissionState: PermissionState
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
                        permissionState.accessibility == .granted ? "Accessibility granted" : "Accessibility needs a manual grant",
                        systemImage: permissionState.accessibility == .granted
                            ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(permissionState.accessibility == .granted ? .green : .orange)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Finish in System Settings")
                    .font(.headline)
                Text("1. Open Privacy & Security → Accessibility.")
                Text("2. Turn on Sendpoint in the app list.")
                Text("3. Return here. This window closes when access is granted.")
            }

            HStack {
                Button("Close", action: onClose)
                Spacer()
                Button("Open Accessibility Settings…", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}

@MainActor
final class AccessibilityHelperWindowController: NSObject, NSWindowDelegate {
    private enum Lifecycle {
        case hidden
        case visible
        case tornDown
    }

    private let permissionState: PermissionState
    private let window: NSWindow
    private var lifecycle: Lifecycle = .hidden
    private var pollingTask: Task<Void, Never>?

    init(permissionState: PermissionState) {
        self.permissionState = permissionState
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 310),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Accessibility Setup"
        window.isReleasedWhenClosed = false
        self.window = window
        super.init()
        window.contentView = NSHostingView(rootView: AccessibilityHelperView(
            permissionState: permissionState,
            onOpenSettings: { [weak permissionState] in
                permissionState?.openAccessibilitySettings()
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
        permissionState.refreshAccessibility()
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
                self.permissionState.refreshAccessibility()
                do {
                    try await Task.sleep(for: .milliseconds(700))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.lifecycle == .visible else { return }
                if self.permissionState.accessibility == .granted {
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
