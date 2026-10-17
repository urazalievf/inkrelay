import Foundation

/// Everything InkRelay needs to know: where notes come from, where they go, and how to read them.
public struct RelayConfig: Codable, Equatable {
    public var sources: [SourceConfig]
    public var destinations: [DestinationConfig]
    public var recognition: RecognitionConfig
    /// Full rescan interval for `inkrelay watch`, on top of file-system events.
    /// Cloud folders don't always report remote changes, so this is the safety net.
    /// Viwoods Cloud is polled on the same interval.
    public var rescanIntervalSeconds: Int
    /// Pull notebooks and the planner straight from Viwoods Cloud, without a Drive export.
    public var viwoodsCloud: ViwoodsCloudConfig?
    /// OAuth client for the Google destinations.
    public var google: GoogleAccountConfig?
    /// App registration for the Microsoft destinations.
    public var microsoft: MicrosoftAccountConfig?
    /// What each destination does when an export is deleted from its folder, by destination id. Missing means keep.
    public var onDelete: [String: RemovalPolicy]
    /// A file must sit unchanged this long before it's read, so half-downloaded exports aren't relayed.
    public var settleSeconds: Int
    /// AI transcription settings for sources with `"recognizer": "claude"`. Defaults apply when missing.
    public var ai: AITranscriptionConfig?
    /// Where `inkrelay send` delivers articles and documents. The first is the default.
    public var sendTargets: [SendTargetConfig]
    /// Shares what was filed into Apple Notes with InkRelay on an iPhone or iPad, so they don't duplicate notes.
    public var sharedLedger: SharedLedgerConfig?
    /// Notebooks a Kindle Scribe shares by email, picked up from Mail.
    public var kindleMail: KindleMailConfig?

    public init(
        sources: [SourceConfig],
        destinations: [DestinationConfig],
        recognition: RecognitionConfig = RecognitionConfig(),
        rescanIntervalSeconds: Int = 300,
        viwoodsCloud: ViwoodsCloudConfig? = nil,
        google: GoogleAccountConfig? = nil,
        microsoft: MicrosoftAccountConfig? = nil,
        onDelete: [String: RemovalPolicy] = [:],
        settleSeconds: Int = 5,
        ai: AITranscriptionConfig? = nil,
        sendTargets: [SendTargetConfig] = [],
        sharedLedger: SharedLedgerConfig? = nil,
        kindleMail: KindleMailConfig? = nil
    ) {
        self.sources = sources
        self.destinations = destinations
        self.recognition = recognition
        self.rescanIntervalSeconds = rescanIntervalSeconds
        self.viwoodsCloud = viwoodsCloud
        self.google = google
        self.microsoft = microsoft
        self.onDelete = onDelete
        self.settleSeconds = settleSeconds
        self.ai = ai
        self.sendTargets = sendTargets
        self.sharedLedger = sharedLedger
        self.kindleMail = kindleMail
    }

    private enum CodingKeys: String, CodingKey {
        case sources, destinations, recognition, rescanIntervalSeconds, viwoodsCloud, google, microsoft, onDelete, settleSeconds, ai, sendTargets, sharedLedger, kindleMail
    }

