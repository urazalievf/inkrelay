import Foundation
import Security

/// Serves the read-later stack at http://127.0.0.1:<port>: the card page, the stack as JSON,
/// page images, and the Done / Later actions.
///
/// It listens on the loopback interface only. Requests whose Host isn't 127.0.0.1 or localhost are refused,
/// which blocks DNS-rebinding pages, and actions need an `X-InkRelay` header, which a page on another
/// site can't send without a CORS preflight this server never approves.
public final class ReviewServer {
    public let store: ReviewStore
    public let config: DestinationConfig.ReviewStackConfig
    private let now: () -> Date
    private let calendars: [TimedEventWriter]
    private var server: LocalHTTPServer?

    /// `calendars` receive suggested events the user accepts.
    public init(store: ReviewStore, config: DestinationConfig.ReviewStackConfig, calendars: [TimedEventWriter] = [], now: @escaping () -> Date = Date.init) {
        self.store = store
        self.config = config
        self.calendars = calendars
        self.now = now
        key = Self.randomKey()
    }

    /// A new key every launch. The page gets it in its address's fragment, which browsers never send, and sends it
    /// back on every API call; other processes on the Mac, and other users of it, don't have it.
    public private(set) var key: String

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Where the key is kept for `inkrelay review open` when another process is already serving the stack.
    public static func keyURL(in store: ReviewStore) -> URL { store.directory.appendingPathComponent(".key") }

    /// The page's address with the key, for opening it.
    public static func pageURL(base: URL, key: String) -> URL {
        URL(string: base.absoluteString + "#k=" + key) ?? base
    }

    /// Starts listening and returns the page's address, with the key in its fragment. Log `url.withoutFragment`,
    /// never this. `port` overrides the configured one (0 picks a free port).
    @discardableResult
    public func start(port: UInt16? = nil) throws -> URL {
        key = Self.randomKey()
        let server = try LocalHTTPServer(port: port ?? UInt16(config.port)) { [weak self] request in
            self?.route(request) ?? .text("Stopped", status: 503)
        }
        try server.start()
        self.server = server
        let keyFile = Self.keyURL(in: store)
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        if FileManager.default.createFile(atPath: keyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) == false {
            try? Data(key.utf8).write(to: keyFile, options: .atomic)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        return Self.pageURL(base: server.baseURL, key: key)
    }

    /// Constant time, so the key can't be guessed a character at a time.
    static func matches(_ given: String?, _ key: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(key.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    func route(_ request: HTTPRequest) -> HTTPResponse {
        guard Self.isLoopbackHost(request.headers["host"]) else { return .text("Forbidden", status: 403) }
        let parts = request.path.split(separator: "/").map(String.init)
        do {
            // The page itself is public; everything with a card in it needs the key.
            if parts.first == "api", !Self.matches(request.headers["x-inkrelay"], key) { return .text("Forbidden", status: 403) }
            if parts.first == "images", !Self.matches(request.query["k"], key) { return .text("Forbidden", status: 403) }
            switch (request.method, parts.count) {
            case ("GET", 0):
                var page = HTTPResponse.html(ReviewPage.html)
                page.headers["X-Frame-Options"] = "DENY"
                page.headers["Content-Security-Policy"] = "frame-ancestors 'none'"
                page.headers["Referrer-Policy"] = "no-referrer"
                return page
            case ("GET", 2) where parts == ["api", "stack"]:
                return try stackResponse()
            case ("GET", 2) where parts[0] == "images":
                let id = parts[1].hasSuffix(".jpg") ? String(parts[1].dropLast(4)) : ""
                guard Self.isCardID(id), let data = try? Data(contentsOf: store.imageURL(for: id)) else {
                    return .text("Not found", status: 404)
                }
                return HTTPResponse(status: 200, contentType: "image/jpeg", body: data, headers: ["Cache-Control": "private, max-age=86400"])
            case ("POST", 4) where parts[0] == "api" && parts[1] == "cards":
                guard Self.isCardID(parts[2]) else { return .text("Not found", status: 404) }
                let card: ReviewCard?
                switch parts[3] {
                case "done": card = try store.markDone(parts[2], now: now(), resurfaceDays: config.resurfaceDays)
                case "later": card = try store.snooze(parts[2], now: now())
                case "accept":
                    guard let event = try store.load().cards[parts[2]]?.event else { return .json(["ok": false, "error": "Not an event."], status: 404) }
                    guard !calendars.isEmpty else {
                        return .json(["ok": false, "error": "No calendar is set up. Add an appleCalendar, googleCalendar or outlookCalendar destination."], status: 409)
                    }
                    for calendar in calendars { _ = try calendar.addEvent(event) }
                    card = try store.markDone(parts[2], now: now(), resurfaceDays: [])
                default: return .text("Not found", status: 404)
                }
                guard let card else { return .json(["ok": false, "error": "No such card."], status: 404) }
                return .json(["ok": true, "status": card.status.rawValue, "dueAt": ISO8601DateFormatter().string(from: card.dueAt)])
            default:
                return .text("Not found", status: 404)
            }
        } catch {
            return .json(["ok": false, "error": error.localizedDescription], status: 500)
        }
    }

    private func stackResponse() throws -> HTTPResponse {
        let (cards, due) = try store.stack(now: now(), limit: config.dailyLimit)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return .json([
            "date": formatter.string(from: now()),
            "due": due,
            "limit": config.dailyLimit,
            "calendars": calendars.map(\.id),
            "cards": cards.map { card -> [String: Any] in
                [
                    "id": card.id,
                    "kind": card.kind.rawValue,
                    "title": card.title,
                    "subtitle": card.subtitle,
                    "text": card.text,
                    "status": card.status.rawValue,
                    "reviews": card.reviews,
                    // The hash in the query busts the browser cache when a page's ink changes.
                    "image": card.hasImage ? "/images/\(card.id).jpg?v=\(card.contentHash.prefix(8))" : NSNull(),
                ]
            },
        ])
    }

    static func isCardID(_ text: String) -> Bool {
        text.count == 16 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let name: Substring
        if host.hasPrefix("[") {
            name = host.dropFirst().prefix { $0 != "]" }
        } else {
            name = host.split(separator: ":", maxSplits: 1).first ?? ""
        }
        return ["127.0.0.1", "localhost", "::1"].contains(String(name))
    }
}
