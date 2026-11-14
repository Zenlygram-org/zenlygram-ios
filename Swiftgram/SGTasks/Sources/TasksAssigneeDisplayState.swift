import Foundation
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — Tasks: what the owner reads about a task's Masʼul (wf15 §4.3) and whose name is shown
// for them (§5.6). Pure: Foundation plus the repository's value types, so
// `Tests/run-cloud-model-tests.sh` checks the whole §4.3 table on the host. The board model and the
// editor hand the facts in (`TasksAssigneeDisplayInputs`); the UI only renders the answer — the state
// word (`tasks_assign_state_*`), its footer and its one action — and never decides by itself.

/// The owner's state word for a task's Masʼul, the first matching row of §4.3.
public enum TasksAssigneeDisplayState: Equatable, CaseIterable {
    /// A queued or in-flight `invitation.request`, not acknowledged yet ("Yuborilmoqda…").
    case sending
    /// A deferred assignment (§12.2: a long server rate limit; re-sent by itself) ("Navbatda").
    case queued
    /// Pending on the server, not expired — whoever the recipient is, Zenlygram or not (anti-oracle) ("Yuborildi").
    case sent
    /// Accepted, task open ("Qabul qildi").
    case accepted
    /// Accepted, completed by the assignee (wire 5 `completed_by`) ("Bajardi").
    case done
    /// Accepted, completed by the owner or by whoever wire 4 cannot name ("Bajarildi").
    case completed
    case declined
    case left
    /// Expired on the server, or pending past `expires_at` by the server clock ("7 kun ichida qabul qilinmadi").
    case expired
    /// Revoked by the owner, until the server's 3-day detach ("Olib tashlandi").
    case removed
    /// No assignment, but a legacy candidate (§7.2: a mapped device-row Masʼul or an owner annotation,
    /// never a task in the sent set) ("Hali yuborilmagan").
    case notSent

    /// The one action §4.3 offers beside the row.
    public enum Action: Equatable {
        /// Nothing beyond the row (a request on its way).
        case none
        /// Masʼulni almashtirish / Masʼulni olib tashlash (a live assignment).
        case replaceOrRemove
        /// Qayta yuborish: the same recipient, a new epoch.
        case resend
        /// Pick again (the owner removed the assignee).
        case pickAgain
        /// Yuborish: the legacy candidate's first `invitation.request`.
        case send
    }

    /// The editor footer under the row (`tasks_assign_footer_*`).
    public enum Footer: Equatable {
        case none
        case queued
        case pending
        case accepted
        case ended
        case notSent
    }

    public var action: Action {
        switch self {
        case .sending, .queued:
            return .none
        case .sent, .accepted, .done, .completed:
            return .replaceOrRemove
        case .declined, .left, .expired:
            return .resend
        case .removed:
            return .pickAgain
        case .notSent:
            return .send
        }
    }

    public var footer: Footer {
        switch self {
        case .sending:
            return .none
        case .queued:
            return .queued
        case .sent:
            return .pending
        case .accepted, .done, .completed:
            return .accepted
        case .declined, .left, .expired, .removed:
            return .ended
        case .notSent:
            return .notSent
        }
    }

    /// The Masʼul row itself opens the picker. Never while a request is on its way ("Yuborilmoqda…":
    /// the pick is being sent). In "Navbatda" it does: the request left the outbox (§12.2) and waits
    /// up to a day for its automatic re-send, and a newer pick is what cancels that deferral — without
    /// the row the owner could neither give the task to someone else nor stop the re-send.
    public var rowPicks: Bool {
        return self.action != .none || self == .queued
    }

    /// The row carries the action `sgtasks.task.<id>.assignee.resend` (Qayta yuborish / Yuborish).
    public var offersSendAction: Bool {
        return self.action == .resend || self.action == .send
    }

    /// Someone has (or is about to get) this task through a live epoch: replacing or removing them
    /// asks first (§4.2 item 5 — the only assign confirmation; "replace alert only when someone loses
    /// access"). A request still on its way, a deferral, an ended epoch and a legacy candidate ask nothing.
    public var someoneLosesAccess: Bool {
        switch self {
        case .sent, .accepted, .done, .completed:
            return true
        case .sending, .queued, .declined, .left, .expired, .removed, .notSent:
            return false
        }
    }

    /// Declined, left or expired: the recipient answered (or never did) and nobody has the task.
    public var isEnded: Bool {
        return self.action == .resend
    }
}

