import Foundation

public struct PadObservation: Codable, Equatable, Sendable {
    public var at: Date
    public var steps: Int
    public var seconds: Int
    public var metres: Int
    public var moving: Bool
    public init(_ value: PadTelemetry, at: Date) {
        self.at = at; steps = value.steps; seconds = value.elapsedSeconds
        metres = value.distanceMetres; moving = value.motion == .running && value.speedKmh > 0
    }
}

public struct AutomaticWalk: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var observedStart: Date
    public var stop: Date?
    public var baselineSteps: Int
    public var baselineSeconds: Int
    public var baselineMetres: Int
    public var last: PadObservation
    public var stepWraps = 0
    public var clockWraps = 0
    public var issue: String?
    public var status = "recording"
    public var resourceName: String?
    public var operationName: String?
    public var uploadAttempted: Bool?
    public var reviewKind: String?
    public var correctionTarget: String?
    public var averageBPM: Int?
    public var detail = ""
    public var steps: Int { max(0, last.steps + stepWraps * 65536 - baselineSteps) }
    public var seconds: Int { max(0, last.seconds + clockWraps * 65536 - baselineSeconds) }
    public var metres: Int { max(0, last.metres - baselineMetres) }
    // The pad clock determines workout duration; the observed stop anchors its interval.
    public var start: Date { (stop ?? last.at).addingTimeInterval(-Double(seconds)) }
    public var exportEnd: Date { stop ?? last.at }
    /// Only a pre-upload overlap is retryable. Counter resets and uncertain writes stay protected.
    public var canRecheckOverlap: Bool {
        status == "review" && issue == nil && uploadAttempted != true && resourceName == nil && operationName == nil && correctionTarget == nil &&
        (reviewKind == "overlap" || (reviewKind == nil && detail == UploadGuard.overlapMessage))
    }
    public var canRecheckSavedOverlap: Bool { status == "review" && reviewKind == "lateOverlap" && resourceName != nil && issue == nil }
    public var canReviewCorrection: Bool { status == "verifying" && correctionTarget != nil && issue == nil }
    public var hasOverlapReview: Bool { canRecheckOverlap || canRecheckSavedOverlap }
    public var needsSync: Bool { ["waitingHeartRate", "ready", "attempted", "verifying"].contains(status) || hasOverlapReview }
}

/// One pad, any number of walks. A disconnect is never treated as a stop.
public struct AutomaticRecorder: Codable, Sendable {
    public private(set) var active: AutomaticWalk?
    public private(set) var lastIdle: PadObservation?
    private var stopped: [PadObservation] = []
    public init() {}

    public mutating func disconnected() { stopped = [] }

