import Foundation
import CryptoKit

/// A signed measurement carried in an existing exercise's notes. The source stays Google's;
/// only the paired recorder can attest that its corrected counters came from the pad.
public struct WorkoutCorrection: Codable, Sendable {
    public let version: Int
    public let recorderClientID: String
    public let resource: String
    public let start: Date
    public let end: Date
    public let steps: Int
    public let metres: Int
    public let seconds: Int
    public let averageBPM: Int
    public init(walk: AutomaticWalk, resource: String, recorderClientID: String) {
        version = 1; self.recorderClientID = recorderClientID; self.resource = resource
        start = walk.start; end = walk.exportEnd; steps = walk.steps; metres = walk.metres
        seconds = walk.seconds; averageBPM = walk.averageBPM ?? 0
    }
    public func signedNote(privateKey: Data) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let signature = try key.signature(for: data)
        return "PadSteps-v1:" + data.base64EncodedString() + "." + signature.base64EncodedString()
    }
    public static func verified(note: String, publicKey: Data, recorderClientID: String, resource: String) -> WorkoutCorrection? {
        let lines = note.split(separator: "\n").filter { $0.hasPrefix("PadSteps-v1:") }
        guard lines.count == 1, let line = lines.first else { return nil }
        let parts = line.dropFirst("PadSteps-v1:".count).split(separator: ".")
        guard parts.count == 2, let data = Data(base64Encoded: String(parts[0])), data.count < 4096,
              let signature = Data(base64Encoded: String(parts[1])),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: data),
              let proof = try? JSONDecoder().decode(Self.self, from: data),
              proof.version == 1, proof.recorderClientID == recorderClientID, proof.resource == resource,
              proof.steps > 0, proof.steps < 100_000, proof.metres >= 0,
              proof.seconds > 0, proof.seconds < 86400, (25...240).contains(proof.averageBPM),
              abs(proof.end.timeIntervalSince(proof.start) - Double(proof.seconds)) < 0.002 else { return nil }
        return proof
    }
    public func matches(_ point: [String: Any]) -> Bool {
        guard point["name"] as? String == resource,
              let exercise = point["exercise"] as? [String: Any], exercise["exerciseType"] as? String == "WALKING",
              let interval = exercise["interval"] as? [String: Any],
              let left = interval["startTime"] as? String, let right = interval["endTime"] as? String,
              let start = PadStepImport.date(left), let end = PadStepImport.date(right),
              abs(start.timeIntervalSince(self.start)) < 0.002, abs(end.timeIntervalSince(self.end)) < 0.002,
              let metrics = exercise["metricsSummary"] as? [String: Any],
              Int(String(describing: metrics["steps"] ?? "")) == steps,
              Int(String(describing: metrics["distanceMillimeters"] ?? "")) == metres * 1000,
              Int(String(describing: metrics["averageHeartRateBeatsPerMinute"] ?? "")) == averageBPM,
              let duration = exercise["activeDuration"] as? String,
              duration.hasSuffix("s"), Double(duration.dropLast()) == Double(seconds) else { return false }
        return true
    }
}
