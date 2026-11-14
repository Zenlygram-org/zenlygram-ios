import Foundation

/// Zenlygram — everything that is "offline" as far as the entitlement is concerned.
///
/// A 5xx is in this list on purpose. **A 5xx or a timeout is "offline", never "unsubscribed"**
/// (invariant I2); so is a body we cannot parse.
public enum SGEntitlementOfflineCause: String, CaseIterable, Hashable {
    case timeout
    case dns
    case tls
    case noRoute
    case connectionLost
    case cancelled
    /// HTTP 5xx. The server is up enough to answer and still tells us nothing about the subscription.
    case serverError
    /// A 2xx whose body did not parse, or a response with no body at all.
    case malformedResponse
    case unknown
}

/// Zenlygram — the device-auth 401 family (`DeviceAuth.php`).
///
/// **None of these ever changes entitlement state.** They change SESSION state. The cached JWS keeps
/// governing until `exp + grace_days`, and user data is never touched.
public enum SGEntitlementSessionFailure: String, CaseIterable, Hashable {
    /// Credentials missing, malformed, or presented in the query string.
    case unauthenticated = "unauthenticated"
    /// |server_now − ts| > 300 s. Recoverable with no user action.
    case clockSkew = "clock_skew"
    /// (device, nonce) reused within 600 s. Every retry needs a fresh nonce, ts and signature.
    case nonceReplayed = "nonce_replayed"
    /// The refresh token is unknown to the server.
    case invalidToken = "invalid_token"
    /// The refresh token is past its 90 days.
    case expiredToken = "expired_token"
    /// Remote logout, the LRU device cap, or an admin.
    case sessionRevoked = "session_revoked"
    /// A rotated token presented after the 60 s overlap: the binding is revoked. Worth a
    /// security-flavoured message.
    case refreshReuse = "refresh_reuse"
    case deviceRevoked = "device_revoked"
    /// The Enclave signature failed, or the signed device id is not this session's (restored backup,
    /// cloned device). The old binding cannot be repaired — a NEW keypair and a re-bind are needed.
    case deviceKeyMismatch = "device_key_mismatch"

    public var stableCode: String {
        return self.rawValue
    }
}

/// Zenlygram — the refusals that are about the REQUEST, never about the subscription.
public enum SGEntitlementRefusalCode: String, CaseIterable, Hashable {
    case invalidRequest = "invalid_request"
    case invalidPubkey = "invalid_pubkey"
    case bindPaused = "bind_paused"
    case bindNotFound = "bind_not_found"
    case trialAlreadyUsed = "trial_already_used"
    case trialDeviceCap = "trial_device_cap"
    case trialDeviceBlocked = "trial_device_blocked"
    case trialPaused = "trial_paused"
    /// 409: the policy is paid, but the operator has not enabled the server's own trial
    /// (`monetization_trial.enabled` false) — the signed policy's `trial_days` is 0, or soon will
    /// be. Not an outage, and nothing was consumed. Only a screen that raced the policy refresh
    /// meets it; `SGIAP.startServerTrial` refuses the same case locally once the policy says so.
    case trialDisabled = "trial_disabled"
    case invalidProduct = "invalid_product"
    case unknownProduct = "unknown_product"
    case invalidTransaction = "invalid_transaction"
    case appleTransactionInvalid = "apple_transaction_invalid"
    /// 401, but NOT a device-auth failure: Apple's chain or bundle-id check failed server-side.
    case appleJwsInvalid = "apple_jws_invalid"
    /// A Sandbox transaction on a Production server, or the reverse. It will NEVER succeed here.
    case appleEnvironmentMismatch = "apple_environment_mismatch"
    case appleSubscriptionConflict = "apple_subscription_conflict"
    /// 409: the transaction is a Family Sharing copy (`inAppOwnershipType` `FAMILY_SHARED`) and the
    /// server does not accept shared subscriptions (an operator switch, off by default). One more
    /// attempt gets the same answer.
    case appleFamilyShared = "apple_family_shared"
    case appleTemporarilyUnavailable = "apple_temporarily_unavailable"
    case idempotencyInFlight = "idempotency_in_flight"
    case notFound = "not_found"
    case methodNotAllowed = "method_not_allowed"
    case requestFailed = "request_failed"
}

