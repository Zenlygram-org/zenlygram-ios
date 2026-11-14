import Foundation

/// Zenlygram — a binding the SERVER ended (design 40 §8.1; reviews R1-1, R2-9; contract amendment
/// A3). An erasure on the web, by an admin or by an in-app deletion on another device revokes every
/// binding of the account; this device's next authenticated call then gets a 401 of the drop
/// family, which SGEntitlement records as the session's `sessionEnd`. Without a guard, auto-link
/// would re-bind at once with the OLD grant and upload phone, names and device data under a fresh
/// core account — so every server-ended binding counts as "consent must be given again":
///
/// - `linkEnded`: the record is `granted`, a `sessionEnd` exists, it is not older than the grant
///   (`sessionEnd.at ≥ decided_at`, whole seconds on the server-offset clock) and it was not handled
///   yet. The coordinator then normalises the grant to `needs_reconsent` / `link_ended`
///   (`SGConsentStore.normaliseAfterConsentStale`), so clearance is `[]` and auto-link stops until a
///   NEW grant — whose `decided_at` is later than the drop.
/// - `reason: account_erased` (core sends it with the 401) is a completed erasure: the local erase
///   of §11.4, with no network call, and the deleted notice.
/// - 409 `consent_stale` on `/bind/start` (automatic or manual) normalises the grant it carried the
///   same way.
///
/// Cost accepted: a benign server-side session loss (the device cap, an expiry, a lost Enclave key)
/// also asks for consent again; nothing is lost locally and one tap restores the flow.
public enum SGCustomerLinkState {
    /// `SGEntitlementSessionEnd` as the core reads it (the app side copies it field by field).
    public struct SessionEnd: Equatable {
        /// The DeviceAuth code that ended the session (`invalid_token`, `session_revoked`, …).
        public let code: String
        /// The 401 body's `reason`, e.g. `account_erased`.
        public let reason: String?
        /// When this device learned of it (`SGEntitlementClock.effectiveNow()`).
        public let at: Date
        /// The `device_id` of the binding that ended.
        public let deviceId: String?

        public init(code: String, reason: String?, at: Date, deviceId: String?) {
            self.code = code
            self.reason = reason
            self.at = at
            self.deviceId = deviceId
        }

        /// The account was erased (contract amendment A3).
        public var isAccountErased: Bool {
            return self.reason == SGCustomerWire.accountErasedReason
        }
    }

    /// `zg.cs.link_ended.v1.<tg>@<authority>` = `{"device_id":String?,"code":String,"at":instant}`: a
    /// copy of the `sessionEnd` the coordinator has already acted on, so each one is handled
    /// exactly once.
    public struct Handled: Equatable {
        public let deviceId: String?
        public let code: String
        /// The `sessionEnd.at` it copies, as an instant.
        public let at: String

        public init(deviceId: String?, code: String, at: String) {
            self.deviceId = deviceId
            self.code = code
            self.at = at
        }

        public init(_ sessionEnd: SessionEnd) {
            self.init(deviceId: sessionEnd.deviceId, code: sessionEnd.code, at: SGCustomerTime.instant(sessionEnd.at))
        }

        /// The stored marker (`SGConsentStore.jsonObject(.linkEnded(tg:authority:))`); nil when it is
        /// not one (no `at` instant).
        public init?(jsonObject object: [String: Any]?) {
            guard let object, let at = object["at"] as? String, SGCustomerTime.isInstant(at) else {
                return nil
            }
            self.init(deviceId: object["device_id"] as? String, code: (object["code"] as? String) ?? "", at: at)
        }

        /// For `SGConsentStore.setJSONObject(_:for: .linkEnded(tg:authority:))`.
        public var jsonObject: [String: Any] {
            var object: [String: Any] = ["code": self.code, "at": self.at]
            object["device_id"] = self.deviceId
            return object
        }

        /// Whether this marker copies `sessionEnd` (same instant).
        public func copies(_ sessionEnd: SessionEnd) -> Bool {
            return self.at == SGCustomerTime.instant(sessionEnd.at)
        }
    }

    /// The server ended the binding the account's current grant linked, and that was not handled
    /// yet: `granted` ∧ `sessionEnd` ∧ `sessionEnd.at ≥ decided_at` ∧ `handled?.at != sessionEnd.at`.
    /// Feeds `SGCustomerClearance` (`linkEnded`), `SGConsentWallPolicy` (`linkEnded`) and the
    /// automatic link's preconditions.
    public static func linkEnded(record: SGConsentRecord?, sessionEnd: SessionEnd?, handled: Handled?) -> Bool {
        guard let record, record.state == .granted, let sessionEnd else {
            return false
        }
        if let handled, handled.copies(sessionEnd) {
            return false
        }
        guard let decidedAt = record.decidedAt.flatMap(SGCustomerTime.date(fromInstant:)) else {
            // A grant without a readable decision time cannot be shown to be newer than the drop.
            return true
        }
        return sessionEnd.at.timeIntervalSince1970.rounded(.down) >= decidedAt.timeIntervalSince1970
    }

    /// What the coordinator does about the account's `sessionEnd` (evaluated on every pass while the
    /// store is readable: start, attach, foreground, every SGEntitlement change).
    public enum Decision: Equatable {
        case none
        /// `reason: account_erased`: the local erase of §11.4 (no network call) and the deleted
        /// notice.
        case accountErased
        /// The grant `consentId` → `needs_reconsent` / `link_ended`
        /// (`SGConsentStore.normaliseAfterConsentStale(tg:consentId:)`). The handled marker is written
        /// on a later pass, once the record reads as no longer `granted` — never before the
        /// normalisation is known to have landed, so a failed write cannot leave the old grant
        /// usable with its drop marked handled.
        case normalise(consentId: String?)
        /// An unhandled `sessionEnd` that ends no current grant (the grant was normalised already,
        /// or is newer, or there is none): write the marker, so a grant given later in the same
        /// second as the drop is never taken for one the drop ended.
        case markHandled(Handled)
    }

    public static func decide(record: SGConsentRecord?, sessionEnd: SessionEnd?, handled: Handled?) -> Decision {
        guard let sessionEnd else {
            return .none
        }
        if sessionEnd.isAccountErased {
            return .accountErased
        }
        if let handled, handled.copies(sessionEnd) {
            return .none
        }
        if SGCustomerLinkState.linkEnded(record: record, sessionEnd: sessionEnd, handled: handled) {
            return .normalise(consentId: record?.consentId)
        }
        return .markHandled(Handled(sessionEnd))
    }

    /// The erasure signals of contract amendment A3 as a classified answer carries them.
    public enum Signal: Equatable {
        /// 401 with `reason: account_erased`: the account was erased (on the web, by an admin, on
        /// another device): the local erase, no network call.
        case accountErased
        /// 409 `consent_stale`: the grant predates an erasure of this Telegram id: normalise it.
        case consentStale
    }

    /// Read through `SGCustomerCallOutcome.isAccountErased` / `.isConsentStale` (the classifier's
    /// own reading of them, I-2b).
    public static func signal(_ outcome: SGCustomerCallOutcome) -> Signal? {
        if outcome.isAccountErased {
            return .accountErased
        }
        if outcome.isConsentStale {
            return .consentStale
        }
        return nil
    }
}
