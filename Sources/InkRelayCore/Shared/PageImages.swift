import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// JPEGs of each page of an export, for destinations that show the ink itself: OneNote pages and review cards.
public enum PageImages {
    public static func jpegs(for url: URL, maxPixelDimension: Int = 1400, quality: Double = 0.8) throws -> [Data] {
        try PageRenderer.images(for: url, scale: 2, maxPixelDimension: maxPixelDimension).map { try jpeg($0, quality: quality) }
    }

    static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RecognitionError.unreadable(URL(fileURLWithPath: "page.jpg"))
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RecognitionError.unreadable(URL(fileURLWithPath: "page.jpg")) }
        return data as Data
    }
}
