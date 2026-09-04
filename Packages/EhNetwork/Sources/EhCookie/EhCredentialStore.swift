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
    private static let lock = NSLock()
    private nonisolated(unsafe) static var availabilityCache: Bool?

    private nonisolated(unsafe) static var storedError: OSStatus = errSecSuccess
    public static var lastError: OSStatus { lock.withLock { storedError } }

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
        lock.lock()
        defer { lock.unlock() }
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
            storedError = status
            // Missing entitlement cannot recover during this process. A
            // temporarily locked Keychain can, so do not cache that failure.
            if status == errSecMissingEntitlement {
                availabilityCache = false
            }
        }
        return available
    }

    public static func load() -> EhCredentials? {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        storedError = status
        if status == errSecSuccess { availabilityCache = true }
        guard status == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(EhCredentials.self, from: data)
        else { return nil }
        return credentials
    }

    @discardableResult
    public static func save(_ credentials: EhCredentials) -> Bool {
        guard !credentials.isEmpty else { return clear() }
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        lock.lock()
        defer { lock.unlock() }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        storedError = updateStatus
        if updateStatus == errSecSuccess {
            availabilityCache = true
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        storedError = addStatus
        if addStatus == errSecSuccess { availabilityCache = true }
        return addStatus == errSecSuccess
    }

    @discardableResult
    public static func clear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery as CFDictionary)
        storedError = status
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
