import CryptoKit
import Foundation

/// Talks to Viwoods Cloud the way the web portal at cloud.viwoods.com does. Viwoods publishes no API,
/// so every request is signed like the portal's and the endpoints can change with any portal update.
///
/// Logging in on the web needs a slider captcha, so InkRelay never asks for the account password.
/// The user copies the portal's access token once (`inkrelay viwoods login`); after that the client
/// refreshes it itself, as the portal does, whenever the cloud says it has expired.
public final class ViwoodsClient {
    public static let baseURL = URL(string: "https://api.viwoods.com/")!
    public static let userAgent = "InkRelay/\(InkRelayCore.version)"

    /// The portal signs each request body with this key. It ships in the portal's own JavaScript.
    static let signingKey = "O9EfpIx4g9o8TKuCv2n5msBHucSrAf"
    static let refreshPath = "api/v1/user/refreshLogin"
    static let expiredCodes: Set<Int> = [401, 10104]
    /// "Incorrect token": the cloud won't refresh it, so the user has to copy a new one.
    static let invalidTokenCode = 10015

    private let transport: HTTPTransport
    private let credentials: ViwoodsCredentialStore
    private var token: String?

    public init(transport: HTTPTransport = URLSessionTransport(), credentials: ViwoodsCredentialStore) {
        self.transport = transport
        self.credentials = credentials
    }

    // MARK: Endpoints

    public func rootFolders() throws -> [ViwoodsRootFolder] {
        try call("api/v1/resourceSync/getRootFolder", [:])
    }

    /// Everything directly inside a cloud folder. `parent` is empty for an app's top level.
    public func contents(of app: ViwoodsApp, parent: String, subTab: Int = -1) throws -> [ViwoodsResource] {
        var all: [ViwoodsResource] = []
        var index = 1
        while true {
            let page: ViwoodsResourcePage = try call("api/v1/resourceSync/getPage", [
                "pageIndex": .int(index), "pageSize": .int(100), "appType": .int(app.rawValue),
                "resourceId": .string(parent), "isDelete": .int(0), "subTab": .int(subTab),
                "resourceType": .int(-1), "star": .int(-1),
                "sortField": .string("creation_time"), "sortOrder": .string("desc"),
            ])
            all += page.list
            if page.list.isEmpty || all.count >= page.count { return all }
            index += 1
        }
    }

    public func notebook(_ app: ViwoodsApp, uuid: String) throws -> ViwoodsNotebook {
        try decodeBlob(try call(app.syncPath, ["uuid": .string(uuid)]))
    }

    /// One item's content as the cloud sends it, for looking at apps InkRelay doesn't pull yet.
    public func rawItem(_ app: ViwoodsApp, uuid: String) throws -> Any {
        let blob: Blob = try call(app.syncPath, ["uuid": .string(uuid)])
        return try JSONSerialization.jsonObject(with: try Gzip.decompressBase64(blob.data))
    }

    public func memo(uuid: String) throws -> ViwoodsMemo {
        try decodeBlob(try call("api/v1/memoSync/get", ["uuid": .string(uuid)]))
    }

    /// Days with planner content in a month given as `yyyy-MM`.
    public func dailyDates(month: String) throws -> [ViwoodsDailyDate] {
        try call("api/v1/resourceDailySync/getDateList", ["month": .string(month)])
    }

    public func dailyItems(from start: String, to end: String, kind: ViwoodsDailyItem.Kind) throws -> [ViwoodsDailyItem] {
        try call("api/v1/resourceDailySync/getList", [
            "startDate": .string(start), "endDate": .string(end), "type": .int(kind.rawValue), "isFinish": .int(-1),
        ])
    }

    /// Fetches a page image from the CDN. These links need no signing or token.
    public func download(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try transport.send(request)
        guard response.statusCode == 200 else { throw ViwoodsError.download(url, response.statusCode) }
        return data
    }

