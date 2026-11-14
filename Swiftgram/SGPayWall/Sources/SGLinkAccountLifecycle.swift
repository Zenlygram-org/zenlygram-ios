import Foundation
#if canImport(SGEntitlement)
import SGEntitlement
#endif

/// Main-actor-owned request lifetime and monotonic poll budget. A hidden screen keeps its code,
/// but callbacks from its old task can no longer change UI or persist a binding.
struct SGLinkAccountLifecycle {
    private var visible = false
    private var foreground = true
    private var generation = UUID()
    private var pollNotBefore: TimeInterval = 0
    private var startNotBefore: TimeInterval = 0

    var isActive: Bool { self.visible && self.foreground }

    mutating func setVisible(_ value: Bool) {
        guard self.visible != value else { return }
        self.visible = value
        self.generation = UUID()
    }

    mutating func setForeground(_ value: Bool) {
        guard self.foreground != value else { return }
        self.foreground = value
        self.generation = UUID()
    }

    mutating func beginRun() -> UUID {
        self.generation = UUID()
        return self.generation
    }

    func accepts(_ generation: UUID) -> Bool {
        return self.isActive && self.generation == generation
    }

    mutating func deferPoll(seconds: TimeInterval, now: TimeInterval) {
        // Retry-After is shared by all requests from this IP. Resuming a screen or requesting a
        // replacement code must not shorten it. All callers supply process uptime, not wall time.
        guard seconds.isFinite, now.isFinite else { return }
        self.pollNotBefore = max(self.pollNotBefore, now + max(0, seconds))
    }

    func pollDelay(now: TimeInterval) -> TimeInterval {
        return max(0, self.pollNotBefore - now)
    }

    mutating func deferStart(seconds: TimeInterval, now: TimeInterval) {
        guard seconds.isFinite, now.isFinite else { return }
        self.startNotBefore = max(self.startNotBefore, now + max(0, seconds))
    }

    func startDelay(now: TimeInterval) -> TimeInterval {
        return max(0, self.startNotBefore - now)
    }
}

/// Retain a one-shot HTTP result during a bot roundtrip. A resumed UI task awaits this same request
/// instead of polling again and receiving `consumed`. Only its current generation may consume it.
struct SGLinkAccountRequestSlot<Value> {
    struct Response {
        let value: Value
        let receivedAt: TimeInterval
    }

    struct Request {
        let id: UUID
        let task: Task<Response, Never>
    }

    private(set) var current: Request?

    @MainActor
    mutating func request(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, operation: @escaping () async -> Value) -> Request {
        if let current = self.current { return current }
        let request = Request(id: UUID(), task: Task {
            let value = await operation()
            return Response(value: value, receivedAt: now())
        })
        self.current = request
        return request
    }

    mutating func consume(_ id: UUID) {
        if self.current?.id == id { self.current = nil }
    }

    mutating func reset() {
        self.current = nil
    }
}

/// How often one link flow may restart `/bind/start` because the install key is no longer the key
/// the current start registered (`SGEntitlementBindPollResult.restartBind`). Nothing was sent for
/// that poll, so a restart consumes nothing server-side; the fresh start registers the CURRENT key,
/// and its proven poll yields a session this install can actually sign for. Bounded so a key that
/// keeps changing ends in a visible failure instead of a loop. Reset by an explicit new attempt.
struct SGLinkAccountKeyRestartBudget {
    static let limit = 1
    private(set) var used = 0

    mutating func reset() {
        self.used = 0
    }

    /// True when one more restart is allowed (and counts it).
    mutating func consumeRestart() -> Bool {
        guard self.used < SGLinkAccountKeyRestartBudget.limit else {
            return false
        }
        self.used += 1
        return true
    }
}

/// One `/bind/poll` answer as the link screen sees it, mapped one-to-one from the client's result
/// by `SGLinkAccountModel` (no decision is made in that mapping). `Failure` is the client's error,
/// passed through to the copy.
enum SGLinkAccountPollAnswer<Failure> {
    case pending
    case denied
    case expired
    case consumed
    case confirmed
    /// The install key is not the one the current start registered; nothing was sent.
    case restartBind
    case rateLimited
    case offline
    case bindNotFound
    case failed(Failure)
}