    public mutating func observe(_ value: PadTelemetry, at now: Date) -> AutomaticWalk? {
        guard [.running, .idle, .paused, .countdown, .stopping].contains(value.motion) else { return nil }
        let sample = PadObservation(value, at: now)
        if active == nil {
            guard sample.moving else { lastIdle = sample; return nil }
            let origin = lastIdle.flatMap { idle -> PadObservation? in
                // A smaller clock/counter marks a new pad session.
                idle.seconds <= sample.seconds && idle.steps <= sample.steps ? idle : nil
            }
            active = AutomaticWalk(observedStart: now, baselineSteps: origin?.steps ?? 0,
                                   baselineSeconds: origin?.seconds ?? 0,
                                   baselineMetres: origin?.metres ?? 0, last: sample)
            stopped = []
            return nil
        }
        guard var walk = active, now > walk.last.at else { return nil }
        let stepBack = sample.steps < walk.last.steps
        let clockBack = sample.seconds < walk.last.seconds
        let stepWrap = stepBack && walk.last.steps > 65000 && sample.steps < 1000
        let clockWrap = clockBack && walk.last.seconds > 65000 && sample.seconds < 1000
        if (stepBack && !stepWrap) || (clockBack && !clockWrap) || sample.metres < walk.last.metres {
            walk.stop = walk.last.at; walk.status = "review"
            walk.issue = "Pad counters reset before a confirmed stop. This walk needs review."
            active = nil; lastIdle = nil; stopped = []
            return walk
        }
        if stepWrap { walk.stepWraps += 1 }
        if clockWrap { walk.clockWraps += 1 }
        let delta = sample.steps + walk.stepWraps * 65536 - walk.last.steps - (walk.stepWraps - (stepWrap ? 1 : 0)) * 65536
        guard Double(delta) <= max(12, now.timeIntervalSince(walk.last.at) * 5) else { return nil }
        walk.last = sample; active = walk
        if sample.moving || value.motion == .stopping || value.motion == .countdown {
            stopped = []; return nil
        }
        if let first = stopped.first, (first.steps != sample.steps || first.seconds != sample.seconds) { stopped = [] }
        stopped.append(sample)
        guard stopped.count >= 5, let first = stopped.first,
              now.timeIntervalSince(first.at) >= 4 else { return nil }
        walk.last = first; walk.stop = first.at
        walk.status = walk.steps > 0 && walk.seconds > 0 ? "waitingHeartRate" : "empty"
        walk.detail = "Waiting for Fitbit Air to sync heart rate."
        active = nil; lastIdle = sample; stopped = []
        return walk
    }
}

public struct HeartObservation: Codable, Equatable, Sendable {
    public var at: Date
    public var bpm: Int
    public init(at: Date, bpm: Int) { self.at = at; self.bpm = bpm }
}

public enum HeartCoverageError: Error, LocalizedError {
    case waitingForSync, internalGap
    public var errorDescription: String? {
        switch self {
        case .waitingForSync: return "Waiting for heart rate at the start or end of this walk. Open Google Health on your iPhone to sync Fitbit Air."
        case .internalGap: return "Fitbit heart rate has substantial gaps. Your walk is stored safely; sync Fitbit Air in Google Health and retry."
        }
    }
}

public struct HeartSummary: Sendable {
    public let average: Int
    public let samples: Int
    public let maxGap: TimeInterval
    public let uncoveredSeconds: TimeInterval
    public static func calculate(_ observations: [HeartObservation], start: Date, end: Date) throws -> HeartSummary {
        let points = observations.filter { $0.at >= start && $0.at <= end && (25...240).contains($0.bpm) }
            .sorted { $0.at < $1.at }
        guard end > start, points.count >= 2, let first = points.first, let last = points.last,
              first.at.timeIntervalSince(start) <= 5, end.timeIntervalSince(last.at) <= 5 else {
            throw HeartCoverageError.waitingForSync
        }
        let gaps = zip(points, points.dropFirst()).map { $1.at.timeIntervalSince($0.at) }
        let maximum = gaps.max() ?? 0
        let duration = end.timeIntervalSince(start)
        // A brief sensor dropout must not leave a well-covered walk queued forever.
        // Treat gaps over 15 seconds as unobserved, rather than filling them in.
        let missing = gaps.filter { $0 > 15 }.reduce(0, +)
        guard maximum <= 30, missing <= duration * 0.05 else { throw HeartCoverageError.internalGap }
        let weights = points.indices.map { index -> TimeInterval in
            let left = index == 0 ? first.at.timeIntervalSince(start) : (gaps[index - 1] <= 15 ? gaps[index - 1] / 2 : 0)
            let right = index == points.count - 1 ? end.timeIntervalSince(last.at) : (gaps[index] <= 15 ? gaps[index] / 2 : 0)
            return left + right
        }
        let observedDuration = weights.reduce(0, +)
        guard observedDuration > 0 else { throw HeartCoverageError.internalGap }
        let total = zip(points, weights).reduce(0.0) { $0 + Double($1.0.bpm) * $1.1 }
        return HeartSummary(average: Int((total / observedDuration).rounded()), samples: points.count,
                            maxGap: maximum, uncoveredSeconds: missing)
    }
}
