import Foundation
import SGEntitlement

// MARK: - Zenlygram Tasks cloud: consumer-visible value types
//
// Everything the Tasks UI reads about one native account's cloud board. The repository builds these
// from the server shadow plus the optimistic overlay of unresolved outbox entries; the UI never
// touches SQL or the wire codec directly. Shared (assignee) rows never carry the owner's list or
// private annotation, and notices about lost access never carry another owner's content.

/// wf15 §12.1: which of the client pacer's limits one more manual Masʼul pick would exceed
/// (`SGTasksCloudError.assignmentLimit`; the UI maps each case to its `tasks_assign_limit*`
/// sentence). The limits themselves are `SGTasksInvitationPacer`'s.
public enum SGTasksAssignmentLimit: String, Equatable, CaseIterable, Sendable {
    /// The 6th assignment to one recipient within a UTC day.
    case perPerson
    /// The 11th manual pick within one minute.
    case perMinute
    /// The 96th assignment of the UTC day.
    case total
    /// 95 or more of the account's assignments still wait for an answer.
    case pending
}

/// A local validation or state refusal. Contains no task text, ids of other users or SQL.
public enum SGTasksCloudError: Error, Equatable {
    case storageUnavailable
    case accountRemoved
    case invalidTitle
    case invalidDescription
    case invalidAnnotation
    case annotationNotConvertible
    case invalidDueDate
    case invalidPriority
    case invalidSortOrder
    case listNotFound
    case taskNotFound
    case invitationNotFound
    case notOwner
    case notAssignee
    case taskCompleted
    case listHasPendingChanges
    case recipientNotConvertible
    case entryNotFound
    case actionNotAllowed
    case notLinked
    case importRequiresCompleteSnapshot
    case importSnapshotStale
    /// The confirmed target (revision / invitation epoch) changed before the action committed.
    case changedElsewhere
    case invitationExpired
    /// An equivalent operation for the same target is already queued.
    case alreadyPending
    /// Later unsent edits of the same task must be discarded (or settle) before this repair.
    case laterChangesPending
    /// R4: the account's Tasks consent was withdrawn (or the migration step's consent epoch is no
    /// longer the current one): nothing can be queued until it is granted again.
    case consentWithdrawn
    /// wf15 §4.2: the Masʼul picked is the account itself. Refused at pick time; nothing is queued.
    case selfAssignment
    /// wf15 §12.1: the client pacer refuses one more manual pick right now (`SGTasksInvitationPacer`;
    /// the case says which sentence). Refused at pick time; nothing is queued.
    case assignmentLimit(SGTasksAssignmentLimit)
}

/// Whether Cloud Tasks may talk to the backend for an account (design 30 §5.1). Fail closed: every
/// state except `allowed` and `legacy` sends no Tasks request at all (realtime included).
/// - `legacy`: exactly R3 — board-driven cycles, single mutations, explicit import; only for a
///   build without a Tasks backend, where every call answers `notConfigured` without a request.
/// - `forbidden`: no consent / unknown customer state (the default before the coordinator installs
///   the real source).
/// - `waiting`: events may be recorded, Tasks sync not yet.
/// - `allowed`: the R4 engine — batch drain, driver, automatic resolution and retry.
public enum SGTasksSyncPermission: Equatable {
    case legacy
    case forbidden
    case waiting
    case allowed
}

/// Why the app-level driver asks for a cycle (`SGTasksCloudRepository.requestDrive`).
public enum SGTasksDriveReason: String, Equatable {
    case launch
    case foreground
    case timer
    case session
    case link
    case consent
    case network
    case background
}

/// Editable owner content of a cloud task. `listId == nil` is the virtual Cloud Inbox.
public struct SGTasksCloudTaskDraft: Equatable {
    public var listId: SGTasksWire.UUID?
    public var title: String
    public var description: String?
    public var dueAt: Int32?
    public var priority: Int
    public var annotation: SGTasksCloudAnnotationDraft?
    /// nil appends after the last task of the target list.
    public var sortOrder: Int32?

