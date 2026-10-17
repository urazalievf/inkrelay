import CoreGraphics
import PDFKit
import XCTest
@testable import InkRelayCore

/// Builds `.note` files byte by byte, following the format the decoder reads.
struct NoteFileBuilder {
    var signature = "SN_FILE_VER_20230015"
    private var body = Data()

    private func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }

    mutating func block(_ data: Data) -> Int {
        let address = 24 + body.count
        body += le32(data.count) + data
        return address
    }

    mutating func meta(_ pairs: [(String, String)]) -> Int {
        block(Data(pairs.map { "<\($0.0):\($0.1)>" }.joined().utf8))
    }

    func file(footer: Int) -> Data {
        Data(("note" + signature).utf8) + body + le32(footer)
    }

    /// Run-length encodes a row-major list of color codes the way Ratta does.
    static func rle(_ codes: [UInt8]) -> Data {
        var out = [UInt8]()
        var index = 0
        while index < codes.count {
            let code = codes[index]
            var run = 0
            while index + run < codes.count, codes[index + run] == code { run += 1 }
            index += run
            while run > 0 {
                if run >= 0x4000 {
                    out += [code, 0xFF]
                    run -= 0x4000
                } else if run <= 128 {
                    out += [code, UInt8(run - 1)]
                    run = 0
                } else {
                    let piece = min(run, 16_384)
                    let high = (piece - 1) >> 7
                    out += [code, 0x80 | UInt8(high - 1), code, UInt8(piece - 1 - (high << 7))]
                    run -= piece
                }
            }
        }
        return Data(out)
    }
}

final class SupernoteNoteTests: XCTestCase {
    static let width = 1404, height = 1872

    /// A page with a black square at the top left on the main layer, a gray band on layer 1,
    /// and a background that's white, optionally hidden.
    private func makeNote(landscape: Bool = false, hideLayer1: Bool = false, signature: String = "SN_FILE_VER_20230015") -> Data {
        var builder = NoteFileBuilder()
        builder.signature = signature
        let (w, h) = landscape ? (Self.height, Self.width) : (Self.width, Self.height)
        var main = [UInt8](repeating: 0x62, count: w * h)
        for y in 0..<100 { for x in 0..<100 { main[y * w + x] = 0x61 } }
        var extra = [UInt8](repeating: 0x62, count: w * h)
        for y in 500..<520 { for x in 0..<w { extra[y * w + x] = 0x9D } }
        let background = [UInt8](repeating: 0x62, count: w * h)

        func layer(_ name: String, _ codes: [UInt8]) -> Int {
            let bitmap = builder.block(NoteFileBuilder.rle(codes))
            return builder.meta([("LAYERNAME", name), ("LAYERPROTOCOL", "RATTA_RLE"), ("LAYERBITMAP", String(bitmap))])
        }
        let mainLayer = layer("MAINLAYER", main)
        let layer1 = layer("LAYER1", extra)
        let backgroundLayer = layer("BGLAYER", background)
        // LAYERINFO is JSON with "#" standing in for ":".
        let info = ##"[{"layerId"#0,"isBackgroundLayer"#false,"isVisible"#true},{"layerId"#1,"isBackgroundLayer"#false,"isVisible"#\##(!hideLayer1)},{"layerId"#-1,"isBackgroundLayer"#true,"isVisible"#true}]"##
        let page = builder.meta([
            ("PAGESTYLE", "style_white"), ("LAYERINFO", info), ("LAYERSEQ", "LAYER1,MAINLAYER,BGLAYER"),
            ("MAINLAYER", String(mainLayer)), ("LAYER1", String(layer1)), ("LAYER2", "0"), ("LAYER3", "0"), ("BGLAYER", String(backgroundLayer)),
            ("ORIENTATION", landscape ? "1090" : "1000"),
        ])
        let header = builder.meta([("FILE_TYPE", "NOTE"), ("APPLY_EQUIPMENT", "N6")])
        let footer = builder.meta([("FILE_FEATURE", String(header)), ("PAGE1", String(page))])
        return builder.file(footer: footer)
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data[y * image.bytesPerRow + x]
    }

    func testRunLengthDecodingCoversShortLongAndSpecialRuns() throws {
        let codes = [UInt8](repeating: 0x61, count: 5) + [UInt8](repeating: 0x62, count: 300) + [UInt8](repeating: 0x65, count: 0x4000) + [0x61]
        let decoded = try RattaRLE.decode(NoteFileBuilder.rle(codes), count: codes.count, highResolutionGrays: true)
        XCTAssertEqual(decoded.count, codes.count)
        XCTAssertEqual(Array(decoded.prefix(5)), [0, 0, 0, 0, 0])
        XCTAssertEqual(decoded[5], SupernoteNote.transparent)
        XCTAssertEqual(decoded[304], SupernoteNote.transparent)
        XCTAssertEqual(decoded[305], SupernoteNote.white)
        XCTAssertEqual(decoded.last, 0)
        XCTAssertThrowsError(try RattaRLE.decode(NoteFileBuilder.rle(codes), count: codes.count + 1, highResolutionGrays: true))
    }

