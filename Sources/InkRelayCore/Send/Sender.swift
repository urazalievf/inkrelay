import Foundation
import PDFKit

/// Where `inkrelay send` delivers: a folder the tablet imports from, a Send-to-Kindle address, or Viwoods Cloud.
public enum SendTargetConfig: Codable, Equatable {
    case folder(id: String, path: String)
    /// Mail.app sends the file to the Kindle's address; that address must allow your sender in Amazon's settings.
    case kindle(id: String, address: String)
    case viwoodsCloud(id: String, app: ViwoodsImportTarget)

    public var id: String {
        switch self {
        case .folder(let id, _), .kindle(let id, _), .viwoodsCloud(let id, _): return id
        }
    }

    private enum Keys: String, CodingKey { case kind, id, path, address, app }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let id = try container.decode(String.self, forKey: .id)
        switch try container.decode(String.self, forKey: .kind) {
        case "folder": self = .folder(id: id, path: try container.decode(String.self, forKey: .path))
        case "kindle": self = .kindle(id: id, address: try container.decode(String.self, forKey: .address))
        case "viwoodsCloud": self = .viwoodsCloud(id: id, app: try container.decodeIfPresent(ViwoodsImportTarget.self, forKey: .app) ?? .learning)
        case let other: throw ConfigError.invalid("Unknown send target kind \"\(other)\". Use folder, kindle or viwoodsCloud.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        switch self {
        case .folder(_, let path):
            try container.encode("folder", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .kindle(_, let address):
            try container.encode("kindle", forKey: .kind)
            try container.encode(address, forKey: .address)
        case .viwoodsCloud(_, let app):
            try container.encode("viwoodsCloud", forKey: .kind)
            try container.encode(app, forKey: .app)
        }
    }
}

/// A file ready for the tablet.
public struct OutgoingFile: Equatable {
    public var fileName: String
    public var data: Data
    public var pageCount: Int
}

/// Turns a link or a file into something an e-ink tablet reads well, and delivers it.
public struct Sender {
    private let transport: HTTPTransport
    private let runner: AppleScriptRunner
    private let viwoods: () -> ViwoodsClient
    private let fileManager: FileManager

    public init(transport: HTTPTransport = URLSessionTransport(), runner: AppleScriptRunner = OSAScriptRunner(), viwoods: @escaping () -> ViwoodsClient, fileManager: FileManager = .default) {
        self.transport = transport
        self.runner = runner
        self.viwoods = viwoods
        self.fileManager = fileManager
    }

    /// Web pages become EPUB books; PDF and EPUB files go as they are; HTML, Markdown and text become EPUB.
    public func prepare(_ input: String, title: String? = nil) throws -> OutgoingFile {
        if let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            var article = try ArticleExtractor.fetch(url, transport: transport)
            if let title { article.title = title }
            return OutgoingFile(fileName: Self.fileName(article.title, "epub"), data: EPUBWriter.book(article), pageCount: 0)
        }
        let file = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        let ext = file.pathExtension.lowercased()
        let data = try Data(contentsOf: file)
        let name = title ?? file.deletingPathExtension().lastPathComponent
        switch ext {
        case "pdf":
            return OutgoingFile(fileName: Self.fileName(name, "pdf"), data: data, pageCount: PDFDocument(data: data)?.pageCount ?? 0)
        case "epub":
            return OutgoingFile(fileName: Self.fileName(name, "epub"), data: data, pageCount: 0)
        case "html", "htm", "xhtml":
            var article = try ArticleExtractor.extract(html: data, from: nil)
            article.title = title ?? article.title
            return OutgoingFile(fileName: Self.fileName(article.title, "epub"), data: EPUBWriter.book(article), pageCount: 0)
        case "md", "markdown", "txt", "text":
            let text = String(decoding: data, as: UTF8.self)
            let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let body = paragraphs.map { paragraph -> String in
                if paragraph.hasPrefix("#") {
                    let level = min(paragraph.prefix { $0 == "#" }.count + 1, 6)
                    return "<h\(level)>\(ArticleExtractor.escape(paragraph.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))</h\(level)>"
                }
                return "<p>" + ArticleExtractor.escape(paragraph).replacingOccurrences(of: "\n", with: "<br/>") + "</p>"
            }.joined(separator: "\n")
            let article = Article(title: name, byline: nil, sourceURL: nil, bodyXHTML: body, images: [])
            return OutgoingFile(fileName: Self.fileName(name, "epub"), data: EPUBWriter.book(article), pageCount: 0)
        default:
            throw SendError.unsupportedFile(ext)
        }
    }

    /// Delivers the file and says where it went.
    public func deliver(_ file: OutgoingFile, to target: SendTargetConfig) throws -> String {
        switch target {
        case .folder(_, let path):
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = Self.unusedURL(in: folder, for: file.fileName, fileManager: fileManager)
            try file.data.write(to: destination, options: .atomic)
            return "Saved \(destination.lastPathComponent) to \(folder.path). The tablet picks it up from there."
        case .kindle(_, let address):
            let temporary = fileManager.temporaryDirectory.appendingPathComponent("InkRelay-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
            let attachment = temporary.appendingPathComponent(file.fileName)
            try file.data.write(to: attachment)
            _ = try runner.run(Self.mailScript, arguments: [address, (file.fileName as NSString).deletingPathExtension, attachment.path])
            return "Mailed \(file.fileName) to \(address). It appears on the Kindle once Amazon has processed it."
        case .viwoodsCloud(_, let app):
            try viwoods().importFile(file.data, fileName: file.fileName, to: app, pageCount: file.pageCount)
            return "Uploaded \(file.fileName) to Viwoods Cloud (\(app == .learning ? "Learning" : "Paper")). It syncs to the tablet with Viwoods Cloud on."
        }
    }

    static func fileName(_ title: String, _ ext: String) -> String {
        let safe = ObsidianDestination.safeFileName(String(title.prefix(80)))
        return safe + "." + ext
    }

    static func unusedURL(in folder: URL, for name: String, fileManager: FileManager) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Sends one message with the file attached, in the background, from Mail's default account.
    static let mailScript = """
    on run argv
        set toAddress to item 1 of argv
        set theSubject to item 2 of argv
        set attachmentFile to (POSIX file (item 3 of argv)) as alias
        tell application "Mail"
            set theMessage to make new outgoing message with properties {subject:theSubject, content:"Sent by InkRelay." & return & return, visible:false}
            tell theMessage
                make new to recipient at end of to recipients with properties {address:toAddress}
                tell content to make new attachment with properties {file name:attachmentFile} at after the last paragraph
            end tell
            delay 1
            send theMessage
        end tell
    end run
    """
}
