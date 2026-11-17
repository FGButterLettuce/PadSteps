import Foundation
import CryptoKit

public struct MeasuredWalkFeed: Codable, Sendable {
    public struct Session: Codable, Sendable {
        public let id: UUID
        public let start: Date
        public let end: Date
        public let steps: Int
        public let legacyResource: String?
        public init(walk: AutomaticWalk) {
            id = walk.id; start = walk.start; end = walk.exportEnd; steps = walk.steps
            legacyResource = walk.stepIdentityAssigned == true ? walk.stepIdentityResource : walk.gapExport?.legacyResource ?? (walk.gapExport == nil ? walk.resourceName : nil)
        }
    }
    public let version: Int
    public let account: String
    public let clientID: String
    public let sessions: [Session]
    public init(account: String, clientID: String, sessions: [Session]) {
        version = 1; self.account = account; self.clientID = clientID; self.sessions = sessions
    }
    public func signed(privateKey: Data) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(self)
        let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).signature(for: payload)
        return try encoder.encode(Envelope(payload: payload, signature: signature))
    }
    public static func imports(_ data: Data, publicKey: Data, account: String, clientID: String) throws -> [PadStepImport] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.payload.count < 4_000_000,
              try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(envelope.signature, for: envelope.payload) else { throw StepImportError.invalidRecord }
        let feed = try JSONDecoder().decode(Self.self, from: envelope.payload)
        guard feed.version == 1, feed.account == account, feed.clientID == clientID,
              !account.isEmpty, account.allSatisfy(\.isNumber), !clientID.isEmpty,
              Set(feed.sessions.map(\.id)).count == feed.sessions.count else { throw StepImportError.invalidRecord }
        let imports = try feed.sessions.map { session in
            guard session.steps > 0, session.steps < 100_000, session.end > session.start,
                  session.end.timeIntervalSince(session.start) < 86400 else { throw StepImportError.invalidRecord }
            let resource = session.legacyResource ?? "users/\(account)/dataTypes/exercise/dataPoints/local-\(session.id.uuidString.lowercased())"
            if let legacy = session.legacyResource {
                let parts = legacy.split(separator: "/")
                guard parts.count == 6, parts[0] == "users", parts[1] == Substring(account), parts[2] == "dataTypes", parts[3] == "exercise", parts[4] == "dataPoints", !parts[5].isEmpty else { throw StepImportError.invalidRecord }
            }
            var imported = PadStepImport(resource: resource, userID: account, start: session.start, end: session.end, steps: session.steps)
            imported.sessionID = session.id; imported.legacyResource = session.legacyResource
            return imported
        }
        guard Set(imports.map(\.syncIdentifier)).count == imports.count else { throw StepImportError.invalidRecord }
        return imports
    }
    private struct Envelope: Codable { let payload: Data; let signature: Data }
}

public extension AutomaticWalk {
    var canExportMeasuredSteps: Bool {
        guard issue == nil, stop != nil, !["recording", "empty", "localOnly"].contains(status),
              steps > 0, steps < 100_000, seconds > 0, seconds < 86400 else { return false }
        // An old-version create may already have reached Google without a saved
        // response. Wait for its legacy identity instead of inventing a new one.
        return !(gapExport == nil && uploadAttempted == true && resourceName == nil)
    }
    func preparingStepIdentity() -> Self {
        guard stepIdentityAssigned != true else { return self }
        var result = self
        result.stepIdentityResource = gapExport?.legacyResource ?? (gapExport == nil ? resourceName : nil)
        result.stepIdentityAssigned = true
        return result
    }
    func retainingStepIdentity(from stored: Self) -> Self {
        guard stored.stepIdentityAssigned == true else { return self }
        var result = self; result.stepIdentityAssigned = true; result.stepIdentityResource = stored.stepIdentityResource
        return result
    }
}
