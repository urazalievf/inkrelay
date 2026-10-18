import XCTest
@testable import InkRelayCore

final class SetupAndDoctorTests: XCTestCase {
    private var home: TemporaryFolder!

    override func setUpWithError() throws {
        home = try TemporaryFolder()
    }

    override func tearDown() {
        home.remove()
    }

    func testFindsCloudDrivesWithGoogleDrivesMyDrive() throws {
        for folder in ["GoogleDrive-me@example.com/My Drive", "Dropbox", "OneDrive-Personal", "SomethingElse", "Box-work"] {
            try FileManager.default.createDirectory(at: home.url.appendingPathComponent("Library/CloudStorage/" + folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), withIntermediateDirectories: true)

        let found = SetupDetector(home: home.url).cloudFolders()

        XCTAssertEqual(found.map(\.provider), ["Box", "Dropbox", "Google Drive", "OneDrive", "iCloud Drive"])
        XCTAssertEqual(found.first { $0.provider == "Google Drive" }?.account, "me@example.com")
        XCTAssertEqual(found.first { $0.provider == "Google Drive" }?.url.lastPathComponent, "My Drive")
        XCTAssertEqual(SetupDetector(home: home.url).tilde(found[1].url), "~/Library/CloudStorage/Dropbox")
    }

    func testReadsObsidiansVaultListNewestFirstAndSkipsMissingOnes() throws {
        let work = try home.write("Vaults/Work/.keep")
        let personal = try home.write("Vaults/Personal/.keep")
        let json: [String: Any] = ["vaults": [
            "a": ["path": work.deletingLastPathComponent().path, "ts": 100],
            "b": ["path": personal.deletingLastPathComponent().path, "ts": 300],
            "c": ["path": home.url.appendingPathComponent("Gone").path, "ts": 500],
        ]]
        try home.write("Library/Application Support/obsidian/obsidian.json", String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))

        XCTAssertEqual(SetupDetector(home: home.url).obsidianVaults().map(\.lastPathComponent), ["Personal", "Work"])
    }

    func testNotesAccountsAreParsedFromAppleScript() throws {
        let runner = FakeScriptRunner()
        runner.results = ["iCloud, On My Mac"]
        XCTAssertEqual(try SetupDetector.notesAccounts(runner: runner), ["iCloud", "On My Mac"])
    }

    func testChoicesBecomeAValidConfig() throws {
        let viwoods = TabletPreset.all[0]
        let config = try SetupChoices(
            tablet: viwoods, useViwoodsCloud: true, exportFolder: "~/Drive/Viwoods", obsidianVault: "~/Vault",
            appleNotesAccount: .some("iCloud"), appleCalendar: true, appleReminders: true
        ).config()

        XCTAssertEqual(config.sources, [SourceConfig(id: "viwoods-aipaper", device: "Viwoods AiPaper", path: "~/Drive/Viwoods")])
        XCTAssertEqual(config.viwoodsCloud?.device, "Viwoods AiPaper")
        XCTAssertEqual(config.destinations.map(\.kind), ["obsidian", "appleNotes", "appleCalendar", "appleReminders", "reviewStack"])
        XCTAssertEqual(SetupChoices(tablet: TabletPreset.all[3], exportFolder: "~/x").tablet.fileTypes, ["pdf", "png"])
        XCTAssertThrowsError(try SetupChoices(tablet: TabletPreset.all[1], reviewStack: false).config(), "nothing to read from and nowhere to write")

        let shared = try SetupChoices(tablet: viwoods, useViwoodsCloud: true, shareWithPhone: true).config()
        guard case .reviewStack(let stack) = shared.destinations.last else { return XCTFail("no review stack") }
        XCTAssertTrue(stack.shareWithPhone, "sharing with a phone shares the review stack, even without Apple Notes")
        XCTAssertNil(shared.sharedLedger)
    }

    // MARK: Doctor

    private func doctor(_ config: RelayConfig, runner: FakeScriptRunner = FakeScriptRunner(), launchctl: (Int32, String) = (1, "")) -> Doctor {
        Doctor(config: config, supportDirectory: home.url, runner: runner, command: { _, _ in launchctl }, home: home.url, secrets: MemorySecretStore())
    }

