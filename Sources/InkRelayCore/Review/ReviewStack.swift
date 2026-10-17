import CryptoKit
import Darwin
import Foundation

/// One card in the read-later stack: a single notebook page or a single to-do, small enough to take in at a glance.
public struct ReviewCard: Codable, Equatable {
    public enum Kind: String, Codable {
        case page
        case todo
        /// A dated line, offered as a calendar event.
        case event
    }

    public enum Status: String, Codable {
        /// Arrived or changed since you last saw it.
        case new
        /// "Later": back at the start of a coming day.
        case snoozed
        /// Done, but scheduled to come back (spaced resurfacing).
        case resurfacing
        /// Out of the stack until its content changes.
        case done
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var text: String
    /// The notebook or to-do the card belongs to: `<source id>/<relative path>` or `todo/<id>`.
    public var itemKey: String
    public var page: Int?
    public var contentHash: String
    public var hasImage: Bool
    public var arrivedAt: Date
    public var dueAt: Date
    public var status: Status
    /// How many times it was marked done.
    public var reviews: Int
    /// For event cards: what "Add to calendar" creates.
    public var event: SuggestedEvent?
}

public struct ReviewState: Codable, Equatable {
    public var cards: [String: ReviewCard] = [:]

    public init(cards: [String: ReviewCard] = [:]) {
        self.cards = cards
    }
}

/// A card as a destination hands it over, before the stack decides where it goes.
struct CardDraft {
    var id: String
    var kind: ReviewCard.Kind
    var title: String
    var subtitle: String
    var text: String
    var page: Int?
    var contentHash: String
    var image: Data?
    /// To-dos ticked off on the tablet skip the stack.
    var finished: Bool = false
    var event: SuggestedEvent?
}

/// The stack on disk: `stack.json` plus one JPEG per page card. Every change takes a file lock and
/// re-reads the file, so `inkrelay watch`, the review page and `inkrelay review` can all touch it at once.
public final class ReviewStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var stateURL: URL { directory.appendingPathComponent("stack.json") }
    var lockURL: URL { directory.appendingPathComponent(".lock") }
    var imagesURL: URL { directory.appendingPathComponent("images", isDirectory: true) }

    public func imageURL(for cardID: String) -> URL {
        imagesURL.appendingPathComponent(cardID + ".jpg")
    }

