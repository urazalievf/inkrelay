import Foundation

/// One pass over every source: find new or changed exports, recognize them once,
/// and send them to each destination that hasn't received this version yet.
///
/// A destination that fails is retried on the next pass; the others aren't re-sent.
/// Exports deleted from a source are left alone in destinations.
public final class RelayEngine {
    private let config: RelayConfig
    private let store: StateStore
    private let recognizer: TextRecognizer
    private let destinations: [NoteDestination]
    private let puller: ViwoodsCloudPuller?
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        config: RelayConfig,
        store: StateStore,
        recognizer: TextRecognizer,
        destinations: [NoteDestination],
        puller: ViwoodsCloudPuller? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.store = store
        self.recognizer = recognizer
        self.destinations = destinations
        self.puller = puller
        self.fileManager = fileManager
        self.now = now
    }

    /// The production wiring: Vision for recognition, the destinations named in the config,
    /// and the Viwoods Cloud puller when the config has a `viwoodsCloud` section.
    public static func live(config: RelayConfig, stateURL: URL = InkRelayCore.defaultStateURL) throws -> RelayEngine {
        let destinations = DestinationFactory.make(config.destinations)
        var puller: ViwoodsCloudPuller?
        if let cloud = config.viwoodsCloud {
            let client = ViwoodsClient(credentials: FileCredentialStore(url: Self.tokenURL(besideState: stateURL)))
            puller = try ViwoodsCloudPuller(config: cloud, client: client, plans: DestinationFactory.plans(in: destinations))
        }
        return RelayEngine(
            config: config,
            store: try StateStore(url: stateURL),
            recognizer: VisionTextRecognizer(config: config.recognition),
            destinations: destinations,
            puller: puller
        )
    }

    /// The Viwoods token sits next to the state file, so separate configs never share a login.
    public static func tokenURL(besideState stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("viwoods-token.json")
    }

    public func syncOnce() -> SyncReport {
        var report = SyncReport()
        if let puller {
            let pull = puller.pull()
            report.pull = pull
            for failure in pull.failures {
                report.failures.append(.init(item: puller.config.id, destinationID: nil, message: failure))
            }
        }
        for source in config.allSources {
            let files: [ScannedFile]
            do {
                files = try FolderScanner.scan(source, fileManager: fileManager)
            } catch {
                report.failures.append(.init(item: source.id, destinationID: nil, message: error.localizedDescription))
                continue
            }
            for file in files {
                report.scanned += 1
                sync(file, from: source, into: &report)
            }
        }
        return report
    }

    private func sync(_ file: ScannedFile, from source: SourceConfig, into report: inout SyncReport) {
        let key = SyncState.key(sourceID: source.id, relativePath: file.relativePath)
        let item = "\(source.id)/\(file.relativePath)"
        let previous = store.record(for: key)

        if let previous, previous.looksUnchanged(file), pending(for: previous.contentHash, in: previous).isEmpty {
            report.unchanged += 1
            return
        }

        do {
            let hash = try ContentHash.sha256(of: file.url)
            var record = FileRecord(
                size: file.size,
                modified: file.modified,
                contentHash: hash,
                destinations: previous?.destinations ?? [:]
            )
            let targets = pending(for: hash, in: record)
            guard !targets.isEmpty else {
                // Touched but not changed: remember the new date so the next pass skips the read.
                try store.set(record, for: key)
                report.unchanged += 1
                return
            }

            let note = InkNote(
                title: file.url.deletingPathExtension().lastPathComponent,
                sourceID: source.id,
                device: source.device,
                originalURL: file.url,
                relativePath: file.relativePath,
                modified: file.modified,
                contentHash: hash,
                pages: try recognizer.recognize(fileAt: file.url)
            )

            var deliveredAll = true
            for destination in targets {
                do {
                    let externalID = try destination.upsert(note, previous: record.destinations[destination.id])
                    record.destinations[destination.id] = DestinationRecord(externalID: externalID, contentHash: hash, syncedAt: now())
                } catch {
                    deliveredAll = false
                    report.failures.append(.init(item: item, destinationID: destination.id, message: error.localizedDescription))
                }
            }
            try store.set(record, for: key)
            if deliveredAll { report.synced += 1 }
        } catch {
            report.failures.append(.init(item: item, destinationID: nil, message: error.localizedDescription))
        }
    }

    /// Destinations that haven't received the export with this hash.
    private func pending(for hash: String, in record: FileRecord) -> [NoteDestination] {
        destinations.filter { record.destinations[$0.id]?.contentHash != hash }
    }
}

public struct SyncReport: Equatable {
    public struct Failure: Equatable {
        /// `<source id>/<relative path>`, or just the source id when the folder itself failed.
        public var item: String
        public var destinationID: String?
        public var message: String
    }

    public var scanned = 0
    public var synced = 0
    public var unchanged = 0
    public var failures: [Failure] = []
    /// What the Viwoods Cloud pull did before the folders were scanned, when one is configured.
    public var pull: PullReport?

    public init() {}

    public var summary: String {
        var text = "\(scanned) found, \(synced) synced, \(unchanged) unchanged"
        if !failures.isEmpty { text += ", \(failures.count) failed" }
        if let pull { text = pull.summary + "; " + text }
        return text
    }
}
