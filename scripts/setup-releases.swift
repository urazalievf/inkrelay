// Sets up signed, notarized releases in one go:
//   swift scripts/setup-releases.swift ~/Downloads/AuthKey_ABC123XYZ9.p8 <issuer-id> [--tag]
//
// 1. Finds the "Developer ID Application" identity in your keychain, or creates one through the
//    App Store Connect API with the same key notarization uses (falls back to Xcode if Apple refuses).
// 2. Exports only that identity, with a random password, and stores everything the release workflow
//    needs as repository secrets with `gh secret set`. Nothing is printed or written to the repo.
// 3. With --tag, tags the current version and pushes the tag, which starts the release.
//
// Other modes: --dry-run (look, change nothing), --self-test (check the JWT signing).
import CryptoKit
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
    exit(1)
}

func say(_ message: String) { print("• " + message) }

@discardableResult
func run(_ tool: String, _ arguments: [String], input: Data? = nil) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    let stdin = Pipe()
    if input != nil { process.standardInput = stdin }
    do { try process.run() } catch { return (-1, error.localizedDescription) }
    if let input {
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
    }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, text)
}

// MARK: App Store Connect

/// An ES256 JWT for the App Store Connect API, valid for 15 minutes.
func appStoreToken(keyPEM: String, keyID: String, issuer: String, now: Date = Date()) throws -> String {
    func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"], options: [.sortedKeys])
    let claims = try JSONSerialization.data(withJSONObject: [
        "iss": issuer, "iat": Int(now.timeIntervalSince1970), "exp": Int(now.timeIntervalSince1970) + 900, "aud": "appstoreconnect-v1",
    ], options: [.sortedKeys])
    let signingInput = base64URL(header) + "." + base64URL(claims)
    let key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
    let signature = try key.signature(for: Data(signingInput.utf8))
    return signingInput + "." + base64URL(signature.rawRepresentation)
}

func appStore(_ method: String, _ path: String, token: String, body: [String: Any]? = nil) -> (Int, [String: Any]) {
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/" + path)!)
    request.httpMethod = method
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if let body {
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let done = DispatchSemaphore(value: 0)
    var result: (Int, [String: Any]) = (0, [:])
    URLSession.shared.dataTask(with: request) { data, response, _ in
        result = ((response as? HTTPURLResponse)?.statusCode ?? 0, (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:])
        done.signal()
    }.resume()
    done.wait()
    return result
}

/// Creates a Developer ID Application certificate for a fresh key pair and imports both into the login keychain.
func createDeveloperID(token: String, work: URL) -> Bool {
    let key = work.appendingPathComponent("developer-id.key").path
    let csr = work.appendingPathComponent("developer-id.csr").path
    let (status, output) = run("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-subj", "/CN=InkRelay Developer ID"])
    guard status == 0, let csrText = try? String(contentsOfFile: csr, encoding: .utf8) else { fail("openssl couldn't make a signing request: \(output)") }
    for type in ["DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION"] {
        let (code, reply) = appStore("POST", "certificates", token: token, body: [
            "data": ["type": "certificates", "attributes": ["certificateType": type, "csrContent": csrText]],
        ])
        guard code == 201,
              let content = ((reply["data"] as? [String: Any])?["attributes"] as? [String: Any])?["certificateContent"] as? String,
              let der = Data(base64Encoded: content) else {
            let detail = ((reply["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? "HTTP \(code)"
            say("Apple didn't create a \(type) certificate: \(detail)")
            continue
        }
        let certificate = work.appendingPathComponent("developer-id.cer")
        try? der.write(to: certificate)
        let p12 = work.appendingPathComponent("import.p12").path
        let password = UUID().uuidString
        let (packed, packOutput) = run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", certificate.path, "-inform", "DER", "-out", p12, "-passout", "pass:" + password, "-legacy"])
        if packed != 0 {
            // Older openssl builds have no -legacy flag.
            let (again, againOutput) = run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certificate.path, "-out", certificate.path + ".pem"])
            guard again == 0 else { fail("Couldn't package the certificate: \(packOutput) \(againOutput)") }
            _ = run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", certificate.path + ".pem", "-out", p12, "-passout", "pass:" + password])
        }
        let (imported, importOutput) = run("/usr/bin/security", ["import", p12, "-k", NSHomeDirectory() + "/Library/Keychains/login.keychain-db", "-P", password, "-T", "/usr/bin/codesign"])
        guard imported == 0 else { fail("Couldn't import the certificate into your keychain: \(importOutput)") }
        say("Created and installed a Developer ID Application certificate.")
        return true
    }
    return false
}

// MARK: Keychain

/// The Developer ID Application identity in the keychains, by its certificate's name.
func developerIdentity() -> (SecIdentity, String)? {
    let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
    var items: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let identities = items as? [SecIdentity] else { return nil }
    for identity in identities {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              let name = SecCertificateCopySubjectSummary(certificate) as String?, name.hasPrefix("Developer ID Application") else { continue }
        return (identity, name)
    }
    return nil
}

/// Exports one identity as PKCS #12. macOS asks for permission to export the private key.
func export(_ identity: SecIdentity, password: String) -> Data? {
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passUnretained(password as CFString)
    var data: CFData?
    guard SecItemExport(identity, .formatPKCS12, [], &parameters, &data) == errSecSuccess else { return nil }
    return data as Data?
}

// MARK: Main

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--self-test") {
    let key = P256.Signing.PrivateKey()
    let token = try appStoreToken(keyPEM: key.pemRepresentation, keyID: "TESTKEY123", issuer: "00000000-0000-0000-0000-000000000000")
    let parts = token.split(separator: ".").map(String.init)
    func decode(_ text: String) -> Data {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)!
    }
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
    let valid = key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8))
    let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as! [String: String]
    print(valid && header["alg"] == "ES256" && header["kid"] == "TESTKEY123" ? "self-test passed" : "self-test FAILED")
    exit(valid ? 0 : 1)
}

