import CoreGraphics
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
    private let reviewShare: ReviewPublisher?
    private let fileManager: FileManager
    private let now: () -> Date
    /// Pro or free, read again at the start of every pass so a key entered while the engine runs, or a trial
    /// that ends while it runs, takes effect at the next sync. Free passes skip the Pro parts and say so once.
    private let entitlementProvider: () -> Entitlement
    private var entitlement: Entitlement
    /// Destination ids left out of this pass because they need Pro.
    private var pausedDestinationIDs: Set<String> = []
    /// Words learned from corrections in Obsidian, shared with the Vision recognizer.
    private let learned: LearnedVocabulary?
    /// Rendered templates and their masks, by template path and page size, for the life of the engine.
    private var templates: [String: CGImage] = [:]
    private var templateMasks: [String: TemplateSubtractor.Mask] = [:]
    private var activeDestinations: [NoteDestination] { destinations.filter { !pausedDestinationIDs.contains($0.id) } }

    public init(
        config: RelayConfig,
        store: StateStore,
        recognizer: TextRecognizer,
        destinations: [NoteDestination],
        puller: ViwoodsCloudPuller? = nil,
        aiRecognizer: TextRecognizer? = nil,
        ledger: SharedLedger? = nil,
        kindle: KindleMailPuller? = nil,
        reviewShare: ReviewPublisher? = nil,
        entitlement: Entitlement = .pro,
        entitlementProvider: (() -> Entitlement)? = nil,
        learned: LearnedVocabulary? = nil,
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
        self.reviewShare = reviewShare
        self.entitlement = entitlement
        self.entitlementProvider = entitlementProvider ?? { entitlement }
        self.learned = learned
        self.fileManager = fileManager
        self.now = now
        refreshEntitlement()
    }

    private func refreshEntitlement() {
        entitlement = entitlementProvider()
        pausedDestinationIDs = entitlement.isPro ? [] : Set(config.destinations.filter(ProFeatures.isPro).map(\.id))
    }

    /// What this pass left out for want of a license, or nil.
    var pausedNotice: String? {
        guard !entitlement.isPro else { return nil }
        let parts = ProFeatures.used(in: config)
        guard !parts.isEmpty else { return nil }
        if let rejection = entitlement.rejection {
            return "\(Self.pausedPrefix): \(parts.joined(separator: ", ")). The key on file wasn't accepted (\(rejection)); enter a new one with `inkrelay license enter KEY` or remove it with `inkrelay license remove`. Nothing is lost."
        }
        let when: String
        if case .trialEnded(let date) = entitlement.basis { when = " since the trial ended \(date.formatted(date: .abbreviated, time: .omitted))" } else { when = "" }
        return "\(Self.pausedPrefix)\(when): \(parts.joined(separator: ", ")). Buy a license at \(LicensePublisher.purchaseText), then enter it in the InkRelay menu or with `inkrelay license enter KEY`; nothing is lost, syncing resumes from here."
    }

    /// The start of the paused notice, so the app can show it as a panel rather than a problem.
    public static let pausedPrefix = "Pro features paused"

    public static func isPausedNotice(_ line: String) -> Bool { line.hasPrefix(pausedPrefix) }

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
        let learned = LearnedVocabulary(url: stateURL.deletingLastPathComponent().appendingPathComponent("vocabulary.json"))
        let vision = VisionTextRecognizer(config: config.recognition, learned: learned)
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
            kindle: config.kindleMail.map { KindleMailPuller(config: $0) },
            reviewShare: reviewPublisher(config: config, destinations: destinations, supportDirectory: stateURL.deletingLastPathComponent()),
            entitlementProvider: { EntitlementStore(supportDirectory: stateURL.deletingLastPathComponent()).current() },
            learned: learned
        )
    }

    static func reviewPublisher(config: RelayConfig, destinations: [NoteDestination], supportDirectory: URL) -> ReviewPublisher? {
        for case .reviewStack(let stack) in config.destinations {
            guard let base = stack.shareBase(ledger: config.sharedLedger) else { return nil }
            let directory = DestinationContext(config: config, supportDirectory: supportDirectory).reviewDirectory
            return ReviewPublisher(store: ReviewStore(directory: directory), base: base, config: stack, calendars: DestinationFactory.eventWriters(in: destinations))
        }
        return nil
    }

    /// The Viwoods token sits next to the state file, so separate configs never share a login.
    public static func tokenURL(besideState stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("viwoods-token.json")
    }

    /// The recognized text of every relayed note, for search.
    public var archive: NoteArchive { NoteArchive(directory: store.url.deletingLastPathComponent().appendingPathComponent("archive", isDirectory: true)) }
    private lazy var notes = archive

    public func syncOnce() -> SyncReport {
        // One pass at a time across processes (watch, the menu bar app, the MCP server), each starting from
        // the state the last one saved, so none overwrites another's records.
        let lock = store.url.deletingLastPathComponent().appendingPathComponent(".sync.lock")
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_CREAT | O_RDWR, 0o600)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer {
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        try? store.reload()
        refreshEntitlement()
        let report = pass()
        LastSync(report: report, at: now()).save(besideState: store.url)
        return report
    }

    private func pass() -> SyncReport {
        var report = SyncReport()
        if let pausedNotice { report.warnings.append(pausedNotice) }
        if let puller, entitlement.isPro {
            let pull = puller.pull()
            report.pull = pull
            for failure in pull.failures {
                report.failures.append(.init(item: puller.config.id, destinationID: nil, message: failure))
            }
        }
        if let kindle, entitlement.isPro {
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
            // Exports in a folder the source now leaves out stay tracked, so excluding a folder never deletes notes.
            let missing = store.keys(forSource: source.id).filter { key in
                !present.contains(key) && source.includes(String(key.dropFirst(source.id.count + 1)))
            }
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
        // Last, so phones see this pass's cards and the Mac applies what they decided since the previous one.
        if let reviewShare, entitlement.isPro {
            let shared = reviewShare.sync()
            report.warnings += shared.failures
        }
        return report
    }

    private func sync(_ file: ScannedFile, from source: SourceConfig, renameCandidates: inout [String: String], into report: inout SyncReport) {
        let key = SyncState.key(sourceID: source.id, relativePath: file.relativePath)
        let item = "\(source.id)/\(file.relativePath)"
        var previous = store.record(for: key)

        // An empty notebook stays out of every destination until someone writes in it.
        if let known = previous, known.blank == true, known.looksUnchanged(file) {
            if known.missingSince != nil {
                var back = known
                back.missingSince = nil
                try? store.set(back, for: key)
            }
            report.unchanged += 1
            return
        }

        // Notes synced before the archive existed get archived once, read with Vision so it costs nothing.
        let needsArchive = previous.map { notes.entry(forKey: key)?.contentHash != $0.contentHash } ?? false
        if let known = previous, known.looksUnchanged(file), pending(for: known.contentHash, in: known).isEmpty,
           !needsArchive || source.usesAI(for: file.relativePath) {
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
            // Learn corrections first, so the changed page is read with them.
            learnCorrections(for: key, record: record, into: &report)
            // A rename goes to every destination that holds the note, so it moves instead of staying behind.
            let pendingNow = pending(for: hash, in: record)
            let targets = renamedFrom == nil ? pendingNow : activeDestinations.filter { destination in
                record.destinations[destination.id] != nil || pendingNow.contains { $0.id == destination.id }
            }
            guard !targets.isEmpty else {
                // Touched but not changed: remember the new date so the next pass skips the read.
                try store.set(record, for: key)
                if notes.entry(forKey: key)?.contentHash != hash, !source.usesAI(for: file.relativePath) {
                    let readable = try ExportConverter.readableURL(for: file.url, key: key, cache: convertedDirectory)
                    let supernoteInk = source.recognizeInkOnly ? try ExportConverter.inkOnlyURL(for: file.url, key: key, cache: convertedDirectory) : nil
                    let forReading = inkOnlyURL(for: file, source: source) ?? supernoteInk ?? readable
                    try notes.upsert(InkNote(
                        title: file.url.deletingPathExtension().lastPathComponent, sourceID: source.id, device: source.device,
                        originalURL: readable, relativePath: file.relativePath, modified: file.modified, contentHash: hash,
                        pages: try recognizePages(of: forReading, relativePath: file.relativePath, source: source)
                    ), key: key, at: now())
                }
                report.unchanged += 1
                return
            }

            // Native notebooks (Supernote .note) become a PDF first; everything downstream reads that.
            let readable = try ExportConverter.readableURL(for: file.url, key: key, cache: convertedDirectory)
            // Viwoods Cloud keeps an ink-only copy beside the page, and Supernote notebooks can leave their template
            // layer out; reading those keeps the template's text out of the note.
            let supernoteInk = source.recognizeInkOnly ? try ExportConverter.inkOnlyURL(for: file.url, key: key, cache: convertedDirectory) : nil
            let forReading = inkOnlyURL(for: file, source: source) ?? supernoteInk ?? readable
            let note = InkNote(
                title: file.url.deletingPathExtension().lastPathComponent,
                sourceID: source.id,
                device: source.device,
                originalURL: readable,
                relativePath: file.relativePath,
                modified: file.modified,
                contentHash: hash,
                pages: try recognizePages(of: forReading, relativePath: file.relativePath, source: source)
            )

            if note.pages.allSatisfy(\.isBlank), record.destinations.isEmpty {
                record.blank = true
                try store.set(record, for: key)
                report.blank += 1
                return
            }

            try? notes.upsert(note, key: key, at: now())
            // The old key leaves the archive before destinations build their digests, or the note counts twice.
            if let renamedFrom { notes.remove(key: renamedFrom) }
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

    /// Claude for the folders the source sends there, otherwise Vision, with the template taken out first when
    /// the source names one.
    private func recognizePages(of url: URL, relativePath: String, source: SourceConfig) throws -> [RecognizedPage] {
        if entitlement.isPro, source.usesAI(for: relativePath), let ai = aiRecognizer {
            (ai as? ClaudeTextRecognizer)?.currentSource = (source.id, source.aiMonthlyBudgetUSD)
            return try ai.recognize(fileAt: url)
        }
        if let templateURL = source.templateURL, let vision = recognizer as? VisionTextRecognizer {
            let settings = vision.config
            let images = try PageRenderer.images(for: url, scale: settings.renderScale, maxPixelDimension: settings.maxPixelDimension)
            let templateKey = templateURL.path + "@\(settings.renderScale)"
            let template: CGImage
            if let cached = templates[templateKey] {
                template = cached
            } else {
                template = try TemplateSubtractor.templateImage(at: templateURL, scale: settings.renderScale, maxPixelDimension: settings.maxPixelDimension)
                templates[templateKey] = template
            }
            let cleaned = images.map { image -> CGImage in
                let maskKey = templateKey + "/\(image.width)x\(image.height)"
                let mask = templateMasks[maskKey] ?? TemplateSubtractor.Mask(template: template, width: image.width, height: image.height)
                templateMasks[maskKey] = mask
                return TemplateSubtractor.clean(image, mask: mask)
            }
            return try vision.recognize(images: cleaned)
        }
        return try recognizer.recognize(fileAt: url)
    }

    /// Before the archive and the vault copy are overwritten: words the person typed into InkRelay's block of the
    /// Obsidian note that weren't in what InkRelay wrote are corrections, and Vision is told to expect them.
    private func learnCorrections(for key: String, record: FileRecord, into report: inout SyncReport) {
        guard let learned, let previous = notes.entry(forKey: key) else { return }
        for case .obsidian(let obsidian) in config.destinations {
            // Only a vault copy of the archived version is comparable; a lagging copy would teach old misreads.
            guard let delivered = record.destinations[obsidian.id], delivered.contentHash == previous.contentHash,
                  let external = Optional(delivered.externalID), !external.isEmpty,
                  let markdown = try? String(contentsOf: obsidian.vaultURL.appendingPathComponent(external), encoding: .utf8),
                  let edited = VocabularyLearner.managedText(of: markdown) else { continue }
            let original = previous.pages.map(\.text).joined(separator: "\n")
            let words = VocabularyLearner.newWords(edited: edited, original: original, known: config.recognition.vocabulary + learned.all)
            report.learned += learned.add(words)
        }
    }

    private func inkOnlyURL(for file: ScannedFile, source: SourceConfig) -> URL? {
        guard let cloud = config.viwoodsCloud, cloud.id == source.id, cloud.recognizeInkOnly else { return nil }
        let url = cloud.inkURL(for: file.relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
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
                notes.remove(key: key)
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
        activeDestinations.filter { record.destinations[$0.id]?.contentHash != hash }
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
    /// Exports with nothing written in them yet, left out of every destination.
    public var blank = 0
    /// Words learned this pass from corrections made in Obsidian.
    public var learned: [String] = []
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
        if blank > 0 { text += ", \(blank) blank" }
        if !learned.isEmpty { text += ", learned \(learned.count) word\(learned.count == 1 ? "" : "s")" }
        if deferred > 0 { text += ", \(deferred) still being written" }
        if !failures.isEmpty { text += ", \(failures.count) failed" }
        if let pull { text = pull.summary + "; " + text }
        return text
    }
}
