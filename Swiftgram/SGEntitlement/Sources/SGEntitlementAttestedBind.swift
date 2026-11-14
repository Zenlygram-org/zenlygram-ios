import Foundation

/// Zenlygram — what the main app's Telegram side produced for one bind-attest attempt: the Telegram-
/// signed Mini App `initData` (`SGEntitlementBindAttest.initData(fromWebAppURL:)`), or why there is
/// none (`attest_bot_not_found`, `attest_no_main_app`, `timeout`, …). Never logged.
public enum SGEntitlementAttestEvidence: Equatable {
    case initData(String)
    case unavailable(reason: String)
}

/// Zenlygram — how one headless attested bind ended (`SGEntitlement.bindWithTelegramAttestation`).
/// The automatic-link scheduler decides the next attempt from it; nothing here retries on its own.
public enum SGEntitlementAttestedBindOutcome: Equatable {
    /// Bound and stored. `mergeConflict`: this phone also holds an Apple-only account with another
    /// subscription (a notice, never a failure).
    case linked(mergeConflict: Bool)
    /// The account already holds a session. Nothing was sent.
    case alreadyLinked
    /// Another bind for the account is live (the Link screen). Nothing was sent.
    case bindInProgress
    /// The server offered no usable attestation for this bind, or `/bind/attest` answered 503
    /// `attest_unavailable`.
    case attestUnavailable
    /// The Telegram side could not produce `initData` (`SGEntitlementAttestEvidence.unavailable`).
    case telegramUnavailable(reason: String)
    /// A refusal: `bind_conflict` 409, `attest_invalid|attest_stale|attest_mismatch` 422,
    /// `bind_not_found` 404, `bind_expired` 410, or any other coded 4xx.
    case refused(code: String, status: Int?)
    /// 409 `consent_stale`: the account's grant predates an erasure of this Telegram id. A new grant
    /// is needed before any automatic link.
    case consentStale
    /// The account may not link automatically (`bindPermission` is not `.allowed`). Nothing was sent
    /// — or, when that changed during the run (consent withdrawn), nothing more was: no Telegram
    /// request, `/bind/attest`, poll or stored confirmation after it.
    case notPermitted
    case rateLimited(retryAfter: Int)
    /// 503 `bind_paused`: linking is switched off server-side.
    case paused(retryAfter: Int?)
    /// No answer, a 5xx, or an answer this build could not read.
    case offline
    /// The bind ran out (`expired` / `consumed` / a key change) before a confirmation arrived.
    case expired
    /// Confirmed, but the confirmation could not be stored (another Telegram account, a changed key).
    case notStored
    /// A newer bind for the account (the Link screen, a logout) replaced this one; or the caller
    /// cancelled the run.
    case superseded
    /// An extension, or a build without the authenticated backend. Nothing was sent.
    case notConfigured
}

extension SGEntitlement {
    /// bind-attest v1.1 for ONE account, with no UI and no code fallback (C§6.6): `/bind/start` with
    /// the account's consent (`beginBind(purpose: .auto)`), Telegram-signed `initData` for that start
    /// from `attest` (run AS that account), `/bind/attest`, then `/bind/poll` until the confirmation
    /// is stored. Never sends a message to the bot and never opens the Mini App URL.
    ///
    /// Main app only, and only for an account whose `bindPermission` is `.allowed`, that holds no
    /// session and has no bind in progress. `beginBind` reads the permission once more after awaiting
    /// a logout's pending `/bind/revoke` and before an automatic consent-fallback retry, and the run
    /// reads it again before Telegram is asked, before `/bind/attest`, before every poll and before
    /// the confirmation is stored: a consent withdrawn mid-run ends the run at its next step as
    /// `.notPermitted`, and no `/bind/start` is sent after it. Every exit that does not link ends the
    /// attempt it began, so it never reads as in progress afterwards.
    public func bindWithTelegramAttestation(accountPeerId: Int64, attest: @escaping (SGEntitlementBindAttest) async -> SGEntitlementAttestEvidence) async -> SGEntitlementAttestedBindOutcome {
        let client = self.client
        if let refusal = SGEntitlementAttestedBindFlow.preflight(
            isMainApp: !self.isExtensionProcess,
            hasClient: client != nil,
            permission: self.bindPermission(accountPeerId: accountPeerId),
            isLinked: self.isLinked(accountPeerId: accountPeerId),
            isBindInProgress: self.isBindInProgress(accountPeerId: accountPeerId)
        ) {
            return refusal
        }
        guard let client else {
            return .notConfigured
        }
        let clock = self.entitlementClock
        let flow = SGEntitlementAttestedBindFlow(
            begin: { [weak self] in
                guard let self else {
                    return .failure(SGEntitlementRequestError(failure: .offline(.cancelled)))
                }
                return await self.beginBind(accountPeerId: accountPeerId, purpose: .auto)
            },
            attest: attest,
            postAttest: { start, initData in
                return await client.bindAttest(pollToken: start.pollToken, registeredPublicKey: start.registeredPublicKey, initData: initData)
            },
            poll: { start in
                return await client.bindPoll(pollToken: start.pollToken, registeredPublicKey: start.registeredPublicKey)
            },
            isCurrent: { [weak self] start in
                return self?.isCurrentBindAttempt(start.attempt) ?? false
            },
            permitted: { [weak self] in
                guard let self else {
                    return false
                }
                return self.bindPermission(accountPeerId: accountPeerId) == .allowed
            },
            complete: { [weak self] confirmation, start in
                guard let self, self.isCurrentBindAttempt(start.attempt) else {
                    return .superseded
                }
                if self.completeBind(confirmation, start: start, accountPeerId: accountPeerId) {
                    return .stored
                }
                return self.isCurrentBindAttempt(start.attempt) ? .notStored : .superseded
            },
            endAttempt: { [weak self] start in
                self?.endBindAttempt(start.attempt)
            },
            sleep: { seconds in
                // Never past the start's expiry (the flow checks), so never near UInt64's range.
                guard seconds > 0 else {
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(min(seconds, 3600.0) * 1_000_000_000.0))
            },
            now: {
                return clock.effectiveNow()
            },
            jitter: {
                return Double.random(in: SGEntitlementAttestedBindFlow.pollJitter)
            }
        )
        return await flow.run()
    }
}

