import XCTest
@testable import InkRelayCore

final class SettingsRoundTripTests: XCTestCase {
    func testSettingsReopenWithTheConfigsChoicesAndKeepWhatTheyDontShow() throws {
        var original = try SetupChoices(tablet: TabletPreset.all[0], useViwoodsCloud: true, obsidianVault: "~/Vault", appleCalendar: true, reviewStack: true, shareWithPhone: true).config()
        // The parts a person edits by hand.
        original.google = GoogleAccountConfig(clientId: "id", clientSecret: "secret")
        original.destinations.append(.googleCalendar(.init(id: "gcal")))
        original.ai = AITranscriptionConfig(model: "claude-opus-5-5", monthlyBudgetUSD: 3)
        original.recognition.vocabulary = ["Erin", "Ensemble"]
        original.onDelete = ["obsidian": .archive, "gcal": .delete]
        original.sendTargets = [.folder(id: "drive", path: "~/Drive/Import")]
        original.viwoodsCloud?.dailyMonths = 3
        original.notifications = NotificationsConfig(problems: true, newNotes: true, reviewReminder: "08:30")

        var reopened = SetupChoices(from: original)
        XCTAssertEqual(reopened.tablet.name, "Viwoods AiPaper")
        XCTAssertTrue(reopened.useViwoodsCloud)
        XCTAssertEqual(reopened.obsidianVault, "~/Vault")
        XCTAssertTrue(reopened.appleCalendar)
        XCTAssertFalse(reopened.appleReminders)
        XCTAssertTrue(reopened.reviewStack)
        XCTAssertTrue(reopened.shareWithPhone)
        XCTAssertTrue(reopened.notifyNewNotes)
        XCTAssertEqual(reopened.reviewReminder, "08:30")

        // Flip two switches and save over the original.
        reopened.dailyNotes = true
        reopened.appleReminders = true
        reopened.reviewReminder = nil
        let saved = try reopened.config(merging: original)

        XCTAssertEqual(saved.google, original.google)
        XCTAssertEqual(saved.ai, original.ai)
        XCTAssertEqual(saved.recognition.vocabulary, ["Erin", "Ensemble"])
        XCTAssertEqual(saved.sendTargets, original.sendTargets)
        XCTAssertEqual(saved.viwoodsCloud?.dailyMonths, 3)
        XCTAssertEqual(saved.onDelete, ["obsidian": .archive, "gcal": .delete])
        XCTAssertEqual(saved.destinations.map(\.kind), ["obsidian", "appleCalendar", "appleReminders", "reviewStack", "googleCalendar"])
        guard case .obsidian(let obsidian) = saved.destinations[0] else { return XCTFail("no obsidian") }
        XCTAssertTrue(obsidian.dailyNotes)
        XCTAssertEqual(obsidian.vaultPath, "~/Vault")
        guard case .reviewStack(let stack) = saved.destinations[3] else { return XCTFail("no stack") }
        XCTAssertTrue(stack.shareWithPhone)
        XCTAssertEqual(saved.notifications, NotificationsConfig(problems: true, newNotes: true, reviewReminder: nil))

        // The JSON round trip keeps the new keys.
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(RelayConfig.self, from: data), saved)
    }

    func testSettingsKeepEverySourceAndEverySettingTheyDontShow() throws {
        var remarkable = SourceConfig(id: "remarkable", device: "reMarkable", path: "~/Drive/reMarkable", fileTypes: ["pdf"], recognizer: .claude)
        remarkable.aiFolders = ["Daily"]
        remarkable.aiMonthlyBudgetUSD = 2
        remarkable.template = "~/Templates/cornell.png"
        let boox = SourceConfig(id: "boox", device: "Boox", path: "~/Drive/Boox", fileTypes: ["pdf", "png"])
        var cloud = ViwoodsCloudConfig(device: "My AiPaper", apps: ["paper"], dailyMonths: 3)
        cloud.recognizeInkOnly = false
        let original = RelayConfig(
            sources: [remarkable, boox],
            destinations: [
                .obsidian(.init(id: "vault", vaultPath: "~/Vault")),
                .appleNotes(.init(id: "notes", folder: "Tablet", account: "iCloud", attachOriginal: false)),
                .appleCalendar(.init(id: "cal", calendar: "Ink", pageTitle: "Plan")),
                .appleReminders(.init(id: "todo", list: "Ink · {device}")),
            ],
            viwoodsCloud: cloud,
            onDelete: ["notes": .archive]
        )

        let reopened = SetupChoices(from: original)
        XCTAssertEqual(reopened.tablet.name, "Viwoods AiPaper", "a cloud section means a Viwoods, whatever it's called")
        XCTAssertTrue(reopened.useViwoodsCloud)
        XCTAssertEqual(reopened.exportFolder, "~/Drive/reMarkable")
        XCTAssertEqual(reopened.appleNotesAccount, .some("iCloud"))

        let saved = try reopened.config(merging: original)
        XCTAssertEqual(saved.sources, [remarkable, boox], "both tablets, with every field")
        XCTAssertEqual(saved.viwoodsCloud, cloud, "the cloud section keeps its device name and settings")
        XCTAssertEqual(saved.destinations.map(\.id), ["vault", "notes", "cal", "todo"])
        guard case .appleReminders(let reminders) = saved.destinations[3] else { return XCTFail("no reminders") }
        XCTAssertEqual(reminders.list, "Ink · {device}")
        guard case .appleNotes(let notes) = saved.destinations[1] else { return XCTFail("no notes") }
        XCTAssertEqual(notes.folder, "Tablet")
        XCTAssertFalse(notes.attachOriginal)
        XCTAssertEqual(saved.onDelete, ["notes": .archive], "a policy for a kept id survives")

        // Pointing the picker at a new folder changes only the first source's path.
        var moved = reopened
        moved.exportFolder = "~/Drive/reMarkable2"
        let movedConfig = try moved.config(merging: original)
        XCTAssertEqual(movedConfig.sources.map(\.path), ["~/Drive/reMarkable2", "~/Drive/Boox"])
        XCTAssertEqual(movedConfig.sources[0].aiFolders, ["Daily"])
        XCTAssertEqual(movedConfig.sources[0].template, "~/Templates/cornell.png")

        // Choosing "None" removes the first source only.
        var cleared = reopened
        cleared.exportFolder = nil
        XCTAssertEqual(try cleared.config(merging: original).sources.map(\.id), ["boox"])
    }

    func testReplacingAConfigKeepsTheOldFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("config.json")
        try folder.write("config.json", "{ not json")
        let config = try SetupChoices(tablet: TabletPreset.all[0], useViwoodsCloud: true, reviewStack: true).config()
        try ConfigStore.replace(config, at: url)
        XCTAssertEqual(try String(contentsOf: folder.url.appendingPathComponent("config.json.bak"), encoding: .utf8), "{ not json")
        XCTAssertEqual(try ConfigStore.load(from: url), config)
    }

    func testNotificationTimesAreChecked() throws {
        XCTAssertEqual(NotificationsConfig(reviewReminder: "09:05").reminderTime?.hour, 9)
        XCTAssertNil(NotificationsConfig(reviewReminder: "25:00").reminderTime)
        let bad = Data(#"{"sources":[{"id":"a","device":"d","path":"/tmp"}],"destinations":[{"kind":"obsidian","id":"o","vaultPath":"/tmp"}],"notifications":{"reviewReminder":"nine"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RelayConfig.self, from: bad).validate())
    }
}
