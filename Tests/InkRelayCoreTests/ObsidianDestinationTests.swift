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
