import CryptoKit
import Foundation
import Security

/// Access and refresh tokens for one signed-in account.
public struct OAuthTokens: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    func isFresh(at now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) > 60
    }
}

/// A Codable value kept in a file only the user can read, next to the config.
public struct SecretFile<Value: Codable> {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Hands out a valid access token, refreshing it when it's about to expire.
public protocol AccessTokenProvider: AnyObject {
    func accessToken() throws -> String
    /// Called after the API rejected the current token, so the next call refreshes it.
    func invalidate()
}

/// An OAuth sign-in kept alive with its refresh token. Shared by Google and Microsoft.
public final class OAuthSession: AccessTokenProvider {
    public let service: String
    let loginCommand: String
    private let store: SecretFile<OAuthTokens>
    private let refresher: (String) throws -> OAuthTokens
    private let now: () -> Date
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    init(service: String, loginCommand: String, store: SecretFile<OAuthTokens>, now: @escaping () -> Date, refresher: @escaping (String) throws -> OAuthTokens) {
        self.service = service
        self.loginCommand = loginCommand
        self.store = store
        self.now = now
        self.refresher = refresher
    }

    public func accessToken() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if tokens == nil { tokens = try store.load() }
        guard let current = tokens else { throw CloudAPIError.notSignedIn(service, loginCommand) }
        if current.isFresh(at: now()) { return current.accessToken }
        guard let refreshToken = current.refreshToken else { throw CloudAPIError.notSignedIn(service, loginCommand) }
        var fresh = try refresher(refreshToken)
        // Google sends the refresh token only once; Microsoft rotates it. Keep whichever is newest.
        if fresh.refreshToken == nil { fresh.refreshToken = refreshToken }
        try store.save(fresh)
        tokens = fresh
        return fresh.accessToken
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        tokens?.expiresAt = .distantPast
    }

    func save(_ fresh: OAuthTokens) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.save(fresh)
        tokens = fresh
    }
}

/// Sends API requests with a bearer token, refreshing it and retrying once when the API answers 401.
public final class AuthorizedClient {
    public let service: String
    private let transport: HTTPTransport
    private let tokens: AccessTokenProvider

    public init(service: String, transport: HTTPTransport, tokens: AccessTokenProvider) {
        self.service = service
        self.transport = transport
        self.tokens = tokens
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        var attempt = request
        attempt.setValue("Bearer " + (try tokens.accessToken()), forHTTPHeaderField: "Authorization")
        attempt.setValue("InkRelay/\(InkRelayCore.version)", forHTTPHeaderField: "User-Agent")
        let first = try transport.send(attempt)
        guard first.1.statusCode == 401 else { return first }
        tokens.invalidate()
        attempt.setValue("Bearer " + (try tokens.accessToken()), forHTTPHeaderField: "Authorization")
        return try transport.send(attempt)
    }

    /// Sends `body` and returns the status with the JSON object in the reply (empty when there is none).
    /// Statuses outside 2xx throw unless listed in `allowing`.
    func call(
        _ method: String,
        _ url: URL,
        json: [String: Any]? = nil,
        body: Data? = nil,
        contentType: String? = nil,
        headers: [String: String] = [:],
        allowing: Set<Int> = []
    ) throws -> (status: Int, object: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        let (data, response) = try send(request)
        let status = response.statusCode
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(status) || allowing.contains(status) { return (status, object) }
        if status == 401 { throw CloudAPIError.notSignedIn(service, "") }
        throw CloudAPIError.http(service, status, CloudAPIError.message(in: object))
    }
}

public enum CloudAPIError: Error, LocalizedError, Equatable {
    /// Service and the command that fixes it.
    case notSignedIn(String, String)
    case notConfigured(String, String)
    case http(String, Int, String)
    case unexpected(String, String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn(let service, let command):
            return "Not signed in to \(service), or the sign-in has expired." + (command.isEmpty ? "" : " Run `\(command)`.")
        case .notConfigured(let service, let fix):
            return "\(service) isn't set up: \(fix)"
        case .http(let service, let status, let message):
            return "\(service) returned HTTP \(status)\(message.isEmpty ? "" : ": \(message)")."
        case .unexpected(let service, let reason):
            return "\(service) answered in an unexpected shape (\(reason))."
        }
    }

    /// Google and Microsoft put the reason in `error.message`; token endpoints use `error_description`.
    static func message(in object: [String: Any]) -> String {
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let description = object["error_description"] as? String { return description }
        if let error = object["error"] as? String { return error }
        return ""
    }
}

/// The token endpoint dialect Google and Microsoft share.
enum OAuthForm {
    static func encode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.keys.sorted().map { key in
            let value = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// Posts a form and returns the status with the decoded JSON reply.
    static func post(_ url: URL, _ fields: [String: String], transport: HTTPTransport) throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = encode(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try transport.send(request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (response.statusCode, object)
    }

    static func tokens(from object: [String: Any], now: Date) -> OAuthTokens? {
        guard let access = object["access_token"] as? String, !access.isEmpty else { return nil }
        let lifetime = (object["expires_in"] as? Double) ?? Double(object["expires_in"] as? Int ?? 3600)
        return OAuthTokens(accessToken: access, refreshToken: object["refresh_token"] as? String, expiresAt: now.addingTimeInterval(lifetime))
    }
}

/// Proof Key for Code Exchange (RFC 7636), so the loopback sign-in can't be replayed by another app.
enum PKCE {
    static func verifier(length: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        }
        return String(base64URL(Data(bytes)).prefix(length))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Builds a URL path component, percent-encoding everything that isn't safe inside one segment.
func pathSegment(_ text: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
}

/// Ids InkRelay created in a cloud account (calendars, folders), so later runs reuse them instead of making new ones.
final class CloudIDs {
    private let file: SecretFile<[String: String]>
    private var cache: [String: String]?

    init(url: URL) {
        file = SecretFile(url: url)
    }

    subscript(key: String) -> String? {
        get {
            if cache == nil { cache = (try? file.load()) ?? [:] }
            return cache?[key]
        }
        set {
            if cache == nil { cache = (try? file.load()) ?? [:] }
            cache?[key] = newValue
            try? file.save(cache ?? [:])
        }
    }
}