/// Zenlygram — the headless attested bind as a sequence over injected steps, so its decisions and
/// its poll cadence are tested without a device identity, a network or real time.
///
/// begin → no usable attest block: `.attestUnavailable` → `attest` → `postAttest` → on `true` poll at
/// once, then twice 1 s apart, then every 3 s + jitter (−0.4…+0.8 s) — the Link screen's cadence —
/// until the start's `expires_at` → `complete`. Before `attest`, before `postAttest`, before every
/// poll and before `complete` the run stops (`interruption(_:)`): `.superseded` when it was cancelled
/// or a newer bind replaced its start, `.notPermitted` when the account may no longer link
/// automatically (consent withdrawn while it ran). `endAttempt` runs on EVERY exit after a successful
/// `begin` that does not link (a failed `begin` has already ended its own attempt).
struct SGEntitlementAttestedBindFlow {
    enum Completion: Equatable {
        case stored
        case notStored
        case superseded
    }

    static let pollJitter: ClosedRange<Double> = -0.4 ... 0.8
    /// The first polls follow a confirmed attestation closely: at once, then 1 s, then 1 s.
    static let quickPollDelays: [TimeInterval] = [1.0, 1.0]
    static let pollInterval: TimeInterval = 3.0

    let begin: () async -> Result<SGEntitlementBindStart, SGEntitlementRequestError>
    let attest: (SGEntitlementBindAttest) async -> SGEntitlementAttestEvidence
    let postAttest: (SGEntitlementBindStart, String) async -> Result<Bool, SGEntitlementRequestError>
    let poll: (SGEntitlementBindStart) async -> Result<SGEntitlementBindPollResult, SGEntitlementRequestError>
    /// Whether the start's attempt is still its account's current one (no newer bind, no logout).
    let isCurrent: (SGEntitlementBindStart) -> Bool
    /// Whether the account may still link automatically (`bindPermission` is `.allowed`), read again
    /// before every step: the run began with it, but the user can withdraw while it is in flight.
    let permitted: () -> Bool
    let complete: (SGEntitlementBindConfirmation, SGEntitlementBindStart) -> Completion
    let endAttempt: (SGEntitlementBindStart) -> Void
    let sleep: (TimeInterval) async -> Void
    let now: () -> Date
    /// A value in `pollJitter`.
    let jitter: () -> Double

    /// The checks that run before anything is sent, in order; nil when the flow may run.
    static func preflight(isMainApp: Bool, hasClient: Bool, permission: SGEntitlementBindPermission, isLinked: Bool, isBindInProgress: Bool) -> SGEntitlementAttestedBindOutcome? {
        guard isMainApp, hasClient else {
            return .notConfigured
        }
        guard permission == .allowed else {
            return .notPermitted
        }
        guard !isLinked else {
            return .alreadyLinked
        }
        guard !isBindInProgress else {
            return .bindInProgress
        }
        return nil
    }

    func run() async -> SGEntitlementAttestedBindOutcome {
        let start: SGEntitlementBindStart
        switch await self.begin() {
        case let .success(value):
            start = value
        case let .failure(error):
            return SGEntitlementAttestedBindFlow.outcome(for: error)
        }
        let outcome = await self.attestAndPoll(start)
        if case .linked = outcome {
            return outcome
        }
        self.endAttempt(start)
        return outcome
    }

    /// Why the run must not take its next step — ask Telegram as the account, post the attestation,
    /// poll or store — or nil: `.superseded` when it was cancelled or its start is no longer current,
    /// `.notPermitted` when the account may no longer link automatically.
    private func interruption(_ start: SGEntitlementBindStart) -> SGEntitlementAttestedBindOutcome? {
        guard !Task.isCancelled, self.isCurrent(start) else {
            return .superseded
        }
        guard self.permitted() else {
            return .notPermitted
        }
        return nil
    }

