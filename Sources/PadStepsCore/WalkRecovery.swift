import Foundation

public struct RecordedWalkTotals: Codable, Equatable, Sendable {
    public let steps: Int
    public let seconds: Int
    public let metres: Int
    public let end: Date
    public init(steps: Int, seconds: Int, metres: Int, end: Date) {
        self.steps = steps; self.seconds = seconds; self.metres = metres; self.end = end
    }
}

public enum WalkRecoveryError: LocalizedError {
    case unavailable, invalidTotals, unconfirmedFailure
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This walk changed. Reopen its recovery actions before continuing."
        case .invalidTotals: return "Use totals at least as large as the last readings, under 100,000 steps and 24 hours, with an end time between the last reading and now."
        case .unconfirmedFailure: return "Google has not confirmed that the original save failed. Check confirmation instead; a second workout was not created."
        }
    }
}

public extension AutomaticWalk {
    private var hasNeverUploaded: Bool {
        uploadAttempted != true && resourceName == nil && operationName == nil && correctionTarget == nil
    }
    var recordedTotals: RecordedWalkTotals { .init(steps: steps, seconds: seconds, metres: metres, end: exportEnd) }
    var canConfirmRecordedTotals: Bool {
        status == "review" && hasNeverUploaded && steps > 0 && seconds > 0 &&
        (["counterReset", "interruptedRecording"].contains(reviewKind ?? "") || issue == "Pad counters reset before a confirmed stop. This walk needs review.")
    }
    var canSaveWithoutHeartRate: Bool { status == "waitingHeartRate" && issue == nil && (hasNeverUploaded || gapExport != nil) }
    var canCheckUpload: Bool {
        status == "review" && issue == nil && creationRejected != true && !(reviewKind == "lateOverlap" && resourceName == nil) &&
        (reviewKind == "confirmation" || reviewKind == "coverageExport" || uploadAttempted == true || resourceName != nil || operationName != nil || correctionTarget != nil)
    }
    var canInspectGoogle: Bool { hasOverlapReview || canReviewCorrection || canCheckUpload || canRetryRejectedSave }
    var canRetryRejectedSave: Bool {
        status == "review" && issue == nil && creationRejected == true && uploadAttempted == true &&
        operationName != nil && resourceName == nil && correctionTarget == nil
    }
    var canKeepLocal: Bool { !["recording", "saved", "localOnly", "empty"].contains(status) }
    var canResumeChecks: Bool { status == "localOnly" && pausedFromStatus != nil }

    func confirmingTotals(_ totals: RecordedWalkTotals, at now: Date) throws -> AutomaticWalk {
        guard canConfirmRecordedTotals else { throw WalkRecoveryError.unavailable }
        guard totals.steps >= steps, totals.steps < 100_000, totals.seconds >= seconds, totals.seconds < 86400,
              totals.metres >= metres, totals.metres < 100_000,
              totals.end >= exportEnd, totals.end <= now,
              totals.steps <= totals.seconds * 5 + 12 else { throw WalkRecoveryError.invalidTotals }
        var result = self
        result.originalTotals = recordedTotals; result.totalsConfirmedAt = now
        result.baselineSteps = 0; result.baselineSeconds = 0; result.baselineMetres = 0
        result.stepWraps = 0; result.clockWraps = 0
        result.last.steps = totals.steps; result.last.seconds = totals.seconds; result.last.metres = totals.metres
        result.last.at = totals.end; result.last.moving = false; result.stop = totals.end
        result.issue = nil; result.reviewKind = nil; result.averageBPM = nil
        result.status = "waitingHeartRate"
        result.detail = "Recorded totals confirmed. Checking Fitbit heart rate before saving."
        return result
    }
    func omittingHeartRate() throws -> AutomaticWalk {
        guard canSaveWithoutHeartRate else { throw WalkRecoveryError.unavailable }
        var result = self; result.heartRateOmitted = true; result.averageBPM = nil; result.status = "ready"
        result.detail = "You chose to save the measured walk without a heart-rate summary."
        return result
    }
    func retryingRejectedSave(verifiedFailure: Bool) throws -> AutomaticWalk {
        guard canRetryRejectedSave else { throw WalkRecoveryError.unavailable }
        guard verifiedFailure else { throw WalkRecoveryError.unconfirmedFailure }
        var result = self
        result.uploadAttempted = false; result.operationName = nil; result.creationRejected = false; result.reviewKind = nil
        result.status = averageBPM != nil || heartRateOmitted == true ? "ready" : "waitingHeartRate"
        result.detail = "Google confirmed the prior save failed. Checking for existing workouts before retrying."
        return result
    }
    func keepingLocal() throws -> AutomaticWalk {
        guard canKeepLocal else { throw WalkRecoveryError.unavailable }
        var result = self; result.pausedFromStatus = status; result.status = "localOnly"
        return result
    }
    func resumingChecks() throws -> AutomaticWalk {
        guard canResumeChecks, let prior = pausedFromStatus else { throw WalkRecoveryError.unavailable }
        var result = self; result.status = prior; result.pausedFromStatus = nil
        return result
    }
}
