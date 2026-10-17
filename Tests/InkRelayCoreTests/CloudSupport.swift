import Foundation
import XCTest
@testable import InkRelayCore

extension FakeTransport {
    /// Registers a plain JSON reply (Google and Graph don't use the Viwoods envelope).
    func reply(_ path: String, status: Int = 200, _ json: [String: Any] = [:]) {
        handlers[path] = { _ in (status, try JSONSerialization.data(withJSONObject: json)) }
    }

    func requests(to path: String) -> [Sent] {
        sent.filter { $0.path == path }
    }
}

func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

/// Decodes an `application/x-www-form-urlencoded` body.
func formFields(_ sent: FakeTransport.Sent) -> [String: String] {
    let text = String(decoding: sent.request.httpBody ?? Data(), as: UTF8.self)
    var fields: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        fields[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return fields
}

func bodyText(_ sent: FakeTransport.Sent) -> String {
    String(decoding: sent.request.httpBody ?? Data(), as: UTF8.self)
}

func freshTokens(_ access: String = "access-1", refresh: String = "refresh-1") -> OAuthTokens {
    OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(3600))
}

func signedInGoogle(_ transport: FakeTransport, in folder: TemporaryFolder, tokens: OAuthTokens = freshTokens()) throws -> GoogleAccount {
    try SecretFile<OAuthTokens>(url: folder.url.appendingPathComponent("google-token.json")).save(tokens)
    return GoogleAccount(config: GoogleAccountConfig(clientId: "client-1", clientSecret: "secret-1"), supportDirectory: folder.url, transport: transport)
}

func signedInMicrosoft(_ transport: FakeTransport, in folder: TemporaryFolder, tokens: OAuthTokens = freshTokens()) throws -> MicrosoftAccount {
    try SecretFile<OAuthTokens>(url: folder.url.appendingPathComponent("microsoft-token.json")).save(tokens)
    return MicrosoftAccount(config: MicrosoftAccountConfig(clientId: "app-1"), supportDirectory: folder.url, transport: transport)
}

func plannerNote(_ date: String = "2026-01-13", text: String = "Gym at 7\nCall Sam") -> InkNote {
    makeNote(title: date, relativePath: "Daily/\(date).pdf", pages: [RecognizedPage(number: 1, text: text)])
}

/// A UTC Gregorian calendar, so day arithmetic in tests doesn't depend on the Mac's time zone.
let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
