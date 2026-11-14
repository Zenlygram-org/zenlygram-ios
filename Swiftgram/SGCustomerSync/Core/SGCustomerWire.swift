import Foundation

/// Zenlygram — the customer-data wire (contract §2.2.5, §2.4; design 40 §6.5): the ONE classifier
/// that turns a transport answer into an `SGCustomerCallOutcome`, the response DTOs of the routes and
/// the typed log line of each call. Unknown response keys are always accepted; a 2xx whose
/// `schema_version` is not 1 is a server this build does not understand (`.unavailable`).
public enum SGCustomerWire {
    public static let schemaVersion = 1
    /// A `Retry-After` / `retry_after` above this is read as this.
    public static let maxRetryAfter: TimeInterval = 86_400
    /// The `reason` of a 401 that ended an erased account's session (contract amendment A3).
    public static let accountErasedReason = "account_erased"
    /// `/bind/start`'s 409 for a consent older than an erasure (amendment A3): never answered on
    /// these routes, but read the same way where it reaches a reducer as `.terminal(409, code)`.
    public static let consentStaleCode = "consent_stale"

    /// What `answer` means (design 40 §6.5):
    ///
    /// | answer | outcome |
    /// |---|---|
    /// | 2xx with `schema_version` 1 | `.ok(body)` |
    /// | 2xx with another or no `schema_version` | `.unavailable(nil)` |
    /// | 401 (any code; `reason` e.g. `account_erased`) | `.session(code, reason)` |
    /// | 403 `consent_required` | `.consentRequired(extras)` |
    /// | 403 `profile_account_not_linked` | `.accountNotLinked` |
    /// | 409 `profile_account_mismatch` | `.accountMismatch` |
    /// | 413 | `.payloadTooLarge` |
    /// | 429 | `.rateLimited(retryAfter)` |
    /// | 404 (an older server), 5xx (incl. 503 `profile_unavailable`), 1xx/3xx | `.unavailable(retryAfter)` |
    /// | 422 (any code), any other 4xx (e.g. 409 `idempotency_in_flight`, `consent_stale`) | `.terminal(status, code)` |
    /// | transport timeout | `.timedOut` |
    /// | offline | `.unavailable(retryAfter)` |
    /// | nothing sent: no session / extension or no backend / token changed | `.notLinkedLocally` / `.notConfigured` / `.credentialChanged` |
    public static func classify(_ answer: SGCustomerRawAnswer) -> SGCustomerCallOutcome {
        let errorBody = SGCustomerErrorBody.decode(answer.body)
        let retryAfter = SGCustomerWire.retryAfter(answer.retryAfter ?? errorBody?.retryAfter)
        switch answer.transport {
        case .notConfigured:
            return .notConfigured
        case .notLinked:
            return .notLinkedLocally
        case .credentialChanged:
            return .credentialChanged
        case .timeout:
            return .timedOut
        case .offline:
            return .unavailable(retryAfter: retryAfter)
        case .ok:
            break
        }
        guard let status = answer.status else {
            return .unavailable(retryAfter: retryAfter)
        }
        let code = answer.code ?? errorBody?.code
        switch status {
        case 200 ... 299:
            guard SGCustomerJSON.integer(SGCustomerJSON.object(answer.body)?["schema_version"]) == SGCustomerWire.schemaVersion else {
                return .unavailable(retryAfter: nil)
            }
            return .ok(answer.body)
        case 401:
            return .session(code: code, reason: answer.reason ?? errorBody?.reason)
        case 403:
            if code == "consent_required" {
                if let extras = SGConsentRequiredExtras.decode(errorBody: answer.body) {
                    return .consentRequired(extras)
                }
                let reason = (answer.reason ?? errorBody?.reason).flatMap(SGConsentRequiredExtras.Reason.init(rawValue:)) ?? .unknown
                return .consentRequired(SGConsentRequiredExtras(reason: reason, consent: nil))
            }
            if code == "profile_account_not_linked" {
                return .accountNotLinked
            }
            return .terminal(status: status, code: code)
        case 404:
            return .unavailable(retryAfter: retryAfter)
        case 409:
            if code == "profile_account_mismatch" {
                return .accountMismatch
            }
            return .terminal(status: status, code: code)
        case 413:
            return .payloadTooLarge
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 400 ... 499:
            return .terminal(status: status, code: code)
        default:
            return .unavailable(retryAfter: retryAfter)
        }
    }