    public init(listId: SGTasksWire.UUID? = nil, title: String, description: String? = nil, dueAt: Int32? = nil, priority: Int = 0, annotation: SGTasksCloudAnnotationDraft? = nil, sortOrder: Int32? = nil) {
        self.listId = listId
        self.title = title
        self.description = description
        self.dueAt = dueAt
        self.priority = priority
        self.annotation = annotation
        self.sortOrder = sortOrder
    }
}

/// The owner-only assignee: a private annotation naming a contact, which only the owner sees. It is
/// data, never an invitation or delivery.
public struct SGTasksCloudAnnotationDraft: Equatable {
    /// Packed native `PeerId.toInt64()` of a CloudUser; converted to the raw Telegram id before sealing.
    public var cloudUserPeerId: Int64
    public var displayName: String

    public init(cloudUserPeerId: Int64, displayName: String) {
        self.cloudUserPeerId = cloudUserPeerId
        self.displayName = displayName
    }
}

/// Why a visible row is not (yet) in its server state.
public enum SGTasksCloudProblem: Equatable {
    case creationNotPermitted
    case invalid
    case integrityQuarantine
    case conflict(SGTasksWire.ConflictReason)
    case notFound
    case stalled
    case waitingForDependency
    /// The server account behind this native account changed (rebind/merge): the operation was
    /// decided for the previous account and is never sent under the new one.
    case accountChanged
}

public struct SGTasksCloudList: Equatable {
    public let id: SGTasksWire.UUID
    public let title: String
    public let sortOrder: Int32
    /// nil until the create has been acknowledged and synced.
    public let revision: SGTasksWire.Revision?
    public let createdAt: Date?
    public let isPending: Bool
    public let problem: SGTasksCloudProblem?
}

public struct SGTasksCloudAssignment: Equatable {
    public let invitationId: SGTasksWire.UUID
    public let recipientTgId: SGTasksWire.TelegramId
    public let state: SGTasksWire.AssignmentState
    /// nil while a locally requested share has not been synced yet.
    public let expiresAt: Date?
    public let isPending: Bool

    /// Expiry is derived from server time only; it never pretends a new revision occurred.
    public func isExpired(serverTime: Date?) -> Bool {
        if self.state == .expired { return true }
        guard self.state == .pending, let expiresAt = self.expiresAt, let serverTime = serverTime else { return false }
        return serverTime >= expiresAt
    }
}

public struct SGTasksCloudTask: Equatable {
    public let id: SGTasksWire.UUID
    public let listId: SGTasksWire.UUID?
    public let title: String
    public let description: String?
    public let dueAt: Int32?
    public let priority: Int
    public let sortOrder: Int32
    public let annotation: SGTasksWire.Annotation?
    public let isCompleted: Bool
    public let completedAt: Date?
    public let createdAt: Date?
    public let viewerRole: SGTasksWire.ViewerRole
    public let ownerTgId: SGTasksWire.TelegramId?
    public let assignment: SGTasksCloudAssignment?
    public let revision: SGTasksWire.Revision?
    public let isPending: Bool
    public let problem: SGTasksCloudProblem?

    /// Assignees may only change completion or leave; owner content stays read-only for them.
    public var isReadOnlyContent: Bool {
        return self.viewerRole == .assignee
    }
}

public struct SGTasksCloudInvitation: Equatable {
    public let id: SGTasksWire.UUID
    public let taskId: SGTasksWire.UUID
    public let ownerTgId: SGTasksWire.TelegramId
    public let title: String
    public let dueAt: Int32?
    public let expiresAt: Date
    /// A local accept/decline/block is queued for this invitation.
    public let isResponsePending: Bool

    public func isExpired(serverTime: Date?) -> Bool {
        guard let serverTime = serverTime else { return false }
        return serverTime >= self.expiresAt
    }
}

