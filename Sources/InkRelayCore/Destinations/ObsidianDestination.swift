import Foundation

/// Writes one Markdown file per export into an Obsidian vault, mirroring the source's folder structure:
/// `<vault>/<folder>/<source id>/<relative dir>/<title>.md`, with the original PDF beside it.
///
/// Only InkRelay's block and frontmatter keys are rewritten when the export changes; the rest of the file is the user's.
public struct ObsidianDestination: NoteDestination {
    public var config: DestinationConfig.ObsidianConfig
    private let fileManager: FileManager

    public init(config: DestinationConfig.ObsidianConfig, fileManager: FileManager = .default) {
        self.config = config
        self.fileManager = fileManager
    }

    public var id: String { config.id }

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        let vault = config.vaultURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: vault.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DestinationError.unavailable(id, "no Obsidian vault at \(vault.path)")
        }

        let directory = Self.vaultRelativeDirectory(for: note, folder: config.folder)
        let baseName = Self.safeFileName(note.title)
        let notePath = Self.join(directory, baseName + ".md")
        let originalPath = config.copyOriginal
            ? Self.join(directory, baseName + "." + note.originalURL.pathExtension.lowercased())
            : nil

        try fileManager.createDirectory(at: vault.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
        if let originalPath {
            let target = vault.appendingPathComponent(originalPath)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: note.originalURL, to: target)
        }

        // Keep whatever the user wrote: from this file, or from the old one after a rename.
        let target = vault.appendingPathComponent(notePath)
        let existing = (try? String(contentsOf: target, encoding: .utf8))
            ?? previous.flatMap { try? String(contentsOf: vault.appendingPathComponent($0.externalID), encoding: .utf8) }
        let markdown = MarkdownRenderer.render(note, embedPath: originalPath, tags: config.tags, merging: existing)
        try Data(markdown.utf8).write(to: target, options: .atomic)
        if let old = previous?.externalID, !old.isEmpty, old != notePath {
            // Renamed or moved at the source: the note moves with it.
            for file in companions(of: old, in: vault) where file.path != vault.appendingPathComponent(notePath).path {
                try? fileManager.removeItem(at: file)
            }
        }
        return notePath
    }

    /// Archive moves the note and its PDF under `<folder>/Archive/`; delete sends them to the Trash.
    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        let vault = config.vaultURL
        let files = companions(of: record.externalID, in: vault)
        switch policy {
        case .keep:
            return
        case .delete:
            for file in files { try fileManager.trashItem(at: file, resultingItemURL: nil) }
        case .archive:
            let relative = record.externalID.hasPrefix(config.folder + "/") ? String(record.externalID.dropFirst(config.folder.count + 1)) : record.externalID
            let archiveDirectory = vault.appendingPathComponent(config.folder).appendingPathComponent("Archive")
                .appendingPathComponent((relative as NSString).deletingLastPathComponent, isDirectory: true)
            try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            for file in files {
                let target = archiveDirectory.appendingPathComponent(file.lastPathComponent)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.moveItem(at: file, to: target)
            }
        }
    }

    /// The note at `notePath` and the copied original beside it (same name, any extension).
    func companions(of notePath: String, in vault: URL) -> [URL] {
        let note = vault.appendingPathComponent(notePath)
        let base = note.deletingPathExtension().lastPathComponent
        let directory = note.deletingLastPathComponent()
        let siblings = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return siblings.filter { $0.deletingPathExtension().lastPathComponent == base }.sorted { $0.path < $1.path }
    }

    static func vaultRelativeDirectory(for note: InkNote, folder: String) -> String {
        let relativeDirectory = (note.relativePath as NSString).deletingLastPathComponent
        let parts = [folder, note.sourceID] + relativeDirectory.split(separator: "/").map(String.init)
        return parts.filter { !$0.isEmpty }.map(safeFileName).joined(separator: "/")
    }

    /// Replaces characters Obsidian rejects in file names or that break wiki links.
    static func safeFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "[]#^|\\/:*?\"<>")
        let cleaned = name.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private static func join(_ directory: String, _ file: String) -> String {
        directory.isEmpty ? file : directory + "/" + file
    }
}

/// Writes the Markdown for a note. InkRelay owns only the part between the markers and a handful of
/// frontmatter keys; everything else in the file is the user's and survives every re-sync.
public enum MarkdownRenderer {
    public static let startMarker = "%% inkrelay:start — written by InkRelay; edits between these markers are replaced on the next sync %%"
    public static let endMarker = "%% inkrelay:end %%"
    /// Frontmatter keys InkRelay rewrites. `tags` is written once, then belongs to the user.
    static let managedKeys = ["source", "device", "original", "pages", "modified", "synced", "suggested_title", "suggested_tags"]

