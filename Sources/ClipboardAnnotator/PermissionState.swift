import ApplicationServices
import Foundation
import Observation

/// Stable values shown by setup and Settings. The transient cases make each
/// finite lifecycle explicit instead of combining status booleans.
enum AccessibilityPermissionState: Equatable, Sendable {
    case checking
    case notGranted
    case granted
}

enum MicrophonePermissionState: Equatable, Sendable {
    case checking
    case notDetermined
    case denied
    case restricted
    case granted
}

enum LocalVoiceModelState: Equatable, Sendable {
    case checking
    case notDownloaded
    case downloading
    case ready
    case failed
}

enum PermissionAction: Equatable, Sendable {
    case requestAccessibility
    case showAccessibilityHelper
    case requestMicrophone
    case openMicrophoneSettings
    case downloadVoiceModel
}

/// A small closure boundary around macOS permission and model APIs.
/// Tests replace it with deterministic closures and never touch TCC.
struct PermissionServices: Sendable {
    var accessibilityStatus: @Sendable () async -> AccessibilityPermissionState
    var requestAccessibility: @Sendable () async -> Bool
    var microphoneStatus: @Sendable () async -> MicrophonePermissionState
    var requestMicrophone: @Sendable () async -> Bool
    var voiceModelIsReady: @Sendable () async -> Bool
    var downloadVoiceModel: @Sendable () async throws -> Void
    var openAccessibilitySettings: @MainActor @Sendable () -> Void
    var openMicrophoneSettings: @MainActor @Sendable () -> Void

    @MainActor
    static func live() -> PermissionServices {
        let checks = PermissionSystemChecks()
        return PermissionServices(
            accessibilityStatus: {
                await checks.accessibilityIsGranted() ? .granted : .notGranted
            },
            requestAccessibility: {
                await checks.requestAccessibility()
            },
            microphoneStatus: {
                await MainActor.run { PermissionCheck.microphonePermissionState }
            },
            requestMicrophone: {
                await VoiceAnnotationService.shared.requestMicrophoneAccess()
            },
            voiceModelIsReady: {
                await VoiceAnnotationService.shared.isVoiceModelReady()
            },
            downloadVoiceModel: {
                try await VoiceAnnotationService.shared.downloadVoiceModel()
            },
            openAccessibilitySettings: {
                PermissionCheck.openAccessibilitySettings()
            },
            openMicrophoneSettings: {
                PermissionCheck.openMicrophoneSettings()
            }
        )
    }
}

/// App-owned permission readiness. One instance lives as long as AppDelegate.
@MainActor
@Observable
final class PermissionState {
    private enum Lifecycle {
        case active
        case tornDown
    }

    private let services: PermissionServices
    private var lifecycle: Lifecycle = .active

    private(set) var accessibility: AccessibilityPermissionState = .checking
    private(set) var microphone: MicrophonePermissionState = .checking
    private(set) var localVoiceModel: LocalVoiceModelState = .checking
    private(set) var hasRequestedAccessibility = false

    var accessibilityAction: PermissionAction? {
        switch accessibility {
        case .checking, .granted:
            return nil
        case .notGranted:
            return hasRequestedAccessibility ? .showAccessibilityHelper : .requestAccessibility
        }
    }

    var microphoneAction: PermissionAction? {
        switch microphone {
        case .checking, .granted:
            return nil
        case .notDetermined:
            return .requestMicrophone
        case .denied, .restricted:
            return .openMicrophoneSettings
        }
    }

    var localVoiceModelAction: PermissionAction? {
        switch localVoiceModel {
        case .checking, .downloading, .ready:
            return nil
        case .notDownloaded, .failed:
            return .downloadVoiceModel
        }
    }

    var isTextCaptureReady: Bool {
        accessibility == .granted
    }

