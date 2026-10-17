import XCTest
@testable import InkRelayCore

final class ReviewMirrorTests: XCTestCase {
    private final class Calendar: TimedEventWriter {
        let id = "calendar"
        var added: [SuggestedEvent] = []
        func addEvent(_ event: SuggestedEvent) throws -> String {
            added.append(event)
            return "event-\(added.count)"
        }
    }

    private var support: TemporaryFolder!
    private var shared: TemporaryFolder!
    private var store: ReviewStore!
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        support = try TemporaryFolder()
        shared = try TemporaryFolder()
        store = ReviewStore(directory: support.url.appendingPathComponent("review"))
    }

    override func tearDown() {
        support.remove()
        shared.remove()
    }

    private func file(_ pages: [String], at date: Date, path: String = "Paper/Plan.pdf") throws {
        let destination = ReviewStackDestination(config: .init(id: "review"), store: store, renderImages: { _ in pages.map { Data($0.utf8) } }, now: { date })
        let note = makeNote(title: "Plan", relativePath: path, pages: pages.enumerated().map { RecognizedPage(number: $0.offset + 1, text: $0.element) })
        _ = try destination.upsert(note, previous: nil)
    }

    private func publisher(calendars: [TimedEventWriter] = [], resurface: [Int] = [], at date: Date) -> ReviewPublisher {
        ReviewPublisher(store: store, base: shared.url, config: .init(id: "review", dailyLimit: 2, resurfaceDays: resurface), calendars: calendars, now: { date })
    }

    func testAPhoneReviewsTheMacsStackAndTheMacCatchesUp() throws {
        try file(["Page one", "Page two", "Page three"], at: start)
        publisher(at: start).sync()

        let phone = PhoneReviewStack(base: shared.url, device: "phone-1")
        let today = phone.today(now: start)
        XCTAssertTrue(today.published)
        XCTAssertEqual(today.cards.map(\.text), ["Page one", "Page two"], "the daily limit applies on the phone too")
        XCTAssertEqual(today.due, 3)
        XCTAssertEqual(phone.imageData(for: today.cards[0]), Data("Page one".utf8))

        try phone.decide(today.cards[0], .done, at: start)
        try phone.decide(today.cards[1], .later, at: start)
        XCTAssertEqual(phone.today(now: start).cards.map(\.text), ["Page three"], "decided cards leave the phone's stack at once")

        let report = publisher(resurface: [3], at: start.addingTimeInterval(60)).sync()
        XCTAssertEqual(report, ReviewPublisher.Report(applied: 2, failures: []))
        let cards = try store.load().cards.values
        XCTAssertEqual(cards.first { $0.text == "Page one" }?.status, .resurfacing)
        XCTAssertEqual(cards.first { $0.text == "Page two" }?.status, .snoozed)
        XCTAssertEqual(try store.stack(now: start.addingTimeInterval(120), limit: 10).cards.map(\.text), ["Page three"])

        // The phone's file is trimmed once the Mac says it applied them, and nothing is applied twice.
        XCTAssertEqual(phone.today(now: start.addingTimeInterval(120)).cards.map(\.text), ["Page three"])
        let own = try JSONDecoder.iso8601.decode([ReviewDecision].self, from: Data(contentsOf: phone.ownURL))
        XCTAssertEqual(own, [])
        XCTAssertEqual(publisher(at: start.addingTimeInterval(180)).sync().applied, 0)

        // Snoozed cards come back the next day on the phone, even before the Mac runs again.
        let tomorrow = start.addingTimeInterval(36 * 3600)
        XCTAssertTrue(phone.today(now: tomorrow).cards.contains { $0.text == "Page two" })
    }

    func testADecisionAboutInkThatChangedSinceIsIgnored() throws {
        try file(["Draft"], at: start)
        publisher(at: start).sync()
        let phone = PhoneReviewStack(base: shared.url, device: "phone-1")
        let card = try XCTUnwrap(phone.today(now: start).cards.first)

        try phone.decide(card, .done, at: start)
        try file(["Draft, finished"], at: start.addingTimeInterval(30))
        publisher(at: start.addingTimeInterval(60)).sync()

        let after = try XCTUnwrap(store.load().cards.values.first)
        XCTAssertEqual(after.status, .new)
        XCTAssertEqual(phone.today(now: start.addingTimeInterval(60)).cards.map(\.text), ["Draft, finished"])
    }

    func testAcceptingASuggestedEventOnThePhoneAddsItOnTheMac() throws {
        let destination = ReviewStackDestination(config: .init(id: "review"), store: store, renderImages: { _ in [] }, now: { self.start })
        let note = makeNote(title: "Plan", relativePath: "Paper/Plan.pdf", pages: [RecognizedPage(number: 1, text: "Dentist 2026-09-25 3pm")])
        _ = try destination.upsert(note, previous: nil)
        let calendar = Calendar()
        publisher(calendars: [calendar], at: start).sync()

        let phone = PhoneReviewStack(base: shared.url, device: "phone-1")
        let today = phone.today(now: start)
        XCTAssertTrue(today.canAddEvents)
        let event = try XCTUnwrap(today.cards.first { $0.kind == .event })
        try phone.decide(event, .accept, at: start)
        publisher(calendars: [calendar], at: start.addingTimeInterval(60)).sync()

        XCTAssertEqual(calendar.added.map(\.title), [event.event?.title].compactMap { $0 })
        XCTAssertEqual(try store.load().cards[event.id]?.status, .done)
    }

    func testAnUnchangedStackIsNotRewritten() throws {
        try file(["Page one"], at: start)
        publisher(at: start).sync()
        let url = ReviewShare.stackURL(ReviewShare.folder(in: shared.url))
        let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)

        publisher(at: start.addingTimeInterval(600)).sync()

        XCTAssertNotNil(written)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970, 1)
    }

    func testNoPublishedStackYet() {
        let today = PhoneReviewStack(base: shared.url, device: "phone-1").today(now: start)
        XCTAssertFalse(today.published)
        XCTAssertEqual(today.cards, [])
    }

    func testSharingIsOffUntilAskedForAndFollowsTheLedgerFolder() throws {
        let off = try JSONDecoder().decode(DestinationConfig.ReviewStackConfig.self, from: Data(#"{"id":"review"}"#.utf8))
        XCTAssertNil(off.shareBase(ledger: nil))
        let on = try JSONDecoder().decode(DestinationConfig.ReviewStackConfig.self, from: Data(#"{"id":"review","shareWithPhone":true}"#.utf8))
        XCTAssertEqual(on.shareBase(ledger: SharedLedgerConfig(folder: "/tmp/Shared"))?.path, "/tmp/Shared")
        let custom = DestinationConfig.ReviewStackConfig(id: "review", shareWithPhone: true, shareFolder: "/tmp/Elsewhere")
        XCTAssertEqual(custom.shareBase(ledger: SharedLedgerConfig(folder: "/tmp/Shared"))?.path, "/tmp/Elsewhere")
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
