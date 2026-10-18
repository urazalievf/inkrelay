import Foundation

/// A block in a Markdown file that InkRelay owns, between two markers. Everything outside it is the user's.
enum ManagedBlock {
    /// `existing` with the block replaced, or the block appended; a missing file becomes just the block.
    static func replace(in existing: String?, with block: String, start: String, end: String) -> String {
        guard let existing, !existing.isEmpty else { return block + "\n" }
        if let from = existing.range(of: start), let to = existing.range(of: end, range: from.upperBound..<existing.endIndex) {
            return String(existing[..<from.lowerBound]) + block + String(existing[to.upperBound...])
        }
        return existing.trimmingCharacters(in: .newlines) + "\n\n" + block + "\n"
    }
}

/// Obsidian's own daily-notes settings: the folder and the date format (moment.js tokens) from
/// `.obsidian/daily-notes.json`, with Obsidian's defaults when the file or a key is missing.
public struct DailyNotesSettings: Equatable {
    public var folder: String
    public var format: String

    public init(folder: String = "", format: String = "YYYY-MM-DD") {
        self.folder = folder
        self.format = format
    }

    public static func load(vault: URL) -> DailyNotesSettings {
        let url = vault.appendingPathComponent(".obsidian/daily-notes.json")
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DailyNotesSettings()
        }
        var settings = DailyNotesSettings()
        if let folder = object["folder"] as? String { settings.folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        if let format = object["format"] as? String, !format.isEmpty { settings.format = format }
        return settings
    }

    /// Whether the vault has the Daily Notes plugin on. Obsidian writes `daily-notes.json` only once its settings
    /// leave their defaults, so `core-plugins.json` (a list in older vaults, a name-to-bool map in newer ones) is
    /// what says the plugin is enabled.
    public static func isEnabled(vault: URL) -> Bool {
        if FileManager.default.fileExists(atPath: vault.appendingPathComponent(".obsidian/daily-notes.json").path) { return true }
        guard let data = try? Data(contentsOf: vault.appendingPathComponent(".obsidian/core-plugins.json")),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let list = object as? [String] { return list.contains("daily-notes") }
        if let map = object as? [String: Any] { return map["daily-notes"] as? Bool == true }
        return false
    }

    /// Vault-relative path of the daily note for a day, without `.md`.
    public func notePath(for date: Date, calendar: Calendar = .current) -> String {
        let name = MomentFormat.string(from: date, format: format, calendar: calendar)
        return folder.isEmpty ? name : folder + "/" + name
    }
}

/// Enough of moment.js's format tokens for daily-note names. Unknown letters pass through unchanged.
public enum MomentFormat {
    /// moment token → DateFormatter pattern, longest first so `YYYY` isn't read as four `Y`s.
    static let tokens: [(String, String)] = [
        ("YYYY", "yyyy"), ("YY", "yy"), ("GGGG", "YYYY"), ("GG", "YY"),
        ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
        ("DDDD", "DDD"), ("DDD", "D"), ("DD", "dd"), ("Do", "d"), ("D", "d"),
        ("dddd", "EEEE"), ("ddd", "EEE"), ("dd", "EEEEEE"), ("d", "e"),
        ("WW", "ww"), ("W", "w"), ("ww", "ww"), ("w", "w"),
        ("HH", "HH"), ("H", "H"), ("hh", "hh"), ("h", "h"), ("mm", "mm"), ("m", "m"), ("ss", "ss"), ("s", "s"), ("A", "a"), ("a", "a"),
        ("Q", "Q"), ("X", "X"),
    ]

    public static func pattern(_ moment: String) -> String {
        var output = ""
        var index = moment.startIndex
        while index < moment.endIndex {
            if moment[index] == "[" {
                // [literal text]
                if let close = moment[index...].firstIndex(of: "]") {
                    let literal = String(moment[moment.index(after: index)..<close])
                    output += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
                    index = moment.index(after: close)
                    continue
                }
            }
            if let (token, replacement) = tokens.first(where: { moment[index...].hasPrefix($0.0) }) {
                output += replacement
                index = moment.index(index, offsetBy: token.count)
                continue
            }
            let character = moment[index]
            output += character.isLetter ? "'" + String(character) + "'" : String(character)
            index = moment.index(after: index)
        }
        return output
    }

    public static func string(from date: Date, format: String, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern(format)
        return formatter.string(from: date)
    }
}

/// What the archive knows about a day or a week, shaped for a Markdown block.
struct InkDigest {
    struct Entry {
        var note: ArchivedNote
        /// Vault-relative link target, without `.md`.
        var link: String
        var isPlanner: Bool
        var plannerDate: String?
    }

    let folder: String
    let calendar: Calendar

    init(folder: String, calendar: Calendar = .current) {
        self.folder = folder
        self.calendar = calendar
    }

