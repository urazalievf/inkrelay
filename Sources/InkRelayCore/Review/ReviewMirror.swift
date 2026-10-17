import Foundation

/// A choice made on a phone, applied to the Mac's stack on its next pass.
public struct ReviewDecision: Codable, Equatable, Identifiable {
    public enum Action: String, Codable {
        case done
        case later
        /// Add a suggested event to the Mac's calendars.
        case accept
    }

    public var id: String
    public var card: String
    /// The card's content when the choice was made. A page whose ink changed since comes back as new instead.
    public var contentHash: String
    public var action: Action
    public var at: Date

    public init(id: String = UUID().uuidString, card: String, contentHash: String, action: Action, at: Date) {
        self.id = id
        self.card = card
        self.contentHash = contentHash
        self.action = action
        self.at = at
    }
}

/// What the Mac publishes for phones: every card still in play, due now or later, so the stack moves on
/// with the days even while the Mac is asleep.
public struct SharedStack: Codable, Equatable {
    public var version = 1
    public var dailyLimit: Int
    /// The Mac has a calendar for suggested events.
    public var canAddEvents: Bool
    public var cards: [ReviewCard]
    /// Decisions the Mac applied lately; each phone drops these from its own file.
    public var applied: [String]
}

/// The read-later stack shared with InkRelay on iPhone and iPad through a folder both reach, usually
/// iCloud Drive/InkRelay. Every file has one writer, so iCloud never has two versions to reconcile: the Mac
/// writes `Review/stack.json` and `Review/images/`, and each phone writes only `Review/decisions-<device>.json`.
enum ReviewShare {
    static func folder(in base: URL) -> URL { base.appendingPathComponent("Review", isDirectory: true) }
    static func stackURL(_ folder: URL) -> URL { folder.appendingPathComponent("stack.json") }
    static func imagesURL(_ folder: URL) -> URL { folder.appendingPathComponent("images", isDirectory: true) }
    static func decisionsURL(_ folder: URL, device: String) -> URL {
        let safe = String(device.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return folder.appendingPathComponent("decisions-\(safe).json")
    }

    /// Named by content, so a page whose ink changed gets a new file and no device shows a stale copy.
    static func imageName(for card: ReviewCard) -> String { "\(card.id)-\(card.contentHash.prefix(8)).jpg" }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads through a file coordinator, which also downloads an iCloud file that isn't on the device yet.
    static func read(_ url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data ?? (error == nil ? nil : try? Data(contentsOf: url))
    }

    static func write(_ data: Data, to url: URL) throws {
        var failure: Error?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        if let error { throw error }
    }

    static func decisions(in folder: URL) -> [String: [ReviewDecision]] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var all: [String: [ReviewDecision]] = [:]
        for name in names where name.hasPrefix("decisions-") && name.hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            all[name] = read(url).flatMap { try? decoder.decode([ReviewDecision].self, from: $0) } ?? []
        }
        return all
    }
}

/// The Mac's side: applies what phones decided, then publishes the stack for them.
public final class ReviewPublisher {
    public struct Report: Equatable {
        public var applied = 0
        public var failures: [String] = []
    }

    let store: ReviewStore
    let folder: URL
    let config: DestinationConfig.ReviewStackConfig
    let calendars: [TimedEventWriter]
    let now: () -> Date
    /// Decisions are remembered this long, so one that lingers in a phone's file isn't applied twice.
    static let memory: TimeInterval = 60 * 24 * 3600

    /// `base` is the shared folder (iCloud Drive/InkRelay); the stack goes in its `Review` folder.
    public init(store: ReviewStore, base: URL, config: DestinationConfig.ReviewStackConfig, calendars: [TimedEventWriter] = [], now: @escaping () -> Date = Date.init) {
        self.store = store
        self.folder = ReviewShare.folder(in: base)
        self.config = config
        self.calendars = calendars
        self.now = now
    }

    var appliedURL: URL { store.directory.appendingPathComponent("applied.json") }

    @discardableResult
    public func sync() -> Report {
        var report = Report()
        let applied = apply(into: &report)
        do {
            try publish(applied: applied)
        } catch {
            report.failures.append("review stack for phones: \(error.localizedDescription)")
        }
        return report
    }

