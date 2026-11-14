import Foundation

/// Zenlygram — `grant` | `withdraw` (contract §2.4.1).
public enum SGConsentAction: String, Equatable {
    case grant
    case withdraw
}

/// Zenlygram — the build's consent mode (`sg_config.consent_mode`, contract §6.1).
public enum SGConsentMode: String, CaseIterable, Equatable {
    case required
    case optional
}

/// Zenlygram — the local consent state of one Telegram account (contract §6.2; absence = `none`).
public enum SGConsentState: String, CaseIterable, Equatable {
    case none
    case granted
    /// Optional builds only; a decline is never uploaded.
    case declined
    case withdrawn
    /// Withdrawn on another device (learned from the server).
    case withdrawnRemote = "withdrawn_remote"
    /// The grant must be given again; `zg.cs.notice.v1.<tg>` says why.
    case needsReconsent = "needs_reconsent"
}

/// Zenlygram — why a record is `needs_reconsent` (`zg.cs.notice.v1.<tg>`, design 40 §4.4).
public enum SGConsentStoredNotice: String, CaseIterable, Equatable {
    /// The server or the bundle retired the granted version.
    case reconsent
    /// This build renders the granted text with other operator values.
    case operatorChanged = "operator_changed"
    /// The server ended the binding this grant linked (or the grant belongs to an erased account).
    case linkEnded = "link_ended"
}

/// Zenlygram — one ConsentEvent (contract §2.4.1): minted once per user action, persisted before
/// any upload, and sent as exactly the bytes `encoded()` produced (sorted keys, unescaped slashes,
/// absent fields left out). A grant carries `text_sha256` and `age_confirmed: true`; a withdraw
/// carries neither.
public struct SGConsentEvent: Equatable {
    public static let iosPlatform = "ios"
    /// `tg_id`: 1…2^53 − 1.
    public static let maxTelegramUserId: Int64 = 9_007_199_254_740_991

    public let consentId: String
    public let tgUserId: Int64
    public let action: SGConsentAction
    public let scopes: [String]
    public let textVersion: Int?
    public let textSha256: String?
    public let locale: SGConsentLocale
    public let consentMode: SGConsentMode
    public let ageConfirmed: Bool?
    public let recordedAt: String
    public let platform: String
    public let appVersion: String

    public init(consentId: String, tgUserId: Int64, action: SGConsentAction, scopes: [String], textVersion: Int?, textSha256: String?, locale: SGConsentLocale, consentMode: SGConsentMode, ageConfirmed: Bool?, recordedAt: String, platform: String = SGConsentEvent.iosPlatform, appVersion: String) {
        self.consentId = consentId
        self.tgUserId = tgUserId
        self.action = action
        self.scopes = scopes
        self.textVersion = textVersion
        self.textSha256 = textSha256
        self.locale = locale
        self.consentMode = consentMode
        self.ageConfirmed = ageConfirmed
        self.recordedAt = recordedAt
        self.platform = platform
        self.appVersion = appVersion
    }

    /// Every field within the contract: the shared types, the scope set, and the per-action fields.
    public var isValid: Bool {
        guard SGCustomerTime.isUUID4(self.consentId),
              (1 ... SGConsentEvent.maxTelegramUserId).contains(self.tgUserId),
              !self.scopes.isEmpty, Set(self.scopes).count == self.scopes.count,
              self.scopes.allSatisfy({ SGConsentScope(rawValue: $0) != nil }),
              SGCustomerTime.isInstant(self.recordedAt),
              self.platform == "ios" || self.platform == "android",
              SGConsentEvent.isVersionText(self.appVersion) else {
            return false
        }
        if let textVersion = self.textVersion, !(1 ... SGConsentManifest.maxVersion).contains(textVersion) {
            return false
        }
        switch self.action {
        case .grant:
            return self.textVersion != nil && self.textSha256.map(SGCustomerTime.isHex64) == true && self.ageConfirmed == true
        case .withdraw:
            return self.textSha256 == nil && self.ageConfirmed == nil
        }
    }

