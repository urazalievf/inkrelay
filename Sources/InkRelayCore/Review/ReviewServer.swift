import Foundation

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
    private var server: LocalHTTPServer?

    public init(store: ReviewStore, config: DestinationConfig.ReviewStackConfig, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.config = config
        self.now = now
    }

    /// Starts listening and returns the page's address. `port` overrides the configured one (0 picks a free port).
    @discardableResult
    public func start(port: UInt16? = nil) throws -> URL {
        let server = try LocalHTTPServer(port: port ?? UInt16(config.port)) { [weak self] request in
            self?.route(request) ?? .text("Stopped", status: 503)
        }
        try server.start()
        self.server = server
        return server.baseURL
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    func route(_ request: HTTPRequest) -> HTTPResponse {
        guard Self.isLoopbackHost(request.headers["host"]) else { return .text("Forbidden", status: 403) }
        let parts = request.path.split(separator: "/").map(String.init)
        do {
            switch (request.method, parts.count) {
            case ("GET", 0):
                return .html(ReviewPage.html)
            case ("GET", 2) where parts == ["api", "stack"]:
                return try stackResponse()
            case ("GET", 2) where parts[0] == "images":
                let id = parts[1].hasSuffix(".jpg") ? String(parts[1].dropLast(4)) : ""
                guard Self.isCardID(id), let data = try? Data(contentsOf: store.imageURL(for: id)) else {
                    return .text("Not found", status: 404)
                }
                return HTTPResponse(status: 200, contentType: "image/jpeg", body: data, headers: ["Cache-Control": "private, max-age=86400"])
            case ("POST", 4) where parts[0] == "api" && parts[1] == "cards":
                guard request.headers["x-inkrelay"] == "1" else { return .text("Forbidden", status: 403) }
                guard Self.isCardID(parts[2]) else { return .text("Not found", status: 404) }
                let card: ReviewCard?
                switch parts[3] {
                case "done": card = try store.markDone(parts[2], now: now(), resurfaceDays: config.resurfaceDays)
                case "later": card = try store.snooze(parts[2], now: now())
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
