import Foundation

/// Runs InkRelay in-process for an app: syncs at start, on folder changes and on a timer, serves the review
/// stack, and reports what it's doing. UI-free, so the menu bar app and tests drive it the same way.
public final class RelayRunner {
    public enum Status: Equatable {
        case notConfigured(String)
        case idle
        case syncing
        case paused
        /// Number of problems in the last pass.
        case attention(Int)
    }

    public struct RecentNote: Equatable, Identifiable {
        public var id: String
        public var title: String
        public var syncedAt: Date
        /// Where clicking it goes: the Obsidian note, or the original export.
        public var openURL: URL?
        public var destinations: [String]
    }

    public struct Snapshot: Equatable {
        public var status: Status = .notConfigured("Starting…")
        public var lastSync: Date?
        public var summary = ""
        public var problems: [String] = []
        public var recent: [RecentNote] = []
        public var reviewDue = 0
        public var reviewURL: URL?
        /// Notes delivered by the last pass; they're at the top of `recent`.
        public var lastSynced = 0

        public init() {}
    }

    public let configURL: URL
    public var stateURL: URL { configURL.deletingLastPathComponent().appendingPathComponent("state.json") }
    public var supportDirectory: URL { configURL.deletingLastPathComponent() }

    /// Called on the runner's queue whenever the snapshot changes.
    public var onChange: ((Snapshot) -> Void)?
    public private(set) var snapshot = Snapshot() {
        didSet { if snapshot != oldValue { onChange?(snapshot) } }
    }

    private let queue = DispatchQueue(label: "inkrelay.runner")
    private let makeEngine: (RelayConfig, URL) throws -> RelayEngine
    private let startsReviewServer: Bool
    private let now: () -> Date
    private var config: RelayConfig?
    private var engine: RelayEngine?
    #if os(macOS)
    private var watcher: FolderWatcher?
    #endif
    private var timer: DispatchSourceTimer?
    private var reviewServer: ReviewServer?
    private var paused = false
    private var syncing = false
    private var syncAgain = false
    /// Where each pass is written down, when set. The app sets it; tests and the agent don't.
    private let log: SyncLog?

    public init(
        configURL: URL = InkRelayCore.defaultConfigURL,
        startsReviewServer: Bool = true,
        log: SyncLog? = nil,
        now: @escaping () -> Date = Date.init,
        makeEngine: @escaping (RelayConfig, URL) throws -> RelayEngine = { try RelayEngine.live(config: $0, stateURL: $1) }
    ) {
        self.log = log
        self.configURL = configURL
        self.startsReviewServer = startsReviewServer
        self.now = now
        self.makeEngine = makeEngine
    }

    /// Loads the config and starts watching. Call again after the config changes.
    public func start() {
        queue.async { self.restart() }
    }

    public func stop() {
        queue.sync { self.tearDown() }
    }

    public func syncNow() {
        queue.async { self.sync(reason: "manual") }
    }

    public func setPaused(_ value: Bool) {
        queue.async {
            self.paused = value
            self.snapshot.status = value ? .paused : self.statusAfter(problems: self.snapshot.problems.count)
            if !value { self.sync(reason: "resumed") }
        }
    }

    /// Runs `work` after everything queued so far, for tests and for callers that need a settled snapshot.
    public func waitUntilIdle() {
        queue.sync {}
    }

    private func restart() {
        tearDown()
        let loaded: RelayConfig
        do {
            loaded = try ConfigStore.load(from: configURL)
        } catch {
            snapshot.status = .notConfigured(error.localizedDescription)
            return
        }
        do {
            engine = try makeEngine(loaded, stateURL)
        } catch {
            snapshot.status = .notConfigured(error.localizedDescription)
            return
        }
        config = loaded
        #if os(macOS)
        let watcher = FolderWatcher(urls: loaded.sources.map(\.url)) { [weak self] in self?.queue.async { self?.sync(reason: "folder change") } }
        if !loaded.sources.isEmpty { watcher.start() }
        self.watcher = watcher
        #endif

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(loaded.rescanIntervalSeconds), repeating: .seconds(loaded.rescanIntervalSeconds))
        timer.setEventHandler { [weak self] in self?.sync(reason: "rescan") }
        timer.resume()
        self.timer = timer

