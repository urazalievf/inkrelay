import CoreGraphics
import Foundation
import ImageIO

/// Reads Supernote's native `.note` files, so notebooks that Supernote's own Dropbox, Google Drive or OneDrive
/// sync drops in a folder can be relayed without exporting PDFs on the device.
///
/// Format, as documented by the community (supernote-tool by jya-dev, Apache-2.0): the file starts with
/// `note` and a signature such as `SN_FILE_VER_20230015`; its last four bytes point at a footer. Every block
/// is a little-endian 32-bit length followed by its bytes. Metadata blocks are `<KEY:VALUE>` pairs. The footer
/// lists the pages; each page lists up to five layers (main, three extra, background), and each layer points
/// at a bitmap compressed with Ratta's run-length scheme (or a PNG for custom templates).
public struct SupernoteNote {
    public struct Page {
        public var layers: [Layer]
        /// Top first, as `LAYERSEQ` lists them.
        public var order: [String]
        public var visibility: [String: Bool]
        public var style: String?
        public var landscape: Bool
    }

    public struct Layer {
        public var name: String
        public var encoding: String
        public var bitmap: Data?
    }

    public let signature: String
    /// Portrait page size in pixels: 1404 × 1872 for A5 X, A6 X and Nomad; 1920 × 2560 for Manta.
    public let width: Int
    public let height: Int
    public let pages: [Page]

    /// From firmware 3.14.27 on, gray strokes use the high-resolution gray codes.
    var highResolutionGrays: Bool { Int(signature.suffix(8)).map { $0 >= 20230015 } ?? false }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 32, String(decoding: bytes[0..<4], as: UTF8.self) == "note" else {
            throw SupernoteError.notANote
        }
        let signature = String(decoding: bytes[4..<24], as: UTF8.self)
        guard signature.range(of: #"^SN_FILE_VER_\d{8}$"#, options: .regularExpression) != nil else {
            throw SupernoteError.unsupported("signature \(signature)")
        }
        self.signature = signature

        let footer = try Self.metadata(bytes, at: Self.uint32(bytes, bytes.count - 4))
        let header = try Self.metadata(bytes, at: Int(footer.first("FILE_FEATURE") ?? "0") ?? 0)
        if header.first("APPLY_EQUIPMENT") == "N5" {
            (width, height) = (1920, 2560)
        } else {
            (width, height) = (1404, 1872)
        }