    /// The error body's `field` (a JSON path such as `consents[1].text_sha256`; consent_* 422s and
    /// 409 `profile_account_mismatch` carry it): `SGConsentReconciler.onConsentsTerminal(field:)`.
    public static func errorField(_ answer: SGCustomerRawAnswer) -> String? {
        return SGCustomerErrorBody.decode(answer.body)?.field
    }

    /// The call's log line: `<code> route=<route>[ status=<nnn>]` — a stable code only (a known
    /// server code, `http_<nnn>`, or one of this file's), never a body, a reason text or a value.
    public static func log(_ outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer, route: SGCustomerRoute) {
        SGCustomerLog.log(SGCustomerWire.logCode(outcome, answer: answer), route: route, status: answer.status)
    }

    static func logCode(_ outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer) -> SGCustomerLogCode {
        switch outcome {
        case .ok:
            return .customerCallOk
        case .notConfigured:
            return .customerNotConfigured
        case .notLinkedLocally:
            return .customerNotLinkedLocally
        case .credentialChanged:
            return .customerCredentialChanged
        case .timedOut:
            return SGCustomerLogCode.server("timeout")
        case let .session(code, reason):
            return SGCustomerLogCode.server(reason == SGCustomerWire.accountErasedReason ? reason : code)
        default:
            if answer.transport == .offline {
                return SGCustomerLogCode.server("offline")
            }
            if let code = answer.code ?? SGCustomerErrorBody.decode(answer.body)?.code {
                return SGCustomerLogCode.server(code)
            }
            return SGCustomerLogCode.server(answer.status.map { "http_\($0)" })
        }
    }

    private static func retryAfter(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else {
            return nil
        }
        return min(max(value, 0), SGCustomerWire.maxRetryAfter)
    }
}

extension SGCustomerCallOutcome {
    /// A 401 whose `reason` is `account_erased`: the account was erased (on the web, by an admin or on
    /// another device) — the local erase of design 40 §11.4, no network call.
    public var isAccountErased: Bool {
        if case let .session(_, reason) = self {
            return reason == SGCustomerWire.accountErasedReason
        }
        return false
    }

    /// A 409 `consent_stale`: the grant predates an erasure of this Telegram id (normalise it).
    public var isConsentStale: Bool {
        if case let .terminal(status, code) = self {
            return status == 409 && code == SGCustomerWire.consentStaleCode
        }
        return false
    }
}

extension SGCustomerLogCode {
    public static let customerCallOk = SGCustomerLogCode("call_ok")
    public static let customerNotConfigured = SGCustomerLogCode("call_not_configured")
    public static let customerNotLinkedLocally = SGCustomerLogCode("call_not_linked_locally")
    public static let customerCredentialChanged = SGCustomerLogCode("call_credential_changed")
    public static let analyticsQueueWriteFailed = SGCustomerLogCode("analytics_queue_write_failed")
    public static let analyticsQueueUnreadable = SGCustomerLogCode("analytics_queue_unreadable")
    public static let profileSnapshotInvalid = SGCustomerLogCode("profile_snapshot_invalid")
}

// MARK: - Error body

/// The extras of a non-2xx body (contract §0.1: `{"error", "message", …extras}`). The `message` is
/// never read.
public struct SGCustomerErrorBody: Equatable {
    public let code: String?
    /// `consent_required` / 401 `reason`.
    public let reason: String?
    /// The JSON path of the refused value (422, 409 `profile_account_mismatch`).
    public let field: String?
    public let retryAfter: TimeInterval?

    public init(code: String?, reason: String?, field: String?, retryAfter: TimeInterval?) {
        self.code = code
        self.reason = reason
        self.field = field
        self.retryAfter = retryAfter
    }

