import CryptoKit
import Foundation

/// What has already been relayed, so each run only touches new or changed exports.
public struct SyncState: Codable, Equatable {
    /// Keyed by `"<source id>/<relative path>"`.
    public var files: [String: FileRecord]

    public init(files: [String: FileRecord] = [:]) {
        self.files = files
    }

    public static func key(sourceID: String, relativePath: String) -> String {
        "\(sourceID)/\(relativePath)"
    }
}

public struct FileRecord: Codable, Equatable {
    public var size: Int64
    public var modified: Date
    public var contentHash: String
    /// Keyed by destination id.
    public var destinations: [String: DestinationRecord]

    public init(size: Int64, modified: Date, contentHash: String, destinations: [String: DestinationRecord] = [:]) {
        self.size = size
        self.modified = modified
        self.contentHash = contentHash
        self.destinations = destinations
    }

    /// True when size and modification date still match, so the file can be skipped without reading it.
    /// Reading a cloud placeholder forces a download, which is what this avoids.
    func looksUnchanged(_ file: ScannedFile) -> Bool {
        size == file.size && abs(modified.timeIntervalSince(file.modified)) < 0.001
    }
}

public struct DestinationRecord: Codable, Equatable {
    /// The destination's handle for the note: a vault-relative path, a Notes id, and so on.
    public var externalID: String
    /// Hash of the export this destination last received.
    public var contentHash: String
    public var syncedAt: Date

    public init(externalID: String, contentHash: String, syncedAt: Date) {
        self.externalID = externalID
        self.contentHash = contentHash
        self.syncedAt = syncedAt
    }
}

/// Loads and saves `state.json` atomically.
public final class StateStore {
    public let url: URL
    public private(set) var state: SyncState

    public init(url: URL = InkRelayCore.defaultStateURL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url))
        } else {
            state = SyncState()
        }
    }

    public func record(for key: String) -> FileRecord? {
        state.files[key]
    }

    public func set(_ record: FileRecord, for key: String) throws {
        state.files[key] = record
        try save()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

enum ContentHash {
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