    func entry(for note: ArchivedNote) -> Entry {
        let directory = (note.relativePath as NSString).deletingLastPathComponent
        let parts = [folder, note.sourceID] + directory.split(separator: "/").map(String.init)
        let link = (parts.filter { !$0.isEmpty }.map(ObsidianDestination.safeFileName) + [ObsidianDestination.safeFileName(note.title)]).joined(separator: "/")
        let plannerDate = note.relativePath.split(separator: "/").dropLast().last == "Daily" ? ViwoodsDate.normalize(note.title) : nil
        return Entry(note: note, link: link, isPlanner: plannerDate != nil, plannerDate: plannerDate)
    }

    /// The day a note belongs to: its planner date, or the day it was written.
    func day(of entry: Entry) -> Date {
        if let plannerDate = entry.plannerDate, let date = ViwoodsDate.date(from: plannerDate, calendar: calendar) { return date }
        return calendar.startOfDay(for: entry.note.modified)
    }

    static let dailyStart = "%% inkrelay:daily:start — written by InkRelay from your tablet; edits inside are replaced %%"
    static let dailyEnd = "%% inkrelay:daily:end %%"
    static let weeklyStart = "%% inkrelay:weekly:start — written by InkRelay from your tablet; edits inside are replaced %%"
    static let weeklyEnd = "%% inkrelay:weekly:end %%"

    /// The block for one day: the planner page, the notes written that day, and their open tasks.
    func dailyBlock(for day: Date, notes: [ArchivedNote]) -> String? {
        let entries = notes.map(entry(for:)).filter { calendar.isDate(self.day(of: $0), inSameDayAs: day) }
        guard !entries.isEmpty else { return nil }
        var lines = [Self.dailyStart, "## From your tablet", ""]
        for planner in entries.filter(\.isPlanner) {
            lines.append("**Planner:** [[\(planner.link)|\(planner.note.title)]]")
            let text = planner.note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append("")
                lines += text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "> " + $0 }
            }
            lines.append("")
        }
        let written = entries.filter { !$0.isPlanner }
        if !written.isEmpty {
            lines.append("**Written today**")
            for item in written {
                lines.append("- [[\(item.link)|\(item.note.title)]] (\(pageWord(item.note.pages.count)))")
            }
            lines.append("")
        }
        let tasks = entries.flatMap { item in
            TaskExtractor.tasks(in: item.note.text, itemKey: item.note.key, plannerDate: item.plannerDate).filter { !$0.isDone }
                .map { "- [ ] \($0.text) ([[\(item.link)|\(item.note.title)]])" }
        }
        if !tasks.isEmpty {
            lines.append("**Open tasks**")
            lines += tasks
            lines.append("")
        }
        lines.append(Self.dailyEnd)
        return lines.joined(separator: "\n")
    }

    /// The block for one ISO week: what was written, the planner days, and every open task.
    func weeklyBlock(for week: DateInterval, notes: [ArchivedNote]) -> String? {
        // DateInterval.contains takes the end as inside; the next Monday's midnight belongs to the next week.
        let entries = notes.map(entry(for:)).filter { let d = day(of: $0); return d >= week.start && d < week.end }.sorted { day(of: $0) < day(of: $1) }
        guard !entries.isEmpty else { return nil }
        let written = entries.filter { !$0.isPlanner }
        let planners = entries.filter(\.isPlanner)
        let pages = entries.reduce(0) { $0 + $1.note.pages.count }
        let tasks = entries.flatMap { item in
            TaskExtractor.tasks(in: item.note.text, itemKey: item.note.key, plannerDate: item.plannerDate).filter { !$0.isDone }
                .map { "- [ ] \($0.text) ([[\(item.link)|\(item.note.title)]])" }
        }
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "EEE MMM d"

        var lines = [Self.weeklyStart]
        lines.append("**\(pageWord(pages)) across \(noteWord(entries.count))**, \(planners.count) planner day\(planners.count == 1 ? "" : "s"), \(tasks.count) open task\(tasks.count == 1 ? "" : "s").")
        lines.append("")
        if !written.isEmpty {
            lines.append("## Notes")
            for item in written {
                lines.append("- \(dayFormatter.string(from: day(of: item))): [[\(item.link)|\(item.note.title)]] (\(pageWord(item.note.pages.count)))")
            }
            lines.append("")
        }
        if !planners.isEmpty {
            lines.append("## Planner")
            for item in planners {
                let first = item.note.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
                lines.append("- \(dayFormatter.string(from: day(of: item))): [[\(item.link)|\(item.note.title)]]" + (first.isEmpty ? "" : " — \(first.prefix(80))"))
            }
            lines.append("")
        }
        if !tasks.isEmpty {
            lines.append("## Open tasks")
            lines += tasks
            lines.append("")
        }
        lines.append(Self.weeklyEnd)
        return lines.joined(separator: "\n")
    }

    /// `2026-W42`, ISO week numbering, Monday first.
    func weekName(for date: Date) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let components = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
    }

    func week(containing date: Date) -> DateInterval {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        return iso.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    }

    private func pageWord(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }
    private func noteWord(_ count: Int) -> String { count == 1 ? "1 note" : "\(count) notes" }
}

extension ViwoodsDate {
    /// Midnight of a `yyyy-MM-dd` planner date in the given calendar.
    static func date(from normalized: String, calendar: Calendar) -> Date? {
        let parts = normalized.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
