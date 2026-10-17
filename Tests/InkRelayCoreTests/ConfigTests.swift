import XCTest
@testable import InkRelayCore

final class ConfigTests: XCTestCase {
    func testDecodesBothDestinationKindsAndFillsDefaults() throws {
        let json = """
        {
          "sources": [{ "id": "viwoods", "path": "~/Exports" }],
          "destinations": [
            { "kind": "obsidian", "id": "vault", "vaultPath": "~/Vault" },
            { "kind": "appleNotes", "id": "notes", "account": "iCloud" }
          ]
        }
        """
        let config = try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.sources.first?.device, "viwoods")
        XCTAssertEqual(config.sources.first?.fileTypes, ["pdf"])
        XCTAssertEqual(config.rescanIntervalSeconds, 300)
        XCTAssertEqual(config.recognition, RecognitionConfig())
        XCTAssertEqual(config.destinations, [
            .obsidian(.init(id: "vault", vaultPath: "~/Vault")),
            .appleNotes(.init(id: "notes", account: "iCloud")),
        ])
    }

    func testDecodesViwoodsCloudAndAppleCalendar() throws {
        let json = """
        {
          "sources": [],
          "destinations": [{ "kind": "appleCalendar", "id": "cal", "calendar": "Plans" }],
          "viwoodsCloud": { "apps": ["paper"], "daily": true, "dailyMonths": 3, "cachePath": "~/Ink/viwoods" }
        }
        """
        let config = try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.destinations, [.appleCalendar(.init(id: "cal", calendar: "Plans"))])
        XCTAssertEqual(config.viwoodsCloud?.apps, ["paper"])
        XCTAssertEqual(config.allSources.map(\.id), ["viwoods-cloud"], "the cloud cache is a source of its own")
        XCTAssertTrue(config.allSources[0].url.path.hasSuffix("/Ink/viwoods"))
        XCTAssertNoThrow(try config.validate(), "no folder sources needed when the cloud is configured")

        var clash = config
        clash.sources = [SourceConfig(id: "viwoods-cloud", device: "x", path: "/x")]
        XCTAssertThrowsError(try clash.validate())
    }

    func testDecodesTheGoogleMicrosoftAndReviewDestinations() throws {
        let json = """
        {
          "sources": [{ "id": "s", "path": "~/x" }],
          "google": { "clientId": "c.apps.googleusercontent.com", "clientSecret": "s" },
          "microsoft": { "clientId": "m" },
          "destinations": [
            { "kind": "googleCalendar", "id": "gcal" },
            { "kind": "googleDocs", "id": "docs", "folder": "Notes" },
            { "kind": "outlookCalendar", "id": "outlook", "timeZone": "America/Chicago" },
            { "kind": "oneNote", "id": "onenote" },
            { "kind": "reviewStack", "id": "stack", "resurfaceDays": [3, 14] }
          ]
        }
        """
        let config = try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))

        XCTAssertNoThrow(try config.validate())
        XCTAssertEqual(config.microsoft?.tenant, "common")
        XCTAssertEqual(config.destinations, [
            .googleCalendar(.init(id: "gcal")),
            .googleDocs(.init(id: "docs", folder: "Notes")),
            .outlookCalendar(.init(id: "outlook", timeZone: "America/Chicago")),
            .oneNote(.init(id: "onenote")),
            .reviewStack(.init(id: "stack", port: 7788, dailyLimit: 25, resurfaceDays: [3, 14])),
        ])
        let roundTrip = try JSONDecoder().decode(RelayConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTrip, config)
    }

    func testCloudDestinationsNeedTheirAccountSection() {
        let google = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: "/x")], destinations: [.googleDocs(.init(id: "docs"))])
        XCTAssertThrowsError(try google.validate()) { error in
            XCTAssertTrue((error as? ConfigError)?.errorDescription?.contains("\"google\" section") == true)
        }
        let microsoft = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: "/x")], destinations: [.oneNote(.init(id: "n"))])
        XCTAssertThrowsError(try microsoft.validate())
        let twoStacks = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: "/x")], destinations: [.reviewStack(.init(id: "a")), .reviewStack(.init(id: "b"))])
        XCTAssertThrowsError(try twoStacks.validate())
        let badPort = RelayConfig(sources: [SourceConfig(id: "s", device: "d", path: "/x")], destinations: [.reviewStack(.init(id: "a", port: 80))])
        XCTAssertThrowsError(try badPort.validate())
    }

    func testExpandsTildeInPaths() throws {
        let source = SourceConfig(id: "s", device: "d", path: "~/Exports")
        XCTAssertEqual(source.url.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Exports").path)
    }

    func testRejectsUnknownDestinationKind() {
        let json = #"{ "sources": [], "destinations": [{ "kind": "evernote", "id": "e" }] }"#
        XCTAssertThrowsError(try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? ConfigError, .invalid("Unknown destination kind \"evernote\". Use one of: obsidian, appleNotes, appleCalendar, googleCalendar, googleDocs, outlookCalendar, oneNote, reviewStack, notion, appleReminders."))
        }
    }

    func testValidationCatchesDuplicateIdsAndEmptyLists() {
        let duplicate = RelayConfig(
            sources: [SourceConfig(id: "a", device: "A", path: "/a"), SourceConfig(id: "a", device: "B", path: "/b")],
            destinations: [.appleNotes(.init(id: "notes"))]
        )
        XCTAssertThrowsError(try duplicate.validate())
        XCTAssertThrowsError(try RelayConfig(sources: [], destinations: [.appleNotes(.init(id: "n"))]).validate())
        XCTAssertNoThrow(try ConfigStore.example.validate())
    }

    func testRoundTripsThroughDisk() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("nested/config.json")

        try ConfigStore.save(ConfigStore.example, to: url)
        XCTAssertEqual(try ConfigStore.load(from: url), ConfigStore.example)
    }

    func testMissingConfigPointsAtInit() {
        let url = URL(fileURLWithPath: "/nonexistent/config.json")
        XCTAssertThrowsError(try ConfigStore.load(from: url)) { error in
            XCTAssertEqual(error as? ConfigError, .missing(url))
        }
    }
}
