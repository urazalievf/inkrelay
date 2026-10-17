import XCTest
@testable import InkRelayCore

final class ObsidianDestinationTests: XCTestCase {
    private var vault: TemporaryFolder!
    private var exports: TemporaryFolder!

    override func setUpWithError() throws {
        vault = try TemporaryFolder()
        exports = try TemporaryFolder()
    }

    override func tearDown() {
        vault.remove()
        exports.remove()
    }

    func testWritesNoteAndOriginalMirroringTheSourceFolders() throws {
        let original = try exports.write("Paper/Meeting notes.pdf", "%PDF")
        let destination = ObsidianDestination(config: .init(id: "vault", vaultPath: vault.url.path))

        let path = try destination.upsert(makeNote(originalURL: original), previous: nil)

        XCTAssertEqual(path, "Ink/viwoods/Paper/Meeting notes.md")
        let markdown = try vault.read(path)
        XCTAssertTrue(markdown.contains("# Meeting notes"))
        XCTAssertTrue(markdown.contains("![[Ink/viwoods/Paper/Meeting notes.pdf]]"))
        XCTAssertTrue(markdown.contains("First line\nSecond line"))
        XCTAssertEqual(try vault.read("Ink/viwoods/Paper/Meeting notes.pdf"), "%PDF")
    }

    func testUpdateOverwritesTheSameFile() throws {
        let original = try exports.write("Meeting notes.pdf", "%PDF")
        let destination = ObsidianDestination(config: .init(id: "vault", vaultPath: vault.url.path, copyOriginal: false))
        let first = try destination.upsert(makeNote(relativePath: "Meeting notes.pdf", originalURL: original), previous: nil)

        let changed = makeNote(
            relativePath: "Meeting notes.pdf",
            originalURL: original,
            pages: [RecognizedPage(number: 1, text: "Rewritten")]
        )
        let previous = DestinationRecord(externalID: first, contentHash: "old", syncedAt: Date())
        let second = try destination.upsert(changed, previous: previous)

        XCTAssertEqual(first, second)
        let markdown = try vault.read(second)
        XCTAssertTrue(markdown.contains("Rewritten"))
        XCTAssertFalse(markdown.contains("![["))
    }

