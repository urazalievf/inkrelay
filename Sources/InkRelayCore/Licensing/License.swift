import CryptoKit
import Foundation

/// A Pro license: who it was issued to and for how long. Keys are signed with Ed25519 and checked against the
/// public key below, so a key works offline and InkRelay never phones home. The private key lives only with
/// the owner (`scripts/make-license.swift`).
public struct License: Codable, Equatable {
    public var id: String
    public var name: String
    public var email: String
    /// `pro` today; room for more.
    public var plan: String
    public var issuedAt: Date
    /// The last day the key works, as `yyyy-MM-dd`, wherever the person is: the whole of that day in their own
    /// time zone, and shown as that date everywhere. Nil (with no `expiresAt`) is for keeps.
    public var expiresOn: String?
    /// An exact end, for keys issued before `expiresOn` existed.
    public var expiresAt: Date?

    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), name: String, email: String, plan: String = "pro", issuedAt: Date,
                expiresOn: String? = nil, expiresAt: Date? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.plan = plan
        self.issuedAt = issuedAt
        self.expiresOn = expiresOn
        self.expiresAt = expiresAt
    }

    public var expires: Bool { expiresOn != nil || expiresAt != nil }

    public func isValid(at date: Date, calendar: Calendar = .current) -> Bool {
        if let expiresOn { return Self.day(of: date, calendar: calendar) <= expiresOn }
        if let expiresAt { return date < expiresAt }
        return true
    }

    /// Whole days from today to the last day: 0 on the last day, negative once it's over, nil for keeps.
    public func daysLeft(at date: Date, calendar: Calendar = .current) -> Int? {
        if let expiresOn {
            let parts = expiresOn.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let last = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: last).day
        }
        guard let expiresAt else { return nil }
        return Int((expiresAt.timeIntervalSince(date) / 86_400).rounded(.down))
    }

    /// The expiry for people: "December 31, 2027", or nil for keeps.
    public func expiryText(style: Date.FormatStyle.DateStyle = .long, calendar: Calendar = .current) -> String? {
        if let expiresOn {
            let parts = expiresOn.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let noon = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return expiresOn }
            return noon.formatted(Date.FormatStyle(date: style, time: .omitted, timeZone: calendar.timeZone))
        }
        return expiresAt?.formatted(Date.FormatStyle(date: style, time: .omitted, timeZone: calendar.timeZone))
    }

    static func day(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// `INK1.<payload>.<signature>`: base64url JSON and a base64url Ed25519 signature over those payload bytes.
public enum LicenseKey {
    public static let prefix = "INK1"

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Issues a key. Used by the owner's script and by tests; the app never signs.
    public static func sign(_ license: License, with privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payload = try encoder.encode(license)
        let signature = try privateKey.signature(for: payload)
        return [prefix, base64URL(payload), base64URL(signature)].joined(separator: ".")
    }

    /// The license inside a key, if the signature is the publisher's. Whitespace and line breaks from an email are ignored.
    public static func verify(_ key: String, publicKey: Curve25519.Signing.PublicKey) throws -> License {
        let compact = key.filter { !$0.isWhitespace }
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix else { throw LicenseError.malformed }
        guard let payload = data(base64URL: parts[1]), let signature = data(base64URL: parts[2]) else { throw LicenseError.malformed }
        guard publicKey.isValidSignature(signature, for: payload) else { throw LicenseError.badSignature }
        do {
            return try decoder.decode(License.self, from: payload)
        } catch {
            throw LicenseError.malformed
        }
    }
}

public enum LicenseError: Error, LocalizedError, Equatable {
    case malformed
    case badSignature
    case expired(String)

    public var errorDescription: String? {
        switch self {
        case .malformed: return "That doesn't look like an InkRelay license key. Paste the whole key, starting with INK1."
        case .badSignature: return "This license key wasn't issued for InkRelay, or it was changed."
        case .expired(let date): return "This license expired on \(date)."
        }
    }
}

/// The publisher's public key. Replace it only together with the private key in `make-license --init`.
public enum LicensePublisher {
    /// Where a key comes from. An email to the publisher until a checkout exists; keys are issued by hand.
    public static let purchaseURL = URL(string: "mailto:hello@inkrelay.app?subject=InkRelay%20Pro%20license")!
    /// The same, for a sentence: "hello@inkrelay.app" rather than a mailto link.
    public static var purchaseText: String {
        purchaseURL.scheme == "mailto" ? (purchaseURL.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? "") : purchaseURL.absoluteString
    }

    public static let publicKeyBase64 = "Jgj+VBNXaf/l0/Ls1OOs10A1djYptKsuLby8jkbXEJw="

    public static var publicKey: Curve25519.Signing.PublicKey? {
        guard let data = Data(base64Encoded: publicKeyBase64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}