    private func attestAndPoll(_ start: SGEntitlementBindStart) async -> SGEntitlementAttestedBindOutcome {
        guard let attestBlock = start.validatedAttest else {
            return .attestUnavailable
        }
        // No `messages.requestMainWebView` as the account once the run may not go on.
        if let interruption = self.interruption(start) {
            return interruption
        }
        let initData: String
        switch await self.attest(attestBlock) {
        case let .initData(value):
            initData = value
        case let .unavailable(reason):
            return .telegramUnavailable(reason: reason)
        }
        // A withdrawal while Telegram was asked: the `initData` never leaves the device.
        if let interruption = self.interruption(start) {
            return interruption
        }
        switch await self.postAttest(start, initData) {
        case .success(true):
            break
        case .success(false):
            // A 200 that is not `confirmed` breaks the wire: unreadable, like any malformed 2xx.
            return .offline
        case let .failure(error):
            return SGEntitlementAttestedBindFlow.outcome(for: error)
        }
        return await self.pollUntilConfirmed(start)
    }

    private func pollUntilConfirmed(_ start: SGEntitlementBindStart) async -> SGEntitlementAttestedBindOutcome {
        let deadline = start.expiresAtDate ?? self.now().addingTimeInterval(SGEntitlementBindAttempts.defaultLifetime)
        var pollIndex = 0
        var lastFailure: SGEntitlementAttestedBindOutcome?
        var deferredUntil: Date?
        while true {
            if pollIndex > 0 {
                var delay: TimeInterval
                if pollIndex - 1 < SGEntitlementAttestedBindFlow.quickPollDelays.count {
                    delay = SGEntitlementAttestedBindFlow.quickPollDelays[pollIndex - 1]
                } else {
                    delay = SGEntitlementAttestedBindFlow.pollInterval + self.jitter()
                }
                if let deferredUntil {
                    // A 429's Retry-After wins over the cadence.
                    delay = max(delay, deferredUntil.timeIntervalSince(self.now()))
                }
                // A poll that could only go out after the start expired is never waited for.
                guard self.now().addingTimeInterval(delay) < deadline else {
                    return lastFailure ?? .expired
                }
                await self.sleep(delay)
            }
            // Never polled once the run may not go on: an unconsumed bind expires on the server.
            if let interruption = self.interruption(start) {
                return interruption
            }
            guard self.now() < deadline else {
                return lastFailure ?? .expired
            }
            pollIndex += 1
            deferredUntil = nil
            switch await self.poll(start) {
            case .success(.pending):
                lastFailure = nil
            case let .success(.confirmed(confirmation)):
                // A withdrawal while this poll was in flight: the confirmation is never stored.
                if let interruption = self.interruption(start) {
                    return interruption
                }
                switch self.complete(confirmation, start) {
                case .stored:
                    return .linked(mergeConflict: confirmation.mergeConflict ?? false)
                case .notStored:
                    return .notStored
                case .superseded:
                    return .superseded
                }
            case .success(.expired), .success(.consumed), .success(.restartBind):
                return .expired
            case .success(.denied):
                return .refused(code: "bind_denied", status: nil)
            case let .failure(error):
                let outcome = SGEntitlementAttestedBindFlow.outcome(for: error)
                switch outcome {
                case .offline:
                    // The confirmation may still be waiting: keep polling until the start expires.
                    lastFailure = .offline
                case let .rateLimited(retryAfter):
                    lastFailure = outcome
                    deferredUntil = self.now().addingTimeInterval(TimeInterval(max(retryAfter, 1)))
                default:
                    return outcome
                }
            }
        }
    }

    /// One failed request → its outcome. The stable `error` code decides first (a coded 503 such as
    /// `attest_unavailable` is otherwise just "offline"), then the failure class.
    static func outcome(for error: SGEntitlementRequestError) -> SGEntitlementAttestedBindOutcome {
        if case let .unknownRefusal(code, _) = error.failure, code == SGEntitlement.consentRequiredLocalCode {
            return .notPermitted
        }
        if case let .unknownRefusal(code, _) = error.failure, code == SGEntitlement.bindSupersededLocalCode {
            return .superseded
        }
        switch error.code {
        case .some(SGEntitlement.consentStaleCode):
            return .consentStale
        case .some("attest_unavailable"):
            return .attestUnavailable
        case .some("bind_paused"):
            return .paused(retryAfter: error.retryAfter)
        default:
            break
        }
        switch error.failure {
        case let .rateLimited(retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .offline:
            return .offline
        case let .refused(refusal):
            if refusal == .bindPaused {
                return .paused(retryAfter: error.retryAfter)
            }
            return .refused(code: error.code ?? refusal.rawValue, status: error.status)
        case let .unknownRefusal(code, status):
            return .refused(code: error.code ?? code, status: error.status ?? status)
        case let .session(cause):
            return .refused(code: cause.rawValue, status: error.status)
        }
    }
}
