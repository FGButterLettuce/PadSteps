import SwiftUI
import ServiceManagement
import PadStepsCore

@main
struct PadStepsDesktopApp: App {
    @StateObject private var monitor = PadMonitor()
    var body: some Scene {
        Window("PadSteps", id: "main") {
            DesktopView(monitor: monitor, google: monitor.google)
                .task {
                    await monitor.google.verifyConnection()
                    if ProcessInfo.processInfo.arguments.contains("--prepare-google-sign-in") {
                        await monitor.google.prepareSignIn()
                    }
                }
        }
        .defaultSize(width: 640, height: 660)
        .windowResizability(.contentMinSize)
        MenuBarExtra("PadSteps", systemImage: monitor.state.recorder.active == nil ? "figure.walk" : "figure.walk.motion") {
            MenuContent(monitor: monitor)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: PadMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(monitor.connection)
        if let walk = monitor.state.recorder.active { Text("\(walk.steps.formatted()) steps • \(duration(walk.seconds))") }
        let pending = monitor.state.walks.filter(\.needsSync).count
        if pending > 0 { Text("\(pending) workout\(pending == 1 ? "" : "s") waiting to sync") }
        Divider()
        Button("Open PadSteps") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Sync saved walks") { monitor.retrySync() }
            .disabled(!monitor.google.connected || monitor.syncing)
        Divider()
        Button("Quit PadSteps") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

struct DesktopView: View {
    @ObservedObject var monitor: PadMonitor
    @ObservedObject var google: GoogleConnection
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var settingsError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(monitor.state.recorder.active == nil ? "Ready when you walk" : "Recording your walk", systemImage: "figure.walk")
                        .font(.title2.weight(.semibold))
                    Label(monitor.connection, systemImage: monitor.linked ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(monitor.linked ? Color.primary : Color.secondary)
                    Text("Start and stop with the pad’s remote. PadSteps saves the workout after Fitbit heart rate syncs.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if let error = monitor.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }

                if let walk = monitor.state.recorder.active {
                    GroupBox("Current walk") {
                        Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 12) {
                            GridRow { Text("Pad steps"); Text(walk.steps.formatted()).monospacedDigit() }
                            GridRow { Text("Distance"); Text(walk.metres, format: .number.precision(.fractionLength(0))).monospacedDigit(); Text("metres").foregroundStyle(.secondary) }
                            GridRow { Text("Pad time"); Text(duration(walk.seconds)).monospacedDigit() }
                            GridRow { Text("Heart rate"); Text("Added after you stop").foregroundStyle(.secondary) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Connections") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("Google Health", systemImage: google.connected ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                                    .font(.headline)
                                Text(google.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button(google.connected ? "Reconnect…" : "Connect…") { Task { await google.prepareSignIn() } }
                                .disabled(google.authorizationURL != nil)
                        }
                        if let url = google.authorizationURL {
                            HStack {
                                Link("Open Google sign-in", destination: url)
                                Button("Copy sign-in link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                            }
                            Text("Approve workout read/write and health-metrics read access. Google access is stored in this Mac’s Keychain.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Divider()
                        if monitor.automaticallyReusesFitbitWalks {
                            Text("Automatically reuse one matching Fitbit Air workout. Other overlaps stay available for review.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("Connect to the pad automatically", isOn: Binding(get: { monitor.state.monitoring }, set: monitor.setMonitoring))
                        Toggle("Open PadSteps at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                                do {
                                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                    settingsError = SMAppService.mainApp.status == .requiresApproval
                                        ? "Allow PadSteps in System Settings → General → Login Items to finish enabling automatic launch." : nil
                                } catch { settingsError = "Couldn’t change login settings. Check System Settings → General → Login Items." }
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }))
                        if let settingsError {
                            Text(settingsError).foregroundStyle(.red)
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }.padding(12)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Walks").font(.headline)
                        Spacer()
                        Button { monitor.retrySync() } label: { Label("Sync now", systemImage: "arrow.clockwise") }
                            .disabled(!google.connected || monitor.syncing)
                    }
                    if monitor.state.walks.isEmpty {
                        Text("Your first walk will appear here when the pad stops.")
                            .foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(monitor.state.walks) { walk in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(walk.exportEnd, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.headline)
                                Spacer()
                                Label(status(walk), systemImage: walk.status == "saved" ? "checkmark.circle" : "clock")
                                    .foregroundStyle(walk.status == "saved" ? Color.primary : Color.secondary)
                            }
                            Text("\(walk.steps.formatted()) steps · \(Double(walk.metres) / 1000, format: .number.precision(.fractionLength(2))) km · \(duration(walk.seconds))\(walk.averageBPM.map { " · \($0) bpm" } ?? "")")
                                .monospacedDigit()
                            Text(walk.issue ?? walk.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if walk.status == "saved" {
                                Button("Compare step sources") { Task { await monitor.auditStepSources(walk.id) } }
                                    .disabled(!google.connected || monitor.syncing)
                                if let summary = monitor.sourceAuditSummary[walk.id] {
                                    Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            if walk.hasOverlapReview || walk.canReviewCorrection {
                                OverlapReviewView(monitor: monitor, walk: walk)
                            } else if walk.status == "verifying" || walk.status == "attempted" {
                                Button("Check save confirmation") { monitor.retrySync() }
                                    .disabled(!google.connected || monitor.syncing)
                            }
                        }.padding(.vertical, 8)
                        Divider()
                    }
                }
                Text("Keep this Mac awake and nearby, and close SPX Fitness. You can close this window; PadSteps stays in the menu bar. Fitbit Air still needs to sync with Google Health on your iPhone.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Show saved data in Finder") { NSWorkspace.shared.open(monitor.directory) }
                    .buttonStyle(.link)
            }.padding(28)
        }
        .frame(minWidth: 540, minHeight: 520)
        .toolbar { ToolbarItem { Label("PadSteps", systemImage: "figure.walk").foregroundStyle(.secondary) } }
    }

    private func status(_ walk: AutomaticWalk) -> String {
        switch walk.status {
        case "saved": return "Saved"
        case "waitingHeartRate": return "Waiting for Fitbit"
        case "ready": return monitor.syncingWalkID == walk.id ? "Saving" : (google.connected ? "Queued to save" : "Sign-in needed")
        case "attempted", "verifying": return monitor.syncingWalkID == walk.id ? "Checking save" : "Confirmation pending"
        case "review": return "Needs review"
        default: return "Recorded"
        }
    }
}

private func duration(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}


/// Inline review keeps the measurements and their recovery actions together.
private struct OverlapReviewView: View {
    @ObservedObject var monitor: PadMonitor
    let walk: AutomaticWalk
    @State private var expanded = true
    @State private var correction: WorkoutConflict?
    private var disabled: Bool { monitor.syncing || !monitor.google.connected }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Check again") { monitor.recheck(walk.id) }.disabled(disabled)
                Button("Compare steps") { Task { await monitor.inspectOverlap(walk.id) } }.disabled(disabled)
                if monitor.syncingWalkID == walk.id { ProgressView().controlSize(.small); Text("Checking Google…").foregroundStyle(.secondary) }
            }
            Text(walk.canReviewCorrection ? "Google has not confirmed the update. Check again reads the same workout; Compare steps lets you review it before retrying the update. Neither action creates another workout." : walk.resourceName == nil ? "Deleted the overlapping workout? Check again will verify it is gone, then save this walk." : "Keep the measured PadSteps workout in Google Health. After removing the extra workout there, choose Check again to verify.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let report = monitor.overlapReports[walk.id] {
                DisclosureGroup("Step comparison", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pad interval: \(walk.start.formatted(date: .abbreviated, time: .standard)) – \(walk.exportEnd.formatted(date: .omitted, time: .standard))")
                            .font(.callout).textSelection(.enabled)
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                            GridRow { Text("Measured by pad"); Text(walk.steps.formatted()).monospacedDigit() }
                            GridRow { Text("Google steps in this interval"); Text(report.comparison.recorded.map { $0.formatted() } ?? "Unknown").monospacedDigit() }
                            GridRow { Text("Missing from Google's count"); Text(report.comparison.missing.map { $0.formatted() } ?? "Unknown").monospacedDigit() }
                        }
                        if let excess = report.comparison.excess, excess > 0 {
                            Text("Google reports \(excess.formatted()) more steps than the pad in this interval.")
                        }
                        if let error = report.intervalError { Text(error).foregroundStyle(.secondary) }
                        if report.workouts.isEmpty {
                            Text(walk.canReviewCorrection ? "The update target is not visible. The original pad walk is preserved; no replacement workout will be created automatically." : walk.resourceName == nil ? "No overlapping workout remains. Choose Check again to save the measured walk." : "No extra overlapping workout remains. Choose Check again to verify the saved PadSteps workout.")
                        }
                        ForEach(report.workouts) { conflict in
                            VStack(alignment: .leading, spacing: 7) {
                                Text("\(conflict.source) · \(conflict.type.replacingOccurrences(of: "_", with: " ").capitalized)").font(.headline)
                                Text("\(conflict.start.formatted(date: .omitted, time: .standard)) – \(conflict.end.formatted(date: .omitted, time: .standard)) · \(conflict.steps.map { "\($0.formatted()) workout steps" } ?? "Workout steps unknown")")
                                    .monospacedDigit().textSelection(.enabled)
                                if (walk.resourceName == nil || walk.correctionTarget == conflict.id), report.workouts.count == 1, conflict.coversSameWalk(walk), walk.averageBPM != nil {
                                    Button(walk.canReviewCorrection ? "Retry using pad totals…" : "Use pad totals for this workout…") { correction = conflict }.disabled(disabled)
                                } else {
                                    Text("This is a partial, different, or multiple-workout overlap. Resolve it in Google Health, then Check again; whole-walk pad totals cannot be applied safely here.")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Correcting a workout sets its total to the pad count; it does not create another workout or add daily Google steps. The iPhone sync keeps one measured pad step record in Apple Health. Keep PadSteps above other step sources there.")
                            .foregroundStyle(.secondary)
                        Text("Checked \(report.checkedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
            }
        }
        .alert("Correct this existing workout?", isPresented: Binding(get: { correction != nil }, set: { if !$0 { correction = nil } })) {
            if let conflict = correction {
                Button("Use \(walk.steps.formatted()) pad steps") {
                    Task { await monitor.correctExistingWorkout(walkID: walk.id, conflict: conflict) }
                    correction = nil
                }
            }
            Button("Cancel", role: .cancel) { correction = nil }
        } message: {
            Text("Replace this workout’s steps, distance, times, duration and average heart rate with the pad walk and synced Fitbit heart rate. Existing splits and pause events will be removed because their times may differ. One Google workout remains. Daily Google steps are separate; Apple Health steps sync through the paired iPhone app.")
        }
    }
}
