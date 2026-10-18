import Foundation

/// A zip to attach to a bug report: what's installed, what `doctor` sees, the config without its secrets,
/// counts from the state, and the tail of the logs. Never tokens, keys, note text or page images.
public enum Diagnostics {
    public static func bundle(configURL: URL, supportDirectory: URL, logDirectory: URL, now: Date = Date()) -> Data {
        var zip = ZipWriter()
        let config = try? ConfigStore.load(from: configURL)

        var about = [
            "InkRelay \(InkRelayCore.version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Date \(ISO8601DateFormatter().string(from: now))",
            "Plan: \(EntitlementStore(supportDirectory: supportDirectory).current(now: now).summary(now: now))",
            "Config: \(configURL.path)",
        ]
        if config == nil { about.append("The config didn't load; see config.json in this bundle.") }
        zip.add("about.txt", Data(about.joined(separator: "\n").utf8))

        if let data = try? Data(contentsOf: configURL) {
            zip.add("config.json", Data(redacted(configJSON: data).utf8))
        }

        if let config {
            let checks = Doctor(config: config, supportDirectory: supportDirectory).checks(includeApps: false, accounts: false)
            let lines = checks.map { "\($0.status.rawValue) \($0.title)" + ($0.detail.isEmpty ? "" : ": \($0.detail)") }
            zip.add("doctor.txt", Data(lines.joined(separator: "\n").utf8))
            zip.add("state.txt", Data(stateSummary(config: config, supportDirectory: supportDirectory).utf8))
        }

        for log in logFiles(in: logDirectory) {
            if let text = try? String(contentsOf: log, encoding: .utf8) {
                let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(400).joined(separator: "\n")
                zip.add("logs/" + log.lastPathComponent, Data(tail.utf8))
            }
        }
        return zip.finish()
    }

    /// `~/Desktop/InkRelay-diagnostics-2026-10-17.zip`
    public static func suggestedName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "InkRelay-diagnostics-\(formatter.string(from: now)).zip"
    }

    /// The config with every secret-looking value replaced, structure intact.
    public static func redacted(configJSON data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "(not valid JSON)" }
        let cleaned = redact(object)
        guard let output = try? JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys]) else { return "(couldn't re-encode)" }
        return String(decoding: output, as: UTF8.self)
    }

    static let secretKeys = ["secret", "token", "password", "apikey", "api_key", "key", "credential"]

    private static func redact(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, inner) in dictionary {
                let lower = key.lowercased()
                if secretKeys.contains(where: { lower.contains($0) }), inner is String {
                    out[key] = "<redacted>"
                } else {
                    out[key] = redact(inner)
                }
            }
            return out
        }
        if let array = value as? [Any] { return array.map(redact) }
        return value
    }

    static func stateSummary(config: RelayConfig, supportDirectory: URL) -> String {
        let state = (try? StateStore(url: supportDirectory.appendingPathComponent("state.json")))?.state ?? SyncState()
        var lines: [String] = ["Tracked exports: \(state.files.count)"]
        for source in config.allSources {
            let records = state.files.filter { $0.key.hasPrefix(source.id + "/") }.map(\.value)
            let blank = records.filter { $0.blank == true }.count
            let missing = records.filter { $0.missingSince != nil }.count
            lines.append("Source \(source.id): \(records.count) tracked, \(blank) blank, \(missing) missing")
        }
        for destination in config.destinations {
            let upToDate = state.files.values.filter { $0.destinations[destination.id]?.contentHash == $0.contentHash }.count
            let behind = state.files.values.filter { $0.blank != true && $0.destinations[destination.id]?.contentHash != $0.contentHash }.count
            lines.append("Destination \(destination.id) (\(destination.kind)): \(upToDate) up to date, \(behind) behind")
        }
        if let cards = try? ReviewStore(directory: supportDirectory.appendingPathComponent("review")).load().cards {
            lines.append("Review cards: \(cards.count), \(cards.values.filter { $0.status != .done }.count) in play")
        }
        return lines.joined(separator: "\n")
    }

    static func logFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".log") }.sorted().map { directory.appendingPathComponent($0) }
    }
}