    /// Stores a token copied from the portal, after checking it works.
    public func login(token: String) throws -> [ViwoodsRootFolder] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !trimmed.isEmpty else { throw ViwoodsError.notLoggedIn }
        self.token = trimmed
        let folders = try rootFolders()
        try credentials.save(ViwoodsCredentials(token: trimmed, updatedAt: Date()))
        return folders
    }

    // MARK: Requests

    /// A value in a request body. The cloud compares the signature against the body it receives,
    /// so what is signed has to be exactly what is sent.
    public enum Param: Equatable {
        case string(String)
        case int(Int)
        /// Only the upload's part tags use an object.
        case object([String: String])

        /// How the portal's JavaScript turns the value into text for the signature.
        var signed: String {
            switch self {
            case .string(let text): return text
            case .int(let number): return String(number)
            case .object: return "[object Object]"
            }
        }

        var json: Any {
            switch self {
            case .string(let text): return text
            case .int(let number): return number
            case .object(let map): return map
            }
        }
    }

    /// The portal's signature: parameters sorted by key as `k=v&k=v`, the signing key appended, MD5 in hex.
    /// Like the portal, it leaves the part tags out when completing an upload.
    static func sign(_ body: [String: Param], path: String = "") -> String {
        let keys = body.keys.sorted().filter { !($0 == "eTags" && path.contains("upload/complete")) }
        let joined = keys.map { "\($0)=\(body[$0]!.signed)" }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((joined + signingKey).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func request(path: String, body: [String: Param], token: String?) throws -> URLRequest {
        var body = body
        body["uri"] = .string("/" + path)
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues(\.json))
        let headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": userAgent,
            "System-Version": "1.0.0",
            "Source": "2",
            "Machine-Model": "web",
            "Machine-Number": "",
            "Language": "us",
            "Sign": sign(body, path: path),
        ]
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "Access-Token")
        }
        return request
    }

    private func currentToken() throws -> String {
        if let token { return token }
        guard let stored = try credentials.load(), !stored.token.isEmpty else { throw ViwoodsError.notLoggedIn }
        token = stored.token
        return stored.token
    }

    private func call<T: Decodable>(_ path: String, _ body: [String: Param]) throws -> T {
        try decode(T.self, from: try reply(path, body), path: path)
    }

    /// The raw envelope after a successful call, refreshing the token once if it expired.
    private func reply(_ path: String, _ body: [String: Param]) throws -> Data {
        let token = try currentToken()
        switch try perform(path: path, body: body, token: token) {
        case .success(let data):
            return data
        case .expired:
            let fresh = try refresh(expired: token)
            switch try perform(path: path, body: body, token: fresh) {
            case .success(let data): return data
            case .expired: throw ViwoodsError.notLoggedIn
            }
        }
    }

    /// The `data` object of a reply, loosely typed, for endpoints whose field names vary.
    private func object(_ path: String, _ body: [String: Param]) throws -> [String: Any] {
        let envelope = (try? JSONSerialization.jsonObject(with: try reply(path, body))) as? [String: Any]
        return envelope?["data"] as? [String: Any] ?? [:]
    }

    // MARK: Importing

    /// Uploads a file into a Viwoods app the way the portal's Import button does: start an upload, PUT the
    /// bytes to the storage URL it hands out, complete it with the file's MD5 and the part's ETag, then
    /// register the file with the app. Learning takes EPUB and PDF; Paper takes PDF.
    public func importFile(_ data: Data, fileName: String, to target: ViwoodsImportTarget, pageCount: Int, parentID: String = "") throws {
        let folder = "/\(target.folderType)/"
        let ticket = try object("api/v2/cloud/upload/init", ["fileName": .string(fileName), "partNum": .int(1), "type": .string(folder)])
        let uploadID = Self.first(ticket, ["uploadId", "id"])
        let filePath = Self.first(ticket, ["filePath", "path"])
        let part = Self.uploadPart(ticket["uploadPath"])
        guard !uploadID.isEmpty, let partURL = URL(string: part.url) else {
            throw ViwoodsError.unexpectedResponse("upload/init", "no upload URL")
        }

        var put = URLRequest(url: partURL)
        put.httpMethod = "PUT"
        put.httpBody = data
        for (name, value) in part.headers { put.setValue(value, forHTTPHeaderField: name) }
        let (_, stored) = try transport.send(put)
        guard (200..<300).contains(stored.statusCode), let etag = stored.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
            throw ViwoodsError.http("upload", stored.statusCode, "the storage server didn't accept the file")
        }

        let hash = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let done = try object("api/v2/cloud/upload/complete", [
            "uploadId": .string(uploadID), "folder": .string(folder), "source": .string(String(target.rawValue)),
            "filePath": .string(filePath), "fileName": .string(fileName), "hash": .string(hash),
            "eTags": .object([part.partNumber: etag]),
        ])
        let fileURL = Self.first(done, ["fileURL", "fileUrl", "file_url", "filePath", "path", "url"])
        _ = try reply("api/v1/resourceSync/import", [
            "appType": .int(target.rawValue), "name": .string(fileName), "parentId": .string(parentID),
            "fileSize": .int(data.count), "filePath": .string(fileURL.isEmpty ? filePath : fileURL), "pageNumber": .int(pageCount),
        ])
    }

    static func first(_ object: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let value = object[key], !(value is NSNull) {
                let text = "\(value)".trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
            }
        }
        return ""
    }

    /// `uploadPath` arrives as a URL, a list of URLs, or objects with the URL, part number and headers.
    static func uploadPart(_ value: Any?) -> (url: String, partNumber: String, headers: [String: String]) {
        let entry = (value as? [Any])?.first ?? value
        if let url = entry as? String { return (url, "1", [:]) }
        guard let object = entry as? [String: Any] else { return ("", "1", [:]) }
        let headers = (object["headers"] ?? object["uploadHeaders"] ?? object["requestHeaders"]) as? [String: Any] ?? [:]
        return (
            first(object, ["url", "uploadUrl", "path", "uploadPath"]),
            first(object, ["partNumber", "partNo", "part"]).isEmpty ? "1" : first(object, ["partNumber", "partNo", "part"]),
            headers.mapValues { "\($0)" }
        )
    }

    private enum Outcome {
        case success(Data)
        case expired
    }

    private func perform(path: String, body: [String: Param], token: String) throws -> Outcome {
        let (data, response) = try transport.send(try Self.request(path: path, body: body, token: token))
        if response.statusCode == 401 { return .expired }
        guard response.statusCode == 200 else {
            throw ViwoodsError.http(path, response.statusCode, Self.message(in: data))
        }
        let envelope = try decodeEnvelope(data, path: path)
        if Self.expiredCodes.contains(envelope.code) { return .expired }
        if envelope.code == Self.invalidTokenCode { throw ViwoodsError.notLoggedIn }
        guard envelope.code == 200 else { throw ViwoodsError.api(path, envelope.code, envelope.msg ?? "") }
        return .success(data)
    }

    /// Trades the expired token for a new one, as the portal does, and stores it.
    private func refresh(expired: String) throws -> String {
        let (data, response) = try transport.send(try Self.request(path: Self.refreshPath, body: [:], token: expired))
        guard response.statusCode == 200,
              let envelope = try? JSONDecoder().decode(Envelope<RefreshResult>.self, from: data),
              envelope.code == 200, let fresh = envelope.data?.token, !fresh.isEmpty else {
            token = nil
            throw ViwoodsError.notLoggedIn
        }
        token = fresh
        try credentials.save(ViwoodsCredentials(token: fresh, updatedAt: Date()))
        return fresh
    }

    private struct Envelope<T: Decodable>: Decodable {
        var code: Int
        var msg: String?
        var data: T?
    }

    private struct RefreshResult: Decodable {
        var token: String?
    }

    /// Notebook endpoints wrap the inflated JSON in `data.data` as base64 gzip.
    private struct Blob: Decodable {
        var data: String
    }

    private func decodeEnvelope(_ data: Data, path: String) throws -> Envelope<EmptyData> {
        do {
            return try JSONDecoder().decode(Envelope<EmptyData>.self, from: data)
        } catch {
            throw ViwoodsError.unexpectedResponse(path, "not the usual envelope")
        }
    }

    private struct EmptyData: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
            guard let payload = envelope.data else { throw ViwoodsError.unexpectedResponse(path, "no data") }
            return payload
        } catch let error as ViwoodsError {
            throw error
        } catch {
            throw ViwoodsError.unexpectedResponse(path, error.localizedDescription)
        }
    }

    private func decodeBlob<T: Decodable>(_ blob: Blob) throws -> T {
        let json = try Gzip.decompressBase64(blob.data)
        do {
            return try JSONDecoder().decode(T.self, from: json)
        } catch {
            throw ViwoodsError.unexpectedResponse("notebook body", error.localizedDescription)
        }
    }

    private static func message(in data: Data) -> String {
        (try? JSONDecoder().decode(Envelope<EmptyData>.self, from: data))?.msg ?? ""
    }
}

