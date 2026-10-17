import Foundation

/// Mirrors Viwoods Cloud into a local folder of PDFs, one per notebook, memo or planner day.
/// That folder is then an ordinary InkRelay source, so recognition and every destination work unchanged.
///
/// To-do items from the planner have no ink to recognize; they go straight to the plan destinations.
public final class ViwoodsCloudPuller {
    public let config: ViwoodsCloudConfig
    private let client: ViwoodsClient
    private let plans: [PlanDestination]
    private let fileManager: FileManager
    private let now: () -> Date
    private var manifest: ViwoodsManifest

    public init(
        config: ViwoodsCloudConfig,
        client: ViwoodsClient,
        plans: [PlanDestination],
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.config = config
        self.client = client
        self.plans = plans
        self.fileManager = fileManager
        self.now = now
        manifest = try ViwoodsManifest.load(from: config.manifestURL)
    }

    public func pull() -> PullReport {
        var report = PullReport()
        do {
            try fileManager.createDirectory(at: config.cacheURL, withIntermediateDirectories: true)
        } catch {
            report.failures.append("cache folder: \(error.localizedDescription)")
            return report
        }
        for app in config.enabledApps {
            var seen = Set<String>()
            do {
                switch app {
                case .memo: try pullMemos(seen: &seen, into: &report)
                case .paper, .meeting: try pullNotebooks(app, parent: "", folder: app.folderName, seen: &seen, into: &report)
                case .knowledgeBase: continue // The portal exposes only its tabs; nothing to download yet.
                }
                // Only after a complete listing: anything not seen was deleted in the cloud.
                prune(app, keeping: seen, into: &report)
            } catch {
                report.failures.append("\(app.folderName): \(error.localizedDescription)")
            }
        }
        if config.daily {
            pullDaily(into: &report)
        }
        do {
            try manifest.save(to: config.manifestURL)
        } catch {
            report.failures.append("manifest: \(error.localizedDescription)")
        }
        return report
    }

    // MARK: Notebooks

    private func pullNotebooks(_ app: ViwoodsApp, parent: String, folder: String, seen: inout Set<String>, into report: inout PullReport) throws {
        for item in try client.contents(of: app, parent: parent) where !item.isSkippable {
            if item.isFolder {
                try pullNotebooks(app, parent: item.resourceId, folder: folder + "/" + safe(item.name), seen: &seen, into: &report)
                continue
            }
            seen.insert(item.resourceId)
            report.checked += 1
            if item.isEncrypted {
                report.failures.append("\(folder)/\(item.name): password-protected notes can't be pulled")
                continue
            }
            let relativePath = folder + "/" + safe(item.name) + ".pdf"
            if isCurrent(item.resourceId, modified: item.lastModifiedTime, at: relativePath) {
                report.unchanged += 1
                continue
            }
            if moveIfOnlyRenamed(item.resourceId, modified: item.lastModifiedTime, to: relativePath) {
                report.updated += 1
                continue
            }
            do {
                let notebook = try client.notebook(app, uuid: item.resourceId)
                try writePDF(from: notebook.pageImageURLs(), to: relativePath, modified: item.lastModifiedTime)
                remember(item.resourceId, modified: item.lastModifiedTime, at: relativePath)
                report.updated += 1
            } catch {
                report.failures.append("\(folder)/\(item.name): \(error.localizedDescription)")
            }
        }
    }

