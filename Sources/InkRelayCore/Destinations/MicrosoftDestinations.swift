import Foundation

/// Planner day pages and to-dos as all-day events in an Outlook calendar, through Microsoft Graph.
/// The calendar is found by name and created if missing.
public final class OutlookCalendarDestination: NoteDestination, PlanDestination, PlannerEventWriter {
    public let config: DestinationConfig.OutlookCalendarConfig
    private let account: MicrosoftAccount
    private var calendarCache: String?

    public init(config: DestinationConfig.OutlookCalendarConfig, account: MicrosoftAccount) {
        self.config = config
        self.account = account
    }

    public var id: String { config.id }
    var pageTitle: String { config.pageTitle }

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        try upsertPlannerPage(note, previous: previous)
    }

    public func upsert(_ todo: DailyTodo, previous: String?) throws -> String {
        try upsertTodo(todo, previous: previous)
    }

    func upsertEvent(_ event: PlannerEvent, previous: String?) throws -> String {
        let body = Self.eventBody(event, timeZone: config.timeZone ?? TimeZone.current.identifier)
        if let previous {
            let (status, object) = try account.client.call("PATCH", MicrosoftAccount.url("me/events/\(pathSegment(previous))"), json: body, allowing: [404])
            if status == 200, let updated = object["id"] as? String { return updated }
        }
        return try insert(body, retryingWithNewCalendar: true)
    }

    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        guard policy == .delete, record.externalID != PlannerEvent.skipped else { return }
        _ = try account.client.call("DELETE", MicrosoftAccount.url("me/events/\(pathSegment(record.externalID))"), allowing: [404])
    }

    func insertTimed(_ body: [String: Any]) throws -> String {
        try insert(body, retryingWithNewCalendar: true)
    }

    private func insert(_ body: [String: Any], retryingWithNewCalendar: Bool) throws -> String {
        let calendar = try calendarID()
        let (status, object) = try account.client.call("POST", MicrosoftAccount.url("me/calendars/\(pathSegment(calendar))/events"), json: body, allowing: [404])
        if status == 404 {
            calendarCache = nil
            guard retryingWithNewCalendar else { throw CloudAPIError.http("Outlook", 404, "calendar not found") }
            return try insert(body, retryingWithNewCalendar: false)
        }
        guard let created = object["id"] as? String else { throw CloudAPIError.unexpected("Outlook", "no event id") }
        return created
    }

    private func calendarID() throws -> String {
        if let calendarCache { return calendarCache }
        let (_, list) = try account.client.call("GET", MicrosoftAccount.url("me/calendars", query: [
            URLQueryItem(name: "$select", value: "id,name"),
            URLQueryItem(name: "$top", value: "100"),
        ]))
        let calendars = list["value"] as? [[String: Any]] ?? []
        if let match = calendars.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(config.calendar) == .orderedSame }),
           let found = match["id"] as? String {
            calendarCache = found
            return found
        }
        let (_, created) = try account.client.call("POST", MicrosoftAccount.url("me/calendars"), json: ["name": config.calendar])
        guard let createdID = created["id"] as? String else { throw CloudAPIError.unexpected("Outlook", "no calendar id") }
        calendarCache = createdID
        return createdID
    }

    /// Graph wants all-day events to start and end at midnight in one time zone, ending on the next day.
    static func eventBody(_ event: PlannerEvent, timeZone: String) -> [String: Any] {
        [
            "subject": event.summary,
            "body": ["contentType": "text", "content": event.description],
            "start": ["dateTime": event.date + "T00:00:00", "timeZone": timeZone],
            "end": ["dateTime": PlannerEvent.dayAfter(event.date) + "T00:00:00", "timeZone": timeZone],
            "isAllDay": true,
            "showAs": "free",
            "isReminderOn": false,
        ]
    }
}

/// Each note as a OneNote page with the page images and the recognized text, in a notebook InkRelay
/// finds or creates. Sections follow the tablet's top-level folders (Paper, Memo, Daily…).
///
/// OneNote can't replace a page's body in place, so an update creates the new page first and then
/// deletes the old one. The page link changes on every update.
public final class OneNoteDestination: NoteDestination {
    public let config: DestinationConfig.OneNoteConfig
    private let account: MicrosoftAccount
    private let renderImages: (URL) -> [Data]
    private var notebookCache: String?
    private var sectionCache: [String: String] = [:]

    public init(config: DestinationConfig.OneNoteConfig, account: MicrosoftAccount, renderImages: @escaping (URL) -> [Data] = { (try? PageImages.jpegs(for: $0)) ?? [] }) {
        self.config = config
        self.account = account
        self.renderImages = renderImages
    }

