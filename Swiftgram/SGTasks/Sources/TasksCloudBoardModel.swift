import Foundation
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — Cloud Tasks board: the pure UI state behind the synced board of the Tasks screen (wf15
// §3: the one board shows it whenever the resolver says `synced`) and behind the read-only
// "Sinxronlangan nusxa" view of the account's cached rows (`isSyncedCopy`).
//
// Foundation only (plus the Foundation-only wire types), so `Tests/run-cloud-model-tests.sh` checks it
// on the host against the real repository value types. The controller owns the repository and all
// I/O; this file owns every decision about WHAT the synced board shows: whether it is usable at all
// (the two gates left: no Tasks service in this build, no cloud storage), which sync state and
// problems are surfaced, which tasks are open or done and in what order, where a quick-added task
// goes, which actions a row offers (an owner deletes with Undo; an accepted recipient only completes
// or leaves) and who may do what with one task (`TasksCloudTaskPermissions`). The link state, the
// copy of older device rows and the consent that waits for the link are the status line's
// (`TasksBoardSourceResolver`), not a gate or a banner here.
//
// wf15 §5.2 (the assignee's view): the tasks assigned TO the user form their own section, "Menga
// topshirilgan" (`assignedSection`, drawn with its header only while it has a row): the accepted
// assignee rows and the PROVISIONAL rows — invitations whose automatic accept (D2, the sender is a
// contact) is queued or in flight, built from the invitation preview alone (title, due, sender) and
// gone the moment that accept fails (the id leaves `automaticAcceptInvitationIds`; the invitation,
// if still pending, is back in Takliflar). Takliflar counts only the invitations the policy left
// for the user.

/// The user-facing kind of an unsent change, one per wire operation kind.
public enum TasksCloudOperationDisplayKind: Equatable {
    case listCreate
    case listUpdate
    case listDelete
    case taskCreate
    case taskUpdate
    case taskComplete
    case taskDelete
    case inviteRequest
    case inviteRespond
    case inviteRevoke
    case senderBlock
    case senderUnblock
}

/// Why an unsent change is where it is, as the user reads it.
public enum TasksCloudIssueDisplayState: Equatable {
    public enum ConflictReason: Equatable {
        case revisionChanged
        case invitationChanged
        case invitationExpired
        case completedTask
    }

    case waiting
    case sending
    case waitingForEarlierChange
    case paused
    case creationNotPermitted
    case invalid
    case integrity
    case conflict(ConflictReason)
    case notFound
    case awaitingSync
    case stalled
    /// The server account behind this native account changed: never sent under the new one.
    case accountChanged
    case rateLimited(seconds: Int?)
    case offline
    /// 503: the service, not the connection.
    case serviceUnavailable
    /// The entitlement session is missing or refused: waits for linking/sign-in, not the network.
    case sessionProblem
    /// R4 `field_changed`: these fields of an edit changed on another device (content order). "Keep
    /// mine" sends the edit again over the new values; "Use the other version" discards it.
    case fieldsChanged([SGTasksWire.ContentField])
    /// R4 `members_changed`: the list's tasks changed since its delete was decided; the user confirms
    /// the delete again with the current task count, or keeps the list.
    case membersChanged
    /// R4: waiting while this account has no data consent for Cloud tasks (or withdrew it).
    case consentRequired
    /// R4: waiting while the server holds Tasks requests until the account's consent is confirmed.
    case consentFenced
}

/// The synced board cannot be shown at all; the card says why (wf15 §3.2: the only gate cards left).
public enum TasksCloudGate: Equatable {
    /// This build has no Tasks service.
    case notConfigured
    /// The cloud cache cannot be opened.
    case storageUnavailable
}

/// The one sync-state card above the tasks. Content stays visible and editable underneath.
public enum TasksCloudBanner: Equatable {
    /// First snapshot is still loading; nothing is known to be missing yet.
    case loading
    /// 403 tasks_account_not_linked: sync paused, everything kept, explicit linking resumes.
    case paused
    /// No entitlement session for this account yet (wf15: a banner with the link action, no gate).
    case notSignedIn
    /// The entitlement session itself was refused; signing in again goes through linking.
    case sessionInvalid
    case offline
    case unavailable
    case rateLimited(seconds: Int?)
    /// R4 (`phaseRefinement`, read before the phase): no data consent for synced tasks, or it was
    /// withdrawn (`withdrawn`). The cached board stays visible, read-only.
    case consentRequired(withdrawn: Bool)
    /// R4: the server holds Tasks requests until the account's consent is confirmed (403
    /// `tasks_consent_required`). The cached board is read-only; queued changes are kept.
    case consentFenced
}

/// R4: why cached cloud content is read-only right now (nothing can be queued or sent).
public enum TasksCloudReadOnlyReason: Equatable {
    /// No data consent for Cloud tasks on this account.
    case consentOff
    /// The account's consent was withdrawn: sync stopped, unsent changes were discarded.
    case withdrawn
    /// The server holds Tasks requests until the account's consent is confirmed.
    case consentFenced
}

/// The consent hold of `phaseRefinement` (read BEFORE `phase`) that makes the cached board
/// read-only; nil when changes may be made (a consent that only waits for the link queues them).
public func tasksCloudReadOnlyReason(_ cloud: SGTasksCloudState, isConsentWithdrawn: Bool) -> TasksCloudReadOnlyReason? {
    switch cloud.phaseRefinement {
    case .consentRequired(waiting: false)?:
        return isConsentWithdrawn ? .withdrawn : .consentOff
    case .consentFenced?:
        return .consentFenced
    case .consentRequired(waiting: true)?, nil:
        return nil
    }
}

public enum TasksCloudBoardRow: Equatable {
    case gate(TasksCloudGate)
    case banner(TasksCloudBanner)
    case notice(id: Int64, kind: SGTasksCloudNotice.Kind)
    /// R4 automatic-resolution notice (a kept delete, fields changed elsewhere); dismissed by id.
    case resolutionNotice(id: Int64, kind: SGTasksCloudResolutionNotice.Kind)
    case invitations(count: Int)
    /// Unsent outbox entries: `attention` of them need an explicit user choice.
    case unsent(pending: Int, attention: Int)
    case emptyMessage(TasksBoardEmptyKind)
    case task(id: String)
    /// wf15 §5.2: a provisional "Menga topshirilgan" row — an invitation whose automatic accept is
    /// queued or in flight; a preview, never access (no completion, no izoh, opens read-only).
    case provisionalTask(invitationId: String)
    case completedHeader(count: Int, isExpanded: Bool)
    case privacyNote
    /// The footer of the read-only "Sinxronlangan nusxa" view (`tasks_syncedCopy_footer`).
    case syncedCopyNote
}

/// Where a task belongs, shown under its title while "All" is selected.
public enum TasksCloudTaskPlacement: Equatable {
    case cloudInbox
    case list(title: String)
    /// Accepted shared task; the owner is a neutral numeric Telegram id (never a sender-supplied name).
    case sharedBy(ownerTelegramId: String)
}

public enum TasksCloudTaskSyncStatus: Equatable {
    case synced
    /// Saved on this device, not yet confirmed by the server.
    case notSent
    /// Refused or stuck: needs an explicit choice on the Unsent Changes screen.
    case needsAttention
}

/// The row-level swipe/context action besides completion.
public enum TasksCloudRowRemoval: Equatable {
    /// Owner: held delete with an Undo toast.
    case delete
    /// Accepted recipient: confirmed Leave, no Undo.
    case leave
}

/// wf15 §5.6 fallback (1): the owner-entered assignee of the device row mapped to a cloud task in the
/// current import scope (`assignee_peer_id` converted, `assignee_display_name`). Local, never sent.
public struct TasksLegacyDeviceAssignee: Equatable {
    public let recipient: SGTasksWire.TelegramId
    public let name: String

    public init(recipient: SGTasksWire.TelegramId, name: String) {
        self.recipient = recipient
        self.name = name
    }
}

/// The owner's Masʼul of one task as the row and the editor show it (wf15 §4.3, §5.6): who, in which
/// state, and the two device-local name fallbacks already matched to that recipient's id. The UI adds
/// the viewer's contact name and the numeric fallback (`TasksAssigneeNameFallback`).
public struct TasksAssigneeDisplay: Equatable {
    public let recipient: SGTasksWire.TelegramId
    public let state: TasksAssigneeDisplayState
    /// The mapped device row's owner-entered name, when that row names this recipient.
    public let deviceRowName: String?
    /// The legacy annotation's owner-entered name, when it names this recipient.
    public let annotationName: String?

    public init(recipient: SGTasksWire.TelegramId, state: TasksAssigneeDisplayState, deviceRowName: String?, annotationName: String?) {
        self.recipient = recipient
        self.state = state
        self.deviceRowName = deviceRowName
        self.annotationName = annotationName
    }
}

public struct TasksCloudTaskDisplay: Equatable {
    public let id: String
    public let title: String
    public let isCompleted: Bool
    public let placement: TasksCloudTaskPlacement
    /// The owner's assignee (the owner-only annotation naming a contact), never shown on shared rows.
    public let assigneeName: String?
    public let dueAt: Int32?
    public let syncStatus: TasksCloudTaskSyncStatus
    public let removal: TasksCloudRowRemoval
    /// wf15 §4.3: the owner's Masʼul line ("Masʼul: Ism · holat"); nil on shared rows and for a task
    /// nobody is assigned to.
    public let assignee: TasksAssigneeDisplay?
}

/// wf15 §5.2: a provisional "Menga topshirilgan" row, built from the invitation preview only — the
/// title, the deadline and the sender (the viewer's contact; the UI shows the contact name). It
/// exists exactly while the automatic accept is queued, in flight or acknowledged but unproven
/// (`SGTasksCloudState.automaticAcceptInvitationIds`); it is not access.
public struct TasksCloudProvisionalTask: Equatable {
    public let invitationId: SGTasksWire.UUID
    public let taskId: SGTasksWire.UUID
    public let title: String
    public let dueAt: Int32?
    public let ownerTgId: SGTasksWire.TelegramId

    public init(invitationId: SGTasksWire.UUID, taskId: SGTasksWire.UUID, title: String, dueAt: Int32?, ownerTgId: SGTasksWire.TelegramId) {
        self.invitationId = invitationId
        self.taskId = taskId
        self.title = title
        self.dueAt = dueAt
        self.ownerTgId = ownerTgId
    }

    public init(_ invitation: SGTasksCloudInvitation) {
        self.init(invitationId: invitation.id, taskId: invitation.taskId, title: invitation.title, dueAt: invitation.dueAt, ownerTgId: invitation.ownerTgId)
    }
}

public enum TasksCloudLimits {
    public static let descriptionGraphemes = 4096
    public static let descriptionUTF8Bytes = 16384
}

public enum TasksCloudDescriptionValidation: Equatable {
    /// nil: no description (empty or nothing visible).
    case valid(String?)
    case tooLong
}

/// A description is optional free text: empty or invisible-only clears it; over the wire limits it is
/// refused (never truncated).
public func tasksCloudValidateDescription(_ raw: String) -> TasksCloudDescriptionValidation {
    if raw.count > TasksCloudLimits.descriptionGraphemes || raw.utf8.count > TasksCloudLimits.descriptionUTF8Bytes {
        return .tooLong
    }
    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .valid(nil)
    }
    return .valid(raw)
}

