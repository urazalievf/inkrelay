import XCTest
@testable import InkRelayCore

final class ReviewStackTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var store: ReviewStore!
    private var clock = Date(timeIntervalSince1970: 1_792_000_000) // a Friday, 2026-10-16 UTC
    private var images: [Data] = []

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        store = ReviewStore(directory: folder.url.appendingPathComponent("review"))
        images = [Data("ink-1".utf8), Data("ink-2".utf8)]
    }

    override func tearDown() {
        folder.remove()
    }

    private func destination(resurface: [Int] = [], limit: Int = 25) -> ReviewStackDestination {
        ReviewStackDestination(
            config: .init(id: "stack", dailyLimit: limit, resurfaceDays: resurface),
            store: store,
            renderImages: { [unowned self] _ in self.images },
            now: { [unowned self] in self.clock }
        )
    }

    private func twoPageNote(_ title: String = "Meeting notes", second: String = "page two") -> InkNote {
        makeNote(title: title, relativePath: "Paper/Work/\(title).pdf", pages: [RecognizedPage(number: 1, text: "page one"), RecognizedPage(number: 2, text: second)])
    }

    private func todaysStack(limit: Int = 25) throws -> [ReviewCard] {
        try store.stack(now: clock, limit: limit).cards
    }

    func testEveryPageBecomesACardWithItsImage() throws {
        _ = try destination().upsert(twoPageNote(), previous: nil)

        let cards = try todaysStack()
        XCTAssertEqual(cards.map(\.page), [1, 2])
        XCTAssertEqual(cards.map(\.subtitle), ["Page 1 of 2 · Paper/Work", "Page 2 of 2 · Paper/Work"])
        XCTAssertEqual(cards.map(\.status), [.new, .new])
        XCTAssertEqual(try Data(contentsOf: store.imageURL(for: cards[1].id)), Data("ink-2".utf8))
    }

    func testOnlyTheChangedPageComesBack() throws {
        _ = try destination().upsert(twoPageNote(), previous: nil)
        for card in try todaysStack() { try store.markDone(card.id, now: clock, resurfaceDays: []) }
        XCTAssertTrue(try todaysStack().isEmpty)

        clock += 3600
        images[1] = Data("ink-2 with more ink".utf8)
        _ = try destination().upsert(twoPageNote(second: "page two, continued"), previous: nil)

        let cards = try todaysStack()
        XCTAssertEqual(cards.map(\.page), [2], "page 1 is unchanged and stays done")
        XCTAssertEqual(cards.first?.text, "page two, continued")
        XCTAssertEqual(cards.first?.reviews, 0)
    }

    func testRemovedPagesLeaveTheStack() throws {
        _ = try destination().upsert(twoPageNote(), previous: nil)
        let second = try todaysStack()[1].id
        images = [images[0]]

        _ = try destination().upsert(makeNote(title: "Meeting notes", relativePath: "Paper/Work/Meeting notes.pdf", pages: [RecognizedPage(number: 1, text: "page one")]), previous: nil)

        XCTAssertEqual(try todaysStack().map(\.page), [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(for: second).path))
    }

    func testNewestNotebookFirstWithPagesInOrderAndADailyLimit() throws {
        _ = try destination().upsert(twoPageNote("Older"), previous: nil)
        clock += 60
        _ = try destination().upsert(twoPageNote("Newer"), previous: nil)

        let (cards, due) = try store.stack(now: clock, limit: 3)
        XCTAssertEqual(cards.map { "\($0.title) \($0.page!)" }, ["Newer 1", "Newer 2", "Older 1"])
        XCTAssertEqual(due, 4)
    }

    func testDoneResurfacesOnScheduleThenRetires() throws {
        _ = try destination().upsert(twoPageNote(), previous: nil)
        let id = try todaysStack()[0].id

        let first = try store.markDone(id, now: clock, resurfaceDays: [3, 10], calendar: utc)
        XCTAssertEqual(first?.status, .resurfacing)
        XCTAssertEqual(first?.dueAt, utc.date(byAdding: .day, value: 3, to: utc.startOfDay(for: clock)))
        XCTAssertFalse(try todaysStack().contains { $0.id == id })

        clock = utc.date(byAdding: .day, value: 3, to: clock)!
        XCTAssertTrue(try todaysStack().contains { $0.id == id })
        XCTAssertEqual(try store.markDone(id, now: clock, resurfaceDays: [3, 10], calendar: utc)?.dueAt, utc.date(byAdding: .day, value: 10, to: utc.startOfDay(for: clock)))
        XCTAssertEqual(try store.markDone(id, now: clock, resurfaceDays: [3, 10], calendar: utc)?.status, .done)
    }

    func testLaterMeansTheStartOfTomorrow() throws {
        _ = try destination().upsert(twoPageNote(), previous: nil)
        let id = try todaysStack()[0].id

        let snoozed = try store.snooze(id, now: clock, calendar: utc)

        XCTAssertEqual(snoozed?.status, .snoozed)
        XCTAssertEqual(snoozed?.dueAt, utc.date(byAdding: .day, value: 1, to: utc.startOfDay(for: clock)))
        XCTAssertEqual(try todaysStack().count, 1)
    }

    func testTodosTickedOffOnTheTabletLeaveTheStack() throws {
        let open = DailyTodo(id: "t1", date: "2026-01-13", text: "Call the bank\nabout the card", isFinished: false, level: 0, modified: 1)
        _ = try destination().upsert(open, previous: nil)
        let card = try XCTUnwrap(try todaysStack().first)
        XCTAssertEqual(card.kind, .todo)
        XCTAssertEqual(card.title, "Call the bank")
        XCTAssertEqual(card.subtitle, "To-do · Tue, Jan 13, 2026 · Important and urgent")
        XCTAssertFalse(card.hasImage)

        var done = open
        done.isFinished = true
        _ = try destination().upsert(done, previous: "review:todo/t1")
        XCTAssertTrue(try todaysStack().isEmpty)
    }

    func testRenamedNotebookKeepsItsCardsAndTheirStatus() throws {
        let handle = try destination().upsert(twoPageNote(), previous: nil)
        let firstPage = try todaysStack()[0]
        try store.markDone(firstPage.id, now: clock, resurfaceDays: [])

        _ = try destination().upsert(
            makeNote(title: "Renamed", relativePath: "Paper/Renamed.pdf", pages: [RecognizedPage(number: 1, text: "page one"), RecognizedPage(number: 2, text: "page two")]),
            previous: DestinationRecord(externalID: handle, contentHash: "h", syncedAt: clock)
        )

        let state = try store.load()
        XCTAssertEqual(state.cards.count, 2)
        XCTAssertTrue(state.cards.values.allSatisfy { $0.itemKey == "viwoods/Paper/Renamed.pdf" })
        XCTAssertEqual(try todaysStack().map(\.page), [2], "page one stays done after the rename")
        XCTAssertEqual(try todaysStack().first?.title, "Renamed")
    }

    func testRemovalDropsTheItemsCards() throws {
        let handle = try destination().upsert(twoPageNote(), previous: nil)
        try destination().remove(DestinationRecord(externalID: handle, contentHash: "h", syncedAt: clock), export: RemovedExport(sourceID: "viwoods", relativePath: "Paper/Work/Meeting notes.pdf"), policy: .archive)
        XCTAssertTrue(try store.load().cards.isEmpty)
    }

    func testPlannerPagesGetAFriendlyTitle() throws {
        _ = try destination().upsert(plannerNote("2026-01-13"), previous: nil)
        XCTAssertEqual(try todaysStack().first?.title, "Daily plan · Tue, Jan 13, 2026")
    }

    func testRendersRealPDFPagesWhenNoRendererIsInjected() throws {
        let pdf = folder.url.appendingPathComponent("Real.pdf")
        try makeTextPDF(at: pdf, lines: ["Hello stack"])
        let real = ReviewStackDestination(config: .init(id: "stack"), store: store, now: { [unowned self] in self.clock })

        _ = try real.upsert(makeNote(title: "Real", relativePath: "Real.pdf", originalURL: pdf, pages: [RecognizedPage(number: 1, text: "Hello stack")]), previous: nil)

        let card = try XCTUnwrap(try todaysStack().first)
        XCTAssertTrue(card.hasImage)
        let jpeg = try Data(contentsOf: store.imageURL(for: card.id))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "a JPEG")
    }

    func testShortIdsResolveWhenUnambiguous() throws {
        _ = try destination().upsert(twoPageNote(), previous: nil)
        let id = try todaysStack()[0].id
        XCTAssertEqual(try store.resolve(String(id.prefix(6))), id)
        XCTAssertNil(try store.resolve(""), "an empty prefix matches every card")
    }

    // MARK: Server

    private func server(resurface: [Int] = []) -> ReviewServer {
        ReviewServer(store: store, config: .init(id: "stack", resurfaceDays: resurface), now: { [unowned self] in self.clock })
    }

    private func get(_ path: String, host: String = "127.0.0.1:7788") -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, headers: ["host": host])
    }

    func testServesThePageTheStackAndImages() throws {
        _ = try destination().upsert(twoPageNote(), previous: nil)
        let server = server()

        let page = server.route(get("/"))
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("<title>Ink Stack</title>"))

        let stack = server.route(get("/api/stack"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: stack.body) as? [String: Any])
        let cards = try XCTUnwrap(json["cards"] as? [[String: Any]])
        XCTAssertEqual(json["due"] as? Int, 2)
        XCTAssertEqual(cards.first?["title"] as? String, "Meeting notes")
        let imagePath = try XCTUnwrap(cards.first?["image"] as? String)
        XCTAssertTrue(imagePath.hasPrefix("/images/"))

        let image = server.route(get(String(imagePath.split(separator: "?")[0])))
        XCTAssertEqual(image.status, 200)
        XCTAssertEqual(image.contentType, "image/jpeg")
        XCTAssertEqual(image.body, Data("ink-1".utf8))
    }

    func testActionsNeedTheHeaderAndALoopbackHost() throws {
        _ = try destination().upsert(twoPageNote(), previous: nil)
        let id = try todaysStack()[0].id
        let server = server()

        XCTAssertEqual(server.route(get("/api/stack", host: "evil.example:7788")).status, 403, "DNS rebinding")
        XCTAssertEqual(server.route(HTTPRequest(method: "POST", path: "/api/cards/\(id)/done", headers: ["host": "localhost:7788"])).status, 403, "no X-InkRelay header")
        XCTAssertEqual(server.route(get("/images/../stack.json")).status, 404)
        XCTAssertEqual(server.route(HTTPRequest(method: "POST", path: "/api/cards/0000000000000000/done", headers: ["host": "[::1]:7788", "x-inkrelay": "1"])).status, 404)

        let done = server.route(HTTPRequest(method: "POST", path: "/api/cards/\(id)/done", headers: ["host": "127.0.0.1:7788", "x-inkrelay": "1"]))
        XCTAssertEqual(done.status, 200)
        XCTAssertEqual(try store.load().cards[id]?.status, .done)
    }

    func testServesOverRealLoopbackHTTP() throws {
        _ = try destination().upsert(twoPageNote(), previous: nil)
        let server = server()
        let base = try server.start(port: 0)
        defer { server.stop() }

        let fetched = expectation(description: "stack fetched")
        var status = 0
        var due: Int?
        URLSession.shared.dataTask(with: base.appendingPathComponent("api/stack")) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            due = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["due"] as? Int
            fetched.fulfill()
        }.resume()
        wait(for: [fetched], timeout: 5)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(due, 2)
        XCTAssertEqual(base.host, "127.0.0.1")
    }

    // MARK: HTTP parsing

    func testParsesRequestsOnlyOnceTheBodyHasArrived() throws {
        let head = "POST /api/cards/abc/done?x=1&name=a%20b HTTP/1.1\r\nHost: 127.0.0.1:7788\r\nContent-Length: 4\r\nX-InkRelay: 1\r\n\r\n"
        XCTAssertNil(try HTTPRequest.parse(Data((head + "ab").utf8)))

        let request = try XCTUnwrap(try HTTPRequest.parse(Data((head + "abcd").utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/cards/abc/done")
        XCTAssertEqual(request.query, ["x": "1", "name": "a b"])
        XCTAssertEqual(request.headers["x-inkrelay"], "1")
        XCTAssertEqual(request.body, Data("abcd".utf8))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("GARBAGE\r\n\r\n".utf8)))
    }
}