public enum SGTasksCloudEntryAction: Hashable {
    case retry
    case discard
    case reapply
    case recreateCopy
    case repair
}

/// One unresolved outbox item as shown in pending/problem UI.
public struct SGTasksCloudEntry: Equatable {
    public enum Status: Equatable {
        case queued
        case sending
        case waitingForDependency
        case held
        case awaitingSync
        case creationNotPermitted
        case invalid
        case integrityQuarantine
        case conflict(SGTasksWire.ConflictReason)
        case notFound
        case stalled
        case accountChanged
    }

    public let id: Int64
    /// The R3 class of the operation: a `task.patch` (R4) is a `.taskUpdate` here — the board
    /// switches over this closed set. The exact kind is `mutationKind`.
    public let kind: SGTasksWire.OperationKind
    public let resourceId: String
    public let status: Status
    public let attempts: Int
    public let nextAttemptAt: Date?
    /// Owner-authored title only; nil for shared, invitation and block operations.
    public let displayTitle: String?
    public let lastServerTime: Date?
    /// R4: the operation exactly as sealed (`.taskPatch` included).
    public let mutationKind: SGTasksWire.MutationKind
    /// R4 `field_changed`: the fields that changed elsewhere, in content order; empty otherwise.
    public let conflictFields: [SGTasksWire.ContentField]
    /// R4 `members_changed`: the list's tasks or invitations changed since the delete was decided.
    public let isMembersConflict: Bool

    public init(id: Int64, kind: SGTasksWire.OperationKind, resourceId: String, status: Status, attempts: Int, nextAttemptAt: Date?, displayTitle: String?, lastServerTime: Date?, mutationKind: SGTasksWire.MutationKind? = nil, conflictFields: [SGTasksWire.ContentField] = [], isMembersConflict: Bool = false) {
        self.id = id
        self.kind = kind
        self.resourceId = resourceId
        self.status = status
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.displayTitle = displayTitle
        self.lastServerTime = lastServerTime
        self.mutationKind = mutationKind ?? .operation(kind)
        self.conflictFields = conflictFields
        self.isMembersConflict = isMembersConflict
    }

    public var allowedActions: Set<SGTasksCloudEntryAction> {
        switch self.status {
        case .creationNotPermitted, .stalled:
            return [.retry, .discard]
        case .invalid:
            switch self.kind {
            case .taskCreate, .taskUpdate, .listCreate, .listUpdate:
                return [.repair, .discard]
            default:
                return [.discard]
            }
        case .integrityQuarantine:
            return [.discard]
        case let .conflict(reason):
            switch self.kind {
            case .taskUpdate, .taskComplete, .taskDelete, .listUpdate, .listDelete:
                return [.reapply, .discard]
            case .inviteRequest:
                // A completed task cannot be shared: reapplying would only conflict again.
                return reason == .completedTask ? [.discard] : [.reapply, .discard]
            default:
                return [.discard]
            }
        case .notFound, .accountChanged:
            switch self.kind {
            case .taskCreate, .taskUpdate:
                return [.recreateCopy, .discard]
            default:
                return [.discard]
            }
        case .queued, .sending, .waitingForDependency, .held, .awaitingSync:
            return []
        }
    }
}

/// Content-free notices; a lost shared task never leaves an accessible copy behind.
public struct SGTasksCloudNotice: Equatable {
    public enum Kind: String, Equatable {
        case sharedAccessLost = "shared_access_lost"
        case ownResourceMissing = "own_resource_missing"
        case importFolderBlocked = "import_folder_blocked"
    }

    public let id: Int64
    public let kind: Kind
    public let date: Date
}

/// R4 content-free notices of an automatic conflict resolution (design 30 §7.3). They are a list of
/// their own beside `notices`, whose `Kind` stays the closed R3 set the board switches over.
public struct SGTasksCloudResolutionNotice: Equatable {
    public enum Kind: Equatable {
        /// A delete met a newer change made elsewhere: the task was kept, nothing was lost.
        case deleteKept
        /// These fields of an edit changed elsewhere; that part of the edit waits for a choice in
        /// Unsent Changes (the rest was sent).
        case changedElsewhere(fields: [SGTasksWire.ContentField])
    }

