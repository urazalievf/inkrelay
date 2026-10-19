import Foundation

/// How close recognized text is to what was written, counted in words: substitutions, deletions and insertions
/// (the word-level edit distance) against the number of words written. Words are compared without case, accents
/// or punctuation, so "Call Mom." and "call mom" agree; line breaks don't count.
public struct WordScore: Equatable {
    public var words: Int
    public var errors: Int

    public init(words: Int = 0, errors: Int = 0) {
        self.words = words
        self.errors = errors
    }

    /// 1 − errors / words, never below 0. A page with nothing written scores 1 when nothing was read.
    public var accuracy: Double {
        guard words > 0 else { return errors == 0 ? 1 : 0 }
        return max(0, 1 - Double(errors) / Double(words))
    }

    public static func + (a: WordScore, b: WordScore) -> WordScore {
        WordScore(words: a.words + b.words, errors: a.errors + b.errors)
    }

    public static func score(recognized: String, truth: String) -> WordScore {
        let read = words(in: recognized), written = words(in: truth)
        return WordScore(words: written.count, errors: distance(read, written))
    }

    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// Levenshtein distance over words, one row at a time.
    static func distance(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// A fixed set of real pages and what was really written on them, kept beside the config so recognition can be
/// measured before and after a change (`inkrelay measure`). One text file per page, named after the export:
/// `measure/<source id>/<path of the export>.p<page>.txt`, e.g. `measure/viwoods/Daily/2025-11-10.pdf.p1.txt`.
/// The files hold the person's own handwriting, so they never leave the Mac and never go in a repository.
public struct MeasureSet {
    public struct Page: Equatable {
        public var sourceID: String
        public var relativePath: String
        public var number: Int
        public var truthURL: URL
    }

    /// A run's totals, one line each in `history.tsv`.
    public struct Run: Equatable {
        public var date: Date
        public var version: String
        public var pages: Int
        public var score: WordScore

        public init(date: Date, version: String, pages: Int, score: WordScore) {
            self.date = date
            self.version = version
            self.pages = pages
            self.score = score
        }
    }

    /// Starts every page file `add` writes. A file that still starts with it was never corrected, so measuring
    /// leaves it out rather than scoring the recognizer against its own reading.
    public static let draftMarker = "[InkRelay draft: correct the text below to what the page really says, then delete this line]"

    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public init(supportDirectory: URL) {
        self.init(directory: supportDirectory.appendingPathComponent("measure", isDirectory: true))
    }

    public func truthURL(sourceID: String, relativePath: String, page: Int) -> URL {
        directory.appendingPathComponent(sourceID, isDirectory: true).appendingPathComponent("\(relativePath).p\(page).txt")
    }

    /// Every page file in the set, sorted by source, export and page.
    public func pages() -> [Page] {
        guard let walker = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let base = directory.resolvingSymlinksInPath().path + "/"
        var found: [Page] = []
        for case let url as URL in walker where url.pathExtension == "txt" {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { continue }
            let parts = path.dropFirst(base.count).split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let match = parts[1].firstMatch(of: #/^(.+)\.p([0-9]+)\.txt$/#), let number = Int(match.2) else { continue }
            let relativePath = String(match.1)
            found.append(Page(sourceID: parts[0], relativePath: relativePath, number: number,
                              truthURL: truthURL(sourceID: parts[0], relativePath: relativePath, page: number)))
        }
        return found.sorted { ($0.sourceID, $0.relativePath, $0.number) < ($1.sourceID, $1.relativePath, $1.number) }
    }

    /// What was written on the page, or nil while the file is still a draft.
    public func truth(of page: Page) throws -> String? {
        let text = try String(contentsOf: page.truthURL, encoding: .utf8)
        return text.hasPrefix(Self.draftMarker) ? nil : text
    }

    /// Writes a draft from what InkRelay reads now; false when the page already has a file, which is never replaced.
    @discardableResult
    public func addDraft(sourceID: String, relativePath: String, page: Int, reading: String) throws -> Bool {
        let url = truthURL(sourceID: sourceID, relativePath: relativePath, page: page)
        guard !fileManager.fileExists(atPath: url.path) else { return false }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((Self.draftMarker + "\n" + reading + "\n").utf8).write(to: url, options: .atomic)
        return true
    }

    private var historyURL: URL { directory.appendingPathComponent("history.tsv") }

    /// Earlier runs, oldest first.
    public func history() -> [Run] {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count >= 5, let date = ISO8601DateFormatter().date(from: fields[0]),
                  let pages = Int(fields[2]), let words = Int(fields[3]), let errors = Int(fields[4]) else { return nil }
            return Run(date: date, version: fields[1], pages: pages, score: WordScore(words: words, errors: errors))
        }
    }

    public func record(_ run: Run) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var text = (try? String(contentsOf: historyURL, encoding: .utf8)) ?? "date\tversion\tpages\twords\terrors\taccuracy\n"
        if !text.hasSuffix("\n") { text += "\n" }
        text += [ISO8601DateFormatter().string(from: run.date), run.version, String(run.pages), String(run.score.words),
                 String(run.score.errors), String(format: "%.4f", run.score.accuracy)].joined(separator: "\t") + "\n"
        try Data(text.utf8).write(to: historyURL, options: .atomic)
    }
}
