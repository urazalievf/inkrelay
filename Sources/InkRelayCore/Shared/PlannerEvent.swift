import Foundation

/// One all-day calendar entry from the planner: a handwritten day page or a typed to-do.
/// Every calendar destination writes the same thing, so Apple, Google and Outlook agree on titles and text.
public struct PlannerEvent: Equatable {
    public var summary: String
    public var description: String
    /// `yyyy-MM-dd`
    public var date: String

    public init(summary: String, description: String, date: String) {
        self.summary = summary
        self.description = description
        self.date = date
    }

    /// Handle a calendar destination returns for notes that aren't planner pages, so the engine doesn't retry them.
    public static let skipped = "skipped"

    /// The event for a planner day page, or nil when the note isn't one.
    public static func dayPage(_ note: InkNote, title: String) -> PlannerEvent? {
        guard let date = plannerDate(of: note) else { return nil }
        let text = note.pages.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        // Handwriting's first line is too often misread to title an event ("ter те" for a to-do list), and
        // Vision rates those misreadings as confidently as good lines. AI transcription's title is reliable.
        let suggested = note.pages.compactMap(\.suggestedTitle).first { !$0.isEmpty }
        return PlannerEvent(
            summary: suggested.map { "\(title): \(firstLine(of: $0))" } ?? title,
            description: (text.isEmpty ? "No text recognized." : text) + "\n\nFrom \(note.device). Synced by InkRelay.",
            date: date
        )
    }

    public static func todo(_ todo: DailyTodo) -> PlannerEvent {
        let mark = todo.isFinished ? "☑ " : "☐ "
        var description = todo.text
        if let priority = todo.priority { description += "\n\nPriority: \(priority)" }
        description += "\n\nViwoods Daily to-do. Synced by InkRelay."
        return PlannerEvent(
            summary: mark + (todo.text.isEmpty ? "To-do" : firstLine(of: todo.text)),
            description: description,
            date: todo.date
        )
    }

    /// Planner pages live under `Daily/` and are named by date.
    public static func plannerDate(of note: InkNote) -> String? {
        let parts = note.relativePath.split(separator: "/")
        guard parts.count >= 2, parts[parts.count - 2] == "Daily" else { return nil }
        return ViwoodsDate.normalize(note.title)
    }

    static func firstLine(of text: String, limit: Int = 80) -> String {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// The day after `date`: all-day events in Google and Outlook end on the following day, exclusive.
    public static func dayAfter(_ date: String) -> String {
        guard let day = dayFormatter.date(from: date),
              let next = utcCalendar.date(byAdding: .day, value: 1, to: day) else { return date }
        return dayFormatter.string(from: next)
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = utcCalendar
        formatter.timeZone = utcCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Writes planner events into one calendar service.
protocol PlannerEventWriter {
    var id: String { get }
    var pageTitle: String { get }
    func upsertEvent(_ event: PlannerEvent, previous: String?) throws -> String
}

/// Every calendar takes planner day pages and to-dos the same way; only the writing differs.
extension PlannerEventWriter {
    func upsertPlannerPage(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        guard let event = PlannerEvent.dayPage(note, title: pageTitle) else { return PlannerEvent.skipped }
        let handle = previous?.externalID
        return try upsertEvent(event, previous: handle == PlannerEvent.skipped ? nil : handle)
    }

    func upsertTodo(_ todo: DailyTodo, previous: String?) throws -> String {
        try upsertEvent(PlannerEvent.todo(todo), previous: previous == PlannerEvent.skipped ? nil : previous)
    }
}
