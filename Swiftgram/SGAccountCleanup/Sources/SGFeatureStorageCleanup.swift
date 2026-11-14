import Foundation
import Security
import SGAppGroupIdentifier

/// The storage operations `SGFeatureStorageCleanup` performs. `SGFeatureSystemStorage` is the device;
/// host tests inject an in-memory Keychain and defaults over temporary directories.
protocol SGFeatureStorage {
    /// Every `kSecAttrAccount` of the service, or nil when the Keychain cannot be read now (before the
    /// first unlock): nothing is deleted then and the next launch's sweep tries again.
    func keychainAccounts(service: String) -> [String]?
    func deleteKeychainItem(service: String, account: String)
    /// The directories whose direct children may be `sgf1` entries.
    func roots() -> [URL]
    /// Direct children of a directory, nil when it cannot be listed (missing, not a directory).
    func children(of directory: URL) -> [URL]?
    func removeItem(_ url: URL)
    func defaultsKeys() -> [String]
    func removeDefault(forKey key: String)
}

/// Zenlygram — removes the on-device state of the optional feature stored under the neutral names
/// below (spec 19 "Tozalash"). Compiled into every build, so it must work without the feature's
/// modules and carry no feature wording: the names are exactly the ones the feature itself uses.
///
/// Storage contract:
///  - Keychain: generic passwords with service `sg.feature.f1`. Per-account items use the decimal
///    account peer id as `kSecAttrAccount`, bare (`<accountPeerId>`) or origin-scoped
///    (`<accountPeerId>@<host>`); both forms belong to that account. Any other account value is
///    device-level. The device lock `d.u13` is never deleted, not even by `removeEverything()`.
///  - Files: entries whose name starts with `sgf1` directly under Application Support, Caches, tmp
///    and the app-group container. Per-account data lives in a child named by the decimal account
///    peer id (e.g. `Application Support/sgf1/<accountPeerId>/`).
///  - Defaults: `UserDefaults.standard` keys starting with `sgf1`. A key whose last dot-separated
///    component is a decimal account peer id (e.g. `sgf1.<name>.<accountPeerId>`) is per-account; any
///    other key is device-level.
///
/// Every operation runs after the previous one finished, in submission order, off the main thread. An
/// operation that deletes accounts' Keychain items first awaits `beforeRemoval` for each of those
/// accounts (it may still need their stored session), then deletes.
final class SGFeatureStorageCleanup {
    static let shared = SGFeatureStorageCleanup(storage: SGFeatureSystemStorage())

    static let keychainService = "sg.feature.f1"
    /// The device-level lock item: survives account removals, the last sign-out and builds without
    /// the feature (spec: it is never cleaned up).
    static let deviceLockAccount = "d.u13"
    static let namePrefix = "sgf1"

    typealias BeforeRemoval = (Int64) async -> Void

    private let storage: SGFeatureStorage
    private let ioQueue = DispatchQueue(label: "sg.cleanup.f1", qos: .utility)
    private let tailLock = NSLock()
    private var tail: Task<Void, Never>?

    init(storage: SGFeatureStorage) {
        self.storage = storage
    }

    /// The account peer id a Keychain account, folder or name component belongs to: `<digits>` or
    /// `<digits>@<anything>`; nil for device-level names.
    static func accountPeerId(fromName name: String) -> Int64? {
        let idPart: Substring
        if let separator = name.firstIndex(of: "@") {
            idPart = name[name.startIndex ..< separator]
        } else {
            idPart = Substring(name)
        }
        guard !idPart.isEmpty, idPart.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int64(idPart)
    }

    /// One signed-out account: its Keychain items (both key forms), its per-account folders and
    /// defaults keys. Device-level items stay.
    @discardableResult
    func removeAccount(_ accountPeerId: Int64, beforeRemoval: BeforeRemoval?) -> Task<Void, Never> {
        return self.enqueue {
            if let beforeRemoval {
                await beforeRemoval(accountPeerId)
            }
            await self.io {
                self.deleteKeychainItems(where: { $0 == accountPeerId })
                for directory in self.prefixedEntries() {
                    for child in self.storage.children(of: directory) ?? [] where SGFeatureStorageCleanup.accountPeerId(fromName: child.lastPathComponent) == accountPeerId {
                        self.storage.removeItem(child)
                    }
                }
                self.removeDefaults(where: { $0 == accountPeerId })
            }
        }
    }

    /// Launch reconciliation: per-account state of accounts that are no longer signed in (removed
    /// while this build was not running, or a removal the locked Keychain refused last time).
    @discardableResult
    func removeAccounts(notIn signedIn: Set<Int64>, beforeRemoval: BeforeRemoval?) -> Task<Void, Never> {
        return self.enqueue {
            if let beforeRemoval {
                for accountPeerId in await self.io({ self.keychainAccountPeerIds() }).subtracting(signedIn).sorted() {
                    await beforeRemoval(accountPeerId)
                }
            }
            await self.io {
                self.deleteKeychainItems(where: { !signedIn.contains($0) })
                for directory in self.prefixedEntries() {
                    for child in self.storage.children(of: directory) ?? [] {
                        if let accountPeerId = SGFeatureStorageCleanup.accountPeerId(fromName: child.lastPathComponent), !signedIn.contains(accountPeerId) {
                            self.storage.removeItem(child)
                        }
                    }
                }
                self.removeDefaults(where: { !signedIn.contains($0) })
            }
        }
    }

