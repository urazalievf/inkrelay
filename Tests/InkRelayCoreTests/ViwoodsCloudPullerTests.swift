import PDFKit
import XCTest
@testable import InkRelayCore

final class ViwoodsCloudPullerTests: XCTestCase {
    private var cache: TemporaryFolder!
    private var transport: FakeTransport!
    private var plans: FakePlanDestination!
    private var noteModified: Int64 = 100
    private var todoText = "Call the bank"

    override func setUpWithError() throws {
        cache = try TemporaryFolder()
        transport = FakeTransport()
        plans = FakePlanDestination()
        script()
    }

    override func tearDown() {
        cache.remove()
    }

    private func makePuller(apps: [String] = ["paper", "memo"], daily: Bool = true) throws -> ViwoodsCloudPuller {
        let config = ViwoodsCloudConfig(apps: apps, daily: daily, dailyMonths: 1, cachePath: cache.url.path)
        let client = ViwoodsClient(transport: transport, credentials: MemoryCredentialStore(credentials: .init(token: "t", updatedAt: Date())))
        return try ViwoodsCloudPuller(config: config, client: client, plans: [plans], now: { Date(timeIntervalSince1970: 1_768_000_000) })
    }

    /// A cloud with one Paper folder holding one notebook, one memo, and one planner day with a page and a to-do.
    private func script() {
        transport.handlers["api/v1/resourceSync/getPage"] = { [self] sent in
            let app = sent.body["appType"] as? Int
            let parent = sent.body["resourceId"] as? String
            let list: [[String: Any]]
            switch (app, parent) {
            case (1, ""):
                list = [
                    ["resourceId": "tpl", "name": "My template", "resourceType": 5],
                    ["resourceId": "folder-1", "name": "Work: Q4", "resourceType": 0, "childSize": 1],
                    ["resourceId": "secret", "name": "Diary", "resourceType": 1, "encrypt": 1, "lastModifiedTime": 1],
                ]
            case (1, "folder-1"):
                list = [["resourceId": "note-1", "name": "ll", "resourceType": 1, "lastModifiedTime": noteModified]]
            case (6, ""):
                list = [["resourceId": "memo-1", "name": "Memo 1", "resourceType": 1, "lastModifiedTime": 50, "childSize": 1]]
            default:
                list = []
            }
            return (200, try FakeTransport.envelope(["count": list.count, "list": list]))
        }
        transport.handlers["api/v1/paperSync/get"] = { sent in
            XCTAssertEqual(sent.body["uuid"] as? String, "note-1")
            return (200, try FakeTransport.blobEnvelope([
                "note": ["id": "note-1", "fileName": "ll"],
                "pages": [["page": ["id": "p1", "order": 0]], ["page": ["id": "p2", "order": 1]], ["page": ["id": "gone", "order": 2, "isDeleted": 1]]],
                "resourceRefs": [
                    ["fileName": "screenshotBmp_p1.png", "remoteUrl": "https://cdn.test/p1.png", "ownerPageId": "p1"],
                    ["fileName": "mainBmp_p1.png", "remoteUrl": "https://cdn.test/ink1.png", "ownerPageId": "p1"],
                    ["fileName": "screenshotBmp_p2.png", "remoteUrl": "https://cdn.test/p2.png", "ownerPageId": "p2"],
                    ["fileName": "mainBmp_p2.png", "remoteUrl": "https://cdn.test/ink2.png", "ownerPageId": "p2"],
                    ["fileName": "screenshotBmp_gone.png", "remoteUrl": "https://cdn.test/gone.png", "ownerPageId": "gone"],
                ],
            ]))
        }
        transport.handlers["api/v1/memoSync/get"] = { _ in
            (200, try FakeTransport.blobEnvelope([
                "memoFileInfo": ["id": "memo-1", "fileName": "Memo 1"],
                "memoPageInfos": [["id": "mp1", "order": 1, "pageShotFileName": "https://cdn.test/memo.png"]],
            ]))
        }
        transport.handlers["api/v1/resourceDailySync/getDateList"] = { sent in
            XCTAssertEqual(sent.body["month"] as? String, "2026-01")
            return (200, try FakeTransport.envelope([["date": "2026-01-13", "hasTaskNote": true, "hasTodo": true]]))
        }
        transport.handlers["api/v1/resourceDailySync/getList"] = { [self] sent in
            XCTAssertEqual(sent.body["startDate"] as? String, "2026-01-13")
            switch sent.body["type"] as? Int {
            case 1:
                return (200, try FakeTransport.envelope([
                    ["id": "d1", "date": "2026-1-13", "name": "day_2026_1_13", "type": 1, "pageOrder": 1, "lastModifiedTime": 300, "url": "https://cdn.test/day.png"],
                ]))
            case 2:
                return (200, try FakeTransport.envelope([
                    ["id": "todo-1", "date": "2026-1-13", "type": 2, "content": todoText, "level": 1, "isFinish": 0, "lastModifiedTime": 310],
                ]))
            default:
                return (200, try FakeTransport.envelope([]))
            }
        }
        for name in ["p1", "p2", "gone", "memo", "day", "ink1", "ink2"] {
            transport.handlers["https://cdn.test/\(name).png"] = { _ in (200, makePNG()) }
        }
    }

