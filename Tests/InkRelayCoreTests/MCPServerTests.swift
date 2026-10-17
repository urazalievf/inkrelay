import XCTest
@testable import InkRelayCore

final class MCPServerTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var configURL: URL!
    private var syncs = 0
    private var sent: [(String, String?, String?)] = []

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        configURL = folder.url.appendingPathComponent("config.json")
        let config = RelayConfig(
            sources: [SourceConfig(id: "viwoods", device: "Viwoods AiPaper", path: folder.url.path), SourceConfig(id: "boox", device: "Boox", path: folder.url.path)],
            destinations: [.reviewStack(.init(id: "review"))]
        )
        try ConfigStore.save(config, to: configURL)
        let archive = NoteArchive(directory: folder.url.appendingPathComponent("archive"))
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try archive.upsert(note("Weekly plan", "viwoods", "Paper/Weekly plan.pdf", "☐ Call the bank about the café card\n☑ Book flights\nTODO: renew passport", base), key: "viwoods/Paper/Weekly plan.pdf")
        try archive.upsert(note("Ideas", "viwoods", "Paper/Ideas.pdf", "Imprint style cards for my own notes", base.addingTimeInterval(60)), key: "viwoods/Paper/Ideas.pdf")
        try archive.upsert(note("Reading", "boox", "Reading.pdf", "Notes on calm technology", base.addingTimeInterval(120)), key: "boox/Reading.pdf")
    }

    override func tearDown() {
        folder.remove()
    }

    private func note(_ title: String, _ source: String, _ path: String, _ text: String, _ modified: Date) -> InkNote {
        InkNote(title: title, sourceID: source, device: source == "boox" ? "Boox" : "Viwoods AiPaper", originalURL: URL(fileURLWithPath: "/tmp/" + path),
                relativePath: path, modified: modified, contentHash: title, pages: [RecognizedPage(number: 1, text: text)])
    }

    private func server() -> MCPServer {
        MCPServer(configURL: configURL, sync: { [unowned self] _, _ in
            self.syncs += 1
            var report = SyncReport()
            report.scanned = 3
            report.synced = 1
            return report
        }, send: { [unowned self] _, input, target, title in
            self.sent.append((input, target, title))
            return "Saved to the tablet."
        })
    }

    /// Sends one request through the same path stdio uses and decodes the reply.
    private func call(_ method: String, _ params: [String: Any]? = nil, id: Int = 1) throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        let reply = try XCTUnwrap(server().handle(line: line))
        XCTAssertFalse(reply.contains("\n"), "stdio messages can't contain newlines")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func tool(_ name: String, _ arguments: [String: Any] = [:]) throws -> (output: [String: Any], isError: Bool, text: String) {
        let reply = try call("tools/call", ["name": name, "arguments": arguments])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (result["structuredContent"] as? [String: Any] ?? [:], result["isError"] as? Bool == true, text)
    }

    func testInitializeNegotiatesTheProtocolVersion() throws {
        let known = try XCTUnwrap(try call("initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any])
        XCTAssertEqual(known["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((known["serverInfo"] as? [String: Any])?["name"] as? String, "inkrelay")
        XCTAssertNotNil((known["capabilities"] as? [String: Any])?["tools"])
        XCTAssertTrue((known["instructions"] as? String)?.contains("inkrelay_search_notes") == true)

        let future = try XCTUnwrap(try call("initialize", ["protocolVersion": "2099-01-01"])["result"] as? [String: Any])
        XCTAssertEqual(future["protocolVersion"] as? String, MCPServer.protocolVersions[0], "an unknown version gets our latest")
    }

    func testNotificationsGetNoReplyAndBadInputGetsJSONRPCErrors() throws {
        XCTAssertNil(server().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server().handle(line: "   "))
        let parse = try XCTUnwrap(server().handle(line: "{not json"))
        XCTAssertTrue(parse.contains("-32700"))
        XCTAssertEqual((try call("resources/list")["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((try call("tools/call", ["name": "inkrelay_delete_everything"])["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertNotNil(try call("ping")["result"])
    }

    func testToolsAreListedWithSchemasAndAnnotations() throws {
        let tools = try XCTUnwrap((try call("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 9)
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertTrue(name.hasPrefix("inkrelay_"), name)
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            XCTAssertNotNil(annotations["readOnlyHint"] as? Bool, name)
        }
        let readOnly = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"] as! String, ($0["annotations"] as! [String: Any])["readOnlyHint"] as! Bool) })
        XCTAssertEqual(readOnly["inkrelay_search_notes"], true)
        XCTAssertEqual(readOnly["inkrelay_sync_now"], false)
    }

    func testSearchMatchesEveryWordIgnoringCaseAndAccents() throws {
        let hit = try tool("inkrelay_search_notes", ["query": "BANK cafe"])
        XCTAssertFalse(hit.isError)
        let results = try XCTUnwrap(hit.output["results"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["title"] as? String }, ["Weekly plan"])
        XCTAssertTrue((results.first?["snippet"] as? String)?.contains("bank") == true)
        XCTAssertTrue(hit.text.contains("\"total_count\""), "the text carries the same JSON")

        XCTAssertEqual((try tool("inkrelay_search_notes", ["query": "bank flights", "source": "boox"]).output["results"] as? [Any])?.count, 0)
        XCTAssertTrue(try tool("inkrelay_search_notes", ["query": "  "]).isError)
    }

    func testListingPagesNewestFirst() throws {
        let first = try tool("inkrelay_list_notes", ["limit": 2]).output
        XCTAssertEqual((first["notes"] as? [[String: Any]])?.map { $0["title"] as? String }, ["Reading", "Ideas"])
        XCTAssertEqual(first["has_more"] as? Bool, true)
        XCTAssertEqual(first["next_offset"] as? Int, 2)
        let second = try tool("inkrelay_list_notes", ["limit": 2, "offset": 2]).output
        XCTAssertEqual((second["notes"] as? [[String: Any]])?.map { $0["title"] as? String }, ["Weekly plan"])
        XCTAssertEqual(second["has_more"] as? Bool, false)
        XCTAssertEqual(try tool("inkrelay_list_notes", ["source": "boox"]).output["total_count"] as? Int, 1)
    }

    func testReadingANoteByAShortIdIncludesItsTasks() throws {
        let id = NoteArchive.id(forKey: "viwoods/Paper/Weekly plan.pdf")
        let note = try tool("inkrelay_get_note", ["id": String(id.prefix(6))]).output
        XCTAssertEqual(note["title"] as? String, "Weekly plan")
        XCTAssertEqual((note["pages"] as? [[String: Any]])?.first?["number"] as? Int, 1)
        XCTAssertEqual((note["tasks"] as? [[String: Any]])?.map { $0["text"] as? String }, ["Call the bank about the café card", "Book flights", "renew passport"])
        XCTAssertTrue(try tool("inkrelay_get_note", ["id": "ffffffff"]).isError)
    }

    func testTasksFilterByStatus() throws {
        let open = try XCTUnwrap(try tool("inkrelay_list_tasks").output["tasks"] as? [[String: Any]])
        XCTAssertEqual(open.map { $0["text"] as? String }, ["Call the bank about the café card", "renew passport"])
        XCTAssertEqual(open.first?["note_title"] as? String, "Weekly plan")
        XCTAssertEqual((try tool("inkrelay_list_tasks", ["status": "done"]).output["tasks"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(try tool("inkrelay_list_tasks", ["status": "someday"]).isError)
    }

    func testReviewCardsCanBeWorkedThrough() throws {
        let store = ReviewStore(directory: folder.url.appendingPathComponent("review"))
        _ = try ReviewStackDestination(config: .init(id: "review"), store: store, renderImages: { _ in [] })
            .upsert(note("Ideas", "viwoods", "Paper/Ideas.pdf", "page", Date()), previous: nil)
        let stack = try tool("inkrelay_review_stack").output
        XCTAssertEqual(stack["due"] as? Int, 1)
        let id = try XCTUnwrap((stack["cards"] as? [[String: Any]])?.first?["id"] as? String)

        let later = try tool("inkrelay_review_card", ["id": String(id.prefix(6)), "action": "later"]).output
        XCTAssertEqual(later["status"] as? String, "snoozed")
        XCTAssertEqual(try tool("inkrelay_review_stack").output["due"] as? Int, 0)
        XCTAssertTrue(try tool("inkrelay_review_card", ["id": id, "action": "accept"]).isError, "not an event")
        XCTAssertTrue(try tool("inkrelay_review_card", ["id": "nope", "action": "done"]).isError)
    }

    func testSyncAndSendGoThroughTheirHandlers() throws {
        let sync = try tool("inkrelay_sync_now").output
        XCTAssertEqual(syncs, 1)
        XCTAssertEqual(sync["synced"] as? Int, 1)
        XCTAssertEqual(sync["summary"] as? String, "3 found, 1 synced, 0 unchanged")

        let send = try tool("inkrelay_send_to_tablet", ["input": "https://example.com/a", "title": "A"]).output
        XCTAssertEqual(send["result"] as? String, "Saved to the tablet.")
        XCTAssertEqual(sent.first?.0, "https://example.com/a")
        XCTAssertEqual(sent.first?.2, "A")
    }

    func testStatusSummarizesSourcesAndTheArchive() throws {
        let status = try tool("inkrelay_status").output
        XCTAssertEqual((status["sources"] as? [[String: Any]])?.map { $0["id"] as? String }, ["viwoods", "boox"])
        XCTAssertEqual(status["notes_searchable"] as? Int, 3)
        XCTAssertEqual(status["review_cards_due"] as? Int, 0)
    }

    func testAMissingConfigExplainsHowToSetUp() throws {
        try FileManager.default.removeItem(at: configURL)
        let status = try tool("inkrelay_status")
        XCTAssertTrue(status.isError)
        XCTAssertTrue(status.text.contains("inkrelay setup"))
    }

    func testTheEngineArchivesWhatItRelaysAndForgetsWhatsDeleted() throws {
        let exports = try TemporaryFolder()
        defer { exports.remove() }
        try exports.write("Keep.pdf", "keep")
        let gone = try exports.write("Gone.pdf", "gone")
        let support = folder.url.appendingPathComponent("engine")
        let destination = FakeDestination(id: "vault")
        let start = Date()
        func engine(_ at: Date) throws -> RelayEngine {
            let config = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: exports.url.path)], destinations: [.appleNotes(.init(id: "vault"))], onDelete: ["vault": .delete], settleSeconds: 0)
            return RelayEngine(config: config, store: try StateStore(url: support.appendingPathComponent("state.json")), recognizer: FakeRecognizer(), destinations: [destination], now: { at })
        }
        _ = try engine(start).syncOnce()
        let archive = NoteArchive(directory: support.appendingPathComponent("archive"))
        XCTAssertEqual(Set(archive.all().map(\.title)), ["Keep", "Gone"])
        XCTAssertEqual(archive.entry(forKey: "s/Keep.pdf")?.text, "hello from the tablet")

        try FileManager.default.removeItem(at: gone)
        _ = try engine(start.addingTimeInterval(10)).syncOnce()
        _ = try engine(start.addingTimeInterval(120)).syncOnce()
        XCTAssertEqual(archive.all().map(\.title), ["Keep"])
    }

    func testNotesSyncedBeforeTheArchiveAreBackfilledWithVisionOnce() throws {
        let exports = try TemporaryFolder()
        defer { exports.remove() }
        try exports.write("Old.pdf", "old")
        let support = folder.url.appendingPathComponent("backfill")
        let recognizer = FakeRecognizer()
        let config = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: exports.url.path)], destinations: [.appleNotes(.init(id: "vault"))], settleSeconds: 0)
        func engine() throws -> RelayEngine {
            RelayEngine(config: config, store: try StateStore(url: support.appendingPathComponent("state.json")), recognizer: recognizer, destinations: [FakeDestination(id: "vault")])
        }
        _ = try engine().syncOnce()
        try FileManager.default.removeItem(at: support.appendingPathComponent("archive"))

        _ = try engine().syncOnce()
        XCTAssertEqual(recognizer.calls.count, 2, "read once more to fill the archive")
        XCTAssertEqual(NoteArchive(directory: support.appendingPathComponent("archive")).all().count, 1)
        _ = try engine().syncOnce()
        XCTAssertEqual(recognizer.calls.count, 2, "and only once")
    }
}
