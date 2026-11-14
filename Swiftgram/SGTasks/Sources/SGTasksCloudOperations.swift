import Foundation
import SGEntitlement

// MARK: - Local mutations (projection + durable enqueue in one transaction) and explicit resolution

enum SGTasksCloudKey {
    static func task(_ id: SGTasksWire.UUID) -> String { return "task:\(id.rawValue)" }
    static func list(_ id: SGTasksWire.UUID) -> String { return "list:\(id.rawValue)" }
    static func invitation(_ id: SGTasksWire.UUID) -> String { return "invitation:\(id.rawValue)" }
    static func block(_ id: SGTasksWire.TelegramId) -> String { return "block:\(id.rawValue)" }
    static func block(raw: String) -> String { return "block:\(raw)" }

    /// The resource whose revision the operation's base_revision names (nil for no-CAS operations).
    static func base(of operation: SGTasksWire.Operation) -> String? {
        switch operation {
        case let .listUpdate(op): return Self.list(op.listId)
        case let .listDelete(op): return Self.list(op.listId)
        case let .taskUpdate(op): return Self.task(op.taskId)
        case let .taskComplete(op): return Self.task(op.taskId)
        case let .taskDelete(op): return Self.task(op.taskId)
        case let .inviteRequest(op): return Self.task(op.taskId)
        case let .inviteRespond(op): return Self.task(op.taskId)
        case let .inviteRevoke(op): return Self.task(op.taskId)
        case .listCreate, .taskCreate, .senderBlock, .senderUnblock: return nil
        }
    }

    /// The resource a receipt identifies.
    static func primary(of operation: SGTasksWire.Operation) -> String {
        switch operation {
        case let .listCreate(op): return Self.list(op.listId)
        case let .taskCreate(op): return Self.task(op.taskId)
        case let .senderBlock(op): return Self.invitation(op.invitationId)
        case let .senderUnblock(op): return Self.block(op.senderTgId)
        default: return Self.base(of: operation) ?? ""
        }
    }

    /// A `task.patch` names its task (it carries no base revision: `expect` fences it).
    static func primary(of mutation: SGTasksWire.SealedMutation) -> String {
        switch mutation {
        case let .mutation(request): return Self.primary(of: request.operation)
        case let .patch(request): return Self.task(request.patch.taskId)
        }
    }
}

extension SGTasksCloudRepository {
    /// Stands in for base_revision ONLY while an entry is unsealed (`sealed = 0`); such an entry is
    /// never sent. Sealing replaces it with the predecessor receipt / shadow revision.
    static let unsealedBaseRevision = SGTasksWire.Revision("1")!

    // MARK: Validation (existing native visible-scalar/limit rules, applied before sealing)

    static func validatedTitle(_ title: String, limit: Int) throws -> String {
        do {
            return try TodoStorage.validatedTitle(title, limit: limit)
        } catch {
            throw SGTasksCloudError.invalidTitle
        }
    }

    static let descriptionGraphemeLimit = 4096
    static let descriptionByteLimit = 16384

    static func validatedContent(_ draft: SGTasksCloudTaskDraft, sortOrder: Int32) throws -> SGTasksWire.Content {
        let title = try Self.validatedTitle(draft.title, limit: TodoStorage.taskTitleLimit)
        if let description = draft.description {
            guard description.count <= Self.descriptionGraphemeLimit, description.utf8.count <= Self.descriptionByteLimit else { throw SGTasksCloudError.invalidDescription }
        }
        if let dueAt = draft.dueAt, dueAt < 0 { throw SGTasksCloudError.invalidDueDate }
        guard (0 ... 4).contains(draft.priority) else { throw SGTasksCloudError.invalidPriority }
        var annotation: SGTasksWire.Annotation?
        if let draftAnnotation = draft.annotation {
            // Packed native ids are never sent; a non-user / unconvertible id needs explicit correction.
            guard let telegramId = SGTasksWire.TelegramId(cloudUserPeerId: draftAnnotation.cloudUserPeerId) else { throw SGTasksCloudError.annotationNotConvertible }
            let name: String
            do {
                name = try TodoStorage.validatedAssignee(peerId: telegramId.int64Value, displayName: draftAnnotation.displayName).displayName
            } catch {
                throw SGTasksCloudError.invalidAnnotation
            }
            annotation = SGTasksWire.Annotation(telegramUserId: telegramId, displayName: name)
        }
        return SGTasksWire.Content(listId: draft.listId, title: title, description: draft.description, dueAt: draft.dueAt, priority: draft.priority, sortOrder: sortOrder, annotation: annotation)
    }

    static func sealedRequest(mutationId: SGTasksWire.UUID, operation: SGTasksWire.Operation) throws -> SGTasksWire.MutationRequest {
        do {
            return try SGTasksWire.MutationRequest(mutationId: mutationId, operation: operation)
        } catch let error as SGTasksWire.ValidationError {
            if error.path.contains("description") { throw SGTasksCloudError.invalidDescription }
            if error.path.contains("annotation") { throw SGTasksCloudError.invalidAnnotation }
            if error.path.contains("title") { throw SGTasksCloudError.invalidTitle }
            if error.path.contains("due") { throw SGTasksCloudError.invalidDueDate }
            if error.path.contains("priority") { throw SGTasksCloudError.invalidPriority }
            throw SGTasksCloudError.actionNotAllowed
        }
    }

    static func sealedPatch(mutationId: SGTasksWire.UUID, patch: SGTasksWire.TaskPatch) throws -> SGTasksWire.PatchRequest {
        do {
            return try SGTasksWire.PatchRequest(mutationId: mutationId, patch: patch)
        } catch let error as SGTasksWire.ValidationError {
            if error.path.contains("description") { throw SGTasksCloudError.invalidDescription }
            if error.path.contains("annotation") { throw SGTasksCloudError.invalidAnnotation }
            if error.path.contains("title") { throw SGTasksCloudError.invalidTitle }
            if error.path.contains("due") { throw SGTasksCloudError.invalidDueDate }
            if error.path.contains("priority") { throw SGTasksCloudError.invalidPriority }
            throw SGTasksCloudError.actionNotAllowed
        }
    }

    /// R4 field-level edit: exactly the fields whose value differs, each expected to still hold the
    /// value the user saw. nil when nothing changed.
    static func patch(taskId: SGTasksWire.UUID, from shown: SGTasksWire.Content, to edited: SGTasksWire.Content) -> SGTasksWire.TaskPatch? {
        var set: [SGTasksWire.ContentField: SGTasksWire.FieldValue] = [:]
        var expect: [SGTasksWire.ContentField: SGTasksWire.FieldValue] = [:]
        for field in SGTasksWire.ContentField.allCases {
            let before = SGTasksWire.FieldValue(field, of: shown)
            let after = SGTasksWire.FieldValue(field, of: edited)
            if before != after {
                set[field] = after
                expect[field] = before
            }
        }
        return set.isEmpty ? nil : SGTasksWire.TaskPatch(taskId: taskId, set: set, expect: expect)
    }

    /// The owner content a visible task shows (the overlay's view of it).
    static func content(of task: SGTasksCloudTask) -> SGTasksWire.Content {
        return SGTasksWire.Content(listId: task.listId, title: task.title, description: task.description, dueAt: task.dueAt, priority: task.priority, sortOrder: task.sortOrder, annotation: task.annotation)
    }

    /// wf15 §4.1: a user edit never writes or clears the owner-only annotation. Whatever the draft
    /// carries (an editor captures its draft when it opens, and "Masʼulni olib tashlash" or a legacy
    /// send may have cleared the annotation since), the draft's own fields are validated and the
    /// content keeps `annotation` — the task's current one — so the annotation is equal on both
    /// sides of a patch and unchanged in a full-content update.
    static func editedContent(_ draft: SGTasksCloudTaskDraft, sortOrder: Int32, keeping annotation: SGTasksWire.Annotation?) throws -> SGTasksWire.Content {
        var plain = draft
        plain.annotation = nil
        let edited = try Self.validatedContent(plain, sortOrder: sortOrder)
        return SGTasksWire.Content(listId: edited.listId, title: edited.title, description: edited.description, dueAt: edited.dueAt, priority: edited.priority, sortOrder: edited.sortOrder, annotation: annotation)
    }

    /// The wire the server last proved for this account (the `server_wire` meta, numeric since wf15
    /// §8.3, written by `noteServerAnswer`): 0 when absent or not a positive number.
    static func serverWire(_ store: SGTasksCloudStore) throws -> Int {
        guard let raw = try store.meta("server_wire"), let wire = Int(raw), wire > 0 else {
            return 0
        }
        return wire
    }

    /// The server has spoken wire R4 or later (`x-wire-negotiation`): R4-only operations may be
    /// sealed. `>= 4`, not `== 4`: an echo of 5 keeps `task.patch`, the members fence and the
    /// migration batches working instead of dropping the client to R3 (wf15 F5).
    static func isServerWire4(_ store: SGTasksCloudStore) throws -> Bool {
        return try self.serverWire(store) >= SGTasksWire.wireRevision
    }

    /// The server has spoken wire 5: R5-only operations (`invitation.note`, wf15 §8.1) may be sealed.
    /// The UI offers them only while this holds; a wire-4 build never sees such an echo because the
    /// server echoes the request's value.
    static func isServerWire5(_ store: SGTasksCloudStore) throws -> Bool {
        return try self.serverWire(store) >= 5
    }

    /// Replaces base_revision (sealing an unsealed entry or re-basing an explicit user reapply).
    static func operation(_ operation: SGTasksWire.Operation, withBase revision: SGTasksWire.Revision) -> SGTasksWire.Operation {
        switch operation {
        case let .listUpdate(op): return .listUpdate(SGTasksWire.ListUpdate(listId: op.listId, baseRevision: revision, title: op.title, sortOrder: op.sortOrder))
        case let .listDelete(op): return .listDelete(SGTasksWire.ListDelete(listId: op.listId, baseRevision: revision, baseMembersRevision: op.baseMembersRevision))
        case let .taskUpdate(op): return .taskUpdate(SGTasksWire.TaskUpdate(taskId: op.taskId, baseRevision: revision, content: op.content))
        case let .taskComplete(op): return .taskComplete(SGTasksWire.TaskComplete(taskId: op.taskId, baseRevision: revision, invitationId: op.invitationId, isCompleted: op.isCompleted))
        case let .taskDelete(op): return .taskDelete(SGTasksWire.TaskDelete(taskId: op.taskId, baseRevision: revision))
        case let .inviteRequest(op): return .inviteRequest(SGTasksWire.InviteRequest(taskId: op.taskId, baseRevision: revision, invitationId: op.invitationId, recipientTgId: op.recipientTgId))
        case let .inviteRespond(op): return .inviteRespond(SGTasksWire.InviteRespond(taskId: op.taskId, baseRevision: revision, invitationId: op.invitationId, decision: op.decision))
        case let .inviteRevoke(op): return .inviteRevoke(SGTasksWire.InviteRevoke(taskId: op.taskId, baseRevision: revision, invitationId: op.invitationId))
        case .listCreate, .taskCreate, .senderBlock, .senderUnblock: return operation
        }
    }