public func tasksCloudOperationDisplayKind(_ kind: SGTasksWire.OperationKind) -> TasksCloudOperationDisplayKind {
    switch kind {
    case .listCreate:
        return .listCreate
    case .listUpdate:
        return .listUpdate
    case .listDelete:
        return .listDelete
    case .taskCreate:
        return .taskCreate
    case .taskUpdate:
        return .taskUpdate
    case .taskComplete:
        return .taskComplete
    case .taskDelete:
        return .taskDelete
    case .inviteRequest:
        return .inviteRequest
    case .inviteRespond:
        return .inviteRespond
    case .inviteRevoke:
        return .inviteRevoke
    case .senderBlock:
        return .senderBlock
    case .senderUnblock:
        return .senderUnblock
    }
}

/// The exact sealed kind: an R4 `task.patch` reads as a task edit.
public func tasksCloudOperationDisplayKind(_ kind: SGTasksWire.MutationKind) -> TasksCloudOperationDisplayKind {
    switch kind {
    case let .operation(operation):
        return tasksCloudOperationDisplayKind(operation)
    case .taskPatch:
        return .taskUpdate
    }
}

private func tasksCloudSeconds(until date: Date?, now: Date) -> Int? {
    guard let date else {
        return nil
    }
    let seconds = Int(date.timeIntervalSince(now).rounded(.up))
    return seconds > 0 ? seconds : nil
}