    /// The last account signed out: every account's Keychain items and every `sgf1` folder (drafts,
    /// upload queue, media cache, install state). Device-level Keychain items and defaults stay: they
    /// are not account data and are meant to outlive sign-outs and reinstalls.
    @discardableResult
    func removeAllAccounts(beforeRemoval: BeforeRemoval?) -> Task<Void, Never> {
        return self.enqueue {
            if let beforeRemoval {
                for accountPeerId in await self.io({ self.keychainAccountPeerIds() }).sorted() {
                    await beforeRemoval(accountPeerId)
                }
            }
            await self.io {
                self.deleteKeychainItems(where: { _ in true })
                for entry in self.prefixedEntries() {
                    self.storage.removeItem(entry)
                }
                self.removeDefaults(where: { _ in true })
            }
        }
    }

    /// A build without the feature: nothing of it may remain, device-level items included, except the
    /// device lock `d.u13`.
    @discardableResult
    func removeEverything() -> Task<Void, Never> {
        return self.enqueue {
            await self.io {
                for account in self.storage.keychainAccounts(service: SGFeatureStorageCleanup.keychainService) ?? [] where account != SGFeatureStorageCleanup.deviceLockAccount {
                    self.storage.deleteKeychainItem(service: SGFeatureStorageCleanup.keychainService, account: account)
                }
                for entry in self.prefixedEntries() {
                    self.storage.removeItem(entry)
                }
                for key in self.storage.defaultsKeys() where key.hasPrefix(SGFeatureStorageCleanup.namePrefix) {
                    self.storage.removeDefault(forKey: key)
                }
            }
        }
    }

    /// Runs `work` after every operation submitted before it.
    private func enqueue(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        self.tailLock.lock()
        defer {
            self.tailLock.unlock()
        }
        let previous = self.tail
        let task = Task(priority: .utility) {
            await previous?.value
            await work()
        }
        self.tail = task
        return task
    }

    /// Blocking Keychain / file / defaults work goes to the utility queue, not the cooperative pool.
    private func io<T>(_ work: @escaping () -> T) async -> T {
        return await withCheckedContinuation { continuation in
            self.ioQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func keychainAccountPeerIds() -> Set<Int64> {
        let accounts = self.storage.keychainAccounts(service: SGFeatureStorageCleanup.keychainService) ?? []
        return Set(accounts.compactMap { SGFeatureStorageCleanup.accountPeerId(fromName: $0) })
    }

    /// Deletes the per-account items whose account peer id matches. Before the first unlock the
    /// items cannot be read; they are then left for the next launch's reconciliation.
    private func deleteKeychainItems(where matches: (Int64) -> Bool) {
        for account in self.storage.keychainAccounts(service: SGFeatureStorageCleanup.keychainService) ?? [] {
            guard let accountPeerId = SGFeatureStorageCleanup.accountPeerId(fromName: account), matches(accountPeerId) else {
                continue
            }
            self.storage.deleteKeychainItem(service: SGFeatureStorageCleanup.keychainService, account: account)
        }
    }

    /// Removes the per-account defaults keys whose account peer id matches; device-level keys stay.
    private func removeDefaults(where matches: (Int64) -> Bool) {
        for key in self.storage.defaultsKeys() where key.hasPrefix(SGFeatureStorageCleanup.namePrefix) {
            guard let last = key.split(separator: ".").last, let accountPeerId = SGFeatureStorageCleanup.accountPeerId(fromName: String(last)), matches(accountPeerId) else {
                continue
            }
            self.storage.removeDefault(forKey: key)
        }
    }

    private func prefixedEntries() -> [URL] {
        var entries: [URL] = []
        for root in self.storage.roots() {
            entries.append(contentsOf: (self.storage.children(of: root) ?? []).filter { $0.lastPathComponent.hasPrefix(SGFeatureStorageCleanup.namePrefix) })
        }
        return entries
    }
}

/// The device: Keychain, the app's and the app group's directories, `UserDefaults.standard`.
struct SGFeatureSystemStorage: SGFeatureStorage {
    func keychainAccounts(service: String) -> [String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else {
                return nil
            }
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            return nil
        }
    }

    func deleteKeychainItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func roots() -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
                roots.append(url)
            }
        }
        roots.append(fileManager.temporaryDirectory)
        if let groupContainer = fileManager.containerURL(forSecurityApplicationGroupIdentifier: sgAppGroupIdentifier()) {
            roots.append(groupContainer)
        }
        return roots
    }

    func children(of directory: URL) -> [URL]? {
        return try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    func removeItem(_ url: URL) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    func defaultsKeys() -> [String] {
        return Array(UserDefaults.standard.dictionaryRepresentation().keys)
    }

    func removeDefault(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
