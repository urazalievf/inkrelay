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
        var changes = 0
        runner.onChange = { _ in changes += 1 }
        runner.start()
        runner.waitUntilIdle()
        defer { runner.stop() }

        XCTAssertEqual(runner.snapshot.status, .idle)
        XCTAssertNotNil(runner.snapshot.lastSync)
        XCTAssertTrue(runner.snapshot.summary.contains("1 synced"))
        XCTAssertEqual(runner.snapshot.recent.map(\.title), ["Meeting notes"])
        XCTAssertEqual(runner.snapshot.recent.first?.openURL?.lastPathComponent, "Meeting notes.pdf", "no vault, so it opens the export")
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(destination.upserts.count, 1)
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
}
