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
    /// Nil is for keeps.
    public var expiresAt: Date?

    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), name: String, email: String, plan: String = "pro", issuedAt: Date, expiresAt: Date? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.plan = plan
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func isValid(at date: Date) -> Bool {
        guard let expiresAt else { return true }
        return date < expiresAt
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
    case expired(Date)

    public var errorDescription: String? {
        switch self {
        case .malformed: return "That doesn't look like an InkRelay license key. Paste the whole key, starting with INK1."
        case .badSignature: return "This license key wasn't issued for InkRelay, or it was changed."
        case .expired(let date): return "This license expired on \(date.formatted(date: .long, time: .omitted))."
        }
    }
}

/// The publisher's public key. Replace it only together with the private key in `make-license --init`.
public enum LicensePublisher {
    public static let publicKeyBase64 = "Jgj+VBNXaf/l0/Ls1OOs10A1djYptKsuLby8jkbXEJw="

    public static var publicKey: Curve25519.Signing.PublicKey? {
        guard let data = Data(base64Encoded: publicKeyBase64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}
