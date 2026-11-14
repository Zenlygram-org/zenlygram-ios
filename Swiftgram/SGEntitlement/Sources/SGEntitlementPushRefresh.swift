import CryptoKit
import Foundation

/// Zenlygram — what a silent refresh push came to, for `application(_:didReceiveRemoteNotification:
/// fetchCompletionHandler:)` (`SGEntitlement.handleSilentPush(completion:)`).
public enum SGEntitlementPushRefreshOutcome: Equatable {
    /// At least one linked account stored a verified token for the session it was sent under.
    case newData
    /// Nothing was sent (no linked account, throttled, backing off), or every answer belonged to a
    /// session that has since changed hands or carried a token that did not verify.
    case noData
    /// Something was sent and nothing was adopted because a request failed or missed the deadline.
    case failed
}

/// Zenlygram — how one account's refresh ended.
enum SGEntitlementRefreshAttempt: Equatable {
    /// The scheduler decided not to send, or the account holds no session.
    case notAttempted
    /// A verified token was stored under the captured session.
    case adopted
    /// The server answered, but nothing was stored: the captured session was logged out, re-bound or
    /// rotated past meanwhile, or the token did not verify. The cached decision stands.
    case notAdopted
    /// Transport failure, a refusal, a 401, or the push deadline. The cached decision stands (I2).
    case failed
}

/// Zenlygram — what became of a `POST /entitlement/refresh` (`SGEntitlementClient.rotateEntitlement`).
enum SGEntitlementRotationOutcome: Equatable {
    /// The successor refresh token is persisted for the presented session.
    case rotated(SGEntitlementRefreshResult)
    /// The server rotated, but the presented session is no longer the account's (a logout or a
    /// re-bind landed meanwhile): nothing was stored. Not a transport failure.
    case sessionChanged
    /// The Keychain refused the successor, after one retry. The old token stays (60 s overlap).
    case notPersisted
    /// The request itself failed.
    case failed(SGEntitlementRequestError)
}

/// Zenlygram — the two refresh calls, injectable so the response handling runs in tests against the
/// real store, verifier and session precondition (a fake `rotate` stubs only the HTTP answer and
/// persists it with `SGEntitlementClient.persistRotation`, exactly as the client does).
struct SGEntitlementRefreshTransport {
    let fetch: (SGEntitlementSessionCredential) async -> Result<String, SGEntitlementRequestError>
    let rotate: (SGEntitlementSessionCredential, String?) async -> SGEntitlementRotationOutcome

    static func live(_ client: SGEntitlementClient) -> SGEntitlementRefreshTransport {
        return SGEntitlementRefreshTransport(
            fetch: { credential in
                return await client.fetchEntitlement(credential: credential).map { $0.entitlement }
            },
            rotate: { credential, pushToken in
                return await client.rotateEntitlement(credential: credential, pushToken: pushToken)
            }
        )
    }
}

/// Zenlygram — whether one binding still needs the current APNs token, decided from its own
/// session material.
///
/// The server stores the token per binding (one device row per Telegram account) and pushes a
/// refresh hint to the bindings of the account an operator, a refund or a renewal changed. The
/// receipt (`SGEntitlementSessionMaterial.pushTokenDigest`) lives in the binding's own Keychain
/// record: it survives a relaunch (the same token is not re-sent, and no fresh session is rotated
/// for it), and it goes with the binding on logout or re-bind.
struct SGEntitlementPushTelemetry: Equatable {
    /// The binding has not received `pushToken` yet.
    let wantsRotation: Bool
    let pushToken: String?

    init(pushToken: String?, material: SGEntitlementSessionMaterial) {
        self.pushToken = pushToken
        if let pushToken {
            self.wantsRotation = material.pushTokenDigest != SGEntitlementPushTelemetry.digest(pushToken)
        } else {
            self.wantsRotation = false
        }
    }

    /// The receipt stored for a delivered token: SHA-256, lowercase hex.
    static func digest(_ pushToken: String) -> String {
        return SGEntitlementCrypto.hexString(Data(SHA256.hash(data: Data(pushToken.utf8))))
    }
}

