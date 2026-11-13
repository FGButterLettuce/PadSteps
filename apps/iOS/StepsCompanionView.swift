import SwiftUI
import GoogleSignIn
import BackgroundTasks

@main
struct PadStepsCompanionApp: App {
    @UIApplicationDelegateAdaptor(StepSyncDelegate.self) private var delegate
    @StateObject private var sync = StepSync.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            StepsCompanionView(sync: sync)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in sync.foreground() }
                .task { sync.start() }
        }
        .onChange(of: phase) { _, value in
            if value == .active { sync.foreground() }
            if value == .background { sync.schedule() }
        }
    }
}

final class StepSyncDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: StepSync.taskID, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in StepSync.shared.handle(task) }
        }
        StepSync.shared.start()
        return true
    }
}

struct StepsCompanionView: View {
    @ObservedObject var sync: StepSync
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(sync.status).accessibilityIdentifier("sync.status")
                    if sync.busy { ProgressView("Checking measured steps…") }
                    if sync.connecting { ProgressView("Connecting Google Health…") }
                    if let problem = sync.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).accessibilityIdentifier("sync.problem")
                    }
                    if let last = sync.lastChecked {
                        LabeledContent("Last checked") { Text(last, style: .time) }
                    }
                    Button("Sync now") { Task { await sync.sync() } }
                        .frame(minHeight: 44).disabled(sync.busy || sync.connecting || sync.email == nil || !sync.authorized)
                } header: { Text("Step sync") }
                footer: { Text("The Mac saves your workout and heart rate to Google Health. This iPhone saves only the walk's measured steps to Apple Health.") }

                Section {
                    if let email = sync.email {
                        LabeledContent("Google Health") { Text(email).textSelection(.enabled) }
                        Button("Reconnect Google Health") { Task { await sync.connectGoogle() } }
                            .frame(minHeight: 44).disabled(sync.busy || sync.connecting)
                    } else {
                        Button("Connect Google Health") {
                            Task { await sync.connectGoogle() }
                        }
                        .frame(minHeight: 44).disabled(sync.busy || sync.connecting || sync.isSimulator)
                    }
                    Button(sync.authorized ? "Review Apple Health access" : "Enable Apple Health") {
                        Task { await sync.connectHealth() }
                    }.frame(minHeight: 44).disabled(sync.busy || sync.connecting || sync.isSimulator)
                    Toggle("Automatic step syncing", isOn: Binding(get: { sync.journal.automatic }, set: { sync.setAutomatic($0) }))
                } header: { Text("Connections") }
                footer: { Text("Allow Steps read and write access. Workouts are read only to wake syncing; no workout or heart-rate copy is created.") }

                Section {
                    LabeledContent("Apple Health daily steps", value: sync.dailySteps?.formatted() ?? "Not checked")
                    Text("Keep PadSteps above Google Health in Apple Health → Steps → Data Sources & Access. This lets Apple Health prioritize the pad during overlapping intervals.")
                    Text("In Bevel, select Apple Health for Steps. Keep your existing workout and heart-rate connection.")
                } header: { Text("Avoid overlapping step sources") }
                footer: { Text("Each walk has one stable step record. Apple Health merges overlapping sources; Bevel's step-source selection must be checked separately.") }

                Section {
                    Text(sync.backgroundStatus)
                    Text("iOS chooses background timing. Leave Background App Refresh enabled and avoid force-quitting PadSteps. Opening it always checks for finished walks.")
                    if sync.workoutsReadable == 0, sync.authorized {
                        Text("No Apple Health workouts are readable yet. A Google workout wake is not confirmed; scheduled and app-open checks are available.")
                    }
                } header: { Text("Background checks") }

                if !sync.entries.isEmpty {
                    Section("Walks") {
                        ForEach(sync.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(entry.walk.steps.formatted()) steps").font(.headline)
                                Text(entry.walk.start, format: .dateTime.month().day().hour().minute()).font(.subheadline)
                                Label(entry.state == "confirmed" ? "Verified once in Apple Health" : "Needs review",
                                      systemImage: entry.state == "confirmed" ? "checkmark.circle" : "exclamationmark.triangle")
                                Text(entry.note).font(.footnote).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("PadSteps")
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if !Task.isCancelled, phase == .active, sync.journal.automatic { await sync.sync() }
                }
            }
        }
    }
}