    /// Base revision at enqueue: the server revision the user saw, sealed immediately — unless an
    /// earlier unresolved/unsynced operation shares the resource, in which case the entry stays
    /// unsealed until that predecessor's receipt (or the following sync) resolves it.
    func enqueueBase(store: SGTasksCloudStore, key: String, shadowRevision: SGTasksWire.Revision?) throws -> (revision: SGTasksWire.Revision, sealed: Bool) {
        if try store.entries().contains(where: { $0.keys.contains(key) }) {
            return (Self.unsealedBaseRevision, false)
        }
        guard let revision = shadowRevision else {
            throw key.hasPrefix("list:") ? SGTasksCloudError.listNotFound : SGTasksCloudError.taskNotFound
        }
        return (revision, true)
    }

    /// Every outbox insert (user edits, the explicit import, the migration step, automatic
    /// resolutions). Refused with `consentWithdrawn` while the account's consent is withdrawn, and
    /// when the caller captured a consent epoch (the migration step) that is no longer current.
    @discardableResult
    func insert(_ operation: SGTasksWire.Operation, keys: [String], sealed: Bool, store: SGTasksCloudStore, state: SGTasksCloudEntryState = .queued, mutationId: SGTasksWire.UUID = SGTasksWire.UUID.generate(), seq: Int64? = nil, holdToken: String? = nil, cancelsCreate: Bool = false, subject: String? = nil, isShared: Bool = false, origin: SGTasksWire.MutationOrigin = .user, autoResolutions: Int = 0, baseSnapshot: Data? = nil, expectedConsentEpoch: Int64? = nil) throws -> Int64 {
        let request = try Self.sealedRequest(mutationId: mutationId, operation: operation)
        return try self.insertSealed(.mutation(request), keys: keys, sealed: sealed, store: store, state: state, seq: seq, holdToken: holdToken, cancelsCreate: cancelsCreate, subject: subject, isShared: isShared, origin: origin, autoResolutions: autoResolutions, baseSnapshot: baseSnapshot, expectedConsentEpoch: expectedConsentEpoch)
    }

    /// An R4 `task.patch` (always sealed: it has no base revision to wait for).
    @discardableResult
    func insertPatch(_ patch: SGTasksWire.TaskPatch, keys: [String], store: SGTasksCloudStore, state: SGTasksCloudEntryState = .queued, mutationId: SGTasksWire.UUID = SGTasksWire.UUID.generate(), seq: Int64? = nil, autoResolutions: Int = 0, conflict: (reason: SGTasksWire.ErrorReason, fields: [SGTasksWire.ContentField])? = nil) throws -> Int64 {
        let request = try Self.sealedPatch(mutationId: mutationId, patch: patch)
        return try self.insertSealed(.patch(request), keys: keys, sealed: true, store: store, state: state, seq: seq, autoResolutions: autoResolutions, conflict: conflict)
    }

    @discardableResult
    func insertSealed(_ mutation: SGTasksWire.SealedMutation, keys: [String], sealed: Bool, store: SGTasksCloudStore, state: SGTasksCloudEntryState = .queued, seq: Int64? = nil, holdToken: String? = nil, cancelsCreate: Bool = false, subject: String? = nil, isShared: Bool = false, origin: SGTasksWire.MutationOrigin = .user, autoResolutions: Int = 0, baseSnapshot: Data? = nil, conflict: (reason: SGTasksWire.ErrorReason, fields: [SGTasksWire.ContentField])? = nil, expectedConsentEpoch: Int64? = nil) throws -> Int64 {
        guard !self.isConsentWithdrawn else { throw SGTasksCloudError.consentWithdrawn }
        if let expected = expectedConsentEpoch, try store.consentEpoch() != expected {
            throw SGTasksCloudError.consentWithdrawn
        }
        var unique: [String] = []
        for key in keys where !unique.contains(key) {
            unique.append(key)
        }
        return try store.insertEntry(seq: seq, mutationId: mutation.mutationId.rawValue, kind: mutation.kind, keys: unique, body: mutation.wireJSON, sealed: sealed, state: state, holdToken: holdToken, cancelsCreate: cancelsCreate, subject: subject, isShared: isShared, createdAt: self.environment.now(), origin: origin, autoResolutions: autoResolutions, baseSnapshot: baseSnapshot, conflict: conflict)
    }

    func emitAnalytics(_ event: SGTasksAnalyticsEvent) {
        SGTasksAnalytics.emit(event, accountPeerId: self.accountPeerId)
    }

    private static func ownedTask(_ id: SGTasksWire.UUID, in state: SGTasksCloudState) throws -> SGTasksCloudTask {
        guard let task = state.tasks.first(where: { $0.id == id }) else { throw SGTasksCloudError.taskNotFound }
        guard task.viewerRole == .owner else { throw SGTasksCloudError.notOwner }
        return task
    }

    private static func taskKeys(_ task: SGTasksCloudTask) -> [String] {
        return [SGTasksCloudKey.task(task.id)] + (task.listId.map { [SGTasksCloudKey.list($0)] } ?? [])
    }

    private static func nextSortOrder(_ values: [Int32]) throws -> Int32 {
        guard let maximum = values.max() else { return 0 }
        guard maximum < Int32.max else { throw SGTasksCloudError.invalidSortOrder }
        return maximum + 1
    }

    // MARK: Lists (owner)

    /// Caller has already passed the existing create entitlement gate; the server decides.
    @discardableResult
    public func createList(title: String) throws -> SGTasksWire.UUID {
        let title = try Self.validatedTitle(title, limit: TodoStorage.folderTitleLimit)
        let id: SGTasksWire.UUID = try self.mutate { store, state in
            let id = SGTasksWire.UUID.generate()
            let sortOrder = try Self.nextSortOrder(state.lists.map { $0.sortOrder })
            try self.insert(.listCreate(SGTasksWire.ListCreate(listId: id, title: title, sortOrder: sortOrder, createdAt: nil)), keys: [SGTasksCloudKey.list(id)], sealed: true, store: store)
            return id
        }
        self.emitAnalytics(.listCreated(cloud: true))
        return id
    }

    /// Rename/reorder. `expectedRevision` is the list revision the confirming dialog showed (nil
    /// for a not-yet-synced list); a different current revision is refused, never overwritten.
    public func updateList(id: SGTasksWire.UUID, title: String, sortOrder: Int32, expectedRevision: SGTasksWire.Revision?) throws {
        let title = try Self.validatedTitle(title, limit: TodoStorage.folderTitleLimit)
        try self.mutate { store, state in
            guard let list = state.lists.first(where: { $0.id == id }) else { throw SGTasksCloudError.listNotFound }
            guard list.revision == expectedRevision else { throw SGTasksCloudError.changedElsewhere }
            let key = SGTasksCloudKey.list(id)
            let base = try self.enqueueBase(store: store, key: key, shadowRevision: list.revision)
            // R4 three-way base (§7.3): what the user edited from, merged against a newer server row.
            let snapshot = SGTasksCloudListBase(title: list.title, sortOrder: list.sortOrder).encoded
            try self.insert(.listUpdate(SGTasksWire.ListUpdate(listId: id, baseRevision: base.revision, title: title, sortOrder: sortOrder)), keys: [key], sealed: base.sealed, store: store, baseSnapshot: snapshot)
        }
    }

    /// No Undo. A never-sent list (and its never-sent member creates) is cancelled locally; a list
    /// with other unresolved own operations must settle first (its CAS fences child changes).
    /// `expectedRevision` is the revision the confirmation showed.
    public func deleteList(id: SGTasksWire.UUID, expectedRevision: SGTasksWire.Revision?) throws {
        let memberCount: Int = try self.mutate { store, state in
            guard let list = state.lists.first(where: { $0.id == id }) else { throw SGTasksCloudError.listNotFound }
            guard list.revision == expectedRevision else { throw SGTasksCloudError.changedElsewhere }
            let members = state.tasks.filter { $0.viewerRole == .owner && $0.listId == id }.count
            let key = SGTasksCloudKey.list(id)
            let related = try store.entries().filter { $0.keys.contains(key) }
            if list.revision == nil {
                guard !related.isEmpty, related.allSatisfy({ !$0.sentOnce && $0.state != .acked }) else { throw SGTasksCloudError.listHasPendingChanges }
                for entry in related {
                    try store.deleteEntry(seq: entry.seq)
                }
                return members
            }
            guard related.isEmpty else { throw SGTasksCloudError.listHasPendingChanges }
            // R4: the members fence, from the settled shadow (only an R4 projection carries it).
            let membersBase = try Self.isServerWire4(store) ? try self.shadowList(id, store: store)?.membersRevision : nil
            try self.insert(.listDelete(SGTasksWire.ListDelete(listId: id, baseRevision: list.revision!, baseMembersRevision: membersBase)), keys: [key], sealed: true, store: store)
            return members
        }
        self.emitAnalytics(.listDeleted(cloud: true, tasks: memberCount))
    }

    func shadowList(_ id: SGTasksWire.UUID, store: SGTasksCloudStore) throws -> SGTasksWire.List? {
        guard let body = try store.row(.shadow, kind: "list", id: id.rawValue), case let .list(list)? = try? SGTasksWire.Projection(wireJSON: body) else { return nil }
        return list
    }

    func shadowTask(_ id: SGTasksWire.UUID, store: SGTasksCloudStore) throws -> SGTasksWire.Task? {
        guard let body = try store.row(.shadow, kind: "task", id: id.rawValue), case let .task(task)? = try? SGTasksWire.Projection(wireJSON: body) else { return nil }
        return task
    }

    // MARK: Tasks