    /// Folder sources plus the Viwoods Cloud cache, which the engine scans like any other folder.
    public var allSources: [SourceConfig] {
        sources + (viwoodsCloud.map { [$0.source] } ?? []) + (kindleMail.map { [$0.source] } ?? [])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decode([SourceConfig].self, forKey: .sources)
        destinations = try container.decode([DestinationConfig].self, forKey: .destinations)
        recognition = try container.decodeIfPresent(RecognitionConfig.self, forKey: .recognition) ?? RecognitionConfig()
        rescanIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .rescanIntervalSeconds) ?? 300
        viwoodsCloud = try container.decodeIfPresent(ViwoodsCloudConfig.self, forKey: .viwoodsCloud)
        google = try container.decodeIfPresent(GoogleAccountConfig.self, forKey: .google)
        microsoft = try container.decodeIfPresent(MicrosoftAccountConfig.self, forKey: .microsoft)
        onDelete = try container.decodeIfPresent([String: RemovalPolicy].self, forKey: .onDelete) ?? [:]
        settleSeconds = try container.decodeIfPresent(Int.self, forKey: .settleSeconds) ?? 5
        ai = try container.decodeIfPresent(AITranscriptionConfig.self, forKey: .ai)
        sendTargets = try container.decodeIfPresent([SendTargetConfig].self, forKey: .sendTargets) ?? []
        sharedLedger = try container.decodeIfPresent(SharedLedgerConfig.self, forKey: .sharedLedger)
        kindleMail = try container.decodeIfPresent(KindleMailConfig.self, forKey: .kindleMail)
    }

    /// Checks the things JSON decoding can't: unique ids and at least one source and destination.
    public func validate() throws {
        guard !allSources.isEmpty else { throw ConfigError.invalid("Add at least one source folder, or a viwoodsCloud or kindleMail section.") }
        guard !destinations.isEmpty else { throw ConfigError.invalid("Add at least one destination.") }
        try viwoodsCloud?.validate()
        if google == nil, let needing = destinations.first(where: \.needsGoogle) {
            throw ConfigError.invalid("Destination \"\(needing.id)\" needs a \"google\" section with the clientId and clientSecret of a Desktop OAuth client.")
        }
        if microsoft == nil, let needing = destinations.first(where: \.needsMicrosoft) {
            throw ConfigError.invalid("Destination \"\(needing.id)\" needs a \"microsoft\" section with the clientId of an app registration.")
        }
        let stacks = destinations.compactMap { destination -> DestinationConfig.ReviewStackConfig? in
            if case .reviewStack(let stack) = destination { return stack }
            return nil
        }
        if stacks.count > 1 { throw ConfigError.invalid("Only one reviewStack destination is supported.") }
        try stacks.first?.validate()
        for destination in destinations {
            if case .notion(let notion) = destination { try notion.validate() }
        }
        let destinationIDs = Set(destinations.map(\.id))
        if let unknown = onDelete.keys.sorted().first(where: { !destinationIDs.contains($0) }) {
            throw ConfigError.invalid("onDelete names \"\(unknown)\", which isn't a destination id.")
        }
        guard (0...600).contains(settleSeconds) else { throw ConfigError.invalid("settleSeconds must be between 0 and 600.") }
        try ai?.validate()
        if let duplicate = sendTargets.map(\.id).firstDuplicate() {
            throw ConfigError.invalid("Two send targets share the id \"\(duplicate)\".")
        }
        for (kind, ids) in [("source", allSources.map(\.id)), ("destination", destinations.map(\.id))] {
            if let duplicate = ids.firstDuplicate() {
                throw ConfigError.invalid("Two \(kind)s share the id \"\(duplicate)\". Ids must be unique.")
            }
        }
        if rescanIntervalSeconds < 30 {
            throw ConfigError.invalid("rescanIntervalSeconds must be at least 30.")
        }
    }
}

/// A folder a tablet exports into, usually one synced by the Google Drive, Dropbox or OneDrive Mac app.
public struct SourceConfig: Codable, Equatable {
    /// Stable id used as the key in the sync state. Changing it re-syncs everything from this source.
    public var id: String
    /// Shown in notes, for example "Viwoods AiPaper".
    public var device: String
    public var path: String
    /// Lowercased extensions to pick up. PDF covers most tablets; Boox can also export PNG.
    public var fileTypes: [String]
    /// Wait for files to settle before reading. Off for InkRelay's own cloud cache, which it writes atomically.
    public var waitsForSettle = true
    /// `vision` (default, on the Mac) or `claude` (page images are sent to Anthropic; see the `ai` section).
    public var recognizer: RecognizerKind

    public init(id: String, device: String, path: String, fileTypes: [String] = ["pdf"], recognizer: RecognizerKind = .vision) {
        self.id = id
        self.device = device
        self.path = path
        self.fileTypes = fileTypes
        self.recognizer = recognizer
    }

    private enum CodingKeys: String, CodingKey { case id, device, path, fileTypes, recognizer }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        device = try container.decodeIfPresent(String.self, forKey: .device) ?? id
        path = try container.decode(String.self, forKey: .path)
        fileTypes = try container.decodeIfPresent([String].self, forKey: .fileTypes) ?? ["pdf"]
        recognizer = try container.decodeIfPresent(RecognizerKind.self, forKey: .recognizer) ?? .vision
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(device, forKey: .device)
        try container.encode(path, forKey: .path)
        try container.encode(fileTypes, forKey: .fileTypes)
        if recognizer != .vision { try container.encode(recognizer, forKey: .recognizer) }
    }

    public var url: URL { URL(fileURLWithPath: PathExpansion.expand(path), isDirectory: true) }
}

