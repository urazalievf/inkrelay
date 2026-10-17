import XCTest
@testable import InkRelayCore

final class TasksAndEventsTests: XCTestCase {
    private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Extraction

    func testFindsOpenAndTickedTasksButNotOrdinaryLines() {
        let text = """
        ☐ Call the bank
        [x] Book flights
        TODO: renew passport
        Today was busy
        - [ ] buy milk
        ☑ Pay rent
        Plain line
        """
        let tasks = TaskExtractor.tasks(in: text, itemKey: "s/a.pdf")
        XCTAssertEqual(tasks.map(\.text), ["Call the bank", "Book flights", "renew passport", "buy milk", "Pay rent"])
        XCTAssertEqual(tasks.map(\.isDone), [false, true, false, false, true])
    }

    func testTickingTheBoxKeepsTheSameKey() {
        let open = TaskExtractor.tasks(in: "☐ Call  the Bank", itemKey: "s/a.pdf")[0]
        let done = TaskExtractor.tasks(in: "☑ call the bank", itemKey: "s/a.pdf")[0]
        XCTAssertEqual(open.key, done.key)
        XCTAssertNotEqual(open.key, TaskExtractor.tasks(in: "☐ Call the bank", itemKey: "s/other.pdf")[0].key)
    }

    func testDueDatesWithAndWithoutTimes() throws {
        let timed = try XCTUnwrap(TaskExtractor.tasks(in: "☐ Dentist on March 3, 2027 at 3pm", itemKey: "k").first)
        XCTAssertEqual(timed.due, local(2027, 3, 3, 15))
        XCTAssertTrue(timed.dueHasTime)

        let dayOnly = try XCTUnwrap(TaskExtractor.tasks(in: "☐ Taxes by April 15, 2027", itemKey: "k").first)
        XCTAssertFalse(dayOnly.dueHasTime)
        XCTAssertNotNil(dayOnly.due)
        XCTAssertNil(TaskExtractor.tasks(in: "☐ Water plants", itemKey: "k").first?.due)
    }

    func testABareTimeOnAPlannerPageBelongsToThatDay() throws {
        let task = try XCTUnwrap(TaskExtractor.tasks(in: "☐ Call Sam at 4:30pm", itemKey: "k", plannerDate: "2027-01-13").first)
        XCTAssertEqual(task.due, local(2027, 1, 13, 16, 30))
    }

    func testDatedLinesThatArentTasksBecomeSuggestedEvents() throws {
        let events = TaskExtractor.events(in: "Dentist March 3, 2027 at 3pm\n☐ Call at 5pm tomorrow\nLunch next week\n- Standup 9:30am", title: "Week", plannerDate: "2027-03-01")
        XCTAssertEqual(events.map(\.title), ["Dentist March 3, 2027 at 3pm", "Standup 9:30am"])
        XCTAssertEqual(events[0].start, local(2027, 3, 3, 15))
        XCTAssertEqual(events[0].end.timeIntervalSince(events[0].start), 3600)
        XCTAssertEqual(events[1].start, local(2027, 3, 1, 9, 30), "bare time on the planner page's day")
    }

    // MARK: Reminders

    func testRemindersAreCreatedOnceAndTickedOffLater() throws {
        let runner = FakeScriptRunner()
        runner.results = ["rem-1", "rem-2"]
        let destination = AppleRemindersDestination(config: .init(id: "reminders", list: "Ink · {device}"), runner: runner)
        let first = makeNote(pages: [RecognizedPage(number: 1, text: "☐ Call the bank\n☐ Dentist on March 3, 2027 at 3pm\nNotes")])

        let handle = try destination.upsert(first, previous: nil)

        XCTAssertEqual(runner.calls.map(\.source), [AppleRemindersDestination.createScript, AppleRemindersDestination.createScript])
        XCTAssertEqual(runner.calls[0].arguments[0], "Ink · Viwoods AiPaper")
        XCTAssertEqual(runner.calls[0].arguments[1], "Call the bank")
        XCTAssertEqual(runner.calls[0].arguments[3], "")
        XCTAssertEqual(runner.calls[1].arguments[3], "2027-03-03T15:00")
        XCTAssertEqual(AppleRemindersDestination.decode(handle).values.sorted(), ["rem-1", "rem-2"])

        runner.calls = []
        runner.results = ["rem-1", "rem-2"]
        let ticked = makeNote(pages: [RecognizedPage(number: 1, text: "☑ Call the bank\n☐ Dentist on March 3, 2027 at 3pm")])
        let again = try destination.upsert(ticked, previous: DestinationRecord(externalID: handle, contentHash: "old", syncedAt: Date()))

        XCTAssertEqual(runner.calls.map(\.source), [AppleRemindersDestination.updateScript, AppleRemindersDestination.updateScript], "no duplicates")
        XCTAssertEqual(runner.calls.first { $0.arguments[0] == "rem-1" }?.arguments[1], "true")
        XCTAssertEqual(AppleRemindersDestination.decode(again), AppleRemindersDestination.decode(handle))
    }

    func testDailyTodosBecomeAllDayReminders() throws {
        let runner = FakeScriptRunner()
        runner.results = ["rem-9"]
        let destination = AppleRemindersDestination(config: .init(id: "reminders"), runner: runner)
        let id = try destination.upsert(DailyTodo(id: "t", date: "2026-01-13", text: "Pay rent", isFinished: false, level: 1, modified: 1), previous: nil)
        XCTAssertEqual(id, "rem-9")
        XCTAssertEqual(runner.calls[0].arguments[3], "2026-01-13")
        XCTAssertTrue(runner.calls[0].arguments[2].contains("Priority: Urgent"))
    }

