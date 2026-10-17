import Foundation

/// Files notes into Apple Notes. Notes has no API, so this drives it with AppleScript,
/// which is why InkRelay has to run on a Mac. macOS asks once for permission to control Notes.
public struct AppleNotesDestination: NoteDestination {
    public var config: DestinationConfig.AppleNotesConfig
    private let runner: AppleScriptRunner

    public init(config: DestinationConfig.AppleNotesConfig, runner: AppleScriptRunner = OSAScriptRunner()) {
        self.config = config
        self.runner = runner
    }

    public var id: String { config.id }

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        let body = AppleNotesHTML.render(note)
        let attachment = config.attachOriginal ? note.originalURL.path : ""
        var reply = ""
        if let previous {
            // An empty result means the note was deleted in Notes, so a fresh one is created below.
            reply = try runner.run(Self.updateScript, arguments: [previous.externalID, body, attachment])
        }
        if Self.noteID(in: reply).isEmpty {
            reply = try runner.run(Self.createScript, arguments: [config.folder, config.account ?? "", body, attachment])
        }
        let noteID = Self.noteID(in: reply)
        guard !noteID.isEmpty else { throw DestinationError.failed(id, "Notes didn't return an id for the new note") }
        if !attachment.isEmpty, reply.hasSuffix("\nnot attached") {
            // This macOS won't attach files through AppleScript: link to the original instead.
            _ = try runner.run(Self.updateScript, arguments: [noteID, AppleNotesHTML.render(note, linkingOriginal: true), ""])
        }
        return noteID
    }

    /// Scripts answer with the note id on the first line and the attachment outcome on the second.
    static func noteID(in reply: String) -> String {
        String(reply.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// Delete puts the note in Recently Deleted; archive moves it to "<folder> Archive" in the same account.
    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        switch policy {
        case .keep: return
        case .delete: _ = try runner.run(Self.deleteScript, arguments: [record.externalID])
        case .archive: _ = try runner.run(Self.archiveScript, arguments: [record.externalID, config.folder + " Archive"])
        }
    }

    static let deleteScript = """
    on run argv
        tell application "Notes"
            if exists note id (item 1 of argv) then delete note id (item 1 of argv)
        end tell
    end run
    """

    static let archiveScript = """
    on run argv
        set noteID to item 1 of argv
        set folderName to item 2 of argv
        tell application "Notes"
            if not (exists note id noteID) then return
            set theNote to note id noteID
            set theAccount to account of container of theNote
            if not (exists folder folderName of theAccount) then
                make new folder at theAccount with properties {name:folderName}
            end if
            move theNote to folder folderName of theAccount
        end tell
    end run
    """

    /// Attaching uses `make new attachment`; any failure is reported back instead of failing the note.
    static let createScript = """
    on run argv
        set folderName to item 1 of argv
        set accountName to item 2 of argv
        set noteBody to item 3 of argv
        set attachmentPath to item 4 of argv
        set outcome to ""
        tell application "Notes"
            if accountName is "" then
                set targetAccount to default account
            else
                set targetAccount to account accountName
            end if
            if not (exists folder folderName of targetAccount) then
                make new folder at targetAccount with properties {name:folderName}
            end if
            set newNote to make new note at folder folderName of targetAccount with properties {body:noteBody}
            set noteID to id of newNote
        end tell
        if attachmentPath is not "" then set outcome to my attach(noteID, attachmentPath)
        return noteID & outcome
    end run
    \(attachHandler)
    """

    /// Notes in Recently Deleted still answer `exists`, so they count as gone and a fresh note is made.
    static let updateScript = """
    on run argv
        set noteID to item 1 of argv
        set noteBody to item 2 of argv
        set attachmentPath to item 3 of argv
        set outcome to ""
        tell application "Notes"
            if not (exists note id noteID) then return ""
            try
                if name of container of note id noteID is "Recently Deleted" then return ""
            end try
            set body of note id noteID to noteBody
        end tell
        if attachmentPath is not "" then set outcome to my attach(noteID, attachmentPath)
        return noteID & outcome
    end run
    \(attachHandler)
    """

    /// Replaces the note's copy of the original, so re-syncs don't pile up attachments.
    static let attachHandler = """
    on attach(noteID, attachmentPath)
        try
            set attachmentFile to (POSIX file attachmentPath) as alias
            tell application "System Events" to set attachmentName to name of attachmentFile
            tell application "Notes"
                try
                    delete (every attachment of note id noteID whose name is attachmentName)
                end try
                make new attachment at end of attachments of note id noteID with data attachmentFile
            end tell
            return ""
        on error
            return linefeed & "not attached"
        end try
    end attach
    """
}

/// Notes takes the first line of the HTML body as the note's title.
public enum AppleNotesHTML {
    public static func render(_ note: InkNote, syncedAt: Date = Date(), linkingOriginal: Bool = false) -> String {
        var html = "<h1>\(escape(note.title))</h1>"
        if !NoteFormatting.hasText(note) {
            html += "<div><i>No text recognized.</i></div>"
        }
        for page in note.pages {
            if note.pages.count > 1 {
                html += "<h2>Page \(page.number)</h2>"
            }
            let lines = page.text.split(separator: "\n", omittingEmptySubsequences: false)
            html += lines.map { $0.isEmpty ? "<div><br></div>" : "<div>\(escape(String($0)))</div>" }.joined()
        }
        let synced = NoteFormatting.timestamp.string(from: syncedAt)
        if linkingOriginal {
            html += "<div><br></div><div><a href=\"\(escape(note.originalURL.absoluteString))\">Open the original \(escape(note.originalURL.lastPathComponent))</a></div>"
        }
        html += "<div><br></div><div><i>From \(escape(note.device)): \(escape(note.relativePath)). Synced by InkRelay \(synced).</i></div>"
        return html
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Runs AppleScript source with arguments passed to its `on run argv` handler.
public protocol AppleScriptRunner {
    func run(_ source: String, arguments: [String]) throws -> String
}

/// Uses `/usr/bin/osascript`. Arguments go straight into argv, so note text never needs AppleScript escaping.
public struct OSAScriptRunner: AppleScriptRunner {
    public init() {}

    public func run(_ source: String, arguments: [String]) throws -> String {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DestinationError.failed("apple-notes", message.isEmpty ? "osascript exited with \(process.terminationStatus)" : message)
        }
        return String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw DestinationError.unavailable("apple", "Apple Notes, Calendar and Reminders are driven from the Mac; on iPhone use the Shortcuts actions")
        #endif
    }
}
