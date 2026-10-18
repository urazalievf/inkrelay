import Foundation

/// One block per sync pass in a plain-text log, the same lines `inkrelay watch` prints: when, why, the summary,
/// then each warning and failure. The menu bar app writes it so people who never touch the terminal still have
/// a history to look at and to attach to a bug report.
public struct SyncLog {
    public static var defaultURL: URL {
        InkRelayCore.home.appendingPathComponent("Library/Logs/InkRelay/inkrelay.log")
    }

    public let url: URL

    public init(url: URL = SyncLog.defaultURL) {
        self.url = url
    }

    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate, .withSpaceBetweenDateAndTime])
    }

    /// The pass's lines, as `printReport` writes them.
    public static func lines(reason: String, report: SyncReport, at date: Date) -> [String] {
        let time = "[\(timestamp(date))]"
        var lines = ["\(time) Synced (\(reason)): \(report.summary)"]
        for warning in report.warnings { lines.append("\(time)   ! \(warning)") }
        for failure in report.failures {
            let destination = failure.destinationID.map { " → \($0)" } ?? ""
            lines.append("\(time)   ✗ \(failure.item)\(destination): \(failure.message)")
        }
        return lines
    }

    public func append(reason: String, report: SyncReport, at date: Date = Date()) {
        append(Self.lines(reason: reason, report: report, at: date))
    }

    public func append(_ lines: [String]) {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        LogTrimmer.trim(url)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// The last pass's outcome, beside the sync state, for `inkrelay status`, the MCP server and diagnostics: every
/// process that syncs writes it, so it's the same answer whoever ran the pass.
public struct LastSync: Codable, Equatable {
    public var at: Date
    public var summary: String
    public var scanned: Int
    public var synced: Int
    public var failed: Int
    public var failures: [String]
    public var warnings: [String]
    public var learnedWords: Int

    public init(report: SyncReport, at date: Date) {
        at = date
        summary = report.summary
        scanned = report.scanned
        synced = report.synced
        failed = report.failures.count
        failures = report.failures.map { failure in failure.item + (failure.destinationID.map { " → \($0)" } ?? "") + ": " + failure.message }
        warnings = report.warnings
        // The words themselves are the person's vocabulary; only how many is kept.
        learnedWords = report.learned.count
    }

    public static func url(besideState stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("last-sync.json")
    }

    public func save(besideState stateURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.url(besideState: stateURL), options: .atomic)
    }

    public static func load(besideState stateURL: URL) -> LastSync? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(besideState: stateURL))).flatMap { try? decoder.decode(LastSync.self, from: $0) }
    }
}

extension StateStore {
    /// The state, or why it can't be read, for places that report on it rather than sync.
    public static func readable(at url: URL) -> Result<SyncState, Error> {
        Result { try StateStore(url: url).state }
    }
}
