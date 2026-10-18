import Foundation

/// The day a planner page is for, read from its file name: `2026-10-17`, `20261017`, `2026_10_17`, `2026.10.17`,
/// `17 Oct 2026`, `Oct 17, 2026` or `October 17th 2026`, anywhere in the name ("Planner 2026-10-17", "2026-10-17
/// week 42"). Day-month-year in numbers (`17.10.2026`) is ambiguous with month-day-year, so it's read only when
/// the source names its `dateFormat`.
public enum PlannerDate {
    /// `yyyy-MM-dd`, or nil when the name holds no date.
    public static func parse(fileName: String, format: String? = nil) -> String? {
        if let format, !format.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: fileName.trimmingCharacters(in: .whitespaces)) {
                let parts = formatter.calendar.dateComponents(in: formatter.timeZone, from: date)
                return validated(parts.year, parts.month, parts.day)
            }
            return nil
        }
        let text = fileName as NSString
        let range = NSRange(location: 0, length: text.length)
        for (pattern, order) in patterns {
            guard let match = pattern.firstMatch(in: fileName, range: range) else { continue }
            func group(_ index: Int) -> String { text.substring(with: match.range(at: index)) }
            let values = order.map { group($0.0) }
            let year = Int(values[0]), day = Int(values[2])
            let month = Int(values[1]) ?? monthNumber(values[1])
            if let date = validated(year, month, day) { return date }
        }
        return nil
    }

    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func monthNumber(_ name: String) -> Int? {
        let prefix = String(name.lowercased().prefix(3))
        return monthNames.firstIndex(of: prefix).map { $0 + 1 }
    }

    static let monthPattern = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?"

    /// Each pattern with the capture groups that hold year, month and day, in that order.
    static let patterns: [(NSRegularExpression, [(Int, String)])] = {
        func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
        return [
            (regex(#"(?<!\d)(\d{4})[-_.](\d{1,2})[-_.](\d{1,2})(?!\d)"#), [(1, "y"), (2, "m"), (3, "d")]),
            (regex(#"(?<!\d)(\d{4})(\d{2})(\d{2})(?!\d)"#), [(1, "y"), (2, "m"), (3, "d")]),
            (regex(#"(?<!\d)(\d{1,2})(?:st|nd|rd|th)?\s+"# + monthPattern + #",?\s+(\d{4})(?!\d)"#), [(3, "y"), (2, "m"), (1, "d")]),
            (regex(monthPattern + #"\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)"#), [(3, "y"), (1, "m"), (2, "d")]),
        ]
    }()

    static func validated(_ year: Int?, _ month: Int?, _ day: Int?) -> String? {
        guard let year, let month, let day, (1900...2200).contains(year), (1...12).contains(month), day >= 1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first), days.contains(day) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// Which folders of a source hold day-planner pages, named by date.
public struct PlannerSettings: Codable, Equatable {
    /// Folders inside the source; a page anywhere under one of them is a planner page when its name holds a date.
    public var folders: [String]
    /// A date format such as `dd.MM.yyyy`, for names the usual forms don't cover.
    public var dateFormat: String?

    public init(folders: [String] = ["Daily"], dateFormat: String? = nil) {
        self.folders = folders
        self.dateFormat = dateFormat
    }

    private enum CodingKeys: String, CodingKey { case folders, dateFormat }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent([String].self, forKey: .folders) ?? ["Daily"]
        dateFormat = try container.decodeIfPresent(String.self, forKey: .dateFormat)
    }
}
