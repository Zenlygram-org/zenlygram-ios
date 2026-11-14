import CryptoKit
import Foundation

/// Zenlygram — the signed-in account's own Telegram user as `SGProfileReader` reads it (design 40
/// §9.1, `TelegramUser`), before normalisation. Only the account's own data: never another peer,
/// never a chat, never `language_code` (verified sources only, contract §2.4.3).
public struct SGProfileUser: Equatable {
    public struct Username: Equatable {
        public var value: String
        public var isActive: Bool
        public var isEditable: Bool

        public init(value: String, isActive: Bool, isEditable: Bool) {
            self.value = value
            self.isActive = isActive
            self.isEditable = isEditable
        }
    }

    /// The RAW Telegram user id (`peerId.id._internalGetInt64Value()`).
    public var userId: Int64
    /// `user.phone` (digits, no `+`), nil or empty when hidden.
    public var phone: String?
    /// `user.usernames` (with `.isActive` / `.isEditable`).
    public var usernames: [Username]
    /// `user.username`, read only when `usernames` is empty.
    public var username: String?
    public var firstName: String?
    public var lastName: String?
    public var isPremium: Bool

    public init(userId: Int64, phone: String?, usernames: [Username], username: String?, firstName: String?, lastName: String?, isPremium: Bool) {
        self.userId = userId
        self.phone = phone
        self.usernames = usernames
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.isPremium = isPremium
    }
}

/// Zenlygram — one `POST /v1/profile/sync` body (contract §2.4.3, design 40 §9), normalised:
/// - `phone`: the digits with `+` prepended, `e164` or null;
/// - `usernames`: the active ones, the editable first, de-duplicated case-insensitively, each
///   `^[A-Za-z0-9_]{4,32}$`, at most 32 (the single `username` when the list is empty);
/// - names: NFC, C0/C1 controls and U+2028/2029 removed, Unicode White_Space trimmed, at most 128
///   scalars; empty → null (the server accepts `first_name: null`);
/// - top-level `app_version` / `os_version`: `ver` (ProfileBoundary refuses anything else);
/// - device values as `SGCustomerNormalise` makes them (descriptive ones null when unknown).
///
/// The body is canonical JSON (`JSONEncoder` `.sortedKeys` + `.withoutEscapingSlashes`, snake_case
/// keys, `null` written for absent optionals). The digest — lowercase hex SHA-256 of that encoding
/// WITHOUT `observed_at` — is what the receipt of a binding remembers (`recordProfileSync`).
public struct SGProfileSnapshot: Equatable {
    public static let schemaVersion = 1
    public static let maxBodyBytes = 16_384
    public static let maxUsernames = 32
    public static let maxNameScalars = 128

    public struct Telegram: Equatable {
        public let userId: Int64
        public let phone: String?
        public let usernames: [String]
        public let firstName: String?
        public let lastName: String?
        public let isPremium: Bool
    }

    public struct Device: Equatable {
        public static let platform = "ios"

        public let deviceClass: SGCustomerDeviceClass
        public let deviceModel: String?
        public let appBuild: String?
        public let uiLanguage: String?
        public let locale: String?
        public let timezone: String?
        public let distribution: SGCustomerDistribution
    }

    public let appVersion: String
    public let osVersion: String
    public let telegram: Telegram
    public let device: Device

    /// The snapshot of `user` on this device, or nil when the user id is not a `tg_id`.
    public init?(user: SGProfileUser, device facts: SGCustomerDeviceFacts) {
        guard (1 ... SGConsentEvent.maxTelegramUserId).contains(user.userId) else {
            return nil
        }
        self.appVersion = SGCustomerNormalise.version(facts.appVersion)
        self.osVersion = SGCustomerNormalise.version(facts.osVersion)
        self.telegram = Telegram(
            userId: user.userId,
            phone: SGProfileSnapshot.e164(user.phone),
            usernames: SGProfileSnapshot.usernames(user.usernames, fallback: user.username),
            firstName: SGProfileSnapshot.nameText(user.firstName),
            lastName: SGProfileSnapshot.nameText(user.lastName),
            isPremium: user.isPremium
        )
        self.device = Device(
            deviceClass: facts.deviceClass,
            deviceModel: SGCustomerNormalise.model(facts.deviceModel),
            appBuild: SGCustomerNormalise.optionalVersion(facts.appBuild),
            uiLanguage: SGCustomerNormalise.uiLanguage(facts.uiLanguage),
            locale: SGCustomerNormalise.bcp47(identifier: facts.locale),
            timezone: SGCustomerNormalise.timezone(facts.timezone),
            distribution: facts.distribution
        )
    }

