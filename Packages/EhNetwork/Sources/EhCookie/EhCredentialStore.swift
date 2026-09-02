import Foundation
import Security

/// Authentication cookies that must survive relaunch without being stored in
/// the plaintext HTTP cookie container.
public struct EhCredentials: Codable, Sendable, Equatable {
    public var memberId: String?
    public var passHash: String?
    public var igneous: String?

    public init(memberId: String? = nil, passHash: String? = nil, igneous: String? = nil) {
        self.memberId = memberId
        self.passHash = passHash
        self.igneous = igneous
    }

    public var isEmpty: Bool {
        memberId == nil && passHash == nil && igneous == nil
    }
}

/// Device-local Keychain persistence for the long-lived EH session.
public enum EhCredentialStore {
    private static let service = "com.ehviewer.credentials"
    private static let account = "eh-session"
    private nonisolated(unsafe) static var availabilityCache: Bool?

    public private(set) nonisolated(unsafe) static var lastError: OSStatus = errSecSuccess

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Unsigned builds can lack the application identifier required by the
    /// Keychain. In that case callers retain persistent cookies so login is
    /// not silently lost between launches.
    public static var isAvailable: Bool {
        if let cached = availabilityCache { return cached }
        let probeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "availability-probe",
            kSecValueData as String: Data([0]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(probeQuery as CFDictionary)
        let status = SecItemAdd(probeQuery as CFDictionary, nil)
        let available = status == errSecSuccess || status == errSecDuplicateItem
        if available {
            SecItemDelete(probeQuery as CFDictionary)
            availabilityCache = true
        } else {
            lastError = status
            // Missing entitlement cannot recover during this process. A
            // temporarily locked Keychain can, so do not cache that failure.
            if status == errSecMissingEntitlement {
                availabilityCache = false
            }
        }
        return available
    }

    public static func load() -> EhCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(EhCredentials.self, from: data)
        else { return nil }
        return credentials
    }

    @discardableResult
    public static func save(_ credentials: EhCredentials) -> Bool {
        guard !credentials.isEmpty else { return clear() }
        guard let data = try? JSONEncoder().encode(credentials) else { return false }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess { lastError = addStatus }
        return addStatus == errSecSuccess
    }

    @discardableResult
    public static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