    private func pullMemos(seen: inout Set<String>, into report: inout PullReport) throws {
        for item in try client.contents(of: .memo, parent: "") where !item.isSkippable && !item.isFolder {
            seen.insert(item.resourceId)
            report.checked += 1
            let relativePath = ViwoodsApp.memo.folderName + "/" + safe(item.name) + ".pdf"
            if isCurrent(item.resourceId, modified: item.lastModifiedTime, at: relativePath) {
                report.unchanged += 1
                continue
            }
            if moveIfOnlyRenamed(item.resourceId, modified: item.lastModifiedTime, to: relativePath) {
                report.updated += 1
                continue
            }
            do {
                let memo = try client.memo(uuid: item.resourceId)
                try writePDF(from: memo.pageImageURLs(), to: relativePath, modified: item.lastModifiedTime)
                remember(item.resourceId, modified: item.lastModifiedTime, at: relativePath)
                report.updated += 1
            } catch {
                report.failures.append("Memo/\(item.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Planner

    private func pullDaily(into report: inout PullReport) {
        for month in recentMonths() {
            let dates: [ViwoodsDailyDate]
            do {
                dates = try client.dailyDates(month: month)
            } catch {
                report.failures.append("Daily \(month): \(error.localizedDescription)")
                continue
            }
            for day in dates {
                guard let date = ViwoodsDate.normalize(day.date) else { continue }
                pullDay(date, into: &report)
            }
        }
    }

    private func pullDay(_ date: String, into report: inout PullReport) {
        report.checked += 1
        do {
            let pages = try client.dailyItems(from: date, to: date, kind: .tasks)
                + client.dailyItems(from: date, to: date, kind: .notes)
            let todos = try client.dailyItems(from: date, to: date, kind: .todo)
            let modified = (pages + todos).compactMap(\.lastModifiedTime).max() ?? 0
            let fingerprint = "\(modified)/\(pages.count)/\(todos.count)"
            let relativePath = "Daily/\(date).pdf"
            if manifest.days[date]?.fingerprint == fingerprint, pages.isEmpty || fileManager.fileExists(atPath: config.cacheURL.appendingPathComponent(relativePath).path) {
                report.unchanged += 1
                return
            }
            let urls = pages.filter { $0.isDelete != 1 }
                .sorted { ($0.type, $0.pageOrder ?? 0) < ($1.type, $1.pageOrder ?? 0) }
                .compactMap { $0.url.flatMap(URL.init(string:)) }
            if !urls.isEmpty {
                try writePDF(from: urls, to: relativePath, modified: modified)
            }
            for todo in todos where todo.isDelete != 1 {
                deliver(DailyTodo(todo, date: date), into: &report)
            }
            manifest.days[date] = DayEntry(fingerprint: fingerprint)
            report.updated += 1
        } catch {
            report.failures.append("Daily \(date): \(error.localizedDescription)")
        }
    }

    private func deliver(_ todo: DailyTodo, into report: inout PullReport) {
        for plan in plans {
            let key = "\(plan.id)/\(todo.id)"
            let previous = manifest.plans[key]
            if previous?.fingerprint == todo.fingerprint { continue }
            do {
                let externalID = try plan.upsert(todo, previous: previous?.externalID)
                manifest.plans[key] = PlanEntry(externalID: externalID, fingerprint: todo.fingerprint)
                report.plansDelivered += 1
            } catch {
                report.failures.append("Daily \(todo.date) to-do → \(plan.id): \(error.localizedDescription)")
            }
        }
    }

    /// `yyyy-MM` for this month and the configured number of months before it.
    func recentMonths() -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM"
        return (0..<max(config.dailyMonths, 1)).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: now()).map(formatter.string)
        }
    }

    // MARK: Files and manifest

    /// `modified` is the cloud's time in milliseconds. The PDF carries it, so notes are dated when they were
    /// written on the tablet rather than when they were pulled.
    private func writePDF(from urls: [URL], to relativePath: String, modified: Int64?) throws {
        guard !urls.isEmpty else { throw PDFComposerError.noPages }
        let images = try urls.map(client.download)
        let url = config.cacheURL.appendingPathComponent(relativePath)
        try PDFComposer.write(pageImages: images, to: url)
        if let modified, modified > 0 {
            try? fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(modified) / 1000)], ofItemAtPath: url.path)
        }
    }

    private func isCurrent(_ resourceID: String, modified: Int64?, at relativePath: String) -> Bool {
        guard let entry = manifest.notes[resourceID] else { return false }
        return entry.modified == (modified ?? 0) && entry.path == relativePath
            && fileManager.fileExists(atPath: config.cacheURL.appendingPathComponent(relativePath).path)
    }

    /// A rename or move on the tablet with no new ink: move the cached PDF, byte for byte, so the relay
    /// recognizes the same content at a new path and moves the notes instead of duplicating them.
    private func moveIfOnlyRenamed(_ resourceID: String, modified: Int64?, to relativePath: String) -> Bool {
        guard let entry = manifest.notes[resourceID], entry.modified == (modified ?? 0), entry.path != relativePath else { return false }
        let old = config.cacheURL.appendingPathComponent(entry.path)
        let new = config.cacheURL.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: old.path) else { return false }
        do {
            try fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: new.path) { try fileManager.removeItem(at: new) }
            try fileManager.moveItem(at: old, to: new)
        } catch {
            return false
        }
        manifest.notes[resourceID] = NoteEntry(modified: entry.modified, path: relativePath)
        return true
    }

    /// Drops cached PDFs of notebooks that are no longer in the cloud, so the relay sees them as deleted.
    private func prune(_ app: ViwoodsApp, keeping seen: Set<String>, into report: inout PullReport) {
        let prefix = app.folderName + "/"
        for (resourceID, entry) in manifest.notes where entry.path.hasPrefix(prefix) && !seen.contains(resourceID) {
            try? fileManager.removeItem(at: config.cacheURL.appendingPathComponent(entry.path))
            manifest.notes[resourceID] = nil
            report.removed += 1
        }
    }

    private func remember(_ resourceID: String, modified: Int64?, at relativePath: String) {
        if let old = manifest.notes[resourceID]?.path, old != relativePath {
            // Renamed or moved on the tablet: drop the stale PDF so the old note stops being refreshed.
            try? fileManager.removeItem(at: config.cacheURL.appendingPathComponent(old))
        }
        manifest.notes[resourceID] = NoteEntry(modified: modified ?? 0, path: relativePath)
    }

    private func safe(_ name: String) -> String {
        ObsidianDestination.safeFileName(name)
    }
}

