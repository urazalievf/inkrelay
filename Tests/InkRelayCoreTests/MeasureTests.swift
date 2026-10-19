import XCTest
@testable import InkRelayCore

final class MeasureTests: XCTestCase {
    func testWordsAreComparedWithoutCaseAccentsOrPunctuation() {
        XCTAssertEqual(WordScore.score(recognized: "Call Mom.\nbuy  milk!", truth: "call mom buy milk"), WordScore(words: 4, errors: 0))
        XCTAssertEqual(WordScore.score(recognized: "Café, don’t", truth: "cafe don't").errors, 0, "accents and curly apostrophes")
        XCTAssertEqual(WordScore.score(recognized: "call mum buy milk", truth: "call mom buy milk").errors, 1, "a substitution")
        XCTAssertEqual(WordScore.score(recognized: "call buy milk", truth: "call mom buy milk").errors, 1, "a deletion")
        XCTAssertEqual(WordScore.score(recognized: "call mom to buy milk", truth: "call mom buy milk").errors, 1, "an insertion")
        XCTAssertEqual(WordScore.score(recognized: "buy milk call mom", truth: "call mom buy milk").errors, 4, "order matters")
        XCTAssertEqual(WordScore.score(recognized: "call mum", truth: "call mom buy milk").accuracy, 0.25, accuracy: 0.0001)
    }

    func testAccuracyStaysBetweenZeroAndOne() {
        XCTAssertEqual(WordScore.score(recognized: "", truth: "").accuracy, 1, "an empty page read as empty")
        XCTAssertEqual(WordScore.score(recognized: "noise", truth: "").accuracy, 0, "text read off an empty page")
        XCTAssertEqual(WordScore.score(recognized: "a b c d e f", truth: "x").accuracy, 0, "insertions can't push it below 0")
        let total = WordScore(words: 10, errors: 1) + WordScore(words: 30, errors: 3)
        XCTAssertEqual(total.accuracy, 0.9, accuracy: 0.0001, "totals weigh pages by their words")
    }

    func testTheSetFindsPagesLeavesDraftsOutAndKeepsHistory() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let set = MeasureSet(supportDirectory: folder.url)

        XCTAssertTrue(try set.addDraft(sourceID: "viwoods", relativePath: "Paper/My notebook.pdf", page: 12, reading: "hello wrld"))
        XCTAssertFalse(try set.addDraft(sourceID: "viwoods", relativePath: "Paper/My notebook.pdf", page: 12, reading: "other"), "never replaced")
        try folder.write("measure/viwoods/Daily/2025-11-10.pdf.p1.txt", "Dentist at 3\n")
        try folder.write("measure/notes.txt", "not a page")
        try folder.write("measure/viwoods/readme.txt", "no page number")

        let pages = set.pages()
        XCTAssertEqual(pages.map { "\($0.sourceID)|\($0.relativePath)|\($0.number)" }, ["viwoods|Daily/2025-11-10.pdf|1", "viwoods|Paper/My notebook.pdf|12"])
        XCTAssertEqual(try set.truth(of: pages[0]), "Dentist at 3\n")
        XCTAssertNil(try set.truth(of: pages[1]), "an uncorrected draft isn't scored")
        XCTAssertEqual(pages[1].truthURL, set.truthURL(sourceID: "viwoods", relativePath: "Paper/My notebook.pdf", page: 12))

        XCTAssertEqual(set.history(), [])
        let first = MeasureSet.Run(date: Date(timeIntervalSince1970: 1_800_000_000), version: "0.10.1", pages: 2, score: WordScore(words: 40, errors: 6))
        let second = MeasureSet.Run(date: Date(timeIntervalSince1970: 1_800_086_400), version: "0.10.2", pages: 2, score: WordScore(words: 40, errors: 4))
        try set.record(first)
        try set.record(second)
        XCTAssertEqual(set.history(), [first, second])
        XCTAssertTrue(try folder.read("measure/history.tsv").hasPrefix("date\tversion\tpages\twords\terrors\taccuracy\n"))
    }

    func testTheEngineReadsAnExportAsSyncWouldWithoutFilingIt() throws {
        let cache = try TemporaryFolder()
        let support = try TemporaryFolder()
        defer { cache.remove(); support.remove() }
        try cache.write("Paper/One.pdf", "rendered page")
        try cache.write(".ink/Paper/One.pdf", "ink only")
        let cloud = ViwoodsCloudConfig(cachePath: cache.url.path)
        let config = RelayConfig(sources: [], destinations: [.obsidian(.init(id: "vault", vaultPath: "/tmp/v"))], viwoodsCloud: cloud, settleSeconds: 0)
        let recognizer = FakeRecognizer()
        let vault = FakeDestination(id: "vault")
        let engine = RelayEngine(config: config, store: try StateStore(url: support.url.appendingPathComponent("state.json")), recognizer: recognizer, destinations: [vault])

        XCTAssertEqual(try engine.read(sourceID: cloud.id, relativePath: "Paper/One.pdf").map(\.text), ["hello from the tablet"])
        XCTAssertTrue(recognizer.calls[0].path.contains("/.ink/"), "the ink copy, as sync reads it")
        XCTAssertTrue(vault.upserts.isEmpty, "nothing filed")
        XCTAssertEqual(engine.syncOnce().synced, 1, "and nothing marked as synced")

        XCTAssertThrowsError(try engine.read(sourceID: "nope", relativePath: "Paper/One.pdf")) { error in
            XCTAssertEqual(error as? RelayEngine.ReadError, .unknownSource("nope", known: [cloud.id]))
        }
        XCTAssertThrowsError(try engine.read(sourceID: cloud.id, relativePath: "Paper/Two.pdf")) { error in
            guard case .missingExport? = error as? RelayEngine.ReadError else { return XCTFail("\(error)") }
        }
    }
}