        let pageAddresses = footer.pairs.filter { $0.key.hasPrefix("PAGE") }.compactMap { Int($0.value) }
        pages = try pageAddresses.map { address in
            let page = try Self.metadata(bytes, at: address)
            var layers: [Layer] = []
            var sawMain = false
            for (key, value) in page.pairs where ["MAINLAYER", "LAYER1", "LAYER2", "LAYER3", "BGLAYER"].contains(key) {
                guard let layerAddress = Int(value), layerAddress > 0 else { continue }
                let layer = try Self.metadata(bytes, at: layerAddress)
                var name = layer.first("LAYERNAME") ?? key
                // Some firmware names the background "MAINLAYER" too; the second one is the background.
                if name == "MAINLAYER" { if sawMain { name = "BGLAYER" } else { sawMain = true } }
                let bitmapAddress = Int(layer.first("LAYERBITMAP") ?? "0") ?? 0
                layers.append(Layer(
                    name: name,
                    encoding: layer.first("LAYERPROTOCOL") ?? "",
                    bitmap: bitmapAddress > 0 ? try Self.block(bytes, at: bitmapAddress) : nil
                ))
            }
            let orientation = page.first("ORIENTATION") ?? "1000"
            return Page(
                layers: layers,
                order: (page.first("LAYERSEQ") ?? "").split(separator: ",").map(String.init),
                visibility: Self.visibility(page.first("LAYERINFO")),
                style: page.first("PAGESTYLE"),
                landscape: orientation == "1090" || orientation == "1270"
            )
        }
    }

    // MARK: Rendering

    static let transparent: UInt8 = 0xFF
    static let white: UInt8 = 0xFE

    /// One page as an 8-bit grayscale image: layers flattened bottom to top, background whitened.
    public func image(of index: Int) throws -> CGImage {
        let page = pages[index]
        let (w, h) = page.landscape ? (height, width) : (width, height)
        var canvas = [UInt8](repeating: Self.white, count: w * h)
        let order = page.order.isEmpty ? ["LAYER3", "LAYER2", "LAYER1", "MAINLAYER", "BGLAYER"] : page.order
        for name in order.reversed() {
            guard page.visibility[name] ?? (name == "MAINLAYER" || page.visibility.isEmpty),
                  let layer = page.layers.first(where: { $0.name == name }),
                  let bitmap = layer.bitmap, !bitmap.isEmpty else { continue }
            let pixels: [UInt8]
            if name == "BGLAYER", page.style?.hasPrefix("user_") == true || layer.encoding == "PNG" {
                pixels = try Self.png(bitmap, width: w, height: h)
            } else if layer.encoding == "RATTA_RLE" {
                let blankTemplate = name == "BGLAYER" && page.style == "style_white" && bitmap.count == 0x140E
                pixels = try RattaRLE.decode(bitmap, count: w * h, highResolutionGrays: highResolutionGrays, blankTemplate: blankTemplate)
            } else {
                throw SupernoteError.unsupported("layer encoding \(layer.encoding)")
            }
            let isBackground = name == "BGLAYER"
            canvas.withUnsafeMutableBufferPointer { target in
                pixels.withUnsafeBufferPointer { source in
                    for i in 0..<target.count {
                        let value = source[i]
                        if value != Self.transparent { target[i] = value } else if isBackground { target[i] = Self.white }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(canvas) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw SupernoteError.unsupported("page image")
        }
        return image
    }

    /// Writes all pages as a PDF, one page each, so the rest of InkRelay treats it like any export.
    public func writePDF(to url: URL) throws {
        let images = try pages.indices.map(image(of:))
        try PDFComposer.write(images: images, to: url)
    }

    // MARK: Container

    struct Metadata {
        var pairs: [(key: String, value: String)]
        func first(_ key: String) -> String? { pairs.first { $0.key == key }?.value }
    }

    static func uint32(_ bytes: [UInt8], _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { throw SupernoteError.truncated }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    static func block(_ bytes: [UInt8], at address: Int) throws -> Data {
        let length = try uint32(bytes, address)
        guard address + 4 + length <= bytes.count else { throw SupernoteError.truncated }
        return Data(bytes[(address + 4)..<(address + 4 + length)])
    }

    static func metadata(_ bytes: [UInt8], at address: Int) throws -> Metadata {
        guard address > 0 else { return Metadata(pairs: []) }
        let text = String(decoding: try block(bytes, at: address), as: UTF8.self)
        let expression = try NSRegularExpression(pattern: "<([^:<>]+):(.*?)>")
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Metadata(pairs: matches.compactMap { match in
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[key]), String(text[value]))
        })
    }

    /// `LAYERINFO` is JSON (with `#` standing in for `:`), sometimes base64.
    static func visibility(_ info: String?) -> [String: Bool] {
        guard let info, info != "none" else { return [:] }
        let text = info.replacingOccurrences(of: "#", with: ":")
        let data = Data(text.utf8)
        let parsed = (try? JSONSerialization.jsonObject(with: data)) ?? Data(base64Encoded: info).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let layers = parsed as? [[String: Any]] else { return [:] }
        var visible: [String: Bool] = [:]
        for layer in layers {
            let id = layer["layerId"] as? Int ?? -1
            let isVisible = layer["isVisible"] as? Bool ?? true
            if layer["isBackgroundLayer"] as? Bool == true {
                visible["BGLAYER"] = isVisible
            } else if id == 0 {
                visible["MAINLAYER"] = isVisible
            } else if id > 0 {
                visible["LAYER\(id)"] = isVisible
            }
        }
        if visible["MAINLAYER"] == nil { visible["MAINLAYER"] = true }
        return visible
    }

    static func png(_ data: Data, width: Int, height: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw SupernoteError.unsupported("template image")
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { throw SupernoteError.unsupported("template image") }
        // Templates are opaque: white stays white, not transparent.
        return [UInt8](UnsafeBufferPointer(start: pixels.assumingMemoryBound(to: UInt8.self), count: width * height)).map { $0 == transparent ? white : $0 }
    }
}

/// Ratta's run-length encoding: pairs of (color code, length). A length with the high bit set is the high part
/// of a longer run, completed by the next pair of the same color; 0xFF means a run of 0x4000 pixels.
enum RattaRLE {
    static func colors(highResolutionGrays: Bool) -> [UInt8: UInt8] {
        var map: [UInt8: UInt8] = [
            0x61: 0x00, // black
            0x62: SupernoteNote.transparent, // background
            0x65: SupernoteNote.white,
            0x66: 0x00, // marker black
        ]
        if highResolutionGrays {
            map[0x9D] = 0x9D; map[0xC9] = 0xC9; map[0x9E] = 0x9D; map[0xCA] = 0xC9
            map[0x63] = 0x30; map[0x64] = 0x50 // older strokes kept in a new file
        } else {
            map[0x63] = 0x9D; map[0x64] = 0xC9; map[0x67] = 0x9D; map[0x68] = 0xC9
        }
        return map
    }

    static func decode(_ data: Data, count: Int, highResolutionGrays: Bool, blankTemplate: Bool = false) throws -> [UInt8] {
        let map = colors(highResolutionGrays: highResolutionGrays)
        func shade(_ code: UInt8) -> UInt8 {
            // The newer format writes other gray levels as their own value.
            map[code] ?? (highResolutionGrays ? code : SupernoteNote.transparent)
        }
        var output = [UInt8]()
        output.reserveCapacity(count + 0x4000)
        let bytes = [UInt8](data)
        var held: (code: UInt8, length: UInt8)?
        var index = 0
        while index + 1 < bytes.count {
            let code = bytes[index]
            var length = Int(bytes[index + 1])
            index += 2
            if let previous = held {
                held = nil
                if previous.code == code {
                    length = 1 + length + ((Int(previous.length & 0x7F) + 1) << 7)
                    output.append(contentsOf: repeatElement(shade(code), count: length))
                    continue
                }
                output.append(contentsOf: repeatElement(shade(previous.code), count: (Int(previous.length & 0x7F) + 1) << 7))
            }
            if length == 0xFF {
                output.append(contentsOf: repeatElement(shade(code), count: blankTemplate ? 0x400 : 0x4000))
            } else if length & 0x80 != 0 {
                held = (code, UInt8(length))
            } else {
                output.append(contentsOf: repeatElement(shade(code), count: length + 1))
            }
        }
        if let previous = held {
            // A held run at the very end is cut to what's left of the page.
            let gap = count - output.count
            for shift in (0..<8).reversed() {
                let length = (Int(previous.length & 0x7F) + 1) << shift
                if length <= gap {
                    output.append(contentsOf: repeatElement(shade(previous.code), count: length))
                    break
                }
            }
        }
        guard output.count == count else { throw SupernoteError.badBitmap(output.count, count) }
        return output
    }
}

public enum SupernoteError: Error, LocalizedError, Equatable {
    case notANote
    case truncated
    case unsupported(String)
    case badBitmap(Int, Int)

    public var errorDescription: String? {
        switch self {
        case .notANote: return "Not a Supernote notebook."
        case .truncated: return "The Supernote notebook is cut short; it may still be syncing."
        case .unsupported(let what): return "This Supernote notebook uses an unsupported \(what)."
        case .badBitmap(let got, let expected): return "A Supernote page decoded to \(got) pixels instead of \(expected)."
        }
    }
}
