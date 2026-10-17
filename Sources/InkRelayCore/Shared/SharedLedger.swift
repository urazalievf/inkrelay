import Foundation

/// What every device has filed into Apple Notes, kept in a folder they all reach (iCloud Drive by default),
/// so InkRelay on the Mac and on an iPhone or iPad don't both make a note for the same export.
///
/// A plain JSON file rather than an iCloud container, so it needs no entitlement: the Mac reads iCloud Drive
/// as a folder and the phone through the Files app. Exports are keyed by the SHA-256 of their bytes, which
/// is the same on every device. Copies iCloud makes when two devices write at once are merged back in.
public final class SharedLedger {
    public struct Entry: Codable, Equatable {
        public var by: String
        public var at: Date
        public var title: String
    }

    struct Contents: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    public let folder: URL
    public let device: String
    /// Oldest entries go first beyond this, which keeps the file small.
    static let limit = 5000

    public init(folder: URL, device: String) {
        self.folder = folder
        self.device = device
    }

    var url: URL { folder.appendingPathComponent("ledger.json") }

    /// The entry for an export, if any device has filed it.
    public func entry(for hash: String) -> Entry? {
        entries()[hash]
    }

    /// True when another device already filed this exact export.
    public func filedElsewhere(_ hash: String) -> Bool {
        guard let entry = entry(for: hash) else { return false }
        return entry.by != device
    }

    public func entries() -> [String: Entry] {
        var merged: [String: Entry] = [:]
        coordinate(writing: false) { _ in merged = readAll().entries }
        return merged
    }

    /// Adds exports this device filed, merging whatever other devices wrote meanwhile.
    public func record(_ hashes: [(hash: String, title: String)], at date: Date = Date()) throws {
        guard !hashes.isEmpty else { return }
        var failure: Error?
        coordinate(writing: true) { _ in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var contents = readAll()
                for item in hashes where contents.entries[item.hash] == nil {
                    contents.entries[item.hash] = Entry(by: device, at: date, title: item.title)
                }
                if contents.entries.count > Self.limit {
                    let keep = contents.entries.sorted { $0.value.at > $1.value.at }.prefix(Self.limit)
                    contents.entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(contents).write(to: url, options: .atomic)
                cleanUpCopies()
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    // MARK: Files

    /// `ledger.json`, the "ledger 2.json" copies a sync conflict leaves beside it, and iCloud's conflict versions.
    private func readAll() -> Contents {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var merged = Contents()
        func merge(_ data: Data?) {
            guard let data, let contents = try? decoder.decode(Contents.self, from: data) else { return }
            for (hash, entry) in contents.entries {
                if let existing = merged.entries[hash], existing.at <= entry.at { continue }
                merged.entries[hash] = entry
            }
        }
        for file in ledgerFiles() { merge(try? Data(contentsOf: file)) }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            merge(try? Data(contentsOf: version.url))
        }
        return merged
    }

    private func ledgerFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("ledger") && $0.hasSuffix(".json") }.sorted().map { folder.appendingPathComponent($0) }
    }

    private func cleanUpCopies() {
        for file in ledgerFiles() where file.lastPathComponent != "ledger.json" { try? FileManager.default.removeItem(at: file) }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }

    private func coordinate(writing: Bool, _ body: (URL) -> Void) {
        var error: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing {
            coordinator.coordinate(writingItemAt: folder, options: .forMerging, error: &error, byAccessor: body)
        } else {
            coordinator.coordinate(readingItemAt: folder, options: [], error: &error, byAccessor: body)
        }
        if error != nil { body(folder) }
    }

    /// iCloud Drive's folder on this Mac, when iCloud Drive is on.
    public static var iCloudDriveFolder: URL? {
        let drive = InkRelayCore.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: drive.path) ? drive.appendingPathComponent("InkRelay", isDirectory: true) : nil
    }
}

/// The `sharedLedger` section of the config.
public struct SharedLedgerConfig: Codable, Equatable {
    /// Folder for `ledger.json`; pick the same folder in the iPhone app. Defaults to iCloud Drive/InkRelay.
    public var folder: String?
    /// How this Mac signs its entries.
    public var device: String

    public init(folder: String? = nil, device: String = "Mac") {
        self.folder = folder
        self.device = device
    }

    private enum CodingKeys: String, CodingKey { case folder, device }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        device = try container.decodeIfPresent(String.self, forKey: .device) ?? "Mac"
    }

    public var folderURL: URL? {
        folder.map { URL(fileURLWithPath: PathExpansion.expand($0), isDirectory: true) } ?? SharedLedger.iCloudDriveFolder
    }
}
