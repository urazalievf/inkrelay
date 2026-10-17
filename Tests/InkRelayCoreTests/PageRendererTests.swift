import CoreGraphics
import PDFKit
import XCTest
@testable import InkRelayCore

final class PageRendererTests: XCTestCase {
    /// A portrait page with a black square in its top-left corner, optionally rotated by the PDF's /Rotate.
    private func pdf(rotation: Int, in folder: TemporaryFolder) throws -> URL {
        let url = folder.url.appendingPathComponent("page-\(rotation).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 250, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        if rotation != 0 {
            let document = PDFDocument(url: url)!
            document.page(at: 0)!.rotation = rotation
            XCTAssertTrue(document.write(to: url))
        }
        return url
    }

    /// Brightness at a fraction of the image, with the origin at the top left as on screen.
    private func brightness(_ image: CGImage, x: Double, y: Double) -> UInt8 {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = -CGFloat(x) * CGFloat(image.width)
        let py = -CGFloat(1 - y) * CGFloat(image.height)
        context.draw(image, in: CGRect(x: px, y: py, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.data!.assumingMemoryBound(to: UInt8.self)[0]
    }

    func testRendersPagesUprightWhateverTheirRotation() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }

        let upright = try XCTUnwrap(PageRenderer.images(for: pdf(rotation: 0, in: folder), scale: 1, maxPixelDimension: 1000).first)
        XCTAssertEqual([upright.width, upright.height], [200, 300])
        XCTAssertLessThan(brightness(upright, x: 0.1, y: 0.05), 50, "square at the top left")
        XCTAssertGreaterThan(brightness(upright, x: 0.9, y: 0.95), 200, "white elsewhere")

        let turned = try XCTUnwrap(PageRenderer.images(for: pdf(rotation: 90, in: folder), scale: 1, maxPixelDimension: 1000).first)
        XCTAssertEqual([turned.width, turned.height], [300, 200], "landscape once turned")
        XCTAssertLessThan(brightness(turned, x: 0.95, y: 0.1), 50, "a quarter turn clockwise moves the top left to the top right")

        let flipped = try XCTUnwrap(PageRenderer.images(for: pdf(rotation: 180, in: folder), scale: 1, maxPixelDimension: 1000).first)
        XCTAssertLessThan(brightness(flipped, x: 0.9, y: 0.95), 50, "upside down puts it at the bottom right")
    }

    func testScalingIsCappedByTheLongestSide() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let image = try XCTUnwrap(PageRenderer.images(for: pdf(rotation: 0, in: folder), scale: 4, maxPixelDimension: 600).first)
        XCTAssertEqual([image.width, image.height], [400, 600])
    }
}
