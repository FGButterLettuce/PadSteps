import Foundation

public struct VersionedStepRecord: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let steps: Int
    public let version: Int
    public init(start: Date, end: Date, steps: Int, version: Int) {
        self.start = start; self.end = end; self.steps = steps; self.version = version
    }
}
public struct StepExportLedger: Codable, Equatable, Sendable {
    public let steps: Int
    public let version: Int
    public init(steps: Int, version: Int) { self.steps = steps; self.version = version }
}
public struct StepExportIntent: Codable, Equatable, Sendable {
    public let previous: StepExportLedger?
    public let steps: Int
    public let version: Int
    public var writeAcknowledged: Bool
    public init(previous: StepExportLedger?, steps: Int, version: Int, writeAcknowledged: Bool = false) {
        self.previous = previous; self.steps = steps; self.version = version; self.writeAcknowledged = writeAcknowledged
    }
}
public enum StepTopUpDecision: Equatable, Sendable {
    case save(steps: Int, version: Int)
    case adopt(steps: Int, version: Int)
    case remove(version: Int)
    case covered(version: Int)
    case review(String)
}

/// One Google walk, one HealthKit identity. Absolute revisions, never incremental extra samples.
public enum StepTopUp {
    public static func plan(padSteps: Int, googleSteps: Int?, start: Date, end: Date,
                            existing: [VersionedStepRecord], prior: StepExportLedger?,
                            pending: StepExportIntent?, legacyConfirmed: Bool) -> StepTopUpDecision {
        guard padSteps > 0, padSteps < 100_000, end > start, end.timeIntervalSince(start) < 86400 else {
            return .review("The pad walk has invalid counters or dates.")
        }
        guard existing.count <= 1, existing.allSatisfy({
            abs($0.start.timeIntervalSince(start)) < 0.002 && abs($0.end.timeIntervalSince(end)) < 0.002 &&
            $0.steps >= 0 && $0.steps < 100_000 && $0.version > 0 && $0.version < 1_000_000
        }) else { return .review("Duplicate or changed step records were found. No automatic replacement.") }
        if let prior {
            guard prior.steps >= 0, prior.steps < 100_000, prior.version >= 0, prior.version < 999_999,
                  prior.steps == 0 || prior.version > 0 else { return .review("The saved export journal has invalid counters or versions.") }
        }
        let found = existing.first
        if let pending {
            guard pending.steps >= 0, pending.steps <= padSteps, pending.version > 0,
                  (pending.version < 1_000_000), (pending.version > (pending.previous?.version ?? 0)) else {
                return .review("The saved step update is invalid. No automatic write.")
            }
            if pending.steps > 0, let found, found.steps == pending.steps, found.version == pending.version {
                return .adopt(steps: found.steps, version: found.version)
            }
            if pending.steps == 0, found == nil, pending.writeAcknowledged {
                return .covered(version: pending.version)
            }
            if let found, let old = pending.previous, found.steps == old.steps, found.version == old.version {
                return pending.steps == 0 ? .remove(version: pending.version) : .save(steps: pending.steps, version: pending.version)
            }
            return .review("An interrupted step update could not be verified. Existing data is preserved.")
        }
        guard let googleSteps, googleSteps >= 0, googleSteps < 100_000 else {
            return .review("Google's step count is not confirmed yet. No guessed top-up was saved.")
        }
        let target = max(0, padSteps - googleSteps)
        if let found {
            if found.steps == target, found.version >= (prior?.version ?? 0) {
                return .adopt(steps: target, version: found.version)
            }
            let known = prior.map { $0.steps == found.steps && $0.version == found.version } ??
                (legacyConfirmed && found.steps == padSteps && found.version == 1)
            guard known else { return .review("Existing steps differ from the saved export journal. No automatic overwrite.") }
            return target == 0 ? .remove(version: found.version + 1) : .save(steps: target, version: found.version + 1)
        }
        guard prior?.steps ?? 0 == 0, !(prior == nil && legacyConfirmed) else {
            return .review("Previously saved steps are missing or unreadable. They were not recreated.")
        }
        return target == 0 ? .covered(version: prior?.version ?? 0) : .save(steps: target, version: (prior?.version ?? 0) + 1)
    }
}
