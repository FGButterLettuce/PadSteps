import Foundation

/// A Google exercise written by our Mac recorder, never a native Fitbit walk.
public struct PadStepImport: Codable, Equatable, Sendable {
    public let resource: String
    public let userID: String
    public let start: Date
    public let end: Date
    public let steps: Int
    public var id: String { "google_\(userID)_\(resource.split(separator: "/").last!)" }
    public var syncIdentifier: String { "padsteps.\(id).steps" }

    public static func parse(_ data: Data, recorderClientID: String) throws -> PadStepImport? {
        guard !recorderClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let source = raw?["dataSource"] as? [String: Any]
        let app = source?["application"] as? [String: Any]
        let exercise = raw?["exercise"] as? [String: Any]
        guard source?["platform"] as? String == "GOOGLE_WEB_API",
              (app?["googleWebClientId"] as? String ?? app?["webClientId"] as? String) == recorderClientID,
              exercise?["exerciseType"] as? String == "WALKING" else { return nil }
        let point = try JSONDecoder().decode(Point.self, from: data)
        guard point.dataSource.platform == "GOOGLE_WEB_API",
              (point.dataSource.application.googleWebClientId ?? point.dataSource.application.webClientId) == recorderClientID,
              point.exercise.exerciseType == "WALKING" else { return nil }
        let parts = point.name.split(separator: "/").map(String.init)
        guard parts.count == 6, parts[0] == "users", parts[2] == "dataTypes", parts[3] == "exercise",
              parts[4] == "dataPoints", parts[1].allSatisfy(\.isNumber), parts[5].allSatisfy(\.isNumber),
              !parts[1].isEmpty, !parts[5].isEmpty,
              let start = date(point.exercise.interval.startTime), let end = date(point.exercise.interval.endTime),
              end > start, end.timeIntervalSince(start) < 24 * 3600,
              let steps = point.exercise.metricsSummary.steps.value, steps > 0, steps < 100_000 else {
            throw StepImportError.invalidRecord
        }
        return .init(resource: point.name, userID: parts[1], start: start, end: end, steps: steps)
    }

    public static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: value) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }

    /// Refuse uncertain records rather than silently restoring deleted or changed health data.
    public func decision(existing: [SavedStepRecord], previouslyConfirmed: Bool) -> StepImportDecision {
        if existing.count == 1, let found = existing.first,
           found.steps == steps, abs(found.start.timeIntervalSince(start)) < 0.002,
           abs(found.end.timeIntervalSince(end)) < 0.002 { return .adopt }
        if !existing.isEmpty || previouslyConfirmed { return .review }
        return .save
    }
}

public struct SavedStepRecord: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let steps: Int
    public init(start: Date, end: Date, steps: Int) { self.start = start; self.end = end; self.steps = steps }
}
public enum StepImportDecision: Sendable { case save, adopt, review }
public enum StepImportError: LocalizedError { case invalidRecord
    public var errorDescription: String? { "A PadSteps workout has invalid counters or dates. Nothing was imported." }
}

private struct Point: Decodable {
    let name: String
    let dataSource: Source
    let exercise: Exercise
    struct Source: Decodable {
        let platform: String?
        let application: Application
        struct Application: Decodable { let googleWebClientId: String?; let webClientId: String? }
    }
    struct Exercise: Decodable {
        let exerciseType: String
        let interval: Interval
        let metricsSummary: Metrics
        struct Interval: Decodable { let startTime: String; let endTime: String }
        struct Metrics: Decodable { let steps: FlexibleInt }
    }
}
private struct FlexibleInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = (try? c.decode(Int.self)) ?? (try? c.decode(String.self)).flatMap(Int.init)
    }
}
