import XCTest
@testable import InkRelayCore

final class FolderScannerTests: XCTestCase {
    private var folder: TemporaryFolder!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    func testFindsMatchingFilesRecursivelyAndSkipsHiddenOnes() throws {
        try folder.write("Paper/Meeting.pdf")
        try folder.write("Daily/2026-10-09.PDF")
        try folder.write("Daily/sketch.png")
        try folder.write("notes.txt")
        try folder.write(".hidden.pdf")
        try folder.write(".tmp/partial.pdf")

        let source = SourceConfig(id: "s", device: "d", path: folder.url.path)
        let files = try FolderScanner.scan(source)

        XCTAssertEqual(files.map(\.relativePath), ["Daily/2026-10-09.PDF", "Paper/Meeting.pdf"])
        XCTAssertEqual(files.first?.size, 1)
    }

    func testHonorsConfiguredFileTypes() throws {
        try folder.write("a.pdf")
        try folder.write("b.png")

        let source = SourceConfig(id: "s", device: "d", path: folder.url.path, fileTypes: ["pdf", "png"])
        XCTAssertEqual(try FolderScanner.scan(source).map(\.relativePath), ["a.pdf", "b.png"])
    }

    func testMissingFolderNamesTheSource() {
        let source = SourceConfig(id: "boox", device: "Boox", path: folder.url.appendingPathComponent("nope").path)
        XCTAssertThrowsError(try FolderScanner.scan(source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("\"boox\""))
        }
    }

    func testExcludedAndIncludedFolders() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        for path in ["Note/Plan.note", "Note/Work/Standup.note", "Document/Book.pdf", "EXPORT/Plan.pdf", "INBOX/x.pdf", "Top.pdf"] {
            try folder.write(path, "x")
        }
        var source = SourceConfig(id: "supernote", device: "Supernote", path: folder.url.path, fileTypes: ["pdf", "note"])
        source.exclude = ["Document", "EXPORT/", "INBOX"]
        XCTAssertEqual(try FolderScanner.scan(source).map(\.relativePath), ["Note/Plan.note", "Note/Work/Standup.note", "Top.pdf"])

        source.exclude = ["Note/Work"]
        source.folders = ["Note"]
        XCTAssertEqual(try FolderScanner.scan(source).map(\.relativePath), ["Note/Plan.note"])
        XCTAssertFalse(source.includes("Top.pdf"))
        XCTAssertTrue(source.entersFolder("Note"))
        XCTAssertFalse(source.entersFolder("Document"))

        let decoded = try JSONDecoder().decode(SourceConfig.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(decoded, source)
    }
}
