import Foundation
import Security
import SGLogging

public enum KeychainError: Error {
    case duplicateEntry
    case unknown(OSStatus)
    case itemNotFound
    case invalidItemFormat
}

public class KeychainBackupManager {
    public static let shared = KeychainBackupManager()
    private let service = "\(Bundle.main.bundleIdentifier!).sessionsbackup"
    /// Set once every stored session sits at `WhenUnlockedThisDeviceOnly` (audit #72).
    private let accessibilityUpgradeKey = "zg.backup.accessibility.v1"
    
    private init() {}
    
    // MARK: - Save Credentials
    public func saveSession(id: String, _ session: Data) throws {
        // Create query dictionary
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecValueData as String: session,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Add to keychain
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status == errSecDuplicateItem {
            // Item already exists, update it
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: id
            ]
            
            // Zenlygram — audit #72: the add path already pins `WhenUnlockedThisDeviceOnly`, but the
            // update path used to leave the accessibility of an item written by an older build
            // untouched (default `WhenUnlocked`, which IS carried by an encrypted backup / Quick
            // Start). Re-assert it on every write so a re-backup also heals the old item.
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: session,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary,
                                          attributesToUpdate as CFDictionary)
            
            if updateStatus != errSecSuccess {
                throw KeychainError.unknown(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unknown(status)
        }
    }
    