/// Why the flow ended visibly.
enum SGLinkAccountFailureReason<Failure> {
    case declined
    case codeExpired
    case didNotGoThrough
    case temporarilyUnavailable
    case failed(Failure)
}

/// What the screen does next. Every decision of the poll step lives here, so the restart budget and
/// each answer's outcome are exercised by tests exactly as `SGLinkAccountModel.poll` applies them.
enum SGLinkAccountPollReaction<Failure> {
    /// Poll again, clearing, keeping or replacing the transient hint.
    case keepPolling(hint: SGLinkAccountPollHint)
    case fail(SGLinkAccountFailureReason<Failure>)
    /// Drop the current start and issue a fresh `/bind/start` under the current key.
    case restartWithCurrentKey
    /// Store the confirmation (`SGEntitlement.completeBind`).
    case complete
}

enum SGLinkAccountPollHint: Equatable {
    case clear
    case keep
    case noConnection
}

extension SGLinkAccountKeyRestartBudget {
    /// The poll step's decision for one answer. `.restartBind` spends the budget; once it is spent
    /// the flow fails visibly ("temporarily unavailable") instead of restarting again, and it never
    /// polls the old start with another key.
    mutating func reaction<Failure>(to answer: SGLinkAccountPollAnswer<Failure>) -> SGLinkAccountPollReaction<Failure> {
        switch answer {
        case .pending:
            return .keepPolling(hint: .clear)
        case .denied:
            return .fail(.declined)
        case .expired:
            return .fail(.codeExpired)
        case .consumed:
            return .fail(.didNotGoThrough)
        case .confirmed:
            return .complete
        case .restartBind:
            return self.consumeRestart() ? .restartWithCurrentKey : .fail(.temporarilyUnavailable)
        case .rateLimited:
            return .keepPolling(hint: .keep)
        case .offline:
            return .keepPolling(hint: .noConnection)
        case .bindNotFound:
            return .fail(.didNotGoThrough)
        case let .failed(failure):
            return .fail(.failed(failure))
        }
    }
}

// Compiled wherever the entitlement module exists (the app, run-link-lifecycle-tests.sh). Host
// runners that compile this file alone (run-bind-key-tests.sh) do not use the policy.
#if canImport(SGEntitlement)
/// Zenlygram — Tasks proof mode. A stored session is not proof of a Telegram link (an Apple-only
/// session has a refresh token but no verified Telegram id), so a caller that needs a fresh Telegram
/// proof (Cloud Tasks recovering from `tasks_account_not_linked`) opens the link screen with
/// `requiresTelegramProof`. Outside proof mode every rule here answers exactly as the screen always
/// behaved.
enum SGLinkAccountProofPolicy {
    /// The screen opens on "already linked" only when a stored session is enough for the caller.
    static func opensAsLinked(hasStoredSession: Bool, requiresTelegramProof: Bool) -> Bool {
        return hasStoredSession && !requiresTelegramProof
    }

    /// Whether a failed `/bind/start` may go through `SGEntitlement.apply`. Decided from the real
    /// failure mapping: in proof mode a failure whose consequence drops the install key
    /// (`invalid_pubkey`, a key mismatch) is NOT applied, because the key may hold a valid stored
    /// session this attempt must never break. Every other failure, and every failure outside proof
    /// mode, is applied as before.
    static func appliesBindStartFailure(_ failure: SGEntitlementFailureClass, requiresTelegramProof: Bool) -> Bool {
        guard requiresTelegramProof else {
            return true
        }
        if case let .dropSession(drop) = SGEntitlementFailureMapping.recovery(for: failure).consequence, drop.contains(.enclaveKey) {
            return false
        }
        return true
    }

    /// Whether an `invalid_pubkey` from `/bind/start` may regenerate the key and start again. Never
    /// in proof mode (same reason); unchanged otherwise.
    static func mayRegenerateKeyAndRestart(requiresTelegramProof: Bool) -> Bool {
        return !requiresTelegramProof
    }
}
#endif
