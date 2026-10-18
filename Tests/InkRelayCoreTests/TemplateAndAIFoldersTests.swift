import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import InkRelayCore

final class TemplateAndAIFoldersTests: XCTestCase {
    /// A page: ruled lines (the template) plus one printed word; and the template alone.
    private func draw(lines: Bool, word: String?) -> CGImage {
        let width = 900, height = 500
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if lines {
            context.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
            context.setLineWidth(3)
            for y in stride(from: 40, to: height, by: 60) {
                context.move(to: CGPoint(x: 20, y: y))
                context.addLine(to: CGPoint(x: width - 20, y: y))
            }
            context.strokePath()
            let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
            let label = CTLineCreateWithAttributedString(NSAttributedString(string: "Name                    Date", attributes: [.font: font, .foregroundColor: CGColor(gray: 0.1, alpha: 1)]))
            context.textPosition = CGPoint(x: 30, y: height - 40)
            CTLineDraw(label, context)
        }
        if let word {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
            context.textPosition = CGPoint(x: 80, y: 220)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }

    func testTheTemplatesLinesAndLabelsAreTakenOutBeforeRecognition() throws {
        let page = draw(lines: true, word: "ORCHARD")
        let template = draw(lines: true, word: nil)
        let mask = TemplateSubtractor.Mask(template: template, width: page.width, height: page.height)
        let cleaned = TemplateSubtractor.clean(page, mask: mask)

        let before = try VisionTextRecognizer(config: RecognitionConfig(languages: ["en-US"])).recognize(images: [page])[0].text
        let after = try VisionTextRecognizer(config: RecognitionConfig(languages: ["en-US"])).recognize(images: [cleaned])[0].text
        XCTAssertTrue(before.contains("Name") || before.contains("Date"), "the template's labels read as text: \(before)")
        XCTAssertFalse(after.contains("Name") || after.contains("Date"), "and are gone after subtraction: \(after)")
        XCTAssertTrue(after.uppercased().contains("ORCHARD"), "the writing survives: \(after)")

        let other = draw(lines: false, word: nil)
        XCTAssertTrue(TemplateSubtractor.clean(other, mask: TemplateSubtractor.Mask(template: template, width: 10, height: 10)) === other, "a mask of another size is ignored")
    }

    func testAIAppliesOnlyToTheNamedFolders() {
        var source = SourceConfig(id: "cloud", device: "Tablet", path: "/tmp/x", recognizer: .claude)
        XCTAssertTrue(source.usesAI(for: "Paper/Notes.pdf"))
        source.aiFolders = ["Daily", "/Meeting/"]
        XCTAssertTrue(source.usesAI(for: "Daily/2026-10-13.pdf"))
        XCTAssertTrue(source.usesAI(for: "Meeting/Standup.pdf"))
        XCTAssertFalse(source.usesAI(for: "Paper/Notes.pdf"))
        XCTAssertFalse(source.usesAI(for: "DailyNotes/x.pdf"))
        source.recognizer = .vision
        XCTAssertFalse(source.usesAI(for: "Daily/2026-10-13.pdf"))

        let cloud = ViwoodsCloudConfig(apps: ["paper"], cachePath: "/tmp/c")
        var withFolders = cloud
        withFolders.recognizer = .claude
        withFolders.aiFolders = ["Daily"]
        withFolders.aiMonthlyBudgetUSD = 2
        XCTAssertEqual(withFolders.source.aiFolders, ["Daily"])
        XCTAssertEqual(withFolders.source.aiMonthlyBudgetUSD, 2)
    }

    func testTheEngineSendsOnlyPlannerPagesToClaude() throws {
        let exports = try TemporaryFolder()
        let support = try TemporaryFolder()
        defer { exports.remove(); support.remove() }
        try exports.write("Daily/2026-10-13.pdf", "plan")
        try exports.write("Paper/Notes.pdf", "notes")
        var source = SourceConfig(id: "drive", device: "Tablet", path: exports.url.path, recognizer: .claude)
        source.aiFolders = ["Daily"]
        let config = RelayConfig(sources: [source], destinations: [.obsidian(.init(id: "vault", vaultPath: "/tmp/v"))], settleSeconds: 0)
        let vision = FakeRecognizer(), claude = FakeRecognizer()
        claude.text = "from claude"
        let engine = RelayEngine(config: config, store: try StateStore(url: support.url.appendingPathComponent("state.json")),
                                 recognizer: vision, destinations: [FakeDestination(id: "vault")], aiRecognizer: claude)

        _ = engine.syncOnce()

        XCTAssertEqual(claude.calls.map(\.lastPathComponent), ["2026-10-13.pdf"])
        XCTAssertEqual(vision.calls.map(\.lastPathComponent), ["Notes.pdf"])
    }

    func testCorrectionsInObsidianAreLearnedBeforeTheNoteIsRewritten() throws {
        let exports = try TemporaryFolder()
        let support = try TemporaryFolder()
        let vault = try TemporaryFolder()
        defer { exports.remove(); support.remove(); vault.remove() }
        let export = try exports.write("Paper/Plan.pdf", "v1")
        let config = RelayConfig(sources: [SourceConfig(id: "drive", device: "Tablet", path: exports.url.path)],
                                 destinations: [.obsidian(.init(id: "obsidian", vaultPath: vault.url.path))], settleSeconds: 0)
        let recognizer = FakeRecognizer()
        recognizer.text = "Setup the diag rome for erin"
        let learned = LearnedVocabulary(url: support.url.appendingPathComponent("vocabulary.json"))
        func engine() throws -> RelayEngine {
            RelayEngine(config: config, store: try StateStore(url: support.url.appendingPathComponent("state.json")), recognizer: recognizer,
                        destinations: DestinationFactory.make(config.destinations, context: DestinationContext(supportDirectory: support.url)), learned: learned)
        }
        _ = try engine().syncOnce()

        // The person fixes the misread word inside InkRelay's block.
        let note = vault.url.appendingPathComponent("Ink/drive/Paper/Plan.md")
        let fixed = try String(contentsOf: note, encoding: .utf8).replacingOccurrences(of: "diag rome", with: "diagram")
        try Data(fixed.utf8).write(to: note)
        // Then writes more on the tablet, which would overwrite the block.
        try Data("v2".utf8).write(to: export)
        let report = try engine().syncOnce()

        XCTAssertEqual(report.learned, ["diagram"])
        XCTAssertTrue(report.summary.contains("learned 1 word"))
        XCTAssertEqual(LearnedVocabulary(url: support.url.appendingPathComponent("vocabulary.json")).all, ["diagram"])
        XCTAssertEqual(try engine().syncOnce().learned, [], "nothing new the next time")
    }

    /// Records the learned words at the moment it's asked to read, as Vision would see them.
    private final class WordsRecorder: TextRecognizer {
        let learned: LearnedVocabulary
        var seen: [[String]] = []
        init(learned: LearnedVocabulary) { self.learned = learned }
        func recognize(fileAt url: URL) throws -> [RecognizedPage] {
            seen.append(learned.all)
            return [RecognizedPage(number: 1, text: "Setup the diag rome for erin")]
        }
    }

    func testTheChangedPageIsReadWithTheCorrectionAlreadyLearned() throws {
        let exports = try TemporaryFolder(), support = try TemporaryFolder(), vault = try TemporaryFolder()
        defer { exports.remove(); support.remove(); vault.remove() }
        let export = try exports.write("Paper/Plan.pdf", "v1")
        let config = RelayConfig(sources: [SourceConfig(id: "drive", device: "Tablet", path: exports.url.path)],
                                 destinations: [.obsidian(.init(id: "obsidian", vaultPath: vault.url.path))], settleSeconds: 0)
        let learned = LearnedVocabulary(url: support.url.appendingPathComponent("vocabulary.json"))
        let recorder = WordsRecorder(learned: learned)
        func engine() throws -> RelayEngine {
            RelayEngine(config: config, store: try StateStore(url: support.url.appendingPathComponent("state.json")), recognizer: recorder,
                        destinations: DestinationFactory.make(config.destinations, context: DestinationContext(supportDirectory: support.url)), learned: learned)
        }
        _ = try engine().syncOnce()
        let note = vault.url.appendingPathComponent("Ink/drive/Paper/Plan.md")
        try Data(try String(contentsOf: note, encoding: .utf8).replacingOccurrences(of: "diag rome", with: "diagram").utf8).write(to: note)
        try Data("v2".utf8).write(to: export)

        _ = try engine().syncOnce()

        XCTAssertEqual(recorder.seen, [[], ["diagram"]], "the second read already knows the word")
    }

    func testAStaleVaultCopyTeachesNothing() throws {
        let exports = try TemporaryFolder(), support = try TemporaryFolder(), vault = try TemporaryFolder()
        defer { exports.remove(); support.remove(); vault.remove() }
        let export = try exports.write("Paper/Plan.pdf", "v1")
        let config = RelayConfig(sources: [SourceConfig(id: "drive", device: "Tablet", path: exports.url.path)],
                                 destinations: [.obsidian(.init(id: "obsidian", vaultPath: vault.url.path))], settleSeconds: 0)
        let recognizer = FakeRecognizer()
        recognizer.text = "diag rome"
        let learned = LearnedVocabulary(url: support.url.appendingPathComponent("vocabulary.json"))
        func engine() throws -> RelayEngine {
            RelayEngine(config: config, store: try StateStore(url: support.url.appendingPathComponent("state.json")), recognizer: recognizer,
                        destinations: DestinationFactory.make(config.destinations, context: DestinationContext(supportDirectory: support.url)), learned: learned)
        }
        _ = try engine().syncOnce()
        // The archive moved on (a later version was read) while the vault still holds the old block.
        let archive = NoteArchive(directory: support.url.appendingPathComponent("archive"))
        try archive.upsert(makeNote(title: "Plan", relativePath: "Paper/Plan.pdf", pages: [RecognizedPage(number: 1, text: "diagram")]), key: "drive/Paper/Plan.pdf")
        try Data("v3".utf8).write(to: export)

        let report = try engine().syncOnce()

        XCTAssertEqual(report.learned, [], "the vault's 'diag rome' isn't a correction of 'diagram'")
    }

    func testATemplateInTheOtherOrientationIsTurnedAndAnOddShapeIsIgnored() {
        let template = draw(lines: true, word: nil)
        // The same template, turned a quarter turn, as a landscape device would export it.
        let turned: CGImage = {
            let context = CGContext(data: nil, width: template.height, height: template.width, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: template.height, height: template.width))
            context.translateBy(x: CGFloat(template.height), y: 0)
            context.rotate(by: .pi / 2)
            context.draw(template, in: CGRect(x: 0, y: 0, width: template.width, height: template.height))
            return context.makeImage()!
        }()
        let mask = TemplateSubtractor.Mask(template: template, width: turned.width, height: turned.height)
        XCTAssertTrue(mask.applies)
        let cleaned = TemplateSubtractor.clean(turned, mask: mask)
        let darkBefore = TemplateSubtractor.grayPixels(turned, width: turned.width, height: turned.height).filter { $0 < 160 }.count
        let darkAfter = TemplateSubtractor.grayPixels(cleaned, width: turned.width, height: turned.height).filter { $0 < 160 }.count
        XCTAssertGreaterThan(darkBefore, 1000)
        XCTAssertLessThan(darkAfter, darkBefore / 20, "the turned template's own lines are taken out")

        let odd = TemplateSubtractor.Mask(template: template, width: 900, height: 900)
        XCTAssertFalse(odd.applies)
        let square = draw(lines: false, word: "X")
        XCTAssertTrue(TemplateSubtractor.clean(square, mask: odd) === square)
    }
}
