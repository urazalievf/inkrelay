import Foundation

/// The `kindleMail` section of the config: notebooks a Kindle Scribe shares by email.
public struct KindleMailConfig: Codable, Equatable {
    /// Doubles as the source id.
    public var id: String
    public var device: String
    /// Only messages whose sender contains this are read.
    public var sender: String
    /// How far back to look.
    public var lookbackDays: Int
    /// Mail is asked at most this often.
    public var checkEveryMinutes: Int
    /// Defaults to `~/Library/Application Support/InkRelay/kindle`.
    public var cachePath: String?

    public init(id: String = "kindle-scribe", device: String = "Kindle Scribe", sender: String = "amazon", lookbackDays: Int = 14, checkEveryMinutes: Int = 15, cachePath: String? = nil) {
        self.id = id
        self.device = device
        self.sender = sender
        self.lookbackDays = lookbackDays
        self.checkEveryMinutes = checkEveryMinutes
        self.cachePath = cachePath
    }

    private enum CodingKeys: String, CodingKey { case id, device, sender, lookbackDays, checkEveryMinutes, cachePath }

    public init(from decoder: Decoder) throws {
        let defaults = KindleMailConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? defaults.id
        device = try container.decodeIfPresent(String.self, forKey: .device) ?? defaults.device
        sender = try container.decodeIfPresent(String.self, forKey: .sender) ?? defaults.sender
        lookbackDays = try container.decodeIfPresent(Int.self, forKey: .lookbackDays) ?? defaults.lookbackDays
        checkEveryMinutes = try container.decodeIfPresent(Int.self, forKey: .checkEveryMinutes) ?? defaults.checkEveryMinutes
        cachePath = try container.decodeIfPresent(String.self, forKey: .cachePath)
    }

    public var cacheURL: URL {
        if let cachePath { return URL(fileURLWithPath: PathExpansion.expand(cachePath), isDirectory: true) }
        return InkRelayCore.supportDirectory.appendingPathComponent("kindle", isDirectory: true)
    }

    public var source: SourceConfig {
        var source = SourceConfig(id: id, device: device, path: cacheURL.path, fileTypes: ["pdf"])
        source.waitsForSettle = false
        return source
    }
}

/// Collects the PDFs a Kindle Scribe emails when a notebook is shared ("Share → Send to email"), whether
/// attached or behind a download link, into a folder the relay reads like any export. It asks Mail only for
/// recent messages from Amazon that mention Kindle, and remembers which messages it has handled.
public final class KindleMailPuller {
    public let config: KindleMailConfig
    private let runner: AppleScriptRunner
    private let transport: HTTPTransport
    private let now: () -> Date
    private var lastCheck: Date?

    public init(config: KindleMailConfig, runner: AppleScriptRunner = OSAScriptRunner(), transport: HTTPTransport = URLSessionTransport(), now: @escaping () -> Date = Date.init) {
        self.config = config
        self.runner = runner
        self.transport = transport
        self.now = now
    }

    var ledgerURL: URL { config.cacheURL.appendingPathComponent(".handled.json") }

    struct Message: Equatable {
        var id: String
        var subject: String
        var content: String
    }

    /// Returns how many notebooks were saved and any problems. Does nothing until `checkEveryMinutes` has passed.
    public func pull() -> (saved: Int, failures: [String]) {
        if let lastCheck, now().timeIntervalSince(lastCheck) < Double(config.checkEveryMinutes * 60) { return (0, []) }
        lastCheck = now()
        var failures: [String] = []
        var saved = 0
        do {
            try FileManager.default.createDirectory(at: config.cacheURL, withIntermediateDirectories: true)
            var handled = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: ledgerURL))) ?? [])
            let listing = try runner.run(Self.listScript, arguments: [config.sender, String(config.lookbackDays)])
            for message in Self.messages(in: listing) where !handled.contains(message.id) {
                let title = Self.title(fromSubject: message.subject)
                do {
                    if try save(message, title: title) { saved += 1 }
                    handled.insert(message.id)
                } catch {
                    failures.append("\"\(title)\": \(error.localizedDescription)")
                }
            }
            try JSONEncoder().encode(handled.sorted()).write(to: ledgerURL, options: .atomic)
        } catch {
            failures.append("Mail: \(error.localizedDescription)")
        }
        return (saved, failures)
    }

    /// Saves the message's PDF, attached or linked. False when the message has no notebook in it.
    private func save(_ message: Message, title: String) throws -> Bool {
        let destination = config.cacheURL.appendingPathComponent(ObsidianDestination.safeFileName(title) + ".pdf")
        let attached = try runner.run(Self.saveAttachmentScript, arguments: [message.id, destination.path])
        if attached == "saved" { return true }
        for link in Self.links(in: message.content).prefix(5) {
            var request = URLRequest(url: link)
            request.setValue("InkRelay/\(InkRelayCore.version)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try transport.send(request)
            // Download links redirect to the file; anything else (a help page, an unsubscribe link) isn't a PDF.
            guard response.statusCode == 200, data.starts(with: Data("%PDF".utf8)) else { continue }
            try data.write(to: destination, options: .atomic)
            return true
        }
        return false
    }

    static func messages(in listing: String) -> [Message] {
        listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, !fields[0].isEmpty else { return nil }
            return Message(id: fields[0], subject: fields[1], content: fields[2])
        }
    }

    /// `You sent a file "Ideas" from your Kindle` → `Ideas`.
    static func title(fromSubject subject: String) -> String {
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] {
            if let start = subject.range(of: open), let end = subject.range(of: close, range: start.upperBound..<subject.endIndex), start.upperBound < end.lowerBound {
                return String(subject[start.upperBound..<end.lowerBound])
            }
        }
        return subject.isEmpty ? "Kindle notebook" : subject
    }

    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            .filter { !$0.absoluteString.lowercased().contains("unsubscribe") && !$0.absoluteString.lowercased().contains("help") }
    }

    /// Recent messages from the sender that mention Kindle, one per line: id, subject, text with line breaks flattened.
    static let listScript = """
    on run argv
        set senderHint to item 1 of argv
        set cutoff to (current date) - ((item 2 of argv) as integer) * days
        set output to ""
        tell application "Mail"
            set found to (every message of inbox whose date received > cutoff and sender contains senderHint and subject contains "Kindle")
            repeat with theMessage in found
                set output to output & (message id of theMessage) & tab & my flatten(subject of theMessage) & tab & my flatten(content of theMessage) & linefeed
            end repeat
        end tell
        return output
    end run

    on flatten(theText)
        set AppleScript's text item delimiters to {return, linefeed, tab}
        set pieces to text items of theText
        set AppleScript's text item delimiters to " "
        set flat to pieces as text
        set AppleScript's text item delimiters to ""
        return flat
    end flatten
    """

    /// Saves the first PDF attached to the message; answers "saved" or "none".
    static let saveAttachmentScript = """
    on run argv
        set messageID to item 1 of argv
        set targetPath to item 2 of argv
        tell application "Mail"
            set matches to (every message of inbox whose message id is messageID)
            if (count of matches) is 0 then return "none"
            repeat with theAttachment in mail attachments of (item 1 of matches)
                if name of theAttachment ends with ".pdf" then
                    save theAttachment in (POSIX file targetPath)
                    return "saved"
                end if
            end repeat
        end tell
        return "none"
    end run
    """
}
