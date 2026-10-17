import XCTest
@testable import InkRelayCore

final class CloudDestinationTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var transport: FakeTransport!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        transport = FakeTransport()
    }

    override func tearDown() {
        folder.remove()
    }

    // MARK: Google Calendar

    private func googleCalendar() throws -> GoogleCalendarDestination {
        GoogleCalendarDestination(config: .init(id: "gcal", calendar: "Viwoods"), account: try signedInGoogle(transport, in: folder))
    }

    func testGoogleCalendarCreatesItsCalendarOnceAndFilesAllDayEvents() throws {
        transport.handlers["calendar/v3/calendars"] = { sent in
            XCTAssertEqual(sent.body["summary"] as? String, "Viwoods")
            return (200, try jsonData(["id": "cal-1@group.calendar.google.com"]))
        }
        var created = 0
        transport.handlers["calendar/v3/calendars/cal-1@group.calendar.google.com/events"] = { sent in
            created += 1
            return (200, try jsonData(["id": "evt-\(created)"]))
        }

        let first = try googleCalendar().upsert(plannerNote(), previous: nil)
        // A new instance, as on the next run: the calendar id comes from disk, not a second create.
        let second = try googleCalendar().upsert(DailyTodo(id: "t", date: "2026-01-31", text: "Renew passport", isFinished: false, level: nil, modified: 1), previous: nil)

        XCTAssertEqual([first, second], ["evt-1", "evt-2"])
        XCTAssertEqual(transport.requests(to: "calendar/v3/calendars").count, 1)
        let events = transport.requests(to: "calendar/v3/calendars/cal-1@group.calendar.google.com/events")
        XCTAssertEqual(events[0].body["summary"] as? String, "Daily plan")
        XCTAssertEqual((events[0].body["start"] as? [String: Any])?["date"] as? String, "2026-01-13")
        XCTAssertEqual((events[0].body["end"] as? [String: Any])?["date"] as? String, "2026-01-14")
        XCTAssertEqual((events[1].body["end"] as? [String: Any])?["date"] as? String, "2026-02-01")
        XCTAssertEqual(events[1].body["summary"] as? String, "☐ Renew passport")
        XCTAssertEqual(events[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
    }

    func testGoogleCalendarUpdatesInPlaceAndRecreatesDeletedEvents() throws {
        transport.reply("calendar/v3/calendars", ["id": "cal"])
        transport.reply("calendar/v3/calendars/cal/events/evt-1", ["id": "evt-1"])
        transport.reply("calendar/v3/calendars/cal/events/gone", status: 410, ["error": ["message": "Resource has been deleted"]])
        transport.reply("calendar/v3/calendars/cal/events", ["id": "evt-new"])
        let destination = try googleCalendar()

        XCTAssertEqual(try destination.upsert(plannerNote(), previous: DestinationRecord(externalID: "evt-1", contentHash: "x", syncedAt: Date())), "evt-1")
        XCTAssertEqual(transport.requests(to: "calendar/v3/calendars/cal/events/evt-1").first?.request.httpMethod, "PATCH")
        XCTAssertEqual(try destination.upsert(plannerNote(), previous: DestinationRecord(externalID: "gone", contentHash: "x", syncedAt: Date())), "evt-new")
    }

    func testGoogleCalendarMakesANewCalendarWhenTheOldOneWasDeleted() throws {
        var calendars = 0
        transport.handlers["calendar/v3/calendars"] = { _ in
            calendars += 1
            return (200, try jsonData(["id": "cal-\(calendars)"]))
        }
        transport.reply("calendar/v3/calendars/cal-1/events", status: 404, ["error": ["message": "Not Found"]])
        transport.reply("calendar/v3/calendars/cal-2/events", ["id": "evt"])

        XCTAssertEqual(try googleCalendar().upsert(plannerNote(), previous: nil), "evt")
        XCTAssertEqual(calendars, 2)
    }

    func testCalendarsIgnoreNotebooksThatArentPlannerPages() throws {
        XCTAssertEqual(try googleCalendar().upsert(makeNote(), previous: nil), PlannerEvent.skipped)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    // MARK: Google Docs

    func testGoogleDocsCreatesAFolderAndUploadsHTMLAsADoc() throws {
        transport.handlers["drive/v3/files"] = { sent in
            XCTAssertEqual(sent.body["mimeType"] as? String, "application/vnd.google-apps.folder")
            XCTAssertEqual(sent.body["name"] as? String, "Ink")
            return (200, try jsonData(["id": "folder-1"]))
        }
        transport.reply("upload/drive/v3/files", ["id": "doc-1"])
        let destination = GoogleDocsDestination(config: .init(id: "docs"), account: try signedInGoogle(transport, in: folder))

        let id = try destination.upsert(makeNote(title: "Q4 & plans"), previous: nil)

        XCTAssertEqual(id, "doc-1")
        let upload = try XCTUnwrap(transport.requests(to: "upload/drive/v3/files").first)
        XCTAssertEqual(upload.request.url?.query, "uploadType=multipart")
        XCTAssertTrue(upload.request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/related; boundary=") == true)
        let body = bodyText(upload)
        XCTAssertTrue(body.contains("\"parents\":[\"folder-1\"]"))
        XCTAssertTrue(body.contains("\"mimeType\":\"application\\/vnd.google-apps.document\"") || body.contains("\"mimeType\":\"application/vnd.google-apps.document\""))
        XCTAssertTrue(body.contains("<h1>Q4 &amp; plans</h1>"))
        XCTAssertTrue(body.contains("<p>First line</p><p>Second line</p>"))
    }

    func testGoogleDocsReplacesTheDocContentOnUpdate() throws {
        transport.reply("upload/drive/v3/files/doc-1", ["id": "doc-1"])
        let destination = GoogleDocsDestination(config: .init(id: "docs"), account: try signedInGoogle(transport, in: folder))

        let id = try destination.upsert(makeNote(), previous: DestinationRecord(externalID: "doc-1", contentHash: "old", syncedAt: Date()))

        XCTAssertEqual(id, "doc-1")
        let patch = try XCTUnwrap(transport.requests(to: "upload/drive/v3/files/doc-1").first)
        XCTAssertEqual(patch.request.httpMethod, "PATCH")
        XCTAssertEqual(patch.request.url?.query, "uploadType=multipart")
        XCTAssertTrue(bodyText(patch).contains("{\"name\":\"Meeting notes\"}"), "renames follow the export")
    }

    func testRemovalTrashesDocsAndDeletesEventsAndPages() throws {
        transport.reply("drive/v3/files/doc-1", ["id": "doc-1"])
        let docs = GoogleDocsDestination(config: .init(id: "docs"), account: try signedInGoogle(transport, in: folder))
        try docs.remove(DestinationRecord(externalID: "doc-1", contentHash: "h", syncedAt: Date()), export: RemovedExport(sourceID: "s", relativePath: "a.pdf"), policy: .delete)
        XCTAssertEqual(transport.requests(to: "drive/v3/files/doc-1").first?.body["trashed"] as? Bool, true)

        try docs.remove(DestinationRecord(externalID: "doc-2", contentHash: "h", syncedAt: Date()), export: RemovedExport(sourceID: "s", relativePath: "b.pdf"), policy: .archive)
        XCTAssertTrue(transport.requests(to: "drive/v3/files/doc-2").isEmpty, "Drive has no archive, so archive keeps the Doc")

        transport.reply("v1.0/me/events/ev-1", status: 204)
        let outlook = OutlookCalendarDestination(config: .init(id: "o"), account: try signedInMicrosoft(transport, in: folder))
        try outlook.remove(DestinationRecord(externalID: "ev-1", contentHash: "h", syncedAt: Date()), export: RemovedExport(sourceID: "s", relativePath: "Daily/2026-01-13.pdf"), policy: .delete)
        XCTAssertEqual(transport.requests(to: "v1.0/me/events/ev-1").first?.request.httpMethod, "DELETE")
        try outlook.remove(DestinationRecord(externalID: PlannerEvent.skipped, contentHash: "h", syncedAt: Date()), export: RemovedExport(sourceID: "s", relativePath: "x.pdf"), policy: .delete)
        XCTAssertEqual(transport.sent.count, 2, "skipped notes never had an event")
    }

    // MARK: Outlook

    private func outlook(timeZone: String? = "America/Chicago") throws -> OutlookCalendarDestination {
        OutlookCalendarDestination(config: .init(id: "outlook", calendar: "Viwoods", timeZone: timeZone), account: try signedInMicrosoft(transport, in: folder))
    }

    func testOutlookFindsTheCalendarByNameAndFilesAllDayEvents() throws {
        transport.handlers["v1.0/me/calendars"] = { sent in
            XCTAssertEqual(sent.request.httpMethod, "GET")
            return (200, try jsonData(["value": [["id": "work", "name": "Work"], ["id": "vw-1", "name": "viwoods"]]]))
        }
        transport.reply("v1.0/me/calendars/vw-1/events", status: 201, ["id": "ev-1"])

        let id = try outlook().upsert(plannerNote(), previous: nil)

        XCTAssertEqual(id, "ev-1")
        let event = try XCTUnwrap(transport.requests(to: "v1.0/me/calendars/vw-1/events").first).body
        XCTAssertEqual(event["subject"] as? String, "Daily plan")
        XCTAssertEqual(event["isAllDay"] as? Bool, true)
        XCTAssertEqual(event["start"] as? [String: String], ["dateTime": "2026-01-13T00:00:00", "timeZone": "America/Chicago"])
        XCTAssertEqual(event["end"] as? [String: String], ["dateTime": "2026-01-14T00:00:00", "timeZone": "America/Chicago"])
    }

    func testOutlookCreatesTheCalendarWhenMissingAndPatchesExistingEvents() throws {
        transport.handlers["v1.0/me/calendars"] = { sent in
            if sent.request.httpMethod == "GET" { return (200, try jsonData(["value": []])) }
            XCTAssertEqual(sent.body["name"] as? String, "Viwoods")
            return (201, try jsonData(["id": "new-cal"]))
        }
        transport.reply("v1.0/me/calendars/new-cal/events", status: 201, ["id": "ev-9"])
        transport.reply("v1.0/me/events/ev-1", status: 404, ["error": ["code": "ErrorItemNotFound", "message": "Not found"]])
        let destination = try outlook()

        let todo = DailyTodo(id: "t", date: "2026-02-02", text: "Pay rent", isFinished: true, level: 2, modified: 1)
        XCTAssertEqual(try destination.upsert(todo, previous: "ev-1"), "ev-9", "deleted in Outlook, so created again")
        XCTAssertEqual(transport.requests(to: "v1.0/me/events/ev-1").first?.request.httpMethod, "PATCH")
        XCTAssertEqual(transport.requests(to: "v1.0/me/calendars/new-cal/events").first?.body["subject"] as? String, "☑ Pay rent")
    }

    // MARK: OneNote

    func testOneNoteFindsOrCreatesTheNotebookAndSectionThenPostsAMultipartPage() throws {
        transport.handlers["v1.0/me/onenote/notebooks"] = { sent in
            if sent.request.httpMethod == "GET" {
                XCTAssertEqual(sent.request.url?.query?.removingPercentEncoding, "$filter=displayName eq 'Ink'")
                return (200, try jsonData(["value": []]))
            }
            XCTAssertEqual(sent.body["displayName"] as? String, "Ink")
            return (201, try jsonData(["id": "nb-1"]))
        }
        transport.reply("v1.0/me/onenote/notebooks/nb-1/sections", ["value": [["id": "sec-1"]]])
        transport.reply("v1.0/me/onenote/sections/sec-1/pages", status: 201, ["id": "page-1"])
        let destination = OneNoteDestination(config: .init(id: "onenote"), account: try signedInMicrosoft(transport, in: folder)) { _ in
            [Data("jpeg-one".utf8), Data("jpeg-two".utf8)]
        }
        let note = makeNote(relativePath: "Paper/Work/Meeting notes.pdf", pages: [RecognizedPage(number: 1, text: "a"), RecognizedPage(number: 2, text: "b")])

        XCTAssertEqual(try destination.upsert(note, previous: nil), "page-1")

        let sections = try XCTUnwrap(transport.requests(to: "v1.0/me/onenote/notebooks/nb-1/sections").first)
        XCTAssertEqual(sections.request.url?.query?.removingPercentEncoding, "$filter=displayName eq 'Paper'")
        let page = try XCTUnwrap(transport.requests(to: "v1.0/me/onenote/sections/sec-1/pages").first)
        XCTAssertTrue(page.request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = bodyText(page)
        XCTAssertTrue(body.contains("name=\"Presentation\""))
        XCTAssertTrue(body.contains("<img src=\"name:page1\""))
        XCTAssertTrue(body.contains("<img src=\"name:page2\""))
        XCTAssertTrue(body.contains("name=\"page2\"\r\nContent-Type: image/jpeg\r\n\r\njpeg-two"))
    }

    func testOneNoteUpdateWritesTheNewPageBeforeDeletingTheOld() throws {
        transport.reply("v1.0/me/onenote/notebooks", ["value": [["id": "nb"]]])
        transport.reply("v1.0/me/onenote/notebooks/nb/sections", ["value": [["id": "sec"]]])
        transport.reply("v1.0/me/onenote/sections/sec/pages", status: 201, ["id": "page-2"])
        transport.reply("v1.0/me/onenote/pages/page-1", status: 204)
        let destination = OneNoteDestination(config: .init(id: "onenote"), account: try signedInMicrosoft(transport, in: folder)) { _ in [] }

        let id = try destination.upsert(makeNote(), previous: DestinationRecord(externalID: "page-1", contentHash: "old", syncedAt: Date()))

        XCTAssertEqual(id, "page-2")
        let order = transport.sent.map(\.path).filter { $0.hasSuffix("/pages") || $0.hasSuffix("page-1") }
        XCTAssertEqual(order, ["v1.0/me/onenote/sections/sec/pages", "v1.0/me/onenote/pages/page-1"])
        XCTAssertEqual(transport.requests(to: "v1.0/me/onenote/pages/page-1").first?.request.httpMethod, "DELETE")
    }

    func testOneNoteSectionsFollowTheTabletsTopFolder() {
        XCTAssertEqual(OneNoteDestination.sectionName(for: makeNote(relativePath: "Daily/2026-01-13.pdf")), "Daily")
        XCTAssertEqual(OneNoteDestination.sectionName(for: makeNote(relativePath: "Flat.pdf")), "Viwoods AiPaper")
        XCTAssertEqual(OneNoteDestination.sectionName(for: makeNote(relativePath: "R&D: #1/x.pdf")), "R-D- -1")
        XCTAssertEqual(OneNoteDestination.odata("Bob's"), "Bob''s")
    }

    // MARK: Factory

    func testFactorySharesOneAccountPerProviderAndFindsEveryPlanSink() throws {
        let context = DestinationContext(
            supportDirectory: folder.url, transport: transport, scriptRunner: FakeScriptRunner(),
            google: GoogleAccountConfig(clientId: "c", clientSecret: "s"), microsoft: MicrosoftAccountConfig(clientId: "m")
        )
        let destinations = DestinationFactory.make([
            .googleCalendar(.init(id: "gcal")), .googleDocs(.init(id: "docs")),
            .outlookCalendar(.init(id: "outlook")), .oneNote(.init(id: "onenote")),
            .reviewStack(.init(id: "stack")), .obsidian(.init(id: "vault", vaultPath: folder.url.path)),
        ], context: context)

        XCTAssertEqual(destinations.map(\.id), ["gcal", "docs", "outlook", "onenote", "stack", "vault"])
        XCTAssertEqual(DestinationFactory.plans(in: destinations).map(\.id), ["gcal", "outlook", "stack"])
        XCTAssertEqual((destinations[4] as? ReviewStackDestination)?.store.directory.lastPathComponent, "review")
    }
}
