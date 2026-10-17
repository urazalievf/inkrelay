import Foundation

/// The `microsoft` section of the config: the application (client) id of an app registration in Microsoft Entra
/// with "Allow public client flows" turned on. `tenant` is `common` for both personal and work accounts.
public struct MicrosoftAccountConfig: Codable, Equatable {
    public var clientId: String
    public var tenant: String

    public init(clientId: String, tenant: String = "common") {
        self.clientId = clientId
        self.tenant = tenant
    }

    private enum CodingKeys: String, CodingKey { case clientId, tenant }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String.self, forKey: .clientId)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant) ?? "common"
    }
}

/// A signed-in Microsoft account for Outlook Calendar and OneNote through Microsoft Graph.
/// Sign-in uses the device code flow: the terminal shows a short code to enter at microsoft.com/devicelogin.
public final class MicrosoftAccount {
    public static let scopes = ["offline_access", "Calendars.ReadWrite", "Notes.ReadWrite"]
    static let loginCommand = "inkrelay microsoft login"
    public static let graph = URL(string: "https://graph.microsoft.com/v1.0/")!

    let config: MicrosoftAccountConfig?
    private let transport: HTTPTransport
    private let now: () -> Date
    public let session: OAuthSession
    public let client: AuthorizedClient

    public init(config: MicrosoftAccountConfig?, supportDirectory: URL, transport: HTTPTransport = URLSessionTransport(), now: @escaping () -> Date = Date.init) {
        self.config = config
        self.transport = transport
        self.now = now
        let store = SecretFile<OAuthTokens>(url: supportDirectory.appendingPathComponent("microsoft-token.json"))
        var refresh: (String) throws -> OAuthTokens = { _ in throw CloudAPIError.notSignedIn("Microsoft", Self.loginCommand) }
        session = OAuthSession(service: "Microsoft", loginCommand: Self.loginCommand, store: store, now: now) { refreshToken in
            try refresh(refreshToken)
        }
        client = AuthorizedClient(service: "Microsoft Graph", transport: transport, tokens: session)
        refresh = { [unowned self] refreshToken in try self.refresh(refreshToken) }
    }

    static func endpoint(_ tenant: String, _ name: String) -> URL {
        URL(string: "https://login.microsoftonline.com/\(pathSegment(tenant))/oauth2/v2.0/\(name)")!
    }

    /// Runs the device code flow. `show` gets Microsoft's instruction ("To sign in, use a web browser to open…");
    /// `sleep` is injectable so tests don't wait for real.
    public func login(show: (String) -> Void, sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        guard let config else {
            throw CloudAPIError.notConfigured("Microsoft", "add a \"microsoft\" section with the clientId of your app registration.")
        }
        let (status, start) = try OAuthForm.post(Self.endpoint(config.tenant, "devicecode"), [
            "client_id": config.clientId,
            "scope": Self.scopes.joined(separator: " "),
        ], transport: transport)
        guard status == 200, let deviceCode = start["device_code"] as? String else {
            throw CloudAPIError.http("Microsoft", status, CloudAPIError.message(in: start))
        }
        let message = start["message"] as? String
            ?? "Open \(start["verification_uri"] as? String ?? "https://microsoft.com/devicelogin") and enter \(start["user_code"] as? String ?? "the code")."
        show(message)

        var interval = TimeInterval((start["interval"] as? Int) ?? 5)
        let deadline = now().addingTimeInterval(TimeInterval((start["expires_in"] as? Int) ?? 900))
        while now() < deadline {
            sleep(interval)
            let (_, reply) = try OAuthForm.post(Self.endpoint(config.tenant, "token"), [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": config.clientId,
                "device_code": deviceCode,
            ], transport: transport)
            if let tokens = OAuthForm.tokens(from: reply, now: now()) {
                try session.save(tokens)
                return
            }
            switch reply["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            default: throw CloudAPIError.http("Microsoft", 400, CloudAPIError.message(in: reply))
            }
        }
        throw CloudAPIError.notSignedIn("Microsoft", Self.loginCommand)
    }

    private func refresh(_ refreshToken: String) throws -> OAuthTokens {
        guard let config else {
            throw CloudAPIError.notConfigured("Microsoft", "add a \"microsoft\" section with the clientId.")
        }
        let (status, object) = try OAuthForm.post(Self.endpoint(config.tenant, "token"), [
            "grant_type": "refresh_token",
            "client_id": config.clientId,
            "refresh_token": refreshToken,
            "scope": Self.scopes.joined(separator: " "),
        ], transport: transport)
        guard status == 200, let tokens = OAuthForm.tokens(from: object, now: now()) else {
            throw CloudAPIError.notSignedIn("Microsoft", Self.loginCommand)
        }
        return tokens
    }

    /// `https://graph.microsoft.com/v1.0/<path>` with optional query items.
    static func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: graph.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }
}
