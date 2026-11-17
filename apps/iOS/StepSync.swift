import BackgroundTasks
import Combine
import HealthKit
import PadStepsCore
import UIKit

struct StepSyncEntry: Codable, Identifiable {
    var walk: PadStepImport
    var state: String
    var note: String
    var checkedAt: Date
    var sampleCount: Int
    var exported: StepExportLedger?
    var pendingExport: StepExportIntent?
    var googleSteps: Int?
    var googleHadNoRecords: Bool?
    var googleCheckedAt: Date?
    var lastAttemptAt: Date?
    var id: String { walk.id }
}

struct StepSyncJournal: Codable {
    var schemaVersion: Int? = 1
    var startedFrom = Calendar.current.startOfDay(for: Date())
    var checkedThrough: Date?
    var account: String?
    var automatic = true
    var topUpPolicyVersion: Int?
    var entries: [String: StepSyncEntry] = [:]
    var isSupported: Bool {
        (schemaVersion ?? 1) == 1 && (topUpPolicyVersion ?? 1) == 1 && entries.allSatisfy { key, entry in
            ["ready", "attempted", "confirmed", "covered", "review", "trial"].contains(entry.state) &&
            entry.walk.isValidMeasurement && key == entry.walk.id && (account == nil || entry.walk.userID == account)
        }
    }
}

@MainActor
final class StepSync: ObservableObject {
    static let shared = StepSync()
    static var taskID: String { (Bundle.main.bundleIdentifier ?? "org.padsteps.iphone") + ".refresh" }
    @Published private(set) var journal: StepSyncJournal
    @Published private(set) var busy = false
    @Published private(set) var connecting = false
    @Published private(set) var email: String?
    @Published private(set) var status = "Connect Google Health, then enable Apple Health step syncing."
    @Published private(set) var problem: String?
    @Published private(set) var dailySteps: Int?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var workoutsReadable = 0
    @Published private(set) var backgroundStatus = "Background sync is not enabled yet."
    @Published private(set) var authorized = false
    private let health = HKHealthStore()
    private let steps = HKQuantityType(.stepCount)
    private let google = GoogleWalkReader()
    private var observers: [String: HKObserverQuery] = [:]
    private var backgroundTypes: [String] = []
    private var forceNextPass = false
    private lazy var syncRun = SharedSyncRun { [weak self] in
        guard let self else { return }
        self.busy = true
        defer { self.busy = false; self.diagnostic() }
        for pass in 0..<2 {
            self.followUp = false
            let force = self.forceNextPass; self.forceNextPass = false
            await self.performSync(force: force)
            if !self.followUp || Task.isCancelled || pass == 1 { break }
        }
    }
    private var followUp = false
    private let journalFile: JournalFile<StepSyncJournal>
    private var journalHealthy: Bool { journalFile.readable }
    private var started = false
    private let journalURL = URL.applicationSupportDirectory.appendingPathComponent("step-sync-journal.json")
    private let diagnosticURL = URL.applicationSupportDirectory.appendingPathComponent("step-sync-status.json")

