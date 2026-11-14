import Foundation

/// What one explicit Restore claim (`apple-restore`) of one transaction came to.
enum SGIAPRestoreClaimOutcome: Equatable, Sendable {
    /// A 2xx under the account's session: the server filed this receipt for that account.
    case claimed
    /// The account had no session when the claim was due (logged out or unlinked during the App
    /// Store sheet). Nothing was sent under any account; the ordinary attach ran instead.
    case noSession
    /// Offline, rate limited or temporarily unavailable (incl. a proof that could not be signed).
    /// The ordinary attach keeps the payment proof; pressing Restore again retries the claim.
    case retryable
    /// The session was refused (401 class). The ordinary attach keeps the payment proof.
    case sessionRejected
    /// `apple_subscription_conflict`: another Telegram account owns this original. Recorded as
    /// non-granting for this account; nothing is enqueued.
    case conflict
    /// Any other definitive refusal. Nothing is enqueued: an unbound attach would be refused too and
    /// would only leave a stuck entry for a receipt the server already has or will never take.
    case refused

    /// Whether the ordinary (unbound, anonymous-proof) attach follows. Only where a later automatic
    /// retry can succeed; never after a definitive refusal.
    var needsOrdinaryAttach: Bool {
        switch self {
        case .noSession, .retryable, .sessionRejected:
            return true
        case .claimed, .conflict, .refused:
            return false
        }
    }
}

/// How a failed claim's error is classified (`SGIAPStoreKitEngine.classifyClaimFailure`).
enum SGIAPRestoreClaimFailureKind: Equatable, Sendable {
    case retryable
    case sessionRejected
    case conflict
    case refused

    var outcome: SGIAPRestoreClaimOutcome {
        switch self {
        case .retryable:
            return .retryable
        case .sessionRejected:
            return .sessionRejected
        case .conflict:
            return .conflict
        case .refused:
            return .refused
        }
    }
}

/// The whole explicit claim of ONE transaction for the account Restore was pressed for, with every
/// effect injected. `SGIAPStoreKitEngine.claimForRestore` runs exactly this with the real client,
/// entitlement and StoreKit; tests run it with fakes. Generic so it carries no StoreKit or
/// `SGEntitlement` type.
///
/// Order, and why:
/// 1. Exclusive on the delivery coordinator for this transaction id: an ordinary attach in flight
///    settles first with its own captured account, and none starts until the claim returns.
/// 2. The account's session is read NOW, not when Restore was pressed: `AppStore.sync()` can sit
///    behind the Apple ID sheet for minutes, a refresh may rotate the token meanwhile, and a claim
///    presenting the old token would be `refresh_reuse` — revoking the whole binding. No session
///    now → no claim under any account.
/// 3. Success → `accept` (record ownership, adopt, finish if no outbox entry). Failure → `reject`
///    (session consequences, conflict record) with the classification.
/// 4. After the exclusive section, the ordinary attach only where an automatic retry can still
///    help (`SGIAPRestoreClaimOutcome.needsOrdinaryAttach`).
struct SGIAPRestoreClaim<Credential, Success, Failure: Error> {
    let currentCredential: () -> Credential?
    let send: (Credential) async -> Result<Success, Failure>
    let classify: (Failure) -> SGIAPRestoreClaimFailureKind
    let accept: (Success, Credential) async -> Void
    let reject: (Failure, Credential, SGIAPRestoreClaimFailureKind) -> Void
    let ordinaryAttach: () async -> Void

    @available(iOS 15.0, *)
    func run(transactionId: String, deliveries: SGIAPDeliveryCoordinator) async -> SGIAPRestoreClaimOutcome {
        let outcome = await deliveries.exclusive(id: transactionId, operation: {
            await self.claim()
        })
        if outcome.needsOrdinaryAttach {
            await self.ordinaryAttach()
        }
        return outcome
    }

    private func claim() async -> SGIAPRestoreClaimOutcome {
        guard let credential = self.currentCredential() else {
            return .noSession
        }
        switch await self.send(credential) {
        case let .success(success):
            await self.accept(success, credential)
            return .claimed
        case let .failure(failure):
            let kind = self.classify(failure)
            self.reject(failure, credential, kind)
            return kind.outcome
        }
    }
}

/// What Restore reports for a BOUND account, from every claim it made.
enum SGIAPRestoreClaimSummary: Equatable {
    /// Every current transaction was claimed for the account.
    case restored
    /// Nothing of ours came back from the App Store.
    case nothingToRestore
    /// At least one claim did not go through. Never reported as "restored".
    case notClaimed(SGIAPRestoreClaimShortfall)
}

/// The most important reason a bound Restore fell short — what the user can act on first.
enum SGIAPRestoreClaimShortfall: Equatable {
    /// A refusal no retry fixes (another account owns it, or the server refused the receipt).
    case needsHelp
    /// The account's session is gone or was refused.
    case unavailable
    /// Transport: pressing Restore again later can work.
    case noConnection
}

extension SGIAPRestoreClaimSummary {
    init(outcomes: [SGIAPRestoreClaimOutcome]) {
        guard !outcomes.isEmpty else {
            self = .nothingToRestore
            return
        }
        if outcomes.allSatisfy({ $0 == .claimed }) {
            self = .restored
        } else if outcomes.contains(where: { $0 == .conflict || $0 == .refused }) {
            self = .notClaimed(.needsHelp)
        } else if outcomes.contains(where: { $0 == .noSession || $0 == .sessionRejected }) {
            self = .notClaimed(.unavailable)
        } else {
            self = .notClaimed(.noConnection)
        }
    }
}
