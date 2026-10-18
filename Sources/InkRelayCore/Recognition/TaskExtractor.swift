import CryptoKit
import Foundation

/// A to-do written on a page: a checkbox line, or a line starting with TODO.
public struct ExtractedTask: Equatable {
    public var text: String
    public var isDone: Bool
    /// A date written in the task, such as "by Friday" or "March 3 at 3pm".
    public var due: Date?
    public var dueHasTime: Bool
    /// Stable across re-syncs and across ticking the box: the note plus the task's own words.
    public var key: String
}

/// A line that names a date and a time and isn't a task, such as "Dentist March 3 at 3pm".
/// Offered in the review stack; a calendar event is only made when the user accepts it.
public struct SuggestedEvent: Codable, Equatable {
    public var title: String
    public var notes: String
    public var start: Date
    public var end: Date

    public init(title: String, notes: String, start: Date, end: Date) {
        self.title = title
        self.notes = notes
        self.start = start
        self.end = end
    }
}

/// Finds tasks and dated lines in recognized text.
public enum TaskExtractor {
    static let openMarks = ["☐", "□", "○", "[ ]", "[]", "- [ ]", "* [ ]"]
    static let doneMarks = ["☑", "☒", "✓", "✔", "✅", "[x]", "[X]", "- [x]", "- [X]", "* [x]"]
    static let todoWords = ["todo:", "todo", "to do:", "to-do:"]
    static let doneWords = ["done:"]

    public static func tasks(in text: String, itemKey: String, plannerDate: String? = nil) -> [ExtractedTask] {
        text.split(separator: "\n").compactMap { raw -> ExtractedTask? in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard let (body, done) = strip(line), !body.isEmpty else { return nil }
            let (due, hasTime) = date(in: body, plannerDate: plannerDate)
            return ExtractedTask(text: body, isDone: done, due: due, dueHasTime: hasTime, key: key(itemKey, body))
        }
    }

    public static func events(in text: String, title: String, plannerDate: String? = nil) -> [SuggestedEvent] {
        text.split(separator: "\n").compactMap { raw -> SuggestedEvent? in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard strip(line) == nil, line.count >= 4 else { return nil }
            let (start, hasTime) = date(in: line, plannerDate: plannerDate)
            guard let start, hasTime else { return nil }
            let cleaned = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            return SuggestedEvent(title: cleaned, notes: "From \"\(title)\". Suggested by InkRelay.", start: start, end: start.addingTimeInterval(3600))
        }
    }

    /// The task's words without its checkbox or TODO marker, and whether it's ticked. Nil for other lines.
    static func strip(_ line: String) -> (String, Bool)? {
        for mark in doneMarks where line.hasPrefix(mark) { return (clean(line.dropFirst(mark.count)), true) }
        for mark in openMarks where line.hasPrefix(mark) { return (clean(line.dropFirst(mark.count)), false) }
        let lower = line.lowercased()
        for word in doneWords where lower.hasPrefix(word) { return (clean(line.dropFirst(word.count)), true) }
        for word in todoWords where lower.hasPrefix(word) {
            let rest = line.dropFirst(word.count)
            // "Todo" must be its own word: "Today" isn't a task.
            if word == "todo", let next = rest.first, next.isLetter { continue }
            return (clean(rest), false)
        }
        return nil
    }

    static func clean<S: StringProtocol>(_ text: S) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-–")))
    }

    /// The Obsidian block id for a task line: `ink-<key>`, with `-2`, `-3` for a repeat within the same note, in the
    /// order the lines appear. The same text in the same note always gets the same id, ticked or not.
    public static func blockID(for key: String, seen: inout [String: Int]) -> String {
        let count = (seen[key] ?? 0) + 1
        seen[key] = count
        return "ink-" + key + (count > 1 ? "-\(count)" : "")
    }

    /// Each task in `text` with its block id, in order, as the note in Obsidian has them.
    public static func tasksWithBlockIDs(in text: String, itemKey: String, plannerDate: String? = nil) -> [(task: ExtractedTask, blockID: String)] {
        var seen: [String: Int] = [:]
        return tasks(in: text, itemKey: itemKey, plannerDate: plannerDate).map { ($0, blockID(for: $0.key, seen: &seen)) }
    }

    static func key(_ itemKey: String, _ text: String) -> String {
        let normalized = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data("\(itemKey)|\(normalized)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static let timePattern = #"(?i)\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\b\d{1,2}:\d{2}\b|\bnoon\b|\bmidnight\b"#
    static let datePattern = #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d|\b\d{1,2}[/.-]\d{1,2}|\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\b|\b(today|tomorrow|tonight)\b|\b\d{4}-\d{2}-\d{2}\b"#

    /// The first date in `text` and whether it includes a time. On a planner page a bare time ("3pm")
    /// belongs to the page's day rather than to today.
    static func date(in text: String, plannerDate: String?) -> (Date?, Bool) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let found = match.date,
              let range = Range(match.range, in: text) else { return (nil, false) }
        let phrase = String(text[range])
        let hasTime = phrase.range(of: timePattern, options: .regularExpression) != nil
        let hasDate = phrase.range(of: datePattern, options: .regularExpression) != nil
        if let plannerDate, !hasDate, let day = PlannerEvent.dayFormatter.date(from: plannerDate) {
            var calendar = Calendar.current
            calendar.timeZone = .current
            let time = calendar.dateComponents([.hour, .minute], from: found)
            var components = PlannerEvent.utcCalendar.dateComponents([.year, .month, .day], from: day)
            components.hour = hasTime ? time.hour : 9
            components.minute = hasTime ? time.minute : 0
            return (calendar.date(from: components), hasTime)
        }
        return (found, hasTime)
    }
}