    func testReportsMissingFoldersVaultsAndAgentState() throws {
        let exports = try home.write("Exports/One.pdf", "x").deletingLastPathComponent()
        let config = RelayConfig(
            sources: [SourceConfig(id: "ok", device: "d", path: exports.path), SourceConfig(id: "gone", device: "d", path: "/nonexistent/x")],
            destinations: [.obsidian(.init(id: "vault", vaultPath: "/nonexistent/vault")), .reviewStack(.init(id: "r"))]
        )

        let checks = doctor(config).checks(includeApps: false, accounts: false)

        XCTAssertEqual(checks.map(\.status), [.ok, .problem, .problem, .ok, .ok, .warning])
        XCTAssertTrue(checks[0].detail.hasPrefix("1 export(s)"))
        XCTAssertEqual(checks[4].title, "Plan")
        XCTAssertTrue(checks[4].detail.hasPrefix("Pro trial"))
        XCTAssertTrue(checks[5].detail.contains("install-agent.sh"))

        try home.write("Library/LaunchAgents/\(Doctor.agentLabel).plist", "<plist/>")
        try home.write("Library/Logs/InkRelay/inkrelay.log", "hello")
        let loaded = doctor(config, launchctl: (0, "gui/501/io.github.urazalievf.inkrelay = {\n\tstate = running\n}")).checks(includeApps: false, accounts: false)
        XCTAssertEqual(loaded.suffix(2).map(\.title), ["Background agent", "Agent log"])
        XCTAssertEqual(loaded.suffix(2).first?.detail, "state = running")
    }

    func testAutomationRefusalPointsAtSystemSettings() throws {
        final class Refusing: AppleScriptRunner {
            var probes: [String] = []
            func run(_ source: String, arguments: [String]) throws -> String {
                probes.append(source)
                if source.contains("Reminders") { throw DestinationError.failed("x", "Not authorized to send Apple events to Reminders. (-1743)") }
                return "1"
            }
        }
        let runner = Refusing()
        let config = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: "/x")], destinations: [
            .appleNotes(.init(id: "n")), .appleNotes(.init(id: "n2")), .appleReminders(.init(id: "r")),
        ])
        let checks = Doctor(config: config, supportDirectory: home.url, runner: runner, command: { _, _ in (1, "") }, home: home.url, secrets: MemorySecretStore()).appChecks()

        XCTAssertEqual(runner.probes.count, 2, "each app is asked once")
        XCTAssertEqual(checks.map(\.status), [.ok, .problem])
        XCTAssertTrue(checks[1].detail.contains("Privacy & Security → Automation"))
    }

    func testLogTrimmingKeepsTheNewestWholeLines() throws {
        let log = try home.write("inkrelay.log", (1...2000).map { "line \($0)" }.joined(separator: "\n") + "\n")
        XCTAssertFalse(LogTrimmer.trim(log, limit: 1_000_000, keep: 100), "small logs are left alone")

        XCTAssertTrue(LogTrimmer.trim(log, limit: 1000, keep: 100))
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("[log trimmed by InkRelay]\nline "))
        XCTAssertTrue(text.hasSuffix("line 2000\n"))
        XCTAssertLessThan(text.utf8.count, 140)
    }

    func testNotesRoundTripCatchesANoteStuckInRecentlyDeleted() {
        /// Notes as InkRelay sees it: ids, a body per note, and the Recently Deleted folder.
        final class FakeNotes: AppleScriptRunner {
            var notes: [String: String] = [:]
            var folders: [String: String] = [:]
            var deleted: Set<String> = []
            var removedFolders: [String] = []
            var counter = 0
            /// When true, behaves like a buggy script that keeps updating deleted notes.
            var ignoreRecentlyDeleted = false
            func run(_ source: String, arguments: [String]) throws -> String {
                if source == AppleNotesDestination.createScript {
                    counter += 1
                    notes["note-\(counter)"] = arguments[2]
                    folders["note-\(counter)"] = arguments[0]
                    return "note-\(counter)"
                }
                if source == AppleNotesDestination.updateScript {
                    let id = arguments[0]
                    guard notes[id] != nil, ignoreRecentlyDeleted || !deleted.contains(id) else { return "" }
                    notes[id] = arguments[1]
                    return id
                }
                if source == AppleNotesDestination.deleteScript {
                    deleted.insert(arguments[0])
                    return ""
                }
                if source == AppleNotesDestination.archiveScript {
                    folders[arguments[0]] = arguments[1]
                    return ""
                }
                if source == NotesRoundTrip.folderOfNoteScript { return folders[arguments[0]] ?? "" }
                if source == NotesRoundTrip.removeFoldersScript { removedFolders = Array(arguments.dropFirst()) }
                return ""
            }
        }
        let good = FakeNotes()
        XCTAssertEqual(NotesRoundTrip(runner: good).run().map(\.status), [.ok, .ok, .ok, .ok, .ok])
        XCTAssertEqual(good.deleted.count, 2, "both test notes are deleted at the end")
        XCTAssertEqual(good.removedFolders, ["InkRelay Test", "InkRelay Test Archive"], "and the test folders removed")

        let buggy = FakeNotes()
        buggy.ignoreRecentlyDeleted = true
        XCTAssertEqual(NotesRoundTrip(runner: buggy).run().last?.status, .problem)
    }
}
