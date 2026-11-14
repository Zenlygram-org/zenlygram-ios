import Foundation

/// Zenlygram — the customer-data routes the core plans, budgets and classifies (contract §2.0,
/// design 40 §6.5). The app-side adapter maps each to `SGEntitlementCustomerDataRoute`; the raw
/// values name the route in store keys (`zg.cs.budget.v1.<route>@…`) and log lines.
public enum SGCustomerRoute: String, CaseIterable, Equatable, Hashable {
    /// `POST /v1/profile/consents`
    case consents
    /// `POST /v1/profile/sync`
    case sync
    /// `GET /v1/profile/me` (user-initiated)
    case me
    /// `POST /v1/profile/events`
    case events
    /// `POST /v1/account/delete` (user-initiated, `Idempotency-Key`)
    case delete
}

/// Zenlygram — one call's answer exactly as the transport saw it, before any decision (design 40
/// §6.5): the app-side adapter only converts `SGEntitlement.customerData(...)` results into this,
/// and `SGCustomerWire.classify` (I-2b) is the ONLY place that turns it into an
/// `SGCustomerCallOutcome`. The body is never logged.
public struct SGCustomerRawAnswer: Equatable {
    public enum Transport: String, Equatable {
        /// The server answered (`status` is set, 2xx or not).
        case ok
        /// No answer within the route's timeout.
        case timeout
        /// No connection, DNS/TLS failure, or an answer that could not be read.
        case offline
        /// An extension or a build without the authenticated backend: nothing was sent.
        case notConfigured
        /// The account holds no session on this device: nothing was sent.
        case notLinked
        /// The account's session changed under the call; its answer was discarded.
        case credentialChanged
    }

    public let transport: Transport
    /// HTTP status, when the server answered.
    public let status: Int?
    /// The error body's stable `error` code.
    public let code: String?
    /// The error body's `reason` (`consent_required`: `no_consent` | `withdrawn` | `reconsent_required`;
    /// a 401: `account_erased`).
    public let reason: String?
    /// The response body: the 2xx JSON, or the error JSON (`consent`, `field`, `retry_after` extras).
    public let body: Data
    /// `Retry-After` / `retry_after`, in seconds.
    public let retryAfter: TimeInterval?

    public init(transport: Transport, status: Int? = nil, code: String? = nil, reason: String? = nil, body: Data = Data(), retryAfter: TimeInterval? = nil) {
        self.transport = transport
        self.status = status
        self.code = code
        self.reason = reason
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Zenlygram — what one customer-data call means for the planner and the reducers (design 40 §6.5,
/// contract §6.5). Produced only by `SGCustomerWire.classify` (I-2b).
public enum SGCustomerCallOutcome: Equatable {
    /// 2xx: apply the response body.
    case ok(Data)
    /// 403 `consent_required`: reconcile (`SGConsentReconciler.onConsentRequired`).
    case consentRequired(SGConsentRequiredExtras)
    /// 403 `profile_account_not_linked`: stop profile/events for this binding.
    case accountNotLinked
    /// 409 `profile_account_mismatch`: drop the payload; a consent entry is marked rejected.
    case accountMismatch
    /// 413: events halve the batch (minimum 1); other routes drop the payload.
    case payloadTooLarge
    /// 422 (any code), or another 4xx with no row of its own (e.g. 409 `idempotency_in_flight` on
    /// a delete): drop the payload (consents: `SGConsentReconciler.onConsentsTerminal`).
    case terminal(status: Int, code: String?)
    /// 429: `Retry-After` / `retry_after` wins, per route.
    case rateLimited(retryAfter: TimeInterval?)
    /// The 401 family, already applied to the session by SGEntitlement; `reason` `account_erased`
    /// marks a completed erasure.
    case session(code: String?, reason: String?)
    /// The transport timed out: events halve the batch (minimum 25), then back off.
    case timedOut
    /// 404 (an older server), 5xx, 503 `profile_unavailable`, offline: back off.
    case unavailable(retryAfter: TimeInterval?)
    /// No stored session for the account: re-plan (auto-link).
    case notLinkedLocally
    /// The token changed under the call: re-plan, no attempt spent.
    case credentialChanged
    /// An extension or a build without the authenticated backend: nothing was sent, nothing to plan.
    case notConfigured
}

/// Zenlygram — the extras of a 403 `consent_required` (contract §2.1, §2.4.2): why the server holds
/// no usable grant, and its effective-consent block.
public struct SGConsentRequiredExtras: Equatable {
    public enum Reason: String, Equatable {
        /// No grant on record for the account.
        case noConsent = "no_consent"
        /// The latest decision is a withdrawal.
        case withdrawn
        /// The granted version is below the server's `min_valid_version`.
        case reconsentRequired = "reconsent_required"
        /// A reason this build does not know (or none).
        case unknown
    }

    public let reason: Reason
    public let consent: SGEffectiveConsent?

    public init(reason: Reason, consent: SGEffectiveConsent?) {
        self.reason = reason
        self.consent = consent
    }

    /// The extras of a `consent_required` error body (`{"error": "consent_required", "reason": …,
    /// "consent": {…}}`), or nil when the body is not that error. Unknown keys are ignored.
    public static func decode(errorBody: Data) -> SGConsentRequiredExtras? {
        guard let object = (try? JSONSerialization.jsonObject(with: errorBody, options: [])) as? [String: Any],
              object["error"] as? String == "consent_required" else {
            return nil
        }
        let reason = (object["reason"] as? String).flatMap(Reason.init(rawValue:)) ?? .unknown
        let consent = (object["consent"] as? [String: Any]).flatMap(SGEffectiveConsent.init(jsonObject:))
        return SGConsentRequiredExtras(reason: reason, consent: consent)
    }
}