/// A typed planner to-do, ready for a calendar.
public struct DailyTodo: Equatable {
    public var id: String
    /// `yyyy-MM-dd`
    public var date: String
    public var text: String
    public var isFinished: Bool
    /// 0 important and urgent, 1 urgent, 2 important; anything else has no priority.
    public var level: Int?
    public var modified: Int64

    public init(id: String, date: String, text: String, isFinished: Bool, level: Int?, modified: Int64) {
        self.id = id
        self.date = date
        self.text = text
        self.isFinished = isFinished
        self.level = level
        self.modified = modified
    }

    init(_ item: ViwoodsDailyItem, date: String) {
        self.init(
            id: item.id,
            date: date,
            text: (item.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            isFinished: item.isFinish == 1,
            level: item.level,
            modified: item.lastModifiedTime ?? 0
        )
    }

    public var priority: String? {
        switch level {
        case 0: return "Important and urgent"
        case 1: return "Urgent"
        case 2: return "Important"
        default: return nil
        }
    }

    var fingerprint: String { "\(modified)/\(isFinished)/\(level ?? -1)/\(text.hashValue)" }
}

/// Somewhere planner to-dos go, such as a calendar.
public protocol PlanDestination {
    var id: String { get }
    /// Creates or updates the entry for one to-do. Returns the destination's handle for it.
    func upsert(_ todo: DailyTodo, previous: String?) throws -> String
}

public struct PullReport: Equatable {
    public var checked = 0
    public var updated = 0
    public var unchanged = 0
    public var plansDelivered = 0
    /// Notebooks deleted in the cloud and dropped from the cache.
    public var removed = 0
    public var failures: [String] = []

    public init() {}

    public var summary: String {
        var text = "cloud: \(checked) checked, \(updated) updated, \(unchanged) unchanged"
        if plansDelivered > 0 { text += ", \(plansDelivered) to-dos delivered" }
        if removed > 0 { text += ", \(removed) deleted in the cloud" }
        if !failures.isEmpty { text += ", \(failures.count) failed" }
        return text
    }
}

// MARK: - Manifest

/// What has been pulled, so unchanged notebooks aren't downloaded again. Lives in the cache folder as a hidden file.
struct ViwoodsManifest: Codable, Equatable {
    var notes: [String: NoteEntry] = [:]
    var days: [String: DayEntry] = [:]
    var plans: [String: PlanEntry] = [:]

