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
            return (200, try JSONSerialization.data(withJSONObject: [
                ["tag_name": "v1.0.0-beta", "html_url": "https://example.test/r/beta", "prerelease": true],
                ["tag_name": "v0.9.0", "html_url": "https://example.test/r/v0.9.0", "body": "Notes", "draft": false, "prerelease": false],
            ]))
        }
        let checker = UpdateChecker(feedURL: URL(string: feed)!, transport: transport)
        XCTAssertEqual(try checker.latest(), ReleaseInfo(version: "0.9.0", url: URL(string: "https://example.test/r/v0.9.0")!, notes: "Notes"), "the newest published one, skipping pre-releases")
        XCTAssertEqual(try checker.check(current: "0.8.0")?.version, "0.9.0")
        XCTAssertNil(try checker.check(current: "0.9.0"))

        transport.handlers[feed] = { _ in (200, Data("[]".utf8)) }
        XCTAssertNil(try checker.latest(), "no releases yet")
        transport.handlers[feed] = { _ in (404, Data()) }
        XCTAssertThrowsError(try checker.latest(), "a feed that can't be read is not 'up to date'") { error in
            XCTAssertEqual(error as? UpdateError, .feedUnavailable(404))
            XCTAssertTrue(error.localizedDescription.contains("can't tell"))
        }
        transport.handlers[feed] = { _ in (503, Data()) }
        XCTAssertThrowsError(try checker.latest())
    }

    /// The app, the site and the guide all send people to the same releases, in the InkRelay repository.
    func testReleasesComeFromOneRepositoryEverywhere() throws {
        XCTAssertEqual(UpdateChecker.feed.absoluteString, "https://api.github.com/repos/urazalievf/inkrelay/releases?per_page=5")
        XCTAssertEqual(UpdateChecker.downloads.absoluteString, "https://github.com/urazalievf/inkrelay/releases")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["site/index.html", "docs/user-guide.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("github.com/\(UpdateChecker.releasesRepository)/releases"), "\(file) doesn't link the releases")
            XCTAssertFalse(text.contains("inkrelay-releases"), "\(file) still links the old downloads repository")
        }
        let notes = root.appendingPathComponent("docs/release-notes/\(InkRelayCore.version).md")
        XCTAssertFalse(((try? String(contentsOf: notes, encoding: .utf8)) ?? "").isEmpty, "the release workflow needs \(notes.lastPathComponent) before tagging")
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

    func testDiagnosticsSayWhyConfigAndStateDidntLoadAndCarryNoPersonalDetails() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let logs = folder.url.appendingPathComponent("logs", isDirectory: true)
        let home = InkRelayCore.home.path
        try folder.write("logs/inkrelay.log", "[t] Synced: read \(home)/Library/CloudStorage/GoogleDrive-someone@gmail.com/My Drive/x.pdf")

        // A config that decodes but doesn't validate.
        try folder.write("config.json", #"{"sources":[{"id":"a","device":"d","path":"/tmp"}],"destinations":[{"kind":"obsidian","id":"o","vaultPath":"/tmp"}],"rescanIntervalSeconds":20}"#)
        var text = String(decoding: Diagnostics.bundle(configURL: folder.url.appendingPathComponent("config.json"), supportDirectory: folder.url, logDirectory: logs, secrets: MemorySecretStore([:])), as: UTF8.self)
        XCTAssertTrue(text.contains("The config didn't load: rescanIntervalSeconds must be at least 30."), "the reason, not just that it failed")

        // A good config with a Notion destination and a broken state file.
        try folder.write("config.json", """
        {"sources":[{"id":"a","device":"d","path":"/tmp"}],
         "destinations":[{"kind":"obsidian","id":"o","vaultPath":"/tmp"},{"kind":"notion","id":"n","parentPageId":"p"},{"kind":"appleNotes","id":"notes","account":"someone@icloud.com"}],
         "sendTargets":[{"kind":"kindle","id":"k","address":"me_123@kindle.com"}]}
        """)
        try folder.write("state.json", "{")
        text = String(decoding: Diagnostics.bundle(configURL: folder.url.appendingPathComponent("config.json"), supportDirectory: folder.url, logDirectory: logs, secrets: MemorySecretStore([:])), as: UTF8.self)
        XCTAssertTrue(text.contains("state.json can't be read"), "not \"0 tracked\"")
        XCTAssertTrue(text.contains("Notion"), "sign-ins are checked, offline here")
        XCTAssertFalse(text.contains("someone@gmail.com") || text.contains("someone@icloud.com") || text.contains("me_123@kindle.com"), "no email survives")
        XCTAssertFalse(text.contains(home), "no home path, which carries the username")
        XCTAssertTrue(text.contains("~/Library/CloudStorage/GoogleDrive-<account>/My Drive"))
    }
}