    /// Caller has already passed the existing create entitlement gate. `listId == nil` is the
    /// virtual Cloud Inbox (never a hidden list create). wf15 §4.1: a create seals `annotation:
    /// null` whatever the draft carries — this client never writes the owner-only annotation; a
    /// Masʼul is an assignment (`createTask(_:assignee:)`).
    @discardableResult
    public func createTask(_ draft: SGTasksCloudTaskDraft) throws -> SGTasksWire.UUID {
        return try self.createTask(draft, assignee: nil)
    }

    /// Owner edit. `draft.sortOrder == nil` appends after the last task of the target list (pass
    /// the current sort order explicitly to keep the position).
    ///
    /// Once the server has spoken wire R4 this is a `task.patch`: only the changed fields, each
    /// expected to hold the value shown (the overlay, which already includes earlier unsent edits of
    /// the same task, ordered before it by the chain), no base revision, sealed at once — and no
    /// entry at all when nothing changed. Before that it is the R3 full-content `task.update`.
    /// Either way the draft's annotation is ignored (wf15 §4.1, `editedContent`): the task keeps the
    /// annotation it has now.
    public func updateTask(id: SGTasksWire.UUID, draft: SGTasksCloudTaskDraft) throws {
        try self.mutate { store, state in
            let task = try Self.ownedTask(id, in: state)
            if let listId = draft.listId, !state.lists.contains(where: { $0.id == listId }) { throw SGTasksCloudError.listNotFound }
            let siblings = state.tasks.filter { $0.viewerRole == .owner && $0.listId == draft.listId && $0.id != id }.map { $0.sortOrder }
            let content = try Self.editedContent(draft, sortOrder: try draft.sortOrder ?? Self.nextSortOrder(siblings), keeping: task.annotation)
            let key = SGTasksCloudKey.task(id)
            let keys = Self.taskKeys(task) + (draft.listId.map { [SGTasksCloudKey.list($0)] } ?? [])
            if try Self.isServerWire4(store) {
                guard let patch = Self.patch(taskId: id, from: Self.content(of: task), to: content) else { return }
                try self.insertPatch(patch, keys: keys, store: store)
                return
            }
            let base = try self.enqueueBase(store: store, key: key, shadowRevision: task.revision)
            try self.insert(.taskUpdate(SGTasksWire.TaskUpdate(taskId: id, baseRevision: base.revision, content: content)), keys: keys, sealed: base.sealed, store: store)
        }
    }

    /// Owner (complete/reopen) or the currently accepted assignee. Repeating the visible state is a no-op.
    public func setTaskCompleted(id: SGTasksWire.UUID, isCompleted: Bool) throws {
        let committed: Bool = try self.mutate { store, state in
            guard let task = state.tasks.first(where: { $0.id == id }) else { throw SGTasksCloudError.taskNotFound }
            guard task.isCompleted != isCompleted else { return false }
            let invitationId: SGTasksWire.UUID?
            switch task.viewerRole {
            case .owner:
                invitationId = Self.ownerCompletionInvitationId(task, serverNow: state.estimatedServerNow(localNow: self.environment.now()))
            case .assignee:
                guard let assignment = task.assignment, assignment.state == .accepted else { throw SGTasksCloudError.notAssignee }
                invitationId = assignment.invitationId
            }
            let key = SGTasksCloudKey.task(id)
            let base = try self.enqueueBase(store: store, key: key, shadowRevision: task.revision)
            try self.insert(.taskComplete(SGTasksWire.TaskComplete(taskId: id, baseRevision: base.revision, invitationId: invitationId, isCompleted: isCompleted)), keys: Self.taskKeys(task), sealed: base.sealed, store: store, isShared: task.viewerRole == .assignee)
            return true
        }
        if committed {
            self.emitAnalytics(.taskCompleted(cloud: true, reopened: !isCompleted))
        }
    }

    /// R3: the owner passes the CURRENT live assignment epoch, null for a personal task or no live
    /// assignment. Accepted is live (it never expires); pending is live until its immutable expiry
    /// by the estimated server clock. A locally queued share/revoke is ordered before this
    /// operation on the same task, so its epoch (or its absence) is the one current at send. The
    /// server stays authoritative: a wrong guess is an explicit 409 invitation_* conflict.
    static func ownerCompletionInvitationId(_ task: SGTasksCloudTask, serverNow: Date?) -> SGTasksWire.UUID? {
        guard let assignment = task.assignment else { return nil }
        switch assignment.state {
        case .accepted:
            return assignment.invitationId
        case .pending:
            return assignment.isExpired(serverTime: serverNow) ? nil : assignment.invitationId
        case .declined, .revoked, .left, .expired:
            return nil
        }
    }

    /// Owner delete: a durable HELD delete (never sent while held) plus its Undo handle. The held
    /// row seals the hold-time server base revision.
    public func deleteTask(id: SGTasksWire.UUID) throws -> SGTasksCloudUndoHandle {
        let token = UUID().uuidString.lowercased()
        let seq: Int64 = try self.mutate { store, state in
            let task = try Self.ownedTask(id, in: state)
            let key = SGTasksCloudKey.task(id)
            let chain = try store.entries().filter { $0.keys.contains(key) }
            let neverSent = task.revision == nil && !chain.isEmpty && chain.allSatisfy { !$0.sentOnce && $0.state != .acked }
            let base: (revision: SGTasksWire.Revision, sealed: Bool)
            if neverSent {
                base = (Self.unsealedBaseRevision, false)
            } else {
                base = try self.enqueueBase(store: store, key: key, shadowRevision: task.revision)
            }
            return try self.insert(.taskDelete(SGTasksWire.TaskDelete(taskId: id, baseRevision: base.revision)), keys: Self.taskKeys(task), sealed: base.sealed, store: store, state: .held, holdToken: token, cancelsCreate: neverSent)
        }
        self.onQueue {
            self.scheduleHoldTimer(seq: seq)
        }
        return SGTasksCloudUndoHandle(taskId: id, repository: self, seq: seq, token: token)
    }

    // MARK: Removing a Masʼul's epoch (explicit, user-confirmed; never inferred from annotations)

    /// Revokes exactly the assignment epoch the confirmation showed; a newer epoch is refused.
    public func revokeInvitation(taskId: SGTasksWire.UUID, expectedInvitationId: SGTasksWire.UUID) throws {
        try self.mutate { store, state in
            let task = try Self.ownedTask(taskId, in: state)
            guard let assignment = task.assignment, assignment.state == .pending || assignment.state == .accepted else { throw SGTasksCloudError.invitationNotFound }
            guard assignment.invitationId == expectedInvitationId else { throw SGTasksCloudError.changedElsewhere }
            let key = SGTasksCloudKey.task(taskId)
            let base = try self.enqueueBase(store: store, key: key, shadowRevision: task.revision)
            try self.insert(.inviteRevoke(SGTasksWire.InviteRevoke(taskId: taskId, baseRevision: base.revision, invitationId: assignment.invitationId)), keys: Self.taskKeys(task), sealed: base.sealed, store: store)
        }
        self.emitAnalytics(.shared(action: SGTasksAnalytics.Shared.revoked))
    }

    // MARK: Masʼul = assignment (wf15 §4, §12)
    //
    // Picking a Masʼul IS the `invitation.request`: the invitation is the assignment, there is no
    // separate share. The owner-only `annotation` is never written by this client — a create seals
    // `annotation: null` and no patch sets one; its only writes are two owner-field clears through
    // `task.patch set.annotation=null` ("Masʼulni olib tashlash" on a legacy annotation-only task,
    // `removeLegacyAnnotation`, and the chain after an `invitation.request` receipt,
    // `SGTasksCloudSync.settleAssignmentReceipt`). Pick-time refusals (self, non-user, a completed
    // task, the pacer) queue nothing. A long server rate limit on an `invitation.request` defers the
    // assignment out of the outbox (`assign_deferred.<taskId>`, §12.2); the first cycle whose start
    // is past `after` re-enqueues it through `enqueueAssignment(automatic: true)` — the same pick
    // retried, never charged to the pacer again, its mutation id in `assign_resend.<taskId>` so that
    // a refusal other than a rate limit ends it quietly (`SGTasksCloudSync`).

    static func deferredAssignmentKey(_ taskId: SGTasksWire.UUID) -> String {
        return SGTasksCloudStore.deferredAssignmentPrefix + taskId.rawValue
    }

    static func automaticResendKey(_ taskId: SGTasksWire.UUID) -> String {
        return SGTasksCloudStore.automaticResendPrefix + taskId.rawValue
    }

    /// Pick-time check before anything is queued (the composer pill and the editor row ask it the
    /// moment a contact is picked): a Telegram user other than the account itself, and one more
    /// manual pick within the pacer. Throws `recipientNotConvertible`, `selfAssignment` or
    /// `assignmentLimit(_:)`.
    public func checkAssignment(recipientCloudUserPeerId: Int64) throws {
        guard let recipient = SGTasksWire.TelegramId(cloudUserPeerId: recipientCloudUserPeerId) else { throw SGTasksCloudError.recipientNotConvertible }
        try self.onQueue {
            guard !self.isInvalidated else { throw SGTasksCloudError.accountRemoved }
            guard let store = self.store else { throw SGTasksCloudError.storageUnavailable }
            let state = self.state
            try Self.checkRecipient(recipient, state: state)
            let limit: SGTasksAssignmentLimit?
            do {
                limit = try self.pacerRefusal(recipient: recipient, store: store, state: state)
            } catch {
                if !store.isOpen { self.failStorage() }
                throw SGTasksCloudError.storageUnavailable
            }
            if let limit = limit {
                throw SGTasksCloudError.assignmentLimit(limit)
            }
        }
    }

    /// The Masʼul pick on an owned task (the editor row, "Masʼulni almashtirish"): the
    /// `invitation.request` to that contact, a new epoch. A live assignment is retired by the server
    /// when it lands (the UI confirms that first, §4.2 item 5). A never-synced task may be assigned:
    /// the request waits unsealed for the create's receipt (§4.2 item 8).
    public func assignTask(id: SGTasksWire.UUID, recipientCloudUserPeerId: Int64) throws {
        guard let recipient = SGTasksWire.TelegramId(cloudUserPeerId: recipientCloudUserPeerId) else { throw SGTasksCloudError.recipientNotConvertible }
        try self.assignTask(id: id, recipient: recipient)
    }

