import Foundation

/// Each note as a Notion page under a parent page or in a database: the title, the page images and the
/// recognized text. Updated in place by page id. The integration token lives in the Keychain.
///
/// Notion can't replace a page's content in one call, so an update clears the page's blocks and writes them again.
/// Anything added to the page in Notion is replaced too; comments and properties stay.
public final class NotionDestination: NoteDestination {
    public static let version = "2022-06-28"
    static let api = URL(string: "https://api.notion.com/v1/")!
    static let loginCommand = "inkrelay notion login"
    public static let keychainAccount = "notion"
    /// Notion's limits: 2,000 characters per text object, 100 blocks per request.
    static let textLimit = 2000
    static let blocksPerRequest = 100

    public let config: DestinationConfig.NotionConfig
    let client: AuthorizedClient
    private let renderImages: (URL) -> [Data]
    private var titleProperty: String?

    public init(
        config: DestinationConfig.NotionConfig,
        secrets: SecretStore = KeychainStore(),
        transport: HTTPTransport = URLSessionTransport(),
        renderImages: @escaping (URL) -> [Data] = { (try? PageImages.jpegs(for: $0, maxPixelDimension: 1600)) ?? [] }
    ) {
        self.config = config
        self.renderImages = renderImages
        client = AuthorizedClient(
            service: "Notion",
            transport: transport,
            tokens: StoredToken(service: "Notion", account: Self.keychainAccount, loginCommand: Self.loginCommand, store: secrets)
        )
    }

    public var id: String { config.id }

    private func call(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil, contentType: String? = nil, allowing: Set<Int> = []) throws -> (status: Int, object: [String: Any]) {
        try client.call(method, Self.api.appendingPathComponent(path), json: json, body: body, contentType: contentType, headers: ["Notion-Version": Self.version], allowing: allowing)
    }

    public func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String {
        let blocks = try Self.blocks(for: note, images: config.includeImages ? uploadImages(of: note) : [])
        let titleKey = try self.titleKey()
        let properties: [String: Any] = [titleKey: ["title": [["text": ["content": String(note.title.prefix(Self.textLimit))]]]]]

        if let previous, !previous.externalID.isEmpty {
            let (status, page) = try call("PATCH", "pages/\(pathSegment(previous.externalID))", json: ["properties": properties], allowing: [404])
            // Archived (trashed) pages can't be edited; make a new one instead.
            if status == 200, page["archived"] as? Bool != true, page["in_trash"] as? Bool != true {
                try replaceChildren(of: previous.externalID, with: blocks)
                return previous.externalID
            }
        }

        let parent: [String: Any] = config.databaseId.map { ["database_id": $0] } ?? ["page_id": config.parentPageId ?? ""]
        let (_, created) = try call("POST", "pages", json: [
            "parent": parent,
            "properties": properties,
            "children": Array(blocks.prefix(Self.blocksPerRequest)),
        ])
        guard let pageID = created["id"] as? String else { throw CloudAPIError.unexpected("Notion", "no page id") }
        if blocks.count > Self.blocksPerRequest {
            try append(Array(blocks.dropFirst(Self.blocksPerRequest)), to: pageID)
        }
        return pageID
    }

    /// Archive and delete both move the page to Notion's trash, where it can be restored.
    public func remove(_ record: DestinationRecord, export: RemovedExport, policy: RemovalPolicy) throws {
        guard policy != .keep, !record.externalID.isEmpty else { return }
        _ = try call("PATCH", "pages/\(pathSegment(record.externalID))", json: ["archived": true], allowing: [404])
    }

    /// Checks the token and returns the integration's name.
    public func whoAmI() throws -> String {
        let (_, me) = try call("GET", "users/me")
        return me["name"] as? String ?? "your integration"
    }

    private func titleKey() throws -> String {
        guard let database = config.databaseId else { return "title" }
        if let titleProperty { return titleProperty }
        let (_, schema) = try call("GET", "databases/\(pathSegment(database))")
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        guard let name = properties.first(where: { $0.value["type"] as? String == "title" })?.key else {
            throw CloudAPIError.unexpected("Notion", "the database has no title property")
        }
        titleProperty = name
        return name
    }

    private func replaceChildren(of pageID: String, with blocks: [[String: Any]]) throws {
        var cursor: String?
        var existing: [String] = []
        repeat {
            var components = URLComponents(url: Self.api.appendingPathComponent("blocks/\(pathSegment(pageID))/children"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "page_size", value: "100")] + (cursor.map { [URLQueryItem(name: "start_cursor", value: $0)] } ?? [])
            let (_, list) = try client.call("GET", components.url!, headers: ["Notion-Version": Self.version])
            existing += (list["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            cursor = (list["has_more"] as? Bool == true) ? list["next_cursor"] as? String : nil
        } while cursor != nil
        for block in existing {
            _ = try call("DELETE", "blocks/\(pathSegment(block))", allowing: [404])
        }
        try append(blocks, to: pageID)
    }

    private func append(_ blocks: [[String: Any]], to pageID: String) throws {
        var start = 0
        while start < blocks.count {
            let chunk = Array(blocks[start..<min(start + Self.blocksPerRequest, blocks.count)])
            _ = try call("PATCH", "blocks/\(pathSegment(pageID))/children", json: ["children": chunk])
            start += Self.blocksPerRequest
        }
    }

    /// Uploads each page image with Notion's file upload API and returns the upload ids, in page order.
    /// A failed upload drops that image rather than the note.
    private func uploadImages(of note: InkNote) throws -> [String?] {
        renderImages(note.originalURL).enumerated().map { index, jpeg in
            do {
                let (_, upload) = try call("POST", "file_uploads", json: ["filename": "page-\(index + 1).jpg", "content_type": "image/jpeg"])
                guard let uploadID = upload["id"] as? String else { return nil }
                let boundary = "inkrelay-" + UUID().uuidString
                var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"page-\(index + 1).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
                body += jpeg
                body += Data("\r\n--\(boundary)--\r\n".utf8)
                _ = try call("POST", "file_uploads/\(pathSegment(uploadID))/send", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
                return uploadID
            } catch {
                return nil
            }
        }
    }

    static func blocks(for note: InkNote, images: [String?]) throws -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for page in note.pages {
            if note.pages.count > 1 { blocks.append(textBlock("heading_2", "Page \(page.number)")) }
            if page.number <= images.count, let upload = images[page.number - 1] {
                blocks.append(["object": "block", "type": "image", "image": ["type": "file_upload", "file_upload": ["id": upload]]])
            }
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            for paragraph in text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
                for chunk in chunks(paragraph, size: textLimit) { blocks.append(textBlock("paragraph", chunk)) }
            }
        }
        if !NoteFormatting.hasText(note) { blocks.append(textBlock("paragraph", "No text recognized.")) }
        blocks.append(textBlock("paragraph", "From \(note.device): \(note.relativePath). Synced by InkRelay.", italic: true))
        return blocks
    }

    static func textBlock(_ type: String, _ content: String, italic: Bool = false) -> [String: Any] {
        var text: [String: Any] = ["type": "text", "text": ["content": content]]
        if italic { text["annotations"] = ["italic": true, "color": "gray"] }
        return ["object": "block", "type": type, type: ["rich_text": [text]]]
    }

    static func chunks(_ text: String, size: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            pieces.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return pieces
    }
}
