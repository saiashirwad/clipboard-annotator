import SendpointDomain
import Foundation
import XCTest
@testable import Sendpoint

@MainActor
final class CaptureSaveLifecycleTests: XCTestCase {
    func testFailureFreezesDraftAndRetryUsesTheExactQueuedCommit() throws {
        let model = makeModel()
        model.note = "Keep this draft"
        let annotation = try makeAnnotation(model)
        let request = try XCTUnwrap(model.beginCommit(
            annotation: annotation,
            destinationSessionID: model.target.sessionID
        ))

        model.note = "A late edit"
        XCTAssertEqual(model.note, "Keep this draft")
        XCTAssertTrue(model.isNoteFrozen)
        XCTAssertNil(model.beginCommit(
            annotation: annotation,
            destinationSessionID: model.target.sessionID
        ))

        XCTAssertEqual(
            model.receive(
                .commitFailed("disk full"),
                for: request.identity,
                destinationStillExists: true
            ),
            .none
        )
        XCTAssertEqual(
            model.savePhase,
            .retryableCommitFailure(
                identity: request.identity,
                message: "Couldn’t save the annotation: disk full"
            )
        )
        XCTAssertEqual(model.note, "Keep this draft")

        XCTAssertTrue(model.retryPendingCommit())
        XCTAssertEqual(model.savePhase, .pendingCommit(request.identity))
        XCTAssertEqual(
            model.receive(
                .committed,
                for: request.identity,
                destinationStillExists: true
            ),
            .dismiss
        )
        XCTAssertEqual(model.savePhase, .committed)
        XCTAssertEqual(model.dismiss(), .none)
        XCTAssertEqual(model.savePhase, .dismissed)
    }

    func testGlobalRetryOutcomeCanFinishTheSameQueuedCommitWhileFailureIsVisible() throws {
        let model = makeModel()
        model.note = "Draft"
        let request = try XCTUnwrap(model.beginCommit(
            annotation: makeAnnotation(model),
            destinationSessionID: model.target.sessionID
        ))
        _ = model.receive(
            .commitFailed("offline"),
            for: request.identity,
            destinationStillExists: true
        )

        XCTAssertEqual(
            model.receive(
                .committed,
                for: request.identity,
                destinationStillExists: true
            ),
            .dismiss
        )
        XCTAssertEqual(model.savePhase, .committed)
    }

    func testMissingOriginalTargetRetainsFrozenAnnotationForExplicitRetarget() throws {
        let model = makeModel()
        model.note = "Draft"
        var annotation = try makeAnnotation(model)
        annotation.provenance.windowTitle = "Best provenance available before save"
        let original = try XCTUnwrap(model.beginCommit(
            annotation: annotation,
            destinationSessionID: model.target.sessionID
        ))

        XCTAssertEqual(
            model.receive(
                .rejected("The target session no longer exists."),
                for: original.identity,
                destinationStillExists: false
            ),
            .none
        )
        XCTAssertEqual(
            model.savePhase,
            .targetUnavailable(message: "The original session was deleted.")
        )
        XCTAssertEqual(model.note, "Draft")
        XCTAssertEqual(model.annotation, annotation)

        let currentSessionID = UUID()
        let retargeted = try XCTUnwrap(
            model.beginRetarget(destinationSessionID: currentSessionID)
        )
        XCTAssertEqual(retargeted.annotation, annotation)
        XCTAssertEqual(retargeted.annotation.id, original.annotation.id)
        XCTAssertEqual(retargeted.identity.captureID, original.identity.captureID)
        XCTAssertEqual(retargeted.identity.annotationID, original.identity.annotationID)
        XCTAssertEqual(retargeted.identity.destinationSessionID, currentSessionID)

        XCTAssertEqual(
            model.receive(
                .rejected("The target session no longer exists."),
                for: retargeted.identity,
                destinationStillExists: false
            ),
            .none
        )
        XCTAssertEqual(
            model.savePhase,
            .targetUnavailable(message: "The selected session was deleted.")
        )
    }

    func testRejectedExistingDestinationCannotRetarget() throws {
        let model = makeModel()
        model.note = "Draft"
        let request = try XCTUnwrap(model.beginCommit(
            annotation: makeAnnotation(model),
            destinationSessionID: model.target.sessionID
        ))

        XCTAssertEqual(
            model.receive(
                .rejected("The annotation already exists."),
                for: request.identity,
                destinationStillExists: true
            ),
            .none
        )
        XCTAssertEqual(
            model.savePhase,
            .terminalSaveFailure(
                message: "The annotation could not be saved: The annotation already exists."
            )
        )
        XCTAssertNil(model.beginRetarget(destinationSessionID: UUID()))
        XCTAssertEqual(model.note, "Draft")
        XCTAssertEqual(model.discard(), .abandonProvenance)
    }