    /// The same pick with a raw Telegram user id (the legacy-assignee sheet converts a device row's
    /// packed id itself, §7.3) and an optional due time (its ten-per-minute spacing).
    public func assignTask(id: SGTasksWire.UUID, recipient: SGTasksWire.TelegramId, nextAttemptAt: Date? = nil) throws {
        try self.mutate { store, state in
            let task = try Self.ownedTask(id, in: state)
            try self.enqueueAssignment(task: task, recipient: recipient, store: store, state: state, automatic: false, nextAttemptAt: nextAttemptAt)
        }
        self.emitAnalytics(.shared(action: SGTasksAnalytics.Shared.inviteSent))
    }

    /// Qayta yuborish (§4.2 item 7): an ended assignment — declined, left, expired, or pending past
    /// its expiry by the estimated server clock — goes to the same recipient as a new epoch. A live
    /// or removed assignment is refused (`actionNotAllowed`: replace it, or pick again).
    public func resendAssignment(taskId: SGTasksWire.UUID) throws {
        try self.mutate { store, state in
            let task = try Self.ownedTask(taskId, in: state)
            guard let assignment = task.assignment else { throw SGTasksCloudError.invitationNotFound }
            let serverNow = state.estimatedServerNow(localNow: self.environment.now())
            switch assignment.state {
            case .declined, .left, .expired:
                break
            case .pending where assignment.isExpired(serverTime: serverNow):
                break
            case .pending, .accepted, .revoked:
                throw SGTasksCloudError.actionNotAllowed
            }
            try self.enqueueAssignment(task: task, recipient: assignment.recipientTgId, store: store, state: state, automatic: false, nextAttemptAt: nil)
        }
        self.emitAnalytics(.shared(action: SGTasksAnalytics.Shared.inviteSent))
    }

    /// The composer's "Qoʻshish" with a Masʼul (§4.2 item 4): one transaction enqueues the
    /// `task.create` (`annotation: null`; the caller passed the create gate) and the
    /// `invitation.request` on the same task key — unsealed until the create's receipt, then sealed
    /// with its revision (`enqueueBase`). A refused pick (self, non-user, pacer) queues nothing, the
    /// create included. A refused create (`blocked_creation`) keeps the invite waiting behind it;
    /// discarding the create discards the invite.
    @discardableResult
    public func createTask(_ draft: SGTasksCloudTaskDraft, assignee recipientCloudUserPeerId: Int64?) throws -> SGTasksWire.UUID {
        var recipient: SGTasksWire.TelegramId?
        if let packed = recipientCloudUserPeerId {
            guard let converted = SGTasksWire.TelegramId(cloudUserPeerId: packed) else { throw SGTasksCloudError.recipientNotConvertible }
            recipient = converted
        }
        let id: SGTasksWire.UUID = try self.mutate { store, state in
            if let listId = draft.listId, !state.lists.contains(where: { $0.id == listId }) { throw SGTasksCloudError.listNotFound }
            if let recipient = recipient {
                try Self.checkRecipient(recipient, state: state)
                if let limit = try self.pacerRefusal(recipient: recipient, store: store, state: state) {
                    throw SGTasksCloudError.assignmentLimit(limit)
                }
            }
            let siblings = state.tasks.filter { $0.viewerRole == .owner && $0.listId == draft.listId }.map { $0.sortOrder }
            var plain = draft
            plain.annotation = nil
            let content = try Self.validatedContent(plain, sortOrder: try draft.sortOrder ?? Self.nextSortOrder(siblings))
            let id = SGTasksWire.UUID.generate()
            let keys = [SGTasksCloudKey.task(id)] + (draft.listId.map { [SGTasksCloudKey.list($0)] } ?? [])
            try self.insert(.taskCreate(SGTasksWire.TaskCreate(taskId: id, content: content, createdAt: nil, isCompleted: false, completedAt: nil)), keys: keys, sealed: true, store: store)
            if let recipient = recipient {
                try self.insertAssignment(taskId: id, recipient: recipient, keys: keys, shadowRevision: nil, store: store, state: state, automatic: false, nextAttemptAt: nil)
            }
            return id
        }
        self.emitAnalytics(.taskCreated(cloud: true, hasDue: draft.dueAt != nil, priority: draft.priority, inList: draft.listId != nil))
        if recipient != nil {
            self.emitAnalytics(.shared(action: SGTasksAnalytics.Shared.inviteSent))
        }
        return id
    }

    /// "Masʼulni olib tashlash" on a legacy annotation-only task (§4.2 item 6): the one explicit
    /// annotation write of this client, the owner-field clear — a `task.patch` expecting the
    /// annotation shown (R4 server), the R3 full-content update without it before that. A task
    /// without an annotation is left alone.
    public func removeLegacyAnnotation(taskId: SGTasksWire.UUID) throws {
        try self.mutate { store, state in
            let task = try Self.ownedTask(taskId, in: state)
            guard let annotation = task.annotation else { return }
            let keys = Self.taskKeys(task)
            if try Self.isServerWire4(store) {
                try self.insertPatch(Self.annotationClearPatch(taskId: taskId, annotation: annotation), keys: keys, store: store)
                return
            }
            let shown = Self.content(of: task)
            let content = SGTasksWire.Content(listId: shown.listId, title: shown.title, description: shown.description, dueAt: shown.dueAt, priority: shown.priority, sortOrder: shown.sortOrder, annotation: nil)
            let base = try self.enqueueBase(store: store, key: SGTasksCloudKey.task(taskId), shadowRevision: task.revision)
            try self.insert(.taskUpdate(SGTasksWire.TaskUpdate(taskId: taskId, baseRevision: base.revision, content: content)), keys: keys, sealed: base.sealed, store: store)
        }
    }

    /// `task.patch {set: {annotation: null}, expect: {annotation: <shown>}}` (§4.1).
    static func annotationClearPatch(taskId: SGTasksWire.UUID, annotation: SGTasksWire.Annotation) -> SGTasksWire.TaskPatch {
        return SGTasksWire.TaskPatch(taskId: taskId, set: [.annotation: .annotation(nil)], expect: [.annotation: .annotation(annotation)])
    }

    /// The shape of that clear and nothing else: a `field_changed` on it is dropped quietly —
    /// another client of the account rewrote the annotation meanwhile, and the task stays a
    /// per-task legacy candidate on that other annotation (§4.1); nothing for Unsent Changes.
    static func isAnnotationClear(_ patch: SGTasksWire.TaskPatch) -> Bool {
        return patch.set == [.annotation: .annotation(nil)]
    }

    static func checkRecipient(_ recipient: SGTasksWire.TelegramId, state: SGTasksCloudState) throws {
        if let own = state.ownTelegramId, own == recipient { throw SGTasksCloudError.selfAssignment }
    }

    /// Owner tasks whose assignment is pending and unexpired on the visible board (the shadow plus
    /// the queued invites, whose expiry is not known yet).
    static func pendingAssignments(_ state: SGTasksCloudState, serverNow: Date?) -> Int {
        return state.tasks.filter { task in
            guard task.viewerRole == .owner, let assignment = task.assignment, assignment.state == .pending else { return false }
            return !assignment.isExpired(serverTime: serverNow)
        }.count
    }

    /// The pacer's clock: the local clock, read as UTC. The pacer is a conservative local pre-check
    /// (the server's own windows stay authoritative, in its own UTC days), so the estimated server
    /// time — which only moves with answers — is not needed here.
    private func pacerClock() -> Date {
        return self.environment.now()
    }

    /// The recipient's, the day's and the minute's counter keys, in that order.
    private func pacerCounterKeys(recipient: SGTasksWire.TelegramId, clock: Date) -> [String] {
        let day = SGTasksInvitationPacer.dayKey(clock)
        return [
            SGTasksInvitationPacer.recipientCounterKey(day: day, recipient: recipient),
            SGTasksInvitationPacer.dayCounterKey(day: day),
            SGTasksInvitationPacer.minuteCounterKey(minute: SGTasksInvitationPacer.minuteKey(clock))
        ]
    }

    /// Which limit one more manual pick to `recipient` would exceed now (nil: allowed), §12.1. A
    /// paced send (wf15 §7.3) is spaced by its due time, so its minute counter is not read.
    func pacerRefusal(recipient: SGTasksWire.TelegramId, store: SGTasksCloudStore, state: SGTasksCloudState, paced: Bool = false) throws -> SGTasksAssignmentLimit? {
        let counters = try self.pacerCounterKeys(recipient: recipient, clock: self.pacerClock()).map { Int(try store.integerMeta($0) ?? 0) }
        let pending = Self.pendingAssignments(state, serverNow: state.estimatedServerNow(localNow: self.environment.now()))
        return SGTasksInvitationPacer.refusal(SGTasksInvitationPacer.Counts(recipientToday: counters[0], today: counters[1], thisMinute: paced ? 0 : counters[2], pending: pending))
    }

    /// Charges one manual pick (at enqueue: a failed send still counts) and deletes the counters
    /// older than two UTC days.
    private func chargePacer(recipient: SGTasksWire.TelegramId, store: SGTasksCloudStore, state: SGTasksCloudState) throws {
        let clock = self.pacerClock()
        for key in self.pacerCounterKeys(recipient: recipient, clock: clock) {
            try store.setMeta(key, String((try store.integerMeta(key) ?? 0) + 1))
        }
        for prefix in [SGTasksInvitationPacer.dayPrefix, SGTasksInvitationPacer.minutePrefix] {
            for entry in try store.metaEntries(prefix: prefix) where SGTasksInvitationPacer.isExpired(counterKey: entry.key, now: clock) {
                try store.setMeta(entry.key, nil)
            }
        }
    }

