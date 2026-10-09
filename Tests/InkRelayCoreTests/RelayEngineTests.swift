import XCTest
@testable import InkRelayCore

final class RelayEngineTests: XCTestCase {
    private var exports: TemporaryFolder!
    private var support: TemporaryFolder!
    private var recognizer: FakeRecognizer!
    private var vault: FakeDestination!
    private var notes: FakeDestination!

    override func setUpWithError() throws {
        exports = try TemporaryFolder()
        support = try TemporaryFolder()
        recognizer = FakeRecognizer()
        vault = FakeDestination(id: "vault")
        notes = FakeDestination(id: "notes")
    }

    override func tearDown() {
        exports.remove()
        support.remove()
    }

    private func makeEngine() throws -> RelayEngine {
        let config = RelayConfig(
            sources: [SourceConfig(id: "viwoods", device: "Viwoods AiPaper", path: exports.url.path)],
            destinations: [.appleNotes(.init(id: "unused"))]
        )
        // A fresh StateStore each time, so state has to survive a round trip through disk.
        let store = try StateStore(url: support.url.appendingPathComponent("state.json"))
        return RelayEngine(config: config, store: store, recognizer: recognizer, destinations: [vault, notes])
    }

    func testFirstPassSendsEveryExportToEveryDestination() throws {
        try exports.write("Paper/One.pdf", "one")
        try exports.write("Paper/Two.pdf", "two")

        let report = try makeEngine().syncOnce()

        XCTAssertEqual(report.scanned, 2)
        XCTAssertEqual(report.synced, 2)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(recognizer.calls.count, 2)
        XCTAssertEqual(vault.upserts.map(\.note.title), ["One", "Two"])
        XCTAssertEqual(notes.upserts.count, 2)
        XCTAssertNil(vault.upserts.first?.previous)
        XCTAssertEqual(vault.upserts.first?.note.device, "Viwoods AiPaper")
    }

    func testSecondPassWithoutChangesDoesNothing() throws {
        try exports.write("One.pdf", "one")
        _ = try makeEngine().syncOnce()

        let report = try makeEngine().syncOnce()

        XCTAssertEqual(report.unchanged, 1)
        XCTAssertEqual(report.synced, 0)
        XCTAssertEqual(recognizer.calls.count, 1)
        XCTAssertEqual(vault.upserts.count, 1)
    }

    func testChangedExportUpdatesTheSameNote() throws {
        let file = try exports.write("One.pdf", "one")
        _ = try makeEngine().syncOnce()

        try Data("one, with more ink".utf8).write(to: file)
        let report = try makeEngine().syncOnce()

        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(vault.upserts.count, 2)
        XCTAssertEqual(vault.upserts.last?.previous?.externalID, "vault:One.pdf")
    }

    func testTouchedButIdenticalExportIsNotResent() throws {
        let file = try exports.write("One.pdf", "one")
        _ = try makeEngine().syncOnce()

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        let report = try makeEngine().syncOnce()

        XCTAssertEqual(report.unchanged, 1)
        XCTAssertEqual(recognizer.calls.count, 1)
        XCTAssertEqual(vault.upserts.count, 1)
    }

    func testFailedDestinationIsRetriedAloneOnTheNextPass() throws {
        try exports.write("One.pdf", "one")
        notes.shouldFail = true

        let first = try makeEngine().syncOnce()
        XCTAssertEqual(first.synced, 0)
        XCTAssertEqual(first.failures.map(\.destinationID), ["notes"])
        XCTAssertEqual(vault.upserts.count, 1)

        notes.shouldFail = false
        let second = try makeEngine().syncOnce()

        XCTAssertEqual(second.synced, 1)
        XCTAssertEqual(second.failures, [])
        XCTAssertEqual(vault.upserts.count, 1, "the destination that succeeded isn't sent the same export again")
        XCTAssertEqual(notes.upserts.count, 1)
    }

    func testMissingSourceFolderIsReportedWithoutStoppingOtherSources() throws {
        try exports.write("One.pdf", "one")
        let config = RelayConfig(
            sources: [
                SourceConfig(id: "gone", device: "Boox", path: exports.url.appendingPathComponent("missing").path),
                SourceConfig(id: "viwoods", device: "Viwoods AiPaper", path: exports.url.path),
            ],
            destinations: [.appleNotes(.init(id: "unused"))]
        )
        let engine = RelayEngine(
            config: config,
            store: try StateStore(url: support.url.appendingPathComponent("state.json")),
            recognizer: recognizer,
            destinations: [vault]
        )

        let report = engine.syncOnce()

        XCTAssertEqual(report.failures.map(\.item), ["gone"])
        XCTAssertEqual(report.synced, 1)
    }
}
