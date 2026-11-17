import Foundation

public struct WorkoutTimeRange: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public var seconds: TimeInterval { end.timeIntervalSince(start) }
}

public enum WorkoutCoverage {
    /// Subtract the union of existing workout intervals. Five-second clock slivers
    /// are tolerated only at covered boundaries; a wholly undetected walk is kept.
    public static func missing(in walk: WorkoutTimeRange, covered: [WorkoutTimeRange]) -> [WorkoutTimeRange] {
        guard walk.end > walk.start else { return [] }
        let intervals = covered.compactMap { value -> WorkoutTimeRange? in
            let start = max(walk.start, value.start), end = min(walk.end, value.end)
            return end > start ? .init(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        guard !intervals.isEmpty else { return [walk] }
        var cursor = walk.start
        var missing: [WorkoutTimeRange] = []
        for interval in intervals {
            if interval.start.timeIntervalSince(cursor) > 5 { missing.append(.init(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if walk.end.timeIntervalSince(cursor) > 5 { missing.append(.init(start: cursor, end: walk.end)) }
        return missing
    }
}

public struct WorkoutGapExport: Codable, Sendable {
    public var gaps: [WorkoutTimeRange]
    public var resources: [String]
    public var retiredResources: [String]
    public var checkedAt: Date?
    public var carrier: String?
    public var operations: [String: String]?
    public var confirmedResources: [String]?
    public var legacyResource: String?
    public var creationStarted: [String: Bool]?
    public var rejectedCreations: [String]?
    public var pendingRanges: [String: WorkoutTimeRange]?
    public var retryAfter: [String: Date]?
    public func retryingDueCreations(at now: Date) -> Self {
        let due = (rejectedCreations ?? []).filter { retryAfter?[$0].map { $0 <= now } == true }
        var result = self
        for name in due { result.creationStarted?[name] = false; result.operations?[name] = nil; result.retryAfter?[name] = nil }
        result.rejectedCreations = (rejectedCreations ?? []).filter { !due.contains($0) }
        return result
    }
    public func retryingRejectedCreations() -> Self {
        var result = self
        for name in rejectedCreations ?? [] {
            result.creationStarted?[name] = false; result.operations?[name] = nil; result.retryAfter?[name] = nil
        }
        result.rejectedCreations = []
        return result
    }
    public init(gaps: [WorkoutTimeRange], resources: [String] = [], retiredResources: [String] = []) {
        self.gaps = gaps; self.resources = resources; self.retiredResources = retiredResources
    }
}