/// Zenlygram — the classified outcome of a failed Zenlygram request.
public enum SGEntitlementFailureClass: Error, Equatable, Hashable {
    case offline(SGEntitlementOfflineCause)
    case rateLimited(retryAfter: Int)
    case session(SGEntitlementSessionFailure)
    case refused(SGEntitlementRefusalCode)
    /// A 4xx whose stable code this build does not know. Treated exactly like a known refusal.
    case unknownRefusal(code: String, status: Int)
}

/// Zenlygram — what a failure does to the LOCAL session material.
///
/// Note what this type cannot express: there is no case that clears the cached entitlement JWS, and
/// none that reduces the capability set. That is deliberate and it is the module's central
/// guarantee — **only a successfully verified token can ever reduce what the user may do. No
/// transport outcome may.** A new case here that touches the token would break invariant I2, and it
/// would have to be written on purpose.
public struct SGEntitlementSessionDrop: OptionSet, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Forget the refresh token for this account. The cached JWS stays and keeps governing.
    public static let refreshToken = SGEntitlementSessionDrop(rawValue: 1 << 0)
    /// Generate a NEW Secure-Enclave keypair before re-binding (`device_key_mismatch`).
    public static let enclaveKey = SGEntitlementSessionDrop(rawValue: 1 << 1)
}

public enum SGEntitlementConsequence: Equatable, Hashable {
    /// Nothing about the entitlement or the session changes.
    case keepEverything
    /// Drop the named session material only. Never the JWS, never vault / lock / task data.
    case dropSession(SGEntitlementSessionDrop)
}

public enum SGEntitlementRetryAdvice: Equatable, Hashable {
    /// Rebuild the credential set — a fresh nonce, a fresh ts and a fresh signature — and retry once.
    /// Re-sending captured headers is `nonce_replayed`, not de-duplication.
    case retryOnceWithFreshCredentials
    /// Re-derive the offset from this response's `server_time`, re-sign and retry exactly once.
    case resignWithServerTimeOnce
    /// Retry later with exponential backoff and jitter; honour `after` when the server gave one.
    case backoff(after: TimeInterval?)
    /// Do not retry automatically: the condition needs new material, a new build, or a human.
    case stop
}

/// What the client does about one failure, decided in exactly one place.
public struct SGEntitlementRecovery: Equatable {
    public let consequence: SGEntitlementConsequence
    public let retry: SGEntitlementRetryAdvice
    /// What to show ONLY when the action was user-initiated AND the retry advice has been exhausted.
    /// A background refresh shows nothing, ever. `nil` means silent even in the foreground.
    public let message: SGEntitlementMessage?

    public init(consequence: SGEntitlementConsequence, retry: SGEntitlementRetryAdvice, message: SGEntitlementMessage?) {
        self.consequence = consequence
        self.retry = retry
        self.message = message
    }
}

