import Foundation

/// One line of `inkrelay doctor`.
public struct DoctorCheck: Equatable {
    public enum Status: String {
        case ok = "✓"
        case warning = "!"
        case problem = "✗"
    }

    public var status: Status
    public var title: String
    public var detail: String

    public init(_ status: Status, _ title: String, _ detail: String = "") {
        self.status = status
        self.title = title
        self.detail = detail
    }
}

/// Checks everything a sync depends on and says what to fix, without changing anything.
public struct Doctor {
    public static let agentLabel = "io.github.urazalievf.inkrelay"

    let config: RelayConfig
    let supportDirectory: URL
    let runner: AppleScriptRunner
    let command: (String, [String]) -> (Int32, String)
    let fileManager: FileManager
    let home: URL
    let secrets: SecretStore

    public init(
        config: RelayConfig,
        supportDirectory: URL,
        runner: AppleScriptRunner = OSAScriptRunner(),
        command: @escaping (String, [String]) -> (Int32, String) = Doctor.run,
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        secrets: SecretStore = KeychainStore()
    ) {
        self.config = config
        self.supportDirectory = supportDirectory
        self.runner = runner
        self.command = command
        self.fileManager = fileManager
        self.home = home
        self.secrets = secrets
    }

    /// `includeApps` probes Notes, Calendar and Reminders, which makes macOS ask for permission the first time.
    public func checks(includeApps: Bool = true, accounts: Bool = true) -> [DoctorCheck] {
        var results = sourceChecks() + destinationChecks()
        if includeApps { results += appChecks() }
        if accounts { results += accountChecks() }
        results += agentChecks()
        return results
    }

    func sourceChecks() -> [DoctorCheck] {
        config.allSources.map { source in
            guard fileManager.fileExists(atPath: source.url.path) else {
                if source.id == config.viwoodsCloud?.id {
                    return DoctorCheck(.warning, "Viwoods Cloud cache", "not created yet; it appears after the first sync")
                }
                return DoctorCheck(.problem, "Source \(source.id)", "no folder at \(source.url.path). Check the path and that the cloud app is running.")
            }
            let count = (try? FolderScanner.scan(source, fileManager: fileManager).count) ?? 0
            return DoctorCheck(.ok, "Source \(source.id)", "\(count) export(s) in \(source.url.path)")
        }
    }

    func destinationChecks() -> [DoctorCheck] {
        config.destinations.compactMap { destination in
            switch destination {
            case .obsidian(let obsidian):
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: obsidian.vaultURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
                return exists
                    ? DoctorCheck(.ok, "Obsidian vault", obsidian.vaultURL.path)
                    : DoctorCheck(.problem, "Obsidian vault", "no vault at \(obsidian.vaultURL.path)")
            case .reviewStack(let stack):
                return DoctorCheck(.ok, "Review stack", "http://127.0.0.1:\(stack.port) while `inkrelay watch` runs")
            default:
                return nil
            }
        }
    }

