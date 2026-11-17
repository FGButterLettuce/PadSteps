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
                    Text("Start and stop with the pad’s remote. PadSteps fills time missing from Google’s workouts after Fitbit heart rate syncs.")
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
                        Text("Keeps Google's walking workouts and fills only uncovered time.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(monitor.relayStatus)
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                            if walk.canInspectGoogle {
                                OverlapReviewView(monitor: monitor, walk: walk)
                            } else if walk.status == "verifying" || walk.status == "attempted" {
                                Button("Check save confirmation") { monitor.retrySync() }
                                    .disabled(!google.connected || monitor.syncing)
                            }
                            if walk.status != "saved" { WalkRecoveryView(monitor: monitor, walk: walk) }
                            if walk.originalTotals != nil {
                                Text("Recovered from recorded readings after the pad was switched off or reset.")
                                    .font(.callout).foregroundStyle(.secondary)
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
        case "localOnly": return "Kept locally"
        case "empty": return "No walking recorded"
        default: return "Recorded"
        }
    }
}

private struct WalkRecoveryView: View {
    @ObservedObject var monitor: PadMonitor
    let walk: AutomaticWalk
    @State private var reviewingTotals = false
    @State private var omitHeartRate = false
    private var disabled: Bool { monitor.syncing }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if walk.canConfirmRecordedTotals {
                Text("The pad reset before its stop could be verified. Confirm the last readings, or enter the final totals if you noted them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Review recorded totals…") { reviewingTotals = true }.disabled(disabled)
            }
            if walk.canSaveWithoutHeartRate {
                HStack {
                    Button("Check Fitbit again") { monitor.retrySync() }.disabled(disabled || !monitor.google.connected)
                    Button("Save without heart rate…") { omitHeartRate = true }.disabled(disabled)
                }
            }
            if walk.canRetryRejectedSave {
                Button("Retry rejected save") { Task { await monitor.retryRejectedSave(walk.id) } }
                    .disabled(disabled || !monitor.google.connected)
            }
            if !(walk.gapExport?.rejectedCreations ?? []).isEmpty {
                Button("Retry rejected gap save") { monitor.retryRejectedGaps(walk.id) }.disabled(disabled || !monitor.google.connected)
            }
            HStack {
                if walk.canKeepLocal {
                    Button(walk.resourceName == nil ? "Keep locally for now" : "Pause checks for this walk") { monitor.keepLocal(walk.id) }.disabled(disabled)
                }
                if walk.canResumeChecks {
                    Button("Resume this walk") { monitor.resumeChecks(walk.id) }.disabled(disabled)
                }
                Button("Show walk files") { monitor.showWalkFiles(walk.id) }
            }
            if walk.status == "localOnly" {
                Text(walk.resourceName == nil ? "This recording is preserved locally. Resume it when you want to continue saving." : "Checking is paused. The existing Google workout and Apple Health steps have not been deleted.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $reviewingTotals) { RecordedTotalsReview(monitor: monitor, walk: walk) }
        .alert("Save without heart rate?", isPresented: $omitHeartRate) {
            Button("Save measured walk") { monitor.saveWithoutHeartRate(walk.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save the pad's measured steps, distance and time. No heart rate will be invented. Google’s native Fitbit heart-rate history stays available, but a workout summary or Strain may be incomplete. Any overlapping workout will still be checked first.")
        }
    }
}

private struct RecordedTotalsReview: View {
    @ObservedObject var monitor: PadMonitor
    let walk: AutomaticWalk
    @Environment(\.dismiss) private var dismiss
    @State private var steps: Int
    @State private var metres: Int
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var end: Date
    init(monitor: PadMonitor, walk: AutomaticWalk) {
        self.monitor = monitor; self.walk = walk
        _steps = State(initialValue: walk.steps); _metres = State(initialValue: walk.metres)
        _minutes = State(initialValue: walk.seconds / 60); _seconds = State(initialValue: walk.seconds % 60)
        _end = State(initialValue: walk.exportEnd)
    }
    private var totals: RecordedWalkTotals { .init(steps: steps, seconds: max(0, min(minutes, 1440)) * 60 + max(0, min(seconds, 59)), metres: metres, end: end) }
    private var valid: Bool {
        (0..<1440).contains(minutes) && (0..<60).contains(seconds) &&
        (try? walk.confirmingTotals(totals, at: Date())) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Recover this walk").font(.title2.weight(.semibold))
            Text("These are the last readings received before the pad reset. They may omit walking after the last update. Keep them as recorded, or enter larger final totals from the pad display.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Steps", value: $steps, format: .number)
                TextField("Distance (metres)", value: $metres, format: .number)
                TextField("Elapsed minutes", value: $minutes, format: .number)
                TextField("Elapsed seconds", value: $seconds, format: .number)
                DatePicker("Ended", selection: $end, in: walk.exportEnd...max(walk.exportEnd, Date()), displayedComponents: [.date, .hourAndMinute])
            }.textFieldStyle(.roundedBorder)
            if !valid { Text("Use totals at least as large as the recorded readings, with seconds from 0 to 59 and a valid end time.").foregroundStyle(.red).font(.callout) }
            Text("The original readings are preserved. Google’s existing workouts and Fitbit heart rate will be checked before saving.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Confirm and continue") { monitor.confirmTotals(walk.id, totals: totals); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid || monitor.syncing)
            }
        }.padding(24).frame(width: 460)
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
            Text(walk.canReviewCorrection || walk.canCheckUpload ? "Check again looks for the original save or reads the same workout. Compare steps shows Google's records. An uncertain save will never trigger another workout automatically." : walk.canRetryRejectedSave ? "Google reported a failed save. Retry rejected save verifies the failure and checks existing workouts before allowing another attempt." : walk.resourceName == nil ? "Deleted the overlapping workout? Check again will verify it is gone, then save this walk." : "Keep the measured PadSteps workout in Google Health. After removing the extra workout there, choose Check again to verify.")
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
                                if (walk.canRecheckOverlap || walk.correctionTarget == conflict.id || (walk.reviewKind == "savedMismatch" && walk.resourceName == conflict.id)), report.workouts.count == 1, conflict.coversSameWalk(walk), walk.averageBPM != nil {
                                    Button(walk.canReviewCorrection ? "Retry using pad totals…" : "Use pad totals for this workout…") { correction = conflict }.disabled(disabled)
                                } else {
                                    Text("This is a partial, different, or multiple-workout overlap. Resolve it in Google Health, then Check again; whole-walk pad totals cannot be applied safely here.")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Correcting a workout sets its total to the pad count; it does not create another workout or add daily Google steps. The paired iPhone exports only the steps missing from Google's count, using the same Apple Health record.")
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