    public static func render(_ note: InkNote, embedPath: String?, tags: [String], syncedAt: Date = Date(), merging existing: String? = nil) -> String {
        var managed: [(String, String)] = [
            ("source", yamlString(note.sourceID)),
            ("device", yamlString(note.device)),
            ("original", yamlString(note.relativePath)),
            ("pages", String(note.pages.count)),
            ("modified", NoteFormatting.timestamp.string(from: note.modified)),
            ("synced", NoteFormatting.timestamp.string(from: syncedAt)),
        ]
        // AI transcription suggests a title and topic tags; they're InkRelay's, so they update with the note.
        if let suggested = note.pages.compactMap(\.suggestedTitle).first { managed.append(("suggested_title", yamlString(suggested))) }
        let suggestedTags = Array(Set(note.pages.flatMap(\.tags))).sorted()
        if !suggestedTags.isEmpty { managed.append(("suggested_tags", "[\(suggestedTags.map(yamlString).joined(separator: ", "))]")) }
        let tagsValue = tags.isEmpty ? nil : "[\(tags.map(yamlString).joined(separator: ", "))]"
        let block = generatedBlock(note, embedPath: embedPath)

        guard let existing, !existing.isEmpty else {
            if let tagsValue { managed.append(("tags", tagsValue)) }
            return frontmatter(managed.map { "\($0.0): \($0.1)" }) + "\n" + block + "\n"
        }

        let (existingFrontmatter, body) = splitFrontmatter(existing)
        var lines = mergeFrontmatter(existingFrontmatter, managed: managed)
        if let tagsValue, !(existingFrontmatter ?? []).contains(where: { key(of: $0) == "tags" }) {
            lines.append("tags: \(tagsValue)")
        }

        let before: String
        let after: String
        if let start = body.range(of: startMarker), let end = body.range(of: endMarker, range: start.upperBound..<body.endIndex) {
            before = String(body[..<start.lowerBound])
            after = String(body[end.upperBound...])
        } else if existingFrontmatter?.contains(where: { key(of: $0) == "source" }) == true {
            // Written by InkRelay before 0.4.0, without markers: the whole body was generated.
            before = "\n"
            after = "\n"
        } else {
            // Somebody else's note with the same name: keep all of it, below the generated part.
            before = "\n"
            after = "\n\n" + body.trimmingCharacters(in: .newlines) + "\n"
        }
        return frontmatter(lines) + (before.isEmpty ? "\n" : before) + block + (after.isEmpty ? "\n" : after)
    }

    static func generatedBlock(_ note: InkNote, embedPath: String?) -> String {
        var lines = [startMarker, "# \(note.title)", ""]
        if let embedPath {
            lines += ["![[\(embedPath)]]", ""]
        }
        if !NoteFormatting.hasText(note) {
            lines += ["_No text recognized._", ""]
        }
        for page in note.pages {
            lines += ["## Page \(page.number)", ""]
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lines += [text.isEmpty ? "_No text recognized on this page._" : text, ""]
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    static func frontmatter(_ lines: [String]) -> String {
        "---\n" + lines.joined(separator: "\n") + "\n---\n"
    }

    /// The frontmatter's lines (nil when there is none) and the rest of the file.
    static func splitFrontmatter(_ text: String) -> ([String]?, String) {
        guard text.hasPrefix("---\n") else { return (nil, text) }
        let rest = text.dropFirst(4)
        guard let close = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else {
            return (nil, text)
        }
        let lines = rest[..<close.lowerBound].components(separatedBy: "\n")
        return (lines, String(rest[close.upperBound...]))
    }

    /// Replaces InkRelay's keys in place and keeps every other key, with its indented or list lines, as written.
    static func mergeFrontmatter(_ existing: [String]?, managed: [(String, String)]) -> [String] {
        var values = Dictionary(uniqueKeysWithValues: managed)
        var output: [String] = []
        var skippingContinuation = false
        for line in existing ?? [] {
            if let key = key(of: line) {
                skippingContinuation = false
                if let value = values.removeValue(forKey: key) {
                    output.append("\(key): \(value)")
                    skippingContinuation = true
                    continue
                }
                output.append(line)
            } else if !skippingContinuation {
                output.append(line)
            }
        }
        for (key, _) in managed where values[key] != nil {
            output.append("\(key): \(values[key]!)")
        }
        return output
    }

    /// The key of a top-level `key: value` line, or nil for continuation lines.
    static func key(of line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "-", first != "#", let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[..<colon])
    }

    /// Double-quoted YAML scalar, so titles with colons or quotes stay valid frontmatter.
    static func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

public enum DestinationError: Error, LocalizedError, Equatable {
    case unavailable(String, String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let id, let reason): return "Destination \"\(id)\" is unavailable: \(reason)."
        case .failed(let id, let reason): return "Destination \"\(id)\" failed: \(reason)."
        }
    }
}
