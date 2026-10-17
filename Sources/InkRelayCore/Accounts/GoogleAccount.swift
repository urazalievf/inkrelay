import Foundation

/// The `google` section of the config: an OAuth client of type "Desktop app" from Google Cloud Console.
/// Google treats a desktop client's secret as public, so it lives in the config rather than the token file.
public struct GoogleAccountConfig: Codable, Equatable {
    public var clientId: String
    public var clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

/// A signed-in Google account. Asks only for calendars InkRelay creates and Drive files InkRelay creates,
/// so it can never read the rest of the account.
public final class GoogleAccount {
    public static let scopes = [
        "https://www.googleapis.com/auth/calendar.app.created",
        "https://www.googleapis.com/auth/drive.file",
    ]
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let loginCommand = "inkrelay google login"

    let config: GoogleAccountConfig?
    private let transport: HTTPTransport
    private let now: () -> Date
    public let session: OAuthSession
    public let client: AuthorizedClient
    /// Calendar and folder ids InkRelay created, by name.
    let ids: CloudIDs

    public init(config: GoogleAccountConfig?, supportDirectory: URL, transport: HTTPTransport = URLSessionTransport(), now: @escaping () -> Date = Date.init) {
        self.config = config
        self.transport = transport
        self.now = now
        ids = CloudIDs(url: supportDirectory.appendingPathComponent("google-ids.json"))
        let store = SecretFile<OAuthTokens>(url: supportDirectory.appendingPathComponent("google-token.json"))
        var refresh: (String) throws -> OAuthTokens = { _ in throw CloudAPIError.notSignedIn("Google", Self.loginCommand) }
        session = OAuthSession(service: "Google", loginCommand: Self.loginCommand, store: store, now: now) { refreshToken in
            try refresh(refreshToken)
        }
        client = AuthorizedClient(service: "Google", transport: transport, tokens: session)
        refresh = { [unowned self] refreshToken in try self.refresh(refreshToken) }
    }

    static func authorizationURL(clientID: String, redirect: String, challenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    /// Signs in through the browser: a one-off server on 127.0.0.1 catches Google's redirect,
    /// the flow Google documents for desktop apps. `openBrowser` gets the consent page URL.
    public func login(timeout: TimeInterval = 300, openBrowser: (URL) -> Void) throws {
        guard let config else {
            throw CloudAPIError.notConfigured("Google", "add a \"google\" section with the clientId and clientSecret of a Desktop OAuth client.")
        }
        let verifier = PKCE.verifier()
        let state = PKCE.verifier(length: 32)
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<String, Error>?

        let server = try LocalHTTPServer { request in
            guard request.path == "/", outcome == nil else { return .text("Not found", status: 404) }
            if let error = request.query["error"] {
                outcome = .failure(CloudAPIError.notSignedIn("Google", "sign-in was declined (\(error))"))
                done.signal()
                return .html(Self.page("Sign-in was cancelled. You can close this tab."))
            }
            guard request.query["state"] == state, let code = request.query["code"], !code.isEmpty else {
                return .text("Bad request", status: 400)
            }
            outcome = .success(code)
            done.signal()
            return .html(Self.page("InkRelay is signed in to Google. You can close this tab and go back to the terminal."))
        }
        try server.start()
        defer { server.stop() }

        let redirect = "http://127.0.0.1:\(server.port)"
        openBrowser(Self.authorizationURL(clientID: config.clientId, redirect: redirect, challenge: PKCE.challenge(for: verifier), state: state))
        guard done.wait(timeout: .now() + timeout) == .success, let outcome else {
            throw CloudAPIError.notSignedIn("Google", Self.loginCommand)
        }
        let code = try outcome.get()
        let (status, object) = try OAuthForm.post(Self.tokenEndpoint, [
            "code": code,
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ], transport: transport)
        guard status == 200, let tokens = OAuthForm.tokens(from: object, now: now()) else {
            throw CloudAPIError.http("Google", status, CloudAPIError.message(in: object))
        }
        try session.save(tokens)
    }

    private func refresh(_ refreshToken: String) throws -> OAuthTokens {
        guard let config else {
            throw CloudAPIError.notConfigured("Google", "add a \"google\" section with the clientId and clientSecret.")
        }
        let (status, object) = try OAuthForm.post(Self.tokenEndpoint, [
            "refresh_token": refreshToken,
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "grant_type": "refresh_token",
        ], transport: transport)
        guard status == 200, let tokens = OAuthForm.tokens(from: object, now: now()) else {
            // invalid_grant: revoked, or unused for six months while the client is in testing mode.
            throw CloudAPIError.notSignedIn("Google", Self.loginCommand)
        }
        return tokens
    }

    static func page(_ message: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>InkRelay</title>
        <body style="font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;margin:0;background:#f3f1ec;color:#1d1c1a">
        <p style="max-width:28em;text-align:center">\(message)</p></body>
        """
    }
}