    public var id: String { config.id }

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        let section = Self.sectionName(for: note)
        let created = try create(note, in: section, retryingWithNewSection: true)
        if let previous, !previous.externalID.isEmpty, previous.externalID != created {
            _ = try? account.client.call("DELETE", MicrosoftAccount.url("me/onenote/pages/\(pathSegment(previous.externalID))"), allowing: [404])
        }
        return created
    }

    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        guard policy == .delete, !record.externalID.isEmpty else { return }
        _ = try account.client.call("DELETE", MicrosoftAccount.url("me/onenote/pages/\(pathSegment(record.externalID))"), allowing: [404])
    }

    private func create(_ note: InkNote, in section: String, retryingWithNewSection: Bool) throws -> String {
        let sectionID = try self.sectionID(section)
        let images = renderImages(note.originalURL)
        let boundary = "inkrelay-" + UUID().uuidString
        var body = Data()
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"Presentation\"\r\nContent-Type: text/html\r\n\r\n".utf8)
        body += Data(Self.html(note, imageCount: images.count).utf8)
        for (index, image) in images.enumerated() {
            body += Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"page\(index + 1)\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
            body += image
        }
        body += Data("\r\n--\(boundary)--\r\n".utf8)

        let (status, object) = try account.client.call(
            "POST", MicrosoftAccount.url("me/onenote/sections/\(pathSegment(sectionID))/pages"),
            body: body, contentType: "multipart/form-data; boundary=\(boundary)", allowing: [404]
        )
        if status == 404 {
            sectionCache = [:]
            notebookCache = nil
            guard retryingWithNewSection else { throw CloudAPIError.http("OneNote", 404, "section not found") }
            return try create(note, in: section, retryingWithNewSection: false)
        }
        guard let created = object["id"] as? String else { throw CloudAPIError.unexpected("OneNote", "no page id") }
        return created
    }

    private func notebookID() throws -> String {
        if let notebookCache { return notebookCache }
        let found = try findOrCreate(
            list: MicrosoftAccount.url("me/onenote/notebooks", query: [URLQueryItem(name: "$filter", value: "displayName eq '\(Self.odata(config.notebook))'")]),
            create: MicrosoftAccount.url("me/onenote/notebooks"),
            name: config.notebook
        )
        notebookCache = found
        return found
    }

    private func sectionID(_ name: String) throws -> String {
        if let known = sectionCache[name] { return known }
        let notebook = try notebookID()
        let found = try findOrCreate(
            list: MicrosoftAccount.url("me/onenote/notebooks/\(pathSegment(notebook))/sections", query: [URLQueryItem(name: "$filter", value: "displayName eq '\(Self.odata(name))'")]),
            create: MicrosoftAccount.url("me/onenote/notebooks/\(pathSegment(notebook))/sections"),
            name: name
        )
        sectionCache[name] = found
        return found
    }

    private func findOrCreate(list: URL, create: URL, name: String) throws -> String {
        let (_, existing) = try account.client.call("GET", list)
        if let first = (existing["value"] as? [[String: Any]])?.first, let found = first["id"] as? String { return found }
        let (_, created) = try account.client.call("POST", create, json: ["displayName": name])
        guard let createdID = created["id"] as? String else { throw CloudAPIError.unexpected("OneNote", "no id for \(name)") }
        return createdID
    }

    /// The tablet folder the note sits in (`Paper/Work/ll.pdf` → `Paper`), or the device for flat folders.
    static func sectionName(for note: InkNote) -> String {
        let parts = note.relativePath.split(separator: "/")
        let raw = parts.count > 1 ? String(parts[0]) : note.device
        // OneNote rejects these in section names.
        let forbidden = CharacterSet(charactersIn: "?*/:<>|&#'%~\\")
        let cleaned = raw.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined().trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Ink" : cleaned).prefix(50))
    }

    static func odata(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }

    static func html(_ note: InkNote, imageCount: Int, syncedAt: Date = Date()) -> String {
        let created = NoteFormatting.timestamp.string(from: note.modified)
        var html = "<!DOCTYPE html><html><head><title>\(AppleNotesHTML.escape(note.title))</title><meta name=\"created\" content=\"\(created)\" /></head><body>"
        for page in note.pages {
            if note.pages.count > 1 { html += "<h2>Page \(page.number)</h2>" }
            if page.number <= imageCount { html += "<img src=\"name:page\(page.number)\" alt=\"Page \(page.number)\" width=\"600\" />" }
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                html += text.split(separator: "\n").map { "<p>\(AppleNotesHTML.escape(String($0)))</p>" }.joined()
            }
        }
        let synced = NoteFormatting.timestamp.string(from: syncedAt)
        html += "<p><i>From \(AppleNotesHTML.escape(note.device)): \(AppleNotesHTML.escape(note.relativePath)). Synced by InkRelay \(synced).</i></p>"
        return html + "</body></html>"
    }
}
