import AppKit
import ImageIO
import PDFKit

/// Rasterizes exports so Vision can read them. Handwriting in tablet PDFs is vector ink, not text.
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
        guard let document = PDFDocument(url: url) else { throw RecognitionError.unreadable(url) }
        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { throw RecognitionError.unreadable(url) }
            var size = page.bounds(for: .mediaBox).size
            if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            let longest = max(size.width, size.height)
            let factor = min(scale, Double(maxPixelDimension) / max(longest, 1))
            let target = NSSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
            // thumbnail(of:for:) applies the page's rotation and paints a white background.
            let image = page.thumbnail(of: target, for: .mediaBox)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw RecognitionError.unreadable(url)
            }
            return cgImage
        }
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