        if startsReviewServer, let stack = Self.reviewStack(in: loaded) {
            let calendars = DestinationFactory.eventWriters(in: DestinationFactory.make(loaded.destinations, context: DestinationContext(config: loaded, supportDirectory: supportDirectory)))
            let server = ReviewServer(store: ReviewStore(directory: reviewDirectory), config: stack, calendars: calendars)
            snapshot.reviewURL = try? server.start()
            reviewServer = snapshot.reviewURL == nil ? nil : server
        }
        snapshot.status = paused ? .paused : .idle
        sync(reason: "startup")
    }

    private func tearDown() {
        #if os(macOS)
        watcher?.stop()
        watcher = nil
        #endif
        timer?.cancel()
        timer = nil
        reviewServer?.stop()
        reviewServer = nil
        engine = nil
        config = nil
        snapshot.reviewURL = nil
    }

    private var reviewDirectory: URL { supportDirectory.appendingPathComponent("review", isDirectory: true) }

    private func sync(reason: String) {
        guard let engine, !paused else { return }
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        snapshot.status = .syncing
        let report = engine.syncOnce()
        log?.append(reason: reason, report: report, at: now())
        syncing = false
        // One snapshot for the whole pass, so nobody sees a new lastSync with the previous pass's counts.
        var next = snapshot
        next.lastSync = now()
        next.summary = report.summary
        next.lastSynced = report.synced
        next.problems = report.failures.map { failure in
            failure.item + (failure.destinationID.map { " → \($0)" } ?? "") + ": " + failure.message
        } + report.warnings
        next.status = statusAfter(problems: report.failures.count)
        refreshDetails(&next)
        snapshot = next
        if report.deferred > 0, let settle = config?.settleSeconds {
            queue.asyncAfter(deadline: .now() + .seconds(settle + 1)) { [weak self] in self?.sync(reason: "settled files") }
        }
        if syncAgain {
            syncAgain = false
            sync(reason: "changes during the last pass")
        }
    }

    private func statusAfter(problems: Int) -> Status {
        if paused { return .paused }
        return problems > 0 ? .attention(problems) : .idle
    }

    private func refreshDetails() {
        var next = snapshot
        refreshDetails(&next)
        snapshot = next
    }

    private func refreshDetails(_ snapshot: inout Snapshot) {
        guard let config else { return }
        snapshot.recent = Self.recentNotes(state: (try? StateStore(url: stateURL))?.state ?? SyncState(), config: config)
        if let stack = Self.reviewStack(in: config) {
            snapshot.reviewDue = (try? ReviewStore(directory: reviewDirectory).stack(now: now(), limit: stack.dailyLimit).due) ?? 0
        }
    }

    static func reviewStack(in config: RelayConfig) -> DestinationConfig.ReviewStackConfig? {
        for destination in config.destinations {
            if case .reviewStack(let stack) = destination { return stack }
        }
        return nil
    }

    /// The most recently relayed exports, newest first, each with somewhere to open it.
    static func recentNotes(state: SyncState, config: RelayConfig, limit: Int = 8) -> [RecentNote] {
        let vaults: [String: URL] = Dictionary(uniqueKeysWithValues: config.destinations.compactMap { destination in
            if case .obsidian(let obsidian) = destination { return (obsidian.id, obsidian.vaultURL) }
            return nil
        })
        let sources = Dictionary(uniqueKeysWithValues: config.allSources.map { ($0.id, $0) })
        return state.files.compactMap { key, record -> RecentNote? in
            guard let last = record.destinations.values.map(\.syncedAt).max(), record.missingSince == nil else { return nil }
            let relative = key.split(separator: "/", maxSplits: 1).last.map(String.init) ?? key
            var open: URL?
            if let (id, vault) = vaults.first(where: { record.destinations[$0.key] != nil }), let note = record.destinations[id] {
                var components = URLComponents()
                components.scheme = "obsidian"
                components.host = "open"
                components.queryItems = [URLQueryItem(name: "path", value: vault.appendingPathComponent(note.externalID).path)]
                open = components.url
            } else if let sourceID = key.split(separator: "/").first.map(String.init), let source = sources[sourceID] {
                open = source.url.appendingPathComponent(relative)
            }
            return RecentNote(
                id: key,
                title: ((relative as NSString).lastPathComponent as NSString).deletingPathExtension,
                syncedAt: last,
                openURL: open,
                destinations: record.destinations.keys.sorted()
            )
        }
        .sorted { $0.syncedAt > $1.syncedAt }
        .prefix(limit)
        .map { $0 }
    }
}
