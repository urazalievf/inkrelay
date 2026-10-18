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

    func testNotificationTimesAreChecked() throws {
        XCTAssertEqual(NotificationsConfig(reviewReminder: "09:05").reminderTime?.hour, 9)
        XCTAssertNil(NotificationsConfig(reviewReminder: "25:00").reminderTime)
        let bad = Data(#"{"sources":[{"id":"a","device":"d","path":"/tmp"}],"destinations":[{"kind":"obsidian","id":"o","vaultPath":"/tmp"}],"notifications":{"reviewReminder":"nine"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RelayConfig.self, from: bad).validate())
    }
}
