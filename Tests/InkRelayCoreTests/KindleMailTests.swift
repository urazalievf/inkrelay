import XCTest
@testable import InkRelayCore

final class KindleMailTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var clock = Date(timeIntervalSince1970: 1_792_000_000)

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    /// Mail as the scripts see it: a listing, and attachments saved on request.
    final class FakeMail: AppleScriptRunner {
        var listing = ""
        var attachments: [String: Data] = [:]
        var listed = 0
        func run(_ source: String, arguments: [String]) throws -> String {
            if source == KindleMailPuller.listScript { listed += 1; return listing }
            if source == KindleMailPuller.saveAttachmentScript {
                guard let data = attachments[arguments[0]] else { return "none" }
                try data.write(to: URL(fileURLWithPath: arguments[1]))
                return "saved"
            }
            return ""
        }
    }

    private func puller(_ mail: FakeMail, _ transport: FakeTransport) -> KindleMailPuller {
        KindleMailPuller(config: KindleMailConfig(cachePath: folder.url.path), runner: mail, transport: transport, now: { [unowned self] in self.clock })
    }

    func testSavesAttachedAndLinkedNotebooksOnce() throws {
        let mail = FakeMail()
        mail.listing = [
            "<a@amazon>\tdo-not-reply@amazon.com\tYou sent a file \"Ideas\" from your Kindle\tYour file is attached.",
            "<b@amazon>\tdo-not-reply@amazon.com\tYou sent a file “Q4 plan” from your Kindle\tHelp: https://www.amazon.com/help Download: https://www.amazon.com/gp/f.html?id=1 then https://www.amazon.com/other",
        ].joined(separator: "\n")
        mail.attachments["<a@amazon>"] = Data("%PDF-attached".utf8)
        let transport = FakeTransport()
        transport.handlers["https://www.amazon.com/gp/f.html?id=1"] = { _ in (200, Data("%PDF-linked".utf8)) }
        transport.handlers["https://www.amazon.com/other"] = { _ in (200, Data("<html>".utf8)) }
        let kindle = puller(mail, transport)

        let first = kindle.pull()

        XCTAssertEqual(first.saved, 2)
        XCTAssertEqual(first.failures, [])
        XCTAssertEqual(try Data(contentsOf: folder.url.appendingPathComponent("Ideas.pdf")), Data("%PDF-attached".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.url.appendingPathComponent("Q4 plan.pdf")), Data("%PDF-linked".utf8))
        XCTAssertFalse(transport.sent.contains { $0.request.url?.path == "/help" }, "help links aren't fetched")

        clock += 3600
        XCTAssertEqual(puller(mail, transport).pull().saved, 0, "handled messages are remembered")
        XCTAssertEqual(transport.sent.count, 2, "a HEAD for the size, then the download")
    }

    func testMailIsAskedAtMostEveryFewMinutes() {
        let mail = FakeMail()
        let kindle = puller(mail, FakeTransport())
        _ = kindle.pull()
        clock += 60
        _ = kindle.pull()
        XCTAssertEqual(mail.listed, 1)
        clock += 15 * 60
        _ = kindle.pull()
        XCTAssertEqual(mail.listed, 2)
    }

    func testTitlesComeFromTheQuotedNameInTheSubject() {
        XCTAssertEqual(KindleMailPuller.title(fromSubject: "You sent a file \"Ideas\" from your Kindle"), "Ideas")
        XCTAssertEqual(KindleMailPuller.title(fromSubject: "You sent “Reading notes” from your Kindle"), "Reading notes")
        XCTAssertEqual(KindleMailPuller.title(fromSubject: "Kindle notebook"), "Kindle notebook")
    }

    func testMessagesWithoutANotebookAreHandledQuietly() throws {
        let mail = FakeMail()
        mail.listing = "<c@amazon>\tYour Kindle order\tThanks for your order."
        let result = puller(mail, FakeTransport()).pull()
        XCTAssertEqual(result.saved, 0)
        XCTAssertEqual(result.failures, [])
    }

    func testTheCacheIsASourceOfItsOwn() throws {
        let json = #"{"sources":[],"destinations":[{"kind":"reviewStack","id":"r"}],"kindleMail":{"cachePath":"/tmp/kindle"}}"#
        let config = try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.allSources.map(\.id), ["kindle-scribe"])
        XCTAssertEqual(config.allSources.first?.path, "/tmp/kindle")
        XCTAssertFalse(config.allSources.first!.waitsForSettle)
        XCTAssertNoThrow(try config.validate())
    }

    func testOnlyAmazonSendersLinksAndSizesCount() throws {
        let mail = FakeMail()
        mail.listing = [
            "<x@evil>\tamazon-kindle@evil.example\tYou sent a file \"Trap\" from your Kindle\tDownload: https://www.amazon.com/gp/f.html?id=9",
            "<y@amazon>\tdo-not-reply@amazon.com\tYou sent a file \"Elsewhere\" from your Kindle\tDownload: https://evil.example/x.pdf or http://www.amazon.com/plain",
            "<z@amazon>\tnotes@kindle.amazon.com\tYou sent a file \"Huge\" from your Kindle\tDownload: https://s3.amazonaws.com/big.pdf",
        ].joined(separator: "\n")
        let transport = FakeTransport()
        transport.handlers["https://s3.amazonaws.com/big.pdf"] = { _ in (200, Data("%PDF-huge".utf8)) }
        transport.responseHeaders["https://s3.amazonaws.com/big.pdf"] = ["Content-Length": String(200 * 1024 * 1024)]
        let kindle = puller(mail, transport)

        let result = kindle.pull()

        XCTAssertEqual(result.saved, 0)
        XCTAssertTrue(result.failures.contains { $0.contains("evil.example") && $0.contains("senderDomains") }, "the fake sender is named, not followed")
        XCTAssertTrue(result.failures.contains { $0.contains("skipped a link to evil.example") })
        XCTAssertTrue(result.failures.contains { $0.contains("skipped a link to www.amazon.com") }, "plain http isn't followed either")
        XCTAssertTrue(result.failures.contains { $0.contains("over the 100 MB limit") })
        XCTAssertFalse(transport.sent.contains { $0.request.url?.host == "evil.example" })
        XCTAssertFalse(transport.sent.contains { $0.request.url?.absoluteString.contains("id=9") == true }, "nothing from the fake sender is fetched")
        XCTAssertEqual(transport.sent.filter { $0.request.httpMethod == "GET" && $0.request.url?.host == "s3.amazonaws.com" }.count, 0, "the oversized file is never downloaded")
        XCTAssertTrue(KindleMailConfig.host("s3.us-east-1.amazonaws.com", isIn: ["amazonaws.com"]))
        XCTAssertFalse(KindleMailConfig.host("amazonaws.com.evil.example", isIn: ["amazonaws.com"]))
        XCTAssertFalse(KindleMailConfig.host("notamazon.com", isIn: ["amazon.com"]))
    }
}