public enum RecognizerKind: String, Codable, Equatable {
    case vision
    case claude
}

/// Where recognized notes are written. The `kind` field picks the case in JSON.
public enum DestinationConfig: Codable, Equatable {
    case obsidian(ObsidianConfig)
    case appleNotes(AppleNotesConfig)
    case appleCalendar(AppleCalendarConfig)
    case googleCalendar(GoogleCalendarConfig)
    case googleDocs(GoogleDocsConfig)
    case outlookCalendar(OutlookCalendarConfig)
    case oneNote(OneNoteConfig)
    case reviewStack(ReviewStackConfig)
    case notion(NotionConfig)
    case appleReminders(AppleRemindersConfig)

    public struct ObsidianConfig: Codable, Equatable {
        public var id: String
        public var vaultPath: String
        /// Folder inside the vault. Each source gets a subfolder under it.
        public var folder: String
        /// Copy the original PDF next to the note and embed it.
        public var copyOriginal: Bool
        public var tags: [String]

        public init(id: String, vaultPath: String, folder: String = "Ink", copyOriginal: Bool = true, tags: [String] = ["ink"]) {
            self.id = id
            self.vaultPath = vaultPath
            self.folder = folder
            self.copyOriginal = copyOriginal
            self.tags = tags
        }

        private enum CodingKeys: String, CodingKey { case id, vaultPath, folder, copyOriginal, tags }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            vaultPath = try container.decode(String.self, forKey: .vaultPath)
            folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? "Ink"
            copyOriginal = try container.decodeIfPresent(Bool.self, forKey: .copyOriginal) ?? true
            tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? ["ink"]
        }