    private func pageCount(_ relativePath: String) -> Int? {
        PDFDocument(url: cache.url.appendingPathComponent(relativePath))?.pageCount
    }

    func testFirstPullWritesNotebooksMemosAndPlannerDays() throws {
        let report = try makePuller().pull()

        XCTAssertEqual(report.failures, ["Paper/Diary: password-protected notes can't be pulled"])
        XCTAssertEqual(report.checked, 4, "the notebook, the encrypted one, the memo and the planner day")
        XCTAssertEqual(report.updated, 3)
        XCTAssertEqual(pageCount("Paper/Work- Q4/ll.pdf"), 2, "deleted pages are left out and the folder name is made safe")
        XCTAssertEqual(pageCount(".ink/Paper/Work- Q4/ll.pdf"), 2, "the ink layer sits beside the page, hidden from the scanner")
        XCTAssertEqual(pageCount("Memo/Memo 1.pdf"), 1)
        XCTAssertEqual(pageCount("Daily/2026-01-13.pdf"), 1)
        XCTAssertEqual(plans.upserts.count, 1)
        XCTAssertEqual(plans.upserts.first?.todo, DailyTodo(id: "todo-1", date: "2026-01-13", text: "Call the bank", isFinished: false, level: 1, modified: 310))
        XCTAssertNil(plans.upserts.first?.previous)
        XCTAssertEqual(report.plansDelivered, 1)
        XCTAssertFalse(transport.sent.contains { $0.request.url?.absoluteString == "https://cdn.test/gone.png" })

        // Dated by the cloud's milliseconds, not the pull: the notebook 100, the memo 50, the day its newest item 310.
        func modified(_ relativePath: String) throws -> TimeInterval? {
            try (FileManager.default.attributesOfItem(atPath: cache.url.appendingPathComponent(relativePath).path)[.modificationDate] as? Date)?.timeIntervalSince1970
        }
        XCTAssertEqual(try XCTUnwrap(modified("Paper/Work- Q4/ll.pdf")), 0.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(modified("Memo/Memo 1.pdf")), 0.05, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(modified("Daily/2026-01-13.pdf")), 0.31, accuracy: 0.001)
    }

