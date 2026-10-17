import XCTest
@testable import InkRelayCore

final class AccountTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var transport: FakeTransport!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        transport = FakeTransport()
    }

    override func tearDown() {
        folder.remove()
    }

    // MARK: Google

    func testGoogleLoginCatchesTheLoopbackRedirectAndStoresTokens() throws {
        transport.handlers["token"] = { sent in
            let form = formFields(sent)
            XCTAssertEqual(form["grant_type"], "authorization_code")
            XCTAssertEqual(form["code"], "the-code")
            XCTAssertEqual(form["client_id"], "client-1")
            XCTAssertEqual(form["code_verifier"]?.count, 64)
            XCTAssertTrue(form["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
            return (200, try jsonData(["access_token": "a-1", "refresh_token": "r-1", "expires_in": 3599]))
        }
        let account = GoogleAccount(config: GoogleAccountConfig(clientId: "client-1", clientSecret: "secret-1"), supportDirectory: folder.url, transport: transport)
        let forged = expectation(description: "a redirect with the wrong state is refused")

        try account.login(timeout: 15) { url in
            let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(items["scope"], GoogleAccount.scopes.joined(separator: " "))
            XCTAssertEqual(items["code_challenge_method"], "S256")
            XCTAssertEqual(items["access_type"], "offline")
            let redirect = items["redirect_uri"]!
            let state = items["state"]!
            // Play the browser: first a forged callback, then Google's real one.
            URLSession.shared.dataTask(with: URL(string: "\(redirect)/?state=forged&code=evil")!) { _, response, _ in
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
                forged.fulfill()
                URLSession.shared.dataTask(with: URL(string: "\(redirect)/?state=\(state)&code=the-code")!).resume()
            }.resume()
        }

        wait(for: [forged], timeout: 5)
        XCTAssertEqual(try account.session.accessToken(), "a-1")
        let stored = try SecretFile<OAuthTokens>(url: folder.url.appendingPathComponent("google-token.json")).load()
        XCTAssertEqual(stored?.refreshToken, "r-1")
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.url.appendingPathComponent("google-token.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testGoogleLoginWithoutAClientExplainsWhatToAdd() {
        let account = GoogleAccount(config: nil, supportDirectory: folder.url, transport: transport)
        XCTAssertThrowsError(try account.login { _ in XCTFail("no browser without a client") }) { error in
            guard case .notConfigured("Google", _)? = error as? CloudAPIError else { return XCTFail("\(error)") }
        }
    }

    func testExpiredGoogleTokenIsRefreshedAndTheRefreshTokenKept() throws {
        let account = try signedInGoogle(transport, in: folder, tokens: OAuthTokens(accessToken: "old", refreshToken: "keep-me", expiresAt: Date().addingTimeInterval(-10)))
        transport.handlers["token"] = { sent in
            XCTAssertEqual(formFields(sent)["grant_type"], "refresh_token")
            XCTAssertEqual(formFields(sent)["refresh_token"], "keep-me")
            return (200, try jsonData(["access_token": "new", "expires_in": 3600]))
        }

        XCTAssertEqual(try account.session.accessToken(), "new")
        XCTAssertEqual(try account.session.accessToken(), "new", "fresh tokens aren't refreshed again")
        XCTAssertEqual(transport.requests(to: "token").count, 1)
        let stored = try SecretFile<OAuthTokens>(url: folder.url.appendingPathComponent("google-token.json")).load()
        XCTAssertEqual(stored?.refreshToken, "keep-me", "Google doesn't resend the refresh token, so the old one stays")
    }

    func testRevokedRefreshTokenAsksToSignInAgain() throws {
        let account = try signedInGoogle(transport, in: folder, tokens: OAuthTokens(accessToken: "old", refreshToken: "revoked", expiresAt: .distantPast))
        transport.reply("token", status: 400, ["error": "invalid_grant"])

        XCTAssertThrowsError(try account.session.accessToken()) { error in
            XCTAssertEqual(error as? CloudAPIError, .notSignedIn("Google", "inkrelay google login"))
        }
    }

    func testAPICallRetriesOnceWithARefreshedTokenAfter401() throws {
        let account = try signedInGoogle(transport, in: folder)
        transport.handlers["token"] = { _ in (200, try jsonData(["access_token": "second", "expires_in": 3600])) }
        var seen: [String] = []
        transport.handlers["calendar/v3/calendars"] = { sent in
            let auth = sent.request.value(forHTTPHeaderField: "Authorization") ?? ""
            seen.append(auth)
            return auth == "Bearer second" ? (200, try jsonData(["id": "cal"])) : (401, Data())
        }

        let (status, object) = try account.client.call("POST", URL(string: "https://www.googleapis.com/calendar/v3/calendars")!, json: [:])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(object["id"] as? String, "cal")
        XCTAssertEqual(seen, ["Bearer access-1", "Bearer second"])
    }

    func testAPIErrorsCarryTheServicesMessage() throws {
        let account = try signedInGoogle(transport, in: folder)
        transport.reply("calendar/v3/calendars", status: 403, ["error": ["message": "Calendar API has not been used in project 1"]])
        XCTAssertThrowsError(try account.client.call("POST", URL(string: "https://www.googleapis.com/calendar/v3/calendars")!, json: [:])) { error in
            XCTAssertEqual(error as? CloudAPIError, .http("Google", 403, "Calendar API has not been used in project 1"))
        }
    }

    // MARK: Microsoft

    func testMicrosoftDeviceCodeLoginPollsPatientlyAndStoresTokens() throws {
        transport.handlers["common/oauth2/v2.0/devicecode"] = { sent in
            XCTAssertEqual(formFields(sent)["scope"], "offline_access Calendars.ReadWrite Notes.ReadWrite")
            return (200, try jsonData([
                "device_code": "dc-1", "user_code": "ABCD-1234", "verification_uri": "https://microsoft.com/devicelogin",
                "interval": 5, "expires_in": 900, "message": "To sign in, open https://microsoft.com/devicelogin and enter ABCD-1234.",
            ]))
        }
        var polls = 0
        transport.handlers["common/oauth2/v2.0/token"] = { sent in
            polls += 1
            XCTAssertEqual(formFields(sent)["device_code"], "dc-1")
            switch polls {
            case 1: return (400, try jsonData(["error": "authorization_pending"]))
            case 2: return (400, try jsonData(["error": "slow_down"]))
            default: return (200, try jsonData(["access_token": "ms-a", "refresh_token": "ms-r", "expires_in": 3600]))
            }
        }
        let account = MicrosoftAccount(config: MicrosoftAccountConfig(clientId: "app-1"), supportDirectory: folder.url, transport: transport)
        var shown: [String] = []
        var sleeps: [TimeInterval] = []

        try account.login(show: { shown.append($0) }, sleep: { sleeps.append($0) })

        XCTAssertEqual(shown, ["To sign in, open https://microsoft.com/devicelogin and enter ABCD-1234."])
        XCTAssertEqual(sleeps, [5, 5, 10], "slow_down adds five seconds")
        XCTAssertEqual(try account.session.accessToken(), "ms-a")
    }

    func testMicrosoftDeclinedSignInStopsPolling() throws {
        transport.reply("common/oauth2/v2.0/devicecode", ["device_code": "dc", "interval": 1, "expires_in": 60, "message": "m"])
        transport.reply("common/oauth2/v2.0/token", status: 400, ["error": "authorization_declined", "error_description": "The user declined."])
        let account = MicrosoftAccount(config: MicrosoftAccountConfig(clientId: "app-1"), supportDirectory: folder.url, transport: transport)

        XCTAssertThrowsError(try account.login(show: { _ in }, sleep: { _ in })) { error in
            XCTAssertEqual(error as? CloudAPIError, .http("Microsoft", 400, "The user declined."))
        }
        XCTAssertEqual(transport.requests(to: "common/oauth2/v2.0/token").count, 1)
    }

    func testMicrosoftRefreshUsesTheRotatedToken() throws {
        let account = try signedInMicrosoft(transport, in: folder, tokens: OAuthTokens(accessToken: "old", refreshToken: "r-old", expiresAt: .distantPast))
        transport.handlers["common/oauth2/v2.0/token"] = { sent in
            XCTAssertEqual(formFields(sent)["refresh_token"], "r-old")
            return (200, try jsonData(["access_token": "a-new", "refresh_token": "r-new", "expires_in": 3600]))
        }

        XCTAssertEqual(try account.session.accessToken(), "a-new")
        XCTAssertEqual(try SecretFile<OAuthTokens>(url: folder.url.appendingPathComponent("microsoft-token.json")).load()?.refreshToken, "r-new")
    }

    func testFormEncodingEscapesReservedCharacters() {
        let encoded = String(decoding: OAuthForm.encode(["scope": "a b", "redirect_uri": "http://127.0.0.1:5/?x=1&y"]), as: UTF8.self)
        XCTAssertEqual(encoded, "redirect_uri=http%3A%2F%2F127.0.0.1%3A5%2F%3Fx%3D1%26y&scope=a%20b")
    }

    func testPKCEChallengeMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}
