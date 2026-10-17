// Measures pages the way InkRelay judges them: ink coverage (the blank-page rule) and what Vision reads,
// with its confidence per line. Read-only; it only opens the PDFs it's given.
//   swift scripts/measure-pages.swift ~/Library/Application\ Support/InkRelay/viwoods/Daily/*.pdf
//   swift scripts/measure-pages.swift --lines 8 notebook.pdf
import CoreGraphics
import Foundation
import Vision

var arguments = Array(CommandLine.arguments.dropFirst())
var lineLimit = 4
if let index = arguments.firstIndex(of: "--lines"), arguments.indices.contains(index + 1) {
    lineLimit = Int(arguments[index + 1]) ?? lineLimit
    arguments.removeSubrange(index...(index + 1))
}
guard !arguments.isEmpty else {
    print("Usage: swift scripts/measure-pages.swift [--lines N] FILE.pdf ...")
    exit(1)
}

for path in arguments {
    guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else {
        print("\(path): not a PDF")
        continue
    }
    for number in 1...max(document.numberOfPages, 1) {
        guard let page = document.page(at: number) else { continue }
        // Rendered at 2x like recognition does (RecognitionConfig.renderScale), on white.
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width * 2), height = Int(box.height * 2)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        context.drawPDFPage(page)
        guard let image = context.makeImage(), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { continue }

        // InkCoverage counts pixels darker than 150; blank means under 0.0001 and no text.
        var dark = 0
        for index in 0..<(width * height) where pixels[index] < 150 { dark += 1 }
        let coverage = Double(dark) / Double(width * height)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .prefix(lineLimit)
            .compactMap { $0.topCandidates(1).first.map { String(format: "%.2f %@", $0.confidence, $0.string) } }

        let name = (path as NSString).lastPathComponent
        let verdict = lines.isEmpty && coverage < 0.0001 ? "  BLANK" : ""
        print("\(name) p\(number)  ink \(String(format: "%.5f", coverage))\(verdict)")
        for line in lines { print("    \(line)") }
    }
}