/// What an unsent entry's line says. A queued entry reads as the account-level reason it is not
/// moving (the R4 consent hold first, then paused, offline, rate limited) rather than a generic
/// "waiting". An R4 conflict reads by its refinement (`members_changed`, then `field_changed`).
public func tasksCloudIssueDisplayState(_ entry: SGTasksCloudEntry, phase: SGTasksCloudState.Phase, refinement: SGTasksCloudState.PhaseRefinement? = nil, now: Date) -> TasksCloudIssueDisplayState {
    switch entry.status {
    case .queued, .held:
        switch refinement {
        case .consentRequired(waiting: false)?:
            return .consentRequired
        case .consentFenced?:
            return .consentFenced
        case .consentRequired(waiting: true)?:
            return .waiting
        case nil:
            break
        }
        switch phase {
        case .pausedNotLinked:
            return .paused
        case .notSignedIn, .sessionInvalid:
            return .sessionProblem
        case .offline:
            return .offline
        case .unavailable:
            return .serviceUnavailable
        case let .rateLimited(retryAt):
            return .rateLimited(seconds: tasksCloudSeconds(until: retryAt, now: now))
        default:
            return .waiting
        }
    case .sending:
        return .sending
    case .waitingForDependency:
        return .waitingForEarlierChange
    case .awaitingSync:
        return .awaitingSync
    case .creationNotPermitted:
        return .creationNotPermitted
    case .invalid:
        return .invalid
    case .integrityQuarantine:
        return .integrity
    case let .conflict(reason):
        // R4 refinements of the closed R3 reason (`revision_changed` on the wire class).
        if entry.isMembersConflict {
            return .membersChanged
        }
        if !entry.conflictFields.isEmpty {
            return .fieldsChanged(entry.conflictFields)
        }
        return .conflict(TasksCloudIssueDisplayState.ConflictReason(reason))
    case .notFound:
        return .notFound
    case .stalled:
        return .stalled
    case .accountChanged:
        return .accountChanged
    }
}

public extension TasksCloudIssueDisplayState.ConflictReason {
    init(_ reason: SGTasksWire.ConflictReason) {
        switch reason {
        case .revisionChanged:
            self = .revisionChanged
        case .invitationChanged:
            self = .invitationChanged
        case .invitationExpired:
            self = .invitationExpired
        case .completedTask:
            self = .completedTask
        }
    }
}

/// Entries the Unsent Changes screen lists: everything not yet confirmed except a delete that is
/// still inside its Undo window (it has not been queued yet).
public func tasksCloudVisibleEntries(_ entries: [SGTasksCloudEntry]) -> [SGTasksCloudEntry] {
    return entries.filter { $0.status != .held }
}

public struct TasksCloudBoardState: Equatable {
    public private(set) var cloud: SGTasksCloudState
    public private(set) var filter: TasksBoardFilter
    public var isCompletedExpanded: Bool
    /// A linked entitlement session exists for this account (read synchronously from SGEntitlement).
    public private(set) var isLinked: Bool
    public private(set) var now: Date
    /// R4: the repository's `consent_withdrawn` flag (the consent hold's wording only).
    public private(set) var isConsentWithdrawn: Bool
    /// wf15 §3.4: the read-only "Sinxronlangan nusxa" view over the account's cached store after sync
    /// went off (F12): owner-role rows only, no status cards, no composer, nothing queued, and the
    /// synced-copy footer instead of the privacy note. Fixed for the view's lifetime.
    public let isSyncedCopy: Bool
    /// wf15 §5.6 / §7.2: cloud task id → the owner-entered assignee of the device row mapped to it
    /// (the host computes the join; the model only reads it).
    public private(set) var legacyDeviceAssignees: [String: TasksLegacyDeviceAssignee] = [:]
    /// wf15 §7.4: the cloud task ids whose legacy assignee was sent from this device (the durable
    /// sent set) — never a legacy candidate again, whatever happened to that assignment.
    public private(set) var legacySentTaskIds: Set<String> = []
    /// The server has spoken wire 5 (the assignee's izoh exists): picks the `_noNote` texts otherwise.
    public private(set) var serverSupportsNote: Bool = false

    public init(cloud: SGTasksCloudState, isLinked: Bool, now: Date, filter: TasksBoardFilter = .all, isCompletedExpanded: Bool = false, isConsentWithdrawn: Bool = false, isSyncedCopy: Bool = false) {
        self.cloud = cloud
        self.isLinked = isLinked
        self.now = now
        self.filter = .all
        self.isCompletedExpanded = isCompletedExpanded
        self.isConsentWithdrawn = isConsentWithdrawn
        self.isSyncedCopy = isSyncedCopy
        self.filter = self.resolved(filter)
    }

