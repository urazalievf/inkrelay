import Foundation

/// Puts the Viwoods Daily planner into Apple Calendar as all-day events: one per handwritten day page,
/// carrying the recognized text, and one per typed to-do. Driven by AppleScript like the Notes destination,
/// so macOS asks once for permission to control Calendar.
///
/// Notebooks that aren't planner pages are ignored here; they belong in Obsidian and Notes.
public struct AppleCalendarDestination: NoteDestination, PlanDestination, PlannerEventWriter {
    public var config: DestinationConfig.AppleCalendarConfig
    private let runner: AppleScriptRunner

    public init(config: DestinationConfig.AppleCalendarConfig, runner: AppleScriptRunner = OSAScriptRunner()) {
        self.config = config
        self.runner = runner
    }

    public var id: String { config.id }
    var pageTitle: String { config.pageTitle }

    /// Handle returned for notes this destination doesn't take, so the engine doesn't retry them.
    public static let skipped = PlannerEvent.skipped

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        try upsertPlannerPage(note, previous: previous)
    }

    public func upsert(_ todo: DailyTodo, previous: String?) throws -> String {
        try upsertTodo(todo, previous: previous)
    }

    func upsertEvent(_ event: PlannerEvent, previous: String?) throws -> String {
        if let previous {
            // Empty means the event was deleted in Calendar; a fresh one is created below.
            let updated = try runner.run(Self.updateScript, arguments: [config.calendar, previous, event.summary, event.description, event.date])
            if !updated.isEmpty { return updated }
        }
        let created = try runner.run(Self.createScript, arguments: [config.calendar, event.summary, event.description, event.date])
        guard !created.isEmpty else { throw DestinationError.failed(id, "Calendar didn't return an id for the new event") }
        return created
    }

    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        guard policy == .delete, record.externalID != PlannerEvent.skipped else { return }
        _ = try runner.run(Self.deleteScript, arguments: [config.calendar, record.externalID])
    }

    static let deleteScript = """
    on run argv
        tell application "Calendar"
            if not (exists calendar (item 1 of argv)) then return
            tell calendar (item 1 of argv)
                delete (every event whose uid is (item 2 of argv))
            end tell
        end tell
    end run
    """

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