    /// wf15 §7.3: the pacer's counters at this moment, for the legacy-assignee sheet's allowance
    /// (`SGTasksInvitationPacer.allowance`) and its spacing (`spacedDate`); nil when the store cannot
    /// be read (the sheet then sends nothing and says so through the enqueue's own refusals).
    public func invitationPacerSnapshot() -> SGTasksInvitationPacer.Snapshot? {
        return self.onQueue {
            guard !self.isInvalidated, let store = self.store else { return nil }
            let clock = self.pacerClock()
            let day = SGTasksInvitationPacer.dayKey(clock)
            do {
                let today = Int(try store.integerMeta(SGTasksInvitationPacer.dayCounterKey(day: day)) ?? 0)
                let thisMinute = Int(try store.integerMeta(SGTasksInvitationPacer.minuteCounterKey(minute: SGTasksInvitationPacer.minuteKey(clock))) ?? 0)
                let recipientPrefix = SGTasksInvitationPacer.dayCounterKey(day: day) + "."
                var recipientToday: [SGTasksWire.TelegramId: Int] = [:]
                for entry in try store.metaEntries(prefix: recipientPrefix) {
                    guard let recipient = SGTasksWire.TelegramId(String(entry.key.dropFirst(recipientPrefix.count))), let count = Int(entry.value) else { continue }
                    recipientToday[recipient] = count
                }
                let state = self.state
                let pending = Self.pendingAssignments(state, serverNow: state.estimatedServerNow(localNow: self.environment.now()))
                return SGTasksInvitationPacer.Snapshot(today: today, thisMinute: thisMinute, pending: pending, recipientToday: recipientToday)
            } catch {
                if !store.isOpen { self.failStorage() }
                return nil
            }
        }
    }

    /// Inside a transaction. The pick on an owned, visible task: a completed task is refused; a
    /// manual pick passes the self check and the pacer and is charged; the automatic re-send of a
    /// deferral (§12.2) is neither checked nor charged. A paced send (`nextAttemptAt` set: the
    /// legacy-assignee sheet, §7.3) is spaced ten per minute by its due time, so the per-minute
    /// refusal does not apply to it — the per-person, daily and pending limits still do.
    func enqueueAssignment(task: SGTasksCloudTask, recipient: SGTasksWire.TelegramId, store: SGTasksCloudStore, state: SGTasksCloudState, automatic: Bool, nextAttemptAt: Date?) throws {
        guard !task.isCompleted else { throw SGTasksCloudError.taskCompleted }
        if !automatic {
            try Self.checkRecipient(recipient, state: state)
            if let limit = try self.pacerRefusal(recipient: recipient, store: store, state: state, paced: nextAttemptAt != nil) {
                throw SGTasksCloudError.assignmentLimit(limit)
            }
        }
        try self.insertAssignment(taskId: task.id, recipient: recipient, keys: Self.taskKeys(task), shadowRevision: task.revision, store: store, state: state, automatic: automatic, nextAttemptAt: nextAttemptAt)
    }

    /// Inside a transaction, after the refusals: the `invitation.request` itself (a fresh epoch) on
    /// the task's keys — unsealed while the create or an earlier operation of the task is
    /// unresolved, else sealed on the shadow revision. A newer pick cancels the task's deferral and
    /// an automatic re-send that never left the device; an automatic re-send records its mutation id.
    private func insertAssignment(taskId: SGTasksWire.UUID, recipient: SGTasksWire.TelegramId, keys: [String], shadowRevision: SGTasksWire.Revision?, store: SGTasksCloudStore, state: SGTasksCloudState, automatic: Bool, nextAttemptAt: Date?) throws {
        let resendKey = Self.automaticResendKey(taskId)
        if !automatic, let resend = try store.meta(resendKey) {
            if let pending = try store.entries().first(where: { $0.mutationId == resend }) {
                // Never sent: the newer pick replaces it. Sent once (outcome unknown): it stays, and
                // its answer is handled as the automatic re-send it is.
                if !pending.sentOnce && pending.state != .acked {
                    try store.deleteEntry(seq: pending.seq)
                    try store.setMeta(resendKey, nil)
                }
            } else {
                try store.setMeta(resendKey, nil)
            }
        }
        try store.setMeta(Self.deferredAssignmentKey(taskId), nil)
        let base = try self.enqueueBase(store: store, key: SGTasksCloudKey.task(taskId), shadowRevision: shadowRevision)
        let mutationId = SGTasksWire.UUID.generate()
        let seq = try self.insert(.inviteRequest(SGTasksWire.InviteRequest(taskId: taskId, baseRevision: base.revision, invitationId: SGTasksWire.UUID.generate(), recipientTgId: recipient)), keys: keys, sealed: base.sealed, store: store, mutationId: mutationId)
        if let due = nextAttemptAt {
            try store.setState(seq: seq, .queued, nextAttemptAt: due)
        }
        if automatic {
            try store.setMeta(resendKey, mutationId.rawValue)
        } else {
            try self.chargePacer(recipient: recipient, store: store, state: state)
        }
    }

    // MARK: Deferred assignments (§12.2): the store's rows

    /// Every `assign_deferred.<taskId>` row, decoded; a row the decoder refuses is skipped here (and
    /// still counted by `unsentCounts`, never pretended away).
    static func deferredAssignments(_ store: SGTasksCloudStore) throws -> [SGTasksCloudDeferredAssignment] {
        let prefix = SGTasksCloudStore.deferredAssignmentPrefix
        return try store.metaEntries(prefix: prefix).compactMap { entry in
            guard let taskId = SGTasksWire.UUID(String(entry.key.dropFirst(prefix.count))),
                  let object = try? JSONSerialization.jsonObject(with: Data(entry.value.utf8)) as? [String: Any],
                  let to = object["to"] as? String, let recipient = SGTasksWire.TelegramId(to),
                  let after = (object["after"] as? NSNumber)?.doubleValue else {
                return nil
            }
            return SGTasksCloudDeferredAssignment(taskId: taskId, recipientTgId: recipient, after: Date(timeIntervalSince1970: after))
        }
    }

    /// `{"after":<unix seconds>,"to":"<recipientTgId>"}`.
    static func encodedDeferral(recipient: SGTasksWire.TelegramId, after: Date) -> String {
        let seconds = Int64(after.timeIntervalSince1970.rounded(.down))
        return "{\"after\":\(seconds),\"to\":\"\(recipient.rawValue)\"}"
    }

    func shadowInvitation(_ id: SGTasksWire.UUID, store: SGTasksCloudStore) throws -> SGTasksWire.Invitation? {
        guard let body = try store.row(.shadow, kind: "invitation", id: id.rawValue), case let .invitation(invitation)? = try? SGTasksWire.Projection(wireJSON: body) else { return nil }
        return invitation
    }

    private static func hasUnresolved(_ key: String, in store: SGTasksCloudStore, kind: SGTasksWire.OperationKind? = nil) throws -> Bool {
        return try store.entries().contains { !$0.isResolved && $0.keys.contains(key) && (kind == nil || $0.kind == .operation(kind!)) }
    }

    /// Accept or decline a visible pending invitation (CAS on the previewed task revision). An
    /// invitation expired by the estimated server clock, or with a queued answer, is refused; the
    /// server remains authoritative for expiry. A manual answer (the default) is recorded durably
    /// (wf15 §5.3: the invitation id; a decline also the task id, so no later epoch of the task is
    /// accepted automatically). `automatic: true` is the contact rule's own accept (`runAutoAccept`
    /// is the only caller): the same `invitation.respond {accept}` on the wire, the same analytics
    /// action, nothing recorded as a manual answer, and `auto_accept.<id>` bookkeeping instead.
    public func respondToInvitation(id: SGTasksWire.UUID, accept: Bool, automatic: Bool = false) throws {
        precondition(accept || !automatic, "an automatic answer is always an accept")
        try self.mutate { store, state in
            guard let invitation = try self.shadowInvitation(id, store: store) else { throw SGTasksCloudError.invitationNotFound }
            if let serverNow = state.estimatedServerNow(localNow: self.environment.now()), serverNow >= invitation.expiresAt.date {
                throw SGTasksCloudError.invitationExpired
            }
            guard try !Self.hasUnresolved(SGTasksCloudKey.invitation(id), in: store) else { throw SGTasksCloudError.alreadyPending }
            if automatic {
                let attempts = try Self.automaticAcceptRecord(store, invitationId: id)?.attempts ?? 0
                guard attempts < SGTasksAutoAcceptPolicy.maximumAttempts else { throw SGTasksCloudError.actionNotAllowed }
                try self.insertAutomaticAccept(invitation, attempts: attempts + 1, store: store)
            } else {
                let keys = [SGTasksCloudKey.task(invitation.taskId), SGTasksCloudKey.invitation(id)]
                try self.insert(.inviteRespond(SGTasksWire.InviteRespond(taskId: invitation.taskId, baseRevision: invitation.taskRevision, invitationId: id, decision: accept ? .accept : .decline)), keys: keys, sealed: true, store: store, isShared: true)
                self.recordManualAnswer(invitationId: id, refusedTaskId: accept ? nil : invitation.taskId)
            }
        }
        self.emitAnalytics(.shared(action: accept ? SGTasksAnalytics.Shared.inviteAccepted : SGTasksAnalytics.Shared.inviteDeclined))
    }

    /// Assignee Leave of exactly the assignment the confirmation showed; no hold, no Undo. Recorded
    /// durably as a manual refusal of the task (wf15 §5.3): a later epoch of it waits in Takliflar.
    public func leaveTask(id: SGTasksWire.UUID, expectedInvitationId: SGTasksWire.UUID) throws {
        try self.mutate { store, state in
            guard let task = state.tasks.first(where: { $0.id == id }) else { throw SGTasksCloudError.taskNotFound }
            guard task.viewerRole == .assignee, let assignment = task.assignment, assignment.state == .accepted else { throw SGTasksCloudError.notAssignee }
            guard assignment.invitationId == expectedInvitationId else { throw SGTasksCloudError.changedElsewhere }
            let key = SGTasksCloudKey.task(id)
            let base = try self.enqueueBase(store: store, key: key, shadowRevision: task.revision)
            try self.insert(.inviteRespond(SGTasksWire.InviteRespond(taskId: id, baseRevision: base.revision, invitationId: assignment.invitationId, decision: .leave)), keys: [key, SGTasksCloudKey.invitation(assignment.invitationId)], sealed: base.sealed, store: store, isShared: true)
            SGTasksInviteAnswersStore.recordRefusedTask(id, invitationId: assignment.invitationId, defaults: self.environment.defaults, accountPeerId: self.accountPeerId, now: self.environment.now())
        }
        self.emitAnalytics(.shared(action: SGTasksAnalytics.Shared.left))
    }

    /// wf15 §5.3: the durable record of a manual answer (`sgtasks.inviteAnswers.<accountPeerId>`).
    private func recordManualAnswer(invitationId: SGTasksWire.UUID, refusedTaskId: SGTasksWire.UUID?) {
        SGTasksInviteAnswersStore.recordInvitation(invitationId, refusedTaskId: refusedTaskId, defaults: self.environment.defaults, accountPeerId: self.accountPeerId, now: self.environment.now())
    }

