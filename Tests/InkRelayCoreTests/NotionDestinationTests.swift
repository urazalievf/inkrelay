import XCTest
@testable import InkRelayCore

final class NotionDestinationTests: XCTestCase {
    private var transport: FakeTransport!
    private var secrets: MemorySecretStore!

    override func setUp() {
        transport = FakeTransport()
        secrets = MemorySecretStore(["notion": "secret_abc"])
    }

    private func destination(_ config: DestinationConfig.NotionConfig = .init(id: "notion", parentPageId: "parent-1"), images: [Data] = []) -> NotionDestination {
        NotionDestination(config: config, secrets: secrets, transport: transport) { _ in images }
    }

    func testCreatesAPageUnderTheParentWithImagesAndText() throws {
        transport.handlers["v1/file_uploads"] = { sent in
            XCTAssertEqual(sent.body["content_type"] as? String, "image/jpeg")
            return (200, try jsonData(["id": "up-\(sent.body["filename"] as! String)"]))
        }
        transport.reply("v1/file_uploads/up-page-1.jpg/send", ["status": "uploaded"])
        transport.reply("v1/pages", ["id": "page-1"])

        let note = makeNote(pages: [RecognizedPage(number: 1, text: "First paragraph\n\nSecond paragraph")])
        let id = try destination(images: [Data("jpeg".utf8)]).upsert(note, previous: nil)

        XCTAssertEqual(id, "page-1")
        let create = try XCTUnwrap(transport.requests(to: "v1/pages").first)
        XCTAssertEqual(create.request.value(forHTTPHeaderField: "Notion-Version"), "2022-06-28")
        XCTAssertEqual(create.request.value(forHTTPHeaderField: "Authorization"), "Bearer secret_abc")
        XCTAssertEqual(create.body["parent"] as? [String: String], ["page_id": "parent-1"])
        let title = ((create.body["properties"] as? [String: Any])?["title"] as? [String: Any])?["title"] as? [[String: Any]]
        XCTAssertEqual((title?.first?["text"] as? [String: String])?["content"], "Meeting notes")
        let children = try XCTUnwrap(create.body["children"] as? [[String: Any]])
        XCTAssertEqual(children.map { $0["type"] as? String }, ["image", "paragraph", "paragraph", "paragraph"])
        XCTAssertEqual(((children[0]["image"] as? [String: Any])?["file_upload"] as? [String: String])?["id"], "up-page-1.jpg")
        let send = try XCTUnwrap(transport.requests(to: "v1/file_uploads/up-page-1.jpg/send").first)
        XCTAssertTrue(send.request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
    }

    func testDatabaseRowsUseTheDatabasesTitleProperty() throws {
        transport.reply("v1/databases/db-1", ["properties": ["Tags": ["type": "multi_select"], "Name": ["type": "title"]]])
        transport.reply("v1/pages", ["id": "row-1"])

        _ = try destination(.init(id: "notion", databaseId: "db-1", includeImages: false)).upsert(makeNote(), previous: nil)

        let create = try XCTUnwrap(transport.requests(to: "v1/pages").first)
        XCTAssertEqual(create.body["parent"] as? [String: String], ["database_id": "db-1"])
        XCTAssertNotNil((create.body["properties"] as? [String: Any])?["Name"])
    }

    func testUpdateReplacesTheBlocksOfTheSamePage() throws {
        transport.reply("v1/pages/page-1", ["id": "page-1", "archived": false])
        var listed = 0
        transport.handlers["v1/blocks/page-1/children"] = { sent in
            if sent.request.httpMethod == "GET" {
                listed += 1
                return listed == 1
                    ? (200, try jsonData(["results": [["id": "b1"]], "has_more": true, "next_cursor": "c2"]))
                    : (200, try jsonData(["results": [["id": "b2"]], "has_more": false]))
            }
            return (200, try jsonData(["results": []]))
        }
        transport.reply("v1/blocks/b1", ["id": "b1"])
        transport.reply("v1/blocks/b2", ["id": "b2"])

        let id = try destination(.init(id: "notion", parentPageId: "p", includeImages: false)).upsert(
            makeNote(), previous: DestinationRecord(externalID: "page-1", contentHash: "old", syncedAt: Date())
        )

        XCTAssertEqual(id, "page-1")
        XCTAssertEqual(listed, 2, "follows the cursor")
        XCTAssertEqual(transport.requests(to: "v1/blocks/b1").first?.request.httpMethod, "DELETE")
        XCTAssertEqual(transport.requests(to: "v1/blocks/b2").first?.request.httpMethod, "DELETE")
        let append = try XCTUnwrap(transport.requests(to: "v1/blocks/page-1/children").last)
        XCTAssertEqual(append.request.httpMethod, "PATCH")
        XCTAssertTrue(transport.requests(to: "v1/pages").isEmpty, "no new page")
    }

    func testAPageTrashedInNotionIsCreatedAgain() throws {
        transport.reply("v1/pages/page-1", ["id": "page-1", "archived": true])
        transport.reply("v1/pages", ["id": "page-2"])
        let id = try destination(.init(id: "notion", parentPageId: "p", includeImages: false)).upsert(
            makeNote(), previous: DestinationRecord(externalID: "page-1", contentHash: "old", syncedAt: Date())
        )
        XCTAssertEqual(id, "page-2")
    }

    func testLongTextIsSplitAndManyBlocksAreAppendedInBatches() throws {
        let long = String(repeating: "a", count: 4500)
        let many = (1...150).map { "para \($0)" }.joined(separator: "\n\n")
        let blocks = try NotionDestination.blocks(for: makeNote(pages: [RecognizedPage(number: 1, text: long + "\n\n" + many)]), images: [])
        XCTAssertEqual(blocks.count, 3 + 150 + 1)

        transport.reply("v1/pages", ["id": "page-1"])
        transport.reply("v1/blocks/page-1/children", ["results": []])
        _ = try destination(.init(id: "notion", parentPageId: "p", includeImages: false)).upsert(makeNote(pages: [RecognizedPage(number: 1, text: long + "\n\n" + many)]), previous: nil)
        XCTAssertEqual((transport.requests(to: "v1/pages").first?.body["children"] as? [Any])?.count, 100)
        XCTAssertEqual((transport.requests(to: "v1/blocks/page-1/children").first?.body["children"] as? [Any])?.count, 54)
    }

    func testRemovalTrashesThePage() throws {
        transport.reply("v1/pages/page-1", ["id": "page-1"])
        try destination().remove(DestinationRecord(externalID: "page-1", contentHash: "h", syncedAt: Date()), export: RemovedExport(sourceID: "s", relativePath: "a.pdf"), policy: .archive)
        XCTAssertEqual(transport.requests(to: "v1/pages/page-1").first?.body["archived"] as? Bool, true)
    }

    func testWithoutATokenItAsksToLogIn() {
        secrets.secrets = [:]
        XCTAssertThrowsError(try destination().upsert(makeNote(), previous: nil)) { error in
            XCTAssertEqual(error as? CloudAPIError, .notSignedIn("Notion", "inkrelay notion login"))
        }
    }

    func testConfigNeedsExactlyOneParent() {
        XCTAssertThrowsError(try DestinationConfig.NotionConfig(id: "n").validate())
        XCTAssertThrowsError(try DestinationConfig.NotionConfig(id: "n", parentPageId: "a", databaseId: "b").validate())
        XCTAssertNoThrow(try DestinationConfig.NotionConfig(id: "n", databaseId: "b").validate())
    }
}