/// Zenlygram — runs work once the app has published its accounts (`SGEntitlement.setAccounts`).
///
/// A refresh push can relaunch a terminated app in the background before the accounts load; read
/// then, the account set is empty and the hint would be answered with nothing refreshed. Each waiter
/// runs exactly once, on `queue`: when the gate opens, or at its timeout, whichever is first. A
/// waiter that timed out is released, and a later opening never runs it again.
final class SGEntitlementReadinessGate {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: () -> Void] = [:]

    func whenOpen(timeout: TimeInterval, queue: DispatchQueue, _ body: @escaping () -> Void) {
        self.lock.lock()
        if self.isOpen {
            self.lock.unlock()
            queue.async(execute: body)
            return
        }
        let id = UUID()
        self.waiters[id] = body
        self.lock.unlock()
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            self.take(id)?()
        }
    }

    func open(queue: DispatchQueue) {
        self.lock.lock()
        self.isOpen = true
        let pending = Array(self.waiters.values)
        self.waiters.removeAll()
        self.lock.unlock()
        for body in pending {
            queue.async(execute: body)
        }
    }

    private func take(_ id: UUID) -> (() -> Void)? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.waiters.removeValue(forKey: id)
    }
}

/// Zenlygram — joins one push's per-account refreshes into the single answer UIKit allows.
///
/// The completion runs exactly once, on `queue`, when every expected attempt has been recorded or at
/// the deadline, whichever is first; attempts still running at the deadline count as `.failed`, and
/// whatever they record later is ignored here (each still applies to its own account only).
final class SGEntitlementPushRefreshCompletion {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let completion: (SGEntitlementPushRefreshOutcome) -> Void
    private var remaining: Int
    private var attempts: [SGEntitlementRefreshAttempt] = []
    private var isFinished = false

    init(expected: Int, deadline: TimeInterval, queue: DispatchQueue = .main, completion: @escaping (SGEntitlementPushRefreshOutcome) -> Void) {
        self.queue = queue
        self.completion = completion
        self.remaining = expected
        if expected <= 0 {
            self.finish()
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) { [self] in
            self.expire()
        }
    }

    func record(_ attempt: SGEntitlementRefreshAttempt) {
        self.lock.lock()
        guard !self.isFinished else {
            self.lock.unlock()
            return
        }
        self.attempts.append(attempt)
        self.remaining -= 1
        let isDone = self.remaining <= 0
        self.lock.unlock()
        if isDone {
            self.finish()
        }
    }

    private func expire() {
        self.lock.lock()
        guard !self.isFinished else {
            self.lock.unlock()
            return
        }
        self.attempts.append(contentsOf: Array(repeating: .failed, count: max(self.remaining, 0)))
        self.remaining = 0
        self.lock.unlock()
        self.finish()
    }

    private func finish() {
        self.lock.lock()
        guard !self.isFinished else {
            self.lock.unlock()
            return
        }
        self.isFinished = true
        let outcome = SGEntitlementPushRefreshCompletion.outcome(self.attempts)
        self.lock.unlock()
        let completion = self.completion
        self.queue.async {
            completion(outcome)
        }
    }

    static func outcome(_ attempts: [SGEntitlementRefreshAttempt]) -> SGEntitlementPushRefreshOutcome {
        if attempts.contains(.adopted) {
            return .newData
        }
        if attempts.contains(.failed) {
            return .failed
        }
        return .noData
    }
}

extension SGEntitlement {
    /// How long a refresh push may keep the app awake before UIKit is answered.
    static let silentPushDeadline: TimeInterval = 20.0

    /// Whether a remote notification is the entitlement server's refresh hint:
    /// `{"aps": {"content-available": 1}, "zenlypay": {"action": "refresh", ...}}` and exactly that
    /// action. It is a hint only — nothing else in it is read, and nothing in it is trusted: what
    /// the account may do still comes from a signed token the client fetches itself.
    public static func isRefreshPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let hint = userInfo["zenlypay"] as? [AnyHashable: Any], let action = hint["action"] as? String else {
            return false
        }
        return action == "refresh"
    }

    /// Accounts a refresh considers: the active one first, then every other account signed in on
    /// the install (their tokens feed the device-wide union, and a push names no account).
    static func refreshTargets(active: Int64?, known: [Int64]) -> [Int64] {
        var targets: [Int64] = []
        if let active {
            targets.append(active)
        }
        for account in known where !targets.contains(account) {
            targets.append(account)
        }
        return targets
    }
}
