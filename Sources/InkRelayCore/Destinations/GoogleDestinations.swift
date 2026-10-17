import Foundation

/// Planner day pages and to-dos as all-day events in a Google calendar InkRelay creates and owns.
/// With the `calendar.app.created` scope it can't see or touch any other calendar.
public final class GoogleCalendarDestination: NoteDestination, PlanDestination, PlannerEventWriter {
    public let config: DestinationConfig.GoogleCalendarConfig
    private let account: GoogleAccount
    static let api = URL(string: "https://www.googleapis.com/calendar/v3/")!

    public init(config: DestinationConfig.GoogleCalendarConfig, account: GoogleAccount) {
        self.config = config
        self.account = account
    }

    public var id: String { config.id }
    var pageTitle: String { config.pageTitle }
    private var idKey: String { "calendar:" + config.calendar }

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        try upsertPlannerPage(note, previous: previous)
    }

    public func upsert(_ todo: DailyTodo, previous: String?) throws -> String {
        try upsertTodo(todo, previous: previous)
    }

    func upsertEvent(_ event: PlannerEvent, previous: String?) throws -> String {
        let body = Self.eventBody(event)
        if let previous {
            let calendar = try calendarID()
            let url = Self.api.appendingPathComponent("calendars/\(pathSegment(calendar))/events/\(pathSegment(previous))")
            let (status, object) = try account.client.call("PATCH", url, json: body, allowing: [404, 410])
            if status == 200, let updated = object["id"] as? String { return updated }
            // 404/410: deleted in Google Calendar, so it's created again below.
        }
        return try insert(body, retryingWithNewCalendar: true)
    }

    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        guard policy == .delete, record.externalID != PlannerEvent.skipped, let calendar = account.ids[idKey] else { return }
        let url = Self.api.appendingPathComponent("calendars/\(pathSegment(calendar))/events/\(pathSegment(record.externalID))")
        _ = try account.client.call("DELETE", url, allowing: [404, 410])
    }

    private func insert(_ body: [String: Any], retryingWithNewCalendar: Bool) throws -> String {
        let calendar = try calendarID()
        let url = Self.api.appendingPathComponent("calendars/\(pathSegment(calendar))/events")
        let (status, object) = try account.client.call("POST", url, json: body, allowing: [404])
        if status == 404 {
            // The calendar itself was deleted. Forget it and make a new one, once.
            account.ids[idKey] = nil
            guard retryingWithNewCalendar else { throw CloudAPIError.http("Google Calendar", 404, "calendar not found") }
            return try insert(body, retryingWithNewCalendar: false)
        }
        guard let created = object["id"] as? String else { throw CloudAPIError.unexpected("Google Calendar", "no event id") }
        return created
    }

    private func calendarID() throws -> String {
        if let known = account.ids[idKey] { return known }
        let (_, object) = try account.client.call("POST", Self.api.appendingPathComponent("calendars"), json: [
            "summary": config.calendar,
            "description": "Planner pages and to-dos from your e-ink tablet, synced by InkRelay.",
            "timeZone": TimeZone.current.identifier,
        ])
        guard let created = object["id"] as? String else { throw CloudAPIError.unexpected("Google Calendar", "no calendar id") }
        account.ids[idKey] = created
        return created
    }

    static func eventBody(_ event: PlannerEvent) -> [String: Any] {
        [
            "summary": event.summary,
            "description": event.description,
            "start": ["date": event.date],
            "end": ["date": PlannerEvent.dayAfter(event.date)],
            "transparency": "transparent",
            "extendedProperties": ["private": ["source": "inkrelay"]],
        ]
    }
}

/// Each note as a Google Doc in a Drive folder InkRelay creates. With the `drive.file` scope
/// InkRelay only ever sees the files it made. The doc holds the recognized text; the ink stays in the PDF.
public final class GoogleDocsDestination: NoteDestination {
    public let config: DestinationConfig.GoogleDocsConfig
    private let account: GoogleAccount
    static let drive = URL(string: "https://www.googleapis.com/drive/v3/files")!
    static let upload = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    static let documentType = "application/vnd.google-apps.document"
    static let folderType = "application/vnd.google-apps.folder"

