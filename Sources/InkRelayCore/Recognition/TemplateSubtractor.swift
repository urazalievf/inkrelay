import CoreGraphics
import Foundation

/// Takes a tablet's printed template out of a page before recognition: wherever the blank template is dark,
/// the page is whitened (with a one-pixel margin, since exports don't line up to the pixel), so ruled lines,
/// "Name" and "Date" boxes stop turning up as text. Ink that crosses a template line loses a pixel or two,
/// which Vision doesn't mind.
public enum TemplateSubtractor {
    static let darkThreshold: UInt8 = 160

    /// The template rendered once at the page's size, as a mask of dark pixels. A template in the other
    /// orientation is turned to match; one whose shape still doesn't fit the page gives a mask that does nothing,
    /// since stretching it would whiten handwriting instead of lines.
    public struct Mask {
        let width: Int
        let height: Int
        let dark: [Bool]
        /// False when the template doesn't fit this page size; `clean` then leaves the page alone.
        public let applies: Bool

        public init(template: CGImage, width: Int, height: Int) {
            self.width = width
            self.height = height
            let turned = (template.width > template.height) != (width > height) && template.width != template.height
            let templateWidth = turned ? template.height : template.width
            let templateHeight = turned ? template.width : template.height
            let aspectOff = abs(Double(templateWidth) / Double(templateHeight) - Double(width) / Double(height)) / (Double(width) / Double(height))
            guard aspectOff <= 0.03 else {
                dark = []
                applies = false
                return
            }
            applies = true
            let gray = TemplateSubtractor.grayPixels(template, width: width, height: height, rotated: turned)
            var dark = [Bool](repeating: false, count: width * height)
            for y in 0..<height {
                for x in 0..<width where gray[y * width + x] < TemplateSubtractor.darkThreshold {
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0, ny >= 0, nx < width, ny < height { dark[ny * width + nx] = true }
                        }
                    }
                }
            }
            self.dark = dark
        }
    }

    /// The page with the template's pixels whitened. Pages of another size are left alone.
    public static func clean(_ page: CGImage, mask: Mask) -> CGImage {
        guard mask.applies, page.width == mask.width, page.height == mask.height else { return page }
        var gray = grayPixels(page, width: mask.width, height: mask.height)
        for index in gray.indices where mask.dark[index] { gray[index] = 255 }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: mask.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return page }
        return image
    }

    static func grayPixels(_ image: CGImage, width: Int, height: Int, rotated: Bool = false) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            if rotated {
                // A quarter turn: the template's long side lies along the page's long side.
                context.translateBy(x: CGFloat(width), y: 0)
                context.rotate(by: .pi / 2)
                context.draw(image, in: CGRect(x: 0, y: 0, width: height, height: width))
            } else {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return pixels
    }

    /// The template image from a PNG, JPEG or the first page of a PDF, rendered at the given scale.
    public static func templateImage(at url: URL, scale: Double, maxPixelDimension: Int) throws -> CGImage {
        guard let first = try PageRenderer.images(for: url, scale: scale, maxPixelDimension: maxPixelDimension).first else {
            throw RecognitionError.unreadable(url)
        }
        return first
    }
}
