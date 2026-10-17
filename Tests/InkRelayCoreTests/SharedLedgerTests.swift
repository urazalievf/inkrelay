import XCTest
@testable import InkRelayCore

final class SharedLedgerTests: XCTestCase {
    private var folder: TemporaryFolder!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    func testDevicesSeeWhatTheOthersFiled() throws {
        let mac = SharedLedger(folder: folder.url.appendingPathComponent("InkRelay"), device: "Mac")
        let phone = SharedLedger(folder: folder.url.appendingPathComponent("InkRelay"), device: "Feruz's iPhone")

        try phone.record([("hash-a", "Standup")])

        XCTAssertTrue(mac.filedElsewhere("hash-a"))
        XCTAssertFalse(phone.filedElsewhere("hash-a"), "its own entry doesn't count as elsewhere")
        XCTAssertEqual(mac.entry(for: "hash-a")?.title, "Standup")
        XCTAssertFalse(mac.filedElsewhere("hash-b"))
    }

    func testConflictCopiesAreMergedAndRemoved() throws {
        let ledger = SharedLedger(folder: folder.url, device: "Mac")
        try ledger.record([("a", "One")], at: Date(timeIntervalSince1970: 100))
        // What iCloud leaves when two devices write at once.
        try FileManager.default.copyItem(at: folder.url.appendingPathComponent("ledger.json"), to: folder.url.appendingPathComponent("ledger 2.json"))
        let other = #"{"version":1,"entries":{"b":{"by":"iPad","at":"2026-01-01T00:00:00Z","title":"Two"},"a":{"by":"iPad","at":"1970-01-01T00:00:50Z","title":"One"}}}"#
        try other.write(to: folder.url.appendingPathComponent("ledger 3.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(Set(ledger.entries().keys), ["a", "b"])
        XCTAssertEqual(ledger.entry(for: "a")?.by, "iPad", "the earliest filing wins")

        try ledger.record([("c", "Three")])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted(), ["ledger.json"])
        XCTAssertEqual(Set(ledger.entries().keys), ["a", "b", "c"])
    }

    func testTheMacSkipsNotesThePhoneAlreadyFiledButStillFeedsEverythingElse() throws {
        let exports = try TemporaryFolder()
        defer { exports.remove() }
        let file = try exports.write("Paper/Standup.pdf", "the same bytes on every device")
        let hash = try ContentHash.sha256(of: file)
        let shared = folder.url.appendingPathComponent("InkRelay")
        try SharedLedger(folder: shared, device: "iPhone").record([(hash, "Standup")])

        let runner = FakeScriptRunner()
        let notes = AppleNotesDestination(config: .init(id: "notes"), runner: runner)
        let vault = FakeDestination(id: "vault")
        let config = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: exports.url.path)], destinations: [.appleNotes(.init(id: "notes"))], settleSeconds: 0)
        let engine = RelayEngine(
            config: config, store: try StateStore(url: folder.url.appendingPathComponent("state.json")),
            recognizer: FakeRecognizer(), destinations: [notes, vault], ledger: SharedLedger(folder: shared, device: "Mac")
        )

        let report = engine.syncOnce()

        XCTAssertTrue(runner.calls.isEmpty, "no second note in Apple Notes")
        XCTAssertEqual(vault.upserts.count, 1, "Obsidian and the rest still get it")
        XCTAssertEqual(report.filedElsewhere, 1)
        XCTAssertEqual(report.synced, 1)
        XCTAssertTrue(report.summary.contains("already in Notes from another device"))
    }

    func testTheMacRecordsWhatItFiles() throws {
        let exports = try TemporaryFolder()
        defer { exports.remove() }
        let file = try exports.write("Memo.pdf", "ink")
        let runner = FakeScriptRunner()
        runner.results = ["x-coredata://note/1"]
        let shared = folder.url.appendingPathComponent("InkRelay")
        let config = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: exports.url.path)], destinations: [.appleNotes(.init(id: "notes"))], settleSeconds: 0)
        let engine = RelayEngine(
            config: config, store: try StateStore(url: folder.url.appendingPathComponent("state.json")),
            recognizer: FakeRecognizer(), destinations: [AppleNotesDestination(config: .init(id: "notes"), runner: runner)],
            ledger: SharedLedger(folder: shared, device: "Mac")
        )

        _ = engine.syncOnce()

        let entry = SharedLedger(folder: shared, device: "iPhone").entry(for: try ContentHash.sha256(of: file))
        XCTAssertEqual(entry?.by, "Mac")
        XCTAssertEqual(entry?.title, "Memo")
    }

    func testConfigDefaultsToICloudDrive() throws {
        let config = try JSONDecoder().decode(SharedLedgerConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.device, "Mac")
        XCTAssertEqual(config.folderURL, SharedLedger.iCloudDriveFolder)
        XCTAssertEqual(SharedLedgerConfig(folder: "/tmp/x").folderURL?.path, "/tmp/x")
    }
}
