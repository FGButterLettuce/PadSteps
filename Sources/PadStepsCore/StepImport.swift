import Foundation

/// A recorder exercise, or a native exercise carrying a verified paired-recorder correction.
public struct PadStepImport: Codable, Equatable, Sendable {
    public let resource: String
    public let userID: String
    public let start: Date
    public let end: Date
    public let steps: Int
    public var sessionID: UUID? = nil
    public var legacyResource: String? = nil
    public var id: String {
        if let legacyResource { return "google_\(userID)_\(legacyResource.split(separator: "/").last!)" }
        return sessionID.map { "pad_session_\(userID)_\($0.uuidString.lowercased())" } ?? "google_\(userID)_\(resource.split(separator: "/").last!)"
    }
    public var syncIdentifier: String { "padsteps.\(id).steps" }

    /// Carrier metadata can change without changing the measured pad session.
    /// Match the HealthKit identity, counters and interval with the same timestamp
    /// tolerance used when verifying existing HealthKit samples.
    public func hasSameMeasurements(as other: PadStepImport) -> Bool {
        id == other.id && userID == other.userID && steps == other.steps &&
        abs(start.timeIntervalSince(other.start)) < 0.002 &&
        abs(end.timeIntervalSince(other.end)) < 0.002
    }

    public static func parse(_ data: Data, recorderClientID: String, correctionPublicKey: Data? = nil) throws -> PadStepImport? {
        guard !recorderClientID.isEmpty else { return nil }
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let source = raw?["dataSource"] as? [String: Any]
        let app = source?["application"] as? [String: Any]
        let exercise = raw?["exercise"] as? [String: Any]
        if let publicKey = correctionPublicKey, let raw,
           let receipt = MeasuredWalkReceipt.verified(point: raw, publicKey: publicKey, clientID: recorderClientID) {
            let resource = receipt.resource == "unassigned" ? (raw["name"] as? String ?? "") : receipt.resource
            let parts = resource.split(separator: "/")
            guard parts.count == 6, parts[0] == "users", parts[2] == "dataTypes", parts[3] == "exercise", parts[4] == "dataPoints",
                  !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { throw StepImportError.invalidRecord }
            var imported = PadStepImport(resource: resource, userID: String(parts[1]), start: receipt.start, end: receipt.end, steps: receipt.steps)
            imported.sessionID = receipt.sessionID
            if let legacy = receipt.legacyResource {
                let identity = legacy.split(separator: "/")
                guard identity.count == 6, identity[0] == "users", identity[1] == parts[1], identity[2] == "dataTypes", identity[3] == "exercise", identity[4] == "dataPoints", !identity[5].isEmpty else { throw StepImportError.invalidRecord }
                imported.legacyResource = legacy
            }
            return imported
        }
        // An unverified session carrier must not fall through as a legacy full walk.
        if (exercise?["notes"] as? String ?? "").contains("PadSteps-measured-v1:") { return nil }
        if let publicKey = correctionPublicKey, let name = raw?["name"] as? String,
           let notes = exercise?["notes"] as? String,
           let proof = WorkoutCorrection.verified(note: notes, publicKey: publicKey, recorderClientID: recorderClientID, resource: name),
           let raw, proof.matches(raw) {
            let parts = name.split(separator: "/").map(String.init)
            guard parts.count == 6, parts[0] == "users", parts[2] == "dataTypes", parts[3] == "exercise",
                  parts[4] == "dataPoints", !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber),
                  !parts[5].isEmpty, parts[5].allSatisfy(\.isNumber) else { throw StepImportError.invalidRecord }
            return .init(resource: name, userID: parts[1], start: proof.start, end: proof.end, steps: proof.steps)
        }
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

    public static func parseAll(_ data: Data, recorderClientID: String, correctionPublicKey: Data? = nil) throws -> [PadStepImport] {
        guard let publicKey = correctionPublicKey,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exercise = raw["exercise"] as? [String: Any] else {
            return try parse(data, recorderClientID: recorderClientID, correctionPublicKey: correctionPublicKey).map { [$0] } ?? []
        }
        let receipts = MeasuredWalkReceipt.verifiedAll(point: raw, publicKey: publicKey, clientID: recorderClientID)
        if receipts.isEmpty { return try parse(data, recorderClientID: recorderClientID, correctionPublicKey: correctionPublicKey).map { [$0] } ?? [] }
        let notes = (exercise["notes"] as? String ?? "").split(separator: "\n").filter { $0.hasPrefix("PadSteps-measured-v1:") }
        var imports: [PadStepImport] = []
        for line in notes {
            var candidate = raw; var fields = exercise; fields["notes"] = String(line); candidate["exercise"] = fields
            if let value = try parse(JSONSerialization.data(withJSONObject: candidate), recorderClientID: recorderClientID, correctionPublicKey: publicKey), receipts.contains(where: { $0.sessionID == value.sessionID }) { imports.append(value) }
        }
        return imports
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