    public func load() throws -> ReviewState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return ReviewState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReviewState.self, from: Data(contentsOf: stateURL))
    }

    @discardableResult
    func mutate<T>(_ change: (inout ReviewState) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: lockURL.path]) }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }

        var state = try load()
        let result = try change(&state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        return result
    }

    // MARK: Filling the stack

    /// Replaces the cards of one notebook or to-do. Unchanged cards keep their place and status;
    /// new or changed ones go to the top of the stack; pages that disappeared are dropped.
    func ingest(itemKey: String, drafts: [CardDraft], now: Date) throws {
        try mutate { state in
            let wanted = Set(drafts.map(\.id))
            for (id, card) in state.cards where card.itemKey == itemKey && !wanted.contains(id) {
                state.cards[id] = nil
                try? FileManager.default.removeItem(at: imageURL(for: id))
            }
            for draft in drafts {
                if var existing = state.cards[draft.id], existing.contentHash == draft.contentHash {
                    // Same ink: only follow renames, and close to-dos ticked off on the tablet.
                    existing.title = draft.title
                    existing.subtitle = draft.subtitle
                    if draft.finished { existing.status = .done }
                    state.cards[draft.id] = existing
                    continue
                }
                if let image = draft.image {
                    try image.write(to: imageURL(for: draft.id), options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: imageURL(for: draft.id))
                }
                state.cards[draft.id] = ReviewCard(
                    id: draft.id, kind: draft.kind, title: draft.title, subtitle: draft.subtitle, text: draft.text,
                    itemKey: itemKey, page: draft.page, contentHash: draft.contentHash, hasImage: draft.image != nil,
                    arrivedAt: now, dueAt: now, status: draft.finished ? .done : .new, reviews: 0, event: draft.event
                )
            }
        }
    }

    /// After a rename: the item's cards take the new key and ids, keeping their status and history.
    func moveItem(from oldKey: String, to newKey: String, id: (Int?) -> String) throws {
        try mutate { state in
            for (oldID, card) in state.cards where card.itemKey == oldKey {
                var moved = card
                moved.itemKey = newKey
                moved.id = id(card.page)
                state.cards[oldID] = nil
                state.cards[moved.id] = moved
                if FileManager.default.fileExists(atPath: imageURL(for: oldID).path) {
                    try? FileManager.default.removeItem(at: imageURL(for: moved.id))
                    try? FileManager.default.moveItem(at: imageURL(for: oldID), to: imageURL(for: moved.id))
                }
            }
        }
    }

    func removeItem(_ itemKey: String) throws {
        try mutate { state in
            for (id, card) in state.cards where card.itemKey == itemKey {
                state.cards[id] = nil
                try? FileManager.default.removeItem(at: imageURL(for: id))
            }
        }
    }

    // MARK: Reading and acting

    /// Today's stack: everything due, newest arrivals first, a notebook's pages in order, at most `limit`.
    public func stack(now: Date, limit: Int) throws -> (cards: [ReviewCard], due: Int) {
        let due = try load().cards.values.filter { $0.status != .done && $0.dueAt <= now }
        let ordered = due.sorted { a, b in
            if a.arrivedAt != b.arrivedAt { return a.arrivedAt > b.arrivedAt }
            if a.itemKey != b.itemKey { return a.itemKey < b.itemKey }
            return (a.page ?? 0) < (b.page ?? 0)
        }
        return (Array(ordered.prefix(max(limit, 0))), due.count)
    }

    /// Done: out of the stack, or scheduled to come back when `resurfaceDays` says so.
    @discardableResult
    public func markDone(_ id: String, now: Date, resurfaceDays: [Int], calendar: Calendar = .current) throws -> ReviewCard? {
        try mutate { state in
            guard var card = state.cards[id] else { return nil }
            card.reviews += 1
            if card.reviews <= resurfaceDays.count,
               let next = calendar.date(byAdding: .day, value: resurfaceDays[card.reviews - 1], to: calendar.startOfDay(for: now)) {
                card.status = .resurfacing
                card.dueAt = next
            } else {
                card.status = .done
            }
            state.cards[id] = card
            return card
        }
    }

    /// Later: back at the start of the next day (or `days` from today).
    @discardableResult
    public func snooze(_ id: String, now: Date, days: Int = 1, calendar: Calendar = .current) throws -> ReviewCard? {
        try mutate { state in
            guard var card = state.cards[id],
                  let next = calendar.date(byAdding: .day, value: max(days, 1), to: calendar.startOfDay(for: now)) else { return nil }
            card.status = .snoozed
            card.dueAt = next
            state.cards[id] = card
            return card
        }
    }

    /// Accepts a full id or the first few characters of one, as `inkrelay review` prints them.
    public func resolve(_ prefix: String) throws -> String? {
        let matches = try load().cards.keys.filter { $0.hasPrefix(prefix.lowercased()) }
        return matches.count == 1 ? matches.first : nil
    }

    static func cardID(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ text: String, _ image: Data?) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(text.utf8))
        if let image { hasher.update(data: image) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Feeds the stack: each page of each relayed note becomes a card, and so does each planner to-do.
/// Only pages whose ink or text changed come back to the top, so adding page 12 to a notebook
/// brings one card, not twelve.
public struct ReviewStackDestination: NoteDestination, PlanDestination {
    public var config: DestinationConfig.ReviewStackConfig
    public let store: ReviewStore
    private let renderImages: (URL) -> [Data]
    private let now: () -> Date

    public init(
        config: DestinationConfig.ReviewStackConfig,
        store: ReviewStore,
        renderImages: @escaping (URL) -> [Data] = { (try? PageImages.jpegs(for: $0, maxPixelDimension: 1600)) ?? [] },
        now: @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.store = store
        self.renderImages = renderImages
        self.now = now
    }

    public var id: String { config.id }

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        let itemKey = "\(note.sourceID)/\(note.relativePath)"
        if let old = previous?.externalID, old.hasPrefix("review:"), old != "review:" + itemKey {
            try store.removeItem(String(old.dropFirst("review:".count)) + "#events")
            try store.moveItem(from: String(old.dropFirst("review:".count)), to: itemKey) { page in
                ReviewStore.cardID("\(itemKey)#\(page ?? 1)")
            }
        }
        let images = renderImages(note.originalURL)
        let title = Self.title(for: note)
        let folder = (note.relativePath as NSString).deletingLastPathComponent
        let drafts = note.pages.map { page -> CardDraft in
            let image = page.number <= images.count ? images[page.number - 1] : nil
            var subtitle = note.pages.count > 1 ? "Page \(page.number) of \(note.pages.count)" : "1 page"
            if !folder.isEmpty { subtitle += " · " + folder }
            return CardDraft(
                id: ReviewStore.cardID("\(itemKey)#\(page.number)"),
                kind: .page,
                title: title,
                subtitle: subtitle,
                text: page.text.trimmingCharacters(in: .whitespacesAndNewlines),
                page: page.number,
                contentHash: ReviewStore.hash(page.text, image),
                image: image
            )
        }
        try store.ingest(itemKey: itemKey, drafts: drafts, now: now())

        // Dated lines become suggested events; nothing reaches a calendar until "Add to calendar".
        let plannerDate = PlannerEvent.plannerDate(of: note)
        let events = note.pages.flatMap { TaskExtractor.events(in: $0.text, title: title, plannerDate: plannerDate) }
        let eventDrafts = events.map { event -> CardDraft in
            CardDraft(
                id: ReviewStore.cardID("\(itemKey)#event#\(event.title)"),
                kind: .event,
                title: event.title,
                subtitle: "Suggested event · " + Self.friendlyTime(event.start) + " · from " + title,
                text: event.title,
                page: nil,
                contentHash: ReviewStore.hash(event.title + "|\(event.start.timeIntervalSince1970)", nil),
                image: nil,
                event: event
            )
        }
        try store.ingest(itemKey: itemKey + "#events", drafts: eventDrafts, now: now())
        return "review:" + itemKey
    }

    static func friendlyTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE, MMM d, h:mm a"
        return formatter.string(from: date)
    }

    public func upsert(_ todo: DailyTodo, previous: String?) throws -> String {
        let itemKey = "todo/\(todo.id)"
        var subtitle = "To-do · " + Self.friendlyDate(todo.date)
        if let priority = todo.priority { subtitle += " · " + priority }
        let draft = CardDraft(
            id: ReviewStore.cardID(itemKey),
            kind: .todo,
            title: todo.text.isEmpty ? "To-do" : PlannerEvent.firstLine(of: todo.text),
            subtitle: subtitle,
            text: todo.text,
            page: nil,
            contentHash: ReviewStore.hash(todo.text + "|\(todo.isFinished)|\(todo.level ?? -1)", nil),
            image: nil,
            finished: todo.isFinished
        )
        try store.ingest(itemKey: itemKey, drafts: [draft], now: now())
        return "review:" + itemKey
    }

    /// Archive or delete: either way the cards leave the stack.
    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        guard policy != .keep, record.externalID.hasPrefix("review:") else { return }
        let itemKey = String(record.externalID.dropFirst("review:".count))
        try store.removeItem(itemKey)
        try store.removeItem(itemKey + "#events")
    }

    static func title(for note: InkNote) -> String {
        if let date = PlannerEvent.plannerDate(of: note) { return "Daily plan · " + friendlyDate(date) }
        return note.title
    }

    /// `2026-01-13` → `Tue, Jan 13, 2026`.
    static func friendlyDate(_ date: String) -> String {
        guard let day = PlannerEvent.dayFormatter.date(from: date) else { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = PlannerEvent.utcCalendar.timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy"
        return formatter.string(from: day)
    }
}
