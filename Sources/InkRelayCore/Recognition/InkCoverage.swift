import CoreGraphics

/// How much of a page is ink. Empty pages from a real tablet measured 0.00002 at most and a page with two
/// short lines 0.0067; a single small word is about 0.0002, so it stays above the threshold. Ruled lines
/// and templates count as ink, which only ever keeps a page, never drops one.
enum InkCoverage {
    static let blankThreshold = 0.0001

    static func isBlank(_ image: CGImage) -> Bool {
        fraction(of: image) < blankThreshold
    }

    /// The share of pixels darker than mid-gray, sampled at half size. Nearest-neighbour sampling keeps thin
    /// strokes as dark as they are instead of blurring them into the paper.
    static func fraction(of image: CGImage) -> Double {
        let width = max(image.width / 2, 1), height = max(image.height / 2, 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 1 }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 1 }
        var dark = 0
        for index in 0..<(width * height) where pixels[index] < 150 { dark += 1 }
        return Double(dark) / Double(width * height)
    }
}
