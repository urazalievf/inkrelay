import CryptoKit
import XCTest
@testable import InkRelayCore

final class SendTests: XCTestCase {
    private var folder: TemporaryFolder!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    static let page = """
    <html><head><title>Why e-ink - Example News</title>
    <meta property="og:site_name" content="Example News"><meta name="author" content="Ana Ruiz"></head>
    <body><nav><a href="/">Home</a> <a href="/about">About</a></nav>
    <div class="sidebar"><p>Subscribe!</p></div>
    <article><h1>Why e-ink</h1><p>Paper you can <em>reload</em>.</p><p>It saves your eyes &amp; battery.</p>
    <img src="/pic.png" alt="A tablet"><img src="/huge.png"><script>track()</script>
    <ul><li>Calm</li><li>Readable</li></ul><p>More at <a href="/more">the site</a>.</p></article>
    <footer>© 2026</footer></body></html>
    """

    func testFindsTheArticleAndLeavesThePageChromeBehind() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        var asked: [URL] = []
        let article = try ArticleExtractor.extract(html: Data(Self.page.utf8), from: URL(string: "https://news.example/story")) { url in
            asked.append(url)
            return url.path == "/pic.png" ? png : nil
        }

        XCTAssertEqual(article.title, "Why e-ink", "the site name is dropped from the title")
        XCTAssertEqual(article.byline, "Ana Ruiz")
        XCTAssertEqual(asked.map(\.absoluteString), ["https://news.example/pic.png", "https://news.example/huge.png"])
        XCTAssertEqual(article.images, [Article.EmbeddedImage(name: "image1.png", mediaType: "image/png", data: png)])
        let body = article.bodyXHTML
        XCTAssertTrue(body.contains("<p>Paper you can <em>reload</em>.</p>"))
        XCTAssertTrue(body.contains("eyes &amp; battery"))
        XCTAssertTrue(body.contains("<img src=\"images/image1.png\" alt=\"A tablet\"/>"))
        XCTAssertTrue(body.contains("<li>Calm</li>"))
        XCTAssertTrue(body.contains("<a href=\"https://news.example/more\">the site</a>"))
        for chrome in ["Home", "Subscribe", "track()", "© 2026", "<h1>"] { XCTAssertFalse(body.contains(chrome), chrome) }
    }

    func testTheEPUBIsAValidArchiveWithMimetypeFirstAndWellFormedXHTML() throws {
        let article = try ArticleExtractor.extract(html: Data(Self.page.utf8), from: URL(string: "https://news.example/story")) { _ in Data([0xFF, 0xD8, 0xFF]) }
        let book = folder.url.appendingPathComponent("book.epub")
        try EPUBWriter.book(article).write(to: book)

        let (status, test) = try run("/usr/bin/unzip", ["-t", book.path])
        XCTAssertEqual(status, 0, test)
        let (_, listing) = try run("/usr/bin/zipinfo", ["-1", book.path])
        let entries = listing.split(separator: "\n").map(String.init)
        XCTAssertEqual(entries.first, "mimetype")
        XCTAssertTrue(entries.contains("OEBPS/images/image1.jpg"))
        let (_, mimetype) = try run("/usr/bin/unzip", ["-p", book.path, "mimetype"])
        XCTAssertEqual(mimetype, "application/epub+zip")

        for entry in ["OEBPS/article.xhtml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "META-INF/container.xml"] {
            let (_, xml) = try run("/usr/bin/unzip", ["-p", book.path, entry])
            XCTAssertNoThrow(try XMLDocument(xmlString: xml, options: []), entry)
        }
    }

    func testCRCMatchesTheStandard() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    private func sender(_ transport: FakeTransport = FakeTransport(), runner: FakeScriptRunner = FakeScriptRunner()) -> Sender {
        Sender(transport: transport, runner: runner, viwoods: {
            ViwoodsClient(transport: transport, credentials: MemoryCredentialStore(credentials: .init(token: "vw", updatedAt: Date())))
        })
    }

    func testTextAndMarkdownBecomeBooksAndOtherFilesAreRefused() throws {
        let notes = try folder.write("Reading list.md", "# Ideas\n\nFirst paragraph\ncontinued.\n\nSecond.")
        let file = try sender().prepare(notes.path)
        XCTAssertEqual(file.fileName, "Reading list.epub")
        let book = folder.url.appendingPathComponent("out.epub")
        try file.data.write(to: book)
        let (_, xhtml) = try run("/usr/bin/unzip", ["-p", book.path, "OEBPS/article.xhtml"])
        XCTAssertTrue(xhtml.contains("<h2>Ideas</h2>"))
        XCTAssertTrue(xhtml.contains("<p>First paragraph<br/>continued.</p>"))

        let zip = try folder.write("archive.zip", "x")
        XCTAssertThrowsError(try sender().prepare(zip.path)) { XCTAssertEqual($0 as? SendError, .unsupportedFile("zip")) }
    }

    func testFolderTargetNeverOverwrites() throws {
        let target = SendTargetConfig.folder(id: "tablet", path: folder.url.appendingPathComponent("Import").path)
        let file = OutgoingFile(fileName: "Story.epub", data: Data("one".utf8), pageCount: 0)
        _ = try sender().deliver(file, to: target)
        _ = try sender().deliver(file, to: target)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.appendingPathComponent("Import").path).sorted(), ["Story 2.epub", "Story.epub"])
    }

    func testKindleTargetMailsTheFileThroughMail() throws {
        let runner = FakeScriptRunner()
        let message = try sender(runner: runner).deliver(OutgoingFile(fileName: "Story.epub", data: Data("epub".utf8), pageCount: 0), to: .kindle(id: "kindle", address: "me_123@kindle.com"))
        XCTAssertEqual(runner.calls.first?.source, Sender.mailScript)
        XCTAssertEqual(Array(runner.calls.first!.arguments.prefix(2)), ["me_123@kindle.com", "Story"])
        XCTAssertTrue(runner.calls.first!.arguments[2].hasSuffix("/Story.epub"))
        XCTAssertTrue(message.contains("me_123@kindle.com"))

        let source = try folder.write("mail.applescript", Sender.mailScript)
        let (status, errors) = try run("/usr/bin/osacompile", ["-o", folder.url.appendingPathComponent("mail.scpt").path, source.path])
        XCTAssertEqual(status, 0, errors)
    }

    func testViwoodsImportFollowsThePortalsFourSteps() throws {
        let transport = FakeTransport()
        let bytes = Data("%PDF-epub-bytes".utf8)
        transport.handlers["api/v2/cloud/upload/init"] = { sent in
            XCTAssertEqual(sent.body["fileName"] as? String, "Story.epub")
            XCTAssertEqual(sent.body["partNum"] as? Int, 1)
            XCTAssertEqual(sent.body["type"] as? String, "/learning/")
            return (200, try FakeTransport.envelope(["uploadId": "up-1", "filePath": "cloud/learning/x.epub", "uploadPath": ["https://storage.test/put?sig=1"]]))
        }
        transport.handlers["https://storage.test/put?sig=1"] = { sent in
            XCTAssertEqual(sent.request.httpMethod, "PUT")
            XCTAssertEqual(sent.request.httpBody, bytes)
            return (200, Data())
        }
        transport.responseHeaders["https://storage.test/put?sig=1"] = ["ETag": "\"etag-1\""]
        transport.handlers["api/v2/cloud/upload/complete"] = { sent in
            XCTAssertEqual(sent.body["eTags"] as? [String: String], ["1": "\"etag-1\""])
            XCTAssertEqual(sent.body["hash"] as? String, Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(sent.body["source"] as? String, "3")
            // The portal leaves the part tags out of the signature for this call.
            var signed = sent.body.compactMapValues { value -> ViwoodsClient.Param? in
                if let text = value as? String { return .string(text) }
                if let number = value as? Int { return .int(number) }
                return nil
            }
            signed["eTags"] = .object([:])
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Sign"), ViwoodsClient.sign(signed, path: "api/v2/cloud/upload/complete"))
            return (200, try FakeTransport.envelope(["fileURL": "https://cdn.test/x.epub"]))
        }
        transport.handlers["api/v1/resourceSync/import"] = { sent in
            XCTAssertEqual(sent.body["appType"] as? Int, 3)
            XCTAssertEqual(sent.body["filePath"] as? String, "https://cdn.test/x.epub")
            XCTAssertEqual(sent.body["fileSize"] as? Int, bytes.count)
            return (200, try FakeTransport.envelope(NSNull()))
        }

        _ = try sender(transport).deliver(OutgoingFile(fileName: "Story.epub", data: bytes, pageCount: 0), to: .viwoodsCloud(id: "vw", app: .learning))

        XCTAssertEqual(transport.sent.map { $0.request.url!.host == "storage.test" ? "PUT" : $0.path },
                       ["api/v2/cloud/upload/init", "PUT", "api/v2/cloud/upload/complete", "api/v1/resourceSync/import"])
    }

    func testSendTargetsDecode() throws {
        let json = #"[{"kind":"folder","id":"drive","path":"~/x"},{"kind":"kindle","id":"k","address":"a@kindle.com"},{"kind":"viwoodsCloud","id":"vw"}]"#
        let targets = try JSONDecoder().decode([SendTargetConfig].self, from: Data(json.utf8))
        XCTAssertEqual(targets, [.folder(id: "drive", path: "~/x"), .kindle(id: "k", address: "a@kindle.com"), .viwoodsCloud(id: "vw", app: .learning)])
        XCTAssertEqual(try JSONDecoder().decode([SendTargetConfig].self, from: JSONEncoder().encode(targets)), targets)
    }
}
