import CoreGraphics
import XCTest
@testable import InkRelayCore

final class LayoutBuilderTests: XCTestCase {
    /// A line whose top edge is at `top`, in page fractions from the bottom, like Vision's boxes.
    private func line(_ text: String, x: CGFloat = 0.1, top: CGFloat, width: CGFloat = 0.8, height: CGFloat = 0.03) -> TextLine {
        TextLine(text: text, box: CGRect(x: x, y: top - height, width: width, height: height))
    }

    func testWrappedLinesBecomeOneParagraphAndGapsSeparateParagraphs() {
        let text = LayoutBuilder.text(from: [
            line("The review stack shows one", top: 0.90),
            line("page at a time.", top: 0.86, width: 0.4),
            line("Second paragraph starts", top: 0.76),
            line("here.", top: 0.72, width: 0.2),
        ])
        XCTAssertEqual(text, "The review stack shows one page at a time.\n\nSecond paragraph starts here.")
    }

    func testShortLinesStayAsWritten() {
        let text = LayoutBuilder.text(from: [
            line("Milk", top: 0.9, width: 0.15),
            line("Eggs", top: 0.86, width: 0.15),
            line("Bread", top: 0.82, width: 0.8),
        ])
        XCTAssertEqual(text, "Milk\nEggs\nBread")
    }

    func testBulletsAreNormalizedNumbersAndCheckboxesKept() {
        let text = LayoutBuilder.text(from: [
            line("• Ship the stack", top: 0.9),
            line("◦ Write the docs", top: 0.86),
            line("1. Call Sam", top: 0.82),
            line("☐ Pay rent", top: 0.78),
        ])
        XCTAssertEqual(text, "- Ship the stack\n- Write the docs\n1. Call Sam\n☐ Pay rent")
    }

    func testABrokenWordIsJoined() {
        let text = LayoutBuilder.text(from: [line("handwriting recog-", top: 0.9), line("nition works", top: 0.86, width: 0.3)])
        XCTAssertEqual(text, "handwriting recognition works")
    }

    func testFragmentsOnOneBaselineMakeOneRow() {
        let text = LayoutBuilder.text(from: [
            line("world", x: 0.32, top: 0.9, width: 0.2),
            line("Hello", x: 0.1, top: 0.9, width: 0.2),
        ])
        XCTAssertEqual(text, "Hello world")
    }

    func testTwoColumnsAreReadOneAfterTheOtherUnderTheTitle() {
        let text = LayoutBuilder.text(from: [
            line("Weekly plan", x: 0.1, top: 0.95, width: 0.8),
            line("Left one", x: 0.05, top: 0.85, width: 0.4),
            line("Right one", x: 0.55, top: 0.85, width: 0.4),
            line("Left two", x: 0.05, top: 0.75, width: 0.4),
            line("Right two", x: 0.55, top: 0.75, width: 0.4),
        ])
        XCTAssertEqual(text, "Weekly plan\n\nLeft one\n\nLeft two\n\nRight one\n\nRight two")
    }

    func testANarrowEdgeColumnIsMarginNotes() {
        let text = LayoutBuilder.text(from: [
            line("Main text line one", x: 0.25, top: 0.9, width: 0.7),
            line("Main text line two", x: 0.25, top: 0.86, width: 0.7),
            line("Main text line three", x: 0.25, top: 0.82, width: 0.7),
            line("see p4", x: 0.02, top: 0.88, width: 0.12),
            line("ask Bo", x: 0.02, top: 0.84, width: 0.12),
        ].map { var l = $0; if l.box.width > 0.55 { l.box.size.width = 0.5 }; return l })
        XCTAssertTrue(text.hasSuffix("\n\n> see p4\n> ask Bo"), text)
        XCTAssertTrue(text.hasPrefix("Main text line one"), text)
    }

    func testEmptyInput() {
        XCTAssertEqual(LayoutBuilder.text(from: []), "")
        XCTAssertEqual(LayoutBuilder.text(from: [line("   ", top: 0.5)]), "")
    }
}
