import CryptoKit
import XCTest
@testable import InkRelayCore

final class LicensingTests: XCTestCase {
    private let signingKey = Curve25519.Signing.PrivateKey()
    private var folder: TemporaryFolder!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    private var store: EntitlementStore {
        EntitlementStore(supportDirectory: folder.url, publicKey: signingKey.publicKey)
    }

    private func key(name: String = "Ada", expires: Date? = nil) throws -> String {
        try LicenseKey.sign(License(id: "abcd1234", name: name, email: "ada@example.com", issuedAt: now, expiresAt: expires), with: signingKey)
    }

    func testAKeyRoundTripsAndSurvivesEmailWrapping() throws {
        let key = try key()
        XCTAssertTrue(key.hasPrefix("INK1."))
        let wrapped = key.enumerated().map { $0.offset % 40 == 39 ? String($0.element) + "\n " : String($0.element) }.joined()
        let license = try LicenseKey.verify(wrapped, publicKey: signingKey.publicKey)
        XCTAssertEqual(license.name, "Ada")
        XCTAssertEqual(license.plan, "pro")
        XCTAssertNil(license.expiresAt)
    }

    func testTamperedAndForeignKeysAreRefused() throws {
        let key = try key()
        var parts = key.split(separator: ".").map(String.init)
        let payload = try XCTUnwrap(LicenseKey.data(base64URL: parts[1]))
        let edited = String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "Ada", with: "Bob")
        parts[1] = LicenseKey.base64URL(Data(edited.utf8))
        XCTAssertThrowsError(try LicenseKey.verify(parts.joined(separator: "."), publicKey: signingKey.publicKey)) { error in
            XCTAssertEqual(error as? LicenseError, .badSignature)
        }
        let otherPublisher = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try LicenseKey.verify(key, publicKey: otherPublisher.publicKey))
        XCTAssertThrowsError(try LicenseKey.verify("INK1.not-a-key", publicKey: signingKey.publicKey)) { error in
            XCTAssertEqual(error as? LicenseError, .malformed)
        }
        XCTAssertThrowsError(try LicenseKey.verify("hello", publicKey: signingKey.publicKey))
    }

    func testTrialRunsFourteenDaysThenFree() throws {
        let store = store
        let first = store.current(now: now)
        XCTAssertTrue(first.isPro)
        XCTAssertEqual(first.basis, .trial(endsAt: Calendar.current.date(byAdding: .day, value: 14, to: now)!))
        XCTAssertTrue(first.summary(now: now).contains("14 days left"))

        let lastDay = Calendar.current.date(byAdding: .day, value: 13, to: now)!.addingTimeInterval(3600)
        XCTAssertTrue(store.current(now: lastDay).isPro)
        XCTAssertEqual(store.current(now: lastDay).summary(now: lastDay), "Pro trial, last day")

        let after = Calendar.current.date(byAdding: .day, value: 15, to: now)!
        let ended = store.current(now: after)
        XCTAssertFalse(ended.isPro)
        XCTAssertTrue(ended.summary(now: after).hasPrefix("Free; the Pro trial ended"))
        XCTAssertEqual(store.trialStart(now: after), now, "the start is remembered, not restarted")
    }

    func testEnteringAKeyMakesItProAndRemovingGoesBack() throws {
        let store = store
        _ = store.trialStart(now: now)
        let after = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        XCTAssertFalse(store.current(now: after).isPro)

        let license = try store.enter(try key(), now: after)
        XCTAssertEqual(license.name, "Ada")
        XCTAssertEqual(store.current(now: after), Entitlement(plan: .pro, basis: .license(license)))
        XCTAssertEqual(store.current(now: after).summary(), "Pro, licensed to Ada")
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.url.appendingPathComponent("license.json").path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        store.remove()
        XCTAssertFalse(store.current(now: after).isPro)
    }

    func testExpiredKeysAreRefusedOnEntryAndLater() throws {
        let store = store
        let expiring = try key(expires: now.addingTimeInterval(86_400 * 30))
        XCTAssertThrowsError(try store.enter(expiring, now: now.addingTimeInterval(86_400 * 31)))
        try store.enter(expiring, now: now)
        XCTAssertTrue(store.current(now: now).isPro)
        XCTAssertTrue(store.current(now: now).summary(now: now).hasPrefix("Pro, licensed to Ada until"))
        let later = now.addingTimeInterval(86_400 * 60)
        XCTAssertFalse(store.current(now: later).isPro, "an expired license falls back to the trial or free")
    }

    func testAnExpiryDateCoversThatWholeDayWhereverThePersonIs() throws {
        let license = License(name: "Ada", email: "a@x", issuedAt: now, expiresOn: "2027-12-31")
        for zone in ["America/Chicago", "Asia/Tokyo", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let lastMinute = calendar.date(from: DateComponents(year: 2027, month: 12, day: 31, hour: 23, minute: 59))!
            let nextMorning = calendar.date(from: DateComponents(year: 2028, month: 1, day: 1, hour: 0, minute: 1))!
            XCTAssertTrue(license.isValid(at: lastMinute, calendar: calendar), zone)
            XCTAssertFalse(license.isValid(at: nextMorning, calendar: calendar), zone)
            XCTAssertTrue(license.expiryText(calendar: calendar)?.contains("31") == true, "shows the stated day in \(zone)")
        }
        let signed = try LicenseKey.sign(license, with: signingKey)
        let decoded = try LicenseKey.verify(signed, publicKey: signingKey.publicKey)
        XCTAssertEqual(decoded.expiresOn, "2027-12-31")
        XCTAssertTrue(decoded.expires)
        XCTAssertFalse(License(name: "B", email: "b@x", issuedAt: now).expires)
    }

    func testProFeaturesAreNamedForPeople() {
        let config = RelayConfig(
            sources: [SourceConfig(id: "drive", device: "Tablet", path: "/tmp/x", recognizer: .claude)],
            destinations: [.obsidian(.init(id: "vault", vaultPath: "/tmp/v")), .notion(.init(id: "notion", parentPageId: "p")), .reviewStack(.init(id: "review"))],
            viwoodsCloud: ViwoodsCloudConfig()
        )
        XCTAssertEqual(ProFeatures.used(in: config), ["Viwoods Cloud", "AI transcription", "notion", "review stack"])
        XCTAssertFalse(ProFeatures.isPro(.appleCalendar(.init(id: "cal"))))
    }

    func testTheBundledPublicKeyIsSetBeforeRelease() throws {
        // The placeholder is replaced by `scripts/make-license.swift --init`; shipping without it would make every key invalid.
        if LicensePublisher.publicKeyBase64 == "__PUBLIC_KEY__" {
            throw XCTSkip("no publisher key yet; run scripts/make-license.swift --init")
        }
        XCTAssertNotNil(LicensePublisher.publicKey)
    }
}
