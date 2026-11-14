import Foundation
import SGEntitlement

// MARK: - Zenlygram Tasks analytics seam (taxonomy v1, contract §3.2)
//
// Pure: no SGCustomerSyncCore, UIKit or network (SGEntitlement only for the error type). Tasks code describes what happened with these
// values; the sync coordinator installs `SGTasksAnalytics.sink`, which maps each case to the
// customer layer's `SGAnalytics` facade by the registry's RAW values (`"tasks.board"`,
// `"conflict_auto_resolved"`, ...). Until it does, every emission is a no-op. No case carries task
// text, ids, names or any other user content: only the registry's enums, booleans and counts.

public enum SGTasksAnalyticsEvent: Equatable {
    case taskCreated(cloud: Bool, hasDue: Bool, priority: Int, inList: Bool), taskCompleted(cloud: Bool, reopened: Bool)
    case taskDeleted(cloud: Bool), listCreated(cloud: Bool), listDeleted(cloud: Bool, tasks: Int)
    /// `invite_sent` | `invite_accepted` | `invite_declined` | `left` | `revoked` | `blocked`.
    case shared(action: String)
    /// `started` | `completed` | `failed` (the migration coordinator's).
    case migration(phase: String, lists: Int?, tasks: Int?, skipped: Int?, durationS: Int?, errorCode: String?)
    /// `conflict_auto_resolved` | `conflict_manual` | `stalled` | `blocked_creation` | `invalid`; the
    /// facade aggregates them per session.
    case syncIssue(kind: String)
    /// `domain` `tasks_sync` | `tasks_migration`; `code` per contract §3.4 (a backend code,
    /// `http_<n>`, `timeout`, `offline`, `dns`, `tls`, `sqlite_<n>` or `unknown`).
    case error(domain: String, code: String)
    /// `tasks.board` | `tasks.lists` | `tasks.task_editor` | `tasks.calendar` |
    /// `tasks.unsent_changes` | `tasks.invitations` | `tasks.archive`.
    case screen(String)
    /// `tasks` | `tasks_cloud` | `tasks_calendar`.
    case featureUsed(String)
    /// Right before the Tasks board presents the paywall.
    case paywallEntry
}

public enum SGTasksAnalytics {
    /// The registry values the engine emits (contract §3.2), spelled once.
    enum SyncIssue {
        static let conflictAutoResolved = "conflict_auto_resolved"
        static let conflictManual = "conflict_manual"
        static let stalled = "stalled"
        static let blockedCreation = "blocked_creation"
        static let invalid = "invalid"
    }

    enum Shared {
        static let inviteSent = "invite_sent"
        static let inviteAccepted = "invite_accepted"
        static let inviteDeclined = "invite_declined"
        static let left = "left"
        static let revoked = "revoked"
        static let blocked = "blocked"
    }

    static let syncErrorDomain = "tasks_sync"

    private static let lock = NSLock()
    private static var installedSink: ((SGTasksAnalyticsEvent, Int64?) -> Void)?

    /// nil = no-op. Set by the sync coordinator; called synchronously on the emitting thread (a
    /// repository queue among others), so it must not call back into the repository.
    public static var sink: ((SGTasksAnalyticsEvent, Int64?) -> Void)? {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.installedSink
        }
        set {
            self.lock.lock()
            self.installedSink = newValue
            self.lock.unlock()
        }
    }

    static func emit(_ event: SGTasksAnalyticsEvent, accountPeerId: Int64?) {
        // Read under the lock, called outside it.
        self.sink?(event, accountPeerId)
    }

    /// Contract §3.4 `code` of a failed Tasks call: the backend code when the classification names
    /// one, else `http_<n>` / `timeout` / `offline` / `dns` / `tls` / `unknown`. Never a message.
    static func errorCode(_ error: SGTasksError) -> String {
        if case .consentRequired? = error.refinement {
            return "tasks_consent_required"
        }
        switch error.kind {
        case .notConfigured, .notSignedIn, .credentialChanged, .malformedResponse, .invalidLocalRequest:
            return "unknown"
        case .accountNotLinked:
            return "tasks_account_not_linked"
        case .creationNotPermitted:
            return "tasks_creation_not_permitted"
        case .notFound:
            return "tasks_not_found"
        case .conflict:
            return "tasks_conflict"
        case .resyncRequired:
            return "tasks_resync_required"
        case .mutationInFlight:
            return "tasks_mutation_in_flight"
        case .invalidRequest:
            return "tasks_invalid_request"
        case .mutationMismatch:
            return "tasks_mutation_mismatch"
        case .rateLimited:
            return "rate_limited"
        case .unavailable:
            return "tasks_unavailable"
        case .session:
            return "http_401"
        case let .transport(cause):
            switch cause {
            case .timeout:
                return "timeout"
            case .dns:
                return "dns"
            case .tls:
                return "tls"
            case .malformedResponse, .serverError, .unknown:
                return "unknown"
            case .noRoute, .connectionLost, .cancelled:
                return "offline"
            }
        case let .rejected(status):
            return (100 ... 999).contains(status) ? "http_\(status)" : "unknown"
        }
    }
}
