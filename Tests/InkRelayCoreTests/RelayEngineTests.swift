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

    private func makeEngine(settle: Int = 0, onDelete: [String: RemovalPolicy] = [:], now: Date = Date()) throws -> RelayEngine {
        let config = RelayConfig(
            sources: [SourceConfig(id: "viwoods", device: "Viwoods AiPaper", path: exports.url.path)],
            destinations: [.appleNotes(.init(id: "vault")), .appleNotes(.init(id: "notes"))],
            onDelete: onDelete,
            settleSeconds: settle
        )
        // A fresh StateStore each time, so state has to survive a round trip through disk.
        let store = try StateStore(url: support.url.appendingPathComponent("state.json"))
        return RelayEngine(config: config, store: store, recognizer: recognizer, destinations: [vault, notes], now: { now })
    }

    private func trackedKeys() throws -> [String] {
        try StateStore(url: support.url.appendingPathComponent("state.json")).keys(forSource: "viwoods")
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

    func testHalfWrittenFilesWaitUntilTheySettle() throws {
        let file = try exports.write("One.pdf", "one")
        let written = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date

        let early = try makeEngine(settle: 5, now: written.addingTimeInterval(2)).syncOnce()
        XCTAssertEqual(early.deferred, 1)
        XCTAssertTrue(vault.upserts.isEmpty)
        XCTAssertTrue(early.summary.contains("1 still being written"))

        let settled = try makeEngine(settle: 5, now: written.addingTimeInterval(6)).syncOnce()
        XCTAssertEqual(settled.synced, 1)
    }

    func testEmptyFilesWaitToo() throws {
        try exports.write("Empty.pdf", "")
        XCTAssertEqual(try makeEngine(settle: 5, now: Date().addingTimeInterval(3600)).syncOnce().deferred, 1)
    }

    func testRenamedExportMovesTheNoteInsteadOfDuplicatingIt() throws {
        let file = try exports.write("One.pdf", "same ink")
        _ = try makeEngine().syncOnce()
        try FileManager.default.createDirectory(at: exports.url.appendingPathComponent("Work"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: exports.url.appendingPathComponent("Work/Renamed.pdf"))

        let report = try makeEngine().syncOnce()

        XCTAssertEqual(report.renamed, 1)
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(vault.upserts.count, 2)
        XCTAssertEqual(vault.upserts.last?.previous?.externalID, "vault:One.pdf", "the old note's handle, so it moves")
        XCTAssertEqual(vault.upserts.last?.note.title, "Renamed")
        XCTAssertEqual(notes.upserts.last?.previous?.externalID, "notes:One.pdf")
        XCTAssertEqual(try trackedKeys(), ["viwoods/Work/Renamed.pdf"])
        XCTAssertEqual(vault.removals.count, 0)
    }

    func testDeletedExportFollowsEachDestinationsPolicyAfterAGracePeriod() throws {
        try exports.write("Keep.pdf", "stays")
        let gone = try exports.write("Gone.pdf", "goes")
        let start = Date()
        _ = try makeEngine(onDelete: ["vault": .delete], now: start).syncOnce()
        try FileManager.default.removeItem(at: gone)

        let first = try makeEngine(onDelete: ["vault": .delete], now: start.addingTimeInterval(10)).syncOnce()
        XCTAssertEqual(first.removed, 0, "a file missing for seconds may just be re-downloading")
        XCTAssertTrue(vault.removals.isEmpty)

        let later = try makeEngine(onDelete: ["vault": .delete], now: start.addingTimeInterval(120)).syncOnce()
        XCTAssertEqual(later.removed, 1)
        XCTAssertEqual(vault.removals.map(\.export.relativePath), ["Gone.pdf"])
        XCTAssertEqual(vault.removals.first?.policy, .delete)
        XCTAssertTrue(notes.removals.isEmpty, "notes has no policy, so it keeps the note")
        XCTAssertEqual(try trackedKeys(), ["viwoods/Gone.pdf", "viwoods/Keep.pdf"], "kept by notes, so the record stays")

        _ = try makeEngine(onDelete: ["vault": .delete], now: start.addingTimeInterval(300)).syncOnce()
        XCTAssertEqual(vault.removals.count, 1, "removed once, not on every pass")
    }

    func testAnEmptyFolderNeverRemovesAnything() throws {
        let only = try exports.write("Only.pdf", "x")
        let start = Date()
        _ = try makeEngine(onDelete: ["vault": .delete, "notes": .delete], now: start).syncOnce()
        try FileManager.default.removeItem(at: only)

        let report = try makeEngine(onDelete: ["vault": .delete, "notes": .delete], now: start.addingTimeInterval(3600)).syncOnce()

        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(vault.removals.isEmpty)
    }

    func testAnExportThatComesBackIsNoLongerMissing() throws {
        try exports.write("Keep.pdf", "stays")
        let file = try exports.write("Back.pdf", "back")
        let saved = try Data(contentsOf: file)
        let start = Date()
        _ = try makeEngine(onDelete: ["vault": .delete], now: start).syncOnce()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try FileManager.default.removeItem(at: file)
        _ = try makeEngine(onDelete: ["vault": .delete], now: start.addingTimeInterval(10)).syncOnce()

        try saved.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
        _ = try makeEngine(onDelete: ["vault": .delete], now: start.addingTimeInterval(20)).syncOnce()
        _ = try makeEngine(onDelete: ["vault": .delete], now: start.addingTimeInterval(500)).syncOnce()

        XCTAssertTrue(vault.removals.isEmpty)
        XCTAssertNil(try StateStore(url: support.url.appendingPathComponent("state.json")).record(for: "viwoods/Back.pdf")?.missingSince)
    }

    func testTwoProcessesSharingStateDontUndoEachOther() throws {
        // Both created up front, like the menu bar app and the MCP server holding their own copies.
        let first = try makeEngine()
        let second = try makeEngine()
        try exports.write("One.pdf", "one")
        _ = first.syncOnce()

        let report = second.syncOnce()

        XCTAssertEqual(report.unchanged, 1, "the second starts from what the first saved")
        XCTAssertEqual(vault.upserts.count, 1, "so it doesn't send the note again")
        XCTAssertEqual(try trackedKeys(), ["viwoods/One.pdf"])
    }

    func testMissingSourceFolderIsReportedWithoutStoppingOtherSources() throws {
        try exports.write("One.pdf", "one")
        let config = RelayConfig(
            sources: [
                SourceConfig(id: "gone", device: "Boox", path: exports.url.appendingPathComponent("missing").path),
                SourceConfig(id: "viwoods", device: "Viwoods AiPaper", path: exports.url.path),
            ],
            destinations: [.appleNotes(.init(id: "unused"))],
            settleSeconds: 0
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