/// The facts §4.3 reads, gathered by the board model (or the editor) from the repository's state.
public struct TasksAssigneeDisplayInputs: Equatable {
    /// The task's current assignment as the overlay shows it (the shadow plus local changes).
    public var assignment: SGTasksCloudAssignment?
    /// An `invitation.request` for this task sits in the outbox, not acknowledged.
    public var hasQueuedRequest: Bool
    /// A deferred assignment for this task waits for its automatic re-send (§12.2).
    public var isDeferred: Bool
    public var isTaskCompleted: Bool
    /// Wire 5 `completed_by == assignee`; false on wire 4 (which cannot say who completed).
    public var completedByAssignee: Bool
    /// §7.2: a mapped device-row Masʼul or an owner annotation, and the task id is not in the sent set.
    public var isLegacyCandidate: Bool
    /// The estimated server clock; nil before any server answer (expiry is never guessed then).
    public var serverNow: Date?

    public init(assignment: SGTasksCloudAssignment? = nil, hasQueuedRequest: Bool = false, isDeferred: Bool = false, isTaskCompleted: Bool = false, completedByAssignee: Bool = false, isLegacyCandidate: Bool = false, serverNow: Date? = nil) {
        self.assignment = assignment
        self.hasQueuedRequest = hasQueuedRequest
        self.isDeferred = isDeferred
        self.isTaskCompleted = isTaskCompleted
        self.completedByAssignee = completedByAssignee
        self.isLegacyCandidate = isLegacyCandidate
        self.serverNow = serverNow
    }
}

public extension TasksAssigneeDisplayState {
    /// The §4.3 table, first match wins; nil = no assignee (the row shows "Masʼul" / "Yoʻq" and the
    /// owner picks). That includes the server's 3-day detach of an ended epoch and the detach after
    /// the assignee's consent withdrawal or account erasure: no explanation, as specified.
    static func resolve(_ inputs: TasksAssigneeDisplayInputs) -> TasksAssigneeDisplayState? {
        // A request of this device the server has not acknowledged (the outbox entry, or the
        // overlay's pending assignment that a queued request produced).
        if inputs.hasQueuedRequest {
            return .sending
        }
        if let assignment = inputs.assignment, assignment.isPending, assignment.state == .pending {
            return .sending
        }
        if inputs.isDeferred {
            return .queued
        }
        if let assignment = inputs.assignment {
            if assignment.isExpired(serverTime: inputs.serverNow) {
                return .expired
            }
            switch assignment.state {
            case .pending:
                return .sent
            case .accepted:
                if !inputs.isTaskCompleted {
                    return .accepted
                }
                return inputs.completedByAssignee ? .done : .completed
            case .declined:
                return .declined
            case .left:
                return .left
            case .expired:
                return .expired
            case .revoked:
                return .removed
            }
        }
        if inputs.isLegacyCandidate {
            return .notSent
        }
        return nil
    }
}

/// Whose name the owner sees for a recipient (§5.6, revision 3), in this order: the viewer's own
/// contact name; the owner-entered `assignee_display_name` of the device row mapped to the cloud task
/// when that row's Telegram id is the recipient's; the task's legacy `annotation.display_name` when
/// its id is the recipient's; the numeric "Telegram foydalanuvchisi N". Device-local, never on the wire.
public enum TasksAssigneeNameFallback {
    /// The order over already id-matched candidates; blank names count as absent.
    public static func resolve(contactName: String?, deviceRowName: String?, annotationName: String?, numeric: String) -> String {
        for candidate in [contactName, deviceRowName, annotationName] {
            if let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
                return candidate
            }
        }
        return numeric
    }

    /// The same order with the id checks of §5.6: a device row or an annotation of another Telegram
    /// id is ignored.
    public static func resolve(recipient: SGTasksWire.TelegramId, contactName: String?, deviceRow: (recipient: SGTasksWire.TelegramId, name: String)?, annotation: SGTasksWire.Annotation?, numeric: String) -> String {
        let deviceRowName = deviceRow.flatMap { $0.recipient == recipient ? $0.name : nil }
        let annotationName = annotation.flatMap { $0.telegramUserId == recipient ? $0.displayName : nil }
        return self.resolve(contactName: contactName, deviceRowName: deviceRowName, annotationName: annotationName, numeric: numeric)
    }
}
