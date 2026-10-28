import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

public enum IdentityKeyError: Error, Equatable {
    case invalidKeyRepresentation
    case signingFailed
    case keychainError(Int32)
    case keyNotFound
}

/// Persistent Ed25519 identity key for mutual host/client authentication.
public struct IdentityKey: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Curve25519.Signing.PublicKey

    public init() {
        let priv = Curve25519.Signing.PrivateKey()
        self.privateKey = priv
        self.publicKey = priv.publicKey
    }

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey
    }

    public init(rawRepresentation data: Data) throws {
        guard data.count == 32 else {
            throw IdentityKeyError.invalidKeyRepresentation
        }
        do {
            let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            self.privateKey = priv
            self.publicKey = priv.publicKey
        } catch {
            throw IdentityKeyError.invalidKeyRepresentation
        }
    }

    public var publicKeyData: Data {
        publicKey.rawRepresentation
    }

    public var privateKeyData: Data {
        privateKey.rawRepresentation
    }

    public func sign(_ data: Data) throws -> Data {
        do {
            return try privateKey.signature(for: data)
        } catch {
            throw IdentityKeyError.signingFailed
        }
    }

    public static func verify(signature: Data, for data: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        guard signature.count == 64 else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    public static func verify(signature: Data, for data: Data, publicKeyData: Data) -> Bool {
        guard publicKeyData.count == 32, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }
}

/// Abstract persistent store for long-term Ed25519 identity keys.
public protocol IdentityKeyStore: Sendable {
    func loadOrCreateIdentity() throws -> IdentityKey
    func forgetIdentity() throws
}

/// Thread-safe in-memory store for testing and ephemeral execution.
public final class InMemoryIdentityKeyStore: IdentityKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: IdentityKey?

    public init(initialKey: IdentityKey? = nil) {
        self.storedKey = initialKey
    }

    public func loadOrCreateIdentity() throws -> IdentityKey {
        lock.lock()
        defer { lock.unlock() }
        if let storedKey {
            return storedKey
        }
        let newKey = IdentityKey()
        storedKey = newKey
        return newKey
    }

    public func forgetIdentity() throws {
        lock.lock()
        defer { lock.unlock() }
        storedKey = nil
    }
}

#if canImport(Security)
/// Keychain-backed store for macOS and iOS production identities.
public final class KeychainIdentityKeyStore: IdentityKeyStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = NSLock()

    public init(service: String = "com.vpad.identity", account: String = "identityKey") {
        self.service = service
        self.account = account
    }

    public func loadOrCreateIdentity() throws -> IdentityKey {
        lock.lock()
        defer { lock.unlock() }

        if let existing = try loadLocked() {
            return existing
        }
        let created = IdentityKey()
        try saveLocked(created)
        return created
    }

    public func forgetIdentity() throws {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw IdentityKeyError.keychainError(status)
        }
    }

    private func loadLocked() throws -> IdentityKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw IdentityKeyError.keychainError(status)
        }
        return try IdentityKey(rawRepresentation: data)
    }

    private func saveLocked(_ key: IdentityKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.privateKeyData
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: key.privateKeyData
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus != errSecSuccess {
                throw IdentityKeyError.keychainError(updateStatus)
            }
        } else if status != errSecSuccess {
            throw IdentityKeyError.keychainError(status)
        }
    }
}
#endif