    /// A fresh repository/entitlement read. A selected list that disappeared falls back to "All".
    public mutating func update(cloud: SGTasksCloudState, isLinked: Bool, now: Date, isConsentWithdrawn: Bool = false) {
        self.cloud = cloud
        self.isLinked = isLinked
        self.now = now
        self.isConsentWithdrawn = isConsentWithdrawn
        self.filter = self.resolved(self.filter)
    }

    public mutating func select(_ filter: TasksBoardFilter) {
        self.filter = self.resolved(filter)
    }

    /// wf15 §4.3 / §5.6: the owner-side facts the host gathers outside the repository — the mapped
    /// device rows' assignees, the durable sent set and whether the server speaks wire 5.
    public mutating func updateAssignmentFacts(legacyDeviceAssignees: [String: TasksLegacyDeviceAssignee], legacySentTaskIds: Set<String>, serverSupportsNote: Bool) {
        self.legacyDeviceAssignees = legacyDeviceAssignees
        self.legacySentTaskIds = legacySentTaskIds
        self.serverSupportsNote = serverSupportsNote
    }

    private func resolved(_ filter: TasksBoardFilter) -> TasksBoardFilter {
        guard case let .folder(id) = filter else {
            return .all
        }
        return self.cloud.lists.contains(where: { $0.id.rawValue == id }) ? filter : .all
    }

    // MARK: Availability

    /// R4: the consent hold makes the cached board read-only (nil: changes may be made).
    public var readOnlyReason: TasksCloudReadOnlyReason? {
        return tasksCloudReadOnlyReason(self.cloud, isConsentWithdrawn: self.isConsentWithdrawn)
    }

    /// The synced copy is read-only by definition; the board while a consent hold applies.
    public var isReadOnly: Bool {
        return self.isSyncedCopy || self.readOnlyReason != nil
    }

    /// Consent is given and only waits for the link or its confirmation (no Tasks request yet).
    private var isWaitingForConsentConfirmation: Bool {
        if case .consentRequired(waiting: true)? = self.cloud.phaseRefinement {
            return true
        }
        return false
    }

    /// nil when the board's content can be shown. Only a build without a Tasks service and a cloud
    /// cache that does not open hide the content (wf15 §3.2); an unlinked or paused account keeps its
    /// cached rows visible with a banner, and the link itself is the status line's business.
    public var gate: TasksCloudGate? {
        switch self.cloud.phase {
        case .notConfigured:
            return .notConfigured
        case .storageUnavailable:
            return .storageUnavailable
        default:
            return nil
        }
    }

    public var isUsable: Bool {
        return self.gate == nil
    }

    /// The composer, "New List" and every other change: a usable board without a consent hold.
    public var canCompose: Bool {
        return self.isUsable && !self.isReadOnly
    }

    /// R4 states (`phaseRefinement`) come before the R3 phase. The synced copy shows none (its footer
    /// says what it is), and a consent that only waits for the link shows none either: the status
    /// line under the board says "Akkaunt bogʻlangach sinxronlash boshlanadi" with the link action.
    public var banner: TasksCloudBanner? {
        if self.isSyncedCopy {
            return nil
        }
        switch self.readOnlyReason {
        case .consentOff?:
            return .consentRequired(withdrawn: false)
        case .withdrawn?:
            return .consentRequired(withdrawn: true)
        case .consentFenced?:
            return .consentFenced
        case nil:
            break
        }
        if self.isWaitingForConsentConfirmation {
            return nil
        }
        switch self.cloud.phase {
        case .pausedNotLinked:
            return .paused
        case .notSignedIn:
            return .notSignedIn
        case .sessionInvalid:
            return .sessionInvalid
        case .offline:
            return .offline
        case .unavailable:
            return .unavailable
        case let .rateLimited(retryAt):
            return .rateLimited(seconds: tasksCloudSeconds(until: retryAt, now: self.now))
        case .syncing:
            return self.cloud.hasCompleteSnapshot ? nil : .loading
        case .idle:
            if !self.isLinked {
                return .paused
            }
            return self.cloud.hasCompleteSnapshot ? nil : .loading
        case .notConfigured, .storageUnavailable:
            return nil
        }
    }

    /// Entries waiting to be sent or confirmed (not those that need a choice, and not a delete still
    /// inside its Undo window).
    public var pendingCount: Int {
        return self.cloud.entries.filter { entry in
            switch entry.status {
            case .queued, .sending, .waitingForDependency, .awaitingSync:
                return true
            default:
                return false
            }
        }.count
    }

    public var attentionCount: Int {
        return self.cloud.entries.filter { !$0.allowedActions.isEmpty }.count
    }

    /// The server clock estimated at this state's local `now` (cached server time advanced by the
    /// local time elapsed since it arrived); nil before any server response. Expiry derives from it.
    public var serverNow: Date? {
        return self.cloud.estimatedServerNow(localNow: self.now)
    }

    /// Pending invitations the user can still answer: Takliflar (wf15 §5.2). Expired ones are left
    /// for the server to drop, and an invitation whose automatic accept is on its way (D2: the sender
    /// is a contact) is a provisional "Menga topshirilgan" row, not an entry here — it comes back
    /// the moment that accept fails and the invitation is still pending.
    public var actionableInvitations: [SGTasksCloudInvitation] {
        return self.cloud.invitations.filter { !$0.isExpired(serverTime: self.serverNow) && !self.cloud.automaticAcceptInvitationIds.contains($0.id) }
    }

    /// wf15 §5.2: the provisional rows of "Menga topshirilgan", in the snapshot's order — every
    /// invitation whose automatic accept is queued, in flight or acknowledged but unproven. None in
    /// the synced copy (own rows only).
    public var provisionalTasks: [TasksCloudProvisionalTask] {
        if self.isSyncedCopy || self.cloud.automaticAcceptInvitationIds.isEmpty {
            return []
        }
        return self.cloud.invitations.filter { self.cloud.automaticAcceptInvitationIds.contains($0.id) }.map { TasksCloudProvisionalTask($0) }
    }

