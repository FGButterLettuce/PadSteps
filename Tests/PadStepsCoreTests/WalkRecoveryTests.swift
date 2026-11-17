import XCTest
@testable import PadStepsCore

final class WalkRecoveryTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 1_800_000_600)
    private func resetWalk() -> AutomaticWalk {
        var recorder = AutomaticRecorder()
        _ = recorder.observe(PadTelemetry(steps: 1, elapsedSeconds: 1, speedKmh: 3, distanceMetres: 0, motion: .running), at: end.addingTimeInterval(-599))
        _ = recorder.observe(PadTelemetry(steps: 900, elapsedSeconds: 600, speedKmh: 3, distanceMetres: 700, motion: .running), at: end)
        return recorder.observe(PadTelemetry(steps: 0, elapsedSeconds: 0, distanceMetres: 0, motion: .idle), at: end.addingTimeInterval(1))!
    }
    func testPowerOffCanRecoverLastReadingsWithoutLosingIdentityOrEvidence() throws {
        let original = resetWalk()
        XCTAssertTrue(original.canConfirmRecordedTotals)
        let recovered = try original.confirmingTotals(original.recordedTotals, at: end.addingTimeInterval(5))
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.steps, 900)
        XCTAssertEqual(recovered.start, original.start)
        XCTAssertEqual(recovered.originalTotals, original.recordedTotals)
        XCTAssertNil(recovered.issue)
        XCTAssertEqual(recovered.status, "waitingHeartRate")
        XCTAssertTrue(recovered.needsSync)
        XCTAssertFalse(recovered.canConfirmRecordedTotals)
    }
    func testConfirmationCannotResetAnUncertainOrSavedUpload() throws {
        for marker in ["attempt", "resource", "operation", "correction"] {
            var walk = resetWalk()
            switch marker {
            case "attempt": walk.uploadAttempted = true
            case "resource": walk.resourceName = "workout"
            case "operation": walk.operationName = "operation"
            default: walk.correctionTarget = "workout"
            }
            XCTAssertFalse(walk.canConfirmRecordedTotals)
            XCTAssertThrowsError(try walk.confirmingTotals(walk.recordedTotals, at: end.addingTimeInterval(5)))
        }
    }
    func testLegacyCounterResetAndArchiveRoundTripRemainRecoverable() throws {
        var walk = resetWalk(); walk.reviewKind = nil
        XCTAssertTrue(walk.canConfirmRecordedTotals)
        let local = try walk.keepingLocal()
        XCTAssertFalse(local.needsSync)
        let restored = try local.resumingChecks()
        XCTAssertTrue(restored.canConfirmRecordedTotals)
        XCTAssertEqual(restored.issue, walk.issue)
    }
    func testConfirmationRejectsSmallerCountersAndFutureEnd() {
        let walk = resetWalk()
        XCTAssertThrowsError(try walk.confirmingTotals(.init(steps: 899, seconds: 600, metres: 700, end: end), at: end))
        XCTAssertThrowsError(try walk.confirmingTotals(.init(steps: 900, seconds: 600, metres: 700, end: end.addingTimeInterval(60)), at: end))
    }
    func testUncertainReviewCanCheckConfirmationButCannotCreate() throws {
        var walk = resetWalk(); walk.issue = nil; walk.uploadAttempted = true
        walk.reviewKind = "confirmation"
        XCTAssertTrue(walk.canCheckUpload)
        XCTAssertTrue(walk.needsSync)
        XCTAssertNotEqual(UploadGuard.decide(attempted: true, matchingNames: [], hasOverlap: false, operationName: nil), .create)
        let restored = try walk.keepingLocal().resumingChecks()
        XCTAssertEqual(restored.uploadAttempted, true)
        XCTAssertTrue(restored.canCheckUpload)
    }
    func testOnlyVerifiedRejectedCreationCanBeRetried() throws {
        var walk = resetWalk(); walk.issue = nil; walk.uploadAttempted = true
        walk.operationName = "operations/rejected"; walk.creationRejected = true
        XCTAssertTrue(walk.canRetryRejectedSave)
        XCTAssertThrowsError(try walk.retryingRejectedSave(verifiedFailure: false))
        let retry = try walk.retryingRejectedSave(verifiedFailure: true)
        XCTAssertNotEqual(retry.uploadAttempted, true)
        XCTAssertNil(retry.operationName)
        walk.resourceName = "existing"
        XCTAssertFalse(walk.canRetryRejectedSave)
        XCTAssertThrowsError(try walk.retryingRejectedSave(verifiedFailure: true))
    }
    func testMultipleMatchesBeforeAnUploadCanBeInspectedAndRechecked() {
        var walk = resetWalk(); walk.issue = nil; walk.reviewKind = "confirmation"
        XCTAssertTrue(walk.canCheckUpload)
        XCTAssertTrue(walk.canInspectGoogle)
        XCTAssertTrue(walk.needsSync)
        XCTAssertNotEqual(UploadGuard.decide(attempted: false, matchingNames: ["first", "second"], hasOverlap: true, operationName: nil), .create)
    }
    func testUnrelatedWorkoutReviewCanBeRecheckedAfterItIsResolved() {
        var walk = resetWalk(); walk.issue = nil; walk.reviewKind = "coverageExport"
        XCTAssertTrue(walk.canInspectGoogle)
        XCTAssertTrue(walk.needsSync)
    }
    func testHeartRateOmissionRequiresAnExplicitDecisionBeforeAnyUpload() throws {
        var walk = resetWalk(); walk.issue = nil; walk.status = "waitingHeartRate"
        XCTAssertTrue(walk.canSaveWithoutHeartRate)
        let accepted = try walk.omittingHeartRate()
        XCTAssertEqual(accepted.status, "ready")
        XCTAssertEqual(accepted.heartRateOmitted, true)
        XCTAssertNil(accepted.averageBPM)
        walk.uploadAttempted = true
        XCTAssertThrowsError(try walk.omittingHeartRate())
    }
}
