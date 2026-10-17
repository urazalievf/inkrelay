import CryptoKit
import Foundation
import InkRelayCore
import UIKit

/// A note read on this device, as Shortcuts and the app show it.
struct RelayedNote: Identifiable, Equatable {
    var id: String
    var title: String
    var text: String
    var modified: Date

    /// One string per note with the title on the first line, which is how Notes' "Create Note" titles a note.
    var noteText: String { title + "\n\n" + text }
}

/// The phone's side of InkRelay: one export folder picked through the Files app (so Google Drive, Dropbox,
/// OneDrive and iCloud Drive all work), read on the device with Vision. Apple Notes has no API on iOS either,
/// so instead of filing notes itself it hands them to Shortcuts.
final class MobileRelay {
    static let shared = MobileRelay()

    private let defaults: UserDefaults
    private let bookmarkKey = "exportFolderBookmark"
    private let ledgerBookmarkKey = "ledgerFolderBookmark"
    private let seenKey = "seenExports"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Folder

    var folderName: String? { resolve(bookmarkKey)?.lastPathComponent }
    /// The folder shared with InkRelay on the Mac, usually iCloud Drive/InkRelay.
    var ledgerFolderName: String? { resolve(ledgerBookmarkKey)?.lastPathComponent }

    func setFolder(_ url: URL) throws {
        try save(url, as: bookmarkKey)
        // A new folder starts fresh: everything already in it counts as new once.
        defaults.removeObject(forKey: seenKey)
    }

    func setLedgerFolder(_ url: URL) throws {
        try save(url, as: ledgerBookmarkKey)
    }

    private func save(_ url: URL, as key: String) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        defaults.set(try url.bookmarkData(options: .minimalBookmark), forKey: key)
    }

    private func resolve(_ key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark) { defaults.set(fresh, forKey: key) }
        return url
    }

    // MARK: Reading

    /// Exports that are new or changed since the last call, read and returned newest first. Each export is
    /// returned once per change. With a shared folder chosen, versions the Mac (or another iPhone or iPad)
    /// already filed into Notes are skipped, and what this device returns is recorded for them.
    func newNotes() throws -> [RelayedNote] {
        guard let folder = resolve(bookmarkKey) else { throw MobileError.noFolder }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let ledgerFolder = resolve(ledgerBookmarkKey)
        let ledgerAccess = ledgerFolder?.startAccessingSecurityScopedResource() ?? false
        defer { if ledgerAccess { ledgerFolder?.stopAccessingSecurityScopedResource() } }
        let ledger = ledgerFolder.map { SharedLedger(folder: $0, device: UIDevice.current.name) }
        var filed: [(hash: String, title: String)] = []

        let source = SourceConfig(id: "mobile", device: "Tablet", path: folder.path, fileTypes: ["pdf", "png", "jpg", "note"])
        let converted = FileManager.default.temporaryDirectory.appendingPathComponent("converted", isDirectory: true)
        let files = try FolderScanner.scan(source)
        var seen = defaults.dictionary(forKey: seenKey) as? [String: String] ?? [:]
        let recognizer = VisionTextRecognizer(config: RecognitionConfig(languages: []))
        var notes: [RelayedNote] = []
        for file in files {
            let stamp = "\(file.size)|\(file.modified.timeIntervalSince1970)"
            guard seen[file.relativePath] != stamp else { continue }
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            seen[file.relativePath] = stamp
            if ledger?.entry(for: hash) != nil { continue }
            let pages = try recognizer.recognize(fileAt: ExportConverter.readableURL(for: file.url, key: file.relativePath, cache: converted))
            let text = pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            let title = file.url.deletingPathExtension().lastPathComponent
            notes.append(RelayedNote(id: file.relativePath, title: title, text: text.isEmpty ? "(No text recognized.)" : text, modified: file.modified))
            filed.append((hash, title))
        }
        defaults.set(seen, forKey: seenKey)
        try? ledger?.record(filed)
        return notes.sorted { $0.modified > $1.modified }
    }

    /// Reads any PDF or image, for the "Recognize Handwriting" action.
    func recognize(_ data: Data, fileName: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = fileName.isEmpty ? "page.pdf" : fileName
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return try VisionTextRecognizer(config: RecognitionConfig(languages: [])).recognize(fileAt: url)
            .map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

enum MobileError: Error, LocalizedError {
    case noFolder

    var errorDescription: String? {
        switch self {
        case .noFolder: return "Open InkRelay and choose the folder your tablet exports to."
        }
    }
}
