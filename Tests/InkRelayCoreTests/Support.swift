import CoreText
import Foundation
import XCTest
@testable import InkRelayCore

/// A throwaway folder under the system temp directory, removed in tearDown.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InkRelayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String = "x") throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func read(_ relativePath: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A file manager whose Trash is a list, so tests never touch the real one.
final class TrashRecorder: FileManager {
    var trashed: [URL] = []

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        trashed.append(url)
        try removeItem(at: url)
    }
}

final class FakeRecognizer: TextRecognizer {
    var calls: [URL] = []
    var text = "hello from the tablet"

    func recognize(fileAt url: URL) throws -> [RecognizedPage] {
        calls.append(url)
        return [RecognizedPage(number: 1, text: text)]
    }
}

final class FakeDestination: NoteDestination {
    struct Upsert {
        var note: InkNote
        var previous: DestinationRecord?
    }

    struct Removal {
        var record: DestinationRecord
        var export: RemovedExport
        var policy: RemovalPolicy
    }

    let id: String
    var upserts: [Upsert] = []
    var removals: [Removal] = []
    var shouldFail = false

    init(id: String) {
        self.id = id
    }

    func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        if shouldFail { throw DestinationError.failed(id, "simulated") }
        upserts.append(Upsert(note: note, previous: previous))
        return previous?.externalID ?? "\(id):\(note.relativePath)"
    }

    func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        removals.append(Removal(record: record, export: export, policy: policy))
    }
}

final class FakeScriptRunner: AppleScriptRunner {
    struct Call {
        var source: String
        var arguments: [String]
    }

    var calls: [Call] = []
    /// Returned in order, one per call.
    var results: [String] = []

    func run(_ source: String, arguments: [String]) throws -> String {
        calls.append(Call(source: source, arguments: arguments))
        return results.isEmpty ? "" : results.removeFirst()
    }
}

func makeNote(
    title: String = "Meeting notes",
    relativePath: String = "Paper/Meeting notes.pdf",
    originalURL: URL = URL(fileURLWithPath: "/tmp/Meeting notes.pdf"),
    pages: [RecognizedPage] = [RecognizedPage(number: 1, text: "First line\nSecond line")]
) -> InkNote {
    InkNote(
        title: title,
        sourceID: "viwoods",
        device: "Viwoods AiPaper",
        originalURL: originalURL,
        relativePath: relativePath,
        modified: Date(timeIntervalSince1970: 1_780_000_000),
        contentHash: "abc123",
        pages: pages
    )
}

/// Writes a one-page PDF with large printed text, for exercising the real Vision path.
func makeTextPDF(at url: URL, lines: [String]) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw NSError(domain: "InkRelayTests", code: 1)
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(mediaBox)
    let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
    for (index, line) in lines.enumerated() {
        let attributed = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 60, y: 700 - CGFloat(index) * 80)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    context.endPDFPage()
    context.closePDF()
}