    /// Applies new decisions in the order they were made and returns the ids applied lately.
    private func apply(into report: inout Report) -> [String: Date] {
        var applied = (try? Data(contentsOf: appliedURL)).flatMap { try? ReviewShare.decoder.decode([String: Date].self, from: $0) } ?? [:]
        let pending = ReviewShare.decisions(in: folder).values.joined()
            .filter { applied[$0.id] == nil }
            .sorted { $0.at < $1.at }
        if !pending.isEmpty, let cards = try? store.load().cards {
            for decision in pending {
                applied[decision.id] = now()
                // A decision about ink that has since changed is moot: the card is new again.
                guard let card = cards[decision.card], card.contentHash == decision.contentHash else { continue }
                do {
                    switch decision.action {
                    case .done:
                        try store.markDone(card.id, now: decision.at, resurfaceDays: config.resurfaceDays)
                    case .later:
                        try store.snooze(card.id, now: decision.at)
                    case .accept:
                        guard let event = card.event, !calendars.isEmpty else { continue }
                        for calendar in calendars { _ = try calendar.addEvent(event) }
                        try store.markDone(card.id, now: decision.at, resurfaceDays: [])
                    }
                    report.applied += 1
                } catch {
                    report.failures.append("\(card.title): \(error.localizedDescription)")
                }
            }
        }
        let cutoff = now().addingTimeInterval(-Self.memory)
        applied = applied.filter { $0.value > cutoff }
        if !pending.isEmpty, let data = try? ReviewShare.encoder.encode(applied) {
            try? data.write(to: appliedURL, options: .atomic)
        }
        return applied
    }

    private func publish(applied: [String: Date]) throws {
        let cards = ReviewStore.ordered(try store.load().cards.values.filter { $0.status != .done })
        let images = ReviewShare.imagesURL(folder)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var wanted = Set<String>()
        for card in cards where card.hasImage {
            let name = ReviewShare.imageName(for: card)
            wanted.insert(name)
            let target = images.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path), let data = try? Data(contentsOf: store.imageURL(for: card.id)) {
                try ReviewShare.write(data, to: target)
            }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? [] where !wanted.contains(name) {
            try? FileManager.default.removeItem(at: images.appendingPathComponent(name))
        }

        let recent = now().addingTimeInterval(-30 * 24 * 3600)
        let shared = SharedStack(
            dailyLimit: config.dailyLimit,
            canAddEvents: !calendars.isEmpty,
            cards: cards,
            applied: applied.filter { $0.value > recent }.keys.sorted()
        )
        let data = try ReviewShare.encoder.encode(shared)
        let url = ReviewShare.stackURL(folder)
        // Unchanged stacks aren't rewritten, so iCloud only uploads when something happened.
        if ReviewShare.read(url) != data { try ReviewShare.write(data, to: url) }
    }
}

/// A phone's side: today's cards from the Mac's stack, minus whatever this or another phone already decided.
public final class PhoneReviewStack {
    public struct Today: Equatable {
        public var cards: [ReviewCard]
        /// Everything due, of which `cards` is at most the daily limit.
        public var due: Int
        public var canAddEvents: Bool
        /// False until the Mac has published a stack to the folder.
        public var published: Bool
    }

    public let folder: URL
    public let device: String

    /// `base` is the shared folder (iCloud Drive/InkRelay); `device` names this phone's decisions file.
    public init(base: URL, device: String) {
        self.folder = ReviewShare.folder(in: base)
        self.device = device
    }

    var ownURL: URL { ReviewShare.decisionsURL(folder, device: device) }

    public func today(now: Date = Date()) -> Today {
        guard let data = ReviewShare.read(ReviewShare.stackURL(folder)),
              let shared = try? ReviewShare.decoder.decode(SharedStack.self, from: data) else {
            return Today(cards: [], due: 0, canAddEvents: false, published: false)
        }
        let applied = Set(shared.applied)
        let files = ReviewShare.decisions(in: folder)
        // Decisions the Mac has applied are done with; keep this phone's file to the ones still on their way.
        let ownName = ownURL.lastPathComponent
        if let own = files[ownName], own.contains(where: { applied.contains($0.id) }),
           let trimmed = try? ReviewShare.encoder.encode(own.filter { !applied.contains($0.id) }) {
            try? ReviewShare.write(trimmed, to: ownURL)
        }
        let decided = Set(files.values.joined().filter { !applied.contains($0.id) }.map { "\($0.card)|\($0.contentHash)" })
        let due = shared.cards.filter { $0.status != .done && $0.dueAt <= now && !decided.contains("\($0.id)|\($0.contentHash)") }
        let ordered = ReviewStore.ordered(due)
        return Today(cards: Array(ordered.prefix(max(shared.dailyLimit, 1))), due: due.count, canAddEvents: shared.canAddEvents, published: true)
    }

    public func decide(_ card: ReviewCard, _ action: ReviewDecision.Action, at date: Date = Date()) throws {
        var own = ReviewShare.read(ownURL).flatMap { try? ReviewShare.decoder.decode([ReviewDecision].self, from: $0) } ?? []
        own.append(ReviewDecision(card: card.id, contentHash: card.contentHash, action: action, at: date))
        try ReviewShare.write(try ReviewShare.encoder.encode(own), to: ownURL)
    }

    /// The page image, downloaded from iCloud first if it isn't on the phone yet.
    public func imageData(for card: ReviewCard) -> Data? {
        guard card.hasImage else { return nil }
        return ReviewShare.read(ReviewShare.imagesURL(folder).appendingPathComponent(ReviewShare.imageName(for: card)))
    }
}