    /// The body's extras, or nil when it is not a JSON object.
    public static func decode(_ data: Data) -> SGCustomerErrorBody? {
        guard let object = SGCustomerJSON.object(data) else {
            return nil
        }
        func short(_ key: String) -> String? {
            guard let text = object[key] as? String, (1 ... 256).contains(text.unicodeScalars.count) else {
                return nil
            }
            return text
        }
        let retryAfter = SGCustomerJSON.integer(object["retry_after"]).map(TimeInterval.init)
        return SGCustomerErrorBody(code: short("error"), reason: short("reason"), field: short("field"), retryAfter: retryAfter)
    }
}

// MARK: - Responses

/// `ingest` of a sync / events answer.
public enum SGCustomerIngest: String, Equatable {
    case stored
    /// `ZENLYPAY_PROFILE_INGEST_ENABLED=false` (or events disabled): nothing was stored; the client
    /// treats it as delivered (a sync receipt; events: delete and pause 24 h).
    case paused
}

/// `POST /v1/profile/sync` 200 (contract §2.4.3).
public struct SGProfileSyncResponse: Equatable {
    public let ingest: SGCustomerIngest?
    public let minIntervalS: Int?

    public init(ingest: SGCustomerIngest?, minIntervalS: Int?) {
        self.ingest = ingest
        self.minIntervalS = minIntervalS
    }

    public static func decode(_ data: Data) -> SGProfileSyncResponse? {
        guard let object = SGCustomerJSON.object(data), SGCustomerJSON.integer(object["schema_version"]) == SGCustomerWire.schemaVersion else {
            return nil
        }
        return SGProfileSyncResponse(
            ingest: (object["ingest"] as? String).flatMap(SGCustomerIngest.init(rawValue:)),
            minIntervalS: SGCustomerJSON.integer(object["min_interval_s"]).flatMap { $0 > 0 ? $0 : nil }
        )
    }
}

/// `POST /v1/profile/events` 200 (contract §2.4.5): every event of the batch is deleted, whatever
/// its fate (accepted, duplicate, rejected).
public struct SGEventsResponse: Equatable {
    public struct Rejection: Equatable {
        /// The event id, as the server echoed it (null for an id that was not a short string).
        public let id: String?
        /// `unknown_event` | `invalid_props` | `invalid_envelope` | `stale` | `future`.
        public let reason: String

        public init(id: String?, reason: String) {
            self.id = id
            self.reason = reason
        }
    }

    public let accepted: Int
    public let duplicates: Int
    public let droppedProps: Int
    public let rejected: [Rejection]
    public let ingest: SGCustomerIngest?
    public let flushIntervalS: Int?

    public init(accepted: Int, duplicates: Int, droppedProps: Int, rejected: [Rejection], ingest: SGCustomerIngest?, flushIntervalS: Int?) {
        self.accepted = accepted
        self.duplicates = duplicates
        self.droppedProps = droppedProps
        self.rejected = rejected
        self.ingest = ingest
        self.flushIntervalS = flushIntervalS
    }

    public static func decode(_ data: Data) -> SGEventsResponse? {
        guard let object = SGCustomerJSON.object(data), SGCustomerJSON.integer(object["schema_version"]) == SGCustomerWire.schemaVersion else {
            return nil
        }
        let rejected = ((object["rejected"] as? [Any]) ?? []).compactMap { value -> Rejection? in
            guard let item = value as? [String: Any], let reason = item["reason"] as? String else {
                return nil
            }
            return Rejection(id: item["id"] as? String, reason: reason)
        }
        return SGEventsResponse(
            accepted: SGCustomerJSON.integer(object["accepted"]) ?? 0,
            duplicates: SGCustomerJSON.integer(object["duplicates"]) ?? 0,
            droppedProps: SGCustomerJSON.integer(object["dropped_props"]) ?? 0,
            rejected: rejected,
            ingest: (object["ingest"] as? String).flatMap(SGCustomerIngest.init(rawValue:)),
            flushIntervalS: SGCustomerJSON.integer(object["flush_interval_s"])
        )
    }
}