    func testStaleCaptureAnnotationAndDestinationOutcomesAreIgnored() throws {
        for changedField in 0..<3 {
            let model = makeModel()
            model.note = "Draft"
            let request = try XCTUnwrap(model.beginCommit(
                annotation: makeAnnotation(model),
                destinationSessionID: model.target.sessionID
            ))
            let stale = CaptureSaveIdentity(
                captureID: changedField == 0 ? UUID() : request.identity.captureID,
                annotationID: changedField == 1 ? UUID() : request.identity.annotationID,
                destinationSessionID: changedField == 2
                    ? UUID()
                    : request.identity.destinationSessionID
            )

            XCTAssertEqual(
                model.receive(
                    .committed,
                    for: stale,
                    destinationStillExists: true
                ),
                .none
            )
            XCTAssertEqual(model.savePhase, .pendingCommit(request.identity))
        }
    }

    func testNoOpAndCancellationNeverClaimSuccess() throws {
        for outcome in [
            AnnotationStoreMutationOutcome.noOp,
            AnnotationStoreMutationOutcome.cancelled,
        ] {
            let model = makeModel()
            model.note = "Draft"
            let request = try XCTUnwrap(model.beginCommit(
                annotation: makeAnnotation(model),
                destinationSessionID: model.target.sessionID
            ))

            XCTAssertEqual(
                model.receive(
                    outcome,
                    for: request.identity,
                    destinationStillExists: true
                ),
                .none
            )
            XCTAssertNotEqual(model.savePhase, .committed)
            guard case .terminalSaveFailure = model.savePhase else {
                return XCTFail("Expected a terminal not-saved state")
            }
            XCTAssertNil(model.beginRetarget(destinationSessionID: UUID()))
            XCTAssertEqual(model.note, "Draft")
        }
    }

    func testTerminalStoreOutcomesShareOneProvenanceRoutingRule() {
        XCTAssertFalse(CaptureSaveOutcomeRouting.abandonsProvenance(after: .committed))
        XCTAssertFalse(
            CaptureSaveOutcomeRouting.abandonsProvenance(after: .commitFailed("offline"))
        )
        XCTAssertTrue(CaptureSaveOutcomeRouting.abandonsProvenance(after: .noOp))
        XCTAssertTrue(
            CaptureSaveOutcomeRouting.abandonsProvenance(after: .rejected("missing"))
        )
        XCTAssertTrue(CaptureSaveOutcomeRouting.abandonsProvenance(after: .cancelled))
    }

    func testDismissAbandonsOnlyEditingOrRejectedWorkAndRejectsLateOutcome() throws {
        let editing = makeModel()
        XCTAssertEqual(editing.dismiss(), .abandonProvenance)
        XCTAssertEqual(editing.savePhase, .dismissed)
        XCTAssertEqual(editing.dismiss(), .none)
        XCTAssertEqual(editing.savePhase, .dismissed)

        let failed = makeModel()
        failed.note = "Draft"
        let request = try XCTUnwrap(failed.beginCommit(
            annotation: makeAnnotation(failed),
            destinationSessionID: failed.target.sessionID
        ))
        _ = failed.receive(
            .commitFailed("offline"),
            for: request.identity,
            destinationStillExists: true
        )
        XCTAssertEqual(failed.dismiss(), .none)
        XCTAssertEqual(
            failed.receive(
                .committed,
                for: request.identity,
                destinationStillExists: true
            ),
            .none
        )
        XCTAssertEqual(failed.savePhase, .dismissed)

        let rejected = makeModel()
        rejected.note = "Draft"
        let rejectedRequest = try XCTUnwrap(rejected.beginCommit(
            annotation: makeAnnotation(rejected),
            destinationSessionID: rejected.target.sessionID
        ))
        _ = rejected.receive(
            .rejected("missing"),
            for: rejectedRequest.identity,
            destinationStillExists: false
        )
        XCTAssertEqual(rejected.discard(), .abandonProvenance)
        XCTAssertEqual(rejected.savePhase, .dismissed)
    }

    private func makeModel() -> CaptureModel {
        let target = AnnotationCaptureContext(
            sessionID: UUID(),
            captureID: UUID(),
            annotationID: UUID(),
            createdAt: Date(timeIntervalSince1970: 123)
        ).target(captured: CapturedSelection(
            text: "Selection",
            appName: "Reader",
            appBundleID: "com.example.reader",
            processIdentifier: 42,
            screenRect: nil
        ))
        return CaptureModel(target: target)
    }

    private func makeAnnotation(_ model: CaptureModel) throws -> Annotation {
        try XCTUnwrap(
            CaptureAnnotationPolicy.annotation(for: model.target, note: model.note)
        )
    }
}