    /// The request body, `observed_at` = `observedAt` (UTC, whole seconds).
    public func body(observedAt: Date) -> Data {
        return self.encoded(observedAt: SGCustomerTime.instant(observedAt))
    }

    /// Lowercase hex SHA-256 of the canonical body without `observed_at`: equal snapshots have
    /// equal digests whenever they were observed.
    public var digest: String {
        return SHA256.hash(data: self.encoded(observedAt: nil)).map { String(format: "%02x", $0) }.joined()
    }

    private func encoded(observedAt: String?) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(Wire(snapshot: self, observedAt: observedAt))) ?? Data()
    }

    // MARK: - Normalisation

    /// `e164` (`^\+[1-9][0-9]{6,14}$`) of the session's phone: its ASCII digits with `+` prepended;
    /// nil when that is not one.
    public static func e164(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let digits = String(raw.unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }.map(Character.init))
        guard (7 ... 15).contains(digits.count), digits.first != "0" else {
            return nil
        }
        return "+" + digits
    }

    /// The active usernames, the editable one(s) first and otherwise in the given order,
    /// de-duplicated case-insensitively, each `^[A-Za-z0-9_]{4,32}$`, at most 32; `fallback` alone
    /// when the list is empty.
    public static func usernames(_ list: [SGProfileUser.Username], fallback: String?) -> [String] {
        let candidates: [String]
        if list.isEmpty {
            candidates = fallback.map { [$0] } ?? []
        } else {
            let active = list.filter(\.isActive)
            candidates = active.filter(\.isEditable).map(\.value) + active.filter { !$0.isEditable }.map(\.value)
        }
        var result: [String] = []
        var seen = Set<String>()
        for name in candidates where SGProfileSnapshot.isUsername(name) && seen.insert(name.lowercased()).inserted {
            result.append(name)
            if result.count == SGProfileSnapshot.maxUsernames {
                break
            }
        }
        return result
    }

    /// `name_text` or nil: NFC, C0/C1 controls and U+2028/2029 removed, White_Space trimmed, clipped
    /// to 128 scalars (and composed again).
    public static func nameText(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let kept = SGConsentCanonicalText.nfc(raw).unicodeScalars.filter { scalar in
            !(scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029)
        }
        // Composed again: a removed control between a letter and its mark leaves them adjacent
        // (`e`, U+0007, U+0301), and the server refuses a name that is not NFC.
        var text = SGConsentCanonicalText.trimmingWhiteSpace(SGConsentCanonicalText.nfc(SGConsentCanonicalText.string(ArraySlice(kept))))
        var rounds = 0
        while text.unicodeScalars.count > SGProfileSnapshot.maxNameScalars, rounds < 4 {
            let clipped = Array(text.unicodeScalars.prefix(SGProfileSnapshot.maxNameScalars))
            text = SGConsentCanonicalText.trimmingWhiteSpace(SGConsentCanonicalText.nfc(SGConsentCanonicalText.string(clipped[...])))
            rounds += 1
        }
        guard !text.isEmpty, text.unicodeScalars.count <= SGProfileSnapshot.maxNameScalars else {
            return nil
        }
        return text
    }

    /// `username`: `^[A-Za-z0-9_]{4,32}$`.
    static func isUsername(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (4 ... 32).contains(bytes.count) && bytes.allSatisfy { byte in
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_")
        }
    }

    // MARK: - Wire

    private struct Wire: Encodable {
        let snapshot: SGProfileSnapshot
        /// nil: the digest form.
        let observedAt: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case observedAt = "observed_at"
            case appVersion = "app_version"
            case osVersion = "os_version"
            case telegram
            case device
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(SGProfileSnapshot.schemaVersion, forKey: .schemaVersion)
            if let observedAt = self.observedAt {
                try container.encode(observedAt, forKey: .observedAt)
            }
            try container.encode(self.snapshot.appVersion, forKey: .appVersion)
            try container.encode(self.snapshot.osVersion, forKey: .osVersion)
            try container.encode(TelegramWire(self.snapshot.telegram), forKey: .telegram)
            try container.encode(DeviceWire(self.snapshot.device), forKey: .device)
        }
    }

    private struct TelegramWire: Encodable {
        let telegram: Telegram

        init(_ telegram: Telegram) {
            self.telegram = telegram
        }

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case phone
            case usernames
            case firstName = "first_name"
            case lastName = "last_name"
            case isPremium = "is_premium"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.telegram.userId, forKey: .userId)
            try container.encode(self.telegram.phone, forKey: .phone)
            try container.encode(self.telegram.usernames, forKey: .usernames)
            try container.encode(self.telegram.firstName, forKey: .firstName)
            try container.encode(self.telegram.lastName, forKey: .lastName)
            try container.encode(self.telegram.isPremium, forKey: .isPremium)
        }
    }

    private struct DeviceWire: Encodable {
        let device: Device

        init(_ device: Device) {
            self.device = device
        }

        enum CodingKeys: String, CodingKey {
            case platform
            case deviceClass = "device_class"
            case deviceModel = "device_model"
            case appBuild = "app_build"
            case uiLanguage = "ui_language"
            case locale
            case timezone
            case distribution
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Device.platform, forKey: .platform)
            try container.encode(self.device.deviceClass.rawValue, forKey: .deviceClass)
            try container.encode(self.device.deviceModel, forKey: .deviceModel)
            try container.encode(self.device.appBuild, forKey: .appBuild)
            try container.encode(self.device.uiLanguage, forKey: .uiLanguage)
            try container.encode(self.device.locale, forKey: .locale)
            try container.encode(self.device.timezone, forKey: .timezone)
            try container.encode(self.device.distribution.rawValue, forKey: .distribution)
        }
    }
}

