import AppKit
import CoreBluetooth
import PadStepsCore
import Darwin

struct DesktopState: Codable {
    var recorder = AutomaticRecorder()
    var walks: [AutomaticWalk] = []
    var deviceID: UUID?
    var healthUserID: String?
    var monitoring = true
}

@MainActor
final class PadMonitor: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var state: DesktopState
    @Published var connection = "Looking for your Sperax P2 Max…"
    @Published var error: String?
    @Published var lastSample: PadObservation?
    @Published var linked = false
    @Published var syncing = false
    @Published var syncingWalkID: UUID?
    @Published var sourceAuditSummary: [UUID: String] = [:]
    @Published var overlapReports: [UUID: OverlapReport] = [:]
    @Published var relayStatus = "Measured steps are queued for the paired iPhone."
    var relaying = false
    var lastRelayDigest: Data?
    let directory: URL
    let google: GoogleConnection
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var query: CBCharacteristic?
    private var decoder = UARTFrameDecoder()
    private var timer: Timer?
    private var lastTelemetry = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var lastSync = Date.distantPast
    private var lastRelayAttempt = Date.distantPast
    private var activity: NSObjectProtocol?
    private var connectingSince: Date?
    private var persistenceHealthy = true
    private var lockFD: Int32 = -1
    private var storageOpen = false
    var canWriteSavedState: Bool { storageOpen && persistenceHealthy }
    var automaticallyReusesFitbitWalks: Bool {
        let value = String(describing: Bundle.main.object(forInfoDictionaryKey: "PadStepsAutoCorrectMatchingWalks") ?? false).lowercased()
        return ["true", "yes", "1"].contains(value)
    }

    override init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.padsteps.desktop", isDirectory: true)
        var initial = DesktopState()
        var startupError: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: url.path) {
                initial = try JSONDecoder().decode(DesktopState.self, from: Data(contentsOf: url))
                initial.recorder.disconnected()
            }
        } catch { startupError = "Couldn’t read saved walks. Automatic recording is paused to protect them." }
        state = initial; google = GoogleConnection(storage: directory)
        super.init()
        lockFD = Darwin.open(directory.appendingPathComponent("process.lock").path, O_CREAT | O_RDWR, 0o600)
        if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            startupError = "PadSteps is already running, or its data folder is unavailable. Use the existing menu-bar app."
        }
        error = startupError; persistenceHealthy = startupError == nil
        storageOpen = startupError == nil
        if startupError != nil { state.monitoring = false }
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconnect() }
        }
    }

    func persist() throws {
        guard storageOpen else { throw PadError.message("Saved data is unavailable. Close the other PadSteps instance or repair the data folder first.") }
        do {
            let url = directory.appendingPathComponent("state.json")
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let file = try FileHandle(forWritingTo: url); try file.synchronize(); try file.close()
            persistenceHealthy = true
        } catch {
            persistenceHealthy = false; self.error = "Couldn’t save walks to disk. Uploads are paused; free disk space and reopen PadSteps."
            throw error
        }
    }

    func setMonitoring(_ enabled: Bool) {
        // Stopping observation mid-walk retains the active recording for reconnect.
        state.monitoring = enabled
        do { try persist() } catch { return }
        if enabled { connect() } else {
            central.stopScan(); if let peripheral { central.cancelPeripheralConnection(peripheral) }
            connection = "Pad monitoring paused"
        }
    }

    func retrySync() { lastSync = .distantPast; Task { await syncPending() } }

    func confirmTotals(_ id: UUID, totals: RecordedWalkTotals) {
        guard !syncing, persistenceHealthy, let walk = state.walks.first(where: { $0.id == id }) else { return }
        do {
            try evidence("before-totals-recovery", walk: walk, value: JSONSerialization.jsonObject(with: JSONEncoder().encode(walk)))
            try update(walk.confirmingTotals(totals, at: Date()))
            retrySync()
        } catch { self.error = error.localizedDescription }
    }

    func saveWithoutHeartRate(_ id: UUID) {
        guard !syncing, let walk = state.walks.first(where: { $0.id == id }) else { return }
        do { try update(walk.omittingHeartRate()); retrySync() }
        catch { self.error = error.localizedDescription }
    }

    func keepLocal(_ id: UUID) {
        guard !syncing, let walk = state.walks.first(where: { $0.id == id }) else { return }
        do { try update(walk.keepingLocal()) } catch { self.error = error.localizedDescription }
    }

    func resumeChecks(_ id: UUID) {
        guard !syncing, let walk = state.walks.first(where: { $0.id == id }) else { return }
        do { try update(walk.resumingChecks()); retrySync() } catch { self.error = error.localizedDescription }
    }

    func showWalkFiles(_ id: UUID) {
        guard let walk = state.walks.first(where: { $0.id == id }) else { return }
        do {
            try evidence("recorded-walk", walk: walk, value: JSONSerialization.jsonObject(with: JSONEncoder().encode(walk)))
            NSWorkspace.shared.open(directory.appendingPathComponent("Walks/\(id.uuidString)"))
        } catch { self.error = error.localizedDescription }
    }

    func retryRejectedSave(_ id: UUID) async {
        guard !syncing, persistenceHealthy, google.connected,
              var walk = state.walks.first(where: { $0.id == id }), walk.canRetryRejectedSave,
              let operationName = walk.operationName else { return }
        syncing = true; syncingWalkID = id
        defer { syncing = false; syncingWalkID = nil; lastSync = .distantPast }
        do {
            try await verifyAccount()
            let operation = try await google.request("GET", operationName)
            try evidence("rejected-save-recheck", walk: walk, value: operation)
            let existing = try await workouts(near: walk)
            let matching = existing.filter { matches($0, walk: walk) }
            if matching.count == 1, let name = matching.first?["name"] as? String {
                walk.resourceName = name; walk.status = "verifying"; walk.creationRejected = false
            } else {
                walk = try walk.retryingRejectedSave(verifiedFailure: operation["done"] as? Bool == true && operation["error"] != nil)
                // The normal upload guard checks these workouts again before any POST.
            }
            try update(walk)
        } catch { self.error = error.localizedDescription }
    }

    private func tick() {
        if state.monitoring, central.state == .poweredOn {
            if let peripheral, peripheral.state == .connected {
                if let query {
                    peripheral.writeValue(SperaxUART.statusQuery, for: query, type: .withoutResponse)
                    if Date().timeIntervalSince(lastTelemetry) > 12 { reconnect() }
                } else if Date().timeIntervalSince(connectingSince ?? Date()) > 15 { reconnect() }
            } else if Date().timeIntervalSince(lastAttempt) > 8 {
                if let connectingSince, Date().timeIntervalSince(connectingSince) > 20, let peripheral {
                    central.cancelPeripheralConnection(peripheral)
                    self.connectingSince = Date()
                }
                connect()
            }
        }
        if state.monitoring && state.recorder.active != nil && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .automaticTerminationDisabled], reason: "Recording walking-pad steps")
        } else if !state.monitoring || state.recorder.active == nil, let activity {
            ProcessInfo.processInfo.endActivity(activity); self.activity = nil
        }
        if Date().timeIntervalSince(lastSync) >= 60 { Task { await syncPending() } }
        if Date().timeIntervalSince(lastRelayAttempt) >= 60 { lastRelayAttempt = Date(); Task { await relayMeasuredWalks() } }
    }

    func reconnect() {
        query = nil; linked = false
        state.recorder.disconnected(); try? persist()
        if let peripheral {
            // Wait for the cancellation callback before connecting again; otherwise
            // a delayed disconnect callback can tear down the new connection.
            connectingSince = Date(); central.cancelPeripheralConnection(peripheral)
        } else { lastAttempt = .distantPast; connect() }
    }

    private func connect() {
        guard state.monitoring, central.state == .poweredOn, peripheral == nil else { return }
        lastAttempt = Date()
        if let id = state.deviceID,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(known)
        } else {
            connection = "Looking for your Sperax P2 Max…"
            central.scanForPeripherals(withServices: [CBUUID(string: SperaxUART.serviceUUID)])
        }
    }

    private func attach(_ pad: CBPeripheral) {
        central.stopScan(); peripheral = pad; pad.delegate = self; connectingSince = Date()
        connection = "Connecting to Sperax P2 Max…"; central.connect(pad)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connect()
        case .unauthorized: connection = "Allow Bluetooth in System Settings → Privacy & Security → Bluetooth."
        case .poweredOff: connection = "Turn on Bluetooth to connect your pad."
        default: connection = "Bluetooth unavailable"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard state.deviceID.map({ $0 == peripheral.identifier }) ?? name.uppercased().contains("SPERAX_P2MAX"), self.peripheral == nil else { return }
        attach(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        decoder = UARTFrameDecoder(); lastTelemetry = Date()
        peripheral.discoverServices([CBUUID(string: SperaxUART.serviceUUID)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { lost(peripheral) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { lost(peripheral) }
    private func lost(_ pad: CBPeripheral) {
        guard peripheral?.identifier == pad.identifier || peripheral == nil else { return }
        peripheral = nil; query = nil; linked = false; connectingSince = nil
        state.recorder.disconnected(); try? persist()
        connection = state.monitoring ? "Pad disconnected • reconnecting automatically" : "Pad monitoring paused"
        lastAttempt = .distantPast
        connect()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics([CBUUID(string: SperaxUART.notifyUUID), CBUUID(string: SperaxUART.queryUUID)], for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == CBUUID(string: SperaxUART.queryUUID) { query = characteristic }
            if characteristic.uuid == CBUUID(string: SperaxUART.notifyUUID) { peripheral.setNotifyValue(true, for: characteristic) }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == CBUUID(string: SperaxUART.notifyUUID), let data = characteristic.value, error == nil else { return }
        for frame in decoder.append(data) {
            guard let value = SperaxUART.telemetry(from: frame) else { continue }
            lastTelemetry = Date(); linked = true; connection = "Sperax P2 Max connected"
            state.deviceID = peripheral.identifier; lastSample = PadObservation(value, at: lastTelemetry)
            if let finished = state.recorder.observe(value, at: lastTelemetry) {
                state.walks.insert(finished, at: 0); lastSync = .distantPast
            }
            do { try persist() } catch { return }
        }
    }

    func update(_ walk: AutomaticWalk) throws {
        guard let index = state.walks.firstIndex(where: { $0.id == walk.id }) else { return }
        state.walks[index] = walk; try persist()
    }
    func evidence(_ name: String, walk: AutomaticWalk, value: Any) throws {
        let folder = directory.appendingPathComponent("Walks/\(walk.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(name + ".json")
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func syncPending() async {
        guard !syncing, persistenceHealthy, google.connected else { return }
        syncing = true; lastSync = Date()
        var automaticCorrections: [(UUID, WorkoutConflict)] = []
        defer {
            syncing = false; syncingWalkID = nil
            let candidates = automaticCorrections
            if !candidates.isEmpty {
                Task { for (id, conflict) in candidates { await self.correctExistingWorkout(walkID: id, conflict: conflict) } }
            }
        }
        for pending in state.walks.filter(\.needsSync) {
            syncingWalkID = pending.id
            var walk = pending
            do {
                if walk.canRecheckOverlap {
                    walk.status = walk.averageBPM == nil ? "waitingHeartRate" : "ready"
                    walk.reviewKind = nil
                    try update(walk)
                }
                let identity = try await google.request("GET", "users/me/identity")
                guard let user = identity["healthUserId"] as? String else { throw PadError.message("Google didn’t identify the connected health account.") }
                if let expected = state.healthUserID, expected != user {
                    throw PadError.message("This is a different Google Health account. Reconnect the account used for your saved walks.")
                }
                state.healthUserID = user; try persist()
                if walk.gapExport == nil, walk.canRecheckSavedOverlap, let legacy = walk.resourceName {
                    var plan = WorkoutGapExport(gaps: [], resources: [legacy])
                    plan.legacyResource = legacy
                    walk.gapExport = plan; try update(walk)
                }
                if walk.gapExport != nil || (walk.issue == nil && walk.uploadAttempted != true && walk.resourceName == nil && walk.operationName == nil && walk.correctionTarget == nil) {
                    try await syncGapExport(walk: &walk)
                    continue
                }
                if walk.canRecheckSavedOverlap {
                    let overlaps = try await workouts(near: walk).filter { $0["name"] as? String != walk.resourceName }
                    if !overlaps.isEmpty {
                        await loadComparison(walk: walk, points: overlaps)
                        continue
                    }
                    walk.status = "verifying"; walk.reviewKind = nil
                    try update(walk)
                }
                if walk.status == "waitingHeartRate" {
                    let points = try await google.pages("users/me/dataTypes/heart-rate/dataPoints", query: [
                        "pageSize": "10000", "dataSourceFamily": "users/me/dataSourceFamilies/google-wearables",
                        "filter": "heart_rate.sample_time.physical_time >= \"\(Self.iso(walk.start))\" AND heart_rate.sample_time.physical_time < \"\(Self.iso(walk.exportEnd))\""])
                    let heart = points.compactMap { point -> HeartObservation? in
                        guard let source = point["dataSource"] as? [String: Any], source["platform"] as? String == "FITBIT",
                              let device = source["device"] as? [String: Any], device["displayName"] as? String == "Fitbit Air",
                              let h = point["heartRate"] as? [String: Any], let time = h["sampleTime"] as? [String: Any],
                              let text = time["physicalTime"] as? String, let at = Self.date(text),
                              let number = h["beatsPerMinute"] as? String, let bpm = Int(number) else { return nil }
                        return HeartObservation(at: at, bpm: bpm)
                    }
                    try evidence("fitbit-heart-rate", walk: walk, value: points)
                    do {
                        let summary = try HeartSummary.calculate(heart, start: walk.start, end: walk.exportEnd)
                        walk.averageBPM = summary.average; walk.status = "ready"
                        try update(walk)
                    } catch let error as HeartCoverageError {
                        walk.detail = error.localizedDescription
                        try update(walk); continue
                    }
                }
                // A correction always keeps the same resource, including across crashes/timeouts.
                if let target = walk.correctionTarget { walk.resourceName = target }
                // Resolve crash/timeout uncertainty by finding the existing workout, never another POST.
                if walk.resourceName == nil {
                    let existing = try await workouts(near: walk)
                    let same = existing.filter { matches($0, walk: walk) }
                    try evidence("overlap-check", walk: walk, value: existing)
                    let decision = UploadGuard.decide(attempted: walk.uploadAttempted == true || walk.status == "attempted" || walk.status == "verifying",
                        matchingNames: same.compactMap { $0["name"] as? String }, hasOverlap: !existing.isEmpty, operationName: walk.operationName)
                    switch decision {
                    case .adopt(let name):
                        walk.resourceName = name; walk.status = "verifying"; try update(walk)
                    case .review(let reason):
                        walk.status = "review"; walk.detail = reason
                        walk.reviewKind = "confirmation"
                        if reason == UploadGuard.overlapMessage {
                            walk.reviewKind = "overlap"
                            await loadComparison(walk: walk, points: existing)
                            if let candidate = WorkoutConflict.automaticCandidate(in: existing, for: walk,
                                enabled: automaticallyReusesFitbitWalks) {
                                automaticCorrections.append((walk.id, candidate))
                            }
                        }
                        try update(walk); continue
                    case .resolveOperation(let operation):
                        try await resolveOperation(operation, walk: &walk)
                    case .create:
                        let body = payload(walk)
                        try evidence("upload-payload", walk: walk, value: body)
                        walk.uploadAttempted = true; walk.reviewKind = nil
                        walk.status = "attempted"; walk.detail = "Saving to Google Health…"; try update(walk)
                        let operation = try await google.request("POST", "users/me/dataTypes/exercise/dataPoints", body: body)
                        try evidence("create-response", walk: walk, value: operation)
                        try applyOperation(operation, walk: &walk)
                        if walk.resourceName == nil, let operationName = walk.operationName {
                            try await resolveOperation(operationName, walk: &walk)
                        }
                    }
                }
                if let name = walk.resourceName {
                    let saved = try await google.request("GET", name)
                    guard matches(saved, walk: walk) else {
                        walk.status = "review"; walk.reviewKind = "savedMismatch"
                        try evidence("different-google-readback", walk: walk, value: saved)
                        throw PadError.message("Google’s saved workout differs from the pad. Compare the records before correcting the existing workout.")
                    }
                    try evidence("google-readback", walk: walk, value: saved)
                    walk.status = "saved"; walk.reviewKind = nil
                    walk.detail = walk.heartRateOmitted == true ? "Saved without a heart-rate summary • steps ready for iPhone sync" : "Saved to Google Health • steps ready for iPhone sync"
                    overlapReports[walk.id] = nil
                    try update(walk)
                }
            } catch {
                walk.detail = error.localizedDescription
                do { try update(walk) } catch { break }
            }
        }
        await auditRecentSavedWalks()
    }

    private func auditRecentSavedWalks() async {
        // Fitbit auto-detection may arrive after our upload; surface that later overlap too.
        let recent = state.walks.filter { $0.status == "saved" && $0.exportEnd > Date().addingTimeInterval(-3 * 86400) }
        for var walk in recent.prefix(20) {
            do {
                try await verifyAccount()
                if walk.gapExport != nil { try await syncGapExport(walk: &walk); continue }
                let all = try await workouts(near: walk)
                try evidence("post-save-overlaps", walk: walk, value: all)
                let points = all.filter { $0["name"] as? String != walk.resourceName }
                if !points.isEmpty {
                    walk.status = "review"; walk.reviewKind = "lateOverlap"
                    walk.detail = "Another Google workout now overlaps this saved PadSteps walk. Keep the measured PadSteps workout and resolve the extra workout in Google Health, then Check again."
                    try update(walk)
                    await loadComparison(walk: walk, points: points)
                }
            } catch { break } // Keep a verified saved walk saved when an audit is temporarily unavailable.
        }
    }

    func recheck(_ id: UUID) {
        guard !syncing, let walk = state.walks.first(where: { $0.id == id }), walk.canInspectGoogle else { return }
        retrySync()
    }

    func inspectOverlap(_ id: UUID) async {
        guard !syncing, google.connected, let walk = state.walks.first(where: { $0.id == id }), walk.canInspectGoogle else { return }
        syncing = true; syncingWalkID = id
        defer { syncing = false; syncingWalkID = nil }
        do {
            try await verifyAccount()
            let points = try await workouts(near: walk).filter { walk.canReviewCorrection || walk.reviewKind == "savedMismatch" || $0["name"] as? String != walk.resourceName }
            try evidence("overlap-check", walk: walk, value: points)
            await loadComparison(walk: walk, points: points)
        } catch { self.error = error.localizedDescription }
    }

    /// Read-only diagnosis of retained tracker steps versus all-source daily credit.
    func auditStepSources(_ id: UUID) async {
        guard !syncing, google.connected, let walk = state.walks.first(where: { $0.id == id }) else { return }
        syncing = true; syncingWalkID = id
        defer { syncing = false; syncingWalkID = nil }
        do {
            try await verifyAccount()
            var counts: [String: Int] = [:]
            if self.error?.hasPrefix("Couldn’t inspect step sources:") == true { self.error = nil }
            sourceAuditSummary[id] = "Checking Google’s step sources…"
            let day = Calendar.current.startOfDay(for: walk.start)
            let end = min(Date(), Calendar.current.date(byAdding: .day, value: 1, to: day)!)
            for family in ["all-sources", "google-wearables"] {
                for (label, start, stop) in [("walk", walk.start, walk.exportEnd), ("day", day, end)] {
                    let response = try await google.request("POST", "users/me/dataTypes/steps/dataPoints:rollUp", body: [
                        "range": ["startTime": Self.iso(start), "endTime": Self.iso(stop)],
                        "windowSize": "86400s", "pageSize": 10,
                        "dataSourceFamily": "users/me/dataSourceFamilies/\(family)"])
                    if let count = StepComparison.rollupCount(response) { counts[label + "-" + family] = count }
                    try evidence("source-audit-\(label)-\(family)", walk: walk, value: response)
                }
            }
            func number(_ key: String) -> String { counts[key].map { $0.formatted() } ?? "Unknown" }
            sourceAuditSummary[id] = "Pad: \(walk.steps.formatted()) steps. Google in this walk: \(number("walk-all-sources")); tracker only: \(number("walk-google-wearables")). This date in Google: \(number("day-all-sources")); tracker only: \(number("day-google-wearables")). Workout summaries are separate."
        } catch {
            sourceAuditSummary[id] = "Step source check failed. No health data changed."
            self.error = "Couldn’t inspect step sources: \(error.localizedDescription)"
        }
    }

    private func verifyAccount() async throws {
        let identity = try await google.request("GET", "users/me/identity")
        guard let user = identity["healthUserId"] as? String, user == state.healthUserID else {
            throw PadError.message("Connect the Google Health account used for this walk before reviewing it.")
        }
    }

    private func loadComparison(walk: AutomaticWalk, points: [[String: Any]]) async {
        var count: Int?; var failure: String?
        do {
            let response = try await google.request("POST", "users/me/dataTypes/steps/dataPoints:rollUp", body: [
                "range": ["startTime": Self.iso(walk.start), "endTime": Self.iso(walk.exportEnd)],
                "windowSize": "\(walk.seconds)s", "pageSize": 10,
                "dataSourceFamily": "users/me/dataSourceFamilies/all-sources"])
            count = StepComparison.rollupCount(response)
            try evidence("interval-steps", walk: walk, value: response)
        } catch { failure = "Google’s interval steps could not be read. Try Check again." }
        if count == nil, failure == nil { failure = "Google returned no confirmed step total for this interval; the shortfall is unknown." }
        overlapReports[walk.id] = OverlapReport(checkedAt: Date(), workouts: points.compactMap(WorkoutConflict.init),
            comparison: StepComparison(pad: walk.steps, recorded: count), intervalError: failure)
    }

    /// An explicit review action changes one existing resource to absolute pad totals, never adds a delta workout.
    func correctExistingWorkout(walkID: UUID, conflict: WorkoutConflict) async {
        guard !syncing, persistenceHealthy, google.connected,
              var walk = state.walks.first(where: { $0.id == walkID }),
              (walk.canRecheckOverlap || (walk.canReviewCorrection && walk.correctionTarget == conflict.id) ||
               (walk.reviewKind == "savedMismatch" && walk.resourceName == conflict.id)),
              conflict.coversSameWalk(walk), walk.averageBPM != nil else { return }
        syncing = true; syncingWalkID = walkID
        defer { syncing = false; syncingWalkID = nil }
        do {
            try await verifyAccount()
            let key = try CorrectionSigner.key()
            let points = try await workouts(near: walk)
            guard points.count == 1, let original = points.first,
                  WorkoutConflict(point: original) == conflict else {
                await loadComparison(walk: walk, points: points)
                throw PadError.message("Google’s workout changed since review. Check the refreshed comparison before correcting it.")
            }
            let proof = WorkoutCorrection(walk: walk, resource: conflict.id, recorderClientID: google.clientID)
            let measured = payload(walk)["exercise"] as! [String: Any]
            var exercise = original["exercise"] as! [String: Any]
            var metrics = exercise["metricsSummary"] as? [String: Any] ?? [:]
            for (key, value) in measured["metricsSummary"] as! [String: Any] { metrics[key] = value }
            for (key, value) in measured where key != "metricsSummary" { exercise[key] = value }
            exercise["metricsSummary"] = metrics
            exercise.removeValue(forKey: "createTime"); exercise.removeValue(forKey: "updateTime")
            // Splits and pause events were measured on Google's old interval and cannot be silently rebased.
            exercise.removeValue(forKey: "splitSummaries"); exercise.removeValue(forKey: "exerciseEvents")
            let oldNotes = (exercise["notes"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("PadSteps-v1:") }.joined(separator: "\n")
            exercise["notes"] = (oldNotes.isEmpty ? "" : oldNotes + "\n") + (try proof.signedNote(privateKey: key.rawRepresentation))
            var body: [String: Any] = ["name": conflict.id, "exercise": exercise]
            if var source = original["dataSource"] as? [String: Any] {
                source.removeValue(forKey: "platform"); source.removeValue(forKey: "application")
                body["dataSource"] = source
            }
            try evidence("before-correction", walk: walk, value: original)
            try evidence("correction-payload", walk: walk, value: body)
            // Persist target before PATCH. Timeout/restart can only read this same resource, never create another.
            walk.correctionTarget = conflict.id; walk.resourceName = conflict.id; walk.uploadAttempted = true
            walk.status = "verifying"; walk.reviewKind = nil; walk.detail = "Correcting the existing Google workout…"
            try update(walk)
            let operation = try await google.request("PATCH", conflict.id, body: body)
            try evidence("correction-response", walk: walk, value: operation)
            try applyOperation(operation, walk: &walk)
            if let operationName = walk.operationName { try await resolveOperation(operationName, walk: &walk) }
            let saved = try await google.request("GET", conflict.id)
            guard CorrectionSigner.verified(saved, walk: walk, clientID: google.clientID) else {
                throw PadError.message("Google has not confirmed the corrected pad counters yet. Check save confirmation; no duplicate workout was created.")
            }
            try evidence("google-readback", walk: walk, value: saved)
            walk.status = "saved"; walk.detail = "Existing Google workout corrected • steps ready for iPhone sync"
            overlapReports[walk.id] = nil; try update(walk)
        } catch {
            if walk.correctionTarget != nil {
                walk.status = "verifying"
                walk.detail = "Correction not confirmed: \(error.localizedDescription) No additional workout will be created."
            } else { self.error = error.localizedDescription }
            try? update(walk)
        }
    }

    private func applyOperation(_ operation: [String: Any], walk: inout AutomaticWalk) throws {
        walk.operationName = operation["name"] as? String ?? walk.operationName
        if operation["error"] != nil {
            walk.status = "review"; walk.reviewKind = "rejectedSave"
            walk.creationRejected = operation["done"] as? Bool == true && walk.resourceName == nil && walk.correctionTarget == nil
            walk.detail = "Google rejected the workout. Review the saved details, then retry the rejected save or keep this walk locally."
        }
        if let response = operation["response"] as? [String: Any], let name = response["name"] as? String {
            walk.resourceName = name; walk.status = "verifying"
        }
        try update(walk)
    }
    private func resolveOperation(_ name: String, walk: inout AutomaticWalk) async throws {
        let result = try await google.request("GET", name)
        try applyOperation(result, walk: &walk)
    }

    func workouts(near walk: AutomaticWalk) async throws -> [[String: Any]] {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        // Exercise session filters use civil time. UTC offset determines local dates.
        f.timeZone = .current
        let left = String(f.string(from: walk.start.addingTimeInterval(-86400)).prefix(10))
        let right = String(f.string(from: walk.exportEnd.addingTimeInterval(172800)).prefix(10))
        let points = try await google.pages("users/me/dataTypes/exercise/dataPoints", query: ["pageSize": "25",
            "filter": "exercise.interval.civil_start_time >= \"\(left)\" AND exercise.interval.civil_start_time < \"\(right)\""])
        return points.filter {
            guard let e = $0["exercise"] as? [String: Any], let i = e["interval"] as? [String: Any],
                  let s = i["startTime"] as? String, let t = i["endTime"] as? String,
                  let start = Self.date(s), let end = Self.date(t) else { return false }
            return start < walk.exportEnd && end > walk.start
        }
    }
    func matches(_ point: [String: Any], walk: AutomaticWalk) -> Bool {
        if CorrectionSigner.verified(point, walk: walk, clientID: google.clientID) { return true }
        guard let source = point["dataSource"] as? [String: Any], source["platform"] as? String == "GOOGLE_WEB_API", let app = source["application"] as? [String: Any],
              (app["googleWebClientId"] as? String ?? app["webClientId"] as? String) == google.clientID,
              let exercise = point["exercise"] as? [String: Any], exercise["exerciseType"] as? String == "WALKING", let interval = exercise["interval"] as? [String: Any],
              let left = interval["startTime"] as? String, let right = interval["endTime"] as? String,
              let start = Self.date(left), let end = Self.date(right),
              abs(start.timeIntervalSince(walk.start)) < 0.002, abs(end.timeIntervalSince(walk.exportEnd)) < 0.002,
              let metrics = exercise["metricsSummary"] as? [String: Any],
              String(describing: metrics["steps"] ?? "") == String(walk.steps),
              (metrics["distanceMillimeters"] as? NSNumber)?.intValue == walk.metres * 1000,
              (walk.heartRateOmitted == true ? metrics["averageHeartRateBeatsPerMinute"] == nil : String(describing: metrics["averageHeartRateBeatsPerMinute"] ?? "") == String(walk.averageBPM ?? 0)),
              let duration = exercise["activeDuration"] as? String,
              Double(duration.dropLast()) == Double(walk.seconds) else { return false }
        return true
    }
    private func payload(_ walk: AutomaticWalk) -> [String: Any] {
        var metrics: [String: Any] = ["steps": String(walk.steps), "distanceMillimeters": walk.metres * 1000]
        if let bpm = walk.averageBPM { metrics["averageHeartRateBeatsPerMinute"] = String(bpm) }
        return ["dataSource": ["recordingMethod": "ACTIVELY_MEASURED", "platform": "GOOGLE_WEB_API"],
         "exercise": ["interval": ["startTime": Self.iso(walk.start), "endTime": Self.iso(walk.exportEnd),
                                    "startUtcOffset": "\(TimeZone.current.secondsFromGMT(for: walk.start))s",
                                    "endUtcOffset": "\(TimeZone.current.secondsFromGMT(for: walk.exportEnd))s"],
                      "exerciseType": "WALKING", "activeDuration": "\(walk.seconds)s",
                      "metricsSummary": metrics]]
    }
    static func iso(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