/// `POST /v1/account/delete` (contract §2.2.5).
public enum SGAccountDeleteRequest {
    /// `{"confirm":"delete_account","schema_version":1}`
    public static let body = Data("{\"confirm\":\"delete_account\",\"schema_version\":1}".utf8)
}

/// `POST /v1/account/delete` 200.
public struct SGAccountDeleteResponse: Equatable {
    /// `erased` (`already_erased` reads the same: the account is gone).
    public let state: String?
    public let accountId: String?
    public let erasedAt: String?
    /// What the law keeps (`payment_records`).
    public let retained: [String]

    public init(state: String?, accountId: String?, erasedAt: String?, retained: [String]) {
        self.state = state
        self.accountId = accountId
        self.erasedAt = erasedAt
        self.retained = retained
    }

    public static func decode(_ data: Data) -> SGAccountDeleteResponse? {
        guard let object = SGCustomerJSON.object(data), SGCustomerJSON.integer(object["schema_version"]) == SGCustomerWire.schemaVersion else {
            return nil
        }
        return SGAccountDeleteResponse(
            state: object["state"] as? String,
            accountId: object["account_id"] as? String,
            erasedAt: (object["erased_at"] as? String).flatMap { SGCustomerTime.isInstant($0) ? $0 : nil },
            retained: ((object["retained"] as? [Any]) ?? []).compactMap { $0 as? String }
        )
    }
}

/// `GET /v1/profile/me` 200 (contract §2.4.4): the data subject's own view, unmasked; held in memory
/// only. Every section is optional (core failures make `account`/`subscription` null; an unconsented
/// account has `consent.state = none` and empty sections). Values stay the server's raw codes; the
/// screen maps them to strings.
public struct SGProfileMe: Equatable {
    public struct Account: Equatable {
        public let id: String?
        public let tgUserId: Int64?
        public let createdAt: String?
    }

    public struct Consent: Equatable {
        public let state: String
        public let consentId: String?
        public let textVersion: Int?
        public let locale: String?
        public let consentMode: String?
        public let effectiveAt: String?
    }

    public struct ConsentHistoryItem: Equatable {
        public let consentId: String?
        public let action: String?
        public let scopes: [String]
        public let textVersion: Int?
        public let locale: String?
        public let consentMode: String?
        public let source: String?
        public let platform: String?
        public let appVersion: String?
        public let recordedAt: String?
        public let receivedAt: String?
        public let outcome: String?
    }

    /// A profile value with where it came from (`telegram_attest` | `telegram_bot` | `client` |
    /// `telegram_session`) and when it was observed.
    public struct Field<Value: Equatable>: Equatable {
        public let value: Value
        public let source: String?
        public let observedAt: String?
    }

    public struct Profile: Equatable {
        public let phone: Field<String>?
        public let country: String?
        public let usernames: Field<[String]>?
        public let firstName: Field<String>?
        public let lastName: Field<String>?
        public let languageCode: Field<String>?
        public let isPremium: Field<Bool>?
    }

    public struct Device: Equatable {
        public let deviceId: String?
        public let platform: String?
        public let deviceClass: String?
        public let deviceModel: String?
        public let osVersion: String?
        public let appVersion: String?
        public let appBuild: String?
        public let uiLanguage: String?
        public let locale: String?
        public let timezone: String?
        public let distribution: String?
        public let firstSeenAt: String?
        public let lastSeenAt: String?
        public let revokedAt: String?
    }

    public struct Activity: Equatable {
        public let firstActiveAt: String?
        public let lastActiveAt: String?
        public let activeDays: Int?
        public let sessions30d: Int?
        public let sessionSeconds30d: Int?
    }

    public struct EventCount: Equatable {
        public let name: String
        public let count: Int
    }

    public struct RecentEvent: Equatable {
        public let name: String
        public let ts: String?
    }

    public struct Events: Equatable {
        public let retentionDays: Int?
        public let total: Int?
        public let byName: [EventCount]
        public let recent: [RecentEvent]
    }

    public struct Subscription: Equatable {
        public let reason: String?
        public let status: String?
        public let source: String?
        public let until: String?
        public let trialEndsAt: String?
    }

