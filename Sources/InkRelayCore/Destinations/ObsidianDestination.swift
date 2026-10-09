import Foundation

/// Writes one Markdown file per export into an Obsidian vault, mirroring the source's folder structure:
/// `<vault>/<folder>/<source id>/<relative dir>/<title>.md`, with the original PDF beside it.
///
/// The note is regenerated on every change to the export, so edits made in Obsidian are overwritten.
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

        let markdown = MarkdownRenderer.render(note, embedPath: originalPath, tags: config.tags)
        try Data(markdown.utf8).write(to: vault.appendingPathComponent(notePath), options: .atomic)
        return notePath
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

public enum MarkdownRenderer {
    public static func render(_ note: InkNote, embedPath: String?, tags: [String], syncedAt: Date = Date()) -> String {
        var lines: [String] = [
            "---",
            "source: \(yamlString(note.sourceID))",
            "device: \(yamlString(note.device))",
            "original: \(yamlString(note.relativePath))",
            "pages: \(note.pages.count)",
            "modified: \(NoteFormatting.timestamp.string(from: note.modified))",
            "synced: \(NoteFormatting.timestamp.string(from: syncedAt))",
        ]
        if !tags.isEmpty {
            lines.append("tags: [\(tags.map(yamlString).joined(separator: ", "))]")
        }
        lines += ["---", "", "# \(note.title)", ""]

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
        return lines.joined(separator: "\n")
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
