import Foundation
import Observation

/// A failure from a queued annotation-store transition.
public enum AnnotationStoreError: Error, Equatable, Sendable {
    case mutationRejected(String)
    case commitFailed(String)
    case tornDown
}

/// Owns the last committed session document and serializes all changes to it.
@MainActor
@Observable
public final class AnnotationStore {
    private enum CommitOutcome {
        case committed
        case failed
        case cancelled
    }

    private var document: StoreDocument
    private let persistence: StorePersistence
    private let onChange: @MainActor @Sendable () -> Void

    private var queuedMutations: [SessionDocumentMutation] = []
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isHalted = false

    public private(set) var error: AnnotationStoreError?
    public private(set) var isTornDown = false

    public var sessions: [Session] {
        document.sessions
    }

    public var currentSessionID: UUID {
        document.currentSessionID
    }

    public var currentSession: Session {
        // StoreDocument validation guarantees this lookup succeeds.
        document.sessions.first { $0.id == document.currentSessionID }!
    }

    public var currentEntries: [Annotation] {
        currentSession.entries
    }

    public var lastCleared: ClearedBatch? {
        document.lastCleared
    }

    public var hasPendingMutations: Bool {
        !queuedMutations.isEmpty
    }

    /// Loads the committed document. On first launch it commits `Default`
    /// before making the store available to its caller.
    public init(
        persistence: StorePersistence,
        defaultSession: Session = Session(name: "Default"),
        onChange: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws {
        let loaded = try await persistence.load()
        let initialDocument: StoreDocument
        if let loaded {
            try SessionDocumentMutations.validate(loaded)
            initialDocument = loaded
        } else {
            let candidate = StoreDocument(
                sessions: [defaultSession],
                currentSessionID: defaultSession.id
            )
            try SessionDocumentMutations.validate(candidate)
            try Task.checkCancellation()
            try await persistence.commit(candidate)
            try Task.checkCancellation()
            initialDocument = candidate
        }

        self.document = initialDocument
        self.persistence = persistence
        self.onChange = onChange
    }

    /// Enqueues one pure document transition. The next candidate always starts
    /// from the last document whose commit completed successfully.
    public func mutate(_ mutation: SessionDocumentMutation) {
        guard !isTornDown else {
            error = .tornDown
            return
        }

        queuedMutations.append(mutation)
        startProcessingIfNeeded()
    }

    /// Resumes work retained after a commit failure.
    public func retryPendingMutations() {
        guard !isTornDown else {
            error = .tornDown
            return
        }
        guard processingTask == nil, hasPendingMutations else { return }
        isHalted = false
        startProcessingIfNeeded()
    }

    /// Returns when the active drain completes or halts.
    public func waitForIdle() async {
        guard !isTornDown, processingTask != nil else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    /// Stops accepting changes, discards queued work, and cancels
    /// the one task owned by the store. Repeated calls have no further effect.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        isHalted = false
        queuedMutations.removeAll()
        processingTask?.cancel()
        resumeIdleWaiters()
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil, !isHalted else { return }
        processingTask = Task { [weak self] in
            await self?.processQueue()
        }
    }

    private func processQueue() async {
        while !Task.isCancelled, !queuedMutations.isEmpty {
            let mutation = queuedMutations.removeFirst()
            switch SessionDocumentMutations.applying(mutation, to: document) {
            case let .applied(candidate):
                switch await commit(candidate) {
                case .committed:
                    break
                case .failed:
                    queuedMutations.insert(mutation, at: 0)
                    isHalted = true
                    finishProcessing()
                    return
                case .cancelled:
                    finishProcessing()
                    return
                }
            case .noOp:
                break
            case let .rejected(message):
                error = .mutationRejected(message)
            }
        }

        finishProcessing()
    }

    private func commit(_ candidate: StoreDocument) async -> CommitOutcome {
        do {
            try Task.checkCancellation()
            try await persistence.commit(candidate)
            try Task.checkCancellation()
        } catch is CancellationError {
            return .cancelled
        } catch {
            self.error = .commitFailed(String(describing: error))
            return .failed
        }

        guard !isTornDown else { return .cancelled }
        document = candidate
        error = nil
        onChange()
        return .committed
    }

    private func finishProcessing() {
        processingTask = nil
        resumeIdleWaiters()
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
