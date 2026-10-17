import CoreGraphics
import Foundation
import ImageIO

/// Builds a PDF from page images, one image per page. The cloud only stores rendered PNGs of each page,
/// so this is how a cloud notebook becomes the same kind of export a tablet would write to a folder.
enum PDFComposer {
    /// Page size in points per image pixel. 0.5 turns the AiPaper's 1440×1920 pages into 10×13.3 inches.
    static let pointsPerPixel: CGFloat = 0.5

    static func write(pageImages: [Data], to url: URL) throws {
        let images = try pageImages.map { data -> CGImage in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw PDFComposerError.unreadableImage
            }
            return image
        }
        guard let first = images.first else { throw PDFComposerError.noPages }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var mediaBox = CGRect(x: 0, y: 0, width: CGFloat(first.width) * pointsPerPixel, height: CGFloat(first.height) * pointsPerPixel)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).part")
        guard let context = CGContext(temporary as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFComposerError.cannotWrite(url)
        }
        for image in images {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            context.draw(image, in: fit(image, in: mediaBox))
            context.endPDFPage()
        }
        context.closePDF()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    /// Scales the image to fit the box without distortion, centred. Pages of one notebook share a size,
    /// so this only matters when the device mixes orientations.
    static func fit(_ image: CGImage, in box: CGRect) -> CGRect {
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height)
    }
}

enum PDFComposerError: Error, LocalizedError, Equatable {
    case unreadableImage
    case noPages
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "A page image from the cloud couldn't be decoded."
        case .noPages: return "The notebook has no pages."
        case .cannotWrite(let url): return "Couldn't create \(url.path)."
        }
    }
}