    /// The manual answers recorded for this account, pruned.
    func manualInviteAnswers() -> SGTasksInviteAnswers {
        return SGTasksInviteAnswersStore.load(defaults: self.environment.defaults, accountPeerId: self.accountPeerId, now: self.environment.now())
    }

    // MARK: The automatic accept (wf15 §5.3, D2)
    //
    // The contact rule is the pure `SGTasksAutoAcceptPolicy`; this is its engine. The coordinator
    // hands in the device-local inputs (the contacts, the Telegram blocked list) through
    // `runAutoAccept`, which runs the policy over every pending invitation of the shadow; every pull
    // re-runs it with the last inputs (`performCycle`), so an invitation that arrives with a pull is
    // accepted — queued in the outbox — before the same cycle's drain. Bookkeeping is the store meta
    // `auto_accept.<invitationId>` = `"<mutationId>:<attempts>"`: `revision_changed` on the entry
    // reseals it from the re-upserted invitation's `task_revision` up to the cap of 3 attempts
    // (`SGTasksCloudAutoResolve`); every other refusal drops the entry quietly — no Unsent Changes
    // row, no `sharedAccessLost` notice, the user did nothing — with the attempts recorded at the
    // cap, so the invitation, if still pending, waits in Takliflar (`SGTasksCloudSync`).

    static func automaticAcceptKey(_ invitationId: SGTasksWire.UUID) -> String {
        return SGTasksCloudStore.automaticAcceptPrefix + invitationId.rawValue
    }

    /// The `auto_accept.<invitationId>` row, decoded; nil when absent or malformed.
    static func automaticAcceptRecord(_ store: SGTasksCloudStore, invitationId: SGTasksWire.UUID) throws -> (mutationId: String, attempts: Int)? {
        guard let raw = try store.meta(Self.automaticAcceptKey(invitationId)) else { return nil }
        return Self.decodeAutomaticAccept(raw)
    }

    static func decodeAutomaticAccept(_ raw: String) -> (mutationId: String, attempts: Int)? {
        guard let separator = raw.lastIndex(of: ":"), let attempts = Int(raw[raw.index(after: separator)...]), attempts >= 0 else { return nil }
        let mutationId = String(raw[..<separator])
        guard SGTasksWire.UUID(mutationId) != nil else { return nil }
        return (mutationId, attempts)
    }

    /// Every invitation's automatic attempts so far, by invitation id.
    static func automaticAcceptAttempts(_ store: SGTasksCloudStore) throws -> [SGTasksWire.UUID: Int] {
        let prefix = SGTasksCloudStore.automaticAcceptPrefix
        var out: [SGTasksWire.UUID: Int] = [:]
        for entry in try store.metaEntries(prefix: prefix) {
            guard let id = SGTasksWire.UUID(String(entry.key.dropFirst(prefix.count))), let record = Self.decodeAutomaticAccept(entry.value) else { continue }
            out[id] = record.attempts
        }
        return out
    }

    /// The invitations whose automatic accept is queued, in flight or acknowledged and still
    /// awaiting the server's proof (`SGTasksCloudState`: the provisional rows). An entry the pull
    /// retired (the task arrived as an assignee row, or the invitation left the snapshot) ends it.
    static func automaticAcceptInvitationIds(_ store: SGTasksCloudStore) throws -> Set<SGTasksWire.UUID> {
        let prefix = SGTasksCloudStore.automaticAcceptPrefix
        let records = try store.metaEntries(prefix: prefix)
        guard !records.isEmpty else { return [] }
        let open = Set(try store.entries().filter { $0.kind == .operation(.inviteRespond) }.map { $0.mutationId })
        var out = Set<SGTasksWire.UUID>()
        for entry in records {
            guard let id = SGTasksWire.UUID(String(entry.key.dropFirst(prefix.count))), let record = Self.decodeAutomaticAccept(entry.value), open.contains(record.mutationId) else { continue }
            out.insert(id)
        }
        return out
    }

    /// Inside a transaction: `auto_accept.*` rows that mean nothing any more go — an acknowledged
    /// accept whose entry the pull retired (the attempts below the cap and no entry left), and any
    /// row of an invitation that is no longer in the shadow. A row at the cap (given up) stays
    /// while its invitation is pending, so the policy never tries that invitation again.
    static func sweepAutomaticAccepts(_ store: SGTasksCloudStore, pendingInvitationIds: Set<SGTasksWire.UUID>) throws {
        let prefix = SGTasksCloudStore.automaticAcceptPrefix
        let records = try store.metaEntries(prefix: prefix)
        guard !records.isEmpty else { return }
        let open = Set(try store.entries().map { $0.mutationId })
        for entry in records {
            guard let id = SGTasksWire.UUID(String(entry.key.dropFirst(prefix.count))), let record = Self.decodeAutomaticAccept(entry.value) else {
                try store.setMeta(entry.key, nil)
                continue
            }
            if !pendingInvitationIds.contains(id) || (record.attempts < SGTasksAutoAcceptPolicy.maximumAttempts && !open.contains(record.mutationId)) {
                try store.setMeta(entry.key, nil)
            }
        }
    }

    /// The entry is the automatic accept of an invitation (`auto_accept.<id>` names its mutation id).
    func isAutomaticAccept(_ entry: SGTasksCloudStoredEntry, store: SGTasksCloudStore) throws -> Bool {
        guard entry.kind == .operation(.inviteRespond), let invitationId = Self.invitationId(of: entry) else { return false }
        return try Self.automaticAcceptRecord(store, invitationId: invitationId)?.mutationId == entry.mutationId
    }

    static func invitationId(of entry: SGTasksCloudStoredEntry) -> SGTasksWire.UUID? {
        guard let key = entry.keys.first(where: { $0.hasPrefix("invitation:") }) else { return nil }
        return SGTasksWire.UUID(String(key.dropFirst("invitation:".count)))
    }

    /// Inside a transaction: the automatic `invitation.respond {accept}` of a pending invitation,
    /// sealed on the invitation's `task_revision`, and its bookkeeping row.
    func insertAutomaticAccept(_ invitation: SGTasksWire.Invitation, attempts: Int, store: SGTasksCloudStore) throws {
        let keys = [SGTasksCloudKey.task(invitation.taskId), SGTasksCloudKey.invitation(invitation.id)]
        let mutationId = SGTasksWire.UUID.generate()
        try self.insert(.inviteRespond(SGTasksWire.InviteRespond(taskId: invitation.taskId, baseRevision: invitation.taskRevision, invitationId: invitation.id, decision: .accept)), keys: keys, sealed: true, store: store, mutationId: mutationId, isShared: true)
        try store.setMeta(Self.automaticAcceptKey(invitation.id), "\(mutationId.rawValue):\(attempts)")
    }

    /// Inside a transaction: the device gives up on this invitation's automatic accept (a definite
    /// refusal, or the cap): the entry goes quietly and the attempts are recorded at the cap, so the
    /// policy never tries again and the invitation, if still pending, waits in Takliflar.
    func dropAutomaticAccept(_ entry: SGTasksCloudStoredEntry, store: SGTasksCloudStore) throws {
        try store.deleteEntry(seq: entry.seq)
        if let invitationId = Self.invitationId(of: entry) {
            try self.recordAutomaticAcceptGivenUp(invitationId: invitationId, store: store)
        }
    }

    func recordAutomaticAcceptGivenUp(invitationId: SGTasksWire.UUID, store: SGTasksCloudStore) throws {
        guard let record = try Self.automaticAcceptRecord(store, invitationId: invitationId) else { return }
        try store.setMeta(Self.automaticAcceptKey(invitationId), "\(record.mutationId):\(max(record.attempts, SGTasksAutoAcceptPolicy.maximumAttempts))")
    }

    /// The coordinator's entry (any thread): the account's device-local inputs changed, or the
    /// account just became `allowed`, or a cycle ended. Runs the policy over every pending
    /// invitation now and keeps the inputs for the pulls that follow.
    public func runAutoAccept(_ inputs: SGTasksAutoAcceptInputs) {
        self.onQueue {
            self.autoAcceptInputs = inputs
            self.performAutoAccept(requestCycle: true)
        }
    }

    /// The coordinator tore the account's device-local sources down (the account stopped being
    /// `allowed` and driven, or its Telegram context was replaced): the inputs it handed in are
    /// stale from here on — the contact set, the blocked list and the senders' flags are re-read
    /// after a re-grant — so the policy does nothing until fresh, fail-closed inputs arrive.
    public func clearAutoAcceptInputs() {
        self.onQueue {
            self.autoAcceptInputs = nil
        }
    }

    /// On queue. Every pending invitation of the shadow the policy accepts gets its automatic
    /// `invitation.respond {accept}`; nothing else changes. `requestCycle` is false inside a cycle
    /// (the same cycle's drain sends what was queued).
    func performAutoAccept(requestCycle: Bool) {
        guard let inputs = self.autoAcceptInputs, !self.isInvalidated else { return }
        self.fenceIfPrincipalChanged()
        guard let store = self.store else { return }
        let state = self.state
        let now = self.environment.now()
        let permission: SGTasksSyncPermission = self.isConsentWithdrawn ? .forbidden : self.permission
        guard permission == .allowed else { return }
        var accepted = 0
        do {
            try store.transaction {
                var invitations: [SGTasksWire.Invitation] = []
                for row in try store.rows(.shadow) where row.kind == "invitation" {
                    if case let .invitation(invitation)? = try? SGTasksWire.Projection(wireJSON: row.body) {
                        invitations.append(invitation)
                    }
                }
                try Self.sweepAutomaticAccepts(store, pendingInvitationIds: Set(invitations.map { $0.id }))
                guard !invitations.isEmpty else { return }
                // An answer is open until the pull proves it: a queued or in-flight entry, and an
                // acknowledged one the shadow has not confirmed yet (the invitation may still be
                // shown in that gap; it must not be answered twice).
                let unresolvedKeys = Set(try store.entries().flatMap { $0.keys })
                let context = SGTasksAutoAcceptPolicy.Context(
                    permission: permission,
                    contactTgIds: inputs.contactTgIds,
                    ownTelegramId: state.ownTelegramId,
                    blockedSenderIds: Set(state.blocks.map { $0.id }),
                    telegramBlockedListLoaded: inputs.telegramBlockedListLoaded,
                    telegramBlockedIds: inputs.telegramBlockedIds,
                    telegramBlockCheckedSenderIds: inputs.telegramBlockCheckedSenderIds,
                    estimatedServerNow: state.estimatedServerNow(localNow: now),
                    hasUnresolvedEntry: { unresolvedKeys.contains($0) },
                    manualAnswers: self.manualInviteAnswers(),
                    automaticAttempts: try Self.automaticAcceptAttempts(store)
                )
                for invitation in invitations {
                    guard SGTasksAutoAcceptPolicy.decide(invitation, context: context) == .accept else { continue }
                    try self.insertAutomaticAccept(invitation, attempts: context.automaticAttempts[invitation.id, default: 0] + 1, store: store)
                    accepted += 1
                }
            }
        } catch {
            if !store.isOpen { self.failStorage() }
            return
        }
        guard accepted > 0 else { return }
        for _ in 0 ..< accepted {
            self.emitAnalytics(.shared(action: SGTasksAnalytics.Shared.inviteAccepted))
        }
        self.rebuildState()
        if requestCycle {
            self.requestCycle(explicit: false)
        }
    }

