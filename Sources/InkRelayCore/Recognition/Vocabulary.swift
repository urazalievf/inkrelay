import Foundation

/// Words InkRelay learned from corrections people made in Obsidian, kept in `vocabulary.json` beside the
/// config and handed to Vision with the config's own `recognition.vocabulary`. A class, so a pass that learns
/// a word reads the next page with it.
public final class LearnedVocabulary {
    public static let limit = 500

    public let url: URL
    private let lock = NSLock()
    private var words: [String] = []
    private var loadedModification: Date?

    public init(url: URL) {
        self.url = url
        reload()
    }

    /// Other processes (`inkrelay vocabulary add`, the app, the agent) write the same file, so every read and
    /// every change starts from what's on disk.
    private func reload() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        guard modified != loadedModification || words.isEmpty else { return }
        words = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
        loadedModification = modified
    }

    public var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        reload()
        return words
    }

    /// Adds what isn't there yet, newest last, dropping the oldest beyond the limit. Returns what was new.
    @discardableResult
    public func add(_ candidates: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        reload()
        let known = Set(words.map { $0.lowercased() })
        var added: [String] = []
        for word in candidates where !known.contains(word.lowercased()) && !added.contains(where: { $0.lowercased() == word.lowercased() }) {
            added.append(word)
        }
        guard !added.isEmpty else { return [] }
        words += added
        if words.count > Self.limit { words.removeFirst(words.count - Self.limit) }
        save()
        return added
    }

    public func remove(_ word: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        reload()
        let before = words.count
        words.removeAll { $0.lowercased() == word.lowercased() }
        if words.count != before { save() }
        return words.count != before
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(words).write(to: url, options: .atomic)
        loadedModification = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
    }
}

/// Finds the words a person typed into InkRelay's block of a note that weren't in what InkRelay wrote:
/// a correction of a misread word, a name, a product. Conservative: words only, three letters or more,
/// at most a handful per note.
public enum VocabularyLearner {
    public static let perNoteLimit = 12

    public static func newWords(edited: String, original: String, known: [String] = []) -> [String] {
        let edited = stripFurniture(edited)
        let before = Set(words(in: original).map { $0.lowercased() })
        let knownSet = Set(known.map { $0.lowercased() })
        var seen = Set<String>()
        var result: [String] = []
        for word in words(in: edited) {
            let key = word.lowercased()
            guard !before.contains(key), !knownSet.contains(key), !seen.contains(key) else { continue }
            // Markdown furniture and InkRelay's own words are never corrections.
            guard !["page", "illegible", "inkrelay"].contains(key) else { continue }
            seen.insert(key)
            result.append(word)
            if result.count == perNoteLimit { break }
        }
        return result
    }

    /// Headings, embeds and InkRelay's own lines, which aren't the person's words.
    static func stripFurniture(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("#") || trimmed.hasPrefix("![[") || trimmed.hasPrefix("%%") || trimmed.hasPrefix("_No text"))
            }
            .joined(separator: "\n")
    }

    /// Runs of letters, with inner apostrophes and hyphens, three characters or longer.
    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
            if trimmed.count >= 3, trimmed.contains(where: \.isLetter), !trimmed.contains(where: \.isNumber) { result.append(trimmed) }
            current = ""
        }
        for character in text {
            if character.isLetter || ((character == "'" || character == "-") && !current.isEmpty) {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// The text between InkRelay's markers in a note, or nil when the note has none.
    public static func managedText(of markdown: String) -> String? {
        guard let start = markdown.range(of: MarkdownRenderer.startMarker),
              let end = markdown.range(of: MarkdownRenderer.endMarker, range: start.upperBound..<markdown.endIndex) else { return nil }
        return String(markdown[start.upperBound..<end.lowerBound])
    }
}
