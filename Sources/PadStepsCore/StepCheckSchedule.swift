import Foundation

public struct StepCheckCandidate: Sendable {
    public let walk: PadStepImport
    public let state: String?
    public let checkedAt: Date?
    public let attemptedAt: Date?
    public let hasPendingWrite: Bool
    public let measurementsChanged: Bool
    public init(walk: PadStepImport, state: String? = nil, checkedAt: Date? = nil, attemptedAt: Date? = nil,
                hasPendingWrite: Bool = false, measurementsChanged: Bool = false) {
        self.walk = walk; self.state = state; self.checkedAt = checkedAt; self.attemptedAt = attemptedAt
        self.hasPendingWrite = hasPendingWrite; self.measurementsChanged = measurementsChanged
    }
    fileprivate var rank: Int {
        if state == nil { return 0 }
        if hasPendingWrite || ["attempted", "ready"].contains(state ?? "") { return 1 }
        if measurementsChanged || !["confirmed", "covered"].contains(state ?? "") { return 2 }
        return 3
    }
}

public enum StepCheckSchedule {
    public static func due(_ candidates: [StepCheckCandidate], now: Date, force: Bool = false) -> [PadStepImport] {
        candidates.filter { value in
            if value.rank == 3 && now.timeIntervalSince(value.walk.end) > 3 * 86400 { return false }
            if force || value.state == nil { return true }
            if let attempted = value.attemptedAt, now.timeIntervalSince(attempted) < 30 { return false }
            if value.rank < 3 { return true }
            let interval: TimeInterval = now.timeIntervalSince(value.walk.end) < 1800 ? 60 : 900
            return value.checkedAt.map { now.timeIntervalSince($0) >= interval } ?? true
        }.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            if left.rank == 3, left.checkedAt != right.checkedAt { return (left.checkedAt ?? .distantPast) < (right.checkedAt ?? .distantPast) }
            return left.walk.end > right.walk.end
        }.map(\.walk)
    }
}

public enum WorkoutAuditSchedule {
    public static func due(_ walks: [AutomaticWalk], now: Date, limit: Int = 20) -> [AutomaticWalk] {
        walks.filter { $0.status == "saved" && $0.exportEnd > now.addingTimeInterval(-3 * 86400) }
            .sorted { left, right in
                let l = left.lastGoogleAudit ?? left.gapExport?.checkedAt ?? .distantPast
                let r = right.lastGoogleAudit ?? right.gapExport?.checkedAt ?? .distantPast
                return l == r ? left.exportEnd > right.exportEnd : l < r
            }.prefix(max(0,limit)).map { $0 }
    }
}
