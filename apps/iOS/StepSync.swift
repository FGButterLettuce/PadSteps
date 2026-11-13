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
    var id: String { walk.id }
}

struct StepSyncJournal: Codable {
    var startedFrom = Calendar.current.startOfDay(for: Date())
    var checkedThrough: Date?
    var account: String?
    var automatic = true
    var entries: [String: StepSyncEntry] = [:]
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
    private var observer: HKObserverQuery?
    private var activeTask: Task<Void, Never>?
    private var followUp = false
    private var journalHealthy = true
    private var started = false
    private let journalURL = URL.applicationSupportDirectory.appendingPathComponent("step-sync-journal.json")
    private let diagnosticURL = URL.applicationSupportDirectory.appendingPathComponent("step-sync-status.json")

    var entries: [StepSyncEntry] { journal.entries.values.sorted { $0.walk.start > $1.walk.start } }
    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private init() {
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do { journal = try JSONDecoder().decode(StepSyncJournal.self, from: Data(contentsOf: journalURL)) }
            catch {
                journal = StepSyncJournal(); journalHealthy = false
                problem = "The saved import journal could not be read. Sync is paused to protect existing steps."
            }
        } else { journal = StepSyncJournal() }
        authorized = health.authorizationStatus(for: steps) == .sharingAuthorized
    }

    func start() {
        guard !started else { return }
        started = true
        registerObserver()
        schedule()
        Task {
            try? await google.restore()
            email = google.email
            if journal.automatic { await sync() }
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
        journal.automatic = enabled
        do { try persist() }
        catch { problem = error.localizedDescription; return }
        if enabled {
            schedule(); Task { await enableDelivery(); await sync() }
        } else {
            activeTask?.cancel()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            Task { try? await health.disableBackgroundDelivery(for: HKObjectType.workoutType()) }
        }
    }

    func foreground() {
        authorized = health.authorizationStatus(for: steps) == .sharingAuthorized
        if journal.automatic {
            registerObserver()
            schedule()
            Task { await enableDelivery(); await sync() }
        }
    }

    func sync() async {
        guard !connecting else { return }
        if let activeTask {
            followUp = true
            await withTaskCancellationHandler { await activeTask.value } onCancel: { activeTask.cancel() }
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            self.busy = true
            defer { self.busy = false; self.activeTask = nil; self.diagnostic() }
            for pass in 0..<2 {
                self.followUp = false
                await self.performSync()
                if !self.followUp || Task.isCancelled || pass == 1 { break }
            }
        }
        activeTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func performSync() async {
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
            journal.account = account; try persist()
            let now = Date()
            var left = max(journal.startedFrom, (journal.checkedThrough ?? journal.startedFrom).addingTimeInterval(-3 * 86400))
            var imported = 0; var adopted = 0
            while left < now {
                try Task.checkCancellation()
                let right = min(now, left.addingTimeInterval(7 * 86400))
                let walks = try await google.walks(from: left, to: right, account: account)
                for walk in walks {
                    try Task.checkCancellation()
                    let result = try await importSteps(walk)
                    if result == "saved" { imported += 1 }
                    if result == "adopted" { adopted += 1 }
                }
                journal.checkedThrough = right; try persist()
                left = right
            }
            dailySteps = try await mergedDailySteps()
            workoutsReadable = try await readableWorkoutCount()
            lastChecked = Date()
            status = imported > 0 ? "Saved \(imported) walk's steps to Apple Health." : (adopted > 0 ? "Existing steps verified. No extra copies added." : "Up to date. Waiting for the next PadSteps Google workout.")
            if entries.contains(where: { $0.state == "review" }) {
                problem = "A walk needs review. Its steps were not added again."
            }
        } catch is CancellationError { status = "Sync paused. It will retry on the next background check or app open." }
        catch { problem = error.localizedDescription }
    }

    private func importSteps(_ walk: PadStepImport) async throws -> String {
        let old = journal.entries[walk.id]
        if let old, old.walk != walk {
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
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        objectWillChange.send()
    }

    private func diagnostic() {
        var value: [String: Any] = ["status": status, "automatic": journal.automatic, "busy": busy,
            "checkedAt": ISO8601DateFormatter().string(from: Date()), "workoutsReadable": workoutsReadable,
            "confirmedWalks": entries.filter { $0.state == "confirmed" }.count,
            "records": entries.map { ["id": $0.id, "steps": $0.walk.steps, "sampleCount": $0.sampleCount, "state": $0.state, "note": $0.note] as [String: Any] }]
        if let problem { value["problem"] = problem }
        if let dailySteps { value["dailySteps"] = dailySteps }
        try? FileManager.default.createDirectory(at: diagnosticURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: diagnosticURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func registerObserver() {
        guard observer == nil, !isSimulator, UserDefaults.standard.bool(forKey: "padsteps.workoutReadRequested") else { return }
        let query = HKObserverQuery(sampleType: HKObjectType.workoutType(), predicate: nil) { [weak self] _, completion, error in
            Task { @MainActor in
                defer { completion() }
                guard let self else { return }
                guard error == nil else { self.observer = nil; return }
                guard self.journal.automatic else { return }
                let deadline = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(25))
                    if !Task.isCancelled { self.activeTask?.cancel() }
                }
                defer { deadline.cancel() }
                await self.sync()
            }
        }
        observer = query; health.execute(query)
    }

    private func enableDelivery() async {
        guard authorized, journal.automatic, !isSimulator,
              UserDefaults.standard.bool(forKey: "padsteps.workoutReadRequested") else { return }
        do {
            try await health.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate)
            backgroundStatus = "Workout changes can wake sync. Other checks run when iOS allows."
        } catch { backgroundStatus = "Workout wake unavailable. App-open and scheduled checks remain available." }
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
        let work = Task { await sync(); task.setTaskCompleted(success: !Task.isCancelled && problem == nil) }
        task.expirationHandler = { work.cancel() }
    }
}
