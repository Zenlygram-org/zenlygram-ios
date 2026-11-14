import Foundation
import Security
import SGAppGroupIdentifier

/// Result of reading one generic-password item. Only `errSecItemNotFound` is `.absent`; every other failure
/// (device locked before first unlock, missing entitlement, …) is `.unreadable` so callers can fail closed.
public enum SGKeychainReadResult {
    case present(Data)
    case absent
    case unreadable(OSStatus)
}

/// Result of an attributes-only presence probe (never reads the secret itself).
public enum SGKeychainProbeResult {
    case present
    case absent
    case unreadable(OSStatus)
}

/// Zenlygram — minimal generic-password helpers for the protection store (audit batch 3).
///
/// - Items shared with the app extensions live in the app-group access group (`sharedAccessGroup`): iOS adds
///   `com.apple.security.application-groups` to every process's keychain access groups, so the app and all its
///   extensions can reach it without a `keychain-access-groups` entitlement.
/// - App-private items (Chat Lock credentials, legacy blobs) are always queried with `accessGroup: nil`, i.e.
///   they stay in the app's default group (its application-identifier).
/// - Every write uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (audit #30): background launches and
///   extensions must be able to read protection state while the phone is locked.
/// - `errSecMissingEntitlement` (-34018) means "no keychain" only in a keychain-less build
///   (`isKeychainlessBuild`); everywhere else it is an ordinary unreadable result.
public enum SGProtectedKeychain {
    public static let sharedAccessGroup: String = sgAppGroupIdentifier()

    /// Build-time switch for the keychain-less fallbacks. Only fake-codesigned simulator builds and DEBUG builds
    /// may treat `errSecMissingEntitlement` (-34018) as "there is no keychain" and use the plaintext app-group
    /// copies. Signed release builds treat -34018 as unreadable (fail closed) and never write plaintext.
    /// The default local build is `debug_sim_arm64` (see CLAUDE.md), which is keychain-less.
    #if DEBUG || targetEnvironment(simulator)
    public static let isKeychainlessBuild: Bool = true
    #else
    public static let isKeychainlessBuild: Bool = false
    #endif

    private static func baseQuery(service: String, account: String?, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public static func read(service: String, account: String, accessGroup: String?) -> SGKeychainReadResult {
        var query = self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            if let data = item as? Data {
                return .present(data)
            }
            return .unreadable(errSecDecode)
        case errSecItemNotFound:
            return .absent
        default:
            return .unreadable(status)
        }
    }

    /// Attributes-only presence check (the secret is never returned).
    public static func probe(service: String, account: String, accessGroup: String?) -> SGKeychainProbeResult {
        var query = self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return .present
        case errSecItemNotFound:
            return .absent
        default:
            return .unreadable(status)
        }
    }

    /// Update, then add. Both paths set `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
    @discardableResult
    public static func write(_ data: Data, service: String, account: String, accessGroup: String?) -> OSStatus {
        let query = self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return errSecSuccess
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem && updateStatus != errSecItemNotFound {
            // The item exists but could not be updated (e.g. not accessible right now): report why.
            return updateStatus
        }
        return addStatus
    }

    @discardableResult
    public static func delete(service: String, account: String, accessGroup: String?) -> OSStatus {
        return SecItemDelete(self.baseQuery(service: service, account: account, accessGroup: accessGroup) as CFDictionary)
    }

    /// Every `kSecAttrAccount` stored under `service` (attributes only, never the secrets). Empty when
    /// there is none or the Keychain cannot be read.
    public static func accounts(service: String, accessGroup: String?) -> [String] {
        var query = self.baseQuery(service: service, account: nil, accessGroup: accessGroup)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Moves every item of an app-private `service` (queried without an access group) to
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in place (migration M1, audit #30).
    ///
    /// Enumerates attributes only (`kSecMatchLimitAll` is never combined with `kSecReturnData`), then updates
    /// the class of each item that is not in it yet. Returns true only when nothing is left to fix. Must run
    /// while protected data is available: a locked device may silently omit `WhenUnlocked` items.
    public static func upgradeAccessibility(service: String) -> Bool {
        var query = self.baseQuery(service: service, account: nil, accessGroup: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return true
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return false
        }
        let target = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        var isDone = true
        for item in items {
            if let accessible = item[kSecAttrAccessible as String] as? String, accessible == target {
                continue
            }
            guard let account = item[kSecAttrAccount as String] as? String else {
                isDone = false
                continue
            }
            let itemQuery = self.baseQuery(service: service, account: account, accessGroup: nil)
            let update: [String: Any] = [
                kSecAttrAccessible as String: target
            ]
            if SecItemUpdate(itemQuery as CFDictionary, update as CFDictionary) != errSecSuccess {
                isDone = false
            }
        }
        return isDone
    }
}
