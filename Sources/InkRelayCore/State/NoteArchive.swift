import CryptoKit
import Foundation

/// A relayed note as InkRelay keeps it for search: the recognized text page by page, where it came from,
/// and when. Local only, next to the sync state, like everything else InkRelay knows.
public struct ArchivedNote: Codable, Equatable {
    public struct Page: Codable, Equatable {
        public var number: Int
        public var text: String
        public var suggestedTitle: String?
        public var tags: [String]
    }

    /// Short stable id, the same one the review stack and assistants use.
    public var id: String
    /// `<source id>/<relative path>`, as in the sync state.
    public var key: String
    public var title: String
    public var sourceID: String
    public var device: String
    public var relativePath: String
    /// The export or the PDF made from it.
    public var originalPath: String
    public var modified: Date
    public var archivedAt: Date
    public var contentHash: String
    public var pages: [Page]

    public var text: String { pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") }
}

/// One JSON file per note under `archive/`.
public final class NoteArchive {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func id(forKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func url(forKey key: String) -> URL { directory.appendingPathComponent(Self.id(forKey: key) + ".json") }

    public func upsert(_ note: InkNote, key: String, at date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = ArchivedNote(
            id: Self.id(forKey: key), key: key, title: note.title, sourceID: note.sourceID, device: note.device,
            relativePath: note.relativePath, originalPath: note.originalURL.path, modified: note.modified, archivedAt: date,
            contentHash: note.contentHash,
            pages: note.pages.map { ArchivedNote.Page(number: $0.number, text: $0.text, suggestedTitle: $0.suggestedTitle, tags: $0.tags) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: url(forKey: key), options: .atomic)
    }

    public func remove(key: String) {
        try? FileManager.default.removeItem(at: url(forKey: key))
    }

    public func entry(forKey key: String) -> ArchivedNote? {
        Self.decode(url(forKey: key))
    }

    public func note(id: String) -> ArchivedNote? {
        let wanted = id.lowercased()
        if wanted.count == 16 { return Self.decode(directory.appendingPathComponent(wanted + ".json")) }
        let matches = all().filter { $0.id.hasPrefix(wanted) }
        return matches.count == 1 ? matches.first : nil
    }

    /// Every archived note, most recently changed first.
    public func all() -> [ArchivedNote] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(Self.decode).sorted { $0.modified > $1.modified }
    }

    static func decode(_ url: URL) -> ArchivedNote? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ArchivedNote.self, from: data)
    }
}
