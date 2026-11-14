import Foundation
import Security
import SGProtectedStore

/// Zenlygram — the per-Telegram-account session material (client contract §8).
///
/// One binding, one refresh token and one cached JWS PER ACCOUNT, keyed by the account's own peer
/// id. The device id, the Enclave key, the clock mark and the StoreKit outbox are per INSTALL and
/// live next to it, not inside it. Sessions, device identity and the outbox are also per BACKEND
/// ORIGIN (`SGEntitlementStore.scope`).
public struct SGEntitlementSessionMaterial: Codable, Equatable {
    /// Opaque, 64 hex. Rotated on every `POST /entitlement/refresh`.
    public var refreshToken: String?
    /// The last entitlement JWS the server sent. Kept even when the session is lost: only a
    /// successfully verified token may ever reduce what the user can do.
    public var entitlement: String?
    /// `accounts.id` (the JWS `sub`).
    public var accountId: String?
    /// `devices.id` (the JWS `dev`), stored from `/bind/poll` and checked on every verification.
    public var deviceId: String?
    /// The subscription horizon the server last reported, as the RFC 3339 string it sent.
    public var until: String?
    /// When this record was last written, by the device's own clock. Diagnostics only.
    public var updatedAt: Date?
    /// SHA-256 (hex) of the APNs token THIS binding delivered on a successful
    /// `POST /entitlement/refresh` — a receipt, never the token. Written only while the binding that
    /// rotated is still the stored one; cleared with the binding (logout, re-bind).
    public var pushTokenDigest: String?
    /// The digest of the profile snapshot THIS binding last delivered to `POST /v1/profile/sync`, and
    /// when (`SGEntitlement.recordProfileSync`) — a receipt, never the snapshot. Written only while
    /// the session that sent it is still the stored one; gone with the item (logout), reset by a new
    /// binding.
    public var profileSyncDigest: String?
    public var profileSyncedAt: Date?
    /// Set when a 401 of the drop family ended this binding (`afterServerDrop`); a logout removes
    /// the whole item and a new binding clears it (`afterBind`), so neither ever leaves one.
    public var sessionEnd: SGEntitlementSessionEnd?

    public init(
        refreshToken: String? = nil,
        entitlement: String? = nil,
        accountId: String? = nil,
        deviceId: String? = nil,
        until: String? = nil,
        updatedAt: Date? = nil,
        pushTokenDigest: String? = nil,
        profileSyncDigest: String? = nil,
        profileSyncedAt: Date? = nil,
        sessionEnd: SGEntitlementSessionEnd? = nil
    ) {
        self.refreshToken = refreshToken
        self.entitlement = entitlement
        self.accountId = accountId
        self.deviceId = deviceId
        self.until = until
        self.updatedAt = updatedAt
        self.pushTokenDigest = pushTokenDigest
        self.profileSyncDigest = profileSyncDigest
        self.profileSyncedAt = profileSyncedAt
        self.sessionEnd = sessionEnd
    }

    public var isLinked: Bool {
        return self.refreshToken != nil
    }

    public var isEmpty: Bool {
        return self.refreshToken == nil && self.entitlement == nil
    }
}

extension SGEntitlementSessionMaterial {
    /// The material once `confirmation` is stored as the account's binding (`SGEntitlement.completeBind`):
    /// its refresh token, `account.id`, `device.id` and `until`. Everything that described the previous
    /// binding goes — the APNs receipt (the new binding has not received the token; its next refresh
    /// carries it), the profile receipt and any `sessionEnd`. The JWS slot is filled only when empty:
    /// `adopt` is its writer, after verification.
    func afterBind(_ confirmation: SGEntitlementBindConfirmation) -> SGEntitlementSessionMaterial {
        var material = self
        material.refreshToken = confirmation.refreshToken
        material.accountId = confirmation.account?.id
        material.deviceId = confirmation.device?.id
        material.until = confirmation.account?.until
        material.pushTokenDigest = nil
        material.profileSyncDigest = nil
        material.profileSyncedAt = nil
        material.sessionEnd = nil
        if material.entitlement == nil {
            material.entitlement = confirmation.entitlement
        }
        return material
    }

    /// The material once the server ended the binding (`SGEntitlement.apply`, a 401 of the drop
    /// family): the refresh token goes and the end is recorded. The JWS and the ids stay.
    func afterServerDrop(code: String, reason: String?, at: Date) -> SGEntitlementSessionMaterial {
        var material = self
        material.refreshToken = nil
        material.sessionEnd = SGEntitlementSessionEnd(code: code, reason: reason, at: at, deviceId: self.deviceId)
        return material
    }
}

