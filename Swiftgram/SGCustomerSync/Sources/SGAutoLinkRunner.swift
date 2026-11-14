import Foundation
import AccountContext
import SGEntitlement
import SGBindAttest
import SGCustomerSyncCore

/// Zenlygram — runs ONE automatic link (design 40 §8, contract §6.6) when the coordinator's
/// `.autoLink` effect says so (`SGAutoLinkPolicy` decided every precondition; at most one runs on the
/// install): `SGEntitlement.bindWithTelegramAttestation` for the account, its attestation made AS that
/// account (`sgBindAttestEvidence` with the account's own context — non-primary accounts link too).
/// No UI, no code fallback, nothing sent to the bot.
///
/// When it ends: `link.attempt{trigger: auto, method: attest, …}` (`SGAutoLinkPolicy.linkAttempt`;
/// a failed one also as `error.occurred{link}`) for an attempt that is not `sentNothing` (a
/// `.notPermitted` that stopped mid-run records none, although its `bind/start` may have gone out),
/// then `completion`
/// on the main queue with the outcome as the core reads it and whether the start offered an attest
/// block (the attest closure ran). The schedule after it — and `.consentStale` (the grant is asked
/// again) or `.notPermitted` (stop until the consent or the permission changes) — is the reducer's.
final class SGAutoLinkRunner {
    /// Set once by the attest closure (any thread), read once the run ended (lock-guarded).
    private final class Offered: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.lock()
            self.value = true
            self.lock.unlock()
        }

        var isSet: Bool {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.value
        }
    }

    func run(accountPeerId: Int64, context: AccountContext, completion: @escaping (SGAutoLinkPolicy.Outcome, Bool) -> Void) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let offered = Offered()
        Task { [weak context] in
            let result = await SGEntitlement.shared.bindWithTelegramAttestation(accountPeerId: accountPeerId, attest: { attest in
                offered.set()
                guard let context else {
                    // The account's context is gone (signed out mid-run): there is no Telegram side.
                    return .unavailable(reason: "attest_no_init_data")
                }
                return await sgBindAttestEvidence(context: context, attest: attest)
            })
            let outcome = SGAutoLinkRunner.outcome(result)
            let durationS = Int(max(0, ProcessInfo.processInfo.systemUptime - startedAt).rounded(.down))
            SGMainQueue.deliver(outcome, to: { outcome in
                if let event = SGAutoLinkPolicy.linkAttempt(outcome, durationS: durationS) {
                    SGAnalytics.record(event, accountPeerId: accountPeerId)
                    // A failed attempt also counts in the session's aggregated `error.occurred{link}`
                    // (design 40 §10.2).
                    if let code = SGAutoLinkPolicy.errorCode(outcome) {
                        SGAnalytics.error(.link, code, accountPeerId: accountPeerId)
                    }
                }
                completion(outcome, offered.isSet)
            })
        }
    }

    /// `SGEntitlementAttestedBindOutcome` case by case (a link's merge-conflict flag and a refusal's
    /// status do not change the schedule).
    static func outcome(_ outcome: SGEntitlementAttestedBindOutcome) -> SGAutoLinkPolicy.Outcome {
        switch outcome {
        case .linked:
            return .linked
        case .alreadyLinked:
            return .alreadyLinked
        case .bindInProgress:
            return .bindInProgress
        case .attestUnavailable:
            return .attestUnavailable
        case let .telegramUnavailable(reason):
            return .telegramUnavailable(reason: reason)
        case let .refused(code, _):
            return .refused(code: code)
        case .consentStale:
            return .consentStale
        case .notPermitted:
            return .notPermitted
        case let .rateLimited(retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case let .paused(retryAfter):
            return .paused(retryAfter: retryAfter)
        case .offline:
            return .offline
        case .expired:
            return .expired
        case .notStored:
            return .notStored
        case .superseded:
            return .superseded
        case .notConfigured:
            return .notConfigured
        }
    }
}