    /// Read-only questions to each Apple app InkRelay drives. Error -1743 means Automation was refused.
    func appChecks() -> [DoctorCheck] {
        var apps: [(String, String)] = []
        for destination in config.destinations {
            switch destination {
            case .appleNotes: apps.append(("Notes", #"tell application "Notes" to count accounts"#))
            case .appleCalendar: apps.append(("Calendar", #"tell application "Calendar" to count calendars"#))
            case .appleReminders: apps.append(("Reminders", #"tell application "Reminders" to count lists"#))
            default: continue
            }
        }
        var seen = Set<String>()
        return apps.filter { seen.insert($0.0).inserted }.map { app, probe in
            do {
                _ = try runner.run(probe, arguments: [])
                return DoctorCheck(.ok, "\(app) automation", "allowed")
            } catch {
                let message = error.localizedDescription
                if message.contains("-1743") || message.lowercased().contains("not allowed") {
                    return DoctorCheck(.problem, "\(app) automation", "refused. Allow it in System Settings → Privacy & Security → Automation.")
                }
                return DoctorCheck(.problem, "\(app) automation", message)
            }
        }
    }

    func accountChecks() -> [DoctorCheck] {
        var results: [DoctorCheck] = []
        if config.viwoodsCloud != nil {
            let client = ViwoodsClient(credentials: FileCredentialStore(url: RelayEngine.tokenURL(besideState: supportDirectory.appendingPathComponent("state.json"))))
            do {
                let folders = try client.rootFolders()
                results.append(DoctorCheck(.ok, "Viwoods Cloud", folders.map { "\($0.name) \($0.count)" }.joined(separator: ", ")))
            } catch {
                results.append(DoctorCheck(.problem, "Viwoods Cloud", error.localizedDescription))
            }
        }
        if config.destinations.contains(where: \.needsGoogle) {
            let account = GoogleAccount(config: config.google, supportDirectory: supportDirectory)
            results.append(Self.signIn("Google", { _ = try account.session.accessToken() }))
        }
        if config.destinations.contains(where: \.needsMicrosoft) {
            let account = MicrosoftAccount(config: config.microsoft, supportDirectory: supportDirectory)
            results.append(Self.signIn("Microsoft", { _ = try account.session.accessToken() }))
        }
        if let notion = config.destinations.compactMap({ destination -> DestinationConfig.NotionConfig? in
            if case .notion(let notion) = destination { return notion }
            return nil
        }).first {
            results.append(Self.signIn("Notion", { _ = try NotionDestination(config: notion, secrets: secrets).whoAmI() }))
        }
        if config.allSources.contains(where: { $0.recognizer == .claude }) {
            let recognizer = ClaudeTextRecognizer(config: config.ai ?? AITranscriptionConfig(), supportDirectory: supportDirectory, fallback: VisionTextRecognizer(), secrets: secrets)
            let (spent, pages) = recognizer.spentThisMonth()
            let budget = (config.ai ?? AITranscriptionConfig()).monthlyBudgetUSD
            results.append(recognizer.apiKey() == nil
                ? DoctorCheck(.problem, "AI transcription", "no API key; run `inkrelay ai login`. Vision reads those pages meanwhile.")
                : DoctorCheck(.ok, "AI transcription", String(format: "$%.2f of $%.2f this month, %d page(s)", spent, budget, pages)))
        }
        return results
    }

    static func signIn(_ service: String, _ check: () throws -> Void) -> DoctorCheck {
        do {
            try check()
            return DoctorCheck(.ok, service, "signed in")
        } catch {
            return DoctorCheck(.problem, service, error.localizedDescription)
        }
    }

    func agentChecks() -> [DoctorCheck] {
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(Self.agentLabel).plist")
        guard fileManager.fileExists(atPath: plist.path) else {
            return [DoctorCheck(.warning, "Background agent", "not installed; run scripts/install-agent.sh to sync at login")]
        }
        var results: [DoctorCheck] = []
        let (status, output) = command("/bin/launchctl", ["print", "gui/\(getuid())/\(Self.agentLabel)"])
        if status == 0 {
            let state = output.split(separator: "\n").first { $0.contains("state =") }?.trimmingCharacters(in: .whitespaces) ?? "loaded"
            results.append(DoctorCheck(.ok, "Background agent", state))
        } else {
            results.append(DoctorCheck(.problem, "Background agent", "installed but not loaded; run scripts/install-agent.sh again"))
        }
        let log = home.appendingPathComponent("Library/Logs/InkRelay/inkrelay.log")
        if let size = (try? fileManager.attributesOfItem(atPath: log.path))?[.size] as? Int {
            results.append(DoctorCheck(size > LogTrimmer.limit ? .warning : .ok, "Agent log", "\(size / 1024) KB at \(log.path)"))
        }
        return results
    }

    public static func run(_ tool: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }
}

/// Keeps the agent's log from growing without limit: past `limit`, only the newest `keep` bytes stay.
/// It truncates in place, because launchd keeps writing to the same open file.
public enum LogTrimmer {
    public static let limit = 5 * 1024 * 1024
    public static let keep = 512 * 1024

    @discardableResult
    public static func trim(_ url: URL, limit: Int = LogTrimmer.limit, keep: Int = LogTrimmer.keep) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit,
              let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(size - keep, 0)))
            var tail = handle.readDataToEndOfFile()
            // Start on a whole line.
            if let newline = tail.firstIndex(of: 0x0A) { tail = tail.subdata(in: tail.index(after: newline)..<tail.endIndex) }
            try handle.truncate(atOffset: 0)
            handle.write(Data("[log trimmed by InkRelay]\n".utf8) + tail)
            return true
        } catch {
            return false
        }
    }
}

/// The checks issue #2 lists for Apple Notes, run for real in a throwaway folder: create, update, delete,
/// what happens to a note in Recently Deleted, long text and non-Latin text. It cleans up after itself.
public struct NotesRoundTrip {
    let runner: AppleScriptRunner
    let account: String?

    public init(runner: AppleScriptRunner = OSAScriptRunner(), account: String? = nil) {
        self.runner = runner
        self.account = account
    }

    public func run() -> [DoctorCheck] {
        let destination = AppleNotesDestination(config: .init(id: "doctor", folder: "InkRelay Test", account: account, attachOriginal: false), runner: runner)
        func note(_ text: String) -> InkNote {
            InkNote(title: "InkRelay test note", sourceID: "doctor", device: "InkRelay doctor", originalURL: URL(fileURLWithPath: "/dev/null"),
                    relativePath: "doctor.pdf", modified: Date(), contentHash: UUID().uuidString, pages: [RecognizedPage(number: 1, text: text)])
        }
        var results: [DoctorCheck] = []
        var created: [String] = []
        defer { for id in created { _ = try? runner.run(AppleNotesDestination.deleteScript, arguments: [id]) } }
        do {
            let first = try destination.upsert(note("First version"), previous: nil)
            created.append(first)
            results.append(DoctorCheck(.ok, "Create a note", "folder \"InkRelay Test\" in \(account ?? "the default account")"))

            let updated = try destination.upsert(note("Second version"), previous: DestinationRecord(externalID: first, contentHash: "a", syncedAt: Date()))
            results.append(updated == first
                ? DoctorCheck(.ok, "Update in place", "the note id stays the same")
                : DoctorCheck(.problem, "Update in place", "Notes gave a new id (\(updated)) instead of updating"))
            if updated != first { created.append(updated) }

            let long = String(repeating: "Line of handwriting text. ", count: 8000) + "\nÜnïcødé · 日本語 · العربية · 😀"
            let big = try destination.upsert(note(long), previous: DestinationRecord(externalID: first, contentHash: "b", syncedAt: Date()))
            results.append(DoctorCheck(.ok, "Long and non-Latin text", "\(long.count) characters accepted"))
            if big != first { created.append(big) }

            _ = try runner.run(AppleNotesDestination.deleteScript, arguments: [first])
            let afterDelete = try destination.upsert(note("Third version"), previous: DestinationRecord(externalID: first, contentHash: "c", syncedAt: Date()))
            created.append(afterDelete)
            results.append(afterDelete != first
                ? DoctorCheck(.ok, "Deleted in Notes", "a fresh note is made instead of updating one in Recently Deleted")
                : DoctorCheck(.problem, "Deleted in Notes", "the note in Recently Deleted was updated; it would never reappear"))
        } catch {
            results.append(DoctorCheck(.problem, "Apple Notes", error.localizedDescription))
        }
        return results
    }
}
