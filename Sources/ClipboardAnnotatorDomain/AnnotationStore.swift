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
    private struct QueuedMutation: Sendable {
        let mutation: SessionDocumentMutation
    }

    private enum CommitOutcome {
        case committed
        case failed
        case cancelled
    }

    private var document: StoreDocument
    private let persistence: StorePersistence
    private let onChange: @MainActor @Sendable () -> Void

    private var queuedMutations: [QueuedMutation] = []
    private var deferredMutations: [QueuedMutation] = []
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
        !queuedMutations.isEmpty || !deferredMutations.isEmpty
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

        queuedMutations.append(QueuedMutation(mutation: mutation))
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

    /// Returns when the active drain completes or halts. Retained mutations and
    /// deferred late updates do not keep this barrier suspended.
    public func waitForIdle() async {
        guard !isTornDown, processingTask != nil else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    /// Stops accepting changes, discards queued and deferred work, and cancels
    /// the one task owned by the store. Repeated calls have no further effect.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        isHalted = false
        queuedMutations.removeAll()
        deferredMutations.removeAll()
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
        if !deferredMutations.isEmpty {
            guard await retryDeferredMutations() else {
                finishProcessing()
                return
            }
        }

        while !Task.isCancelled, !queuedMutations.isEmpty {
            let queued = queuedMutations.removeFirst()
            switch SessionDocumentMutations.applying(queued.mutation, to: document) {
            case let .applied(candidate):
                switch await commit(candidate) {
                case .committed:
                    guard await retryDeferredMutations() else {
                        finishProcessing()
                        return
                    }
                case .failed:
                    queuedMutations.insert(queued, at: 0)
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
            case .deferred:
                deferredMutations.append(queued)
            }
        }

        finishProcessing()
    }

    /// Returns false when processing must halt or stop.
    private func retryDeferredMutations() async -> Bool {
        guard !Task.isCancelled, !deferredMutations.isEmpty else {
            return !Task.isCancelled
        }
        let pending = deferredMutations
        deferredMutations.removeAll()
        var retained: [QueuedMutation] = []

        for (index, queued) in pending.enumerated() {
            guard !Task.isCancelled else { return false }
            switch SessionDocumentMutations.applying(queued.mutation, to: document) {
            case let .applied(candidate):
                switch await commit(candidate) {
                case .committed:
                    break
                case .failed:
                    deferredMutations = retained + pending[index...]
                    isHalted = true
                    return false
                case .cancelled:
                    return false
                }
            case .noOp:
                break
            case let .rejected(message):
                error = .mutationRejected(message)
            case .deferred:
                retained.append(queued)
            }
        }

        deferredMutations = retained
        return true
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
