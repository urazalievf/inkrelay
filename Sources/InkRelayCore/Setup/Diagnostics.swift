import Foundation

/// A zip to attach to a bug report: what's installed, what `doctor` sees, the config without its secrets,
/// counts from the state, and the tail of the logs. Never tokens, keys, note text or page images.
public enum Diagnostics {
    /// `includeApps` also asks Notes, Calendar and Reminders whether InkRelay may control them; sign-ins are always
    /// checked, since an expired one is the most common reason for a red icon.
    public static func bundle(configURL: URL, supportDirectory: URL, logDirectory: URL, includeApps: Bool = false,
                              secrets: SecretStore = KeychainStore(), now: Date = Date()) -> Data {
        var zip = ZipWriter()
        let loaded = Result { try ConfigStore.load(from: configURL) }
        let config = try? loaded.get()
        let entitlement = EntitlementStore(supportDirectory: supportDirectory).current(now: now)
        var scrubber = Scrubber(home: InkRelayCore.home.path)
        if case .license(let license) = entitlement.basis { scrubber.licensee = license.name }
        func add(_ name: String, _ text: String) { zip.add(name, Data(scrubber.scrub(text).utf8)) }

        var about = [
            "InkRelay \(InkRelayCore.version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Date \(ISO8601DateFormatter().string(from: now))",
            "Plan: \(entitlement.summary(now: now))",
            "Config: \(configURL.path)",
        ]
        if case .failure(let error) = loaded { about.append("The config didn't load: \(error.localizedDescription)") }
        add("about.txt", about.joined(separator: "\n"))

        if let data = try? Data(contentsOf: configURL) {
            add("config.json", redacted(configJSON: data))
        }

        if let config {
            let checks = Doctor(config: config, supportDirectory: supportDirectory, secrets: secrets).checks(includeApps: includeApps, accounts: true)
            let lines = checks.map { "\($0.status.rawValue) \($0.title)" + ($0.detail.isEmpty ? "" : ": \($0.detail)") }
            add("doctor.txt", lines.joined(separator: "\n"))
            add("state.txt", stateSummary(config: config, supportDirectory: supportDirectory))
        }
        let stateURL = supportDirectory.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: LastSync.url(besideState: stateURL)) {
            add("last-sync.json", String(decoding: data, as: UTF8.self))
        }

        for log in logFiles(in: logDirectory) {
            if let text = try? String(contentsOf: log, encoding: .utf8) {
                let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(400).joined(separator: "\n")
                add("logs/" + log.lastPathComponent, tail)
            }
        }
        return zip.finish()
    }

    /// Takes what identifies the person out of free text: the home folder (which carries the macOS username, and
    /// cloud folders that carry an account email), email addresses, and the licensee's name.
    struct Scrubber {
        var home: String
        var licensee: String?

        func scrub(_ text: String) -> String {
            var output = text
            if !home.isEmpty { output = output.replacingOccurrences(of: home, with: "~") }
            if let licensee, licensee.count >= 2 { output = output.replacingOccurrences(of: licensee, with: "<licensee>") }
            // Cloud folders are named after the account (GoogleDrive-name@gmail.com); the provider stays, which helps support.
            let cloud = try! NSRegularExpression(pattern: #"CloudStorage/([A-Za-z]+)-[^/\s]+"#)
            output = cloud.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "CloudStorage/$1-<account>")
            let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
            output = email.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "<email>")
            return output
        }
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

    static let secretKeys = ["secret", "token", "password", "apikey", "api_key", "key", "credential", "address", "account", "email", "sender"]

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
        let readable = StateStore.readable(at: supportDirectory.appendingPathComponent("state.json"))
        guard case .success(let state) = readable else {
            if case .failure(let error) = readable { return "state.json can't be read: \(error.localizedDescription)" }
            return ""
        }
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