    var exportsMissingSteps: Bool { Bundle.main.object(forInfoDictionaryKey: "PadStepsStepExportMode") as? String == "missing-google" }
    var entries: [StepSyncEntry] { journal.entries.values.sorted { $0.walk.start > $1.walk.start } }
    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private init() {
        let store = JournalFile(url: URL.applicationSupportDirectory.appendingPathComponent("step-sync-journal.json"), fresh: StepSyncJournal(),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication], validate: { $0.isSupported })
        journalFile = store; journal = store.initialValue
        if !store.readable { problem = JournalFileError.unreadable.localizedDescription }
        authorized = health.authorizationStatus(for: steps) == .sharingAuthorized
    }

    func start() {
        guard !started else { return }
        started = true
        guard journalHealthy else { diagnostic(); return }
        if exportsMissingSteps, journal.topUpPolicyVersion != 1 {
            // Resume a controlled trial only after the user-selected missing-step mode is installed.
            if journal.entries.values.contains(where: { $0.state == "trial" }) { journal.automatic = true }
            journal.topUpPolicyVersion = 1
            do { try persist() } catch { problem = error.localizedDescription; return }
        }
        registerObserver()
        schedule()
        Task {
            try? await google.restore()
            email = google.email
            if journal.automatic {
                await enableDelivery()
                if UIApplication.shared.applicationState == .active { await sync() }
            }
        }
    }

    func connectGoogle() async {
        guard !busy, !connecting else { return }
        connecting = true
        defer { connecting = false }
        do {
            try await google.signIn(); email = google.email
            connecting = false
            await sync()
        }
        catch { problem = error.localizedDescription; diagnostic() }
    }

    func connectHealth() async {
        guard !busy, !connecting else { return }
        do {
            guard !isSimulator, HKHealthStore.isHealthDataAvailable() else {
                throw ProofError.message("Use your iPhone for real step syncing. Simulator cannot write steps.")
            }
            try await health.requestAuthorization(toShare: [steps], read: [steps, HKObjectType.workoutType()])
            UserDefaults.standard.set(true, forKey: "padsteps.workoutReadRequested")
            authorized = health.authorizationStatus(for: steps) == .sharingAuthorized
            guard authorized else { throw ProofError.message("Allow PadSteps to write Steps in Apple Health settings.") }
            registerObserver()
            await enableDelivery()
            await sync()
        } catch { problem = error.localizedDescription; diagnostic() }
    }

    func setAutomatic(_ enabled: Bool) {
        guard journalHealthy else { problem = JournalFileError.unreadable.localizedDescription; return }
        journal.automatic = enabled
        if !enabled { syncRun.cancelAll(); BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID) }
        do { try persist() }
        catch { problem = error.localizedDescription; return }
        if enabled {
            schedule(); Task { await enableDelivery(); await sync() }
        } else {
            syncRun.cancelAll()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            Task {
                for type in observedTypes { try? await health.disableBackgroundDelivery(for: type) }
                if journal.automatic { await enableDelivery() }
            }
        }
    }

    func foreground() {
        if let restored = journalFile.reloadIfAvailable() { journal = restored; problem = nil; started = false; start() }
        authorized = health.authorizationStatus(for: steps) == .sharingAuthorized
        if journal.automatic {
            registerObserver()
            schedule()
            Task { await enableDelivery(); await sync(force: true) }
        }
    }

    @discardableResult func sync(force: Bool = false) async -> Bool {
        guard !connecting else { return false }
        if force { forceNextPass = true }
        if syncRun.isRunning { followUp = true }
        return await syncRun.run()
    }

    private func performSync(force: Bool) async {
        guard journalHealthy else { return }
        guard !isSimulator else { status = "Connect your iPhone to sync real steps."; return }
        guard authorized else { status = "Enable Apple Health to save measured steps."; return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            status = "Waiting for iPhone to unlock so saved steps can be checked safely."; return
        }
        problem = nil
        do {
            let account = try await google.userID(); email = google.email
            if let bound = journal.account, bound != account {
                throw ProofError.message("This phone's import journal belongs to a different Google Health account. No steps were added.")
            }
            guard journal.entries.values.allSatisfy({ $0.walk.userID == account }) else {
                throw ProofError.message("Saved step records belong to a different Google Health account. No steps were changed.")
            }
            journal.account = account; try persist()
            var imported = 0; var adopted = 0
            let now = Date()
            var candidates: [String: PadStepImport] = [:]
            let feedURL = URL.applicationSupportDirectory.appendingPathComponent("measured-walk-feed.json")
            if FileManager.default.fileExists(atPath: feedURL.path) {
                guard let text = Bundle.main.object(forInfoDictionaryKey: "PadStepsCorrectionPublicKey") as? String,
                      let key = Data(base64Encoded: text) else { throw ProofError.message("This iPhone is not paired with the Mac's measured-step feed.") }
                let localWalks = try MeasuredWalkFeed.imports(Data(contentsOf: feedURL), publicKey: key, account: account, clientID: Bundle.main.object(forInfoDictionaryKey: "PadStepsRecorderClientID") as? String ?? "")
                for walk in localWalks where walk.start >= journal.startedFrom && walk.end <= now { candidates[walk.id] = walk }
            } else {
                // Legacy fallback. A verified local feed is the authoritative full
                // measurement source, so do not also process its workout carriers.
                let left = max(journal.startedFrom, now.addingTimeInterval(-3 * 86400))
                for walk in try await google.walks(from: left, to: now, account: account) { candidates[walk.id] = walk }
                journal.checkedThrough = now; try persist()
            }
            // An interrupted write must remain recoverable even if its source
            // workout or old feed entry is no longer returned.
            for entry in journal.entries.values where entry.pendingExport != nil || entry.state == "attempted" {
                if candidates[entry.id] == nil { candidates[entry.id] = entry.walk }
            }
            let checks = candidates.values.map { walk in
                let old = journal.entries[walk.id]
                return StepCheckCandidate(walk: walk, state: old?.state, checkedAt: old?.checkedAt,
                    attemptedAt: old?.lastAttemptAt, hasPendingWrite: old?.pendingExport != nil,
                    measurementsChanged: old.map { !$0.walk.hasSameMeasurements(as: walk) } ?? false)
            }
            for walk in StepCheckSchedule.due(checks, now: now, force: force) {
                try Task.checkCancellation()
                var attempt = journal.entries[walk.id] ?? StepSyncEntry(walk: walk, state: "ready", note: "Waiting for the initial step check.", checkedAt: .distantPast, sampleCount: 0)
                attempt.lastAttemptAt = Date(); journal.entries[walk.id] = attempt; try persist()
                let result = try await importSteps(walk)
                if result == "saved" { imported += 1 }
                if result == "adopted" { adopted += 1 }
            }
            dailySteps = try await mergedDailySteps()
            workoutsReadable = try await readableWorkoutCount()
            lastChecked = Date()
            status = imported > 0 ? "Saved \(imported) walk's steps to Apple Health." : (adopted > 0 ? "Existing steps verified. No extra copies added." : "Up to date. Waiting for the next measured walk from your Mac.")
            if entries.contains(where: { $0.state == "review" }) {
                problem = "A walk needs review. Its steps were not added again."
            }
        } catch is CancellationError { status = "Sync paused. It will retry on the next background check or app open." }
        catch {
            problem = error.localizedDescription
            status = journal.automatic ? "Check incomplete. Saved steps are preserved; automatic checks will retry." : "Check incomplete. Saved steps are preserved; tap Sync now to retry."
        }
    }

    private func importSteps(_ walk: PadStepImport) async throws -> String {
        if exportsMissingSteps { return try await importTopUp(walk) }
        let old = journal.entries[walk.id]
        if old?.state == "trial" || old?.exported != nil {
            journal.entries[walk.id]?.state = "review"
            journal.entries[walk.id]?.note = "This walk has a revised export. Its existing steps are preserved when switching export modes."
            try persist(); return "review"
        }
        if let old, !old.walk.hasSameMeasurements(as: walk) {
            journal.entries[walk.id]?.state = "review"
            journal.entries[walk.id]?.note = "Google's counters or interval changed. The existing steps were preserved."
            try persist(); return "review"
        }
        let samples = try await ownSamples(walk)
        let confirmed = old?.state == "confirmed" || old?.state == "review"
        let records = samples.map { SavedStepRecord(start: $0.startDate, end: $0.endDate, steps: Int($0.quantity.doubleValue(for: .count()).rounded())) }
        switch walk.decision(existing: records, previouslyConfirmed: confirmed) {
        case .review:
            journal.entries[walk.id] = .init(walk: walk, state: "review", note: "Existing steps differ, are duplicated, or are no longer readable. No replacement saved.", checkedAt: Date(), sampleCount: samples.count)
            try persist(); return "review"
        case .adopt:
            journal.entries[walk.id] = .init(walk: walk, state: "confirmed", note: "One existing step record verified; nothing added.", checkedAt: Date(), sampleCount: 1)
            try persist(); return "adopted"
        case .save:
            guard health.authorizationStatus(for: steps) == .sharingAuthorized else {
                throw ProofError.message("Steps write access was disabled. Enable it in Apple Health.")
            }
            journal.entries[walk.id] = .init(walk: walk, state: "attempted", note: "Saving with a stable walk identifier.", checkedAt: Date(), sampleCount: 0)
            try persist()
            try Task.checkCancellation()
            let device = HKDevice(name: "Sperax P2 Max", manufacturer: "Sperax", model: "P2 Max", hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
            let sample = HKQuantitySample(type: steps, quantity: .init(unit: .count(), doubleValue: Double(walk.steps)), start: walk.start, end: walk.end, device: device,
                metadata: [HKMetadataKeySyncIdentifier: walk.syncIdentifier, HKMetadataKeySyncVersion: 1, HKMetadataKeyTimeZone: TimeZone.current.identifier])
            try await health.save(sample)
            let found = try await ownSamples(walk)
            let readback = found.map { SavedStepRecord(start: $0.startDate, end: $0.endDate, steps: Int($0.quantity.doubleValue(for: .count()).rounded())) }
            guard walk.decision(existing: readback, previouslyConfirmed: true) == .adopt else {
                // Do not create another sample when read permission is denied or the write is uncertain.
                journal.entries[walk.id]?.state = "review"; try persist()
                throw ProofError.message("Steps were submitted but readback could not verify one copy. Allow Steps read access before retrying.")
            }
            journal.entries[walk.id] = .init(walk: walk, state: "confirmed", note: "Saved and read back one step record.", checkedAt: Date(), sampleCount: 1)
            try persist(); return "saved"
        }
    }

    private func importTopUp(_ walk: PadStepImport) async throws -> String {
        let old = journal.entries[walk.id]
        guard old == nil || old!.walk.hasSameMeasurements(as: walk) else {
            journal.entries[walk.id]?.state = "review"
            journal.entries[walk.id]?.note = "Google's pad measurements changed. The existing export was preserved."
            try persist(); return "review"
        }
        let googleCount = try await google.recordedSteps(for: walk)
        var samples = try await ownSamples(walk)
        let records = samples.map { VersionedStepRecord(start: $0.startDate, end: $0.endDate,
            steps: Int($0.quantity.doubleValue(for: .count()).rounded()),
            version: ($0.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue ?? 0) }
        var prior = old?.exported
        // Migrate only a verified, explicitly requested private trial. Other unexpected quantities stay protected.
        if prior == nil, old?.state == "trial", let sample = samples.first, samples.count == 1,
           (sample.metadata?["PadStepsMeasuredSteps"] as? NSNumber)?.intValue == walk.steps,
           sample.metadata?["PadStepsTrialID"] as? String != nil, let record = records.first {
            prior = StepExportLedger(steps: record.steps, version: record.version)
        }
        var entry = old ?? StepSyncEntry(walk: walk, state: "ready", note: "", checkedAt: Date(), sampleCount: 0)
        entry.walk = walk
        entry.googleSteps = googleCount.count; entry.googleHadNoRecords = googleCount.noRecords; entry.googleCheckedAt = Date()
        var firstRead = true
        let outcome = try await StepExportTransaction.perform(walk: walk, googleSteps: googleCount.count,
            prior: prior, pending: old?.pendingExport,
            legacyConfirmed: old.map { ["confirmed", "review", "trial", "attempted"].contains($0.state) } ?? false,
            read: {
                if firstRead { firstRead = false } else { samples = try await self.ownSamples(walk) }
                return samples.map { VersionedStepRecord(start: $0.startDate, end: $0.endDate,
                    steps: Int($0.quantity.doubleValue(for: .count()).rounded()),
                    version: ($0.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue ?? 0) }
            }, write: { count, version in
                guard self.health.authorizationStatus(for: self.steps) == .sharingAuthorized else {
                    throw ProofError.message("Steps write access was disabled. Enable it in Apple Health.")
                }
                var metadata = samples.first?.metadata ?? [:]
                metadata[HKMetadataKeySyncIdentifier] = walk.syncIdentifier; metadata[HKMetadataKeySyncVersion] = version
                metadata[HKMetadataKeyTimeZone] = TimeZone.current.identifier
                metadata["PadStepsMeasuredSteps"] = walk.steps; metadata["PadStepsGoogleSteps"] = googleCount.count
                metadata["PadStepsExportMode"] = "missing-google"; metadata.removeValue(forKey: "PadStepsTrialID")
                let device = samples.first?.device ?? HKDevice(name: "Sperax P2 Max", manufacturer: "Sperax", model: "P2 Max",
                    hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
                let sample = HKQuantitySample(type: self.steps, quantity: .init(unit: .count(), doubleValue: Double(count)),
                    start: walk.start, end: walk.end, device: device, metadata: metadata)
                try await self.health.save(sample)
            }, remove: {
                guard samples.count == 1, let sample = samples.first else { throw ProofError.message("The redundant top-up could not be identified safely.") }
                try await self.health.delete(sample)
            }, persistIntent: { intent in
                entry.pendingExport = intent; entry.state = "attempted"
                entry.note = intent.steps == 0 ? "Google now covers the walk; removing only this app's redundant top-up." : "Updating the same step record to the measured shortfall."
                self.journal.entries[walk.id] = entry; try self.persist()
            })
        let completed: StepExportLedger
        let wrote: Bool
        switch outcome {
        case .review(let reason):
            entry.state = "review"; entry.note = reason
            journal.entries[walk.id] = entry; try persist(); return "review"
        case .complete(let ledger, let changed): completed = ledger; wrote = changed
        }
        entry.exported = completed; entry.pendingExport = nil; entry.checkedAt = Date()
        entry.sampleCount = completed.steps == 0 ? 0 : 1; entry.state = completed.steps == 0 ? "covered" : "confirmed"
        entry.note = "\(walk.steps) pad − \(googleCount.count) Google = \(max(0, walk.steps - googleCount.count)) missing; \(completed.steps) exported."
        if googleCount.noRecords { entry.note += " Google has no step records yet; later syncs recheck this count." }
        if googleCount.count > walk.steps { entry.note += " Google's count exceeds the pad; no negative correction was invented." }
        if completed.steps != max(0, walk.steps - googleCount.count) {
            entry.checkedAt = .distantPast; entry.lastAttemptAt = nil; followUp = true
        }
        journal.entries[walk.id] = entry; try persist()
        return wrote ? "saved" : "adopted"
    }

    private func ownSamples(_ walk: PadStepImport) async throws -> [HKQuantitySample] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [HKQuery.predicateForObjects(from: .default()), HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [walk.syncIdentifier])])
        return try await withCheckedThrowingContinuation { continuation in
            health.execute(HKSampleQuery(sampleType: steps, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples as? [HKQuantitySample] ?? []) }
            })
        }
    }

    private func mergedDailySteps() async throws -> Int? {
        let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.startOfDay(for: Date()), end: Date())
        return try await withCheckedThrowingContinuation { continuation in
            health.execute(HKStatisticsQuery(quantityType: steps, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: stats?.sumQuantity().map { Int($0.doubleValue(for: .count()).rounded()) }) }
            })
        }
    }

    private func readableWorkoutCount() async throws -> Int {
        let predicate = HKQuery.predicateForSamples(withStart: journal.startedFrom, end: Date())
        let walks = journal.entries.values.map(\.walk)
        return try await withCheckedThrowingContinuation { continuation in
            health.execute(HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else {
                    let matching = (samples as? [HKWorkout] ?? []).filter { workout in
                        walks.contains { abs($0.start.timeIntervalSince(workout.startDate)) < 10 && abs($0.end.timeIntervalSince(workout.endDate)) < 10 }
                    }
                    continuation.resume(returning: matching.count)
                }
            })
        }
    }

    private func persist() throws {
        journal.schemaVersion = 1
        try journalFile.save(journal)
        objectWillChange.send()
    }

    private func diagnostic() {
        var value: [String: Any] = ["status": status, "automatic": journal.automatic, "busy": busy,
            "checkedAt": ISO8601DateFormatter().string(from: Date()), "workoutsReadable": workoutsReadable,
            "confirmedWalks": entries.filter { $0.state == "confirmed" }.count,
            "records": entries.map { ["id": $0.id, "steps": $0.exported?.steps ?? $0.walk.steps, "measuredSteps": $0.walk.steps,
                "googleSteps": $0.googleSteps.map { $0 as Any } ?? NSNull(), "syncVersion": $0.exported.map { $0.version as Any } ?? NSNull(), "sampleCount": $0.sampleCount, "state": $0.state, "note": $0.note] as [String: Any] }]
        value["exportMode"] = exportsMissingSteps ? "missing-google" : "full"
        value["backgroundTypes"] = backgroundTypes
        value["observerTypes"] = Array(observers.keys).sorted()
        value["backgroundStatus"] = backgroundStatus
        if let problem { value["problem"] = problem }
        if let dailySteps { value["dailySteps"] = dailySteps }
        try? FileManager.default.createDirectory(at: diagnosticURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: diagnosticURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private var observedTypes: [HKSampleType] {
        var types: [HKSampleType] = [steps]
        if UserDefaults.standard.bool(forKey: "padsteps.workoutReadRequested") { types.append(HKObjectType.workoutType()) }
        return types
    }

    private func registerObserver() {
        guard !isSimulator, authorized else { return }
        for type in observedTypes where observers[type.identifier] == nil {
            // Google/iPhone step changes can wake catch-up; our own exports must not trigger a sync loop.
            let predicate = type.identifier == steps.identifier
                ? NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: .default())) : nil
            let identifier = type.identifier
            let query = HKObserverQuery(sampleType: type, predicate: predicate) { [weak self] query, completion, error in
                Task { @MainActor in
                    defer { completion() }
                    guard let self else { return }
                    guard error == nil else { self.health.stop(query); self.observers[identifier] = nil; return }
                    guard self.journal.automatic else { return }
                    let work = Task { await self.sync() }
                    let deadline = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(25))
                        if !Task.isCancelled { work.cancel() }
                    }
                    defer { deadline.cancel() }
                    _ = await work.value
                }
            }
            observers[identifier] = query; health.execute(query)
        }
    }

    private func enableDelivery() async {
        guard authorized, journal.automatic, !isSimulator else { return }
        backgroundTypes = []
        for type in observedTypes {
            do {
                let frequency: HKUpdateFrequency = type.identifier == steps.identifier ? .hourly : .immediate
                try await health.enableBackgroundDelivery(for: type, frequency: frequency)
                if !journal.automatic { try? await health.disableBackgroundDelivery(for: type); continue }
                backgroundTypes.append(type.identifier)
            } catch { continue }
        }
        backgroundStatus = backgroundTypes.isEmpty
            ? "Health wake unavailable. App-open and scheduled checks remain available."
            : "Health changes can wake catch-up. iOS schedules background checks; opening PadSteps checks immediately."
    }

    func schedule() {
        guard journal.automatic, !isSimulator else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { backgroundStatus = "iOS background refresh is unavailable. Opening PadSteps still syncs automatically." }
    }

    func handle(_ task: BGAppRefreshTask) {
        guard journal.automatic else { task.setTaskCompleted(success: true); return }
        schedule()
        let work = Task { let completed = await sync(); task.setTaskCompleted(success: completed && !Task.isCancelled && problem == nil) }
        task.expirationHandler = { work.cancel() }
    }
}
