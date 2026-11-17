import Foundation
import CryptoKit
import PadStepsCore

extension PadMonitor {
    func writeWalkFeed() throws -> URL? {
        guard canWriteSavedState else { throw PadError.message("Saved data is unavailable. The step relay is paused to protect existing records.") }
        guard let account = state.healthUserID else { return nil }
        var assigned = false
        for index in state.walks.indices where state.walks[index].canExportMeasuredSteps && state.walks[index].stepIdentityAssigned != true {
            state.walks[index] = state.walks[index].preparingStepIdentity(); assigned = true
        }
        if assigned { try persist() }
        let sessions = state.walks.filter(\.canExportMeasuredSteps)
            .sorted { $0.id.uuidString < $1.id.uuidString }.map { MeasuredWalkFeed.Session(walk: $0) }
        let feed = MeasuredWalkFeed(account: account, clientID: google.clientID, sessions: sessions)
        let data = try feed.signed(privateKey: CorrectionSigner.key().rawRepresentation)
        let url = directory.appendingPathComponent("measured-walk-feed.json")
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }
    func relayMeasuredWalks() async {
        guard !relaying, canWriteSavedState else { return }
        guard let device = Bundle.main.object(forInfoDictionaryKey: "PadStepsRelayDeviceID") as? String, !device.isEmpty,
              let bundle = Bundle.main.object(forInfoDictionaryKey: "PadStepsRelayBundleID") as? String, !bundle.isEmpty else {
            relayStatus = "Configure the paired iPhone relay to sync measured steps without a Google workout."
            return
        }
        relaying = true
        defer { relaying = false }
        do {
            guard let url = try writeWalkFeed() else { return }
            let digest = Data(SHA256.hash(data: try Data(contentsOf: url)))
            if lastRelayDigest == digest { return }
            relayStatus = "Sending measured steps to your paired iPhone…"
            let arguments = ["devicectl", "device", "copy", "to", "--device", device,
                "--source", url.path, "--destination", "Library/Application Support/measured-walk-feed.json",
                "--domain-type", "appDataContainer", "--domain-identifier", bundle, "--timeout", "25", "--quiet"]
            let succeeded = try await Task.detached(priority: .utility) {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                return process.terminationStatus == 0
            }.value
            if succeeded {
                lastRelayDigest = digest
                relayStatus = "Measured steps delivered to your paired iPhone. Apple Health catches up when the phone is unlocked and PadSteps runs."
            } else {
                relayStatus = "Measured steps are queued on this Mac. Reconnect the paired iPhone; transfer retries automatically."
            }
        } catch { relayStatus = "Measured steps are retained. Phone transfer could not finish: \(error.localizedDescription)" }
    }
}