let dryRun = arguments.contains("--dry-run")
let positional = arguments.filter { !$0.hasPrefix("--") }
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

let (ghStatus, ghOutput) = run("/usr/bin/env", ["gh", "auth", "status"])
guard ghStatus == 0 else { fail("Sign in to GitHub's command line first: gh auth login\n\(ghOutput)") }

var identity = developerIdentity()
say(identity.map { "Found \($0.1) in your keychain." } ?? "No Developer ID Application certificate in your keychain yet.")

guard positional.count >= 2 else {
    print("""

    Usage: swift scripts/setup-releases.swift <AuthKey_KEYID.p8> <issuer-id> [--tag] [--dry-run]

    Make the key once at https://appstoreconnect.apple.com/access/integrations/api → Team Keys → +,
    with the Admin role (Developer is enough when the certificate already exists). Download the .p8
    and copy the Issuer ID shown above the list. The same key signs notarization requests.
    """)
    exit(dryRun ? 0 : 1)
}
let keyURL = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath)
let issuer = positional[1]
guard let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8) else { fail("Can't read \(keyURL.path).") }
let keyID = keyURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "AuthKey_", with: "")
guard keyID.count == 10 else { fail("The key file should be named AuthKey_<KEY ID>.p8, as App Store Connect downloads it.") }
let token: String
do { token = try appStoreToken(keyPEM: keyPEM, keyID: keyID, issuer: issuer) } catch { fail("That doesn't look like an App Store Connect key: \(error.localizedDescription)") }
let (checked, _) = appStore("GET", "certificates?limit=1", token: token)
guard checked == 200 else { fail("App Store Connect refused the key (HTTP \(checked)). Check the issuer id and that the key isn't revoked.") }
say("The App Store Connect key works.")

if dryRun {
    say("Dry run: nothing was created or stored.")
    exit(0)
}

if identity == nil {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("inkrelay-release-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    if createDeveloperID(token: token, work: work) { identity = developerIdentity() }
    guard identity != nil else {
        fail("""
        Apple doesn't let API keys create Developer ID certificates; only the Account Holder can, on the website or in Xcode:
          • developer.apple.com/account/resources/certificates/add → Developer ID Application → G2 Sub-CA → upload a CSR
            (openssl req -new -newkey rsa:2048 -nodes -keyout developer-id.key -out developer-id.csr -subj "/CN=Developer ID"),
            download the .cer, and import key and certificate into the login keychain; or
          • Xcode → Settings → Accounts → your team → Manage Certificates → + → Developer ID Application.
        Then run this again.
        """)
    }
}

let (chosen, name) = identity!
let password = UUID().uuidString + UUID().uuidString
say("Exporting \(name); macOS will ask you to allow it.")
guard let p12 = export(chosen, password: password) else { fail("The keychain didn't allow exporting the certificate.") }

let secrets: [(String, String)] = [
    ("DEVELOPER_ID_P12_BASE64", p12.base64EncodedString()),
    ("DEVELOPER_ID_P12_PASSWORD", password),
    ("DEVELOPER_ID_NAME", name),
    ("NOTARY_KEY_P8_BASE64", Data(keyPEM.utf8).base64EncodedString()),
    ("NOTARY_KEY_ID", keyID),
    ("NOTARY_ISSUER_ID", issuer),
]
for (secret, value) in secrets {
    let (status, output) = run("/usr/bin/env", ["gh", "secret", "set", secret, "--repo", "urazalievf/inkrelay"], input: Data(value.utf8))
    guard status == 0 else { fail("gh couldn't set \(secret): \(output)") }
}
say("Stored the six release secrets in urazalievf/inkrelay.")

if arguments.contains("--tag") {
    let source = (try? String(contentsOf: repository.appendingPathComponent("Sources/InkRelayCore/InkRelayCore.swift"), encoding: .utf8)) ?? ""
    guard let match = source.firstMatch(of: #/static let version = "([0-9.]+)"/#) else { fail("Couldn't read InkRelayCore.version.") }
    let tag = "v" + match.1
    let (checked, checkOutput) = run(repository.appendingPathComponent("scripts/check-version.sh").path, [tag])
    guard checked == 0 else { fail(checkOutput) }
    let (tagged, tagOutput) = run("/usr/bin/git", ["-C", repository.path, "tag", tag])
    guard tagged == 0 else { fail("git tag failed: \(tagOutput)") }
    let (pushed, pushOutput) = run("/usr/bin/git", ["-C", repository.path, "push", "origin", tag])
    guard pushed == 0 else { fail("git push failed: \(pushOutput)") }
    say("Pushed \(tag). The release workflow is building, signing and notarizing it: gh run watch --repo urazalievf/inkrelay")
} else {
    say("Done. Release with: git tag v<version> && git push origin v<version> (or run this again with --tag).")
}
