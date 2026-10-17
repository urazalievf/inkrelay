import Foundation

/// Tasks written on pages (checkbox lines and TODO lines) and Viwoods Daily to-dos as Apple Reminders,
/// with due dates when the task names one. Ticking a box on the tablet completes the reminder;
/// re-syncs never duplicate. Driven by AppleScript like Notes and Calendar.
public struct AppleRemindersDestination: NoteDestination, PlanDestination {
    public var config: DestinationConfig.AppleRemindersConfig
    private let runner: AppleScriptRunner

    public init(config: DestinationConfig.AppleRemindersConfig, runner: AppleScriptRunner = OSAScriptRunner()) {
        self.config = config
        self.runner = runner
    }

    public var id: String { config.id }

    /// The handle is a JSON map from task key to reminder id, so each task keeps its reminder across re-syncs.
    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        var known = Self.decode(previous?.externalID)
        let itemKey = "\(note.sourceID)/\(note.relativePath)"
        let plannerDate = PlannerEvent.plannerDate(of: note)
        let tasks = note.pages.flatMap { TaskExtractor.tasks(in: $0.text, itemKey: itemKey, plannerDate: plannerDate) }
        let list = listName(for: note.device, source: note.sourceID)
        for task in tasks {
            known[task.key] = try upsertReminder(
                name: task.text,
                body: "From \"\(note.title)\" (\(note.relativePath)). Synced by InkRelay.",
                due: task.due.map { Self.dueString($0, hasTime: task.dueHasTime) } ?? "",
                done: task.isDone,
                list: list,
                previous: known[task.key]
            )
        }
        return Self.encode(known)
    }

    public func upsert(_ todo: DailyTodo, previous: String?) throws -> String {
        var body = "Viwoods Daily to-do."
        if let priority = todo.priority { body += " Priority: \(priority)." }
        return try upsertReminder(
            name: todo.text.isEmpty ? "To-do" : PlannerEvent.firstLine(of: todo.text),
            body: body + " Synced by InkRelay.",
            due: todo.date,
            done: todo.isFinished,
            list: listName(for: "Viwoods Daily", source: "viwoods"),
            previous: previous
        )
    }

    /// Delete removes the note's reminders; archive marks them completed.
    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        guard policy != .keep else { return }
        for reminder in Self.decode(record.externalID).values {
            _ = try runner.run(policy == .delete ? Self.deleteScript : Self.completeScript, arguments: [reminder])
        }
    }

    private func upsertReminder(name: String, body: String, due: String, done: Bool, list: String, previous: String?) throws -> String {
        if let previous, !previous.isEmpty {
            // Only the done state follows the tablet; edits made in Reminders (name, due date, notes) are left alone.
            let updated = try runner.run(Self.updateScript, arguments: [previous, done ? "true" : "false"])
            if !updated.isEmpty { return updated }
        }
        let created = try runner.run(Self.createScript, arguments: [list, name, body, due, done ? "true" : "false"])
        guard !created.isEmpty else { throw DestinationError.failed(id, "Reminders didn't return an id") }
        return created
    }

    func listName(for device: String, source: String) -> String {
        config.list.replacingOccurrences(of: "{device}", with: device).replacingOccurrences(of: "{source}", with: source)
    }

    static func decode(_ handle: String?) -> [String: String] {
        guard let handle, let data = handle.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return map
    }

    static func encode(_ map: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `yyyy-MM-dd` for all-day dues, `yyyy-MM-ddTHH:mm` in the Mac's time zone otherwise.
    static func dueString(_ date: Date, hasTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = hasTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static let dateHandler = """
    on parseDate(dateString)
        set theDate to current date
        set day of theDate to 1
        set year of theDate to (text 1 thru 4 of dateString) as integer
        set month of theDate to (text 6 thru 7 of dateString) as integer
        set day of theDate to (text 9 thru 10 of dateString) as integer
        if (length of dateString) ≥ 16 then
            set time of theDate to ((text 12 thru 13 of dateString) as integer) * hours + ((text 15 thru 16 of dateString) as integer) * minutes
        else
            set time of theDate to 9 * hours
        end if
        return theDate
    end parseDate
    """

    static let createScript = """
    on run argv
        set listName to item 1 of argv
        set taskName to item 2 of argv
        set taskBody to item 3 of argv
        set dueString to item 4 of argv
        set isDone to (item 5 of argv) is "true"
        tell application "Reminders"
            if not (exists list listName) then make new list with properties {name:listName}
            set newReminder to make new reminder at end of reminders of list listName with properties {name:taskName, body:taskBody, completed:isDone}
            if dueString is not "" then
                if (length of dueString) ≥ 16 then
                    set due date of newReminder to my parseDate(dueString)
                else
                    set allday due date of newReminder to my parseDate(dueString)
                end if
            end if
            return id of newReminder
        end tell
    end run
    \(dateHandler)
    """

    static let updateScript = """
    on run argv
        set reminderID to item 1 of argv
        set isDone to (item 2 of argv) is "true"
        tell application "Reminders"
            try
                set theReminder to reminder id reminderID
                set completed of theReminder to isDone
                return reminderID
            on error
                return ""
            end try
        end tell
    end run
    """

    static let completeScript = """
    on run argv
        tell application "Reminders"
            try
                set completed of reminder id (item 1 of argv) to true
            end try
        end tell
    end run
    """

    static let deleteScript = """
    on run argv
        tell application "Reminders"
            try
                delete reminder id (item 1 of argv)
            end try
        end tell
    end run
    """
}

/// Calendars that can take a confirmed event with a start and end time.
public protocol TimedEventWriter {
    var id: String { get }
    func addEvent(_ event: SuggestedEvent) throws -> String
}

enum EventTime {
    /// Local wall-clock time, as Outlook and AppleScript want it.
    static func local(_ date: Date, seconds: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = seconds ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

extension AppleCalendarDestination: TimedEventWriter {
    public func addEvent(_ event: SuggestedEvent) throws -> String {
        let created = try scriptRunner.run(Self.timedCreateScript, arguments: [config.calendar, event.title, event.notes, EventTime.local(event.start), EventTime.local(event.end)])
        guard !created.isEmpty else { throw DestinationError.failed(id, "Calendar didn't return an id for the new event") }
        return created
    }

    static let timedCreateScript = """
    on run argv
        set calendarName to item 1 of argv
        set theSummary to item 2 of argv
        set theDescription to item 3 of argv
        set startDate to my parseDate(item 4 of argv)
        set endDate to my parseDate(item 5 of argv)
        tell application "Calendar"
            if not (exists calendar calendarName) then
                make new calendar with properties {name:calendarName}
            end if
            tell calendar calendarName
                set theEvent to make new event at end of events with properties {summary:theSummary, description:theDescription, start date:startDate, end date:endDate}
            end tell
            return uid of theEvent
        end tell
    end run
    \(AppleRemindersDestination.dateHandler)
    """
}

extension GoogleCalendarDestination: TimedEventWriter {
    public func addEvent(_ event: SuggestedEvent) throws -> String {
        let timeZone = TimeZone.current.identifier
        return try insertTimed([
            "summary": event.title,
            "description": event.notes,
            "start": ["dateTime": EventTime.rfc3339(event.start), "timeZone": timeZone],
            "end": ["dateTime": EventTime.rfc3339(event.end), "timeZone": timeZone],
        ])
    }
}

extension OutlookCalendarDestination: TimedEventWriter {
    public func addEvent(_ event: SuggestedEvent) throws -> String {
        let timeZone = config.timeZone ?? TimeZone.current.identifier
        return try insertTimed([
            "subject": event.title,
            "body": ["contentType": "text", "content": event.notes],
            "start": ["dateTime": EventTime.local(event.start, seconds: true), "timeZone": timeZone],
            "end": ["dateTime": EventTime.local(event.end, seconds: true), "timeZone": timeZone],
        ])
    }
}