    /// The exact JSON bytes of this event.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(Wire(self))) ?? Data()
    }

    /// The JSON object of `encoded()` (the `consent` of `/bind/start`).
    public func jsonObject() -> [String: Any] {
        return ((try? JSONSerialization.jsonObject(with: self.encoded(), options: [])) as? [String: Any]) ?? [:]
    }

    /// The event of stored or sent bytes, or nil when they are not a valid event.
    public static func decode(_ data: Data) -> SGConsentEvent? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let action = SGConsentAction(rawValue: wire.action),
              let locale = SGConsentLocale(rawValue: wire.locale),
              let mode = SGConsentMode(rawValue: wire.consentMode) else {
            return nil
        }
        let event = SGConsentEvent(consentId: wire.consentId, tgUserId: wire.tgUserId, action: action, scopes: wire.scopes, textVersion: wire.textVersion, textSha256: wire.textSha256, locale: locale, consentMode: mode, ageConfirmed: wire.ageConfirmed, recordedAt: wire.recordedAt, platform: wire.platform, appVersion: wire.appVersion)
        return event.isValid ? event : nil
    }

    /// `ver` (`^[0-9A-Za-z._+() -]{1,32}$`): `CFBundleShortVersionString` clipped to it — other
    /// characters dropped, at most 32 kept, `0` when nothing is left.
    public static func clippedVersion(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter(SGConsentEvent.isVersionScalar).prefix(32)
        guard !kept.isEmpty else {
            return "0"
        }
        return SGConsentCanonicalText.string(ArraySlice(kept))
    }

    static func isVersionText(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return (1 ... 32).contains(scalars.count) && scalars.allSatisfy(SGConsentEvent.isVersionScalar)
    }

    private static func isVersionScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A:
            return true
        default:
            return scalar == "." || scalar == "_" || scalar == "+" || scalar == "(" || scalar == ")" || scalar == " " || scalar == "-"
        }
    }

    private struct Wire: Codable {
        let consentId: String
        let tgUserId: Int64
        let action: String
        let scopes: [String]
        let textVersion: Int?
        let textSha256: String?
        let locale: String
        let consentMode: String
        let ageConfirmed: Bool?
        let recordedAt: String
        let platform: String
        let appVersion: String

        enum CodingKeys: String, CodingKey {
            case consentId = "consent_id"
            case tgUserId = "tg_user_id"
            case action
            case scopes
            case textVersion = "text_version"
            case textSha256 = "text_sha256"
            case locale
            case consentMode = "consent_mode"
            case ageConfirmed = "age_confirmed"
            case recordedAt = "recorded_at"
            case platform
            case appVersion = "app_version"
        }

        init(_ event: SGConsentEvent) {
            self.consentId = event.consentId
            self.tgUserId = event.tgUserId
            self.action = event.action.rawValue
            self.scopes = event.scopes
            self.textVersion = event.textVersion
            self.textSha256 = event.textSha256
            self.locale = event.locale.rawValue
            self.consentMode = event.consentMode.rawValue
            self.ageConfirmed = event.ageConfirmed
            self.recordedAt = event.recordedAt
            self.platform = event.platform
            self.appVersion = event.appVersion
        }
    }
}

/// Zenlygram — the local consent record of one Telegram account (`zg.consent.v1.<tg>`, contract
/// §6.2): every key always present, null when unknown.
/// `{"v":1,"tg_user_id":…,"state":…,"consent_id":…,"text_version":…,"text_sha256":…,"locale":…,
/// "consent_mode":…,"decided_at":…}` — `consent_id` and `decided_at` are those of the latest
/// decision (the withdraw's for `withdrawn`, the remote one's for `withdrawn_remote`).
public struct SGConsentRecord: Equatable {
    public static let formatVersion = 1

    public var tgUserId: Int64
    public var state: SGConsentState
    public var consentId: String?
    public var textVersion: Int?
    public var textSha256: String?
    public var locale: SGConsentLocale?
    public var consentMode: SGConsentMode?
    public var decidedAt: String?

    public init(tgUserId: Int64, state: SGConsentState, consentId: String? = nil, textVersion: Int? = nil, textSha256: String? = nil, locale: SGConsentLocale? = nil, consentMode: SGConsentMode? = nil, decidedAt: String? = nil) {
        self.tgUserId = tgUserId
        self.state = state
        self.consentId = consentId
        self.textVersion = textVersion
        self.textSha256 = textSha256
        self.locale = locale
        self.consentMode = consentMode
        self.decidedAt = decidedAt
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(Wire(self))) ?? Data()
    }

    public static func decode(_ data: Data) -> SGConsentRecord? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.v == SGConsentRecord.formatVersion,
              let state = SGConsentState(rawValue: wire.state) else {
            return nil
        }
        return SGConsentRecord(
            tgUserId: wire.tgUserId,
            state: state,
            consentId: wire.consentId,
            textVersion: wire.textVersion,
            textSha256: wire.textSha256,
            locale: wire.locale.flatMap(SGConsentLocale.init(rawValue:)),
            consentMode: wire.consentMode.flatMap(SGConsentMode.init(rawValue:)),
            decidedAt: wire.decidedAt
        )
    }

    private struct Wire: Codable {
        let v: Int
        let tgUserId: Int64
        let state: String
        let consentId: String?
        let textVersion: Int?
        let textSha256: String?
        let locale: String?
        let consentMode: String?
        let decidedAt: String?

        enum CodingKeys: String, CodingKey {
            case v
            case tgUserId = "tg_user_id"
            case state
            case consentId = "consent_id"
            case textVersion = "text_version"
            case textSha256 = "text_sha256"
            case locale
            case consentMode = "consent_mode"
            case decidedAt = "decided_at"
        }

        init(_ record: SGConsentRecord) {
            self.v = SGConsentRecord.formatVersion
            self.tgUserId = record.tgUserId
            self.state = record.state.rawValue
            self.consentId = record.consentId
            self.textVersion = record.textVersion
            self.textSha256 = record.textSha256
            self.locale = record.locale?.rawValue
            self.consentMode = record.consentMode?.rawValue
            self.decidedAt = record.decidedAt
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.v, forKey: .v)
            try container.encode(self.tgUserId, forKey: .tgUserId)
            try container.encode(self.state, forKey: .state)
            try container.encode(self.consentId, forKey: .consentId)
            try container.encode(self.textVersion, forKey: .textVersion)
            try container.encode(self.textSha256, forKey: .textSha256)
            try container.encode(self.locale, forKey: .locale)
            try container.encode(self.consentMode, forKey: .consentMode)
            try container.encode(self.decidedAt, forKey: .decidedAt)
        }
    }
}

