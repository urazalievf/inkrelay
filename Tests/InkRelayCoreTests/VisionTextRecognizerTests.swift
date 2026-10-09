import XCTest
@testable import InkRelayCore

/// Runs the real PDF rendering and Vision path on printed text. Handwriting fixtures from
/// real tablets are tracked separately; printed text keeps this test deterministic.
final class VisionTextRecognizerTests: XCTestCase {
    func testReadsTextFromAPDFTopToBottom() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let pdf = folder.url.appendingPathComponent("printed.pdf")
        try makeTextPDF(at: pdf, lines: ["Buy oat milk", "Call the dentist"])

        let pages = try VisionTextRecognizer().recognize(fileAt: pdf)

        XCTAssertEqual(pages.count, 1)
        let lines = pages[0].text.lowercased().split(separator: "\n").map(String.init)
        let milk = try XCTUnwrap(lines.firstIndex { $0.contains("oat milk") }, "got: \(lines)")
        let dentist = try XCTUnwrap(lines.firstIndex { $0.contains("dentist") }, "got: \(lines)")
        XCTAssertLessThan(milk, dentist)
    }

    func testUnreadableFileThrows() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bogus = try folder.write("broken.pdf", "not a pdf")

        XCTAssertThrowsError(try VisionTextRecognizer().recognize(fileAt: bogus))
    }
}