public enum ViwoodsError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case http(String, Int, String)
    case api(String, Int, String)
    case unexpectedResponse(String, String)
    case download(URL, Int)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not signed in to Viwoods Cloud, or the saved token has expired. Run `inkrelay viwoods login`."
        case .http(let path, let status, let message):
            return "Viwoods Cloud returned HTTP \(status) for \(path)\(message.isEmpty ? "" : ": \(message)")."
        case .api(let path, let code, let message):
            return "Viwoods Cloud rejected \(path) (code \(code))\(message.isEmpty ? "" : ": \(message)")."
        case .unexpectedResponse(let path, let reason):
            return "Viwoods Cloud answered \(path) in a shape InkRelay doesn't understand (\(reason)). The portal may have changed."
        case .download(let url, let status):
            return "Couldn't download \(url.lastPathComponent) (HTTP \(status))."
        }
    }
}

// MARK: - Transport and credentials

public protocol HTTPTransport {
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse)
}

/// Blocking URLSession, since the engine runs one pass at a time.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = 60
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(URLError(.unknown))
        session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                result = .success((data ?? Data(), response))
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}

public struct ViwoodsCredentials: Codable, Equatable {
    public var token: String
    public var updatedAt: Date

    public init(token: String, updatedAt: Date) {
        self.token = token
        self.updatedAt = updatedAt
    }
}

public protocol ViwoodsCredentialStore {
    func load() throws -> ViwoodsCredentials?
    func save(_ credentials: ViwoodsCredentials) throws
}

/// Keeps the token in a file only the user can read, next to the config.
public struct FileCredentialStore: ViwoodsCredentialStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> ViwoodsCredentials? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ViwoodsCredentials.self, from: Data(contentsOf: url))
    }

    public func save(_ credentials: ViwoodsCredentials) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(credentials).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// For tests and for `login`, where no token exists yet.
public final class MemoryCredentialStore: ViwoodsCredentialStore {
    public var credentials: ViwoodsCredentials?

    public init(credentials: ViwoodsCredentials? = nil) {
        self.credentials = credentials
    }

    public func load() throws -> ViwoodsCredentials? { credentials }
    public func save(_ credentials: ViwoodsCredentials) throws { self.credentials = credentials }
}
