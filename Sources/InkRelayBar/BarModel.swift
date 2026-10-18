import AppKit
import InkRelayCore
import ServiceManagement
import SwiftUI

@MainActor
final class BarModel: ObservableObject {
    @Published private(set) var snapshot = RelayRunner.Snapshot()
    @Published private(set) var agentRunning = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// A newer InkRelay the daily check found.
    @Published private(set) var update: ReleaseInfo?

    let runner: RelayRunner

    /// `--config PATH` at launch (or INKRELAY_CONFIG) points the app at another config, as with the command.
    nonisolated static var launchConfigURL: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--config"), arguments.indices.contains(flag + 1) {
            return URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath)
        }
        if let path = ProcessInfo.processInfo.environment["INKRELAY_CONFIG"] {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return InkRelayCore.defaultConfigURL
    }

    init(configURL: URL? = nil) {
        runner = RelayRunner(configURL: configURL ?? Self.launchConfigURL)
        runner.onChange = { [weak self] snapshot in
            Task { @MainActor in self?.take(snapshot) }
        }
        Notifier.shared.prepare()
        Notifier.shared.onOpenReview = { [weak self] in self?.open(self?.snapshot.reviewURL) }
        scheduleUpdateChecks()
        agentRunning = Self.isAgentLoaded()
        // Two engines writing the same state would duplicate notes, so the app waits while the agent runs.
        if !agentRunning { runner.start() }
        // First run with Viwoods Cloud configured: ask for the sign-in straight away, no menu hunting.
        if needsViwoodsSignIn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showViwoodsSignIn() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.askToOpenAtLoginOnce() }
        }
    }

    /// InkRelay only syncs while it runs, so the first launch from Applications asks whether to open it at login.
    /// Asked once; the menu's "Open at login" changes it later.
    func askToOpenAtLoginOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "askedOpenAtLogin"), !launchAtLogin, !needsSetup,
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        defaults.set(true, forKey: "askedOpenAtLogin")
        let alert = NSAlert()
        alert.messageText = "Open InkRelay when you log in?"
        alert.informativeText = "InkRelay syncs your tablet only while it's running. You can change this any time with Open at Login in its menu."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setLaunchAtLogin(true) }
    }

    var isPaused: Bool { snapshot.status == .paused }

    /// A new snapshot from the runner: show it, and notify about what changed, as the config asks.
    private func take(_ fresh: RelayRunner.Snapshot) {
        let previous = snapshot
        snapshot = fresh
        let settings = config?.notifications ?? NotificationsConfig()
        if settings.problems, fresh.problems != previous.problems {
            Notifier.shared.problems(fresh.problems)
        }
        if settings.newNotes, fresh.lastSync != previous.lastSync, fresh.lastSynced > 0 {
            Notifier.shared.newNotes(Array(fresh.recent.prefix(fresh.lastSynced).map(\.title)))
        }
        if let time = settings.reminderTime, fresh.lastSync != previous.lastSync {
            Notifier.shared.reviewReminder(hour: time.hour, minute: time.minute, count: fresh.reviewDue)
        }
    }

    var config: RelayConfig? { try? ConfigStore.load(from: runner.configURL) }
    var supportDirectory: URL { runner.configURL.deletingLastPathComponent() }

    // MARK: Plan

    var entitlement: Entitlement { EntitlementStore(supportDirectory: supportDirectory).current() }

    /// Asks for a key in a sheet-less alert, saves it, and restarts the engine so paused parts resume now.
    func enterLicense() {
        let alert = NSAlert()
        alert.messageText = "Enter your InkRelay Pro license"
        alert.informativeText = "Paste the key from your purchase email. It starts with INK1."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "INK1.…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Enter")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let license = try EntitlementStore(supportDirectory: supportDirectory).enter(field.stringValue)
            objectWillChange.send()
            runner.start()
            let thanks = NSAlert()
            thanks.messageText = "Thanks, \(license.name)."
            thanks.informativeText = "InkRelay is Pro on this Mac" + (license.expiresAt.map { " until \($0.formatted(date: .long, time: .omitted))" } ?? "") + "."
            thanks.runModal()
        } catch {
            let failed = NSAlert(error: error)
            failed.runModal()
        }
    }

    // MARK: Updates

    private var updateTimer: Timer?

    private func scheduleUpdateChecks() {
        guard config?.checkForUpdates ?? true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkForUpdates(quietly: true) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates(quietly: true) }
        }
    }

    /// Quiet checks only post a notification and a menu row; a manual check always answers.
    func checkForUpdates(quietly: Bool = false) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try UpdateChecker().check() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let release):
                    self.update = release
                    if let release {
                        Notifier.shared.updateAvailable(release)
                        if !quietly { self.offer(release) }
                    } else if !quietly {
                        let alert = NSAlert()
                        alert.messageText = "InkRelay \(InkRelayCore.version) is up to date."
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                case .failure(let error):
                    if !quietly {
                        NSApp.activate(ignoringOtherApps: true)
                        NSAlert(error: error).runModal()
                    }
                }
            }
        }
    }

    private func offer(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "InkRelay \(release.version) is available"
        alert.informativeText = "You have \(InkRelayCore.version). " + (release.notes.isEmpty ? "" : String(release.notes.prefix(600)))
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
    }

    // MARK: Diagnostics

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Diagnostics.suggestedName()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        panel.message = "Versions, doctor's checks, the config without its secrets, state counts and recent logs. No note text, tokens or keys."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/InkRelay", isDirectory: true)
        let data = Diagnostics.bundle(configURL: runner.configURL, supportDirectory: supportDirectory, logDirectory: logs)
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    var viwoodsTokenURL: URL { RelayEngine.tokenURL(besideState: runner.stateURL) }

    /// The config pulls Viwoods Cloud but there's no working sign-in yet.
    var needsViwoodsSignIn: Bool {
        guard (try? ConfigStore.load(from: runner.configURL))?.viwoodsCloud != nil else { return false }
        return !FileManager.default.fileExists(atPath: viwoodsTokenURL.path)
            || snapshot.problems.contains { $0.contains("inkrelay viwoods login") }
    }

    private var signInWindow: NSWindow?

    /// Opens Viwoods' sign-in page in a window of its own; it closes itself once signed in.
    func showViwoodsSignIn() {
        if let signInWindow {
            signInWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: ViwoodsSignInView(model: self) { [weak self] in
                self?.signInWindow?.close()
                self?.signInWindow = nil
            })
        )
        window.title = "Sign In to Viwoods"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        signInWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Checks the token against Viwoods Cloud, saves it, and syncs. Returns a message when it didn't work.
    func saveViwoodsToken(_ token: String) -> String? {
        do {
            _ = try ViwoodsClient(credentials: FileCredentialStore(url: viwoodsTokenURL)).login(token: token)
            runner.syncNow()
            objectWillChange.send()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.askToOpenAtLoginOnce() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var symbol: String {
        switch snapshot.status {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .attention, .notConfigured: return "exclamationmark.triangle"
        case .paused: return "pause.circle"
        case .idle: return "scribble.variable"
        }
    }

    var statusLine: String {
        switch snapshot.status {
        case .notConfigured: return "Not set up yet"
        case .syncing: return "Syncing…"
        case .paused: return "Paused"
        case .attention(let count): return count == 1 ? "1 problem in the last sync" : "\(count) problems in the last sync"
        case .idle:
            guard let last = snapshot.lastSync else { return "Ready" }
            return "Up to date · " + last.formatted(date: .omitted, time: .shortened)
        }
    }

    var needsSetup: Bool {
        if case .notConfigured = snapshot.status { return true }
        return false
    }

    func syncNow() { runner.syncNow() }
    func togglePause() { runner.setPaused(!isPaused) }
    func reload() { runner.start() }

    func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func openConfig() {
        let url = runner.configURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func openLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/InkRelay")
        NSWorkspace.shared.open(log)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Hands syncing over from the command-line agent to the app.
    func stopAgentAndStart() {
        let domain = "gui/\(getuid())/\(Doctor.agentLabel)"
        _ = Doctor.run("/bin/launchctl", ["bootout", domain])
        agentRunning = Self.isAgentLoaded()
        if !agentRunning { runner.start() }
    }

    static func isAgentLoaded() -> Bool {
        Doctor.run("/bin/launchctl", ["print", "gui/\(getuid())/\(Doctor.agentLabel)"]).0 == 0
    }
}