    public let id: Int64
    public let kind: Kind
    public let date: Date
}

/// wf15 §12.2: an assignment (`invitation.request`) the server rate-limited for longer than two
/// minutes. It left the outbox — a held entry would block every later edit of its task for up to a
/// day (F8) — and the repository sends it again by itself at the first cycle after `after`, as the
/// same pick retried (no new decision, no pacer charge). Content-free: a task id, the recipient's
/// Telegram id and a time. The owner's row reads "Navbatda"; while it waits it is an unsent change
/// (`SGTasksCloudRepository.unsentChangeCounts`), so the logout and withdrawal confirmations name it.
public struct SGTasksCloudDeferredAssignment: Equatable {
    public let taskId: SGTasksWire.UUID
    public let recipientTgId: SGTasksWire.TelegramId
    /// Local clock: the re-send happens at the first cycle that starts after this.
    public let after: Date

    public init(taskId: SGTasksWire.UUID, recipientTgId: SGTasksWire.TelegramId, after: Date) {
        self.taskId = taskId
        self.recipientTgId = recipientTgId
        self.after = after
    }
}

public struct SGTasksCloudState: Equatable {
    /// R4 states `Phase` has no case for. `Phase` stays the closed R3 set (the board switches over
    /// it exhaustively), so this is read BEFORE `phase`, as `SGTasksError.refinement` is before
    /// `kind`.
    public enum PhaseRefinement: Equatable {
        /// The consent gate holds every Tasks request (`SGTasksSyncPermission` `.waiting` when
        /// `waiting`, else `.forbidden` or a local withdrawal). `phase` is whatever the engine last
        /// was — `.idle` when nothing ran.
        case consentRequired(waiting: Bool)
        /// The server answered 403 `tasks_consent_required`: traffic backs off (30 s doubling to
        /// 15 min) until a permission change. `effectiveAt` is the wire instant of the standing
        /// withdrawal, when given. `phase` is its R3 class, `.unavailable(retryAt:)`.
        case consentFenced(effectiveAt: String?)
    }

    public enum Phase: Equatable {
        case idle
        case syncing
        case pausedNotLinked
        case notSignedIn
        case notConfigured
        case sessionInvalid
        case offline(retryAt: Date?)
        case unavailable(retryAt: Date?)
        case rateLimited(retryAt: Date?)
        case storageUnavailable
    }

    public var phase: Phase
    public var hasCompleteSnapshot: Bool
    public var lastSyncedAt: Date?
    public var serverTime: Date?
    /// Local clock when `serverTime` was received; pairs with it for `estimatedServerNow`.
    public var serverTimeReceivedAt: Date?
    public var ownTelegramId: SGTasksWire.TelegramId?
    public var lists: [SGTasksCloudList]
    public var tasks: [SGTasksCloudTask]
    public var invitations: [SGTasksCloudInvitation]
    public var blocks: [SGTasksWire.Block]
    public var entries: [SGTasksCloudEntry]
    public var notices: [SGTasksCloudNotice]
    /// R4: read before `phase` (see `PhaseRefinement`); nil when no R4 state applies.
    public var phaseRefinement: PhaseRefinement? = nil
    /// R4 automatic-resolution notices (dismissed like `notices`, by id).
    public var resolutionNotices: [SGTasksCloudResolutionNotice] = []
    /// wf15 §12.2: assignments waiting outside the outbox for their automatic re-send, by task id.
    /// The owner's row of such a task reads "Navbatda" whatever the shadow says about it.
    public var deferredAssignments: [SGTasksCloudDeferredAssignment] = []
    /// wf15 §5.3 (D2): the pending invitations whose automatic accept is queued or in flight (the
    /// sender is a contact). Each is a provisional "Menga topshirilgan" row, not a Takliflar entry;
    /// it leaves the set with the receipt (the task then arrives as an assignee row) or with a
    /// quiet drop (the invitation, if still pending, is back in Takliflar).
    public var automaticAcceptInvitationIds: Set<SGTasksWire.UUID> = []