    static func load(from url: URL) throws -> ViwoodsManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return ViwoodsManifest() }
        return try JSONDecoder().decode(ViwoodsManifest.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct NoteEntry: Codable, Equatable {
    var modified: Int64
    var path: String
}

struct DayEntry: Codable, Equatable {
    var fingerprint: String
}

struct PlanEntry: Codable, Equatable {
    var externalID: String
    var fingerprint: String
}

// MARK: - Config

/// The `viwoodsCloud` section of the config.
public struct ViwoodsCloudConfig: Codable, Equatable {
    /// Doubles as the source id, so destinations file cloud notes under it.
    public var id: String
    public var device: String
    /// Which apps to pull: `paper`, `meeting`, `memo`.
    public var apps: [String]
    /// Pull the Daily planner: handwritten day pages as PDFs, typed to-dos to plan destinations.
    public var daily: Bool
    /// How many months back to look for planner entries, counting this one.
    public var dailyMonths: Int
    /// Where the PDFs are mirrored. Defaults to `~/Library/Application Support/InkRelay/viwoods`.
    public var cachePath: String?
    /// `vision` (default) or `claude`, as for folder sources.
    public var recognizer: RecognizerKind = .vision

    public init(
        id: String = "viwoods-cloud",
        device: String = "Viwoods AiPaper",
        apps: [String] = ["paper", "meeting", "memo"],
        daily: Bool = true,
        dailyMonths: Int = 12,
        cachePath: String? = nil
    ) {
        self.id = id
        self.device = device
        self.apps = apps
        self.daily = daily
        self.dailyMonths = dailyMonths
        self.cachePath = cachePath
    }

    private enum CodingKeys: String, CodingKey { case id, device, apps, daily, dailyMonths, cachePath, recognizer }

    public init(from decoder: Decoder) throws {
        let defaults = ViwoodsCloudConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? defaults.id
        device = try container.decodeIfPresent(String.self, forKey: .device) ?? defaults.device
        apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? defaults.apps
        daily = try container.decodeIfPresent(Bool.self, forKey: .daily) ?? defaults.daily
        dailyMonths = try container.decodeIfPresent(Int.self, forKey: .dailyMonths) ?? defaults.dailyMonths
        cachePath = try container.decodeIfPresent(String.self, forKey: .cachePath)
        recognizer = try container.decodeIfPresent(RecognizerKind.self, forKey: .recognizer) ?? .vision
    }

    public var enabledApps: [ViwoodsApp] {
        apps.compactMap(ViwoodsApp.init(name:))
    }

    public var cacheURL: URL {
        if let cachePath { return URL(fileURLWithPath: PathExpansion.expand(cachePath), isDirectory: true) }
        return InkRelayCore.supportDirectory.appendingPathComponent("viwoods", isDirectory: true)
    }

    var manifestURL: URL { cacheURL.appendingPathComponent(".manifest.json") }

    /// The cache as a source, so the engine treats pulled PDFs like any other export.
    public var source: SourceConfig {
        var source = SourceConfig(id: id, device: device, path: cacheURL.path, fileTypes: ["pdf"], recognizer: recognizer)
        source.waitsForSettle = false
        return source
    }

    func validate() throws {
        guard !id.isEmpty else { throw ConfigError.invalid("viwoodsCloud.id can't be empty.") }
        if let unknown = apps.first(where: { ViwoodsApp(name: $0) == nil }) {
            throw ConfigError.invalid("viwoodsCloud.apps: unknown app \"\(unknown)\". Use paper, meeting or memo.")
        }
        guard dailyMonths >= 1 else { throw ConfigError.invalid("viwoodsCloud.dailyMonths must be at least 1.") }
    }
}
