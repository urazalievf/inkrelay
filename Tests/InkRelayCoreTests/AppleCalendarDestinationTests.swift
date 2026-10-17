import XCTest
@testable import InkRelayCore

final class AppleCalendarDestinationTests: XCTestCase {
    private func makeDestination(_ runner: FakeScriptRunner) -> AppleCalendarDestination {
        AppleCalendarDestination(config: .init(id: "calendar", calendar: "Viwoods"), runner: runner)
    }

    func testPlannerPageBecomesAnAllDayEventWithTheRecognizedText() throws {
        let runner = FakeScriptRunner()
        runner.results = ["uid-1"]
        let note = makeNote(
            title: "2026-01-13",
            relativePath: "Daily/2026-01-13.pdf",
            pages: [RecognizedPage(number: 1, text: "\nGym at 7\nCall Sam")]
        )

        let id = try makeDestination(runner).upsert(note, previous: nil)

        XCTAssertEqual(id, "uid-1")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].source, AppleCalendarDestination.createScript)
        XCTAssertEqual(runner.calls[0].arguments[0], "Viwoods")
        XCTAssertEqual(runner.calls[0].arguments[1], "Daily plan", "misread first lines made poor titles, so the text goes in the notes")
        XCTAssertTrue(runner.calls[0].arguments[2].hasPrefix("Gym at 7\nCall Sam"))
        XCTAssertEqual(runner.calls[0].arguments[3], "2026-01-13")
    }

    func testOrdinaryNotebooksAreSkippedWithoutTouchingCalendar() throws {
        let runner = FakeScriptRunner()
        let id = try makeDestination(runner).upsert(makeNote(relativePath: "Paper/Work/ll.pdf"), previous: nil)
        XCTAssertEqual(id, AppleCalendarDestination.skipped)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testUpdatesTheExistingEventAndRecreatesADeletedOne() throws {
        let runner = FakeScriptRunner()
        runner.results = ["uid-1", "", "uid-2"]
        let destination = makeDestination(runner)
        let note = makeNote(title: "2026-01-13", relativePath: "Daily/2026-01-13.pdf", pages: [])
        let previous = DestinationRecord(externalID: "uid-1", contentHash: "old", syncedAt: Date())

        XCTAssertEqual(try destination.upsert(note, previous: previous), "uid-1")
        XCTAssertEqual(runner.calls[0].source, AppleCalendarDestination.updateScript)
        XCTAssertEqual(Array(runner.calls[0].arguments.prefix(3)), ["Viwoods", "uid-1", "Daily plan"])
        XCTAssertTrue(runner.calls[0].arguments[3].hasPrefix("No text recognized."))

        XCTAssertEqual(try destination.upsert(note, previous: previous), "uid-2", "deleted in Calendar, so created again")
        XCTAssertEqual(runner.calls.map(\.source).suffix(2), [AppleCalendarDestination.updateScript, AppleCalendarDestination.createScript])
    }

    func testTodosCarryTheirStateAndPriority() throws {
        let runner = FakeScriptRunner()
        runner.results = ["uid-9", "uid-9"]
        let destination = makeDestination(runner)
        let open = DailyTodo(id: "t", date: "2026-02-02", text: "Renew passport\nbring photos", isFinished: false, level: 0, modified: 1)

        XCTAssertEqual(try destination.upsert(open, previous: nil), "uid-9")
        XCTAssertEqual(runner.calls[0].arguments[1], "☐ Renew passport")
        XCTAssertTrue(runner.calls[0].arguments[2].contains("Priority: Important and urgent"))
        XCTAssertEqual(runner.calls[0].arguments[3], "2026-02-02")

        var done = open
        done.isFinished = true
        done.level = 7
        XCTAssertEqual(try destination.upsert(done, previous: "uid-9"), "uid-9")
        XCTAssertEqual(runner.calls[1].source, AppleCalendarDestination.updateScript)
        XCTAssertEqual(runner.calls[1].arguments[2], "☑ Renew passport")
        XCTAssertFalse(runner.calls[1].arguments[3].contains("Priority"))
    }

    func testLongFirstLinesAreShortenedInTheTitle() {
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(PlannerEvent.firstLine(of: long).count, 80)
    }

    func testAnAITranscriptionTitleNamesTheDay() {
        let note = makeNote(title: "2026-01-13", relativePath: "Daily/2026-01-13.pdf", pages: [
            RecognizedPage(number: 1, text: "Gym at 7", suggestedTitle: "Gym and errands"),
        ])
        XCTAssertEqual(PlannerEvent.dayPage(note, title: "Daily plan")?.summary, "Daily plan: Gym and errands")
    }

    func testAllDayEventsEndTheNextDay() {
        XCTAssertEqual(PlannerEvent.dayAfter("2026-01-31"), "2026-02-01")
        XCTAssertEqual(PlannerEvent.dayAfter("2028-02-28"), "2028-02-29")
        XCTAssertEqual(PlannerEvent.dayAfter("2026-12-31"), "2027-01-01")
    }

    func testDestinationFactoryBuildsCalendarAndFindsPlanSinks() {
        let destinations = DestinationFactory.make([
            .obsidian(.init(id: "vault", vaultPath: "/tmp")),
            .appleCalendar(.init(id: "cal")),
        ], scriptRunner: FakeScriptRunner())
        XCTAssertEqual(destinations.map(\.id), ["vault", "cal"])
        XCTAssertEqual(DestinationFactory.plans(in: destinations).map(\.id), ["cal"])
    }
}