    /// Blocks the verified inviter of an invitation addressed to this account. Refused while an
    /// answer/block for that invitation or a block/unblock of that sender is queued.
    public func blockSender(invitationId: SGTasksWire.UUID) throws {
        try self.mutate { store, state in
            let sender: SGTasksWire.TelegramId
            if let invitation = try self.shadowInvitation(invitationId, store: store) {
                sender = invitation.ownerTgId
            } else if let task = state.tasks.first(where: { $0.viewerRole == .assignee && $0.assignment?.invitationId == invitationId }), let owner = task.ownerTgId {
                sender = owner
            } else {
                throw SGTasksCloudError.invitationNotFound
            }
            let invitationKey = SGTasksCloudKey.invitation(invitationId)
            let senderKey = SGTasksCloudKey.block(sender)
            guard try !Self.hasUnresolved(invitationKey, in: store), try !Self.hasUnresolved(senderKey, in: store) else { throw SGTasksCloudError.alreadyPending }
            try self.insert(.senderBlock(SGTasksWire.SenderBlock(invitationId: invitationId)), keys: [invitationKey, senderKey], sealed: true, store: store, subject: sender.rawValue, isShared: true)
            // wf15 §5.3: a manual answer; the block itself stays durable through the server's
            // `sender.block` (`blockedSenderIds`).
            self.recordManualAnswer(invitationId: invitationId, refusedTaskId: nil)
        }
        self.emitAnalytics(.shared(action: SGTasksAnalytics.Shared.blocked))
    }

    public func unblockSender(_ senderTgId: SGTasksWire.TelegramId) throws {
        try self.mutate { store, _ in
            let key = SGTasksCloudKey.block(senderTgId)
            guard try !Self.hasUnresolved(key, in: store, kind: .senderUnblock) else { throw SGTasksCloudError.alreadyPending }
            try self.insert(.senderUnblock(SGTasksWire.SenderUnblock(senderTgId: senderTgId)), keys: [key], sealed: true, store: store)
        }
    }

    // MARK: Read-only entry content (repair starts from the refused entry, not the overlay)

    /// The exact owner content sealed in a task.create / task.update entry. A private annotation
    /// whose raw Telegram id cannot be expressed as a packed CloudUser id is returned without it.
    public func entryTaskDraft(entryId: Int64) -> SGTasksCloudTaskDraft? {
        return self.onQueue {
            guard let store = self.store, let entry = try? store.entry(seq: entryId), let mutation = try? SGTasksWire.SealedMutation(wireJSON: entry.body) else { return nil }
            let content: SGTasksWire.Content
            switch mutation {
            case let .patch(request):
                // A patch carries only its fields: over the task as the server holds it.
                guard let task = try? self.shadowTask(request.patch.taskId, store: store) else { return nil }
                content = task.content.applying(request.patch.set)
            case let .mutation(request):
                switch request.operation {
                case let .taskCreate(op): content = op.content
                case let .taskUpdate(op): content = op.content
                default: return nil
                }
            }
            let annotation = content.annotation.flatMap { annotation in
                Self.cloudUserPeerId(annotation.telegramUserId).map { SGTasksCloudAnnotationDraft(cloudUserPeerId: $0, displayName: annotation.displayName) }
            }
            return SGTasksCloudTaskDraft(listId: content.listId, title: content.title, description: content.description, dueAt: content.dueAt, priority: content.priority, annotation: annotation, sortOrder: content.sortOrder)
        }
    }

    /// The exact title sealed in a list.create / list.update entry.
    public func entryListTitle(entryId: Int64) -> String? {
        return self.onQueue {
            guard let store = self.store, let entry = try? store.entry(seq: entryId), case let .mutation(request)? = try? SGTasksWire.SealedMutation(wireJSON: entry.body) else { return nil }
            switch request.operation {
            case let .listCreate(op): return op.title
            case let .listUpdate(op): return op.title
            default: return nil
            }
        }
    }

    /// Packed native id (CloudUser namespace 0) for a raw Telegram id, accepted only when the wire's
    /// own decoder maps it back to the same raw id.
    static func cloudUserPeerId(_ telegramId: SGTasksWire.TelegramId) -> Int64? {
        let raw = UInt64(telegramId.int64Value)
        let packed = ((raw >> 32) << 35) | (raw & 0xffff_ffff)
        guard packed <= UInt64(Int64.max), SGTasksWire.TelegramId(cloudUserPeerId: Int64(packed)) == telegramId else { return nil }
        return Int64(packed)
    }

    // MARK: Explicit resolution

    private func decodedEntry(_ entryId: Int64, store: SGTasksCloudStore) throws -> (SGTasksCloudStoredEntry, SGTasksWire.SealedMutation) {
        guard let entry = try store.entry(seq: entryId) else { throw SGTasksCloudError.entryNotFound }
        guard let mutation = try? SGTasksWire.SealedMutation(wireJSON: entry.body) else {
            // Only discard is possible for undecodable (quarantined) rows.
            throw SGTasksCloudError.actionNotAllowed
        }
        return (entry, mutation)
    }

    /// The R3 operation of a decoded entry; `actionNotAllowed` for a patch where only R3 applies.
    private static func r3Operation(_ mutation: SGTasksWire.SealedMutation) throws -> SGTasksWire.Operation {
        guard case let .mutation(request) = mutation else { throw SGTasksCloudError.actionNotAllowed }
        return request.operation
    }

    /// 403 creation refusal or stalled automatic retry: resend the SAME sealed identity.
    public func retry(entryId: Int64) throws {
        try self.mutate { store, _ in
            guard let entry = try store.entry(seq: entryId) else { throw SGTasksCloudError.entryNotFound }
            guard entry.state == .blockedCreation || entry.state == .stalled else { throw SGTasksCloudError.actionNotAllowed }
            try store.setState(seq: entryId, .queued, attempts: 0, nextAttemptAt: nil)
        }
        self.refresh()
    }

    /// Drops an unresolved entry. Never-sent operations based on it go with it when it never left
    /// the device or was definitely refused; after a send with an uncertain outcome it may be
    /// committed, so later edits stay and re-seal against the server state (an explicit conflict
    /// if it moved).
    public func discard(entryId: Int64) throws {
        try self.mutate { store, _ in
            guard let entry = try store.entry(seq: entryId) else { throw SGTasksCloudError.entryNotFound }
            guard entry.state != .acked, entry.state != .sending, entry.state != .held else { throw SGTasksCloudError.actionNotAllowed }
            let mutation = try? SGTasksWire.SealedMutation(wireJSON: entry.body)
            try store.deleteEntry(seq: entryId)
            // Uncertain = handed to the network without a definite answer (it may be committed).
            let outcomeUncertain = entry.sentOnce && (entry.state == .queued || entry.state == .stalled)
            guard let mutation = mutation, !outcomeUncertain else { return }
            let primary = SGTasksCloudKey.primary(of: mutation)
            let isCreate = mutation.kind.isCreation
            for later in try store.entries() where later.seq > entryId && !later.sentOnce && later.state != .acked && later.keys.contains(primary) {
                if !later.sealed || isCreate {
                    try store.deleteEntry(seq: later.seq)
                }
            }
        }
    }

    /// 409 conflict: explicit user choice to apply the same intent on the CURRENT server revision,
    /// as a new mutation id (and a new invitation epoch for a share). Never automatic.
    ///
    /// R4: a `task.patch` is reapplied as the same `set` expected against the server's current
    /// values ("keep mine"); a members-fenced list delete is resealed with the current members
    /// revision (the user confirmed the current task count).
    public func reapplyOnCurrentVersion(entryId: Int64) throws {
        try self.mutate { store, state in
            let (entry, mutation) = try self.decodedEntry(entryId, store: store)
            guard entry.state == .conflict else { throw SGTasksCloudError.actionNotAllowed }
            if case let .patch(request) = mutation {
                let key = SGTasksCloudKey.task(request.patch.taskId)
                guard try !store.entries().contains(where: { $0.seq < entryId && $0.keys.contains(key) && !$0.isResolved }) else { throw SGTasksCloudError.actionNotAllowed }
                guard let current = try self.shadowTask(request.patch.taskId, store: store) else { throw SGTasksCloudError.taskNotFound }
                var expect: [SGTasksWire.ContentField: SGTasksWire.FieldValue] = [:]
                for field in request.patch.set.keys {
                    expect[field] = SGTasksWire.FieldValue(field, of: current.content)
                }
                try store.deleteEntry(seq: entryId)
                try self.insertPatch(SGTasksWire.TaskPatch(taskId: request.patch.taskId, set: request.patch.set, expect: expect), keys: entry.keys, store: store, seq: entryId)
                return
            }
            let original = try Self.r3Operation(mutation)
            guard let key = SGTasksCloudKey.base(of: original) else { throw SGTasksCloudError.actionNotAllowed }
            guard try !store.entries().contains(where: { $0.seq < entryId && $0.keys.contains(key) && !$0.isResolved }) else { throw SGTasksCloudError.actionNotAllowed }
            let current: SGTasksWire.Revision?
            if key.hasPrefix("list:") {
                current = state.lists.first(where: { SGTasksCloudKey.list($0.id) == key })?.revision
            } else {
                current = state.tasks.first(where: { SGTasksCloudKey.task($0.id) == key })?.revision
            }
            guard let revision = current else { throw key.hasPrefix("list:") ? SGTasksCloudError.listNotFound : SGTasksCloudError.taskNotFound }
            var operation = Self.operation(original, withBase: revision)
            switch operation {
            case .inviteRespond, .inviteRevoke:
                throw SGTasksCloudError.actionNotAllowed
            case let .inviteRequest(op):
                // A completed task cannot be shared; only discard resolves that conflict.
                if entry.conflictReason == .completedTask { throw SGTasksCloudError.actionNotAllowed }
                operation = .inviteRequest(SGTasksWire.InviteRequest(taskId: op.taskId, baseRevision: revision, invitationId: SGTasksWire.UUID.generate(), recipientTgId: op.recipientTgId))
            case let .taskComplete(op):
                // The epoch is re-read from the current task, never the stale one that conflicted.
                guard let task = state.tasks.first(where: { $0.id == op.taskId }) else { throw SGTasksCloudError.taskNotFound }
                let invitationId: SGTasksWire.UUID?
                switch task.viewerRole {
                case .owner:
                    invitationId = Self.ownerCompletionInvitationId(task, serverNow: state.estimatedServerNow(localNow: self.environment.now()))
                case .assignee:
                    guard let assignment = task.assignment, assignment.state == .accepted else { throw SGTasksCloudError.notAssignee }
                    invitationId = assignment.invitationId
                }
                operation = .taskComplete(SGTasksWire.TaskComplete(taskId: op.taskId, baseRevision: revision, invitationId: invitationId, isCompleted: op.isCompleted))
            case let .listDelete(op) where op.baseMembersRevision != nil:
                // The user confirmed the delete of the list as it is now: the members fence moves
                // to its current members revision (none once the server no longer speaks R4).
                let members = try Self.isServerWire4(store) ? try self.shadowList(op.listId, store: store)?.membersRevision : nil
                operation = .listDelete(SGTasksWire.ListDelete(listId: op.listId, baseRevision: revision, baseMembersRevision: members))
            default:
                break
            }
            try store.deleteEntry(seq: entryId)
            try self.insert(operation, keys: entry.keys, sealed: true, store: store, seq: entryId, subject: entry.subject, isShared: entry.isShared, origin: entry.origin)
        }
    }