    // MARK: - Accessibility Upgrade
    /// All stored session attributes. `nil` means the read failed outright (for example
    /// `errSecInteractionNotAllowed` before the first unlock); `isNotFound` means the service
    /// answered `errSecItemNotFound`.
    ///
    /// IMPORTANT: neither an empty `items` nor `isNotFound` proves the service is empty — while the
    /// device is locked the system silently omits `WhenUnlocked` / `WhenUnlockedThisDeviceOnly` items,
    /// so the whole service reads as absent. Callers must qualify both with `protectedDataAvailable`
    /// (the same rule as `ChatPincodeManager.enumerateLockedKeychainAccounts`).
    private func copyAllAttributes() -> (items: [[String: Any]], isNotFound: Bool)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            // A persistent reference addresses an item that carries no account attribute, so the sweep
            // can still move it instead of leaving it off-target — and the flag unset — forever.
            kSecReturnPersistentRef as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return ([], true)
        }

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return nil
        }

        return (items, false)
    }

    /// Zenlygram — audit #72: sessions written by an older build may still be `WhenUnlocked`, which
    /// travels with an encrypted iTunes/Finder backup and with Quick Start. `kSecAttrAccessible` is
    /// updatable in place (unlike `kSecAttrAccessControl`), so a plain `SecItemUpdate` is enough —
    /// no delete-and-re-add, and therefore no window in which the auth keys could be lost.
    ///
    /// Cheap and idempotent: after the first fully successful sweep the flag short-circuits it.
    /// The flag means "every stored item was *verified* at `WhenUnlockedThisDeviceOnly`", not merely
    /// "every update call returned success" — the attributes are re-read afterwards, so a partial
    /// sweep (some items upgraded, some not) leaves the flag unset and retries on the next run
    /// rather than letting the device-only notice cover items that are still `WhenUnlocked`.
    ///
    /// The caller must pass `UIApplication.shared.isProtectedDataAvailable` (this module deliberately
    /// stays free of UIKit, so the value comes from the app side). It is not optional: a locked device
    /// hides every `WhenUnlocked` item, so the service reads as empty and "nothing stored" becomes
    /// indistinguishable from "everything is hidden by the lock screen". The flag is therefore only
    /// ever set on a read taken while protected data is available; a locked or unreadable Keychain
    /// just means "retry next launch".
    public func upgradeAccessibilityIfNeeded(protectedDataAvailable: Bool) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: self.accessibilityUpgradeKey) {
            return
        }

        guard protectedDataAvailable else {
            // A locked device hides every WhenUnlocked item, so the service reads as empty and the
            // sweep would "verify" nothing. Retry on the next launch / unlock instead.
            SGLogger.shared.log("SessionBackup", "Accessibility sweep: protected data unavailable, retrying later")
            return
        }

        guard let read = self.copyAllAttributes() else {
            // Keychain temporarily unreadable — retry on the next launch / unlock.
            SGLogger.shared.log("SessionBackup", "Accessibility sweep: keychain unreadable, retrying later")
            return
        }

        if read.items.isEmpty {
            // Trustworthy only because protected data is known available: an empty read (whether
            // `errSecItemNotFound` or an empty success) really is "nothing stored" here rather than
            // "every item is hidden by the lock screen". Whatever is written from now on is created
            // device-only by `saveSession`.
            defaults.set(true, forKey: self.accessibilityUpgradeKey)
            return
        }

        let target = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        var upgraded = 0
        var updateFailures = 0
        for item in read.items {
            if let accessible = item[kSecAttrAccessible as String] as? String, accessible == target {
                continue
            }

            // Address the item by service + account, falling back to its persistent reference for an
            // item that somehow carries no account attribute (`saveSession` always sets one).
            let updateQuery: [String: Any]
            if let account = item[kSecAttrAccount as String] as? String {
                updateQuery = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
            } else if let persistentRef = item[kSecValuePersistentRef as String] as? Data {
                updateQuery = [
                    kSecValuePersistentRef as String: persistentRef
                ]
            } else {
                updateFailures += 1
                SGLogger.shared.log("SessionBackup", "Accessibility sweep: stored item with neither an account attribute nor a persistent reference, skipped")
                continue
            }

            let attributesToUpdate: [String: Any] = [
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]

            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus == errSecSuccess {
                upgraded += 1
            } else {
                updateFailures += 1
                // The account id is a Telegram peer id, so it is not logged.
                SGLogger.shared.log("SessionBackup", "Accessibility upgrade failed for one session: \(updateStatus)")
            }
        }

        // Verify instead of inferring: re-read the attributes and only claim the device-only promise
        // once every stored item actually sits at the target accessibility.
        guard let verified = self.copyAllAttributes() else {
            SGLogger.shared.log("SessionBackup", "Accessibility sweep: verification read failed (upgraded \(upgraded), failed \(updateFailures))")
            return
        }

        // The verification must also be authoritative: `isNotFound`, or fewer items than the sweep
        // itself saw, means protected data went away mid-sweep (or a concurrent `deleteSession` from
        // the Session Backup screen ran) and proves nothing. Leave the flag unset and retry — the
        // sweep is idempotent, so a spurious retry is harmless while a spurious flag is not.
        let stillOpen = verified.items.filter { ($0[kSecAttrAccessible as String] as? String) != target }.count
        if stillOpen == 0 && !verified.isNotFound && verified.items.count >= read.items.count {
            defaults.set(true, forKey: self.accessibilityUpgradeKey)
            SGLogger.shared.log("SessionBackup", "Accessibility sweep complete: \(verified.items.count) session(s) device-only (\(upgraded) upgraded now)")
        } else {
            SGLogger.shared.log("SessionBackup", "Accessibility sweep incomplete: \(stillOpen) of \(verified.items.count) session(s) still not device-only (read \(read.items.count), upgraded \(upgraded), failed \(updateFailures))")
        }
    }
    
    // MARK: - Retrieve Credentials
    public func retrieveSession(for id: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let sessionData = result as? Data else {
            throw KeychainError.itemNotFound
        }
        
        return sessionData
    }
    
    // MARK: - Delete Credentials
    public func deleteSession(for id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unknown(status)
        }
    }
    
    // MARK: - Retrieve All Accounts
    public func getAllSessons() throws -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return []
        }
        
        guard status == errSecSuccess,
              let credentialsDataArray = result as? [Data] else {
            throw KeychainError.unknown(status)
        }
        
        return credentialsDataArray
    }
    
    // MARK: - Delete All Sessions
    public func deleteAllSessions() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        // If no items were found, that's fine - just return
        if status == errSecItemNotFound {
            return
        }
        
        // For any other error, throw
        if status != errSecSuccess {
            throw KeychainError.unknown(status)
        }
    }
}
