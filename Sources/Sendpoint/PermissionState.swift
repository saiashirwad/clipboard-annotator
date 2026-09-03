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
    case notDownloaded
    case downloading(progress: Double?)
    case ready
    case failed(VoiceModelDownloadFailure)
}

enum VoiceModelDownloadFailure: Equatable, Sendable {
    /// The Mac had no usable network path to the model host.
    case offline
    case other

    init(_ error: Error) {
        let offlineCodes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
        ]
        if let urlError = error as? URLError, offlineCodes.contains(urlError.code) {
            self = .offline
        } else {
            self = .other
        }
    }
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
    var voiceModelFilesExist: @Sendable () -> Bool
    var downloadVoiceModel: @Sendable (
        _ onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Void
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
            voiceModelFilesExist: {
                LocalVoiceModelFiles.exist()
            },
            downloadVoiceModel: { onProgress in
                try await VoiceAnnotationService.shared.downloadVoiceModel(
                    onProgress: onProgress
                )
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
    private(set) var localVoiceModel: LocalVoiceModelState
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
        case .downloading, .ready:
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
    @ObservationIgnored private var modelProgressTask: Task<Void, Never>?
    @ObservationIgnored private var readinessObserver: NSObjectProtocol?

    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var accessibilityGeneration = 0
    @ObservationIgnored private var microphoneGeneration = 0
    @ObservationIgnored private var modelGeneration = 0

    init(services: PermissionServices) {
        self.services = services
        localVoiceModel = services.voiceModelFilesExist() ? .ready : .notDownloaded
        readinessObserver = NotificationCenter.default.addObserver(
            forName: .voiceModelDidBecomeReady,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.voiceModelBecameReady()
            }
        }
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
        let services = services

        // Model readiness is an on-disk fact. Read it without joining the
        // unrelated asynchronous permission checks.
        refreshVoiceModel()

        // Keep the last useful values visible while a background refresh runs.
        // The initial values already communicate the first load.
        refreshTask = Task { [weak self, services] in
            guard !Task.isCancelled else { return }
            async let accessibility = services.accessibilityStatus()
            async let microphone = services.microphoneStatus()

            let result = await (accessibility, microphone)
            guard !Task.isCancelled else { return }
            self?.finishRefresh(
                refreshID: refreshID,
                accessibilityID: accessibilityID,
                appliesAccessibility: appliesAccessibility,
                microphoneID: microphoneID,
                accessibility: result.0,
                microphone: result.1
            )
        }
    }

    func voiceModelBecameReady() {
        guard lifecycle == .active else { return }
        // Let this instance's download finish through its one completion path.
        // A capture-time preparation has no owned task, so it invalidates any
        // older model result before publishing readiness.
        if modelDownloadTask == nil {
            modelGeneration += 1
        }
        localVoiceModel = .ready
    }

    /// Re-read the model files without hiding a download or its last failure.
    func refreshVoiceModel() {
        guard lifecycle == .active, modelDownloadTask == nil else { return }
        if services.voiceModelFilesExist() {
            if localVoiceModel != .ready {
                modelGeneration += 1
                localVoiceModel = .ready
            }
            return
        }
        if case .failed = localVoiceModel { return }
        if localVoiceModel != .notDownloaded {
            modelGeneration += 1
            localVoiceModel = .notDownloaded
        }
    }

    /// Watch the files only while Setup or Settings shows this state.
    func watchVoiceModel(interval: Duration = .seconds(2)) async {
        while lifecycle == .active, !Task.isCancelled {
            refreshVoiceModel()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
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
              localVoiceModelAction == .downloadVoiceModel
        else { return }
        modelGeneration += 1
        let generation = modelGeneration
        let services = services
        localVoiceModel = .downloading(progress: nil)

        let (progressValues, progressContinuation) = AsyncStream.makeStream(of: Double.self)
        modelProgressTask = Task { [weak self] in
            for await fraction in progressValues {
                guard !Task.isCancelled else { return }
                self?.reportModelDownloadProgress(
                    generation: generation,
                    fraction: fraction
                )
            }
        }
        let reportProgress: @Sendable (Double) -> Void = { fraction in
            progressContinuation.yield(fraction)
        }

        modelDownloadTask = Task { [weak self, services] in
            defer { progressContinuation.finish() }
            do {
                try Task.checkCancellation()
                try await services.downloadVoiceModel(reportProgress)
                try Task.checkCancellation()
                self?.finishModelDownload(generation: generation, result: .ready)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishModelDownload(
                    generation: generation,
                    result: .failed(VoiceModelDownloadFailure(error))
                )
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
                modelProgressTask,
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
        modelProgressTask?.cancel()
        if let readinessObserver {
            NotificationCenter.default.removeObserver(readinessObserver)
            self.readinessObserver = nil
        }
        refreshTask = nil
        accessibilityRefreshTask = nil
        accessibilityRequestTask = nil
        microphoneRequestTask = nil
        modelDownloadTask = nil
        modelProgressTask = nil
    }

    private func finishRefresh(
        refreshID: Int,
        accessibilityID: Int,
        appliesAccessibility: Bool,
        microphoneID: Int,
        accessibility: AccessibilityPermissionState,
        microphone: MicrophonePermissionState
    ) {
        guard lifecycle == .active, refreshGeneration == refreshID else { return }
        refreshTask = nil
        if appliesAccessibility, accessibilityGeneration == accessibilityID {
            self.accessibility = accessibility
        }
        if microphoneGeneration == microphoneID {
            self.microphone = microphone
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

    private func reportModelDownloadProgress(generation: Int, fraction: Double) {
        guard lifecycle == .active,
              modelGeneration == generation,
              case .downloading = localVoiceModel
        else { return }
        localVoiceModel = .downloading(progress: min(max(fraction, 0), 1))
    }

    private func finishModelDownload(generation: Int, result: LocalVoiceModelState) {
        guard lifecycle == .active, modelGeneration == generation else { return }
        modelGeneration += 1
        modelDownloadTask = nil
        modelProgressTask?.cancel()
        modelProgressTask = nil
        // File readiness is authoritative. A shared preparation can publish it
        // before this caller returns, so a later caller-specific error must not
        // replace the ready state.
        if case .ready = localVoiceModel, case .failed = result { return }
        localVoiceModel = result
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
