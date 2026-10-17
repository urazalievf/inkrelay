import CoreGraphics
import XCTest
@testable import InkRelayCore

final class BlankPageTests: XCTestCase {
    private func page(strokeWidth: CGFloat?) -> CGImage {
        let context = CGContext(data: nil, width: 1404, height: 1872, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1404, height: 1872))
        if let strokeWidth {
            // One short handwritten-looking word: a few thin strokes.
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(strokeWidth)
            for offset in stride(from: 0, to: 120, by: 30) {
                context.move(to: CGPoint(x: 200 + offset, y: 1600))
                context.addLine(to: CGPoint(x: 215 + offset, y: 1640))
            }
            context.strokePath()
        }
        return context.makeImage()!
    }

    func testEmptyPagesAreBlankAndAWordIsNot() {
        XCTAssertTrue(InkCoverage.isBlank(page(strokeWidth: nil)))
        XCTAssertFalse(InkCoverage.isBlank(page(strokeWidth: 3)), "a pen stroke three pixels wide survives the half-size sampling")
    }

    func testBlankPagesGetNoReviewCard() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = ReviewStore(directory: folder.url)
        let destination = ReviewStackDestination(config: .init(id: "review"), store: store, renderImages: { _ in [] })
        let note = makeNote(title: "Memo", relativePath: "Memo/Memo.pdf", pages: [
            RecognizedPage(number: 1, text: "Buy milk"),
            RecognizedPage(number: 2, text: "", isBlank: true),
        ])

        _ = try destination.upsert(note, previous: nil)

        let cards = Array(try store.load().cards.values)
        XCTAssertEqual(cards.map(\.page), [1])
        XCTAssertEqual(cards.first?.subtitle, "Page 1 of 2 · Memo")
    }
}