/// Zenlygram — the session ONE authenticated request runs under: the account and the refresh token
/// it presents, captured once, before sending. The transport presents exactly this token (on its
/// retries too), and everything the response causes — adopting a JWS, storing a rotated token,
/// dropping the token after a 401, regenerating the key after `device_key_mismatch` — happens only
/// while that token is still the account's stored one. A response that outlived its session (a
/// logout, a re-bind, a rotation that won the race) changes nothing.
public struct SGEntitlementSessionCredential: Equatable {
    public let accountPeerId: Int64
    public let refreshToken: String

    public init(accountPeerId: Int64, refreshToken: String) {
        self.accountPeerId = accountPeerId
        self.refreshToken = refreshToken
    }
}

public enum SGEntitlementStoreError: Error, Equatable {
    case encodingFailed
    case writeFailed(OSStatus)
    case verifyFailed
    case unreadable
    /// `updateSession(accountPeerId:if:_:)` found material its caller no longer owns — typically a
    /// response landing after a logout or a re-bind. Nothing was written.
    case preconditionFailed
}

/// What a read of one Keychain item found. "Not there" and "cannot look right now" are different
/// answers: before the first unlock after a reboot the class every item here lives in is not yet
/// available, and a record that merely could not be read must never be treated as never written —
/// `SGEntitlementLocalGrace` is minted once, not once per locked launch.
enum SGEntitlementStoreItemRead: Equatable {
    case present(Data)
    case absent
    case unreadable(OSStatus)
}

