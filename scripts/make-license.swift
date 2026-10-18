// Issues InkRelay Pro license keys. The signing key lives only on the owner's Mac, never in the repo.
//
//   swift scripts/make-license.swift --init
//       Makes the key pair once: the private key goes to
//       ~/Library/Application Support/InkRelay/licensing/signing-key (owner-only file), and the public key is
//       written into Sources/InkRelayCore/Licensing/License.swift. Rebuild after this.
//   swift scripts/make-license.swift --name "Ada Lovelace" --email ada@example.com [--expires 2027-12-31]
//       Prints a key to send to the customer.
//   swift scripts/make-license.swift --verify INK1.…
//       Checks a key against the public key on this Mac and prints what's in it.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
    exit(1)
}

let keyFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/InkRelay/licensing", isDirectory: true)
let privateKeyURL = keyFolder.appendingPathComponent("signing-key")
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = repository.appendingPathComponent("Sources/InkRelayCore/Licensing/License.swift")

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func data(base64URL text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    return Data(base64Encoded: base64)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let raw = try? Data(contentsOf: privateKeyURL), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No signing key at \(privateKeyURL.path). Run with --init once.")
    }
    return key
}

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--init") {
    guard !FileManager.default.fileExists(atPath: privateKeyURL.path) || arguments.contains("--force") else {
        fail("A signing key already exists at \(privateKeyURL.path). Keys issued with it stop working if you replace it; pass --force if that's what you want.")
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try key.rawRepresentation.write(to: privateKeyURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    var source = try String(contentsOf: sourceURL, encoding: .utf8)
    guard let range = source.range(of: #"public static let publicKeyBase64 = "[^"]*""#, options: .regularExpression) else {
        fail("Couldn't find publicKeyBase64 in \(sourceURL.path).")
    }
    source.replaceSubrange(range, with: "public static let publicKeyBase64 = \"\(publicKey)\"")
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    print("• Private key: \(privateKeyURL.path) (keep it; back it up somewhere private).")
    print("• Public key written to \(sourceURL.lastPathComponent): \(publicKey)")
    print("• Rebuild the app and commit the public key.")
    exit(0)
}

if let key = option("--verify") {
    var source = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
    guard let range = source.range(of: #"publicKeyBase64 = "([^"]*)""#, options: .regularExpression) else { fail("No public key in the source.") }
    source = String(source[range])
    let encoded = source.split(separator: "\"")[1]
    guard let raw = Data(base64Encoded: String(encoded)), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { fail("The public key in the source isn't set.") }
    let compact = key.filter { !$0.isWhitespace }
    let parts = compact.split(separator: ".").map(String.init)
    guard parts.count == 3, parts[0] == "INK1", let payload = data(base64URL: parts[1]), let signature = data(base64URL: parts[2]) else { fail("Not an InkRelay key.") }
    guard publicKey.isValidSignature(signature, for: payload) else { fail("Bad signature.") }
    print("✓ Valid. " + String(decoding: payload, as: UTF8.self))
    exit(0)
}

guard let name = option("--name"), let email = option("--email") else {
    print("""
    Usage:
      swift scripts/make-license.swift --init
      swift scripts/make-license.swift --name "Ada Lovelace" --email ada@example.com [--expires YYYY-MM-DD]
      swift scripts/make-license.swift --verify INK1.…
    """)
    exit(1)
}

var expires: Date?
if let text = option("--expires") {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    guard let date = formatter.date(from: text) else { fail("--expires takes YYYY-MM-DD.") }
    expires = date
}

// The same fields and order as `License` in InkRelayCore, so the app decodes what this signs.
let id = String(UUID().uuidString.prefix(8)).lowercased()
var payload: [String: Any] = ["id": id, "name": name, "email": email, "plan": "pro", "issuedAt": ISO8601DateFormatter().string(from: Date())]
if let expires { payload["expiresAt"] = ISO8601DateFormatter().string(from: expires) }
let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
let signature = try loadPrivateKey().signature(for: payloadData)
let key = ["INK1", base64URL(payloadData), base64URL(signature)].joined(separator: ".")
print(key)
FileHandle.standardError.write(Data("• Issued \(id) to \(name) <\(email)>\(expires.map { ", expires \($0.formatted(date: .long, time: .omitted))" } ?? ", for keeps").\n".utf8))