    var isVoiceReady: Bool {
        isTextCaptureReady && microphone == .granted && localVoiceModel == .ready
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var accessibilityRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var accessibilityRequestTask: Task<Void, Never>?
    @ObservationIgnored private var microphoneRequestTask: Task<Void, Never>?
    @ObservationIgnored private var modelDownloadTask: Task<Void, Never>?

    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var accessibilityGeneration = 0
    @ObservationIgnored private var microphoneGeneration = 0
    @ObservationIgnored private var modelGeneration = 0

    init(services: PermissionServices) {
        self.services = services
    }

    convenience init() {
        self.init(services: .live())
    }

    func refresh() {
        guard lifecycle == .active else { return }

        refreshTask?.cancel()
        refreshGeneration += 1
        let refreshID = refreshGeneration
        let accessibilityID = accessibilityGeneration
        let appliesAccessibility = accessibilityRefreshTask == nil
            && accessibilityRequestTask == nil
        let microphoneID = microphoneGeneration
        let modelID = modelGeneration
        let services = services

        // Keep the last useful values visible while a background refresh runs.
        // The initial values already communicate the first load.
        refreshTask = Task { [weak self, services] in
            guard !Task.isCancelled else { return }
            async let accessibility = services.accessibilityStatus()
            async let microphone = services.microphoneStatus()
            async let modelIsReady = services.voiceModelIsReady()

            let result = await (accessibility, microphone, modelIsReady)
            guard !Task.isCancelled else { return }
            self?.finishRefresh(
                refreshID: refreshID,
                accessibilityID: accessibilityID,
                appliesAccessibility: appliesAccessibility,
                microphoneID: microphoneID,
                modelID: modelID,
                accessibility: result.0,
                microphone: result.1,
                modelIsReady: result.2
            )
        }
    }

    /// Refresh only Accessibility for helper polling. A running scoped check
    /// owns its task until completion, so polling ticks never restart it.
    func refreshAccessibility() {
        guard lifecycle == .active,
              accessibilityRefreshTask == nil,
              accessibilityRequestTask == nil
        else { return }

        accessibilityGeneration += 1
        let generation = accessibilityGeneration
        let services = services
        accessibilityRefreshTask = Task { [weak self, services] in
            guard !Task.isCancelled else { return }
            let status = await services.accessibilityStatus()
            guard !Task.isCancelled else { return }
            self?.finishAccessibilityRefresh(generation: generation, status: status)
        }
    }

    func requestAccessibility() {
        guard lifecycle == .active,
              accessibility == .notGranted,
              !hasRequestedAccessibility
        else { return }
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = nil
        accessibilityRequestTask?.cancel()
        hasRequestedAccessibility = true
        accessibilityGeneration += 1
        let generation = accessibilityGeneration
        let services = services
        accessibility = .checking

        accessibilityRequestTask = Task { [weak self, services] in
            guard !Task.isCancelled else { return }
            let granted = await services.requestAccessibility()
            guard !Task.isCancelled else { return }
            self?.finishAccessibilityRequest(generation: generation, granted: granted)
        }
    }

    func requestMicrophone() {
        guard lifecycle == .active, microphone == .notDetermined else { return }
        microphoneRequestTask?.cancel()
        microphoneGeneration += 1
        let generation = microphoneGeneration
        let services = services
        microphone = .checking

        microphoneRequestTask = Task { [weak self, services] in
            guard !Task.isCancelled else { return }
            let granted = await services.requestMicrophone()
            guard !Task.isCancelled else { return }
            self?.finishMicrophoneRequest(generation: generation, granted: granted)
        }
    }

    func downloadModel() {
        guard lifecycle == .active,
              modelDownloadTask == nil,
              localVoiceModel == .notDownloaded || localVoiceModel == .failed
        else { return }
        modelGeneration += 1
        let generation = modelGeneration
        let services = services
        localVoiceModel = .downloading

        modelDownloadTask = Task { [weak self, services] in
            do {
                try Task.checkCancellation()
                try await services.downloadVoiceModel()
                try Task.checkCancellation()
                self?.finishModelDownload(generation: generation, succeeded: true)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishModelDownload(generation: generation, succeeded: false)
            }
        }
    }

    func openAccessibilitySettings() {
        guard lifecycle == .active else { return }
        services.openAccessibilitySettings()
    }

    func openMicrophoneSettings() {
        guard lifecycle == .active else { return }
        services.openMicrophoneSettings()
    }

    /// Test and lifecycle support. It waits only for work owned at each pass.
    func waitForIdle() async {
        while lifecycle == .active {
            let tasks = [
                refreshTask,
                accessibilityRefreshTask,
                accessibilityRequestTask,
                microphoneRequestTask,
                modelDownloadTask,
            ].compactMap { $0 }
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }

    /// The sole teardown path. Repeated calls do nothing.
    func teardown() {
        guard lifecycle == .active else { return }
        lifecycle = .tornDown
        refreshGeneration += 1
        accessibilityGeneration += 1
        microphoneGeneration += 1
        modelGeneration += 1

        refreshTask?.cancel()
        accessibilityRefreshTask?.cancel()
        accessibilityRequestTask?.cancel()
        microphoneRequestTask?.cancel()
        modelDownloadTask?.cancel()
        refreshTask = nil
        accessibilityRefreshTask = nil
        accessibilityRequestTask = nil
        microphoneRequestTask = nil
        modelDownloadTask = nil
    }

    private func finishRefresh(
        refreshID: Int,
        accessibilityID: Int,
        appliesAccessibility: Bool,
        microphoneID: Int,
        modelID: Int,
        accessibility: AccessibilityPermissionState,
        microphone: MicrophonePermissionState,
        modelIsReady: Bool
    ) {
        guard lifecycle == .active, refreshGeneration == refreshID else { return }
        refreshTask = nil
        if appliesAccessibility, accessibilityGeneration == accessibilityID {
            self.accessibility = accessibility
        }
        if microphoneGeneration == microphoneID {
            self.microphone = microphone
        }
        if modelGeneration == modelID {
            localVoiceModel = modelIsReady ? .ready : .notDownloaded
        }
    }

    private func finishAccessibilityRefresh(
        generation: Int,
        status: AccessibilityPermissionState
    ) {
        guard lifecycle == .active, accessibilityGeneration == generation else { return }
        accessibilityGeneration += 1
        accessibilityRefreshTask = nil
        accessibility = status
    }

    private func finishAccessibilityRequest(generation: Int, granted: Bool) {
        guard lifecycle == .active, accessibilityGeneration == generation else { return }
        accessibilityGeneration += 1
        accessibilityRequestTask = nil
        accessibility = granted ? .granted : .notGranted
    }

    private func finishMicrophoneRequest(generation: Int, granted: Bool) {
        guard lifecycle == .active, microphoneGeneration == generation else { return }
        microphoneGeneration += 1
        microphoneRequestTask = nil
        microphone = granted ? .granted : .denied
    }

    private func finishModelDownload(generation: Int, succeeded: Bool) {
        guard lifecycle == .active, modelGeneration == generation else { return }
        modelGeneration += 1
        modelDownloadTask = nil
        localVoiceModel = succeeded ? .ready : .failed
    }
}

/// Potentially blocking Accessibility checks run off MainActor.
private actor PermissionSystemChecks {
    func accessibilityIsGranted() -> Bool {
        guard !Task.isCancelled else { return false }
        let granted = AXIsProcessTrusted()
        guard !Task.isCancelled else { return false }
        return granted
    }

    func requestAccessibility() -> Bool {
        guard !Task.isCancelled else { return false }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        guard !Task.isCancelled else { return false }
        return granted
    }
}
