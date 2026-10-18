import XCTest
@testable import InkRelayCore

final class VocabularyTests: XCTestCase {
    func testWordsAreLettersOnlyThreeOrMore() {
        XCTAssertEqual(VocabularyLearner.words(in: "Setup the diagram for Erin, re-run it; it's 2 pm. OK?"), ["Setup", "the", "diagram", "for", "Erin", "re-run", "it's"])
    }

    func testCorrectionsAreTheNewWordsAndFurnitureIsIgnored() {
        let original = "Setup the diag rome for erin\nEnsemble"
        let edited = """
        # Temp

        ![[Ink/viwoods-cloud/Paper/Temp.pdf]]

        ## Page 1

        Setup the diagram for Erin
        Ensemble
        _No text recognized on this page._
        """
        XCTAssertEqual(VocabularyLearner.newWords(edited: edited, original: original), ["diagram"], "Erin only changed case; the title, embed and page lines aren't corrections")
        XCTAssertEqual(VocabularyLearner.newWords(edited: edited, original: original, known: ["Diagram"]), [])
        XCTAssertEqual(VocabularyLearner.newWords(edited: original, original: original), [])
    }

    func testCheckboxesAndBlockIdsAreNeverLearned() {
        let original = "☐ Call the bank"
        let edited = "- [ ] Call the bank ^ink-0a1b2c3d4e5f6a7b\n- [x] Call the bank ^ink-0a1b2c3d4e5f6a7b-2"
        XCTAssertEqual(VocabularyLearner.newWords(edited: edited, original: original), [])
    }

    func testManagedTextIsTheBlockBetweenTheMarkers() {
        let markdown = "mine\n" + MarkdownRenderer.startMarker + "\n# T\n\nhello\n" + MarkdownRenderer.endMarker + "\nalso mine\n"
        XCTAssertEqual(VocabularyLearner.managedText(of: markdown), "\n# T\n\nhello\n")
        XCTAssertNil(VocabularyLearner.managedText(of: "no markers"))
    }

    func testLearnedWordsPersistDedupeAndCap() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("vocabulary.json")
        let learned = LearnedVocabulary(url: url)
        XCTAssertEqual(learned.add(["Erin", "erin", "Ensemble"]), ["Erin", "Ensemble"])
        XCTAssertEqual(learned.add(["ENSEMBLE"]), [])
        XCTAssertEqual(LearnedVocabulary(url: url).all, ["Erin", "Ensemble"], "written to disk")
        XCTAssertTrue(learned.remove("erin"))
        XCTAssertFalse(learned.remove("erin"))
        XCTAssertEqual(LearnedVocabulary(url: url).all, ["Ensemble"])

        learned.add((1...(LearnedVocabulary.limit + 5)).map { "word\($0)" })
        XCTAssertEqual(learned.all.count, LearnedVocabulary.limit)
        XCTAssertEqual(learned.all.last, "word\(LearnedVocabulary.limit + 5)", "the newest stay")
    }

    func testTwoProcessesShareTheFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("vocabulary.json")
        let daemon = LearnedVocabulary(url: url)
        daemon.add(["Erin"])
        let cli = LearnedVocabulary(url: url)
        Thread.sleep(forTimeInterval: 0.02)
        cli.add(["Ensemble"])
        XCTAssertTrue(cli.remove("Erin"))
        XCTAssertEqual(daemon.all, ["Ensemble"], "the long-running engine sees what the command changed")
        Thread.sleep(forTimeInterval: 0.02)
        daemon.add(["Orchard"])
        XCTAssertEqual(LearnedVocabulary(url: url).all, ["Ensemble", "Orchard"], "and doesn't bring the removed word back")
    }
}