    public static let empty = SGTasksCloudState(phase: .idle, hasCompleteSnapshot: false, lastSyncedAt: nil, serverTime: nil, serverTimeReceivedAt: nil, ownTelegramId: nil, lists: [], tasks: [], invitations: [], blocks: [], entries: [], notices: [])

    /// The last server time advanced by local elapsed time (never by the local wall clock alone);
    /// nil before any server response. The server stays authoritative for expiry.
    public func estimatedServerNow(localNow: Date = Date()) -> Date? {
        guard let serverTime = self.serverTime, let receivedAt = self.serverTimeReceivedAt else { return nil }
        return serverTime.addingTimeInterval(max(localNow.timeIntervalSince(receivedAt), 0))
    }
}

// MARK: - Explicit legacy import

public enum SGTasksCloudImportIssue: Equatable {
    case invalidTitle
    case invalidDescription
    case annotationNotConvertible
    case invalidAnnotation
    case invalidDate
    case invalidPriority
    case parentFolderNeedsCorrection
    case invalidSortOrder
    /// An earlier import attempt of this row was refused for good (quarantined / not found); the
    /// immutable mapping cannot be re-sent. Resolve the earlier entry in Unsent Changes first.
    case previousImportFailed
}

public struct SGTasksCloudImportPreview {
    public enum ItemStatus: Equatable {
        /// Never handed to the network: consent enqueues it with its reserved identity.
        case importable
        /// Handed to the network before with an unknown outcome: consent resends the SAME reserved
        /// identity. If it had already reached the cloud and was removed since, it does not reappear.
        case resendPreviousAttempt
        /// Present in this account's cloud data.
        case alreadyInCloud
        /// Its earlier import is queued or in flight in this account.
        case importPending
        /// Its earlier import was refused (creation not permitted, invalid, conflict) or stalled and
        /// waits for an explicit retry/repair/discard in Unsent Changes; never re-created here.
        case importBlocked
        /// Imported before and since removed from the cloud; the same identity is never re-created.
        case removedFromCloud
        case needsCorrection(SGTasksCloudImportIssue)

        /// Consent (re)enqueues rows in these states.
        public var isEnqueuedByConsent: Bool {
            return self == .importable || self == .resendPreviousAttempt
        }
    }

    public struct Folder: Equatable {
        public let legacyId: String
        public let title: String
        public let taskCount: Int
        /// The renamable/deletable local "Inbox" folder. It imports as a real cloud list,
        /// distinct from the empty virtual Cloud Inbox.
        public let isLegacyInbox: Bool
        public let status: ItemStatus
    }

    public struct Task: Equatable {
        public let legacyId: String
        public let title: String
        public let folderLegacyId: String
        public let status: ItemStatus
    }

    public let folders: [Folder]
    public let tasks: [Task]
    public var importableFolderCount: Int {
        return self.folders.filter { $0.status.isEnqueuedByConsent }.count
    }
    public var importableTaskCount: Int {
        return self.tasks.filter { $0.status.isEnqueuedByConsent }.count
    }

    // The immutable consent snapshot and the account it was prepared for.
    let accountPeerId: Int64
    let snapshot: TodoCloudImportSnapshot
}

public struct SGTasksCloudImportResult: Equatable {
    public let enqueuedLists: Int
    public let enqueuedTasks: Int
    /// Of the enqueued rows, those resent with an earlier reserved identity.
    public let resentPreviousAttempts: Int
    /// Present in the cloud or with an earlier import still pending.
    public let skippedAlreadyImported: Int
    public let removedFromCloud: Int
    public let blocked: Int
    public let needsCorrection: Int
}