/// Zenlygram — the server's effective-consent block (contract §2.4.2), in `/v1/profile/consents`
/// answers and `consent_required` errors.
public struct SGEffectiveConsent: Equatable {
    public enum State: String, Equatable {
        case granted
        case withdrawn
        case none
    }

    public let state: State
    public let consentId: String?
    /// A withdraw's `text_version: null` reads as absent.
    public let textVersion: Int?
    public let effectiveAt: String?

    public init(state: State, consentId: String?, textVersion: Int?, effectiveAt: String?) {
        self.state = state
        self.consentId = consentId
        self.textVersion = textVersion
        self.effectiveAt = effectiveAt
    }

    /// The block of a decoded JSON object, or nil when `state` is unknown. A malformed optional
    /// field reads as absent.
    public init?(jsonObject object: [String: Any]) {
        guard let state = (object["state"] as? String).flatMap(State.init(rawValue:)) else {
            return nil
        }
        self.state = state
        self.consentId = object["consent_id"] as? String
        self.textVersion = SGConsentManifest.integer(object["text_version"])
        self.effectiveAt = (object["effective_at"] as? String).flatMap { SGCustomerTime.isInstant($0) ? $0 : nil }
    }
}

/// Zenlygram — the body of `POST /v1/profile/consents` (contract §2.4.1).
public enum SGConsentsRequest {
    public static let maxEvents = 10
    public static let maxBodyBytes = 16_384

    /// `{"schema_version":1,"consents":[…]}` around the exact stored bytes of `events` (in the order
    /// given; the planner sends one per request), or nil when there are none, more than ten, one is
    /// not a valid event, or the body would exceed 16 KiB.
    public static func body(events: [Data]) -> Data? {
        guard (1 ... SGConsentsRequest.maxEvents).contains(events.count),
              events.allSatisfy({ SGConsentEvent.decode($0) != nil }) else {
            return nil
        }
        var body = Data("{\"consents\":[".utf8)
        for (index, event) in events.enumerated() {
            if index > 0 {
                body.append(UInt8(ascii: ","))
            }
            body.append(event)
        }
        body.append(Data("],\"schema_version\":1}".utf8))
        return body.count <= SGConsentsRequest.maxBodyBytes ? body : nil
    }
}

/// Zenlygram — a `POST /v1/profile/consents` 200 (contract §2.4.1, amendment A4). Unknown keys are
/// accepted; another `schema_version` is not this answer.
public struct SGConsentsResponse: Equatable {
    public enum Outcome: String, Equatable {
        case recorded
        case superseded
        case duplicate
    }

    public struct Item: Equatable {
        public let consentId: String
        public let outcome: Outcome
        /// The `consent_id` was first recorded for another account: never effective here (A4).
        public let foreign: Bool

        public init(consentId: String, outcome: Outcome, foreign: Bool = false) {
            self.consentId = consentId
            self.outcome = outcome
            self.foreign = foreign
        }
    }

    /// Items with an outcome this build does not know are left out (never acked).
    public let results: [Item]
    public let consent: SGEffectiveConsent?
    /// `{"state":"scheduled","due_by":…}` after a transition to withdrawn; nil otherwise.
    public let erasureDueBy: String?

    public init(results: [Item], consent: SGEffectiveConsent?, erasureDueBy: String? = nil) {
        self.results = results
        self.consent = consent
        self.erasureDueBy = erasureDueBy
    }

    public static func decode(_ data: Data) -> SGConsentsResponse? {
        guard let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              SGConsentManifest.integer(object["schema_version"]) == 1,
              let results = object["results"] as? [Any] else {
            return nil
        }
        let items = results.compactMap { value -> Item? in
            guard let item = value as? [String: Any], let consentId = item["consent_id"] as? String,
                  let outcome = (item["outcome"] as? String).flatMap(Outcome.init(rawValue:)) else {
                return nil
            }
            return Item(consentId: consentId, outcome: outcome, foreign: item["foreign"] as? Bool == true)
        }
        let consent = (object["consent"] as? [String: Any]).flatMap(SGEffectiveConsent.init(jsonObject:))
        let dueBy = (object["erasure"] as? [String: Any])?["due_by"] as? String
        return SGConsentsResponse(results: items, consent: consent, erasureDueBy: dueBy)
    }
}
