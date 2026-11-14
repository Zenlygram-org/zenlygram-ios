// MARK: Zenlygram — call recording delivery: re-sending what the native upload gate denied.
//
// A LOCKED RELAUNCH DENIES, BY DESIGN. Until Delivery has a live account, a readable sidecar and a
// protection verdict, TelegramCore's upload gate lets nothing through, so a recording upload the
// pending-message manager restarts fails. Once that proof is back the leg is re-sent ONCE, under the
// consent already recorded. Exactly two facts say "the gate denied it", and nothing else does:
//   * the LAST verdict the gate delivered for the leg's upload resource in this process. An allow
//     after a deny means any later failure is an ordinary one (network, server), which is never
//     re-sent on its own;
//   * when this process saw no verdict for the resource at all, the leg's durable mark in the
//     delivery ledger (`SGCallRecordingDeliveryLegFacts.uploadGateDenied`), written when the leg's
//     message was seen failed after a deny — so a kill between the denial and the returning proof
//     does not turn the denial into an ordinary failure. The mark lives on the facts of that one
//     attempt (correlation id): re-sending starts a fresh attempt, which drops it.
// A failure that is neither stays "not sent" for the user's own "Try sending again".
//
// NOTHING HERE GRANTS ANYTHING. A re-send additionally needs the upload allowance Delivery publishes
// only after re-validating the leg (owner signed in and not removed, same account database, ledger
// entry known and not retiring, privacy `.open` or `.protected` with this recording's own grant), a
// readable sidecar, the leg's own audio file readable, the leg's own message failed, and — for an
// AUTOMATIC delivery — the "Send to Saved Messages" setting still on: turning it off promises that
// nothing more is uploaded on its own, which includes a re-send (a legacy pair with one leg already
// acknowledged is never withdrawn, so this check is the only thing that stops its other leg). The
// user's own "Try sending again" is a manual attempt and is not affected. Any of them missing:
// nothing is re-sent, discarded or copied.

import Foundation

/// The inputs `SGCallRecordingGateDenialRecovery` decides on for one unacknowledged, enqueued leg.
public struct SGCallRecordingGateDeniedLeg: Equatable {
    public let correlationId: Int64
    /// The ledger's durable mark for this leg's attempt.
    public let durablyDenied: Bool
    /// Delivery's upload allowance for this leg exists right now (current proof re-validated).
    public let uploadAllowed: Bool
    /// The leg's own audio file can be opened right now.
    public let fileReadable: Bool
    /// `sgCallRecordingGateDeniedResendConsented` for the delivery's provenance, read now.
    public let resendConsented: Bool

    public init(correlationId: Int64, durablyDenied: Bool, uploadAllowed: Bool, fileReadable: Bool, resendConsented: Bool) {
        self.correlationId = correlationId
        self.durablyDenied = durablyDenied
        self.uploadAllowed = uploadAllowed
        self.fileReadable = fileReadable
        self.resendConsented = resendConsented
    }
}

/// Whether recorded consent still covers re-sending a denied leg without a tap: always for a manual
/// delivery, and for an automatic one only while the setting is on. An unknown provenance (`nil`, no
/// ledger entry) is never consent.
public func sgCallRecordingGateDeniedResendConsented(isAutomatic: Bool?, autoSendEnabled: Bool) -> Bool {
    guard let isAutomatic else {
        return false
    }
    return !isAutomatic || autoSendEnabled
}

/// Created with no side effects (the gate's decider holds it before any account exists).
/// `recordVerdict` may be called from any queue; everything else is main-only.
public final class SGCallRecordingGateDenialRecovery {
    private let lock = NSLock()
    /// The last verdict the gate delivered to a live upload, by resource random id. Under `lock`.
    private var lastVerdicts: [Int64: Bool] = [:]
    /// Correlation ids re-sent after a denial in this process: the denied attempt and its
    /// replacement. Main-only.
    private var resentCorrelationIds = Set<Int64>()

    public init() {
    }

    // MARK: The gate's side

    /// Every verdict the gate's decider delivers to a live upload of `resourceRandomId`.
    public func recordVerdict(resourceRandomId: Int64, allowed: Bool) {
        self.lock.lock()
        self.lastVerdicts[resourceRandomId] = allowed
        self.lock.unlock()
    }

    // MARK: Delivery's side (main)

    /// The last verdict for the leg's upload in this process; nil when there was none.
    public func lastVerdict(correlationId: Int64) -> Bool? {
        let randomId = sgCallRecordingResourceRandomId(correlationId: correlationId)
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.lastVerdicts[randomId]
    }

    /// Whether the gate is what stopped this leg: this process's last verdict, else the durable mark.
    public func wasDenied(correlationId: Int64, durablyDenied: Bool) -> Bool {
        if let allowed = self.lastVerdict(correlationId: correlationId) {
            return !allowed
        }
        return durablyDenied
    }

    /// What the leg's durable mark must say after its own message was observed. Set only once the
    /// message is seen failed after a deny; cleared as soon as the gate let this attempt through.
    public func durableDenial(correlationId: Int64, current: Bool, messageFailed: Bool) -> Bool {
        switch self.lastVerdict(correlationId: correlationId) {
        case .some(false):
            return messageFailed ? true : current
        case .some(true):
            return false
        case .none:
            return current
        }
    }

    /// The leg may be re-sent once its own failed message is seen: denied by the gate, current
    /// proof re-established, its file readable, consent still covering it, and not re-sent in this
    /// process yet. A refusal consumes nothing; the row reads "not sent" until proof and consent hold.
    public func isResendable(_ leg: SGCallRecordingGateDeniedLeg) -> Bool {
        guard leg.resendConsented, leg.uploadAllowed, leg.fileReadable, !self.resentCorrelationIds.contains(leg.correlationId) else {
            return false
        }
        return self.wasDenied(correlationId: leg.correlationId, durablyDenied: leg.durablyDenied)
    }

    /// The one re-send decision, at the moment the leg's own message is observed.
    public func shouldResend(_ leg: SGCallRecordingGateDeniedLeg, messageFailed: Bool, sidecarReadable: Bool) -> Bool {
        return messageFailed && sidecarReadable && self.isResendable(leg)
    }

    /// An observer that already exists only re-reports when its messages change, and a denied
    /// leg's failed message does not change when proof returns. It must be restarted (so it reports
    /// the current values again) exactly when some leg it watches became re-sendable.
    public func observerMustReevaluate(_ legs: [SGCallRecordingGateDeniedLeg]) -> Bool {
        return legs.contains(where: { self.isResendable($0) })
    }

    /// Called as the leg is re-sent under `fresh`: neither attempt is re-sent again in this process.
    public func markResent(old: Int64, fresh: Int64) {
        self.resentCorrelationIds.insert(old)
        self.resentCorrelationIds.insert(fresh)
        let randomId = sgCallRecordingResourceRandomId(correlationId: old)
        self.lock.lock()
        self.lastVerdicts.removeValue(forKey: randomId)
        self.lock.unlock()
    }
}