    func testRenameMovesTheNoteAndItsPDF() throws {
        let original = try exports.write("Paper/Meeting notes.pdf", "%PDF")
        let destination = ObsidianDestination(config: .init(id: "vault", vaultPath: vault.url.path))
        let first = try destination.upsert(makeNote(originalURL: original), previous: nil)
        let moved = try exports.write("Work/Standup.pdf", "%PDF")

        let second = try destination.upsert(
            makeNote(title: "Standup", relativePath: "Work/Standup.pdf", originalURL: moved),
            previous: DestinationRecord(externalID: first, contentHash: "abc123", syncedAt: Date())
        )

        XCTAssertEqual(second, "Ink/viwoods/Work/Standup.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent(first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("Ink/viwoods/Paper/Meeting notes.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("Ink/viwoods/Work/Standup.pdf").path))
    }

    func testArchiveMovesUnderArchiveAndDeleteUsesTheTrash() throws {
        let original = try exports.write("Paper/Meeting notes.pdf", "%PDF")
        let trash = TrashRecorder()
        let destination = ObsidianDestination(config: .init(id: "vault", vaultPath: vault.url.path), fileManager: trash)
        let path = try destination.upsert(makeNote(originalURL: original), previous: nil)
        let record = DestinationRecord(externalID: path, contentHash: "h", syncedAt: Date())
        let export = RemovedExport(sourceID: "viwoods", relativePath: "Paper/Meeting notes.pdf")

        try destination.remove(record, export: export, policy: .archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("Ink/Archive/viwoods/Paper/Meeting notes.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("Ink/Archive/viwoods/Paper/Meeting notes.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent(path).path))

        let again = try destination.upsert(makeNote(originalURL: original), previous: nil)
        try destination.remove(DestinationRecord(externalID: again, contentHash: "h", syncedAt: Date()), export: export, policy: .delete)
        XCTAssertEqual(trash.trashed.map(\.lastPathComponent), ["Meeting notes.md", "Meeting notes.pdf"])
    }

    private func syncTwice(edit: (String) -> String, second: InkNote? = nil) throws -> String {
        let original = try exports.write("Paper/Meeting notes.pdf", "%PDF")
        let destination = ObsidianDestination(config: .init(id: "vault", vaultPath: vault.url.path, copyOriginal: false))
        let path = try destination.upsert(makeNote(originalURL: original), previous: nil)
        let file = vault.url.appendingPathComponent(path)
        try edit(try String(contentsOf: file, encoding: .utf8)).write(to: file, atomically: true, encoding: .utf8)
        let next = second ?? makeNote(originalURL: original, pages: [RecognizedPage(number: 1, text: "Rewritten by the tablet")])
        let again = try destination.upsert(next, previous: DestinationRecord(externalID: path, contentHash: "old", syncedAt: Date()))
        return try vault.read(again)
    }

    func testEditsOutsideTheMarkersSurviveAResync() throws {
        let markdown = try syncTwice { text in
            text
                .replacingOccurrences(of: MarkdownRenderer.startMarker, with: "My summary above.\n\n" + MarkdownRenderer.startMarker)
                .replacingOccurrences(of: "First line", with: "edited inside the block")
                + "\n## My follow-ups\n- call Sam\n"
        }

        XCTAssertTrue(markdown.contains("My summary above.\n\n" + MarkdownRenderer.startMarker))
        XCTAssertTrue(markdown.contains("## My follow-ups\n- call Sam"))
        XCTAssertTrue(markdown.contains("Rewritten by the tablet"))
        XCTAssertFalse(markdown.contains("edited inside the block"), "the generated part is InkRelay's")
        XCTAssertEqual(markdown.components(separatedBy: MarkdownRenderer.startMarker).count, 2, "one block, not two")
    }

    func testUserFrontmatterAndTagsSurviveWhileInkRelaysKeysUpdate() throws {
        let markdown = try syncTwice { text in
            text
                .replacingOccurrences(of: "tags: [\"ink\"]", with: "tags: [\"ink\", \"project-x\"]\naliases:\n  - standup\nstatus: draft")
                .replacingOccurrences(of: "pages: 1", with: "pages: 99")
        }

        XCTAssertTrue(markdown.contains("tags: [\"ink\", \"project-x\"]"))
        XCTAssertTrue(markdown.contains("aliases:\n  - standup\nstatus: draft"))
        XCTAssertTrue(markdown.contains("pages: 1\n"), "InkRelay's own keys are rewritten")
        XCTAssertFalse(markdown.contains("pages: 99"))
    }

    func testNotesWrittenBeforeMarkersAreMigratedOnce() throws {
        let markdown = try syncTwice { text in
            // A 0.3.0 note: same frontmatter, no markers.
            text.replacingOccurrences(of: MarkdownRenderer.startMarker + "\n", with: "").replacingOccurrences(of: "\n" + MarkdownRenderer.endMarker, with: "")
        }

        XCTAssertTrue(markdown.contains(MarkdownRenderer.startMarker))
        XCTAssertTrue(markdown.contains(MarkdownRenderer.endMarker))
        XCTAssertEqual(markdown.components(separatedBy: "# Meeting notes").count, 2, "the old body is replaced, not kept twice")
        XCTAssertFalse(markdown.contains("First line"))
    }

    func testANoteThatIsntInkRelaysIsKeptBelowTheGeneratedPart() throws {
        try FileManager.default.createDirectory(at: vault.url.appendingPathComponent("Ink/viwoods/Paper"), withIntermediateDirectories: true)
        try "# My own meeting notes\nDon't lose me.\n".write(to: vault.url.appendingPathComponent("Ink/viwoods/Paper/Meeting notes.md"), atomically: true, encoding: .utf8)
        let original = try exports.write("Paper/Meeting notes.pdf", "%PDF")
        let destination = ObsidianDestination(config: .init(id: "vault", vaultPath: vault.url.path, copyOriginal: false))

        let path = try destination.upsert(makeNote(originalURL: original), previous: nil)

        let markdown = try vault.read(path)
        XCTAssertTrue(markdown.contains("# My own meeting notes\nDon't lose me."))
        XCTAssertTrue(markdown.contains(MarkdownRenderer.endMarker + "\n\n# My own meeting notes"))
    }

    func testARenameCarriesTheUsersTextToTheNewNote() throws {
        let moved = try exports.write("Work/Standup.pdf", "%PDF")
        let markdown = try syncTwice(edit: { $0 + "\nMy notes on this.\n" }, second: makeNote(title: "Standup", relativePath: "Work/Standup.pdf", originalURL: moved))

        XCTAssertTrue(markdown.contains("# Standup"))
        XCTAssertTrue(markdown.contains("My notes on this."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("Ink/viwoods/Paper/Meeting notes.md").path))
    }

    func testMissingVaultFailsWithoutCreatingIt() {
        let missing = vault.url.appendingPathComponent("not-a-vault")
        let destination = ObsidianDestination(config: .init(id: "vault", vaultPath: missing.path))

        XCTAssertThrowsError(try destination.upsert(makeNote(), previous: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testSanitizesNamesObsidianRejects() {
        XCTAssertEqual(ObsidianDestination.safeFileName("Q3: plan [draft] #1"), "Q3- plan -draft- -1")
        XCTAssertEqual(ObsidianDestination.safeFileName(" .. "), "Untitled")
    }

    func testFrontmatterQuotesValues() {
        let markdown = MarkdownRenderer.render(makeNote(title: #"Say "hi": now"#), embedPath: nil, tags: ["ink", "meeting"])
        XCTAssertTrue(markdown.hasPrefix("---\nsource: \"viwoods\"\ndevice: \"Viwoods AiPaper\""))
        XCTAssertTrue(markdown.contains(#"tags: ["ink", "meeting"]"#))
        XCTAssertTrue(markdown.contains(#"# Say "hi": now"#))
    }

    func testBlankPagesSayNothingWasRecognized() {
        let markdown = MarkdownRenderer.render(makeNote(pages: [RecognizedPage(number: 1, text: "  ")]), embedPath: nil, tags: [])
        XCTAssertTrue(markdown.contains("_No text recognized._"))
    }
}