    public func provisionalTask(invitationId: String) -> TasksCloudProvisionalTask? {
        return self.provisionalTasks.first(where: { $0.invitationId.rawValue == invitationId })
    }

    /// The provisional row of a task id (the row carries the task's id, so it keeps it when the
    /// accepted task arrives in its place).
    public func provisionalTask(taskId: String) -> TasksCloudProvisionalTask? {
        return self.provisionalTasks.first(where: { $0.taskId.rawValue == taskId })
    }

    // MARK: Lists and filters

    public var selectedList: SGTasksCloudList? {
        guard case let .folder(id) = self.filter else {
            return nil
        }
        return self.cloud.lists.first(where: { $0.id.rawValue == id })
    }

    /// Where a quick-added task goes: the selected list, or the virtual Cloud Inbox (`nil`) under
    /// "All". Never a hidden list creation.
    public var quickAddListId: SGTasksWire.UUID? {
        return self.selectedList?.id
    }

    public func task(id: String) -> SGTasksCloudTask? {
        return self.cloud.tasks.first(where: { $0.id.rawValue == id })
    }

    /// The synced copy shows the account's own rows only (§3.3: rows shared WITH the account are not
    /// part of the promised copy).
    private func isShown(_ task: SGTasksCloudTask) -> Bool {
        return !self.isSyncedCopy || task.viewerRole == .owner
    }

    private func matchesFilter(_ task: SGTasksCloudTask) -> Bool {
        guard self.isShown(task) else {
            return false
        }
        switch self.filter {
        case .all:
            return true
        case let .folder(id):
            return task.viewerRole == .owner && task.listId?.rawValue == id
        }
    }

    /// Cloud Inbox first, then lists in order, then tasks shared with the user.
    private func groupRank(_ task: SGTasksCloudTask, listRanks: [String: Int]) -> Int {
        if task.viewerRole == .assignee {
            return Int.max
        }
        guard let listId = task.listId else {
            return -1
        }
        return listRanks[listId.rawValue] ?? Int.max - 1
    }

    private var listRanks: [String: Int] {
        var ranks: [String: Int] = [:]
        for (index, list) in self.cloud.lists.enumerated() {
            ranks[list.id.rawValue] = index
        }
        return ranks
    }

