import Foundation

/// InkRelay as a Model Context Protocol server over stdio, so an AI assistant (any MCP client) can find,
/// read and act on the user's handwritten notes: search what was written,
/// pull out tasks, work through the review stack, sync, and send reading to the tablet.
///
/// Newline-delimited JSON-RPC 2.0 on stdin and stdout; nothing else is ever written to stdout.
/// Everything stays on the Mac: the server reads InkRelay's local archive and state.
public final class MCPServer {
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public typealias Sync = (RelayConfig, URL) throws -> SyncReport
    public typealias Send = (_ config: RelayConfig, _ input: String, _ target: String?, _ title: String?) throws -> String

    let configURL: URL
    let now: () -> Date
    let sync: Sync
    let send: Send?

    public init(configURL: URL, now: @escaping () -> Date = Date.init, sync: Sync? = nil, send: Send? = nil) {
        self.configURL = configURL
        self.now = now
        self.sync = sync ?? { config, stateURL in try RelayEngine.live(config: config, stateURL: stateURL).syncOnce() }
        self.send = send ?? Self.defaultSend
    }

    var supportDirectory: URL { configURL.deletingLastPathComponent() }
    var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    var archive: NoteArchive { NoteArchive(directory: supportDirectory.appendingPathComponent("archive", isDirectory: true)) }

    // MARK: Transport

    /// Serves until stdin closes.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard let reply = handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    /// One message in, at most one message out (notifications get no reply).
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Self.encode(Self.error(id: NSNull(), code: -32700, message: "Parse error: not a JSON object"))
        }
        return handle(message).map { Self.encode($0) }
    }

    func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : Self.error(id: id!, code: -32600, message: "Invalid request: no method")
        }
        // Notifications (no id) never get a reply.
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return Self.result(id: id, [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "inkrelay", "title": "InkRelay", "version": InkRelayCore.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Self.tools.map(\.definition)])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = Self.tools.first(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "(none)")")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let output = try tool.run(self, arguments)
                return Self.result(id: id, [
                    "content": [["type": "text", "text": Self.encode(output, pretty: true)]],
                    "structuredContent": output,
                ])
            } catch {
                return Self.result(id: id, [
                    "content": [["type": "text", "text": "Error: " + error.localizedDescription]],
                    "isError": true,
                ])
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static let instructions = """
    InkRelay relays handwritten notes from e-ink tablets (Viwoods, Supernote, reMarkable, Boox, Kindle Scribe) into \
    the user's notes apps, and keeps the recognized text of every note locally. Use inkrelay_search_notes to find \
    notes by what was written, then inkrelay_get_note for the full text. inkrelay_list_tasks lists the to-dos written \
    on pages. inkrelay_review_stack and inkrelay_review_card work through the read-later stack. inkrelay_sync_now picks \
    up new pages, and inkrelay_send_to_tablet sends an article or document to the tablet. Recognized text comes from \
    handwriting, so expect misread words.
    """

    static func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// Compact JSON never contains a raw newline, which the stdio framing requires.
    static func encode(_ object: Any, pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Helpers for tools

    func config() throws -> RelayConfig {
        do {
            return try ConfigStore.load(from: configURL)
        } catch {
            throw MCPToolError("InkRelay isn't set up at \(configURL.path): \(error.localizedDescription) Run `inkrelay setup` first.")
        }
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func page<T>(_ items: [T], _ arguments: [String: Any], defaultLimit: Int, maxLimit: Int = 100) -> (slice: [T], meta: [String: Any]) {
        let limit = min(max(arguments["limit"] as? Int ?? defaultLimit, 1), maxLimit)
        let offset = max(arguments["offset"] as? Int ?? 0, 0)
        let slice = offset < items.count ? Array(items[offset..<min(offset + limit, items.count)]) : []
        var meta: [String: Any] = ["total_count": items.count, "count": slice.count, "offset": offset, "has_more": offset + slice.count < items.count]
        if offset + slice.count < items.count { meta["next_offset"] = offset + slice.count }
        return (slice, meta)
    }

    static func snippet(_ text: String, around query: String? = nil, length: Int = 180) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let query, let hit = flat.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return flat.count > length ? String(flat.prefix(length - 1)) + "…" : flat
        }
        let start = flat.index(hit.lowerBound, offsetBy: -min(60, flat.distance(from: flat.startIndex, to: hit.lowerBound)))
        let end = flat.index(start, offsetBy: min(length, flat.distance(from: start, to: flat.endIndex)))
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    func notes(source: String?) -> [ArchivedNote] {
        let all = archive.all()
        guard let source, !source.isEmpty else { return all }
        return all.filter { $0.sourceID == source }
    }

    func summary(_ note: ArchivedNote) -> [String: Any] {
        [
            "id": note.id, "title": note.title, "source": note.sourceID, "device": note.device,
            "path": note.relativePath, "modified": Self.iso(note.modified), "pages": note.pages.count,
            "preview": Self.snippet(note.text, length: 160),
        ]
    }

    #if os(macOS)
    static let defaultSend: Send? = { config, input, target, title in
        guard let chosen = target.map({ id in config.sendTargets.first { $0.id == id } }) ?? config.sendTargets.first else {
            throw MCPToolError(target == nil
                ? "No send targets are configured. Add \"sendTargets\" to the config (a folder, kindle or viwoodsCloud)."
                : "No send target \"\(target!)\". Known: \(config.sendTargets.map(\.id).joined(separator: ", ")).")
        }
        let tokenURL = RelayEngine.tokenURL(besideState: InkRelayCore.defaultStateURL)
        let sender = Sender(viwoods: { ViwoodsClient(credentials: FileCredentialStore(url: tokenURL)) })
        return try sender.deliver(try sender.prepare(input, title: title), to: chosen)
    }
    #else
    static let defaultSend: Send? = nil
    #endif
}

public struct MCPToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
