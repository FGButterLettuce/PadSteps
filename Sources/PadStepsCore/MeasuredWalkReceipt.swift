import Foundation
import CryptoKit

/// Carries full-session pad measurements independently of the gap workout's
/// duration and metrics. The phone uses one session identity across carriers.
public struct MeasuredWalkReceipt: Codable, Sendable {
    public let version: Int
    public let sessionID: UUID
    public let recorderClientID: String
    public let resource: String
    public let start: Date
    public let end: Date
    public let steps: Int
    public let carrierStart: Date
    public let carrierEnd: Date
    public let gap: Bool
    public let legacyResource: String?
    public init(walk: AutomaticWalk, resource: String, carrier: WorkoutTimeRange, gap: Bool, clientID: String) {
        version = 1; sessionID = walk.id; recorderClientID = clientID; self.resource = resource
        start = walk.start; end = walk.exportEnd; steps = walk.steps
        carrierStart = carrier.start; carrierEnd = carrier.end; self.gap = gap
        legacyResource = walk.gapExport?.legacyResource
    }
    public func signedNote(privateKey: Data) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).signature(for: data)
        return "PadSteps-measured-v1:" + data.base64EncodedString() + "." + signature.base64EncodedString()
    }
    public static func verified(point: [String: Any], publicKey: Data, clientID: String) -> Self? {
        guard let resource = point["name"] as? String,
              let exercise = point["exercise"] as? [String: Any], exercise["exerciseType"] as? String == "WALKING",
              let note = exercise["notes"] as? String,
              let interval = exercise["interval"] as? [String: Any],
              let left = interval["startTime"] as? String, let right = interval["endTime"] as? String,
              let carrierStart = PadStepImport.date(left), let carrierEnd = PadStepImport.date(right) else { return nil }
        let lines = note.split(separator: "\n").filter { $0.hasPrefix("PadSteps-measured-v1:") }
        guard lines.count == 1, let line = lines.first else { return nil }
        let parts = line.dropFirst("PadSteps-measured-v1:".count).split(separator: ".")
        guard parts.count == 2, let data = Data(base64Encoded: String(parts[0])), data.count < 4096,
              let signature = Data(base64Encoded: String(parts[1])),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey), key.isValidSignature(signature, for: data),
              let receipt = try? JSONDecoder().decode(Self.self, from: data), receipt.version == 1,
              (receipt.resource == resource || receipt.resource == "unassigned"), receipt.recorderClientID == clientID,
              receipt.steps > 0, receipt.steps < 100_000,
              receipt.end > receipt.start, receipt.end.timeIntervalSince(receipt.start) < 86400,
              abs(receipt.carrierStart.timeIntervalSince(carrierStart)) < 0.002,
              abs(receipt.carrierEnd.timeIntervalSince(carrierEnd)) < 0.002,
              carrierStart < receipt.end, carrierEnd > receipt.start else { return nil }
        if receipt.resource == "unassigned" {
            guard let source = point["dataSource"] as? [String: Any], source["platform"] as? String == "GOOGLE_WEB_API",
                  let app = source["application"] as? [String: Any],
                  (app["googleWebClientId"] as? String ?? app["webClientId"] as? String) == clientID else { return nil }
        }
        return receipt
    }
    public static func verifiedAll(point: [String: Any], publicKey: Data, clientID: String) -> [Self] {
        guard let exercise = point["exercise"] as? [String: Any], let notes = exercise["notes"] as? String else { return [] }
        let receipts = notes.split(separator: "\n").filter { $0.hasPrefix("PadSteps-measured-v1:") }.compactMap { line -> Self? in
            var candidate = point; var data = exercise; data["notes"] = String(line); candidate["exercise"] = data
            return verified(point: candidate, publicKey: publicKey, clientID: clientID)
        }
        let groups = Dictionary(grouping: receipts, by: \.sessionID)
        return receipts.filter { groups[$0.sessionID]?.count == 1 }
    }
}
