import Foundation
import SGEntitlement

// MARK: - Visible board = server shadow + optimistic overlay
//
// Pure: no SQL, no clock, no network. The shadow is never modified here; unresolved outbox
// operations are replayed over a copy in sequence order. Conflict / not-found entries are NOT
// applied (the current server row stays visible with a problem marker), so a stale local change is
// never shown as if it were accepted.

struct SGTasksCloudDecodedEntry {
    let stored: SGTasksCloudStoredEntry
    /// An R3 operation or an R4 `task.patch`, exactly as sealed.
    let mutation: SGTasksWire.SealedMutation
}

enum SGTasksCloudOverlay {
    private struct ListRow {
        var id: SGTasksWire.UUID
        var title: String
        var sortOrder: Int32
        var revision: SGTasksWire.Revision?
        var createdAt: Date?
        var isPending = false
        var problem: SGTasksCloudProblem?
    }

    private struct TaskRow {
        var id: SGTasksWire.UUID
        var content: SGTasksWire.Content
        var isCompleted: Bool
        var completedAt: Date?
        var createdAt: Date?
        var viewerRole: SGTasksWire.ViewerRole
        var ownerTgId: SGTasksWire.TelegramId?
        var assignment: SGTasksCloudAssignment?
        var revision: SGTasksWire.Revision?
        var isPending = false
        var problem: SGTasksCloudProblem?
    }

    private struct InvitationRow {
        var invitation: SGTasksWire.Invitation
        var isResponsePending = false
    }

    struct Board {
        var lists: [SGTasksCloudList]
        var tasks: [SGTasksCloudTask]
        var invitations: [SGTasksCloudInvitation]
        var blocks: [SGTasksWire.Block]
        var entries: [SGTasksCloudEntry]
    }

    /// Operations whose effect is shown optimistically. Conflict / not-found / previous-account
    /// operations are excluded (the latter belong to a server account this board no longer shows).
    static func isApplied(_ state: SGTasksCloudEntryState) -> Bool {
        switch state {
        case .queued, .sending, .held, .acked, .blockedCreation, .invalid, .quarantined, .stalled:
            return true
        case .conflict, .notFound, .principalChanged:
            return false
        }
    }

    /// States that stop later operations sharing a resource key until the user resolves them.
    static func blocksDependents(_ state: SGTasksCloudEntryState) -> Bool {
        switch state {
        case .blockedCreation, .invalid, .quarantined, .conflict, .notFound, .stalled, .principalChanged:
            return true
        case .queued, .sending, .held, .acked:
            return false
        }
    }

    static func problem(for state: SGTasksCloudEntryState, reason: SGTasksWire.ConflictReason?) -> SGTasksCloudProblem? {
        switch state {
        case .blockedCreation: return .creationNotPermitted
        case .invalid: return .invalid
        case .quarantined: return .integrityQuarantine
        case .conflict: return .conflict(reason ?? .revisionChanged)
        case .notFound: return .notFound
        case .stalled: return .stalled
        case .principalChanged: return .accountChanged
        case .queued, .sending, .held, .acked: return nil
        }
    }

