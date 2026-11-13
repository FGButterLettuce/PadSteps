import Foundation

/// Unknown is not zero. Workout summaries and reconciled interval steps are different measurements.
public struct StepComparison: Codable, Equatable, Sendable {
    public let pad: Int
    public let recorded: Int?
    public init(pad: Int, recorded: Int?) { self.pad = pad; self.recorded = recorded }
    public var missing: Int? { recorded.map { max(0, pad - $0) } }
    public var excess: Int? { recorded.map { max(0, $0 - pad) } }

    public static func rollupCount(_ response: [String: Any]) -> Int? {
        guard response["nextPageToken"] as? String ?? "" == "",
              let points = response["rollupDataPoints"] as? [[String: Any]], !points.isEmpty else { return nil }
        var total = 0
        for point in points {
            guard let steps = point["steps"] as? [String: Any],
                  let count = Int(String(describing: steps["countSum"] ?? "")), count >= 0,
                  count <= 100_000, total <= 100_000 - count else { return nil }
            total += count
        }
        return total
    }
}

public struct WorkoutConflict: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let start: Date
    public let end: Date
    public let type: String
    public let source: String
    public let steps: Int?
    public init?(point: [String: Any]) {
        guard let name = point["name"] as? String,
              let exercise = point["exercise"] as? [String: Any],
              let interval = exercise["interval"] as? [String: Any],
              let left = interval["startTime"] as? String, let right = interval["endTime"] as? String,
              let start = PadStepImport.date(left), let end = PadStepImport.date(right), end > start else { return nil }
        id = name; self.start = start; self.end = end
        type = exercise["exerciseType"] as? String ?? "Unknown exercise"
        let dataSource = point["dataSource"] as? [String: Any] ?? [:]
        let device = dataSource["device"] as? [String: Any] ?? [:]
        source = device["displayName"] as? String ?? dataSource["platform"] as? String ?? "Unknown source"
        let summary = exercise["metricsSummary"] as? [String: Any] ?? [:]
        let value = Int(String(describing: summary["steps"] ?? ""))
        steps = value.flatMap { $0 >= 0 && $0 <= 100_000 ? $0 : nil }
    }
    /// Automatic reconciliation is deliberately narrower than an explicit reviewed correction.
    public static func automaticCandidate(in points: [[String: Any]], for walk: AutomaticWalk, enabled: Bool) -> WorkoutConflict? {
        guard enabled, walk.canRecheckOverlap, points.count == 1, let point = points.first,
              let source = point["dataSource"] as? [String: Any], source["platform"] as? String == "FITBIT",
              let device = source["device"] as? [String: Any], device["displayName"] as? String == "Fitbit Air",
              let method = source["recordingMethod"] as? String,
              ["ACTIVELY_MEASURED", "PASSIVELY_MEASURED", "DERIVED"].contains(method),
              let conflict = WorkoutConflict(point: point), conflict.coversSameWalk(walk) else { return nil }
        let overlap = min(conflict.end, walk.exportEnd).timeIntervalSince(max(conflict.start, walk.start))
        guard overlap >= 0.9 * walk.exportEnd.timeIntervalSince(walk.start),
              overlap >= 0.9 * conflict.end.timeIntervalSince(conflict.start) else { return nil }
        return conflict
    }
    public func coversSameWalk(_ walk: AutomaticWalk) -> Bool {
        // Do not overwrite a partial, longer, or unrelated session with a whole-pad total.
        type == "WALKING" && abs(start.timeIntervalSince(walk.start)) <= 60 && abs(end.timeIntervalSince(walk.exportEnd)) <= 60
    }
}

public struct OverlapReport: Codable, Sendable {
    public let checkedAt: Date
    public let workouts: [WorkoutConflict]
    public let comparison: StepComparison
    public let intervalError: String?
    public init(checkedAt: Date, workouts: [WorkoutConflict], comparison: StepComparison, intervalError: String?) {
        self.checkedAt = checkedAt; self.workouts = workouts; self.comparison = comparison; self.intervalError = intervalError
    }
}
