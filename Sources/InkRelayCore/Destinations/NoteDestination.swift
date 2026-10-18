import Foundation

/// A notes app InkRelay writes into.
public protocol NoteDestination {
    var id: String { get }

    /// Creates the note, or updates it in place when `previous` says it was sent before.
    /// Returns the destination's handle for the note, stored for the next update.
    /// After a rename `previous` belongs to the old path, so the note should move rather than be duplicated.
    func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String

    /// The export behind `record` was deleted. Never called with `.keep`.
    func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws
}

extension NoteDestination {
    /// Destinations that can't remove anything keep the note.
    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {}
}

/// What destinations need beyond their own config: where tokens live, how to reach the network, how to run AppleScript.
public struct DestinationContext {
    public var supportDirectory: URL
    public var transport: HTTPTransport
    public var scriptRunner: AppleScriptRunner
    public var google: GoogleAccountConfig?
    public var microsoft: MicrosoftAccountConfig?
    public var now: () -> Date
    public var secrets: SecretStore

    public init(
        supportDirectory: URL = InkRelayCore.supportDirectory,
        transport: HTTPTransport = URLSessionTransport(),
        scriptRunner: AppleScriptRunner = OSAScriptRunner(),
        google: GoogleAccountConfig? = nil,
        microsoft: MicrosoftAccountConfig? = nil,
        secrets: SecretStore = KeychainStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.supportDirectory = supportDirectory
        self.transport = transport
        self.scriptRunner = scriptRunner
        self.google = google
        self.microsoft = microsoft
        self.secrets = secrets
        self.now = now
    }

    public init(config: RelayConfig, supportDirectory: URL) {
        self.init(supportDirectory: supportDirectory, google: config.google, microsoft: config.microsoft)
    }

    public var reviewDirectory: URL { supportDirectory.appendingPathComponent("review", isDirectory: true) }
}

public enum DestinationFactory {
    public static func make(_ configs: [DestinationConfig], scriptRunner: AppleScriptRunner = OSAScriptRunner()) -> [NoteDestination] {
        make(configs, context: DestinationContext(scriptRunner: scriptRunner))
    }

    /// One Google and one Microsoft account are shared by all their destinations, so each refreshes its token once.
    public static func make(_ configs: [DestinationConfig], context: DestinationContext) -> [NoteDestination] {
        var googleAccount: GoogleAccount?
        var microsoftAccount: MicrosoftAccount?
        func google() -> GoogleAccount {
            if let googleAccount { return googleAccount }
            let made = GoogleAccount(config: context.google, supportDirectory: context.supportDirectory, transport: context.transport, now: context.now)
            googleAccount = made
            return made
        }
        func microsoft() -> MicrosoftAccount {
            if let microsoftAccount { return microsoftAccount }
            let made = MicrosoftAccount(config: context.microsoft, supportDirectory: context.supportDirectory, transport: context.transport, now: context.now)
            microsoftAccount = made
            return made
        }
        return configs.map { config -> NoteDestination in
            switch config {
            case .obsidian(let obsidian):
                return ObsidianDestination(config: obsidian, archive: NoteArchive(directory: context.supportDirectory.appendingPathComponent("archive", isDirectory: true)))
            case .appleNotes(let notes):
                return AppleNotesDestination(config: notes, runner: context.scriptRunner)
            case .appleCalendar(let calendar):
                return AppleCalendarDestination(config: calendar, runner: context.scriptRunner)
            case .googleCalendar(let calendar):
                return GoogleCalendarDestination(config: calendar, account: google())
            case .googleDocs(let docs):
                return GoogleDocsDestination(config: docs, account: google())
            case .outlookCalendar(let calendar):
                return OutlookCalendarDestination(config: calendar, account: microsoft())
            case .oneNote(let oneNote):
                return OneNoteDestination(config: oneNote, account: microsoft())
            case .reviewStack(let stack):
                return ReviewStackDestination(config: stack, store: ReviewStore(directory: context.reviewDirectory), now: context.now)
            case .notion(let notion):
                return NotionDestination(config: notion, secrets: context.secrets, transport: context.transport)
            case .appleReminders(let reminders):
                return AppleRemindersDestination(config: reminders, runner: context.scriptRunner)
            }
        }
    }

    /// Calendars that can take a confirmed event with a time.
    public static func eventWriters(in destinations: [NoteDestination]) -> [TimedEventWriter] {
        destinations.compactMap { $0 as? TimedEventWriter }
    }

    /// The destinations that also take planner to-dos.
    public static func plans(in destinations: [NoteDestination]) -> [PlanDestination] {
        destinations.compactMap { $0 as? PlanDestination }
    }
}

enum NoteFormatting {
    static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func hasText(_ note: InkNote) -> Bool {
        note.pages.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
