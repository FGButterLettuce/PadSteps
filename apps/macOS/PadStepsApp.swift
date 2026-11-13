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