/// Zenlygram — a binding's profile receipt (`SGEntitlement.profileSyncReceipt`): the digest it
/// delivered and when.
public struct SGProfileSyncReceipt: Equatable {
    public let digest: String
    public let at: Date

    public init(digest: String, at: Date) {
        self.digest = digest
        self.at = at
    }
}

/// Zenlygram — when the profile snapshot is sent (design 40 §9.3, contract §6.5), after first idle
/// and outside the route's backoff and budget (the planner):
/// (a) no receipt for this binding → now;
/// (b) the digest differs from the receipt → 10 s after it changed, and ≥ 5 min after the last
///     attempt;
/// (c) the receipt is older than max(6 h, `min_interval_s`) → then, in the foreground only.
/// A terminal 409/422 records the digest too (step 4 is done for the binding), and a 200 records it
/// also for `"ingest": "paused"`.
public enum SGProfileSyncCadence {
    public static let debounce: TimeInterval = 10
    public static let minimumSpacing: TimeInterval = 5 * 60
    public static let refreshInterval: TimeInterval = 6 * 3600

    /// When the snapshot `digest` is due (≤ `now` = due now), or nil (not due).
    /// - Parameters:
    ///   - digestChangedAt: when this digest was first seen differing from the receipt (nil = now).
    ///   - lastAttemptAt: the last sync attempt of the binding.
    ///   - minIntervalS: the server's `min_interval_s` hint.
    public static func dueAt(digest: String, receipt: SGProfileSyncReceipt?, digestChangedAt: Date?, lastAttemptAt: Date?, minIntervalS: Int?, isForeground: Bool, now: Date) -> Date? {
        guard let receipt else {
            return now
        }
        if receipt.digest != digest {
            var due = (digestChangedAt ?? now).addingTimeInterval(SGProfileSyncCadence.debounce)
            if let lastAttemptAt {
                due = max(due, lastAttemptAt.addingTimeInterval(SGProfileSyncCadence.minimumSpacing))
            }
            return due
        }
        guard isForeground else {
            return nil
        }
        let interval = max(SGProfileSyncCadence.refreshInterval, TimeInterval(max(minIntervalS ?? 0, 0)))
        return receipt.at.addingTimeInterval(interval)
    }
}
