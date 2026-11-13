import Foundation
import CryptoKit
import PadStepsCore

enum CorrectionSigner {
    static func key() throws -> Curve25519.Signing.PrivateKey {
        guard let url = Bundle.main.url(forResource: "correction-key", withExtension: "json"),
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String],
              let text = object["privateKey"], let raw = Data(base64Encoded: text) else {
            throw PadError.message("This build is not paired for existing-workout corrections. Build the Mac and iPhone apps with the same local correction key.")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }
    static func verified(_ point: [String: Any], walk: AutomaticWalk, clientID: String) -> Bool {
        guard let key = try? key(), let exercise = point["exercise"] as? [String: Any],
              let note = exercise["notes"] as? String, let resource = point["name"] as? String,
              let proof = WorkoutCorrection.verified(note: note, publicKey: key.publicKey.rawRepresentation,
                  recorderClientID: clientID, resource: resource),
              proof.steps == walk.steps, proof.metres == walk.metres, proof.seconds == walk.seconds, proof.averageBPM == walk.averageBPM, abs(proof.start.timeIntervalSince(walk.start)) < 0.002,
              abs(proof.end.timeIntervalSince(walk.exportEnd)) < 0.002 else { return false }
        return proof.matches(point)
    }
}
