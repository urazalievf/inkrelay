import XCTest
@testable import InkRelayCore

final class AppleNotesDestinationTests: XCTestCase {
    func testCreatesInTheConfiguredFolderAndAccount() throws {
        let runner = FakeScriptRunner()
        runner.results = ["x-coredata://note/p1"]
        let destination = AppleNotesDestination(config: .init(id: "notes", folder: "Ink", account: "iCloud"), runner: runner)

        let id = try destination.upsert(makeNote(), previous: nil)

        XCTAssertEqual(id, "x-coredata://note/p1")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].source, AppleNotesDestination.createScript)
        XCTAssertEqual(Array(runner.calls[0].arguments.prefix(2)), ["Ink", "iCloud"])
        XCTAssertTrue(runner.calls[0].arguments[2].hasPrefix("<h1>Meeting notes</h1>"))
    }

    func testUpdatesTheExistingNoteInPlace() throws {
        let runner = FakeScriptRunner()
        runner.results = ["x-coredata://note/p1"]
        let destination = AppleNotesDestination(config: .init(id: "notes"), runner: runner)
        let previous = DestinationRecord(externalID: "x-coredata://note/p1", contentHash: "old", syncedAt: Date())

        let id = try destination.upsert(makeNote(), previous: previous)

        XCTAssertEqual(id, "x-coredata://note/p1")
        XCTAssertEqual(runner.calls.map(\.source), [AppleNotesDestination.updateScript])
        XCTAssertEqual(runner.calls[0].arguments.first, "x-coredata://note/p1")
    }

    func testRecreatesANoteDeletedInNotes() throws {
        let runner = FakeScriptRunner()
        runner.results = ["", "x-coredata://note/p2"]
        let destination = AppleNotesDestination(config: .init(id: "notes"), runner: runner)
        let previous = DestinationRecord(externalID: "x-coredata://note/p1", contentHash: "old", syncedAt: Date())

        let id = try destination.upsert(makeNote(), previous: previous)

        XCTAssertEqual(id, "x-coredata://note/p2")
        XCTAssertEqual(runner.calls.map(\.source), [AppleNotesDestination.updateScript, AppleNotesDestination.createScript])
        XCTAssertEqual(runner.calls[1].arguments[1], "", "no account configured means the default account")
    }

    func testAttachesTheOriginalPDF() throws {
        let runner = FakeScriptRunner()
        runner.results = ["x-coredata://note/p1"]
        let destination = AppleNotesDestination(config: .init(id: "notes"), runner: runner)

        _ = try destination.upsert(makeNote(originalURL: URL(fileURLWithPath: "/tmp/Meeting notes.pdf")), previous: nil)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].arguments[3], "/tmp/Meeting notes.pdf")
        XCTAssertTrue(AppleNotesDestination.createScript.contains("on attach(noteID, attachmentPath)"))
    }

    func testFallsBackToALinkWhenNotesWontAttach() throws {
        let runner = FakeScriptRunner()
        runner.results = ["x-coredata://note/p1\nnot attached", "x-coredata://note/p1"]
        let destination = AppleNotesDestination(config: .init(id: "notes"), runner: runner)

        let id = try destination.upsert(makeNote(originalURL: URL(fileURLWithPath: "/tmp/Meeting notes.pdf")), previous: nil)

        XCTAssertEqual(id, "x-coredata://note/p1", "the outcome line isn't part of the id")
        XCTAssertEqual(runner.calls.map(\.source), [AppleNotesDestination.createScript, AppleNotesDestination.updateScript])
        XCTAssertTrue(runner.calls[1].arguments[1].contains("<a href=\"file:///tmp/Meeting%20notes.pdf\">Open the original Meeting notes.pdf</a>"))
        XCTAssertEqual(runner.calls[1].arguments[2], "", "no second attempt")
    }

    func testAttachingCanBeTurnedOff() throws {
        let runner = FakeScriptRunner()
        runner.results = ["x-coredata://note/p1"]
        _ = try AppleNotesDestination(config: .init(id: "notes", attachOriginal: false), runner: runner).upsert(makeNote(), previous: nil)
        XCTAssertEqual(runner.calls[0].arguments[3], "")
    }

    func testDeleteAndArchiveUseTheirScripts() throws {
        let runner = FakeScriptRunner()
        let destination = AppleNotesDestination(config: .init(id: "notes", folder: "Ink"), runner: runner)
        let record = DestinationRecord(externalID: "x-coredata://note/p1", contentHash: "h", syncedAt: Date())
        let export = RemovedExport(sourceID: "s", relativePath: "a.pdf")

        try destination.remove(record, export: export, policy: .delete)
        try destination.remove(record, export: export, policy: .archive)
        try destination.remove(record, export: export, policy: .keep)

        XCTAssertEqual(runner.calls.map(\.source), [AppleNotesDestination.deleteScript, AppleNotesDestination.archiveScript])
        XCTAssertEqual(runner.calls[1].arguments, ["x-coredata://note/p1", "Ink Archive"])
    }

    func testEmptyIdFromNotesIsAnError() {
        let runner = FakeScriptRunner()
        let destination = AppleNotesDestination(config: .init(id: "notes"), runner: runner)
        XCTAssertThrowsError(try destination.upsert(makeNote(), previous: nil))
    }

    func testHTMLEscapesRecognizedText() {
        let note = makeNote(title: "A & B", pages: [RecognizedPage(number: 1, text: "<script> \"x\"\n\nafter blank")])
        let html = AppleNotesHTML.render(note)

        XCTAssertTrue(html.hasPrefix("<h1>A &amp; B</h1>"))
        XCTAssertTrue(html.contains("<div>&lt;script&gt; &quot;x&quot;</div><div><br></div><div>after blank</div>"))
        XCTAssertFalse(html.contains("<h2>"), "single-page notes skip page headings")
    }

    func testMultiPageNotesGetPageHeadings() {
        let note = makeNote(pages: [RecognizedPage(number: 1, text: "a"), RecognizedPage(number: 2, text: "b")])
        let html = AppleNotesHTML.render(note)
        XCTAssertTrue(html.contains("<h2>Page 1</h2><div>a</div><h2>Page 2</h2><div>b</div>"))
    }
}