    func testGrayCodesDependOnTheFirmwareGeneration() throws {
        let codes: [UInt8] = [0x63, 0x64, 0x9D, 0xC9, 0x80]
        XCTAssertEqual(try RattaRLE.decode(NoteFileBuilder.rle(codes), count: 5, highResolutionGrays: true), [0x30, 0x50, 0x9D, 0xC9, 0x80])
        XCTAssertEqual(Array(try RattaRLE.decode(NoteFileBuilder.rle(codes), count: 5, highResolutionGrays: false).prefix(2)), [0x9D, 0xC9])
    }

    func testParsesPagesAndFlattensLayersBottomToTop() throws {
        let note = try SupernoteNote(data: makeNote())
        XCTAssertEqual(note.pages.count, 1)
        XCTAssertEqual([note.width, note.height], [1404, 1872])
        XCTAssertEqual(note.pages[0].layers.map(\.name), ["MAINLAYER", "LAYER1", "BGLAYER"])

        let image = try note.image(of: 0)
        XCTAssertEqual([image.width, image.height], [1404, 1872])
        XCTAssertEqual(pixel(image, 10, 10), 0x00, "ink from the main layer")
        XCTAssertEqual(pixel(image, 700, 510), 0x9D, "gray from layer 1")
        XCTAssertEqual(pixel(image, 700, 1000), SupernoteNote.white, "whitened background")
    }

    func testHiddenLayersStayHidden() throws {
        let image = try SupernoteNote(data: makeNote(hideLayer1: true)).image(of: 0)
        XCTAssertEqual(pixel(image, 700, 510), SupernoteNote.white)
        XCTAssertEqual(pixel(image, 10, 10), 0x00)
    }

    func testLandscapePagesKeepTheirShape() throws {
        let image = try SupernoteNote(data: makeNote(landscape: true)).image(of: 0)
        XCTAssertEqual([image.width, image.height], [1872, 1404])
    }

    func testMantaPagesAreLarger() throws {
        var builder = NoteFileBuilder()
        let header = builder.meta([("APPLY_EQUIPMENT", "N5")])
        let footer = builder.meta([("FILE_FEATURE", String(header))])
        let note = try SupernoteNote(data: builder.file(footer: footer))
        XCTAssertEqual([note.width, note.height], [1920, 2560])
        XCTAssertTrue(note.pages.isEmpty)
    }

    func testRejectsOtherFilesAndTruncatedNotes() {
        XCTAssertThrowsError(try SupernoteNote(data: Data(repeating: 0, count: 100))) { XCTAssertEqual($0 as? SupernoteError, .notANote) }
        let truncated = makeNote().prefix(5000) + Data([0xFF, 0xFF, 0x0F, 0x00])
        XCTAssertThrowsError(try SupernoteNote(data: Data(truncated))) { XCTAssertEqual($0 as? SupernoteError, .truncated) }
    }

    func testWritesAPDFAndTheEngineRelaysNotesThroughIt() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("exports/Note"), withIntermediateDirectories: true)
        try makeNote().write(to: folder.url.appendingPathComponent("exports/Note/Standup.note"))
        let recognizer = FakeRecognizer()
        let destination = FakeDestination(id: "vault")
        let config = RelayConfig(
            sources: [SourceConfig(id: "supernote", device: "Supernote Nomad", path: folder.url.appendingPathComponent("exports").path, fileTypes: ["note"])],
            destinations: [.appleNotes(.init(id: "vault"))],
            settleSeconds: 0
        )
        let engine = RelayEngine(config: config, store: try StateStore(url: folder.url.appendingPathComponent("support/state.json")), recognizer: recognizer, destinations: [destination])

        XCTAssertEqual(engine.syncOnce().synced, 1)

        let pdf = try XCTUnwrap(destination.upserts.first?.note.originalURL)
        XCTAssertEqual(pdf.pathExtension, "pdf")
        XCTAssertEqual(recognizer.calls, [pdf], "recognition reads the PDF, not the notebook")
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 1)
        XCTAssertEqual(destination.upserts.first?.note.title, "Standup")
        XCTAssertEqual(destination.upserts.first?.note.relativePath, "Note/Standup.note")
    }

    /// Real notebooks from Supernote devices, when INKRELAY_SUPERNOTE_SAMPLES points at a folder of them
    /// (for example the fixtures in github.com/philips/supernote-typescript).
    func testDecodesRealNotebooksWhenSamplesAreAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["INKRELAY_SUPERNOTE_SAMPLES"] else {
            throw XCTSkip("set INKRELAY_SUPERNOTE_SAMPLES to a folder of .note files")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasSuffix(".note") }
        XCTAssertFalse(files.isEmpty)
        for name in files {
            let note = try SupernoteNote(data: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(name)))
            XCTAssertFalse(note.pages.isEmpty, name)
            for index in note.pages.indices { XCTAssertNoThrow(try note.image(of: index), "\(name) page \(index + 1)") }
        }
    }
}