    public struct Retention: Equatable {
        public let profile: String?
        public let eventsDays: Int?
        public let activityMonths: Int?
        public let consentLogYearsAfterErasure: Int?
    }

    public let account: Account?
    public let consent: Consent?
    public let consentHistory: [ConsentHistoryItem]
    public let profile: Profile?
    public let devices: [Device]
    public let activity: Activity?
    public let events: Events?
    public let subscription: Subscription?
    public let retention: Retention?

    public static func decode(_ data: Data) -> SGProfileMe? {
        guard let object = SGCustomerJSON.object(data), SGCustomerJSON.integer(object["schema_version"]) == SGCustomerWire.schemaVersion else {
            return nil
        }
        func section(_ key: String) -> [String: Any]? {
            return object[key] as? [String: Any]
        }
        func list(_ value: Any?) -> [[String: Any]] {
            return ((value as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        }
        func strings(_ value: Any?) -> [String] {
            return ((value as? [Any]) ?? []).compactMap { $0 as? String }
        }
        func field<Value>(_ value: Any?, _ read: (Any?) -> Value?) -> Field<Value>? {
            guard let item = value as? [String: Any], let read = read(item["value"]) else {
                return nil
            }
            return Field(value: read, source: item["source"] as? String, observedAt: item["observed_at"] as? String)
        }
        let account = section("account").map { item in
            Account(id: item["id"] as? String, tgUserId: SGCustomerJSON.integer(item["tg_user_id"]).map(Int64.init), createdAt: item["created_at"] as? String)
        }
        let consent = section("consent").flatMap { item -> Consent? in
            guard let state = item["state"] as? String else {
                return nil
            }
            return Consent(state: state, consentId: item["consent_id"] as? String, textVersion: SGCustomerJSON.integer(item["text_version"]), locale: item["locale"] as? String, consentMode: item["consent_mode"] as? String, effectiveAt: item["effective_at"] as? String)
        }
        let history = list(object["consent_history"]).map { item in
            ConsentHistoryItem(
                consentId: item["consent_id"] as? String, action: item["action"] as? String, scopes: strings(item["scopes"]),
                textVersion: SGCustomerJSON.integer(item["text_version"]), locale: item["locale"] as? String,
                consentMode: item["consent_mode"] as? String, source: item["source"] as? String, platform: item["platform"] as? String,
                appVersion: item["app_version"] as? String, recordedAt: item["recorded_at"] as? String,
                receivedAt: item["received_at"] as? String, outcome: item["outcome"] as? String
            )
        }
        let profile = section("profile").map { item in
            Profile(
                phone: field(item["phone"]) { $0 as? String },
                country: item["country"] as? String,
                usernames: field(item["usernames"]) { value -> [String]? in (value as? [Any]).map { $0.compactMap { $0 as? String } } },
                firstName: field(item["first_name"]) { $0 as? String },
                lastName: field(item["last_name"]) { $0 as? String },
                languageCode: field(item["language_code"]) { $0 as? String },
                isPremium: field(item["is_premium"]) { SGCustomerJSON.bool($0) }
            )
        }
        let devices = list(object["devices"]).map { item in
            Device(
                deviceId: item["device_id"] as? String, platform: item["platform"] as? String, deviceClass: item["device_class"] as? String,
                deviceModel: item["device_model"] as? String, osVersion: item["os_version"] as? String, appVersion: item["app_version"] as? String,
                appBuild: item["app_build"] as? String, uiLanguage: item["ui_language"] as? String, locale: item["locale"] as? String,
                timezone: item["timezone"] as? String, distribution: item["distribution"] as? String, firstSeenAt: item["first_seen_at"] as? String,
                lastSeenAt: item["last_seen_at"] as? String, revokedAt: item["revoked_at"] as? String
            )
        }
        let activity = section("activity").map { item in
            Activity(
                firstActiveAt: item["first_active_at"] as? String, lastActiveAt: item["last_active_at"] as? String,
                activeDays: SGCustomerJSON.integer(item["active_days"]), sessions30d: SGCustomerJSON.integer(item["sessions_30d"]),
                sessionSeconds30d: SGCustomerJSON.integer(item["session_seconds_30d"])
            )
        }
        let events = section("events").map { item in
            Events(
                retentionDays: SGCustomerJSON.integer(item["retention_days"]),
                total: SGCustomerJSON.integer(item["total"]),
                byName: list(item["by_name"]).compactMap { entry in
                    guard let name = entry["name"] as? String, let count = SGCustomerJSON.integer(entry["count"]) else {
                        return nil
                    }
                    return EventCount(name: name, count: count)
                },
                recent: list(item["recent"]).compactMap { entry in
                    guard let name = entry["name"] as? String else {
                        return nil
                    }
                    return RecentEvent(name: name, ts: entry["ts"] as? String)
                }
            )
        }
        let subscription = section("subscription").map { item in
            Subscription(reason: item["reason"] as? String, status: item["status"] as? String, source: item["source"] as? String, until: item["until"] as? String, trialEndsAt: item["trial_ends_at"] as? String)
        }
        let retention = section("retention").map { item in
            Retention(
                profile: item["profile"] as? String, eventsDays: SGCustomerJSON.integer(item["events_days"]),
                activityMonths: SGCustomerJSON.integer(item["activity_months"]),
                consentLogYearsAfterErasure: SGCustomerJSON.integer(item["consent_log_years_after_erasure"])
            )
        }
        return SGProfileMe(account: account, consent: consent, consentHistory: history, profile: profile, devices: devices, activity: activity, events: events, subscription: subscription, retention: retention)
    }
}

// MARK: - Hints

/// The server's hints for this install (`zg.cs.hints.v1@<authority>`, design 40 §4.4): the event
/// flush interval, the ingest pause and the profile sync's minimum interval.
public struct SGCustomerHints: Equatable {
    /// `flush_interval_s` of the last events answer (60…3600).
    public var flushIntervalS: Int?
    /// Event upload paused until (an `"ingest": "paused"` events answer + 24 h).
    public var eventsPausedUntil: Date?
    /// `min_interval_s` of the last sync answer.
    public var minIntervalS: Int?

    public init(flushIntervalS: Int? = nil, eventsPausedUntil: Date? = nil, minIntervalS: Int? = nil) {
        self.flushIntervalS = flushIntervalS
        self.eventsPausedUntil = eventsPausedUntil
        self.minIntervalS = minIntervalS
    }

    /// The stored marker (`SGConsentStore.jsonObject(.hints(authority:))`); malformed fields read as
    /// absent.
    public init(jsonObject object: [String: Any]?) {
        let object = object ?? [:]
        self.flushIntervalS = SGCustomerJSON.integer(object["flush_interval_s"]).flatMap { $0 > 0 ? $0 : nil }
        self.eventsPausedUntil = SGCustomerJSON.integer(object["events_paused_until"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        self.minIntervalS = SGCustomerJSON.integer(object["min_interval_s"]).flatMap { $0 > 0 ? $0 : nil }
    }

    /// For `SGConsentStore.setJSONObject(_:for: .hints(authority:))`.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        object["flush_interval_s"] = self.flushIntervalS
        object["events_paused_until"] = self.eventsPausedUntil.map { Int($0.timeIntervalSince1970.rounded(.down)) }
        object["min_interval_s"] = self.minIntervalS
        return object
    }
}

// MARK: - JSON text

/// Compact JSON text with sorted keys, slashes and non-ASCII left as they are — the form the server
/// measures and the parsed-JSON fixtures compare (contract §3.1). Plus strict readers of decoded
/// values (a boolean is never a number and the other way round).
enum SGCustomerJSON {
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            case "\u{08}":
                result += "\\b"
            case "\u{0C}":
                result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// `{"key":value,…}` of already-encoded member values, sorted by key bytes.
    static func object(_ members: [(String, String)]) -> String {
        let sorted = members.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        return "{" + sorted.map { SGCustomerJSON.quoted($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    /// A JSON object decoded from `data`, or nil.
    static func object(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    /// A JSON integer (never a boolean, a float or a string).
    static func integer(_ value: Any?) -> Int? {
        return SGConsentManifest.integer(value)
    }

    /// A JSON boolean (never a number).
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}