    /// 404 on the user's own resource: an explicit NEW gated create (caller gates) with a new id.
    /// The copy keeps its list when that list still exists, otherwise lands in the Cloud Inbox.
    @discardableResult
    public func recreateAsNewCopy(entryId: Int64) throws -> SGTasksWire.UUID {
        return try self.mutate { store, state in
            let (entry, mutation) = try self.decodedEntry(entryId, store: store)
            // 404 on an own resource, or a draft decided for a previous server account: the copy is
            // a brand-new create under the current account (new task id and mutation id).
            guard entry.state == .notFound || entry.state == .principalChanged else { throw SGTasksCloudError.actionNotAllowed }
            let content: SGTasksWire.Content
            switch mutation {
            case let .patch(request):
                // A patch alone is not a task: only over a server row still known here.
                guard let task = try self.shadowTask(request.patch.taskId, store: store) else { throw SGTasksCloudError.actionNotAllowed }
                content = task.content.applying(request.patch.set)
            case let .mutation(request):
                switch request.operation {
                case let .taskCreate(op): content = op.content
                case let .taskUpdate(op): content = op.content
                default: throw SGTasksCloudError.actionNotAllowed
                }
            }
            let listId = content.listId.flatMap { id in state.lists.contains(where: { $0.id == id }) ? id : nil }
            let copy = SGTasksWire.Content(listId: listId, title: content.title, description: content.description, dueAt: content.dueAt, priority: content.priority, sortOrder: content.sortOrder, annotation: content.annotation)
            let id = SGTasksWire.UUID.generate()
            try store.deleteEntry(seq: entryId)
            let keys = [SGTasksCloudKey.task(id)] + (listId.map { [SGTasksCloudKey.list($0)] } ?? [])
            try self.insert(.taskCreate(SGTasksWire.TaskCreate(taskId: id, content: copy, createdAt: nil, isCompleted: false, completedAt: nil)), keys: keys, sealed: true, store: store)
            return id
        }
    }

    /// 422 invalid task create/update: the user's corrected content as a NEW sealed mutation id.
    /// The annotation is never the draft's (wf15 §4.1): a patch keeps the server row's, a create or
    /// full update the refused operation's own.
    public func repair(entryId: Int64, taskDraft: SGTasksCloudTaskDraft) throws {
        try self.mutate { store, state in
            let (entry, mutation) = try self.decodedEntry(entryId, store: store)
            guard entry.state == .invalid else { throw SGTasksCloudError.actionNotAllowed }
            if let listId = taskDraft.listId, !state.lists.contains(where: { $0.id == listId }) { throw SGTasksCloudError.listNotFound }
            // Later full-content edits of the same task still carry the refused content; they must
            // be discarded (or settle) first, so the repair is neither overwritten nor re-refused.
            let taskKey = SGTasksCloudKey.primary(of: mutation)
            guard try !store.entries().contains(where: { $0.seq > entryId && $0.operationClass == .taskUpdate && !$0.isResolved && $0.keys.contains(taskKey) }) else { throw SGTasksCloudError.laterChangesPending }
            if case let .patch(request) = mutation {
                // The corrected content against the server row: a new patch (R4) or a full update.
                guard let task = try self.shadowTask(request.patch.taskId, store: store) else { throw SGTasksCloudError.taskNotFound }
                let content = try Self.editedContent(taskDraft, sortOrder: taskDraft.sortOrder ?? task.content.sortOrder, keeping: task.content.annotation)
                let keys = entry.keys + (taskDraft.listId.map { [SGTasksCloudKey.list($0)] } ?? [])
                try store.deleteEntry(seq: entryId)
                if try Self.isServerWire4(store) {
                    if let patch = Self.patch(taskId: task.id, from: task.content, to: content) {
                        try self.insertPatch(patch, keys: keys, store: store, seq: entryId)
                    }
                } else {
                    try self.insert(.taskUpdate(SGTasksWire.TaskUpdate(taskId: task.id, baseRevision: task.revision, content: content)), keys: keys, sealed: true, store: store, seq: entryId)
                }
                return
            }
            let operation: SGTasksWire.Operation
            switch try Self.r3Operation(mutation) {
            case let .taskCreate(op):
                let content = try Self.editedContent(taskDraft, sortOrder: taskDraft.sortOrder ?? op.content.sortOrder, keeping: op.content.annotation)
                operation = .taskCreate(SGTasksWire.TaskCreate(taskId: op.taskId, content: content, createdAt: op.createdAt, isCompleted: op.isCompleted, completedAt: op.completedAt))
            case let .taskUpdate(op):
                let content = try Self.editedContent(taskDraft, sortOrder: taskDraft.sortOrder ?? op.content.sortOrder, keeping: op.content.annotation)
                operation = .taskUpdate(SGTasksWire.TaskUpdate(taskId: op.taskId, baseRevision: op.baseRevision, content: content))
            default:
                throw SGTasksCloudError.actionNotAllowed
            }
            // A create only touches its (new) list; an update also keeps the task's current list.
            let newListKeys = taskDraft.listId.map { [SGTasksCloudKey.list($0)] } ?? []
            let keys = operation.kind == .taskCreate ? entry.keys.filter { !$0.hasPrefix("list:") } + newListKeys : entry.keys + newListKeys
            try store.deleteEntry(seq: entryId)
            try self.insert(operation, keys: keys, sealed: entry.sealed, store: store, seq: entryId, origin: entry.origin)
        }
    }

    /// 422 invalid list create/update: corrected title as a NEW sealed mutation id.
    public func repair(entryId: Int64, listTitle: String) throws {
        let title = try Self.validatedTitle(listTitle, limit: TodoStorage.folderTitleLimit)
        try self.mutate { store, _ in
            let (entry, mutation) = try self.decodedEntry(entryId, store: store)
            guard entry.state == .invalid else { throw SGTasksCloudError.actionNotAllowed }
            let operation: SGTasksWire.Operation
            switch try Self.r3Operation(mutation) {
            case let .listCreate(op):
                operation = .listCreate(SGTasksWire.ListCreate(listId: op.listId, title: title, sortOrder: op.sortOrder, createdAt: op.createdAt))
            case let .listUpdate(op):
                operation = .listUpdate(SGTasksWire.ListUpdate(listId: op.listId, baseRevision: op.baseRevision, title: title, sortOrder: op.sortOrder))
            default:
                throw SGTasksCloudError.actionNotAllowed
            }
            try store.deleteEntry(seq: entryId)
            try self.insert(operation, keys: entry.keys, sealed: entry.sealed, store: store, seq: entryId, origin: entry.origin, baseSnapshot: entry.baseSnapshot)
        }
    }

    /// Explicit user choice only: never-sent task creates waiting on a refused (403/422/quarantined)
    /// imported list are re-filed to the Cloud Inbox. Nothing is ever re-filed automatically.
    public func moveBlockedImportTasksToCloudInbox(listId: SGTasksWire.UUID) throws {
        try self.mutate { store, _ in
            let listKey = SGTasksCloudKey.list(listId)
            let entries = try store.entries()
            guard let create = entries.first(where: { $0.kind == .operation(.listCreate) && $0.keys.contains(listKey) }),
                  create.state == .blockedCreation || create.state == .invalid || create.state == .quarantined else {
                throw SGTasksCloudError.actionNotAllowed
            }
            for entry in entries where entry.kind == .operation(.taskCreate) && !entry.sentOnce && entry.keys.contains(listKey) {
                guard let request = try? SGTasksWire.MutationRequest(wireJSON: entry.body), case let .taskCreate(op) = request.operation else { continue }
                let content = SGTasksWire.Content(listId: nil, title: op.content.title, description: op.content.description, dueAt: op.content.dueAt, priority: op.content.priority, sortOrder: op.content.sortOrder, annotation: op.content.annotation)
                let moved = try Self.sealedRequest(mutationId: request.mutationId, operation: .taskCreate(SGTasksWire.TaskCreate(taskId: op.taskId, content: content, createdAt: op.createdAt, isCompleted: op.isCompleted, completedAt: op.completedAt)))
                try store.rewriteUnsent(seq: entry.seq, body: moved.wireJSON, keys: entry.keys.filter { $0 != listKey })
            }
        }
    }

    public func dismissNotice(id: Int64) {
        _ = try? self.mutate { store, _ in
            try store.deleteNotice(id: id)
        }
    }
}
