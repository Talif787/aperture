import Foundation
import Security
import ApertureAuth

/// Credential storage backed by the Keychain.
///
/// The accessibility class is the detail that matters here, and it is easy to get wrong in
/// a way that is invisible on a desk. Background uploads and background sync run while the
/// device is locked. A refresh token stored as `WhenUnlocked` becomes unreadable exactly
/// when the background session needs it, so every overnight sync fails with an
/// authentication error that cannot be reproduced by anyone holding an unlocked phone.
///
/// Every class used is a `ThisDeviceOnly` variant, so nothing travels in an encrypted
/// backup to a different device.
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.aperture.field", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func load() async throws -> TokenPair? {
        guard let data = try read(SecretKind.refreshToken.account) else { return nil }
        return try JSONDecoder().decode(StoredTokens.self, from: data).toTokenPair()
    }

    public func save(_ tokens: TokenPair) async throws {
        let data = try JSONEncoder().encode(StoredTokens(tokens))
        try write(data, account: SecretKind.refreshToken.account, policy: SecretKind.refreshToken.accessPolicy)
    }

    public func clear() async throws {
        try delete(SecretKind.refreshToken.account)
    }

    // MARK: - Keychain primitives

    private func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func write(_ data: Data, account: String, policy: KeychainAccessPolicy) throws {
        let query = baseQuery(account)

        // Update first, then add. The reverse order produces a duplicate-item error on
        // every refresh after the first, which is a confusing way to discover that tokens
        // rotate.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: policy.secAttrAccessibleValue
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = policy.secAttrAccessibleValue

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    private func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// The on-disk shape, kept separate from the domain type.
///
/// `TokenPair` is free to change its shape for readability; this one cannot, because a
/// change would make every already-stored credential unreadable and sign out the entire
/// fleet on upgrade.
private struct StoredTokens: Codable {
    let accessToken: String
    let accessTokenExpiry: Date
    let refreshToken: String
    let refreshTokenExpiry: Date
    let issuedAt: Date

    init(_ pair: TokenPair) {
        accessToken = pair.accessToken
        accessTokenExpiry = pair.accessTokenExpiry
        refreshToken = pair.refreshToken
        refreshTokenExpiry = pair.refreshTokenExpiry
        issuedAt = pair.issuedAt
    }

    func toTokenPair() -> TokenPair {
        TokenPair(
            accessToken: accessToken,
            accessTokenExpiry: accessTokenExpiry,
            refreshToken: refreshToken,
            refreshTokenExpiry: refreshTokenExpiry,
            issuedAt: issuedAt
        )
    }
}
