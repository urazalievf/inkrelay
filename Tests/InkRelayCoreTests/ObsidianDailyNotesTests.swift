import XCTest
@testable import InkRelayCore

final class ObsidianDailyNotesTests: XCTestCase {
    private var vault: TemporaryFolder!
    private var support: TemporaryFolder!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    override func setUpWithError() throws {
        vault = try TemporaryFolder()
        support = try TemporaryFolder()
    }

    override func tearDown() {
        vault.remove()
        support.remove()
    }

    func testMomentTokensBecomeDateFormatterPatterns() {
        XCTAssertEqual(MomentFormat.pattern("YYYY-MM-DD"), "yyyy-MM-dd")
        XCTAssertEqual(MomentFormat.pattern("YYYY/MM/DD"), "yyyy/MM/dd")
        XCTAssertEqual(MomentFormat.pattern("DD.MM.YYYY"), "dd.MM.yyyy")
        XCTAssertEqual(MomentFormat.pattern("dddd, MMMM D YYYY"), "EEEE, MMMM d yyyy")
        XCTAssertEqual(MomentFormat.pattern("[Daily] YYYY-[W]WW"), "'Daily' yyyy-'W'ww")
        XCTAssertEqual(MomentFormat.pattern("GGGG-[W]WW"), "YYYY-'W'ww")
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9))!
        XCTAssertEqual(MomentFormat.string(from: date, format: "YYYY-MM-DD", calendar: calendar), "2026-10-13")
        XCTAssertEqual(MomentFormat.string(from: date, format: "ddd, MMM D", calendar: calendar), "Tue, Oct 13")
        XCTAssertEqual(MomentFormat.string(from: date, format: "MMMM Do, YYYY", calendar: calendar), "October 13th, 2026", "Obsidian's ordinal day")
        for (day, text) in [(1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (11, "11th"), (12, "12th"), (13, "13th"), (21, "21st"), (22, "22nd"), (23, "23rd"), (31, "31st")] {
            XCTAssertEqual(MomentFormat.ordinal(day), text)
        }
        XCTAssertEqual(DailyNotesSettings(folder: "Journal/Daily", format: "YYYY-MM-DD").notePath(for: date, calendar: calendar), "Journal/Daily/2026-10-13")
    }

    func testThePluginCountsAsOnFromEitherSettingsFile() throws {
        XCTAssertFalse(DailyNotesSettings.isEnabled(vault: vault.url))
        try vault.write(".obsidian/core-plugins.json", #"["file-explorer", "daily-notes"]"#)
        XCTAssertTrue(DailyNotesSettings.isEnabled(vault: vault.url), "older vaults list plugin names")
        try vault.write(".obsidian/core-plugins.json", #"{"file-explorer": true, "daily-notes": false}"#)
        XCTAssertFalse(DailyNotesSettings.isEnabled(vault: vault.url))
        try vault.write(".obsidian/core-plugins.json", #"{"daily-notes": true}"#)
        XCTAssertTrue(DailyNotesSettings.isEnabled(vault: vault.url), "newer vaults map names to on/off")
        try vault.write(".obsidian/core-plugins.json", "{}")
        try vault.write(".obsidian/daily-notes.json", "{}")
        XCTAssertTrue(DailyNotesSettings.isEnabled(vault: vault.url), "settings saved means it's on")
    }

    func testObsidiansOwnSettingsAreRead() throws {
        try vault.write(".obsidian/daily-notes.json", #"{"folder": "/Daily/", "format": "DD-MM-YYYY", "template": "t"}"#)
        XCTAssertEqual(DailyNotesSettings.load(vault: vault.url), DailyNotesSettings(folder: "Daily", format: "DD-MM-YYYY", template: "t"))
        XCTAssertEqual(DailyNotesSettings.load(vault: support.url), DailyNotesSettings(), "defaults without the plugin file")
    }

    func testManagedBlocksAreReplacedAndTheRestIsKept() {
        let block = "START\nnew\nEND"
        XCTAssertEqual(ManagedBlock.replace(in: nil, with: block, start: "START", end: "END"), "START\nnew\nEND\n")
        XCTAssertEqual(ManagedBlock.replace(in: "mine\n\nSTART\nold\nEND\n\nalso mine\n", with: block, start: "START", end: "END"), "mine\n\nSTART\nnew\nEND\n\nalso mine\n")
        XCTAssertEqual(ManagedBlock.replace(in: "# Tuesday\n\nmy thoughts\n", with: block, start: "START", end: "END"), "# Tuesday\n\nmy thoughts\n\nSTART\nnew\nEND\n")
        // The end marker was deleted: the orphan start marker goes too, so later syncs never swallow what follows it.
        let orphan = ManagedBlock.replace(in: "mine\nSTART\nold half\nmy new paragraph\n", with: block, start: "START", end: "END")
        XCTAssertEqual(orphan, "mine\n\nold half\nmy new paragraph\n\nSTART\nnew\nEND\n")
        XCTAssertEqual(ManagedBlock.replace(in: orphan, with: "START\nnewer\nEND", start: "START", end: "END"), "mine\n\nold half\nmy new paragraph\n\nSTART\nnewer\nEND\n")
    }

    func testANewDailyNoteStartsFromThePersonsTemplate() throws {
        try vault.write(".obsidian/daily-notes.json", #"{"folder": "Journal", "format": "YYYY-MM-DD", "template": "Templates/Daily"}"#)
        try vault.write("Templates/Daily.md", "# {{date:dddd, MMMM Do}}\n\nMade {{date}} at {{time}} for {{title}}\n\n## Log\n")
        let settings = DailyNotesSettings.load(vault: vault.url)
        XCTAssertEqual(settings.template, "Templates/Daily")
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 5))!
        XCTAssertEqual(settings.newNoteText(vault: vault.url, for: tuesday, now: now, calendar: calendar),
                       "# Tuesday, October 13th\n\nMade 2026-10-13 at 09:05 for 2026-10-13\n\n## Log\n")
        XCTAssertNil(DailyNotesSettings().newNoteText(vault: vault.url, for: tuesday, now: now, calendar: calendar))

        let archive = NoteArchive(directory: support.url.appendingPathComponent("archive"))
        let export = support.url.appendingPathComponent("Temp.pdf")
        try Data("pdf".utf8).write(to: export)
        let note = InkNote(title: "Temp", sourceID: "viwoods-cloud", device: "Viwoods AiPaper", originalURL: export, relativePath: "Paper/Temp.pdf",
                           modified: tuesday, contentHash: "abc", pages: [RecognizedPage(number: 1, text: "Migrate")])
        try archive.upsert(note, key: "viwoods-cloud/Paper/Temp.pdf", at: tuesday)
        let destination = ObsidianDestination(config: .init(id: "obsidian", vaultPath: vault.url.path, dailyNotes: true), archive: archive, calendar: calendar)
        _ = try destination.upsert(note, previous: nil)
        let daily = try String(contentsOf: vault.url.appendingPathComponent("Journal/2026-10-13.md"), encoding: .utf8)
        XCTAssertTrue(daily.hasPrefix("# Tuesday, October 13th\n"), "the template came first")
        XCTAssertTrue(daily.contains("## Log"))
        XCTAssertTrue(daily.contains(InkDigest.dailyStart))
    }

    func testARenameDoesNotDoubleTheDigest() throws {
        let exports = try TemporaryFolder()
        defer { exports.remove() }
        let export = try exports.write("Paper/Temp.pdf", "ink")
        let config = RelayConfig(sources: [SourceConfig(id: "drive", device: "Tablet", path: exports.url.path)],
                                 destinations: [.obsidian(.init(id: "obsidian", vaultPath: vault.url.path, weeklyDigest: true))], settleSeconds: 0)
        let recognizer = FakeRecognizer()
        recognizer.text = "☐ Renew passport"
        func engine() throws -> RelayEngine {
            RelayEngine(config: config, store: try StateStore(url: support.url.appendingPathComponent("state.json")), recognizer: recognizer,
                        destinations: DestinationFactory.make(config.destinations, context: DestinationContext(supportDirectory: support.url)))
        }
        _ = try engine().syncOnce()
        try FileManager.default.moveItem(at: export, to: exports.url.appendingPathComponent("Paper/Budget.pdf"))
        let report = try engine().syncOnce()
        XCTAssertEqual(report.renamed, 1)

        let weekly = try XCTUnwrap(FileManager.default.enumerator(at: vault.url.appendingPathComponent("Ink/Weekly"), includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "md" })
        let text = try String(contentsOf: weekly, encoding: .utf8)
        XCTAssertTrue(text.contains("[[Ink/drive/Paper/Budget|Budget]]"))
        XCTAssertFalse(text.contains("Temp"), "the old name is gone from the digest")
        XCTAssertTrue(text.contains("across 1 note**"), text)
        XCTAssertEqual(text.components(separatedBy: "Renew passport").count, 2, "the task is listed once")
        XCTAssertTrue(text.contains("[[Ink/drive/Paper/Budget#^ink-"), "linked under its new name")
    }

    private func archived(title: String, path: String, text: String, modified: Date, pages: Int = 1) -> ArchivedNote {
        ArchivedNote(id: NoteArchive.id(forKey: "viwoods-cloud/" + path), key: "viwoods-cloud/" + path, title: title, sourceID: "viwoods-cloud", device: "Viwoods AiPaper",
                     relativePath: path, originalPath: "/x", modified: modified, archivedAt: modified, contentHash: "h" + title,
                     pages: (1...pages).map { ArchivedNote.Page(number: $0, text: $0 == 1 ? text : "", suggestedTitle: nil, tags: []) })
    }

    func testTheDailyBlockHasThePlannerTheNotesAndTheOpenTasks() {
        let digest = InkDigest(folder: "Ink", calendar: calendar)
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14))!
        let notes = [
            archived(title: "2026-10-13", path: "Daily/2026-10-13.pdf", text: "Gym at 7\n☐ Call the bank\n☑ Paid rent", modified: tuesday.addingTimeInterval(-86_400 * 3)),
            archived(title: "Temp", path: "Paper/Temp.pdf", text: "Migrate\n- [ ] Renew passport", modified: tuesday, pages: 3),
            archived(title: "Old", path: "Paper/Old.pdf", text: "Last week", modified: tuesday.addingTimeInterval(-86_400 * 8)),
        ]

        let block = try! XCTUnwrap(digest.dailyBlock(for: tuesday, notes: notes))

        XCTAssertTrue(block.hasPrefix(InkDigest.dailyStart))
        XCTAssertTrue(block.hasSuffix(InkDigest.dailyEnd))
        XCTAssertTrue(block.contains("**Planner:** [[Ink/viwoods-cloud/Daily/2026-10-13|2026-10-13]]"), "the planner page counts for its date, not when it was pulled")
        XCTAssertTrue(block.contains("> Gym at 7"))
        XCTAssertTrue(block.contains("- [[Ink/viwoods-cloud/Paper/Temp|Temp]] (3 pages)"))
        XCTAssertFalse(block.contains("Old"))
        let bank = "ink-" + TaskExtractor.key("viwoods-cloud/Daily/2026-10-13.pdf", "Call the bank")
        let passport = "ink-" + TaskExtractor.key("viwoods-cloud/Paper/Temp.pdf", "Renew passport")
        XCTAssertTrue(block.contains("- [[Ink/viwoods-cloud/Daily/2026-10-13#^\(bank)|Call the bank]] (2026-10-13)"), block)
        XCTAssertTrue(block.contains("- [[Ink/viwoods-cloud/Paper/Temp#^\(passport)|Renew passport]] (Temp)"))
        XCTAssertFalse(block.contains("- [ ]"), "a link to the task's own checkbox, never a second checkbox")
        XCTAssertFalse(block.contains("[ ] Paid rent"), "done tasks aren't listed as open; they still show in the page's text")
        XCTAssertNil(digest.dailyBlock(for: tuesday.addingTimeInterval(86_400 * 30), notes: notes))
    }

    func testTheWeeklyBlockCountsTheWeekMondayToSunday() {
        let digest = InkDigest(folder: "Ink", calendar: calendar)
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14))!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23))!
        let nextMonday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 1))!
        let notes = [
            archived(title: "Temp", path: "Paper/Temp.pdf", text: "☐ Renew passport", modified: tuesday, pages: 3),
            archived(title: "Sketch", path: "Paper/Sketch.pdf", text: "", modified: sunday, pages: 2),
            archived(title: "2026-10-14", path: "Daily/2026-10-14.pdf", text: "Dentist\nthen groceries", modified: nextMonday),
            archived(title: "Later", path: "Paper/Later.pdf", text: "next week", modified: nextMonday),
        ]

        XCTAssertEqual(digest.weekName(for: tuesday), "2026-W42")
        let block = try! XCTUnwrap(digest.weeklyBlock(for: digest.week(containing: tuesday), notes: notes))
        XCTAssertTrue(block.contains("**6 pages across 3 notes**, 1 planner day, 1 open task."), block)
        XCTAssertTrue(block.contains("- Tue Oct 13: [[Ink/viwoods-cloud/Paper/Temp|Temp]] (3 pages)"))
        XCTAssertTrue(block.contains("- Sun Oct 18: [[Ink/viwoods-cloud/Paper/Sketch|Sketch]] (2 pages)"))
        XCTAssertTrue(block.contains("- Wed Oct 14: [[Ink/viwoods-cloud/Daily/2026-10-14|2026-10-14]] — Dentist"))
        XCTAssertFalse(block.contains("Later"))
    }

    func testTheObsidianDestinationWritesTheDailyNoteAndTheDigest() throws {
        try vault.write(".obsidian/daily-notes.json", #"{"folder": "Journal", "format": "YYYY-MM-DD"}"#)
        try vault.write("Journal/2026-10-13.md", "# Tuesday\n\nMy own words.\n")
        let archive = NoteArchive(directory: support.url.appendingPathComponent("archive"))
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14))!
        let export = support.url.appendingPathComponent("Temp.pdf")
        try Data("pdf".utf8).write(to: export)
        let note = InkNote(title: "Temp", sourceID: "viwoods-cloud", device: "Viwoods AiPaper", originalURL: export, relativePath: "Paper/Temp.pdf",
                           modified: tuesday, contentHash: "abc", pages: [RecognizedPage(number: 1, text: "Migrate\n☐ Renew passport")])
        try archive.upsert(note, key: "viwoods-cloud/Paper/Temp.pdf", at: tuesday)
        let destination = ObsidianDestination(config: .init(id: "obsidian", vaultPath: vault.url.path, dailyNotes: true, weeklyDigest: true), archive: archive, calendar: calendar)

        _ = try destination.upsert(note, previous: nil)

        let daily = try String(contentsOf: vault.url.appendingPathComponent("Journal/2026-10-13.md"), encoding: .utf8)
        XCTAssertTrue(daily.hasPrefix("# Tuesday\n\nMy own words.\n"), "the person's own text stays")
        XCTAssertTrue(daily.contains("- [[Ink/viwoods-cloud/Paper/Temp|Temp]] (1 page)"))
        XCTAssertTrue(daily.contains("|Renew passport]]"))
        let weekly = try String(contentsOf: vault.url.appendingPathComponent("Ink/Weekly/2026-W42.md"), encoding: .utf8)
        XCTAssertTrue(weekly.hasPrefix("# Week 42, 2026"))
        XCTAssertTrue(weekly.contains("[[Ink/viwoods-cloud/Paper/Temp|Temp]]"))

        // A second sync of the same note rewrites the blocks in place, without doubling them.
        _ = try destination.upsert(note, previous: nil)
        let again = try String(contentsOf: vault.url.appendingPathComponent("Journal/2026-10-13.md"), encoding: .utf8)
        XCTAssertEqual(again.components(separatedBy: InkDigest.dailyStart).count, 2)
    }
}
