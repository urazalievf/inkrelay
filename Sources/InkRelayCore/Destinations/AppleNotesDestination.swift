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
        if let previous {
            // An empty result means the note was deleted in Notes, so a fresh one is created below.
            let updated = try runner.run(Self.updateScript, arguments: [previous.externalID, body])
            if !updated.isEmpty { return updated }
        }
        let created = try runner.run(Self.createScript, arguments: [config.folder, config.account ?? "", body])
        guard !created.isEmpty else { throw DestinationError.failed(id, "Notes didn't return an id for the new note") }
        return created
    }

    static let createScript = """
    on run argv
        set folderName to item 1 of argv
        set accountName to item 2 of argv
        set noteBody to item 3 of argv
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
            return id of newNote
        end tell
    end run
    """

    static let updateScript = """
    on run argv
        set noteID to item 1 of argv
        set noteBody to item 2 of argv
        tell application "Notes"
            if exists note id noteID then
                set body of note id noteID to noteBody
                return noteID
            end if
            return ""
        end tell
    end run
    """
}

/// Notes takes the first line of the HTML body as the note's title.
public enum AppleNotesHTML {
    public static func render(_ note: InkNote, syncedAt: Date = Date()) -> String {
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
    }
}
