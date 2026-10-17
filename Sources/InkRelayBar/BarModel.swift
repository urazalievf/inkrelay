import AppKit
import InkRelayCore
import ServiceManagement
import SwiftUI

@MainActor
final class BarModel: ObservableObject {
    @Published private(set) var snapshot = RelayRunner.Snapshot()
    @Published private(set) var agentRunning = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

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
            Task { @MainActor in self?.snapshot = snapshot }
        }
        agentRunning = Self.isAgentLoaded()
        // Two engines writing the same state would duplicate notes, so the app waits while the agent runs.
        if !agentRunning { runner.start() }
        // First run with Viwoods Cloud configured: ask for the sign-in straight away, no menu hunting.
        if needsViwoodsSignIn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showViwoodsSignIn() }
        }
    }

    var isPaused: Bool { snapshot.status == .paused }

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
