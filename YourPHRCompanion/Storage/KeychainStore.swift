import Foundation
import Security

/// Token, base URL, device id, and HealthKit anchors live here — not in UserDefaults.
/// A stolen backup of the app container should not contain the access token in plaintext plist.
final class KeychainStore {
    static let shared = KeychainStore()

    static let service = "com.epipc.ipc-health"

    enum Account {
        static let token = "token"
        static let refreshToken = "refresh_token"
        static let grantEndsAt = "grant_ends_at"
        static let accessExpiresAt = "access_expires_at"
        static let deviceLabel = "device_label"
        /// The refresh token already presented. A second send would revoke the grant.
        static let presentedRefresh = "presented_refresh"
        static let baseURL = "base_url"
        static let deviceID = "device_id"
        static let anchors = "anchors"
        static let username = "username"
    }

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unexpectedStatus(update) }
        } else if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.unexpectedStatus(added) }
        } else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func removeAll() {
        [
            Account.token, Account.refreshToken, Account.grantEndsAt, Account.accessExpiresAt,
            Account.deviceLabel, Account.presentedRefresh, Account.baseURL, Account.deviceID,
            Account.anchors, Account.username,
        ].forEach(remove)
    }

    /// Mark this refresh token as presented before the request leaves the phone.
    func beginPresentedRefresh() throws -> String {
        guard let refresh = get(account: Account.refreshToken), !refresh.isEmpty else {
            throw APIClientError.notPaired
        }
        if get(account: Account.presentedRefresh) == refresh {
            throw APIClientError.refreshInterrupted
        }
        try set(refresh, account: Account.presentedRefresh)
        return refresh
    }

    func clearPresentedRefresh() {
        remove(account: Account.presentedRefresh)
    }

    /// Refresh token first, then the access token, so a crash cannot keep the spent refresh.
    func commitGrant(_ grant: DeviceGrant, server: String? = nil) throws {
        try set(grant.refreshToken, account: Account.refreshToken)
        try set(grant.accessToken, account: Account.token)
        try set(grant.grantEndsAt, account: Account.grantEndsAt)
        try set(grant.label, account: Account.deviceLabel)
        let expires = Date().addingTimeInterval(TimeInterval(grant.expiresIn))
        try set(ISO8601DateFormatter.api.string(from: expires), account: Account.accessExpiresAt)
        if let server {
            try set(server, account: Account.baseURL)
        }
        clearPresentedRefresh()
    }

    func accessTokenNeedsRefresh(within seconds: TimeInterval = 300) -> Bool {
        guard let raw = get(account: Account.accessExpiresAt),
              let expires = ISO8601DateFormatter.api.date(from: raw) else {
            return true
        }
        return expires.timeIntervalSinceNow < seconds
    }

    /// Stable per-install id sent as `device.device_id`. Created once and reused so the server
    /// can attach sync anchors to this phone rather than inventing a new device on every launch.
    func deviceID() throws -> String {
        if let existing = get(account: Account.deviceID), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        try set(id, account: Account.deviceID)
        return id
    }
}
