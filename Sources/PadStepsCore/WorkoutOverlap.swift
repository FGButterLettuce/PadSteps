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
    public let platform: String?
    public let applicationClientID: String?
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
        platform = dataSource["platform"] as? String
        let application = dataSource["application"] as? [String: Any]
        applicationClientID = application?["googleWebClientId"] as? String ?? application?["webClientId"] as? String
        let device = dataSource["device"] as? [String: Any] ?? [:]
        source = device["displayName"] as? String ?? dataSource["platform"] as? String ?? "Unknown source"
        let summary = exercise["metricsSummary"] as? [String: Any] ?? [:]
        let value = Int(String(describing: summary["steps"] ?? ""))
        steps = value.flatMap { $0 >= 0 && $0 <= 100_000 ? $0 : nil }
    }
    public func isOwned(by clientID: String) -> Bool {
        platform == "GOOGLE_WEB_API" && applicationClientID == clientID && !clientID.isEmpty
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
