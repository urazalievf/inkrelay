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

    func testExpandsTildeInPaths() throws {
        let source = SourceConfig(id: "s", device: "d", path: "~/Exports")
        XCTAssertEqual(source.url.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Exports").path)
    }

    func testRejectsUnknownDestinationKind() {
        let json = #"{ "sources": [], "destinations": [{ "kind": "evernote", "id": "e" }] }"#
        XCTAssertThrowsError(try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? ConfigError, .invalid("Unknown destination kind \"evernote\". Use \"obsidian\" or \"appleNotes\"."))
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
