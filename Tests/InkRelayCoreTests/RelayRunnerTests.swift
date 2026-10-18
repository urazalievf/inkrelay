import XCTest
@testable import InkRelayCore

final class RelayRunnerTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var destination: FakeDestination!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        destination = FakeDestination(id: "vault")
    }

    override func tearDown() {
        folder.remove()
    }

    private func runner(config: RelayConfig?) throws -> RelayRunner {
        let configURL = folder.url.appendingPathComponent("support/config.json")
        if let config { try ConfigStore.save(config, to: configURL) }
        return RelayRunner(configURL: configURL, startsReviewServer: false) { [unowned self] config, stateURL in
            RelayEngine(config: config, store: try StateStore(url: stateURL), recognizer: FakeRecognizer(), destinations: [self.destination])
        }
    }

    private func config() throws -> RelayConfig {
        let exports = folder.url.appendingPathComponent("exports")
        try folder.write("exports/Paper/Meeting notes.pdf", "ink")
        return RelayConfig(sources: [SourceConfig(id: "viwoods", device: "Viwoods", path: exports.path)], destinations: [.appleNotes(.init(id: "vault"))], settleSeconds: 0)
    }

    func testFirstSyncFillsTheSnapshotWithRecentNotes() throws {
        let runner = try runner(config: try config())
        var seen: [RelayRunner.Snapshot] = []
        runner.onChange = { seen.append($0) }
        runner.start()
        runner.waitUntilIdle()
        // The folder watcher can start a second pass for the file written just before it started; stopping waits
        // for that, and the snapshots arrive on the runner's queue, so they're read once it's done.
        runner.stop()

        let afterFirstPass = try XCTUnwrap(seen.last { $0.status == .idle && $0.summary.contains("1 synced") })
        XCTAssertNotNil(afterFirstPass.lastSync)
        XCTAssertEqual(afterFirstPass.recent.map(\.title), ["Meeting notes"])
        XCTAssertEqual(afterFirstPass.recent.first?.openURL?.lastPathComponent, "Meeting notes.pdf", "no vault, so it opens the export")
        XCTAssertEqual(runner.snapshot.status, .idle)
        XCTAssertEqual(destination.upserts.count, 1)
        for snapshot in seen where snapshot.lastSync != nil {
            XCTAssertTrue(snapshot.summary.contains("found"), "a snapshot with a sync time carries that pass's summary, never the previous one's")
        }
        XCTAssertEqual(afterFirstPass.lastSynced, 1)
    }

    func testPausedRunnersDontSync() throws {
        let runner = try runner(config: try config())
        runner.setPaused(true)
        runner.start()
        runner.syncNow()
        runner.waitUntilIdle()
        defer { runner.stop() }

        XCTAssertEqual(runner.snapshot.status, .paused)
        XCTAssertTrue(destination.upserts.isEmpty)

        runner.setPaused(false)
        runner.waitUntilIdle()
        XCTAssertEqual(destination.upserts.count, 1, "resuming syncs straight away")
    }

    func testMissingConfigMeansNotConfigured() throws {
        let runner = try runner(config: nil)
        runner.start()
        runner.waitUntilIdle()
        guard case .notConfigured(let reason) = runner.snapshot.status else { return XCTFail("\(runner.snapshot.status)") }
        XCTAssertTrue(reason.contains("inkrelay init"))
    }

    func testProblemsTurnIntoAttention() throws {
        destination.shouldFail = true
        let runner = try runner(config: try config())
        runner.start()
        runner.waitUntilIdle()
        defer { runner.stop() }

        XCTAssertEqual(runner.snapshot.status, .attention(1))
        XCTAssertTrue(runner.snapshot.problems.first?.contains("→ vault: ") == true)
    }

    func testRecentNotesOpenInObsidianWhenAVaultHasThem() {
        let config = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: "/exports")], destinations: [.obsidian(.init(id: "obsidian", vaultPath: "/Vault"))])
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let state = SyncState(files: [
            "s/Paper/A.pdf": FileRecord(size: 1, modified: older, contentHash: "a", destinations: ["obsidian": DestinationRecord(externalID: "Ink/s/Paper/A.md", contentHash: "a", syncedAt: older)]),
            "s/B.pdf": FileRecord(size: 1, modified: newer, contentHash: "b", destinations: ["obsidian": DestinationRecord(externalID: "Ink/s/B.md", contentHash: "b", syncedAt: newer)]),
            "s/Gone.pdf": FileRecord(size: 1, modified: newer, contentHash: "c", destinations: ["obsidian": DestinationRecord(externalID: "x", contentHash: "c", syncedAt: newer)], missingSince: newer),
        ])

        let recent = RelayRunner.recentNotes(state: state, config: config)

        XCTAssertEqual(recent.map(\.title), ["B", "A"], "newest first, missing exports left out")
        XCTAssertEqual(recent.last?.openURL?.absoluteString, "obsidian://open?path=/Vault/Ink/s/Paper/A.md")
    }

    func testEachPassIsLoggedAndRememberedBesideTheState() throws {
        let logURL = folder.url.appendingPathComponent("logs/inkrelay.log")
        let configURL = folder.url.appendingPathComponent("support/config.json")
        try ConfigStore.save(try config(), to: configURL)
        let runner = RelayRunner(configURL: configURL, startsReviewServer: false, log: SyncLog(url: logURL)) { [unowned self] config, stateURL in
            RelayEngine(config: config, store: try StateStore(url: stateURL), recognizer: FakeRecognizer(), destinations: [self.destination])
        }
        runner.start()
        runner.waitUntilIdle()
        runner.stop()

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("Synced (startup):"), log)
        XCTAssertTrue(log.contains("1 synced"))
        // The watcher may add a second pass for the file written before it started, so the last one says 0 or 1.
        let last = try XCTUnwrap(LastSync.load(besideState: runner.stateURL))
        XCTAssertEqual(last.scanned, 1)
        XCTAssertEqual(last.failed, 0)
    }
}
