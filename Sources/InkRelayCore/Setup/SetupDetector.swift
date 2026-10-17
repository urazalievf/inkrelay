import Foundation

/// A tablet as setup offers it: the device name for notes, what it exports, and how to set the export up.
public struct TabletPreset: Equatable {
    public var name: String
    public var fileTypes: [String]
    public var exportHint: String
    /// Viwoods can skip the export folder entirely.
    public var hasCloudSource: Bool

    public static let all: [TabletPreset] = [
        TabletPreset(name: "Viwoods AiPaper", fileTypes: ["pdf"], exportHint: "Turn on Viwoods Cloud on the tablet, or long-press the cloud-sync button → Settings → Google Drive, OneDrive or Dropbox, format PDF.", hasCloudSource: true),
        TabletPreset(name: "reMarkable", fileTypes: ["pdf"], exportHint: "Settings → Integrations → Google Drive, Dropbox or OneDrive, then share notebooks there as PDF.", hasCloudSource: false),
        TabletPreset(name: "Supernote", fileTypes: ["pdf", "note"], exportHint: "Turn on Settings → Sync with Dropbox, Google Drive or OneDrive and pick its Note folder: InkRelay reads the .note notebooks themselves, no PDF export needed.", hasCloudSource: false),
        TabletPreset(name: "Boox", fileTypes: ["pdf", "png"], exportHint: "Share or auto-export notes as PDF or PNG to a cloud drive.", hasCloudSource: false),
        TabletPreset(name: "Kindle Scribe", fileTypes: ["pdf"], exportHint: "Share a notebook → Send to email: InkRelay can pick the PDF up from Mail. Or save the PDFs into a folder.", hasCloudSource: false),
        TabletPreset(name: "Other tablet", fileTypes: ["pdf"], exportHint: "Export PDFs into a folder on this Mac or in a synced cloud drive.", hasCloudSource: false),
    ]
}

/// A synced folder found on the Mac: Google Drive, Dropbox, OneDrive, Box or iCloud Drive.
public struct CloudFolder: Equatable {
    public var provider: String
    public var account: String
    public var url: URL
}

/// Finds what setup can offer without anyone typing paths: cloud drives, Obsidian vaults, Notes accounts.
public struct SetupDetector {
    public let home: URL
    private let fileManager: FileManager

    public init(home: URL = InkRelayCore.home, fileManager: FileManager = .default) {
        self.home = home
        self.fileManager = fileManager
    }

    /// Folders under `~/Library/CloudStorage`, plus iCloud Drive. Google Drive's root is its "My Drive" folder.
    public func cloudFolders() -> [CloudFolder] {
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let entries = ((try? fileManager.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var folders: [CloudFolder] = []
        for entry in entries {
            let name = entry.lastPathComponent
            let (provider, account): (String, String)
            if name.hasPrefix("GoogleDrive-") { (provider, account) = ("Google Drive", String(name.dropFirst("GoogleDrive-".count))) }
            else if name.hasPrefix("OneDrive-") { (provider, account) = ("OneDrive", String(name.dropFirst("OneDrive-".count))) }
            else if name.hasPrefix("Dropbox") { (provider, account) = ("Dropbox", name.hasPrefix("Dropbox-") ? String(name.dropFirst("Dropbox-".count)) : "") }
            else if name.hasPrefix("Box-") { (provider, account) = ("Box", String(name.dropFirst("Box-".count))) }
            else { continue }
            let myDrive = entry.appendingPathComponent("My Drive", isDirectory: true)
            let root = provider == "Google Drive" && fileManager.fileExists(atPath: myDrive.path) ? myDrive : entry
            folders.append(CloudFolder(provider: provider, account: account, url: root))
        }
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fileManager.fileExists(atPath: iCloud.path) {
            folders.append(CloudFolder(provider: "iCloud Drive", account: "", url: iCloud))
        }
        return folders
    }

    /// Vaults Obsidian knows, from its own `obsidian.json`, most recently opened first.
    public func obsidianVaults() -> [URL] {
        let file = home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values
            .sorted { ($0["ts"] as? Double ?? 0) > ($1["ts"] as? Double ?? 0) }
            .compactMap { ($0["path"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Notes account names. macOS asks once for permission to control Notes.
    public static func notesAccounts(runner: AppleScriptRunner = OSAScriptRunner()) throws -> [String] {
        let reply = try runner.run(#"tell application "Notes" to get name of every account"#, arguments: [])
        return reply.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Writes `~` for the home folder, so configs stay readable and portable.
    public func tilde(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }
}

/// What the user picked in `inkrelay setup`, turned into a config.
public struct SetupChoices: Equatable {
    public var tablet: TabletPreset
    public var useViwoodsCloud: Bool
    public var exportFolder: String?
    public var obsidianVault: String?
    public var appleNotesAccount: String??
    public var appleCalendar: Bool
    public var appleReminders: Bool
    public var reviewStack: Bool
    /// Share what's filed into Notes with InkRelay on an iPhone or iPad, through iCloud Drive.
    public var shareWithPhone: Bool
    /// Pick up notebooks a Kindle Scribe emails, from Mail.
    public var kindleMail: Bool = false

    public init(tablet: TabletPreset, useViwoodsCloud: Bool = false, exportFolder: String? = nil, obsidianVault: String? = nil,
                appleNotesAccount: String?? = nil, appleCalendar: Bool = false, appleReminders: Bool = false, reviewStack: Bool = true,
                shareWithPhone: Bool = false) {
        self.tablet = tablet
        self.useViwoodsCloud = useViwoodsCloud
        self.exportFolder = exportFolder
        self.obsidianVault = obsidianVault
        self.appleNotesAccount = appleNotesAccount
        self.appleCalendar = appleCalendar
        self.appleReminders = appleReminders
        self.reviewStack = reviewStack
        self.shareWithPhone = shareWithPhone
    }

    public func config() throws -> RelayConfig {
        var sources: [SourceConfig] = []
        if let exportFolder {
            let id = ObsidianDestination.safeFileName(tablet.name.lowercased().replacingOccurrences(of: " ", with: "-"))
            sources.append(SourceConfig(id: id, device: tablet.name, path: exportFolder, fileTypes: tablet.fileTypes))
        }
        var destinations: [DestinationConfig] = []
        if let obsidianVault { destinations.append(.obsidian(.init(id: "obsidian", vaultPath: obsidianVault))) }
        if let account = appleNotesAccount { destinations.append(.appleNotes(.init(id: "apple-notes", account: account))) }
        if appleCalendar { destinations.append(.appleCalendar(.init(id: "apple-calendar"))) }
        if appleReminders { destinations.append(.appleReminders(.init(id: "apple-reminders"))) }
        if reviewStack { destinations.append(.reviewStack(.init(id: "review"))) }
        let config = RelayConfig(
            sources: sources,
            destinations: destinations,
            viwoodsCloud: useViwoodsCloud ? ViwoodsCloudConfig(device: tablet.name) : nil,
            sharedLedger: shareWithPhone && appleNotesAccount != nil ? SharedLedgerConfig() : nil,
            kindleMail: kindleMail ? KindleMailConfig() : nil
        )
        try config.validate()
        return config
    }
}
