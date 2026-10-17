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
    /// Used for sources with `"recognizer": "claude"`.
    private let aiRecognizer: TextRecognizer?
    /// What other devices filed into Apple Notes.
    private let ledger: SharedLedger?
    private let kindle: KindleMailPuller?
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        config: RelayConfig,
        store: StateStore,
        recognizer: TextRecognizer,
        destinations: [NoteDestination],
        puller: ViwoodsCloudPuller? = nil,
        aiRecognizer: TextRecognizer? = nil,
        ledger: SharedLedger? = nil,
        kindle: KindleMailPuller? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.store = store
        self.recognizer = recognizer
        self.destinations = destinations
        self.puller = puller
        self.aiRecognizer = aiRecognizer
        self.ledger = ledger
        self.kindle = kindle
        self.fileManager = fileManager
        self.now = now
    }

    /// The production wiring: Vision for recognition, the destinations named in the config,
    /// and the Viwoods Cloud puller when the config has a `viwoodsCloud` section.
    public static func live(config: RelayConfig, stateURL: URL = InkRelayCore.defaultStateURL) throws -> RelayEngine {
        let destinations = DestinationFactory.make(
            config.destinations,
            context: DestinationContext(config: config, supportDirectory: stateURL.deletingLastPathComponent())
        )
        var puller: ViwoodsCloudPuller?
        if let cloud = config.viwoodsCloud {
            let client = ViwoodsClient(credentials: FileCredentialStore(url: Self.tokenURL(besideState: stateURL)))
            puller = try ViwoodsCloudPuller(config: cloud, client: client, plans: DestinationFactory.plans(in: destinations))
        }
        let vision = VisionTextRecognizer(config: config.recognition)
        let ai: TextRecognizer? = config.allSources.contains { $0.recognizer == .claude }
            ? ClaudeTextRecognizer(config: config.ai ?? AITranscriptionConfig(), supportDirectory: stateURL.deletingLastPathComponent(), fallback: vision)
            : nil
        return RelayEngine(
            config: config,
            store: try StateStore(url: stateURL),
            recognizer: vision,
            destinations: destinations,
            puller: puller,
            aiRecognizer: ai,
            ledger: config.sharedLedger.flatMap { shared in shared.folderURL.map { SharedLedger(folder: $0, device: shared.device) } },
            kindle: config.kindleMail.map { KindleMailPuller(config: $0) }
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
        if let kindle {
            let (_, failures) = kindle.pull()
            for failure in failures { report.failures.append(.init(item: kindle.config.id, destinationID: nil, message: failure)) }
        }
        for source in config.allSources {
            let files: [ScannedFile]
            do {
                files = try FolderScanner.scan(source, fileManager: fileManager)
            } catch {
                report.failures.append(.init(item: source.id, destinationID: nil, message: error.localizedDescription))
                continue
            }
            let present = Set(files.map { SyncState.key(sourceID: source.id, relativePath: $0.relativePath) })
            let missing = store.keys(forSource: source.id).filter { !present.contains($0) }
            // A tracked export that vanished while an identical one appeared elsewhere was renamed or moved.
            var renameCandidates: [String: String] = [:]
            for key in missing {
                if let hash = store.record(for: key)?.contentHash { renameCandidates[hash] = key }
            }
            for file in files {
                report.scanned += 1
                sync(file, from: source, renameCandidates: &renameCandidates, into: &report)
            }
            let gone = missing.filter { store.record(for: $0) != nil }
            if !gone.isEmpty {
                if files.isEmpty {
                    // An empty folder is far more often an unmounted cloud drive than a deliberate wipe.
                    report.warnings.append("\(source.id): the folder is empty, so \(gone.count) missing export(s) were left alone.")
                } else {
                    for key in gone { handleMissing(key, source: source, into: &report) }
                }
            }
        }
        return report
    }

    private func sync(_ file: ScannedFile, from source: SourceConfig, renameCandidates: inout [String: String], into report: inout SyncReport) {
        let key = SyncState.key(sourceID: source.id, relativePath: file.relativePath)
        let item = "\(source.id)/\(file.relativePath)"
        var previous = store.record(for: key)

        if let known = previous, known.looksUnchanged(file), pending(for: known.contentHash, in: known).isEmpty {
            if known.missingSince != nil { try? store.set(FileRecord(size: known.size, modified: known.modified, contentHash: known.contentHash, destinations: known.destinations), for: key) }
            report.unchanged += 1
            return
        }
        // Age below zero means the cloud's clock is ahead of the Mac's, not that the file is being written.
        let age = now().timeIntervalSince(file.modified)
        if source.waitsForSettle, file.size == 0 || (age >= 0 && age < Double(config.settleSeconds)) {
            // Probably still downloading or being written; the follow-up pass picks it up.
            report.deferred += 1
            return
        }

        do {
            let hash = try ContentHash.sha256(of: file.url)
            var renamedFrom: String?
            if previous == nil, let oldKey = renameCandidates[hash], let old = store.record(for: oldKey) {
                renamedFrom = oldKey
                renameCandidates[hash] = nil
                previous = old
            }
            var record = FileRecord(
                size: file.size,
                modified: file.modified,
                contentHash: hash,
                destinations: previous?.destinations ?? [:]
            )
            // A rename goes to every destination that holds the note, so it moves instead of staying behind.
            let pendingNow = pending(for: hash, in: record)
            let targets = renamedFrom == nil ? pendingNow : destinations.filter { destination in
                record.destinations[destination.id] != nil || pendingNow.contains { $0.id == destination.id }
            }
            guard !targets.isEmpty else {
                // Touched but not changed: remember the new date so the next pass skips the read.
                try store.set(record, for: key)
                report.unchanged += 1
                return
            }

            // Native notebooks (Supernote .note) become a PDF first; everything downstream reads that.
            let readable = try ExportConverter.readableURL(for: file.url, key: key, cache: convertedDirectory)
            let note = InkNote(
                title: file.url.deletingPathExtension().lastPathComponent,
                sourceID: source.id,
                device: source.device,
                originalURL: readable,
                relativePath: file.relativePath,
                modified: file.modified,
                contentHash: hash,
                pages: try (source.recognizer == .claude ? aiRecognizer ?? recognizer : recognizer).recognize(fileAt: readable)
            )

            var deliveredAll = true
            var filedInNotes = false
            for destination in targets {
                if destination is AppleNotesDestination, let ledger, ledger.filedElsewhere(hash) {
                    // An iPhone or iPad already put this version in Notes; making another would duplicate it.
                    record.destinations[destination.id] = DestinationRecord(
                        externalID: record.destinations[destination.id]?.externalID ?? "", contentHash: hash, syncedAt: now()
                    )
                    report.filedElsewhere += 1
                    continue
                }
                do {
                    let externalID = try destination.upsert(note, previous: record.destinations[destination.id])
                    record.destinations[destination.id] = DestinationRecord(externalID: externalID, contentHash: hash, syncedAt: now())
                    if destination is AppleNotesDestination { filedInNotes = true }
                } catch {
                    deliveredAll = false
                    report.failures.append(.init(item: item, destinationID: destination.id, message: error.localizedDescription))
                }
            }
            try store.set(record, for: key)
            if filedInNotes, let ledger {
                do {
                    try ledger.record([(hash, note.title)], at: now())
                } catch {
                    report.warnings.append("Couldn't update the shared ledger: \(error.localizedDescription)")
                }
            }
            if let renamedFrom {
                try store.remove(renamedFrom)
                ExportConverter.discard(key: renamedFrom, cache: convertedDirectory)
                report.renamed += 1
            }
            if deliveredAll { report.synced += 1 }
            if source.recognizer == .claude, let claude = aiRecognizer as? ClaudeTextRecognizer {
                report.warnings += claude.takeFallbacks().map { "Vision read \($0)" }
            }
        } catch {
            report.failures.append(.init(item: item, destinationID: nil, message: error.localizedDescription))
        }
    }

    /// PDFs made from native notebooks, next to the sync state.
    private var convertedDirectory: URL { store.url.deletingLastPathComponent().appendingPathComponent("converted", isDirectory: true) }

    /// Seconds an export must stay missing before destinations act on it, so a cloud app re-downloading a file doesn't count.
    static let deletionGraceSeconds: TimeInterval = 60

    private func handleMissing(_ key: String, source: SourceConfig, into report: inout SyncReport) {
        guard var record = store.record(for: key) else { return }
        let firstMissed = record.missingSince ?? now()
        if record.missingSince == nil {
            record.missingSince = firstMissed
            try? store.set(record, for: key)
        }
        guard now().timeIntervalSince(firstMissed) >= Self.deletionGraceSeconds else { return }

        let export = RemovedExport(sourceID: source.id, relativePath: String(key.dropFirst(source.id.count + 1)))
        var acted = false
        for destination in destinations {
            guard let held = record.destinations[destination.id] else { continue }
            let policy = config.onDelete[destination.id] ?? .keep
            guard policy != .keep else { continue }
            do {
                try destination.remove(held, export: export, policy: policy)
                record.destinations[destination.id] = nil
                acted = true
            } catch {
                report.failures.append(.init(item: key, destinationID: destination.id, message: error.localizedDescription))
            }
        }
        do {
            if record.destinations.isEmpty {
                try store.remove(key)
                ExportConverter.discard(key: key, cache: convertedDirectory)
            } else {
                try store.set(record, for: key)
            }
        } catch {
            report.failures.append(.init(item: key, destinationID: nil, message: error.localizedDescription))
        }
        if acted { report.removed += 1 }
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
    /// Files still being written; a follow-up pass picks them up.
    public var deferred = 0
    public var renamed = 0
    public var removed = 0
    /// Versions another device had already filed into Apple Notes.
    public var filedElsewhere = 0
    /// Things worth knowing that aren't failures.
    public var warnings: [String] = []
    /// What the Viwoods Cloud pull did before the folders were scanned, when one is configured.
    public var pull: PullReport?

    public init() {}

    public var summary: String {
        var text = "\(scanned) found, \(synced) synced, \(unchanged) unchanged"
        if renamed > 0 { text += ", \(renamed) renamed" }
        if removed > 0 { text += ", \(removed) removed" }
        if filedElsewhere > 0 { text += ", \(filedElsewhere) already in Notes from another device" }
        if deferred > 0 { text += ", \(deferred) still being written" }
        if !failures.isEmpty { text += ", \(failures.count) failed" }
        if let pull { text = pull.summary + "; " + text }
        return text
    }
}