/// Zenlygram — Keychain storage for everything the entitlement needs, in the app group's shared
/// access group so the Notification Service Extension can reach it.
///
/// This reuses `SGProtectedStore`'s solved problem rather than inventing a second scheme:
/// `SGProtectedKeychain` already owns the shared access group (`sgAppGroupIdentifier()`), the
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` class, the update-then-add write and the
/// keychain-less-build fallback. Deviation from the contract, deliberately: the contract says
/// `AfterFirstUnlock`, this uses `...ThisDeviceOnly`, which is what every other Zenlygram protection
/// item uses. It is strictly stronger and it is correct here — a device binding restored onto a
/// different phone must re-bind (`device_key_mismatch`), not inherit a session.
///
/// Writes are verified by a read-back, as in `SGProtectedStore`: only a value that reads back
/// identically counts as written. That is what makes refresh-token rotation safe — the new token is
/// persisted (and proven persisted) before the old one is ever discarded.
///
/// Origin-bound items — sessions, the device id, the Enclave and software keys, the Apple outbox —
/// live under `scope`'s names (`base@authority`, `SGEntitlementStoreScope`). A build for a new backend
/// origin therefore starts with a fresh session, device identity and outbox, and never reads, copies,
/// sends, rewrites or deletes another origin's items or the bare pre-origin (`.com`-era) ones. The one
/// exception is `discardLegacySession(accountPeerId:)`: an explicit logout deletes that account's bare
/// session item, unread, as logout always did. The clock mark and the two local grace records are
/// per INSTALL and are never scoped.
public final class SGEntitlementStore {
    public static let shared = SGEntitlementStore()

    static let service = "uz.zenlygram.entitlement"

    // Base names. The origin-bound ones are never used bare: see `scope`.
    static let deviceIdAccount = "device.id.v1"
    static let enclaveKeyAccount = "device.enclave.v1"
    static let softwareKeyAccount = "device.softkey.v1"
    static let clockMarkAccount = "clock.mark.v1"
    static let outboxAccount = "apple.outbox.v1"
    /// `SGEntitlementLocalGrace` — per install, like the clock mark; never cleared by a logout and
    /// never scoped by origin.
    static let localGraceAccount = "grace.firstlaunch.v1"
    /// `SGEntitlementPaidModeMark` — the local grace's second minted-once record (D9: the install's
    /// first evaluation under a PAID policy). Per install, never cleared by a logout and never scoped
    /// by origin, exactly like `localGraceAccount`.
    static let paidModeMarkAccount = "grace.firstpaid.v1"
    static let sessionAccountPrefix = "session.v1."

    /// Keychain-less builds only (fake-codesigned simulator / DEBUG, exactly
    /// `SGProtectedKeychain.isKeychainlessBuild`): a plaintext app-group copy so the simulator can be
    /// used at all. A signed release build treats `errSecMissingEntitlement` as a failed write and
    /// never creates these keys.
    static let fallbackKeyPrefix = "zg.ent.fb."

    /// The namespace of the origin-bound items. `shared` uses the build's (`SGEntitlementStoreScope.shipped`).
    public let scope: SGEntitlementStoreScope
    private let deviceIdItem: String
    private let enclaveKeyItem: String
    private let softwareKeyItem: String
    private let outboxItem: String

    private let defaults: UserDefaults?
    private let keychain: SGEntitlementKeychainAccess
    private let lock = NSLock()
    private var cachedSessions: [Int64: SGEntitlementSessionMaterial] = [:]

    private convenience init() {
        self.init(defaults: UserDefaults(suiteName: SGProtectedKeychain.sharedAccessGroup), keychain: .live, scope: .shipped)
    }

    /// Tests build a store of their own: an owned defaults suite, the Keychain calls to use and the
    /// origin scope, so every write goes through this class's own write-and-read-back path.
    init(defaults: UserDefaults?, keychain: SGEntitlementKeychainAccess, scope: SGEntitlementStoreScope = .unconfigured) {
        self.defaults = defaults
        self.keychain = keychain
        self.scope = scope
        self.deviceIdItem = scope.scopedKey(SGEntitlementStore.deviceIdAccount)
        self.enclaveKeyItem = scope.scopedKey(SGEntitlementStore.enclaveKeyAccount)
        self.softwareKeyItem = scope.scopedKey(SGEntitlementStore.softwareKeyAccount)
        self.outboxItem = scope.scopedKey(SGEntitlementStore.outboxAccount)
    }

    // MARK: - Raw item access

    private func readItem(account: String) -> SGEntitlementStoreItemRead {
        switch self.keychain.read(account) {
        case let .present(data):
            return .present(data)
        case .absent:
            if let data = self.fallbackData(account: account) {
                return .present(data)
            }
            return .absent
        case let .unreadable(status):
            if status == errSecMissingEntitlement && SGProtectedKeychain.isKeychainlessBuild {
                if let data = self.fallbackData(account: account) {
                    return .present(data)
                }
                return .absent
            }
            return .unreadable(status)
        }
    }

    private func readData(account: String) -> Data? {
        if case let .present(data) = self.readItem(account: account) {
            return data
        }
        return nil
    }

    private func fallbackData(account: String) -> Data? {
        guard SGProtectedKeychain.isKeychainlessBuild else {
            return nil
        }
        return self.defaults?.data(forKey: SGEntitlementStore.fallbackKeyPrefix + account)
    }

    @discardableResult
    private func writeData(_ data: Data, account: String) -> Result<Void, SGEntitlementStoreError> {
        let status = self.keychain.write(data, account)
        if status == errSecSuccess {
            self.defaults?.removeObject(forKey: SGEntitlementStore.fallbackKeyPrefix + account)
        } else if status == errSecMissingEntitlement && SGProtectedKeychain.isKeychainlessBuild {
            self.defaults?.set(data, forKey: SGEntitlementStore.fallbackKeyPrefix + account)
        } else {
            return .failure(.writeFailed(status))
        }
        // Read-back verification: a rotation that is not proven persisted must not be adopted.
        guard let readBack = self.readData(account: account), readBack == data else {
            return .failure(.verifyFailed)
        }
        return .success(())
    }

    private func deleteData(account: String) {
        self.keychain.delete(account)
        self.defaults?.removeObject(forKey: SGEntitlementStore.fallbackKeyPrefix + account)
    }

    // MARK: - Per-install items (the device identity and the outbox per origin, too)

    /// The raw device id, this origin's. **Never pad, trim, re-case or re-encode it after minting**:
    /// the signed message uses these exact bytes while the server stores `hmac(trim(raw))`, so
    /// whitespace hashes the same but signs differently. One string per origin, everywhere, forever.
    public func deviceId() -> String? {
        if let data = self.readData(account: self.deviceIdItem), let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        return nil
    }

    /// Mints the device id if it does not exist yet: 32 random bytes as 64 lowercase hex characters.
    public func ensureDeviceId() -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let existing = self.deviceId() {
            return existing
        }
        guard let bytes = SGEntitlementCrypto.randomBytes(32) else {
            return nil
        }
        let value = SGEntitlementCrypto.hexString(bytes)
        guard case .success = self.writeData(Data(value.utf8), account: self.deviceIdItem) else {
            return nil
        }
        return value
    }

    func enclaveKeyBlob() -> Data? {
        return self.readData(account: self.enclaveKeyItem)
    }

    @discardableResult
    func setEnclaveKeyBlob(_ data: Data?) -> Bool {
        guard let data else {
            self.deleteData(account: self.enclaveKeyItem)
            return true
        }
        if case .success = self.writeData(data, account: self.enclaveKeyItem) {
            return true
        }
        return false
    }

    func softwareKeyBlob() -> Data? {
        return self.readData(account: self.softwareKeyItem)
    }

    @discardableResult
    func setSoftwareKeyBlob(_ data: Data?) -> Bool {
        guard let data else {
            self.deleteData(account: self.softwareKeyItem)
            return true
        }
        if case .success = self.writeData(data, account: self.softwareKeyItem) {
            return true
        }
        return false
    }

    func clockMarkData() -> Data? {
        return self.readData(account: SGEntitlementStore.clockMarkAccount)
    }

    @discardableResult
    func setClockMarkData(_ data: Data) -> Bool {
        if case .success = self.writeData(data, account: SGEntitlementStore.clockMarkAccount) {
            return true
        }
        return false
    }

    /// The local grace record (`SGEntitlementLocalGrace`), or nil when this install has never
    /// evaluated. Written once by the main app; extensions only read it. Survives logout, account
    /// switches, an app-group defaults wipe and a reinstall — only a Keychain wipe resets it.
    func localGraceData() -> Data? {
        return self.readData(account: SGEntitlementStore.localGraceAccount)
    }

    /// `localGraceData()` with "absent" and "unreadable right now" kept apart — the only reader that
    /// mints (`SGEntitlement.localGrace(now:)`) must mint on the first and never on the second.
    func localGraceRecord() -> SGEntitlementStoreItemRead {
        return self.readItem(account: SGEntitlementStore.localGraceAccount)
    }

    @discardableResult
    func setLocalGraceData(_ data: Data) -> Bool {
        if case .success = self.writeData(data, account: SGEntitlementStore.localGraceAccount) {
            return true
        }
        return false
    }

    /// The paid-policy mark (`SGEntitlementPaidModeMark`), "absent" and "unreadable right now" kept
    /// apart like `localGraceRecord()`: its only minting reader (`SGEntitlement.paidModeMark(now:)`)
    /// mints on the first and never on the second. Written once by the main app on its first
    /// evaluation under a paid policy; extensions only read it.
    func paidModeMarkRecord() -> SGEntitlementStoreItemRead {
        return self.readItem(account: SGEntitlementStore.paidModeMarkAccount)
    }

    @discardableResult
    func setPaidModeMarkData(_ data: Data) -> Bool {
        if case .success = self.writeData(data, account: SGEntitlementStore.paidModeMarkAccount) {
            return true
        }
        return false
    }

    func outboxData() -> Data? {
        return self.readData(account: self.outboxItem)
    }

    @discardableResult
    func setOutboxData(_ data: Data) -> Bool {
        if case .success = self.writeData(data, account: self.outboxItem) {
            return true
        }
        return false
    }

    // MARK: - Per-Telegram-account session

    /// The bare, pre-origin item name. Only `discardLegacySession(accountPeerId:)` uses it.
    static func legacySessionAccount(_ accountPeerId: Int64) -> String {
        return "\(SGEntitlementStore.sessionAccountPrefix)\(accountPeerId)"
    }

    /// This origin's item: `session.v1.<peer>@<authority>`.
    private func sessionItem(_ accountPeerId: Int64) -> String {
        return self.scope.scopedKey(SGEntitlementStore.legacySessionAccount(accountPeerId))
    }

    /// The account's material: the cache, or on a miss one Keychain read that is published to the
    /// cache. The read and the publication happen under the same lock `clearSession` and
    /// `updateSession` hold, so a read that began before a logout cannot cache the deleted material
    /// after it. (`readData` takes no lock of its own.)
    public func session(accountPeerId: Int64) -> SGEntitlementSessionMaterial {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let cached = self.cachedSessions[accountPeerId] {
            return cached
        }
        var material = SGEntitlementSessionMaterial()
        if let data = self.readData(account: self.sessionItem(accountPeerId)),
           let decoded = try? JSONDecoder().decode(SGEntitlementSessionMaterial.self, from: data) {
            material = decoded
        }
        self.cachedSessions[accountPeerId] = material
        return material
    }

    /// Read-modify-write of one account's material. Returns the stored value on success; on failure
    /// NOTHING is changed, which is what lets the caller keep using the old refresh token inside its
    /// 60 s rotation overlap.
    ///
    /// `precondition` is evaluated against the CURRENT material under the same lock as the write, and
    /// a `false` writes nothing (`.preconditionFailed`). It is how a network response that outlived
    /// its session — the attach or refresh that lands after `clearSession`, or after a re-bind minted
    /// a different refresh token — is kept from resurrecting or overwriting the account's material.
    @discardableResult
    public func updateSession(accountPeerId: Int64, if precondition: (SGEntitlementSessionMaterial) -> Bool = { _ in true }, _ transform: (inout SGEntitlementSessionMaterial) -> Void) -> Result<SGEntitlementSessionMaterial, SGEntitlementStoreError> {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var material = self.cachedSessions[accountPeerId] ?? {
            if let data = self.readData(account: self.sessionItem(accountPeerId)),
               let decoded = try? JSONDecoder().decode(SGEntitlementSessionMaterial.self, from: data) {
                return decoded
            }
            return SGEntitlementSessionMaterial()
        }()
        guard precondition(material) else {
            return .failure(.preconditionFailed)
        }
        transform(&material)
        material.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(material) else {
            return .failure(.encodingFailed)
        }
        switch self.writeData(data, account: self.sessionItem(accountPeerId)) {
        case .success:
            self.cachedSessions[accountPeerId] = material
            return .success(material)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Logout. Drops the session material for ONE account and nothing else: never the device id,
    /// never the Enclave key, never the clock mark, never the outbox, never the local grace record
    /// (a logout must not re-grant the 7 days), and never any vault / lock / task data.
    ///
    /// Returns the material it removed, read under the same lock that empties the cache, so the
    /// caller can still present the old refresh token to `/bind/revoke` after the local copy is gone.
    @discardableResult
    public func clearSession(accountPeerId: Int64) -> SGEntitlementSessionMaterial {
        self.lock.lock()
        let removed = self.cachedSessions[accountPeerId] ?? {
            if let data = self.readData(account: self.sessionItem(accountPeerId)),
               let decoded = try? JSONDecoder().decode(SGEntitlementSessionMaterial.self, from: data) {
                return decoded
            }
            return SGEntitlementSessionMaterial()
        }()
        self.cachedSessions[accountPeerId] = SGEntitlementSessionMaterial()
        // Under the lock, like `updateSession`'s write: a write slipping in between the cache reset and
        // the delete would otherwise be deleted from the Keychain while it stayed live in memory.
        self.deleteData(account: self.sessionItem(accountPeerId))
        self.lock.unlock()
        return removed
    }

    /// Explicit logout only: deletes this account's bare pre-origin (`.com`-era) session item — the
    /// refresh token and JWS an earlier build stored — exactly as logout always removed it. It is
    /// never read, returned, revoked or sent anywhere, and nothing else pre-origin is touched (other
    /// accounts' sessions, the device id and keys, the outbox). Never called on launch, on a
    /// recompute or for a new empty origin.
    public func discardLegacySession(accountPeerId: Int64) {
        self.lock.lock()
        self.deleteData(account: SGEntitlementStore.legacySessionAccount(accountPeerId))
        self.lock.unlock()
    }

    /// Drops the in-memory copy so the next read goes back to the Keychain (used after a process
    /// learns, via the Darwin notification, that another one wrote).
    public func invalidateCache() {
        self.lock.lock()
        self.cachedSessions.removeAll()
        self.lock.unlock()
    }

    /// Tests only: seeds one account's material in memory, without touching the Keychain — the test
    /// host is not entitled to the shared access group, so a real write cannot be verified there.
    /// `clearSession(accountPeerId:)` undoes it.
    func seedSessionForTesting(accountPeerId: Int64, _ material: SGEntitlementSessionMaterial) {
        self.lock.lock()
        self.cachedSessions[accountPeerId] = material
        self.lock.unlock()
    }
}

/// Zenlygram — the Keychain calls `SGEntitlementStore` makes, bound to its service and the shared
/// access group. `live` is the only production value.
struct SGEntitlementKeychainAccess {
    let read: (String) -> SGKeychainReadResult
    let write: (Data, String) -> OSStatus
    let delete: (String) -> Void

    static let live = SGEntitlementKeychainAccess(
        read: { account in
            return SGProtectedKeychain.read(service: SGEntitlementStore.service, account: account, accessGroup: SGProtectedKeychain.sharedAccessGroup)
        },
        write: { data, account in
            return SGProtectedKeychain.write(data, service: SGEntitlementStore.service, account: account, accessGroup: SGProtectedKeychain.sharedAccessGroup)
        },
        delete: { account in
            _ = SGProtectedKeychain.delete(service: SGEntitlementStore.service, account: account, accessGroup: SGProtectedKeychain.sharedAccessGroup)
        }
    )
}