    public init(config: DestinationConfig.GoogleDocsConfig, account: GoogleAccount) {
        self.config = config
        self.account = account
    }

    public var id: String { config.id }
    private var idKey: String { "folder:" + config.folder }

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        let html = Self.html(note)
        if let previous, !previous.externalID.isEmpty {
            // Uploading onto an existing Doc replaces its content (and its name, after a rename)
            // and keeps the link people may have shared.
            var components = URLComponents(url: Self.upload.appendingPathComponent(pathSegment(previous.externalID)), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "uploadType", value: "multipart")]
            let (body, boundary) = try Self.multipart(metadata: ["name": note.title], html: html)
            let (status, object) = try account.client.call(
                "PATCH", components.url!, body: body, contentType: "multipart/related; boundary=\(boundary)", allowing: [404]
            )
            if status == 200, let updated = object["id"] as? String { return updated }
        }
        return try create(note, html: html, retryingWithNewFolder: true)
    }

    /// Delete moves the Doc to the Drive trash, where it stays for 30 days.
    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        guard policy == .delete, !record.externalID.isEmpty else { return }
        _ = try account.client.call("PATCH", Self.drive.appendingPathComponent(pathSegment(record.externalID)), json: ["trashed": true], allowing: [404])
    }

    static func multipart(metadata: [String: Any], html: String) throws -> (Data, String) {
        let boundary = "inkrelay-" + UUID().uuidString
        var body = Data()
        body += Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += try JSONSerialization.data(withJSONObject: metadata)
        body += Data("\r\n--\(boundary)\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n".utf8)
        body += Data(html.utf8)
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        return (body, boundary)
    }

    private func create(_ note: InkNote, html: String, retryingWithNewFolder: Bool) throws -> String {
        let folder = try folderID()
        let (body, boundary) = try Self.multipart(metadata: ["name": note.title, "mimeType": Self.documentType, "parents": [folder]], html: html)

        var components = URLComponents(url: Self.upload, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadType", value: "multipart")]
        let (status, object) = try account.client.call(
            "POST", components.url!, body: body, contentType: "multipart/related; boundary=\(boundary)", allowing: [404]
        )
        if status == 404 {
            account.ids[idKey] = nil
            guard retryingWithNewFolder else { throw CloudAPIError.http("Google Drive", 404, "folder not found") }
            return try create(note, html: html, retryingWithNewFolder: false)
        }
        guard let created = object["id"] as? String else { throw CloudAPIError.unexpected("Google Drive", "no file id") }
        return created
    }

    private func folderID() throws -> String {
        if let known = account.ids[idKey] { return known }
        let (_, object) = try account.client.call("POST", Self.drive, json: ["name": config.folder, "mimeType": Self.folderType])
        guard let created = object["id"] as? String else { throw CloudAPIError.unexpected("Google Drive", "no folder id") }
        account.ids[idKey] = created
        return created
    }

    /// Drive converts this HTML into a Doc: the title as a heading, one section per page.
    static func html(_ note: InkNote, syncedAt: Date = Date()) -> String {
        var html = "<html><head><meta charset=\"utf-8\"><title>\(AppleNotesHTML.escape(note.title))</title></head><body>"
        html += "<h1>\(AppleNotesHTML.escape(note.title))</h1>"
        if !NoteFormatting.hasText(note) { html += "<p><i>No text recognized.</i></p>" }
        for page in note.pages {
            if note.pages.count > 1 { html += "<h2>Page \(page.number)</h2>" }
            for line in page.text.split(separator: "\n", omittingEmptySubsequences: false) {
                html += line.isEmpty ? "<p><br></p>" : "<p>\(AppleNotesHTML.escape(String(line)))</p>"
            }
        }
        let synced = NoteFormatting.timestamp.string(from: syncedAt)
        html += "<p><i>From \(AppleNotesHTML.escape(note.device)): \(AppleNotesHTML.escape(note.relativePath)). Synced by InkRelay \(synced).</i></p>"
        return html + "</body></html>"
    }
}