    static func build(shadow: [SGTasksWire.Projection], entries: [SGTasksCloudDecodedEntry], ownTelegramId: SGTasksWire.TelegramId?) -> Board {
        var lists: [String: ListRow] = [:]
        var tasks: [String: TaskRow] = [:]
        var invitations: [String: InvitationRow] = [:]
        var blocks: [String: SGTasksWire.Block] = [:]
        let index = ShadowIndex(shadow)

        for projection in shadow {
            switch projection {
            case let .list(list):
                lists[list.id.rawValue] = ListRow(id: list.id, title: list.title, sortOrder: list.sortOrder, revision: list.revision, createdAt: list.createdAt.date)
            case let .task(task):
                tasks[task.id.rawValue] = TaskRow(
                    id: task.id, content: task.content, isCompleted: task.isCompleted, completedAt: task.completedAt?.date,
                    createdAt: task.createdAt.date, viewerRole: task.viewerRole, ownerTgId: task.ownerTgId,
                    assignment: task.assignment.map { SGTasksCloudAssignment(invitationId: $0.invitationId, recipientTgId: $0.recipientTgId, state: $0.state, expiresAt: $0.expiresAt.date, isPending: false) },
                    revision: task.revision
                )
            case let .invitation(invitation):
                invitations[invitation.id.rawValue] = InvitationRow(invitation: invitation)
            case let .block(block):
                blocks[block.id.rawValue] = block
            }
        }

        var publicEntries: [SGTasksCloudEntry] = []
        var problemKeys: Set<String> = []

        for decoded in entries {
            let stored = decoded.stored
            let waiting = stored.state == .queued && !stored.keys.allSatisfy { !problemKeys.contains($0) }
            if blocksDependents(stored.state) || waiting {
                problemKeys.formUnion(stored.keys)
            }
            let problem: SGTasksCloudProblem? = waiting ? .waitingForDependency : Self.problem(for: stored.state, reason: stored.conflictReason)
            // Title is read before the operation applies (a delete removes the row it names).
            let displayTitle = Self.displayTitle(decoded.mutation, isShared: stored.isShared, tasks: tasks, lists: lists)
            // An acknowledged delete keeps applying until retired: an earlier acknowledged create of
            // the same row may still be applied above it (its row never reached the shadow).
            let isDelete = stored.kind == .operation(.taskDelete) || stored.kind == .operation(.listDelete)
            if isApplied(stored.state) && (isDelete || !Self.isCovered(stored, mutation: decoded.mutation, index: index)) {
                switch decoded.mutation {
                case let .mutation(request):
                    Self.apply(request.operation, entry: stored, ownTelegramId: ownTelegramId, lists: &lists, tasks: &tasks, invitations: &invitations, blocks: &blocks)
                case let .patch(request):
                    // R4: exactly the `set` fields land; every other field keeps its value.
                    if let content = tasks[request.patch.taskId.rawValue]?.content {
                        tasks[request.patch.taskId.rawValue]?.content = content.applying(request.patch.set)
                    }
                }
            }
            switch decoded.mutation {
            case let .mutation(request):
                Self.mark(request.operation, problem: problem, lists: &lists, tasks: &tasks, invitations: &invitations)
            case let .patch(request):
                if var row = tasks[request.patch.taskId.rawValue] {
                    row.isPending = true
                    row.problem = row.problem ?? problem
                    tasks[request.patch.taskId.rawValue] = row
                }
            }

            publicEntries.append(SGTasksCloudEntry(
                id: stored.seq,
                kind: stored.operationClass,
                resourceId: Self.resourceId(decoded.mutation),
                status: Self.status(stored, waiting: waiting),
                attempts: stored.attempts,
                nextAttemptAt: stored.nextAttemptAt,
                displayTitle: displayTitle,
                lastServerTime: stored.serverTime,
                mutationKind: stored.kind,
                conflictFields: stored.state == .conflict ? stored.conflictFields : [],
                isMembersConflict: stored.state == .conflict && stored.isMembersConflict
            ))
        }

        let visibleLists = lists.values.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.createdAt != rhs.createdAt { return (lhs.createdAt ?? .distantFuture) < (rhs.createdAt ?? .distantFuture) }
            return lhs.id.rawValue < rhs.id.rawValue
        }.map { SGTasksCloudList(id: $0.id, title: $0.title, sortOrder: $0.sortOrder, revision: $0.revision, createdAt: $0.createdAt, isPending: $0.isPending, problem: $0.problem) }

