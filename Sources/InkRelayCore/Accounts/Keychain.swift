import Foundation
import Security

/// Somewhere to keep API secrets that aren't OAuth sessions: the Notion token, the AI transcription key.
public protocol SecretStore {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String, for account: String) throws
    func deleteSecret(for account: String) throws
}

/// The login keychain, as generic passwords under the service "InkRelay".
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "InkRelay") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func secret(for account: String) throws -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "InkRelay \(account)"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    public func deleteSecret(for account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public var status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain: \(message)"
    }
}

/// For tests.
public final class MemorySecretStore: SecretStore {
    public var secrets: [String: String]

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public func secret(for account: String) throws -> String? { secrets[account] }
    public func setSecret(_ value: String, for account: String) throws { secrets[account] = value }
    public func deleteSecret(for account: String) throws { secrets[account] = nil }
}

/// A token that doesn't expire, read from a secret store. Notion integration tokens work this way.
final class StoredToken: AccessTokenProvider {
    let service: String
    let account: String
    let loginCommand: String
    private let store: SecretStore

    init(service: String, account: String, loginCommand: String, store: SecretStore) {
        self.service = service
        self.account = account
        self.loginCommand = loginCommand
        self.store = store
    }

    func accessToken() throws -> String {
        guard let token = try store.secret(for: account), !token.isEmpty else {
            throw CloudAPIError.notSignedIn(service, loginCommand)
        }
        return token
    }

    func invalidate() {}
}
