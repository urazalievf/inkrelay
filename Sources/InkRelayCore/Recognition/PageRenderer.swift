import CoreGraphics
import Foundation
import ImageIO

/// Rasterizes exports so Vision can read them. Handwriting in tablet PDFs is vector ink, not text.
/// Plain Core Graphics, so it runs the same on the Mac and on iPhone and iPad.
enum PageRenderer {
    static func images(for url: URL, scale: Double, maxPixelDimension: Int) throws -> [CGImage] {
        if url.pathExtension.lowercased() == "pdf" {
            return try pdfPages(url, scale: scale, maxPixelDimension: maxPixelDimension)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RecognitionError.unreadable(url)
        }
        return [image]
    }

    private static func pdfPages(_ url: URL, scale: Double, maxPixelDimension: Int) throws -> [CGImage] {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { throw RecognitionError.unreadable(url) }
        return try (1...document.numberOfPages).map { index in
            guard let page = document.page(at: index) else { throw RecognitionError.unreadable(url) }
            return try render(page, scale: scale, maxPixelDimension: maxPixelDimension, url: url)
        }
    }

    /// Draws one page on white, honoring the page's rotation, at `scale` times its size but no larger than `maxPixelDimension`.
    static func render(_ page: CGPDFPage, scale: Double, maxPixelDimension: Int, url: URL) throws -> CGImage {
        let box = page.getBoxRect(.mediaBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let turned = rotation == 90 || rotation == 270
        let shown = turned ? CGSize(width: box.height, height: box.width) : box.size
        let factor = min(scale, Double(maxPixelDimension) / max(Double(max(shown.width, shown.height)), 1))
        let width = max(Int((Double(shown.width) * factor).rounded()), 1)
        let height = max(Int((Double(shown.height) * factor).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RecognitionError.unreadable(url) }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / shown.width, y: CGFloat(height) / shown.height)
        // PDF rotation is clockwise; Core Graphics angles are counterclockwise.
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: shown.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: shown.width, y: shown.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: shown.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw RecognitionError.unreadable(url) }
        return image
    }
}

public enum RecognitionError: Error, LocalizedError {
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Couldn't open \(url.lastPathComponent) as a PDF or image."
        }
    }
}
