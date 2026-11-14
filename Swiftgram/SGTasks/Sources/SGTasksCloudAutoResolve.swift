import Foundation
import SGEntitlement

// MARK: - R4 automatic conflict resolution and retry (design 30 §7.3, §7.4)
//
// Only the R4 engine (`allowed`) resolves anything by itself; `legacy` keeps every R3 conflict and
// refusal explicit. A 409 the table below can answer is marked `auto_resolve = pending` and resolved
// right after the next COMPLETE pull, against the fresh shadow; everything else stays explicit
// (Unsent Changes), exactly as in R3. One intent is resolved automatically at most twice: a
// resolution's new entry inherits `auto_resolutions + 1`, and at 2 the next conflict is explicit.
//
// | operation      | answer                                  | automatic action                         |
// | task.patch     | field_changed F                          | the fields outside F → a new patch (new  |
// |                |                                          | id, expect = the server's values); the   |
// |                |                                          | part restricted to F stays explicit      |
// | task.complete  | revision_changed / invitation_changed    | server already in the intent → dropped;  |
// |                |                                          | else resealed (fresh base, current epoch)|
// | task.delete    | revision_changed                         | task still there → delete dropped,       |
// |                |                                          | `deleteKept` notice (nothing lost)       |
// | list.update    | revision_changed                         | three-way merge of title / sort order    |
// |                |                                          | with `base_snapshot`; disjoint → resealed|
// | list.delete    | revision_changed                         | resealed on the fresh revision, keeping  |
// |                |                                          | the members fence it was decided under   |
// | invitation.    | revision_changed                         | owner still owns and the task is open →  |
// |   request      |                                          | resealed from the shadow as a new epoch; |
// |                |                                          | else explicit (the automatic re-send of  |
// |                |                                          | a deferral: dropped, wf15 §12.2)         |
// | invitation.    | revision_changed                         | the same epoch still current → resealed; |
// |   revoke       |                                          | else dropped (the intent already holds)  |
// | task.patch     | field_changed                            | dropped: the task stays a per-task legacy|
// |  {annotation:  |                                          | candidate on the other annotation        |
// |   null} (§4.1) |                                          | (wf15 §4.1)                              |
// | invitation.    | revision_changed                         | the AUTOMATIC accept of a contact's      |
// |   respond      |                                          | invitation (wf15 §5.3): resealed from the|
// |   {accept}     |                                          | re-upserted invitation's task_revision   |
// |                |                                          | while it is pending and under the cap of |
// |                |                                          | 3 attempts, else dropped quietly; a      |
// |                |                                          | manual answer stays explicit             |
// | anything else  | (members_changed, task.update, sharing,  | explicit (R3)                            |
// |                | 404 ...)                                 |                                          |
//
// Every outcome emits `tasks.sync_issue` (`conflict_auto_resolved` / `conflict_manual`). Retry
// (§7.4): on a driver occasion a `stalled` entry (launch, foreground, network, link, session) and a
// `blocked_creation` one (launch, foreground, session — while the local create gate allows it, or
// for a migration create) return to the queue with the same identity, at most 5 times each.

extension SGTasksCloudRepository {
    static let maximumAutoResolutions = 2
    static let maximumAutoRequeues = 5

    private static let stalledRequeueReasons: Set<SGTasksDriveReason> = [.launch, .foreground, .network, .link, .session]
    private static let blockedRequeueReasons: Set<SGTasksDriveReason> = [.launch, .foreground, .session]

    // MARK: Marking (inside the answer's transaction)

