import ClipboardAnnotatorDomain
import Foundation

/// Retains probe work after a successful save, but not after an unsaved cancel.
@MainActor
final class PendingProvenanceWorkOwner {
    typealias LateUpdate = @MainActor (SessionDocumentMutation) -> Void

    private struct Route: Equatable, Sendable {
        let captureID: UUID
        let annotationID: UUID
        let sessionID: UUID
        let application: ApplicationIdentity

        init(target: AnnotationCaptureTarget) {
            captureID = target.captureID
            annotationID = target.annotationID
            sessionID = target.sessionID
            application = target.application
        }
    }

    private struct Work {
        let route: Route
        var task: Task<Void, Never>?
        var provenance: Provenance?
        var savedAnnotation: Annotation?
    }

    private let probe: ProvenanceProbe
    private let lateUpdate: LateUpdate
    private var workByCaptureID: [UUID: Work] = [:]
    private var activeTaskCaptureIDs: Set<UUID> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isTornDown = false

    init(probe: ProvenanceProbe, lateUpdate: @escaping LateUpdate) {
        self.probe = probe
        self.lateUpdate = lateUpdate
    }

    var pendingCount: Int { workByCaptureID.count }
    var pendingTaskCount: Int { activeTaskCaptureIDs.count }

    func waitForIdle() async {
        guard pendingTaskCount > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func start(for target: AnnotationCaptureTarget) {
        guard !isTornDown,
              workByCaptureID[target.captureID] == nil,
              !activeTaskCaptureIDs.contains(target.captureID)
        else { return }
        let route = Route(target: target)
        let application = CapturedApplication(
            identity: target.application,
            processIdentifier: target.captured.processIdentifier
        )
        workByCaptureID[route.captureID] = Work(
            route: route,
            task: nil,
            provenance: nil,
            savedAnnotation: nil
        )
        activeTaskCaptureIDs.insert(route.captureID)

        let task = Task { [weak self, probe] in
            let provenance = await probe.probe(application)
            if !Task.isCancelled {
                self?.probeFinished(provenance, route: route)
            }
            self?.probeTaskFinished(captureID: route.captureID)
        }
        workByCaptureID[route.captureID]?.task = task
    }

    /// Marks the capture saved and returns the best provenance available now.
    /// If work is still pending, the retained task will send one exact late update.
    func annotationForSave(
        _ annotation: Annotation,
        target: AnnotationCaptureTarget
    ) -> Annotation {
        guard !isTornDown,
              var work = workByCaptureID[target.captureID],
              work.route == Route(target: target),
              annotation.id == target.annotationID,
              annotation.provenance.application == target.application
        else { return annotation }

        if let provenance = work.provenance,
           provenance.application == target.application {
            var enriched = annotation
            enriched.provenance = provenance
            work.task?.cancel()
            workByCaptureID.removeValue(forKey: target.captureID)
            return enriched
        }

        work.savedAnnotation = annotation
        workByCaptureID[target.captureID] = work
        return annotation
    }

    /// Cancels only if this capture has not been queued for a save.
    func cancelBeforeSave(for target: AnnotationCaptureTarget) {
        guard let work = workByCaptureID[target.captureID],
              work.route == Route(target: target),
              work.savedAnnotation == nil
        else { return }
        work.task?.cancel()
        workByCaptureID.removeValue(forKey: target.captureID)
        resumeIdleWaitersIfNeeded()
    }

    /// Cancels matching work even after it was prepared for a save. Use this
    /// only when that save was rejected or the user chose a new destination.
    func abandon(for target: AnnotationCaptureTarget) {
        guard let work = workByCaptureID[target.captureID],
              work.route == Route(target: target)
        else { return }
        work.task?.cancel()
        workByCaptureID.removeValue(forKey: target.captureID)
        resumeIdleWaitersIfNeeded()
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        let work = workByCaptureID.values
        workByCaptureID.removeAll()
        activeTaskCaptureIDs.removeAll()
        work.forEach { $0.task?.cancel() }
        resumeIdleWaitersIfNeeded()
    }

    private func probeFinished(_ provenance: Provenance, route: Route) {
        guard !isTornDown,
              var work = workByCaptureID[route.captureID],
              work.route == route
        else { return }
        work.task = nil

        guard provenance.application == route.application else {
            workByCaptureID.removeValue(forKey: route.captureID)
            return
        }

        guard let saved = work.savedAnnotation else {
            work.provenance = provenance
            workByCaptureID[route.captureID] = work
            return
        }
        guard saved.id == route.annotationID,
              saved.provenance.application == route.application
        else {
            workByCaptureID.removeValue(forKey: route.captureID)
            return
        }

        workByCaptureID.removeValue(forKey: route.captureID)
        lateUpdate(.updateAnnotationProvenance(
            sessionID: route.sessionID,
            annotationID: route.annotationID,
            expectedApplication: route.application,
            provenance: provenance
        ))
    }

    private func probeTaskFinished(captureID: UUID) {
        activeTaskCaptureIDs.remove(captureID)
        resumeIdleWaitersIfNeeded()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard pendingTaskCount == 0 else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