        public var vaultURL: URL { URL(fileURLWithPath: PathExpansion.expand(vaultPath), isDirectory: true) }
    }

    public struct AppleNotesConfig: Codable, Equatable {
        public var id: String
        /// Notes folder to file into. Created on first use.
        public var folder: String
        /// Notes account name such as "iCloud". Empty or missing uses the default account.
        public var account: String?
        /// Attach the original PDF so the handwriting sits next to the text.
        public var attachOriginal: Bool

        public init(id: String, folder: String = "Ink", account: String? = nil, attachOriginal: Bool = true) {
            self.id = id
            self.folder = folder
            self.account = account
            self.attachOriginal = attachOriginal
        }

        private enum CodingKeys: String, CodingKey { case id, folder, account, attachOriginal }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? "Ink"
            account = try container.decodeIfPresent(String.self, forKey: .account)
            attachOriginal = try container.decodeIfPresent(Bool.self, forKey: .attachOriginal) ?? true
        }
    }

    /// Apple Calendar takes only the Viwoods Daily planner: handwritten day pages and typed to-dos,
    /// as all-day events. Other notebooks are skipped.
    public struct AppleCalendarConfig: Codable, Equatable {
        public var id: String
        /// Calendar to file into. Created on first use if missing.
        public var calendar: String
        /// Event title for a day page, followed by the first recognized line.
        public var pageTitle: String

        public init(id: String, calendar: String = "Viwoods", pageTitle: String = "Daily plan") {
            self.id = id
            self.calendar = calendar
            self.pageTitle = pageTitle
        }

        private enum CodingKeys: String, CodingKey { case id, calendar, pageTitle }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            calendar = try container.decodeIfPresent(String.self, forKey: .calendar) ?? "Viwoods"
            pageTitle = try container.decodeIfPresent(String.self, forKey: .pageTitle) ?? "Daily plan"
        }
    }

    public var id: String {
        switch self {
        case .obsidian(let config): return config.id
        case .appleNotes(let config): return config.id
        case .appleCalendar(let config): return config.id
        case .googleCalendar(let config): return config.id
        case .googleDocs(let config): return config.id
        case .outlookCalendar(let config): return config.id
        case .oneNote(let config): return config.id
        case .reviewStack(let config): return config.id
        case .notion(let config): return config.id
        case .appleReminders(let config): return config.id
        }
    }

    public var kind: String {
        switch self {
        case .obsidian: return "obsidian"
        case .appleNotes: return "appleNotes"
        case .appleCalendar: return "appleCalendar"
        case .googleCalendar: return "googleCalendar"
        case .googleDocs: return "googleDocs"
        case .outlookCalendar: return "outlookCalendar"
        case .oneNote: return "oneNote"
        case .reviewStack: return "reviewStack"
        case .notion: return "notion"
        case .appleReminders: return "appleReminders"
        }
    }

    private enum KindKey: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: KindKey.self).decode(String.self, forKey: .kind)
        switch kind {
        case "obsidian": self = .obsidian(try ObsidianConfig(from: decoder))
        case "appleNotes": self = .appleNotes(try AppleNotesConfig(from: decoder))
        case "appleCalendar": self = .appleCalendar(try AppleCalendarConfig(from: decoder))
        case "googleCalendar": self = .googleCalendar(try GoogleCalendarConfig(from: decoder))
        case "googleDocs": self = .googleDocs(try GoogleDocsConfig(from: decoder))
        case "outlookCalendar": self = .outlookCalendar(try OutlookCalendarConfig(from: decoder))
        case "oneNote": self = .oneNote(try OneNoteConfig(from: decoder))
        case "reviewStack": self = .reviewStack(try ReviewStackConfig(from: decoder))
        case "notion": self = .notion(try NotionConfig(from: decoder))
        case "appleReminders": self = .appleReminders(try AppleRemindersConfig(from: decoder))
        default:
            throw ConfigError.invalid("Unknown destination kind \"\(kind)\". Use one of: \(Self.kinds.joined(separator: ", ")).")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var kindContainer = encoder.container(keyedBy: KindKey.self)
        try kindContainer.encode(kind, forKey: .kind)
        switch self {
        case .obsidian(let config): try config.encode(to: encoder)
        case .appleNotes(let config): try config.encode(to: encoder)
        case .appleCalendar(let config): try config.encode(to: encoder)
        case .googleCalendar(let config): try config.encode(to: encoder)
        case .googleDocs(let config): try config.encode(to: encoder)
        case .outlookCalendar(let config): try config.encode(to: encoder)
        case .oneNote(let config): try config.encode(to: encoder)
        case .reviewStack(let config): try config.encode(to: encoder)
        case .notion(let config): try config.encode(to: encoder)
        case .appleReminders(let config): try config.encode(to: encoder)
        }
    }

    public static let kinds = ["obsidian", "appleNotes", "appleCalendar", "googleCalendar", "googleDocs", "outlookCalendar", "oneNote", "reviewStack", "notion", "appleReminders"]
}

public struct RecognitionConfig: Codable, Equatable {
    /// BCP 47 codes passed to Vision. Empty lets Vision decide.
    public var languages: [String]
    public var usesLanguageCorrection: Bool
    /// Pages are rendered at this multiple of their PDF size before recognition.
    public var renderScale: Double
    /// Upper bound on the longest rendered side, to keep memory in check on large pages.
    public var maxPixelDimension: Int

    public init(languages: [String] = ["en-US"], usesLanguageCorrection: Bool = true, renderScale: Double = 2, maxPixelDimension: Int = 3000) {
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.renderScale = renderScale
        self.maxPixelDimension = maxPixelDimension
    }

    private enum CodingKeys: String, CodingKey { case languages, usesLanguageCorrection, renderScale, maxPixelDimension }

    public init(from decoder: Decoder) throws {
        let defaults = RecognitionConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? defaults.languages
        usesLanguageCorrection = try container.decodeIfPresent(Bool.self, forKey: .usesLanguageCorrection) ?? defaults.usesLanguageCorrection
        renderScale = try container.decodeIfPresent(Double.self, forKey: .renderScale) ?? defaults.renderScale
        maxPixelDimension = try container.decodeIfPresent(Int.self, forKey: .maxPixelDimension) ?? defaults.maxPixelDimension
    }
}

public enum ConfigError: Error, LocalizedError, Equatable {
    case missing(URL)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let url): return "No config at \(url.path). Run `inkrelay init` to create one."
        case .invalid(let message): return message
        }
    }
}

enum PathExpansion {
    /// Expands a leading `~` to the user's home folder.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

extension Array where Element: Hashable {
    func firstDuplicate() -> Element? {
        var seen = Set<Element>()
        for element in self where !seen.insert(element).inserted {
            return element
        }
        return nil
    }
}