    /// A 409 (`reason` is the exact wire reason): automatic when the R4 engine runs this cycle, the
    /// table has a row for it and the intent has been resolved automatically fewer than twice;
    /// otherwise explicit. Either way a cycle follows (its pull reveals the server row).
    func markConflict(_ entry: SGTasksCloudStoredEntry, mutation: SGTasksWire.SealedMutation, reason: SGTasksWire.ErrorReason, fields: [SGTasksWire.ContentField], serverTime: Date?, store: SGTasksCloudStore, events: inout [SGTasksAnalyticsEvent]) throws -> SendOutcome {
        let automatic = self.willResolveAutomatically(entry, mutation: mutation, reason: reason)
        try store.setConflict(seq: entry.seq, reason: reason, fields: fields, autoResolve: automatic, serverTime: serverTime)
        if !automatic {
            events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.conflictManual))
        }
        self.isCycleRequested = true
        return .continueDraining
    }

    /// On queue, during a cycle: the conflict will be resolved after the next complete pull (the R4
    /// engine runs this cycle, the table has a row for it, the intent was resolved fewer than twice).
    func willResolveAutomatically(_ entry: SGTasksCloudStoredEntry, mutation: SGTasksWire.SealedMutation, reason: SGTasksWire.ErrorReason) -> Bool {
        guard self.cycleIsR4, entry.autoResolutions < Self.maximumAutoResolutions else { return false }
        if Self.resolvesAutomatically(entry, mutation: mutation, reason: reason) {
            return true
        }
        // wf15 §5.3: the automatic accept of a contact's invitation (never a manual answer) is
        // resealed after `revision_changed` from the re-upserted invitation, up to its cap.
        if reason == .revisionChanged, entry.kind == .operation(.inviteRespond), let store = self.store, (try? self.isAutomaticAccept(entry, store: store)) == true {
            return true
        }
        return false
    }

    static func resolvesAutomatically(_ entry: SGTasksCloudStoredEntry, mutation: SGTasksWire.SealedMutation, reason: SGTasksWire.ErrorReason) -> Bool {
        switch mutation {
        case .patch:
            return reason == .fieldChanged
        case let .mutation(request):
            switch request.operation {
            case .taskComplete:
                return reason == .revisionChanged || reason == .invitationChanged
            case .taskDelete, .listDelete, .inviteRequest, .inviteRevoke:
                return reason == .revisionChanged
            case .listUpdate:
                return reason == .revisionChanged && entry.baseSnapshot.flatMap(SGTasksCloudListBase.init) != nil
            case .listCreate, .taskCreate, .taskUpdate, .inviteRespond, .senderBlock, .senderUnblock:
                return false
            }
        }
    }

    // MARK: Resolving (after a complete pull)

    private enum Resolution {
        /// The server already holds the intent (or the target is gone): the entry goes.
        case dropped
        /// Replaced in place by these entries (a new identity each).
        case replaced([Replacement])
        /// Stays a conflict for the user.
        case explicit
    }

    private struct Replacement {
        let mutation: SGTasksWire.SealedMutation
        let state: SGTasksCloudEntryState
        let conflict: (reason: SGTasksWire.ErrorReason, fields: [SGTasksWire.ContentField])?
        var baseSnapshot: Data? = nil
    }

    /// On queue, right after a complete pull of the R4 engine: every pending conflict is resolved
    /// against the fresh shadow, in outbox order, in one transaction.
    func resolvePendingConflictsAfterPull() {
        guard self.cycleIsR4, let store = self.store, self.isFenceCurrent else { return }
        var events: [SGTasksAnalyticsEvent] = []
        do {
            try store.transaction {
                for entry in try store.entries() where entry.state == .conflict && entry.isAutoResolvePending {
                    try self.resolve(entry, store: store, events: &events)
                }
            }
        } catch {
            if !store.isOpen { self.failStorage() }
            return
        }
        guard !events.isEmpty else { return }
        for event in events {
            self.emitAnalytics(event)
        }
        self.rebuildState()
        self.isCycleRequested = true
    }

    private func resolve(_ entry: SGTasksCloudStoredEntry, store: SGTasksCloudStore, events: inout [SGTasksAnalyticsEvent]) throws {
        let now = self.environment.now()
        guard let mutation = try? SGTasksWire.SealedMutation(wireJSON: entry.body), mutation.kind == entry.kind else {
            try store.clearAutoResolve(seq: entry.seq)
            events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.conflictManual))
            return
        }
        // wf15 §12.2: the automatic re-send of a deferred assignment keeps its marker through a
        // reseal (the new mutation id) and loses it when it is dropped.
        var resendKey: String?
        if case let .mutation(request) = mutation, case let .inviteRequest(op) = request.operation, try store.meta(Self.automaticResendKey(op.taskId)) == entry.mutationId {
            resendKey = Self.automaticResendKey(op.taskId)
        }
        // wf15 §5.3: the automatic accept's record follows a reseal (the new mutation id, one more
        // attempt) and marks the invitation given up on a drop (attempts at the cap).
        var acceptRecord: (key: String, attempts: Int)?
        if case let .mutation(request) = mutation, case let .inviteRespond(op) = request.operation, let record = try Self.automaticAcceptRecord(store, invitationId: op.invitationId), record.mutationId == entry.mutationId {
            acceptRecord = (Self.automaticAcceptKey(op.invitationId), record.attempts)
        }
        switch try self.resolution(entry, mutation: mutation, store: store) {
        case .dropped:
            try store.deleteEntry(seq: entry.seq)
            if let resendKey = resendKey {
                try store.setMeta(resendKey, nil)
            }
            if let acceptRecord = acceptRecord {
                try store.setMeta(acceptRecord.key, "\(entry.mutationId):\(max(acceptRecord.attempts, SGTasksAutoAcceptPolicy.maximumAttempts))")
            }
            if entry.kind == .operation(.taskDelete) {
                // A kept task is news to the user only when it is still there.
                if case let .mutation(request) = mutation, case let .taskDelete(op) = request.operation, try self.shadowTask(op.taskId, store: store) != nil {
                    try store.addResolutionNotice(.deleteKept, at: now)
                }
            }
            events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.conflictAutoResolved))
        case let .replaced(replacements):
            try store.deleteEntry(seq: entry.seq)
            for (index, replacement) in replacements.enumerated() {
                // The first keeps the entry's place in the outbox; a split's explicit part follows.
                try self.insertSealed(replacement.mutation, keys: entry.keys, sealed: true, store: store, state: replacement.state, seq: index == 0 ? entry.seq : nil, subject: entry.subject, isShared: entry.isShared, origin: entry.origin, autoResolutions: entry.autoResolutions + 1, baseSnapshot: replacement.baseSnapshot, conflict: replacement.conflict)
                if let conflict = replacement.conflict {
                    try store.addResolutionNotice(.changedElsewhere(fields: conflict.fields), at: now)
                    events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.conflictManual))
                } else {
                    events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.conflictAutoResolved))
                }
            }
            if let resendKey = resendKey, let first = replacements.first {
                try store.setMeta(resendKey, first.mutation.mutationId.rawValue)
            }
            if let acceptRecord = acceptRecord, let first = replacements.first {
                try store.setMeta(acceptRecord.key, "\(first.mutation.mutationId.rawValue):\(acceptRecord.attempts + 1)")
            }
        case .explicit:
            try store.clearAutoResolve(seq: entry.seq)
            if case .patch = mutation, !entry.conflictFields.isEmpty {
                try store.addResolutionNotice(.changedElsewhere(fields: entry.conflictFields), at: now)
            }
            events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.conflictManual))
        }
    }

    /// §7.3 against the fresh shadow. A replacement that the sealing rules refuse is no automatic
    /// resolution (the conflict stays explicit).
    private func resolution(_ entry: SGTasksCloudStoredEntry, mutation: SGTasksWire.SealedMutation, store: SGTasksCloudStore) throws -> Resolution {
        switch mutation {
        case let .patch(request):
            return try self.patchResolution(entry, patch: request.patch, store: store)
        case let .mutation(request):
            switch request.operation {
            case let .taskComplete(op):
                guard let task = try self.shadowTask(op.taskId, store: store) else { return .explicit }
                if task.isCompleted == op.isCompleted {
                    return .dropped
                }
                let invitationId: SGTasksWire.UUID?
                switch task.viewerRole {
                case .owner:
                    invitationId = Self.ownerCompletionInvitationId(task, serverNow: self.state.estimatedServerNow(localNow: self.environment.now()))
                case .assignee:
                    guard let assignment = task.assignment, assignment.state == .accepted else { return .explicit }
                    invitationId = assignment.invitationId
                }
                return Self.reseal(.taskComplete(SGTasksWire.TaskComplete(taskId: op.taskId, baseRevision: task.revision, invitationId: invitationId, isCompleted: op.isCompleted)))
            case .taskDelete:
                // Still there → the delete is dropped and the task kept; gone → the intent holds.
                return .dropped
            case let .listUpdate(op):
                guard let base = entry.baseSnapshot.flatMap(SGTasksCloudListBase.init), let list = try self.shadowList(op.listId, store: store) else { return .explicit }
                guard let title = Self.merge(base: base.title, mine: op.title, theirs: list.title),
                      let sortOrder = Self.merge(base: base.sortOrder, mine: op.sortOrder, theirs: list.sortOrder) else {
                    return .explicit
                }
                if title == list.title && sortOrder == list.sortOrder {
                    return .dropped
                }
                guard var replacement = Self.replacement(.listUpdate(SGTasksWire.ListUpdate(listId: op.listId, baseRevision: list.revision, title: title, sortOrder: sortOrder))) else { return .explicit }
                // The next merge starts from the row this one was made against.
                replacement.baseSnapshot = SGTasksCloudListBase(title: list.title, sortOrder: list.sortOrder).encoded
                return .replaced([replacement])
            case let .listDelete(op):
                guard let list = try self.shadowList(op.listId, store: store) else { return .dropped }
                // The rename elsewhere does not change the intent; the members fence it was decided
                // under stays, so a changed set of tasks still asks the user (`members_changed`).
                return Self.reseal(.listDelete(SGTasksWire.ListDelete(listId: op.listId, baseRevision: list.revision, baseMembersRevision: op.baseMembersRevision)))
            case let .inviteRequest(op):
                // wf15 §10: the owner still owns and the task is open → the pick is resealed on the
                // fresh revision as a new epoch (a new invitation id, as the explicit reapply does).
                // Otherwise the user's pick stays explicit, while the automatic re-send of a deferred
                // assignment ends quietly (§12.2).
                let automaticResend = try store.meta(Self.automaticResendKey(op.taskId)) == entry.mutationId
                guard let task = try self.shadowTask(op.taskId, store: store), task.viewerRole == .owner, !task.isCompleted else {
                    return automaticResend ? .dropped : .explicit
                }
                return Self.reseal(.inviteRequest(SGTasksWire.InviteRequest(taskId: op.taskId, baseRevision: task.revision, invitationId: SGTasksWire.UUID.generate(), recipientTgId: op.recipientTgId)))
            case let .inviteRevoke(op):
                // Resealed only while the same epoch is still the task's current assignment; a task
                // that is gone, or whose epoch ended or changed, already holds the intent.
                guard let task = try self.shadowTask(op.taskId, store: store), task.viewerRole == .owner, let assignment = task.assignment, assignment.invitationId == op.invitationId, assignment.state == .pending || assignment.state == .accepted else {
                    return .dropped
                }
                return Self.reseal(.inviteRevoke(SGTasksWire.InviteRevoke(taskId: op.taskId, baseRevision: task.revision, invitationId: op.invitationId)))
            case let .inviteRespond(op):
                // wf15 §5.3: only the automatic accept of a contact's invitation resolves by itself
                // (a manual answer stays explicit, as in R3). The server re-upserted the pending
                // invitation with the task's new revision (`TasksProjection.php:107-108`): resealed on
                // it while the invitation is still pending here, unexpired and under the cap;
                // otherwise the device gives up quietly (the invitation, if it is still pending, waits
                // in Takliflar) — never an Unsent Changes row.
                guard let record = try Self.automaticAcceptRecord(store, invitationId: op.invitationId), record.mutationId == entry.mutationId else { return .explicit }
                guard op.decision == .accept, record.attempts < SGTasksAutoAcceptPolicy.maximumAttempts,
                      let invitation = try self.shadowInvitation(op.invitationId, store: store), invitation.taskId == op.taskId else {
                    return .dropped
                }
                if let serverNow = self.state.estimatedServerNow(localNow: self.environment.now()), serverNow >= invitation.expiresAt.date {
                    return .dropped
                }
                return Self.reseal(.inviteRespond(SGTasksWire.InviteRespond(taskId: op.taskId, baseRevision: invitation.taskRevision, invitationId: op.invitationId, decision: .accept)))
            case .listCreate, .taskCreate, .taskUpdate, .senderBlock, .senderUnblock:
                return .explicit
            }
        }
    }

    /// `field_changed` F: a field outside F still holds an unrelated value → re-patched against the
    /// server's current value; a field of F that the server now holds as set is settled; the rest of
    /// F stays explicit, as a patch of its own with its original expectation.
    private func patchResolution(_ entry: SGTasksCloudStoredEntry, patch: SGTasksWire.TaskPatch, store: SGTasksCloudStore) throws -> Resolution {
        if Self.isAnnotationClear(patch) {
            // wf15 §4.1: the legacy annotation was rewritten elsewhere (or is already gone): the
            // clear is dropped quietly; the task stays a per-task candidate on whatever the server
            // holds. Nothing for the user to choose.
            return .dropped
        }
        guard let task = try self.shadowTask(patch.taskId, store: store), task.viewerRole == .owner else { return .explicit }
        let conflicting = Set(entry.conflictFields)
        var autoSet: [SGTasksWire.ContentField: SGTasksWire.FieldValue] = [:]
        var autoExpect: [SGTasksWire.ContentField: SGTasksWire.FieldValue] = [:]
        var keptSet: [SGTasksWire.ContentField: SGTasksWire.FieldValue] = [:]
        var keptExpect: [SGTasksWire.ContentField: SGTasksWire.FieldValue] = [:]
        for field in SGTasksWire.ContentField.allCases {
            guard let value = patch.set[field] else { continue }
            let current = SGTasksWire.FieldValue(field, of: task.content)
            if current == value {
                continue
            }
            if conflicting.contains(field) {
                keptSet[field] = value
                keptExpect[field] = patch.expect[field] ?? current
            } else {
                autoSet[field] = value
                autoExpect[field] = current
            }
        }
        if autoSet.isEmpty && keptSet.isEmpty {
            return .dropped
        }
        if autoSet.isEmpty {
            // Nothing left to send automatically: the conflict is the user's, as it is.
            return .explicit
        }
        var replacements: [Replacement] = []
        guard let automatic = try? Self.sealedPatch(mutationId: SGTasksWire.UUID.generate(), patch: SGTasksWire.TaskPatch(taskId: patch.taskId, set: autoSet, expect: autoExpect)) else { return .explicit }
        replacements.append(Replacement(mutation: .patch(automatic), state: .queued, conflict: nil))
        if !keptSet.isEmpty {
            guard let kept = try? Self.sealedPatch(mutationId: SGTasksWire.UUID.generate(), patch: SGTasksWire.TaskPatch(taskId: patch.taskId, set: keptSet, expect: keptExpect)) else { return .explicit }
            let fields = SGTasksWire.ContentField.allCases.filter { keptSet[$0] != nil }
            replacements.append(Replacement(mutation: .patch(kept), state: .conflict, conflict: (reason: .fieldChanged, fields: fields)))
        }
        return .replaced(replacements)
    }

    private static func replacement(_ operation: SGTasksWire.Operation) -> Replacement? {
        guard let sealed = try? Self.sealedRequest(mutationId: SGTasksWire.UUID.generate(), operation: operation) else { return nil }
        return Replacement(mutation: .mutation(sealed), state: .queued, conflict: nil)
    }

    private static func reseal(_ operation: SGTasksWire.Operation) -> Resolution {
        guard let replacement = Self.replacement(operation) else { return .explicit }
        return .replaced([replacement])
    }

    /// Three-way: an unchanged side takes the other's value; the same new value on both sides
    /// agrees; two different new values are a real conflict (nil).
    static func merge<T: Equatable>(base: T, mine: T, theirs: T) -> T? {
        if mine == base {
            return theirs
        }
        if theirs == base || theirs == mine {
            return mine
        }
        return nil
    }

    /// The owner's current live assignment epoch on the SERVER row (see the overlay version,
    /// `ownerCompletionInvitationId(_: SGTasksCloudTask, ...)`).
    static func ownerCompletionInvitationId(_ task: SGTasksWire.Task, serverNow: Date?) -> SGTasksWire.UUID? {
        guard let assignment = task.assignment else { return nil }
        switch assignment.state {
        case .accepted:
            return assignment.invitationId
        case .pending:
            if let serverNow = serverNow, serverNow >= assignment.expiresAt.date {
                return nil
            }
            return assignment.invitationId
        case .declined, .revoked, .left, .expired:
            return nil
        }
    }

    // MARK: Automatic requeue (§7.4)

    /// On queue (R4 engine). Same identity, attempts reset, at most `maximumAutoRequeues` times per
    /// entry; a consent fence never counts here (it never fails an entry).
    func autoRequeue(for reason: SGTasksDriveReason) {
        guard let store = self.store else { return }
        let requeueStalled = Self.stalledRequeueReasons.contains(reason)
        let requeueBlocked = Self.blockedRequeueReasons.contains(reason)
        guard requeueStalled || requeueBlocked else { return }
        var events: [SGTasksAnalyticsEvent] = []
        do {
            try store.transaction {
                var mayCreate: Bool?
                for entry in try store.entries() where entry.autoRequeues < Self.maximumAutoRequeues {
                    switch entry.state {
                    case .stalled where requeueStalled:
                        try store.autoRequeue(seq: entry.seq)
                        events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.stalled))
                    case .blockedCreation where requeueBlocked:
                        if mayCreate == nil {
                            mayCreate = self.environment.creationAllowed(self.accountPeerId)
                        }
                        guard mayCreate == true || entry.origin == .migration else { continue }
                        try store.autoRequeue(seq: entry.seq)
                        events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.blockedCreation))
                    default:
                        break
                    }
                }
            }
        } catch {
            if !store.isOpen { self.failStorage() }
            return
        }
        guard !events.isEmpty else { return }
        for event in events {
            self.emitAnalytics(event)
        }
        self.rebuildState()
    }
}
