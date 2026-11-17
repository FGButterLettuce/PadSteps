import Foundation

public enum StepExportOutcome: Sendable {
    case complete(StepExportLedger, wrote: Bool)
    case review(String)
}
public enum StepExportTransactionError: LocalizedError {
    case unconfirmed
    public var errorDescription: String? { "The step update was submitted but readback is not confirmed. Its saved intent is retained; another step identity will not be created." }
}

/// The phone and fault-injection tests share this transaction, including the
/// ordering of durable intent, provider write, acknowledgement and readback.
@MainActor
public enum StepExportTransaction {
    public static func perform(walk: PadStepImport, googleSteps: Int, prior: StepExportLedger?,
                               pending: StepExportIntent?, legacyConfirmed: Bool,
                               read: @MainActor () async throws -> [VersionedStepRecord],
                               write: @MainActor (Int, Int) async throws -> Void,
                               remove: @MainActor () async throws -> Void,
                               persistIntent: @MainActor (StepExportIntent) throws -> Void) async throws -> StepExportOutcome {
        let existing = try await read()
        let decision = StepTopUp.plan(padSteps: walk.steps, googleSteps: googleSteps, start: walk.start, end: walk.end,
                                      existing: existing, prior: prior, pending: pending, legacyConfirmed: legacyConfirmed)
        switch decision {
        case .review(let reason): return .review(reason)
        case .adopt(let steps, let version): return .complete(.init(steps: steps, version: version), wrote: false)
        case .covered(let version): return .complete(.init(steps: 0, version: version), wrote: false)
        case .save(let steps, let version):
            let previous = existing.first.map { StepExportLedger(steps: $0.steps, version: $0.version) } ?? prior
            var intent: StepExportIntent = pending ?? StepExportIntent(previous: previous, steps: steps, version: version)
            try persistIntent(intent)
            try Task.checkCancellation()
            try await write(steps, version)
            intent.writeAcknowledged = true; try persistIntent(intent)
            let found = try await read()
            let verified = StepTopUp.plan(padSteps: walk.steps, googleSteps: googleSteps, start: walk.start, end: walk.end,
                                         existing: found, prior: prior, pending: intent, legacyConfirmed: true)
            guard case .adopt(let actual, let actualVersion) = verified, actual == steps, actualVersion == version else { throw StepExportTransactionError.unconfirmed }
            return .complete(.init(steps: steps, version: version), wrote: true)
        case .remove(let version):
            guard existing.count == 1, let record = existing.first else { throw StepExportTransactionError.unconfirmed }
            var intent: StepExportIntent = pending ?? StepExportIntent(previous: StepExportLedger(steps: record.steps, version: record.version), steps: 0, version: version)
            try persistIntent(intent)
            try Task.checkCancellation()
            try await remove()
            intent.writeAcknowledged = true; try persistIntent(intent)
            guard try await read().isEmpty else { throw StepExportTransactionError.unconfirmed }
            return .complete(.init(steps: 0, version: version), wrote: true)
        }
    }
}