    public var activeTasks: [SGTasksCloudTask] {
        let ranks = self.listRanks
        return self.cloud.tasks.enumerated().filter { !$0.element.isCompleted && self.matchesFilter($0.element) }.sorted { lhs, rhs in
            let lhsRank = self.groupRank(lhs.element, listRanks: ranks)
            let rhsRank = self.groupRank(rhs.element, listRanks: ranks)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.element.sortOrder != rhs.element.sortOrder {
                return lhs.element.sortOrder < rhs.element.sortOrder
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// wf15 §5.2: the open tasks assigned TO the user — the "Menga topshirilgan" section's accepted
    /// rows (`activeTasks` keeps them last; here they are split off into their own section).
    public var activeAssignedTasks: [SGTasksCloudTask] {
        return self.activeTasks.filter { $0.viewerRole == .assignee }
    }

    /// The open rows above the assigned section: the user's own tasks.
    public var activeOwnTasks: [SGTasksCloudTask] {
        return self.activeTasks.filter { $0.viewerRole != .assignee }
    }

    /// Most recently completed first; an unknown completion time (imported) sorts last.
    public var completedTasks: [SGTasksCloudTask] {
        return self.cloud.tasks.enumerated().filter { $0.element.isCompleted && self.matchesFilter($0.element) }.sorted { lhs, rhs in
            let lhsDate = lhs.element.completedAt ?? Date.distantPast
            let rhsDate = rhs.element.completedAt ?? Date.distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    public var chips: [TasksBoardChip] {
        var activeByList: [String: Int] = [:]
        var activeTotal = 0
        for task in self.cloud.tasks where !task.isCompleted && self.isShown(task) {
            activeTotal += 1
            if task.viewerRole == .owner, let listId = task.listId {
                activeByList[listId.rawValue, default: 0] += 1
            }
        }
        var chips = [TasksBoardChip(filter: .all, folderTitle: nil, activeCount: activeTotal, isSelected: self.filter == .all)]
        for list in self.cloud.lists {
            let filter = TasksBoardFilter.folder(id: list.id.rawValue)
            chips.append(TasksBoardChip(filter: filter, folderTitle: list.title, activeCount: activeByList[list.id.rawValue] ?? 0, isSelected: self.filter == filter))
        }
        return chips
    }

    // MARK: Rows

    /// The owner's Masʼul of a task (wf15 §4.3): the pure table over the overlay's assignment, the
    /// outbox (a queued `invitation.request`), the deferrals (§12.2) and the legacy candidates
    /// (§7.2: a mapped device row or an owner annotation, never a task in the sent set). nil for a
    /// shared row and for a task nobody is assigned to.
    public func assigneeDisplay(for task: SGTasksCloudTask) -> TasksAssigneeDisplay? {
        return tasksAssigneeDisplay(task: task, cloud: self.cloud, serverNow: self.serverNow, legacyDeviceAssignee: self.legacyDeviceAssignees[task.id.rawValue], isLegacySent: self.legacySentTaskIds.contains(task.id.rawValue))
    }

    public func display(_ task: SGTasksCloudTask) -> TasksCloudTaskDisplay {
        let placement: TasksCloudTaskPlacement
        if task.viewerRole == .assignee {
            placement = .sharedBy(ownerTelegramId: task.ownerTgId?.rawValue ?? "")
        } else if let listId = task.listId {
            placement = .list(title: self.cloud.lists.first(where: { $0.id == listId })?.title ?? "")
        } else {
            placement = .cloudInbox
        }
        let syncStatus: TasksCloudTaskSyncStatus
        switch task.problem {
        case .none, .some(.waitingForDependency):
            syncStatus = task.isPending ? .notSent : .synced
        case .some:
            syncStatus = .needsAttention
        }
        return TasksCloudTaskDisplay(
            id: task.id.rawValue,
            title: task.title,
            isCompleted: task.isCompleted,
            placement: placement,
            assigneeName: task.viewerRole == .owner ? task.annotation?.displayName : nil,
            dueAt: task.dueAt,
            syncStatus: syncStatus,
            removal: task.viewerRole == .owner ? .delete : .leave,
            assignee: self.assigneeDisplay(for: task)
        )
    }

    /// Section 0: account/sync status (empty for the synced copy). Section 1: the user's own open
    /// tasks (or the empty message). Section 2 (`assignedSection`, wf15 §5.2): "Menga topshirilgan" —
    /// the accepted assignee rows, then the provisional rows; empty (no header) when there is none.
    /// Section 3: the completed disclosure and, when expanded, the completed tasks. Section 4: the
    /// privacy note (the synced copy: its footer). A gated board shows only the gate.
    public var sections: [[TasksCloudBoardRow]] {
        return self.projectedSections(including: { _ in true })
    }

    /// The index of the "Menga topshirilgan" section in `sections` / `calendarSections` (the host
    /// draws its header, `sgtasks.assigned.header`, only while the section has a row).
    public static let assignedSection = 2

    /// The board's sections with only the open/completed/assigned tasks (provisional rows included)
    /// narrowed to one calendar day or to undated tasks, in the board's own order and with that
    /// projection's completed count. Account status and the footer note are not per-task and stay;
    /// a gated board still shows only its gate. `.all` is exactly `sections`.
    public func calendarSections(filter: TasksCalendarFilter, calendar: Calendar) -> [[TasksCloudBoardRow]] {
        let matcher = TasksCalendarMatcher(filter: filter, calendar: calendar)
        return self.projectedSections(including: { matcher.matches(dueAt: $0) })
    }

    /// The (projected) deadline of every task the current list filter shows — open, assigned
    /// (provisional rows included) and completed; nil for each undated task. Empty while gated:
    /// cached cloud content is never surfaced behind a gate.
    public var calendarDueDates: [Int32?] {
        if self.gate != nil {
            return []
        }
        return (self.activeTasks + self.completedTasks).map { $0.dueAt } + self.provisionalTasks.map { $0.dueAt }
    }

    private func projectedSections(including isIncluded: (Int32?) -> Bool) -> [[TasksCloudBoardRow]] {
        if let gate = self.gate {
            return [[.gate(gate)]]
        }
        var status: [TasksCloudBoardRow] = []
        if !self.isSyncedCopy {
            // The synced copy is a still picture of the account's own rows: no sync state, no
            // unsent changes, no invitations, no notices.
            if let banner = self.banner {
                status.append(.banner(banner))
            }
            let pending = self.pendingCount
            let attention = self.attentionCount
            if pending > 0 || attention > 0 {
                status.append(.unsent(pending: pending, attention: attention))
            }
            // The Takliflar row is the only way into that screen, and the screen is the only place
            // with "Blocked senders → Unblock" (wf15 §5.1): it stays while a sender is blocked even
            // with nothing pending (count 0: the row reads the plain title), so a block made from an
            // accepted task or from Takliflar itself can always be undone.
            let invitations = self.actionableInvitations.count
            if invitations > 0 || !self.cloud.blocks.isEmpty {
                status.append(.invitations(count: invitations))
            }
            for notice in self.cloud.notices {
                status.append(.notice(id: notice.id, kind: notice.kind))
            }
            for notice in self.cloud.resolutionNotices {
                status.append(.resolutionNotice(id: notice.id, kind: notice.kind))
            }
        }

        let active = self.activeOwnTasks.filter { isIncluded($0.dueAt) }
        let completed = self.completedTasks.filter { isIncluded($0.dueAt) }
        // wf15 §5.2: "Menga topshirilgan" — accepted rows first, then the provisional ones. A list
        // filter shows the user's own tasks only (as `matchesFilter`), so the section is empty then.
        var assignedRows: [TasksCloudBoardRow] = self.activeAssignedTasks.filter { isIncluded($0.dueAt) }.map { .task(id: $0.id.rawValue) }
        if self.filter == .all {
            assignedRows.append(contentsOf: self.provisionalTasks.filter { isIncluded($0.dueAt) }.map { .provisionalTask(invitationId: $0.invitationId.rawValue) })
        }
        let openRows: [TasksCloudBoardRow]
        if !active.isEmpty {
            openRows = active.map { .task(id: $0.id.rawValue) }
        } else if !assignedRows.isEmpty {
            // Tasks assigned to the user are tasks: nothing is claimed empty above their section.
            openRows = []
        } else if self.cloud.hasCompleteSnapshot {
            openRows = [.emptyMessage(completed.isEmpty ? .noTasks : .allDone)]
        } else {
            // Before the first complete snapshot nothing is known to be missing: no "No Tasks" /
            // "All Done" claim (the status card says what is happening); local rows still show.
            openRows = []
        }

        var completedRows: [TasksCloudBoardRow] = []
        if !completed.isEmpty {
            completedRows.append(.completedHeader(count: completed.count, isExpanded: self.isCompletedExpanded))
            if self.isCompletedExpanded {
                completedRows.append(contentsOf: completed.map { .task(id: $0.id.rawValue) })
            }
        }

        // The copy of older device rows is the status line's offer (wf15 §3.2 S6b/S8), never a row here.
        let footer: [TasksCloudBoardRow] = [self.isSyncedCopy ? .syncedCopyNote : .privacyNote]
        return [status, openRows, assignedRows, completedRows, footer]
    }
}

/// The owner's Masʼul of one task (wf15 §4.3, §5.6) from the repository's state and the two
/// device-local facts; shared by the board state and the editor so both read the same row. The
/// recipient is the assignment's; for a deferral the deferred pick's (the shadow may still show the
/// epoch it replaces); for a legacy candidate the device row's, else the annotation's. The two name
/// fallbacks are matched to that recipient here (a device row or annotation of another id is ignored).
public func tasksAssigneeDisplay(task: SGTasksCloudTask, cloud: SGTasksCloudState, serverNow: Date?, legacyDeviceAssignee: TasksLegacyDeviceAssignee?, isLegacySent: Bool) -> TasksAssigneeDisplay? {
    guard task.viewerRole == .owner else {
        return nil
    }
    let id = task.id.rawValue
    let deferral = cloud.deferredAssignments.first(where: { $0.taskId == task.id })
    let hasQueuedRequest = cloud.entries.contains(where: { $0.kind == .inviteRequest && $0.resourceId == id })
    let candidateRecipient = legacyDeviceAssignee?.recipient ?? task.annotation?.telegramUserId
    let isLegacyCandidate = candidateRecipient != nil && !task.isCompleted && !isLegacySent
    let inputs = TasksAssigneeDisplayInputs(
        assignment: task.assignment,
        hasQueuedRequest: hasQueuedRequest,
        isDeferred: deferral != nil,
        isTaskCompleted: task.isCompleted,
        completedByAssignee: false,
        isLegacyCandidate: isLegacyCandidate,
        serverNow: serverNow
    )
    guard let state = TasksAssigneeDisplayState.resolve(inputs) else {
        return nil
    }
    let recipient: SGTasksWire.TelegramId?
    switch state {
    case .queued:
        recipient = deferral?.recipientTgId ?? task.assignment?.recipientTgId
    case .notSent:
        recipient = candidateRecipient
    case .sending, .sent, .accepted, .done, .completed, .declined, .left, .expired, .removed:
        recipient = task.assignment?.recipientTgId ?? deferral?.recipientTgId
    }
    guard let recipient else {
        return nil
    }
    let deviceRowName = legacyDeviceAssignee.flatMap { $0.recipient == recipient ? $0.name : nil }
    let annotationName = task.annotation.flatMap { $0.telegramUserId == recipient ? $0.displayName : nil }
    return TasksAssigneeDisplay(recipient: recipient, state: state, deviceRowName: deviceRowName, annotationName: annotationName)
}

/// What the viewer may do with one cloud task: the UI mirror of the repository's checks
/// (`SGTasksCloudOperations`), which stay authoritative. No role beyond the server's: the owner holds
/// content, completion, sharing and delete; a recipient with the CURRENT accepted invitation may only
/// complete/reopen or leave, bound to that invitation epoch. Accepted access never expires. A shared
/// row without an accepted invitation (missing or terminal), or a vanished task, fails closed. Owner
/// rights never depend on sync state: unsent or refused changes keep editing and completion offline
/// (a Masʼul pick is checked by the repository at pick time, not here).
public struct TasksCloudTaskPermissions: Equatable {
    public enum Role: Equatable {
        case owner
        case acceptedRecipient
        case noAccess
    }

    public let role: Role
    /// The accepted invitation a recipient's completion and Leave are bound to; nil otherwise.
    public let recipientInvitationId: SGTasksWire.UUID?

    public init(task: SGTasksCloudTask?) {
        guard let task else {
            self.role = .noAccess
            self.recipientInvitationId = nil
            return
        }
        switch task.viewerRole {
        case .owner:
            self.role = .owner
            self.recipientInvitationId = nil
        case .assignee:
            if let assignment = task.assignment, assignment.state == .accepted {
                self.role = .acceptedRecipient
                self.recipientInvitationId = assignment.invitationId
            } else {
                self.role = .noAccess
                self.recipientInvitationId = nil
            }
        }
    }

    public var canEditContent: Bool {
        return self.role == .owner
    }

    public var canSetCompletion: Bool {
        return self.role != .noAccess
    }

    public var canDelete: Bool {
        return self.role == .owner
    }

    /// Assigning a Masʼul and removing one (owner only; the repository's pick-time checks still apply).
    public var canManageSharing: Bool {
        return self.role == .owner
    }

    public var canLeave: Bool {
        return self.recipientInvitationId != nil
    }
}

/// The content Save would actually submit: a valid title is trimmed, invisible-only notes become nil.
/// An invalid title or over-long notes stay raw (Save refuses those separately).
public func tasksCloudNormalizedDraft(_ draft: SGTasksCloudTaskDraft) -> SGTasksCloudTaskDraft {
    var normalized = draft
    if case let .valid(title) = tasksValidateTitle(draft.title, limit: TasksTitleLimit.task) {
        normalized.title = title
    }
    if case let .valid(description) = tasksCloudValidateDescription(draft.description ?? "") {
        normalized.description = description
    }
    return normalized
}

/// Whether Save would change anything: compared after normalization, so whitespace-only edits and
/// cleared-to-blank notes never queue a no-op update or re-seal refused content under a new id.
public func tasksCloudDraftHasChanges(_ draft: SGTasksCloudTaskDraft, from original: SGTasksCloudTaskDraft) -> Bool {
    return tasksCloudNormalizedDraft(draft) != tasksCloudNormalizedDraft(original)
}

/// The editor's "changed elsewhere" question at Save: the task as it is now differs from the draft
/// the editor opened with in a field Save writes. The owner-only annotation is not one (wf15 §4.1:
/// the repository keeps the task's current annotation whatever the draft carries), and the editor's
/// own "Masʼulni olib tashlash" or a legacy send's chained clear changes it while the editor stays
/// open — the user's own action must not raise the alert.
public func tasksCloudDraftChangedElsewhere(_ current: SGTasksCloudTaskDraft, opened: SGTasksCloudTaskDraft) -> Bool {
    var current = current
    current.annotation = nil
    var opened = opened
    opened.annotation = nil
    return current != opened
}

/// A list name typed to repair a refused list change differs from what was refused (after the same
/// trim the title rule applies). nil `refused` (unknown) never blocks the repair.
public func tasksCloudListRepairChangesTitle(_ title: String, refused: String?) -> Bool {
    guard let refused else {
        return true
    }
    if case let .valid(refusedTitle) = tasksValidateTitle(refused, limit: TasksTitleLimit.folder) {
        return title != refusedTitle
    }
    return title != refused
}

/// "Move its tasks to Cloud Inbox" exists only for a list the server refused to create (creation not
/// permitted, invalid, or quarantined) — the states the repository accepts for that move.
public func tasksCloudCanMoveListTasksToInbox(kind: SGTasksWire.OperationKind, status: SGTasksCloudEntry.Status) -> Bool {
    guard kind == .listCreate else {
        return false
    }
    switch status {
    case .creationNotPermitted, .invalid, .integrityQuarantine:
        return true
    default:
        return false
    }
}

public func tasksCloudCanMoveListTasksToInbox(problem: SGTasksCloudProblem?) -> Bool {
    switch problem {
    case .some(.creationNotPermitted), .some(.invalid), .some(.integrityQuarantine):
        return true
    default:
        return false
    }
}

/// Whether the board's own Retry may run: a pause that only linking can clear (not linked, no or a
/// refused session) is never resumed by a plain retry, and an account-wide rate limit is a durable
/// gate until its `retryAt` (a refresh would not send anything before then, so none is offered).
public func tasksCloudRetryResumesSync(phase: SGTasksCloudState.Phase, now: Date) -> Bool {
    switch phase {
    case .pausedNotLinked, .notSignedIn, .sessionInvalid, .notConfigured:
        return false
    case let .rateLimited(retryAt):
        guard let retryAt else {
            return true
        }
        return retryAt <= now
    default:
        return true
    }
}

/// R4: never while a consent hold (`phaseRefinement`, read before the phase) keeps every Tasks
/// request off: a retry would send nothing.
public func tasksCloudRetryResumesSync(cloud: SGTasksCloudState, now: Date) -> Bool {
    if cloud.phaseRefinement != nil {
        return false
    }
    return tasksCloudRetryResumesSync(phase: cloud.phase, now: now)
}

/// What the logout confirmation says about an account's cloud tasks (design 30 §5.7), from the
/// repository's unsent counts by origin and (wf15 §7.4) the number of legacy device-row assignees
/// still unsent (`sgtasks.legacyAssignees.remaining.<accountPeerId>`). Never a fake zero:
/// unreadable counts give the generic notice. The decision lives here (pure, host-tested);
/// `sgTasksLogoutNotice` only gathers the inputs and renders (revision 3).
public enum TasksLogoutNotice: Equatable {
    /// The counts could not be read: the existing generic notice, followed by the unsent-assignees
    /// paragraph when `unsentAssignees > 0`.
    case generic(unsentAssignees: Int)
    /// `unsent` user changes have not reached the server (0: no count line); `migrationPending`:
    /// device tasks are still being copied (the copy resumes at the next sign-in);
    /// `unsentAssignees` legacy device-row Masʼuls were never sent (0: no paragraph) — they are lost
    /// with the device rows at the last logout (`tasks_logout_unsentAssignees`).
    case details(unsent: Int, migrationPending: Bool, unsentAssignees: Int)

    /// nil only when nothing at all is waiting: the confirmation has no Tasks line.
    public init?(counts: (user: Int, migration: Int)?, unsentAssignees: Int) {
        let assignees = max(0, unsentAssignees)
        guard let counts else {
            self = .generic(unsentAssignees: assignees)
            return
        }
        let unsent = max(0, counts.user)
        let migrationPending = counts.migration > 0
        guard unsent > 0 || migrationPending || assignees > 0 else {
            return nil
        }
        self = .details(unsent: unsent, migrationPending: migrationPending, unsentAssignees: assignees)
    }

    /// The paragraph count of `tasks_logout_unsentAssignees` (0: none).
    public var unsentAssignees: Int {
        switch self {
        case let .generic(unsentAssignees):
            return unsentAssignees
        case let .details(_, _, unsentAssignees):
            return unsentAssignees
        }
    }
}

/// What copying device tasks to Cloud can do right now, from the consent preview's row states.
public enum TasksCloudImportAvailability: Equatable {
    /// No device lists or tasks at all.
    case nothingOnDevice
    /// Consent would enqueue (or resend) at least one row.
    case canCopy
    /// Nothing to enqueue, but some rows can never be copied as they are: the screen explains why.
    case onlyNeedsCorrection
    /// Nothing to enqueue; an earlier copy is still being sent or waits in Unsent Changes.
    case waitingOnEarlierCopy
    /// Everything is already in Cloud (or was removed there and is never re-created).
    case alreadyDone
}

public func tasksCloudImportAvailability(statuses: [SGTasksCloudImportPreview.ItemStatus]) -> TasksCloudImportAvailability {
    if statuses.isEmpty {
        return .nothingOnDevice
    }
    if statuses.contains(where: { $0.isEnqueuedByConsent }) {
        return .canCopy
    }
    if statuses.contains(where: { if case .needsCorrection = $0 { return true }; return false }) {
        return .onlyNeedsCorrection
    }
    if statuses.contains(where: { $0 == .importPending || $0 == .importBlocked }) {
        return .waitingOnEarlierCopy
    }
    return .alreadyDone
}

public extension SGTasksCloudImportPreview {
    var availability: TasksCloudImportAvailability {
        return tasksCloudImportAvailability(statuses: self.folders.map { $0.status } + self.tasks.map { $0.status })
    }
}
