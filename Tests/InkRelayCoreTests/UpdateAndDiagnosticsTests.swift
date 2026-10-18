import XCTest
@testable import InkRelayCore

final class UpdateAndDiagnosticsTests: XCTestCase {
    func testVersionsCompareNumberByNumber() {
        XCTAssertTrue(UpdateChecker.isNewer("0.8.0", than: "0.7.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.7.0.1", than: "0.7.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.12.3"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"), "numbers, not strings")
        XCTAssertFalse(UpdateChecker.isNewer("0.7.0", than: "0.7.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.7.0", than: "0.7.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.6.9", than: "0.7.0"))
    }

    func testTheFeedIsReadAndMissingReleasesMeanNone() throws {
        let transport = FakeTransport()
        let feed = "https://feed.test/latest"
        transport.handlers[feed] = { sent in
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertNil(sent.request.httpBody)
            return (200, try JSONSerialization.data(withJSONObject: ["tag_name": "v0.9.0", "html_url": "https://example.test/r/v0.9.0", "body": "Notes", "draft": false, "prerelease": false]))
        }
        let checker = UpdateChecker(feedURL: URL(string: feed)!, transport: transport)
        XCTAssertEqual(try checker.latest(), ReleaseInfo(version: "0.9.0", url: URL(string: "https://example.test/r/v0.9.0")!, notes: "Notes"))
        XCTAssertEqual(try checker.check(current: "0.8.0")?.version, "0.9.0")
        XCTAssertNil(try checker.check(current: "0.9.0"))

        transport.handlers[feed] = { _ in (404, Data()) }
        XCTAssertNil(try checker.latest())
        transport.handlers[feed] = { _ in (200, try JSONSerialization.data(withJSONObject: ["tag_name": "v1.0.0", "html_url": "https://example.test", "prerelease": true])) }
        XCTAssertNil(try checker.latest(), "pre-releases aren't offered")
        transport.handlers[feed] = { _ in (503, Data()) }
        XCTAssertThrowsError(try checker.latest())
    }

    func testDiagnosticsRedactSecretsAndCarryNoNoteText() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let configURL = folder.url.appendingPathComponent("config.json")
        try folder.write("config.json", """
        {
          "sources": [{ "id": "drive", "device": "Tablet", "path": "/nonexistent/exports" }],
          "destinations": [{ "kind": "obsidian", "id": "vault", "vaultPath": "/nonexistent/vault" }],
          "google": { "clientId": "abc.apps", "clientSecret": "GOCSPX-hidden" },
          "ai": { "model": "claude-opus-5-5" }
        }
        """)
        let logs = folder.url.appendingPathComponent("logs", isDirectory: true)
        try folder.write("logs/inkrelay.log", (1...500).map { "line \($0) token=should-not-matter" }.joined(separator: "\n"))
        try folder.write("archive/x.json", "{\"text\":\"Dear diary, secret handwriting\"}")

        let zip = Diagnostics.bundle(configURL: configURL, supportDirectory: folder.url, logDirectory: logs)
        let text = String(decoding: zip, as: UTF8.self)

        XCTAssertTrue(text.contains("about.txt"))
        XCTAssertTrue(text.contains("doctor.txt"))
        XCTAssertTrue(text.contains("state.txt"))
        XCTAssertTrue(text.contains("logs/inkrelay.log"))
        XCTAssertTrue(text.contains("<redacted>"))
        XCTAssertFalse(text.contains("GOCSPX-hidden"), "the client secret is gone")
        XCTAssertTrue(text.contains("abc.apps"), "ids stay, so support can tell configs apart")
        XCTAssertTrue(text.contains("line 500") && !text.contains("line 99 "), "only the tail of the log")
        XCTAssertFalse(text.contains("Dear diary"), "note text never leaves the Mac")
        XCTAssertTrue(text.contains("Plan: Pro trial"))
    }
}