    func testSecondPullDownloadsNothingWhenNothingChanged() throws {
        _ = try makePuller().pull()
        let downloadsBefore = transport.sent.filter { $0.request.url?.host == "cdn.test" }.count

        let report = try makePuller().pull()

        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.unchanged, 3)
        XCTAssertEqual(transport.sent.filter { $0.request.url?.host == "cdn.test" }.count, downloadsBefore)
        XCTAssertEqual(plans.upserts.count, 1, "the unchanged to-do isn't sent again")
    }

    func testChangedNotebookIsRewrittenAndChangedTodoIsUpdatedInPlace() throws {
        _ = try makePuller().pull()
        noteModified = 200
        todoText = "Call the bank, again"
        transport.handlers["api/v1/resourceDailySync/getList"] = { [self] sent in
            switch sent.body["type"] as? Int {
            case 2:
                return (200, try FakeTransport.envelope([
                    ["id": "todo-1", "date": "2026-1-13", "type": 2, "content": todoText, "level": 1, "isFinish": 1, "lastModifiedTime": 400],
                ]))
            default:
                return (200, try FakeTransport.envelope([]))
            }
        }

        let report = try makePuller().pull()

        XCTAssertEqual(report.updated, 2, "the notebook and the planner day")
        XCTAssertEqual(plans.upserts.count, 2)
        XCTAssertEqual(plans.upserts.last?.previous, "event-todo-1")
        XCTAssertEqual(plans.upserts.last?.todo.isFinished, true)
    }

    func testRenamedNotebookReplacesTheOldPDF() throws {
        _ = try makePuller().pull()
        noteModified = 300
        let original = transport.handlers["api/v1/resourceSync/getPage"]!
        transport.handlers["api/v1/resourceSync/getPage"] = { sent in
            if sent.body["resourceId"] as? String == "folder-1" {
                return (200, try FakeTransport.envelope(["count": 1, "list": [
                    ["resourceId": "note-1", "name": "Renamed", "resourceType": 1, "lastModifiedTime": 300],
                ]]))
            }
            return try original(sent)
        }

        _ = try makePuller().pull()

        XCTAssertNil(pageCount("Paper/Work- Q4/ll.pdf"))
        XCTAssertEqual(pageCount("Paper/Work- Q4/Renamed.pdf"), 2)
        XCTAssertNil(pageCount(".ink/Paper/Work- Q4/ll.pdf"))
        XCTAssertEqual(pageCount(".ink/Paper/Work- Q4/Renamed.pdf"), 2)
    }

    func testRenameWithoutNewInkMovesTheCachedPDFByteForByte() throws {
        _ = try makePuller().pull()
        let before = try Data(contentsOf: cache.url.appendingPathComponent("Paper/Work- Q4/ll.pdf"))
        let downloads = transport.sent.filter { $0.request.url?.host == "cdn.test" }.count
        let original = transport.handlers["api/v1/resourceSync/getPage"]!
        transport.handlers["api/v1/resourceSync/getPage"] = { sent in
            if sent.body["resourceId"] as? String == "folder-1" {
                return (200, try FakeTransport.envelope(["count": 1, "list": [
                    ["resourceId": "note-1", "name": "Renamed", "resourceType": 1, "lastModifiedTime": 100],
                ]]))
            }
            return try original(sent)
        }

        _ = try makePuller().pull()

        XCTAssertEqual(try Data(contentsOf: cache.url.appendingPathComponent("Paper/Work- Q4/Renamed.pdf")), before, "same bytes, so the relay sees a rename")
        XCTAssertEqual(transport.sent.filter { $0.request.url?.host == "cdn.test" }.count, downloads, "nothing downloaded again")
        XCTAssertEqual(pageCount(".ink/Paper/Work- Q4/Renamed.pdf"), 2, "the ink copy moved too")
    }

    func testNotebooksDeletedInTheCloudLeaveTheCache() throws {
        _ = try makePuller().pull()
        let original = transport.handlers["api/v1/resourceSync/getPage"]!
        transport.handlers["api/v1/resourceSync/getPage"] = { sent in
            if sent.body["appType"] as? Int == 6 { return (200, try FakeTransport.envelope(["count": 0, "list": []])) }
            return try original(sent)
        }

        let report = try makePuller().pull()

        XCTAssertEqual(report.removed, 1)
        XCTAssertNil(pageCount("Memo/Memo 1.pdf"))
        XCTAssertEqual(pageCount("Paper/Work- Q4/ll.pdf"), 2)
    }

    func testAFailedListingRemovesNothing() throws {
        _ = try makePuller().pull()
        transport.handlers["api/v1/resourceSync/getPage"] = { _ in (500, Data()) }

        let report = try makePuller().pull()

        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(pageCount("Memo/Memo 1.pdf"), 1)
    }

    func testCloudErrorsAreReportedPerAppWithoutStoppingTheRest() throws {
        transport.handlers["api/v1/memoSync/get"] = { _ in (500, Data()) }

        let report = try makePuller().pull()

        XCTAssertTrue(report.failures.contains { $0.hasPrefix("Memo/Memo 1: ") })
        XCTAssertEqual(pageCount("Paper/Work- Q4/ll.pdf"), 2)
        XCTAssertEqual(pageCount("Daily/2026-01-13.pdf"), 1)
    }

    func testRecentMonthsCountBackFromNow() throws {
        let config = ViwoodsCloudConfig(dailyMonths: 3, cachePath: cache.url.path)
        let client = ViwoodsClient(transport: transport, credentials: MemoryCredentialStore())
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 15
        let january = Calendar(identifier: .gregorian).date(from: components)!
        let puller = try ViwoodsCloudPuller(config: config, client: client, plans: [], now: { january })

        XCTAssertEqual(puller.recentMonths(), ["2026-01", "2025-12", "2025-11"])
    }

    func testConfigDefaultsAndValidation() throws {
        let decoded = try JSONDecoder().decode(ViwoodsCloudConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, ViwoodsCloudConfig())
        XCTAssertEqual(decoded.enabledApps, [.paper, .meeting, .memo])
        XCTAssertEqual(decoded.source.id, "viwoods-cloud")
        XCTAssertTrue(decoded.cacheURL.path.hasSuffix("Application Support/InkRelay/viwoods"))
        XCTAssertThrowsError(try ViwoodsCloudConfig(apps: ["paper", "reader"]).validate())
        XCTAssertThrowsError(try ViwoodsCloudConfig(dailyMonths: 0).validate())
        var negative = ViwoodsCloudConfig()
        negative.aiMonthlyBudgetUSD = -1
        XCTAssertThrowsError(try negative.validate())
    }
}