/// Zenlygram — the single place that maps a failure to a consequence.
///
/// This is the most dangerous code in the module: getting one row wrong either locks a paying user
/// out or hands a lapsed one a free ride, and the first of those costs someone their data. It is
/// written once, it is exhaustive over the enums, and it is unit tested case by case.
public enum SGEntitlementFailureMapping {
    public static func recovery(for failure: SGEntitlementFailureClass) -> SGEntitlementRecovery {
        switch failure {
        case let .offline(cause):
            switch cause {
            case .timeout, .dns, .tls, .noRoute, .connectionLost, .cancelled, .serverError, .malformedResponse, .unknown:
                // Every one of these is "we did not hear back". Nothing changes; nothing is said.
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .backoff(after: nil), message: nil)
            }
        case let .rateLimited(retryAfter):
            return SGEntitlementRecovery(
                consequence: .keepEverything,
                retry: .backoff(after: TimeInterval(max(retryAfter, 1))),
                message: .tooManyAttempts
            )
        case let .session(sessionFailure):
            switch sessionFailure {
            case .unauthenticated:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .retryOnceWithFreshCredentials, message: .signInAgain)
            case .clockSkew:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .resignWithServerTimeOnce, message: .checkDateAndTime)
            case .nonceReplayed:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .retryOnceWithFreshCredentials, message: nil)
            case .invalidToken, .expiredToken, .sessionRevoked, .deviceRevoked:
                return SGEntitlementRecovery(consequence: .dropSession(.refreshToken), retry: .stop, message: .signInAgain)
            case .refreshReuse:
                return SGEntitlementRecovery(consequence: .dropSession(.refreshToken), retry: .stop, message: .signedOutForSecurity)
            case .deviceKeyMismatch:
                return SGEntitlementRecovery(consequence: .dropSession([.refreshToken, .enclaveKey]), retry: .stop, message: .signInAgain)
            }
        case let .refused(code):
            switch code {
            case .invalidRequest, .invalidProduct, .unknownProduct, .invalidTransaction, .appleTransactionInvalid, .notFound, .methodNotAllowed, .requestFailed:
                // Client or configuration bugs. Never the user's problem and never the subscription's.
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .temporarilyUnavailable)
            case .invalidPubkey:
                // Regenerate the keypair and bind again: handled by the bind flow, not by a retry here.
                return SGEntitlementRecovery(consequence: .dropSession(.enclaveKey), retry: .stop, message: .temporarilyUnavailable)
            case .bindPaused:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .linkingUnavailable)
            case .bindNotFound:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .linkingDidNotGoThrough)
            case .trialAlreadyUsed:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .trialAlreadyUsed)
            case .trialDeviceCap:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .trialDeviceCap)
            case .trialDeviceBlocked:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .trialDeviceBlocked)
            case .trialPaused:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .trialUnavailable)
            case .trialDisabled:
                // Not offered right now, by the operator's choice: its own copy, not the outage's.
                // Nothing to retry; the next adopted policy decides whether the button comes back.
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .trialNotOffered)
            case .appleJwsInvalid, .appleSubscriptionConflict:
                // Keep the transaction UNFINISHED and hand it to a human. Never loop.
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .purchaseNeedsHelp)
            case .appleEnvironmentMismatch:
                // A build/server mismatch. It will never succeed: stop, log loudly, do not finish().
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .purchaseNeedsHelp)
            case .appleFamilyShared:
                // A Family Sharing copy the server refuses. Retrying cannot change the answer: stop,
                // leave the transaction UNFINISHED and surface the support path. Never loop.
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .purchaseNeedsHelp)
            case .appleTemporarilyUnavailable:
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .backoff(after: nil), message: nil)
            case .idempotencyInFlight:
                // The first attempt is still running: wait about a second and retry with the SAME key.
                return SGEntitlementRecovery(consequence: .keepEverything, retry: .backoff(after: 1.0), message: nil)
            }
        case .unknownRefusal:
            return SGEntitlementRecovery(consequence: .keepEverything, retry: .stop, message: .temporarilyUnavailable)
        }
    }

    // MARK: - Classification

    /// HTTP status + the server's stable `error` code -> a failure class.
    ///
    /// The stable code decides BEFORE the status does, in both directions:
    /// - `apple_jws_invalid` is a 401 that has nothing to do with the device session, so mapping it
    ///   by status would drop a refresh token over Apple's chain check.
    /// - `bind_paused`, `trial_paused` and `apple_temporarily_unavailable` are 503s that are operator
    ///   switches, not outages, so mapping them by status would show the wrong thing (or nothing).
    /// A 5xx with no code — a proxy error page, a crash — is what "offline" is for.
    public static func classify(status: Int, code: String?, retryAfter: Int?) -> SGEntitlementFailureClass {
        if status == 429 {
            return .rateLimited(retryAfter: retryAfter ?? 60)
        }
        if let code, !code.isEmpty {
            if let refusal = SGEntitlementRefusalCode(rawValue: code) {
                return .refused(refusal)
            }
            if let session = SGEntitlementSessionFailure(rawValue: code) {
                return .session(session)
            }
        }
        if status >= 500 {
            return .offline(.serverError)
        }
        if let code, !code.isEmpty {
            return .unknownRefusal(code: code, status: status)
        }
        if status == 401 {
            return .session(.unauthenticated)
        }
        if status == 404 {
            return .refused(.notFound)
        }
        if status == 405 {
            return .refused(.methodNotAllowed)
        }
        return .unknownRefusal(code: "", status: status)
    }

    /// A `URLError` -> a failure class. Everything here is `offline`.
    public static func classify(urlErrorCode: URLError.Code) -> SGEntitlementFailureClass {
        switch urlErrorCode {
        case .timedOut:
            return .offline(.timeout)
        case .cannotFindHost, .dnsLookupFailed:
            return .offline(.dns)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return .offline(.tls)
        case .cannotConnectToHost, .notConnectedToInternet:
            return .offline(.noRoute)
        case .networkConnectionLost:
            return .offline(.connectionLost)
        case .cancelled:
            return .offline(.cancelled)
        default:
            return .offline(.unknown)
        }
    }
}