    func testRemovingANoteDeletesOrCompletesItsReminders() throws {
        let runner = FakeScriptRunner()
        let destination = AppleRemindersDestination(config: .init(id: "reminders"), runner: runner)
        let record = DestinationRecord(externalID: AppleRemindersDestination.encode(["a": "rem-1"]), contentHash: "h", syncedAt: Date())
        try destination.remove(record, export: RemovedExport(sourceID: "s", relativePath: "a.pdf"), policy: .archive)
        try destination.remove(record, export: RemovedExport(sourceID: "s", relativePath: "a.pdf"), policy: .delete)
        XCTAssertEqual(runner.calls.map(\.source), [AppleRemindersDestination.completeScript, AppleRemindersDestination.deleteScript])
    }

    func testTheAppleScriptsCompile() throws {
        // Compiled exactly as shipped, so a handler that failed to interpolate shows up here.
        let scripts = [
            AppleRemindersDestination.createScript, AppleRemindersDestination.updateScript,
            AppleRemindersDestination.completeScript, AppleRemindersDestination.deleteScript,
            AppleCalendarDestination.createScript, AppleCalendarDestination.updateScript,
            AppleCalendarDestination.timedCreateScript, AppleCalendarDestination.deleteScript,
            AppleNotesDestination.createScript, AppleNotesDestination.updateScript,
            AppleNotesDestination.deleteScript, AppleNotesDestination.archiveScript,
            NotesRoundTrip.folderOfNoteScript, NotesRoundTrip.removeFoldersScript,
        ]
        for script in scripts { XCTAssertFalse(script.contains("\\("), "an interpolation was left in the script") }
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        for (index, script) in scripts.enumerated() {
            let source = try folder.write("s\(index).applescript", script)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", folder.url.appendingPathComponent("s\(index).scpt").path, source.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "script \(index): " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    // MARK: Review stack and calendars

    final class RecordingCalendar: TimedEventWriter {
        let id = "cal"
        var added: [SuggestedEvent] = []
        func addEvent(_ event: SuggestedEvent) throws -> String {
            added.append(event)
            return "evt"
        }
    }

    func testSuggestedEventsWaitInTheStackUntilAccepted() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = ReviewStore(directory: folder.url)
        let clock = Date()
        let stack = ReviewStackDestination(config: .init(id: "stack"), store: store, renderImages: { _ in [] }, now: { clock })
        _ = try stack.upsert(makeNote(pages: [RecognizedPage(number: 1, text: "Dentist March 3, 2027 at 3pm")]), previous: nil)

        let card = try XCTUnwrap(try store.stack(now: clock, limit: 10).cards.first { $0.kind == .event })
        XCTAssertTrue(card.subtitle.hasPrefix("Suggested event · Wed, Mar 3, 3:00 PM"))

        let calendar = RecordingCalendar()
        let request = HTTPRequest(method: "POST", path: "/api/cards/\(card.id)/accept", headers: ["host": "127.0.0.1:7788", "x-inkrelay": "1"])
        XCTAssertEqual(ReviewServer(store: store, config: .init(id: "stack"), now: { clock }).route(request).status, 409, "no calendar configured")
        XCTAssertTrue(calendar.added.isEmpty)

        XCTAssertEqual(ReviewServer(store: store, config: .init(id: "stack"), calendars: [calendar], now: { clock }).route(request).status, 200)
        XCTAssertEqual(calendar.added.map(\.title), ["Dentist March 3, 2027 at 3pm"])
        XCTAssertEqual(try store.load().cards[card.id]?.status, .done)
    }

    func testGoogleAndOutlookTakeTimedEvents() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let transport = FakeTransport()
        transport.reply("calendar/v3/calendars", ["id": "cal"])
        transport.reply("calendar/v3/calendars/cal/events", ["id": "g-1"])
        transport.reply("v1.0/me/calendars", ["value": [["id": "o-cal", "name": "Viwoods"]]])
        transport.reply("v1.0/me/calendars/o-cal/events", status: 201, ["id": "o-1"])
        let event = SuggestedEvent(title: "Dentist", notes: "n", start: local(2027, 3, 3, 15), end: local(2027, 3, 3, 16))

        XCTAssertEqual(try GoogleCalendarDestination(config: .init(id: "g"), account: signedInGoogle(transport, in: folder)).addEvent(event), "g-1")
        XCTAssertEqual(try OutlookCalendarDestination(config: .init(id: "o", timeZone: "America/Chicago"), account: signedInMicrosoft(transport, in: folder)).addEvent(event), "o-1")

        let google = try XCTUnwrap(transport.requests(to: "calendar/v3/calendars/cal/events").first).body
        XCTAssertEqual((google["start"] as? [String: String])?["timeZone"], TimeZone.current.identifier)
        XCTAssertNotNil((google["start"] as? [String: String])?["dateTime"])
        let outlook = try XCTUnwrap(transport.requests(to: "v1.0/me/calendars/o-cal/events").first).body
        XCTAssertEqual(outlook["start"] as? [String: String], ["dateTime": EventTime.local(event.start, seconds: true), "timeZone": "America/Chicago"])
        XCTAssertNil(outlook["isAllDay"])
    }
}