        let visibleTasks = tasks.values.sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            if lhs.content.sortOrder != rhs.content.sortOrder { return lhs.content.sortOrder < rhs.content.sortOrder }
            if lhs.createdAt != rhs.createdAt { return (lhs.createdAt ?? .distantFuture) < (rhs.createdAt ?? .distantFuture) }
            return lhs.id.rawValue < rhs.id.rawValue
        }.map { row in
            SGTasksCloudTask(
                id: row.id, listId: row.content.listId, title: row.content.title, description: row.content.description,
                dueAt: row.content.dueAt, priority: row.content.priority, sortOrder: row.content.sortOrder,
                annotation: row.viewerRole == .owner ? row.content.annotation : nil,
                isCompleted: row.isCompleted, completedAt: row.completedAt, createdAt: row.createdAt,
                viewerRole: row.viewerRole, ownerTgId: row.ownerTgId, assignment: row.assignment,
                revision: row.revision, isPending: row.isPending, problem: row.problem
            )
        }

        let visibleInvitations = invitations.values.sorted { $0.invitation.expiresAt.date < $1.invitation.expiresAt.date }.map { row in
            SGTasksCloudInvitation(id: row.invitation.id, taskId: row.invitation.taskId, ownerTgId: row.invitation.ownerTgId, title: row.invitation.title, dueAt: row.invitation.dueAt, expiresAt: row.invitation.expiresAt.date, isResponsePending: row.isResponsePending)
        }

        let visibleBlocks = blocks.values.sorted { $0.id.int64Value < $1.id.int64Value }

        return Board(lists: visibleLists, tasks: visibleTasks, invitations: visibleInvitations, blocks: visibleBlocks, entries: publicEntries)
    }

    /// What the server shadow currently proves, for acknowledgement coverage.
    struct ShadowIndex {
        var taskRevisions: [String: SGTasksWire.Revision] = [:]
        var listRevisions: [String: SGTasksWire.Revision] = [:]
        var blockIds: Set<String> = []
        /// Assignee tasks and their accepted invitation epoch.
        var acceptedInvitations: [String: String] = [:]

        init(_ shadow: [SGTasksWire.Projection]) {
            for projection in shadow {
                switch projection {
                case let .list(list):
                    self.listRevisions[list.id.rawValue] = list.revision
                case let .task(task):
                    self.taskRevisions[task.id.rawValue] = task.revision
                    if task.viewerRole == .assignee, let assignment = task.assignment, assignment.state == .accepted {
                        self.acceptedInvitations[task.id.rawValue] = assignment.invitationId.rawValue
                    }
                case .invitation:
                    break
                case let .block(block):
                    self.blockIds.insert(block.id.rawValue)
                }
            }
        }
    }

    /// `isCovered` for any sealed mutation: a `task.patch` is proven like a `task.update`, by its
    /// receipt revision (an `unchanged` receipt names the revision already stored).
    static func isCovered(_ entry: SGTasksCloudStoredEntry, mutation: SGTasksWire.SealedMutation, index: ShadowIndex) -> Bool {
        switch mutation {
        case let .mutation(request):
            return Self.isCovered(entry, operation: request.operation, index: index)
        case let .patch(request):
            guard entry.state == .acked else { return false }
            return Self.covered(index.taskRevisions[request.patch.taskId.rawValue], entry.ackRevision.flatMap(SGTasksWire.Revision.init))
        }
    }

    /// An acknowledged operation stays applied until the shadow PROVES its effect: the committed
    /// revision (or a later one) is present, or — for deletes — the row is gone. A missing row is
    /// not proof for other kinds (a coalesced row can move beyond a changes watermark and arrive
    /// next cycle); those acknowledgements retire only on an authoritative removal (a `remove` change
    /// or a complete snapshot that began after the acknowledgement), see the sync pass.
    static func isCovered(_ entry: SGTasksCloudStoredEntry, operation: SGTasksWire.Operation, index: ShadowIndex) -> Bool {
        guard entry.state == .acked else { return false }
        let ackRevision = entry.ackRevision.flatMap(SGTasksWire.Revision.init)
        switch operation {
        case let .listCreate(op):
            return index.listRevisions[op.listId.rawValue] != nil
        case let .listUpdate(op):
            return Self.covered(index.listRevisions[op.listId.rawValue], ackRevision)
        case let .listDelete(op):
            return index.listRevisions[op.listId.rawValue] == nil
        case let .taskCreate(op):
            return index.taskRevisions[op.taskId.rawValue] != nil
        case let .taskDelete(op):
            return index.taskRevisions[op.taskId.rawValue] == nil
        case let .taskUpdate(op):
            return Self.covered(index.taskRevisions[op.taskId.rawValue], ackRevision)
        case let .taskComplete(op):
            return Self.covered(index.taskRevisions[op.taskId.rawValue], ackRevision)
        case let .inviteRequest(op):
            return Self.covered(index.taskRevisions[op.taskId.rawValue], ackRevision)
        case let .inviteRevoke(op):
            return Self.covered(index.taskRevisions[op.taskId.rawValue], ackRevision)
        case let .inviteRespond(op):
            switch op.decision {
            case .accept:
                return index.acceptedInvitations[op.taskId.rawValue] == op.invitationId.rawValue
            case .decline, .leave:
                // Proven only by the removal of the invitation / shared task (sync pass).
                return false
            }
        case .senderBlock:
            return entry.subject.map { index.blockIds.contains($0) } ?? false
        case .senderUnblock:
            // A block row still present is not proof; its removal retires this (sync pass).
            return false
        }
    }

    private static func covered(_ current: SGTasksWire.Revision?, _ ack: SGTasksWire.Revision?) -> Bool {
        guard let current = current, let ack = ack else { return false }
        return current >= ack
    }

    private static func apply(_ operation: SGTasksWire.Operation, entry: SGTasksCloudStoredEntry, ownTelegramId: SGTasksWire.TelegramId?, lists: inout [String: ListRow], tasks: inout [String: TaskRow], invitations: inout [String: InvitationRow], blocks: inout [String: SGTasksWire.Block]) {
        switch operation {
        case let .listCreate(op):
            if lists[op.listId.rawValue] == nil {
                lists[op.listId.rawValue] = ListRow(id: op.listId, title: op.title, sortOrder: op.sortOrder, revision: nil, createdAt: op.createdAt?.date ?? entry.createdAt)
            }
        case let .listUpdate(op):
            lists[op.listId.rawValue]?.title = op.title
            lists[op.listId.rawValue]?.sortOrder = op.sortOrder
        case let .listDelete(op):
            lists[op.listId.rawValue] = nil
            for (id, task) in tasks where task.viewerRole == .owner && task.content.listId == op.listId {
                tasks[id] = nil
            }
        case let .taskCreate(op):
            if tasks[op.taskId.rawValue] == nil {
                tasks[op.taskId.rawValue] = TaskRow(
                    id: op.taskId, content: op.content, isCompleted: op.isCompleted, completedAt: op.completedAt?.date,
                    createdAt: op.createdAt?.date ?? entry.createdAt, viewerRole: .owner, ownerTgId: ownTelegramId,
                    assignment: nil, revision: nil
                )
            }
        case let .taskUpdate(op):
            tasks[op.taskId.rawValue]?.content = op.content
        case let .taskComplete(op):
            if var task = tasks[op.taskId.rawValue], task.isCompleted != op.isCompleted {
                task.isCompleted = op.isCompleted
                task.completedAt = op.isCompleted ? entry.createdAt : nil
                tasks[op.taskId.rawValue] = task
            }
        case let .taskDelete(op):
            tasks[op.taskId.rawValue] = nil
        case let .inviteRequest(op):
            tasks[op.taskId.rawValue]?.assignment = SGTasksCloudAssignment(invitationId: op.invitationId, recipientTgId: op.recipientTgId, state: .pending, expiresAt: nil, isPending: true)
        case let .inviteRevoke(op):
            if let assignment = tasks[op.taskId.rawValue]?.assignment, assignment.invitationId == op.invitationId {
                tasks[op.taskId.rawValue]?.assignment = SGTasksCloudAssignment(invitationId: assignment.invitationId, recipientTgId: assignment.recipientTgId, state: .revoked, expiresAt: assignment.expiresAt, isPending: true)
            }
        case let .inviteRespond(op):
            switch op.decision {
            case .accept, .decline:
                invitations[op.invitationId.rawValue]?.isResponsePending = true
            case .leave:
                tasks[op.taskId.rawValue] = nil
            }
        case let .senderBlock(op):
            let sender = entry.subject ?? invitations[op.invitationId.rawValue]?.invitation.ownerTgId.rawValue
            for (id, row) in invitations where row.invitation.ownerTgId.rawValue == sender || id == op.invitationId.rawValue {
                invitations[id] = nil
            }
            if let sender = sender, let senderId = SGTasksWire.TelegramId(sender), blocks[sender] == nil, let createdAt = SGTasksWire.Instant(date: entry.createdAt) {
                blocks[sender] = SGTasksWire.Block(id: senderId, createdAt: createdAt)
            }
        case let .senderUnblock(op):
            blocks[op.senderTgId.rawValue] = nil
        }
    }

    private static func mark(_ operation: SGTasksWire.Operation, problem: SGTasksCloudProblem?, lists: inout [String: ListRow], tasks: inout [String: TaskRow], invitations: inout [String: InvitationRow]) {
        func markList(_ id: SGTasksWire.UUID) {
            guard var row = lists[id.rawValue] else { return }
            row.isPending = true
            row.problem = row.problem ?? problem
            lists[id.rawValue] = row
        }
        func markTask(_ id: SGTasksWire.UUID) {
            guard var row = tasks[id.rawValue] else { return }
            row.isPending = true
            row.problem = row.problem ?? problem
            tasks[id.rawValue] = row
        }
        switch operation {
        case let .listCreate(op): markList(op.listId)
        case let .listUpdate(op): markList(op.listId)
        case let .listDelete(op): markList(op.listId)
        case let .taskCreate(op): markTask(op.taskId)
        case let .taskUpdate(op): markTask(op.taskId)
        case let .taskComplete(op): markTask(op.taskId)
        case let .taskDelete(op): markTask(op.taskId)
        case let .inviteRequest(op): markTask(op.taskId)
        case let .inviteRevoke(op): markTask(op.taskId)
        case let .inviteRespond(op):
            markTask(op.taskId)
            invitations[op.invitationId.rawValue]?.isResponsePending = true
        case .senderBlock, .senderUnblock:
            break
        }
    }

    private static func status(_ entry: SGTasksCloudStoredEntry, waiting: Bool) -> SGTasksCloudEntry.Status {
        switch entry.state {
        case .queued: return waiting ? .waitingForDependency : .queued
        case .sending: return .sending
        case .held: return .held
        case .acked: return .awaitingSync
        case .blockedCreation: return .creationNotPermitted
        case .invalid: return .invalid
        case .quarantined: return .integrityQuarantine
        case .conflict: return .conflict(entry.conflictReason ?? .revisionChanged)
        case .notFound: return .notFound
        case .stalled: return .stalled
        case .principalChanged: return .accountChanged
        }
    }

    static func resourceId(_ mutation: SGTasksWire.SealedMutation) -> String {
        switch mutation {
        case let .mutation(request):
            return Self.resourceId(request.operation)
        case let .patch(request):
            return request.patch.taskId.rawValue
        }
    }

    static func resourceId(_ operation: SGTasksWire.Operation) -> String {
        switch operation {
        case let .listCreate(op): return op.listId.rawValue
        case let .listUpdate(op): return op.listId.rawValue
        case let .listDelete(op): return op.listId.rawValue
        case let .taskCreate(op): return op.taskId.rawValue
        case let .taskUpdate(op): return op.taskId.rawValue
        case let .taskComplete(op): return op.taskId.rawValue
        case let .taskDelete(op): return op.taskId.rawValue
        case let .inviteRequest(op): return op.taskId.rawValue
        case let .inviteRespond(op): return op.taskId.rawValue
        case let .inviteRevoke(op): return op.taskId.rawValue
        case let .senderBlock(op): return op.invitationId.rawValue
        case let .senderUnblock(op): return op.senderTgId.rawValue
        }
    }

    private static func displayTitle(_ mutation: SGTasksWire.SealedMutation, isShared: Bool, tasks: [String: TaskRow], lists: [String: ListRow]) -> String? {
        switch mutation {
        case let .mutation(request):
            return Self.displayTitle(request.operation, isShared: isShared, tasks: tasks, lists: lists)
        case let .patch(request):
            guard !isShared else { return nil }
            if case let .title(title)? = request.patch.set[.title] {
                return title
            }
            return Self.ownTitle(request.patch.taskId, tasks)
        }
    }

    private static func displayTitle(_ operation: SGTasksWire.Operation, isShared: Bool, tasks: [String: TaskRow], lists: [String: ListRow]) -> String? {
        guard !isShared else { return nil }
        switch operation {
        case let .listCreate(op): return op.title
        case let .listUpdate(op): return op.title
        case let .listDelete(op): return lists[op.listId.rawValue]?.title
        case let .taskCreate(op): return op.content.title
        case let .taskUpdate(op): return op.content.title
        case let .taskComplete(op): return Self.ownTitle(op.taskId, tasks)
        case let .taskDelete(op): return Self.ownTitle(op.taskId, tasks)
        case let .inviteRequest(op): return Self.ownTitle(op.taskId, tasks)
        case let .inviteRevoke(op): return Self.ownTitle(op.taskId, tasks)
        case .inviteRespond, .senderBlock, .senderUnblock:
            return nil
        }
    }

    private static func ownTitle(_ id: SGTasksWire.UUID, _ tasks: [String: TaskRow]) -> String? {
        guard let row = tasks[id.rawValue], row.viewerRole == .owner else { return nil }
        return row.content.title
    }
}
