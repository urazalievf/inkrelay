import Foundation

/// Puts the Viwoods Daily planner into Apple Calendar as all-day events: one per handwritten day page,
/// carrying the recognized text, and one per typed to-do. Driven by AppleScript like the Notes destination,
/// so macOS asks once for permission to control Calendar.
///
/// Notebooks that aren't planner pages are ignored here; they belong in Obsidian and Notes.
public struct AppleCalendarDestination: NoteDestination, PlanDestination {
    public var config: DestinationConfig.AppleCalendarConfig
    private let runner: AppleScriptRunner

    public init(config: DestinationConfig.AppleCalendarConfig, runner: AppleScriptRunner = OSAScriptRunner()) {
        self.config = config
        self.runner = runner
    }

    public var id: String { config.id }

    /// Handle returned for notes this destination doesn't take, so the engine doesn't retry them.
    public static let skipped = "skipped"

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        guard let date = Self.plannerDate(of: note) else { return Self.skipped }
        let text = note.pages.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        let summary = Self.summary(prefix: config.pageTitle, text: text)
        let description = (text.isEmpty ? "No text recognized." : text) + "\n\nFrom \(note.device). Synced by InkRelay."
        return try upsertEvent(summary: summary, description: description, date: date, previous: previous?.externalID)
    }

    public func upsert(_ todo: DailyTodo, previous: String?) throws -> String {
        let mark = todo.isFinished ? "☑ " : "☐ "
        let summary = mark + (todo.text.isEmpty ? "To-do" : Self.firstLine(of: todo.text))
        var description = todo.text
        if let priority = todo.priority { description += "\n\nPriority: \(priority)" }
        description += "\n\nViwoods Daily to-do. Synced by InkRelay."
        return try upsertEvent(summary: summary, description: description, date: todo.date, previous: previous)
    }

    private func upsertEvent(summary: String, description: String, date: String, previous: String?) throws -> String {
        if let previous, previous != Self.skipped {
            // Empty means the event was deleted in Calendar; a fresh one is created below.
            let updated = try runner.run(Self.updateScript, arguments: [config.calendar, previous, summary, description, date])
            if !updated.isEmpty { return updated }
        }
        let created = try runner.run(Self.createScript, arguments: [config.calendar, summary, description, date])
        guard !created.isEmpty else { throw DestinationError.failed(id, "Calendar didn't return an id for the new event") }
        return created
    }

    /// Planner pages live under `Daily/` and are named by date.
    static func plannerDate(of note: InkNote) -> String? {
        let parts = note.relativePath.split(separator: "/")
        guard parts.count >= 2, parts[parts.count - 2] == "Daily" else { return nil }
        return ViwoodsDate.normalize(note.title)
    }

    static func summary(prefix: String, text: String) -> String {
        let line = firstLine(of: text)
        return line.isEmpty ? prefix : "\(prefix): \(line)"
    }

    static func firstLine(of text: String, limit: Int = 80) -> String {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    static let dateHandler = """
    on plannerDate(dateString)
        set theDate to current date
        set day of theDate to 1
        set year of theDate to (text 1 thru 4 of dateString) as integer
        set month of theDate to (text 6 thru 7 of dateString) as integer
        set day of theDate to (text 9 thru 10 of dateString) as integer
        set time of theDate to 0
        return theDate
    end plannerDate
    """

    static let createScript = """
    on run argv
        set calendarName to item 1 of argv
        set theSummary to item 2 of argv
        set theDescription to item 3 of argv
        set theDate to my plannerDate(item 4 of argv)
        tell application "Calendar"
            if not (exists calendar calendarName) then
                make new calendar with properties {name:calendarName}
            end if
            tell calendar calendarName
                set theEvent to make new event at end of events with properties {summary:theSummary, description:theDescription, start date:theDate, end date:theDate + 1 * days, allday event:true}
            end tell
            return uid of theEvent
        end tell
    end run
    \(dateHandler)
    """

    static let updateScript = """
    on run argv
        set calendarName to item 1 of argv
        set eventID to item 2 of argv
        set theSummary to item 3 of argv
        set theDescription to item 4 of argv
        set theDate to my plannerDate(item 5 of argv)
        tell application "Calendar"
            if not (exists calendar calendarName) then return ""
            tell calendar calendarName
                set matches to (every event whose uid is eventID)
                if (count of matches) is 0 then return ""
                set theEvent to item 1 of matches
                set summary of theEvent to theSummary
                set description of theEvent to theDescription
                set start date of theEvent to theDate
                set end date of theEvent to theDate + 1 * days
                set allday event of theEvent to true
            end tell
            return eventID
        end tell
    end run
    \(dateHandler)
    """
}
