import Foundation
import Network

/// A small HTTP/1.1 server on the loopback interface only. It serves the review stack page
/// and catches Google's sign-in redirect. One request per connection; no keep-alive, no TLS.
public final class LocalHTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "inkrelay.local-http")
    private let handler: Handler
    public private(set) var port: UInt16 = 0

    /// `port` 0 lets the system pick a free one; read `port` after `start()`.
    public init(port: UInt16 = 0, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        if port == 0 {
            listener = try NWListener(using: parameters)
        } else {
            guard let fixed = NWEndpoint.Port(rawValue: port) else { throw LocalHTTPServerError.cannotListen("bad port \(port)") }
            listener = try NWListener(using: parameters, on: fixed)
        }
        self.handler = handler
    }

    deinit { listener.cancel() }

    public func start(timeout: TimeInterval = 5) throws {
        let settled = DispatchSemaphore(value: 0)
        var failure: Error?
        var signalled = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = self.listener.port?.rawValue ?? 0
            case .failed(let error), .waiting(let error):
                failure = error
            default:
                return
            }
            if !signalled {
                signalled = true
                settled.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard settled.wait(timeout: .now() + timeout) == .success else { throw LocalHTTPServerError.cannotListen("timed out") }
        if let failure {
            listener.cancel()
            throw LocalHTTPServerError.cannotListen(failure.localizedDescription)
        }
    }

    public func stop() {
        listener.cancel()
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                if let request = try HTTPRequest.parse(buffer) {
                    self.respond(self.handler(request), on: connection)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            } catch {
                self.respond(.text("Bad request", status: 400), on: connection)
            }
        }
    }

    private func respond(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}

public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    /// One request from the bytes received so far, or nil when more are needed.
    static func parse(_ received: Data) throws -> HTTPRequest? {
        let data = Data(received)
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeaderBytes { throw LocalHTTPServerError.badRequest }
            return nil
        }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw LocalHTTPServerError.badRequest }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxBodyBytes else { throw LocalHTTPServerError.badRequest }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }

        guard let components = URLComponents(string: "http://localhost" + String(requestLine[1])) else {
            throw LocalHTTPServerError.badRequest
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components.path.isEmpty ? "/" : components.path,
            query: query,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length))
        )
    }
}

public struct HTTPResponse: Equatable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }

    public static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    public static func html(_ html: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var fields = headers
        fields["Content-Type"] = contentType
        fields["Content-Length"] = String(body.count)
        fields["Connection"] = "close"
        fields["Cache-Control"] = fields["Cache-Control"] ?? "no-store"
        fields["X-Content-Type-Options"] = "nosniff"
        for name in fields.keys.sorted() { head += "\(name): \(fields[name]!)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Status"
        }
    }
}

public enum LocalHTTPServerError: Error, LocalizedError, Equatable {
    case cannotListen(String)
    case badRequest

    public var errorDescription: String? {
        switch self {
        case .cannotListen(let reason): return "Couldn't start the local web server: \(reason)."
        case .badRequest: return "Malformed HTTP request."
        }
    }
}
