import XCTest
@testable import InkRelayCore

final class ProGatingTests: XCTestCase {
    private var exports: TemporaryFolder!
    private var support: TemporaryFolder!

    override func setUpWithError() throws {
        exports = try TemporaryFolder()
        support = try TemporaryFolder()
        try exports.write("Paper/One.pdf", "one")
    }

    override func tearDown() {
        exports.remove()
        support.remove()
    }

    private func engine(_ entitlement: Entitlement, vault: FakeDestination, review: FakeDestination) throws -> RelayEngine {
        let config = RelayConfig(
            sources: [SourceConfig(id: "drive", device: "Tablet", path: exports.url.path)],
            destinations: [.obsidian(.init(id: "vault", vaultPath: "/tmp/v")), .reviewStack(.init(id: "review"))],
            settleSeconds: 0
        )
        let store = try StateStore(url: support.url.appendingPathComponent("state.json"))
        return RelayEngine(config: config, store: store, recognizer: FakeRecognizer(), destinations: [vault, review], entitlement: entitlement)
    }

    func testFreePassesSkipProDestinationsAndSayWhy() throws {
        let vault = FakeDestination(id: "vault"), review = FakeDestination(id: "review")
        let ended = Entitlement(plan: .free, basis: .trialEnded(Date(timeIntervalSince1970: 1_800_000_000)))

        let report = try engine(ended, vault: vault, review: review).syncOnce()

        XCTAssertEqual(vault.upserts.count, 1, "free destinations keep working")
        XCTAssertEqual(review.upserts.count, 0, "Pro destinations wait")
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.warnings[0].hasPrefix("Pro features paused since the trial ended"), report.warnings[0])
        XCTAssertTrue(report.warnings[0].contains("review stack"))
    }

    func testEnteringALicenseLaterDeliversWhatWasPaused() throws {
        let vault = FakeDestination(id: "vault"), review = FakeDestination(id: "review")
        _ = try engine(.free, vault: vault, review: review).syncOnce()

        let report = try engine(.pro, vault: vault, review: review).syncOnce()

        XCTAssertEqual(review.upserts.count, 1, "the note reaches the review stack without re-sending it to the vault")
        XCTAssertEqual(vault.upserts.count, 1)
        XCTAssertEqual(report.warnings, [])
    }

    func testFreeWithoutProPartsHasNoNotice() throws {
        let vault = FakeDestination(id: "vault")
        let config = RelayConfig(sources: [SourceConfig(id: "drive", device: "Tablet", path: exports.url.path)], destinations: [.obsidian(.init(id: "vault", vaultPath: "/tmp/v"))], settleSeconds: 0)
        let store = try StateStore(url: support.url.appendingPathComponent("state.json"))
        let report = RelayEngine(config: config, store: store, recognizer: FakeRecognizer(), destinations: [vault], entitlement: .free).syncOnce()
        XCTAssertEqual(report.warnings, [])
    }
}
