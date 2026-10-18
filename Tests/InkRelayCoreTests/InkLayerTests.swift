import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import InkRelayCore

final class InkLayerTests: XCTestCase {
    func testTheNotebookOffersInkOnlyPagesOnlyWhenEveryPageHasOne() throws {
        let json: [String: Any] = [
            "note": ["id": "n", "fileName": "ll"],
            "pages": [["page": ["id": "p1", "order": 0]], ["page": ["id": "p2", "order": 1]]],
            "resourceRefs": [
                ["fileName": "screenshotBmp_p1.png", "remoteUrl": "https://cdn.test/p1.png", "ownerPageId": "p1"],
                ["fileName": "mainBmp_p1.png", "remoteUrl": "https://cdn.test/ink1.png", "ownerPageId": "p1"],
                ["fileName": "screenshotBmp_p2.png", "remoteUrl": "https://cdn.test/p2.png", "ownerPageId": "p2"],
                ["fileName": "mainBmp_p2.png", "remoteUrl": "https://cdn.test/ink2.png", "ownerPageId": "p2"],
            ],
        ]
        let notebook = try JSONDecoder().decode(ViwoodsNotebook.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(notebook.inkImageURLs()?.map(\.absoluteString), ["https://cdn.test/ink1.png", "https://cdn.test/ink2.png"])

        var partial = json
        partial["resourceRefs"] = (json["resourceRefs"] as! [[String: Any]]).filter { $0["fileName"] as? String != "mainBmp_p2.png" }
        let missing = try JSONDecoder().decode(ViwoodsNotebook.self, from: JSONSerialization.data(withJSONObject: partial))
        XCTAssertNil(missing.inkImageURLs(), "half an ink layer would mismatch page numbers")
    }

    func testTheEngineReadsTheInkCopyAndDeliversTheFullPage() throws {
        let cache = try TemporaryFolder()
        let support = try TemporaryFolder()
        defer { cache.remove(); support.remove() }
        try cache.write("Paper/One.pdf", "rendered page")
        try cache.write(".ink/Paper/One.pdf", "ink only")
        let cloud = ViwoodsCloudConfig(cachePath: cache.url.path)
        let config = RelayConfig(sources: [], destinations: [.obsidian(.init(id: "vault", vaultPath: "/tmp/v"))], viwoodsCloud: cloud, settleSeconds: 0)
        let recognizer = FakeRecognizer()
        let vault = FakeDestination(id: "vault")
        let engine = RelayEngine(config: config, store: try StateStore(url: support.url.appendingPathComponent("state.json")), recognizer: recognizer, destinations: [vault])

        let report = engine.syncOnce()

        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(recognizer.calls.map(\.lastPathComponent), ["One.pdf"])
        XCTAssertTrue(recognizer.calls[0].path.contains("/.ink/"), "recognition reads the ink copy")
        XCTAssertFalse(vault.upserts[0].note.originalURL.path.contains("/.ink/"), "destinations get the full page")

        let off = RelayConfig(sources: [], destinations: config.destinations, viwoodsCloud: ViwoodsCloudConfig(cachePath: cache.url.path, recognizeInkOnly: false), settleSeconds: 0)
        let plain = RelayEngine(config: off, store: try StateStore(url: support.url.appendingPathComponent("state2.json")), recognizer: recognizer, destinations: [FakeDestination(id: "vault")])
        _ = plain.syncOnce()
        XCTAssertFalse(recognizer.calls[1].path.contains("/.ink/"))
    }

    /// Three pages with printed words, read concurrently, come back in page order.
    func testPagesAreRecognizedInOrderWhenReadConcurrently() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let words = ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO"]
        let images: [CGImage] = words.map { word in
            let context = CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 110, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
            context.textPosition = CGPoint(x: 60, y: 150)
            CTLineDraw(line, context)
            return context.makeImage()!
        }
        let pdf = folder.url.appendingPathComponent("words.pdf")
        try PDFComposer.write(images: images, to: pdf)

        let pages = try VisionTextRecognizer(config: RecognitionConfig(languages: ["en-US"], concurrency: 3)).recognize(fileAt: pdf)

        XCTAssertEqual(pages.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(pages.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }, words)
    }
}
