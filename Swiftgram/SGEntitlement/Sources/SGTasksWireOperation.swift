import Foundation
import CryptoKit

extension SGTasksWire {
    /// The twelve operations every wire revision accepts. Closed (see the `SGTasksWire` note): the
    /// R4-only `task.patch` is `MutationKind.taskPatch`.
    public enum OperationKind: String, Hashable, Sendable, CaseIterable {
        case listCreate = "list.create"
        case listUpdate = "list.update"
        case listDelete = "list.delete"
        case taskCreate = "task.create"
        case taskUpdate = "task.update"
        case taskComplete = "task.complete"
        case taskDelete = "task.delete"
        case inviteRequest = "invitation.request"
        case inviteRespond = "invitation.respond"
        case inviteRevoke = "invitation.revoke"
        case senderBlock = "sender.block"
        case senderUnblock = "sender.unblock"

        /// The only kinds that may carry `creation_proof` (and are creation-gated by the server).
        public var isCreation: Bool {
            return self == .listCreate || self == .taskCreate
        }
    }

    /// The `kind` of any operation the R4 wire carries (`$defs.Receipt.operation`): one of the R3
    /// twelve, or `task.patch`.
    public enum MutationKind: Hashable, Sendable, RawRepresentable {
        case operation(OperationKind)
        /// `task.patch` (R4 only).
        case taskPatch

        public init?(rawValue: String) {
            if let kind = OperationKind(rawValue: rawValue) {
                self = .operation(kind)
            } else if rawValue == "task.patch" {
                self = .taskPatch
            } else {
                return nil
            }
        }

        public var rawValue: String {
            switch self {
            case let .operation(kind):
                return kind.rawValue
            case .taskPatch:
                return "task.patch"
            }
        }

        public var isCreation: Bool {
            if case let .operation(kind) = self {
                return kind.isCreation
            }
            return false
        }
    }

    public struct ListCreate: Hashable, Sendable {
        public let listId: SGTasksWire.UUID
        public let title: String
        public let sortOrder: SortOrder
        /// An explicit imported creation time; nil means "server now".
        public let createdAt: Instant?

        public init(listId: SGTasksWire.UUID, title: String, sortOrder: SortOrder, createdAt: Instant?) {
            self.listId = listId
            self.title = title
            self.sortOrder = sortOrder
            self.createdAt = createdAt
        }
    }

    public struct ListUpdate: Hashable, Sendable {
        public let listId: SGTasksWire.UUID
        public let baseRevision: Revision
        public let title: String
        public let sortOrder: SortOrder

        public init(listId: SGTasksWire.UUID, baseRevision: Revision, title: String, sortOrder: SortOrder) {
            self.listId = listId
            self.baseRevision = baseRevision
            self.title = title
            self.sortOrder = sortOrder
        }
    }

    public struct ListDelete: Hashable, Sendable {
        public let listId: SGTasksWire.UUID
        public let baseRevision: Revision
        /// R4 only (`$defs.ListDeleteR4`): the members fence. A list whose `members_revision` moved
        /// since answers 409 `members_changed`; nil (R3) deletes without that fence. On the wire and
        /// in the business hash only when present.
        public let baseMembersRevision: Revision?

        public init(listId: SGTasksWire.UUID, baseRevision: Revision, baseMembersRevision: Revision? = nil) {
            self.listId = listId
            self.baseRevision = baseRevision
            self.baseMembersRevision = baseMembersRevision
        }
    }

    public struct TaskCreate: Hashable, Sendable {
        public let taskId: SGTasksWire.UUID
        public let content: Content
        public let createdAt: Instant?
        public let isCompleted: Bool
        /// Must be nil while `isCompleted` is false; nil with `isCompleted` true is "unknown".
        public let completedAt: Instant?

        public init(taskId: SGTasksWire.UUID, content: Content, createdAt: Instant?, isCompleted: Bool, completedAt: Instant?) {
            self.taskId = taskId
            self.content = content
            self.createdAt = createdAt
            self.isCompleted = isCompleted
            self.completedAt = completedAt
        }
    }

    public struct TaskUpdate: Hashable, Sendable {
        public let taskId: SGTasksWire.UUID
        public let baseRevision: Revision
        public let content: Content

        public init(taskId: SGTasksWire.UUID, baseRevision: Revision, content: Content) {
            self.taskId = taskId
            self.baseRevision = baseRevision
            self.content = content
        }
    }

    /// Complete (`isCompleted: true`) or reopen (`false`). The owner passes the current invitation
    /// id (nil without a live assignment); an accepted assignee passes its own.
    public struct TaskComplete: Hashable, Sendable {
        public let taskId: SGTasksWire.UUID
        public let baseRevision: Revision
        public let invitationId: SGTasksWire.UUID?
        public let isCompleted: Bool

        public init(taskId: SGTasksWire.UUID, baseRevision: Revision, invitationId: SGTasksWire.UUID?, isCompleted: Bool) {
            self.taskId = taskId
            self.baseRevision = baseRevision
            self.invitationId = invitationId
            self.isCompleted = isCompleted
        }
    }

    public struct TaskDelete: Hashable, Sendable {
        public let taskId: SGTasksWire.UUID
        public let baseRevision: Revision

        public init(taskId: SGTasksWire.UUID, baseRevision: Revision) {
            self.taskId = taskId
            self.baseRevision = baseRevision
        }
    }

    /// An explicit, user-confirmed share. A new `invitationId` is a new assignment epoch.
    public struct InviteRequest: Hashable, Sendable {
        public let taskId: SGTasksWire.UUID
        public let baseRevision: Revision
        public let invitationId: SGTasksWire.UUID
        public let recipientTgId: TelegramId

        public init(taskId: SGTasksWire.UUID, baseRevision: Revision, invitationId: SGTasksWire.UUID, recipientTgId: TelegramId) {
            self.taskId = taskId
            self.baseRevision = baseRevision
            self.invitationId = invitationId
            self.recipientTgId = recipientTgId
        }
    }

    public enum InviteDecision: String, Hashable, Sendable, CaseIterable {
        case accept
        case decline
        case leave
    }

    public struct InviteRespond: Hashable, Sendable {
        public let taskId: SGTasksWire.UUID
        public let baseRevision: Revision
        public let invitationId: SGTasksWire.UUID
        public let decision: InviteDecision

        public init(taskId: SGTasksWire.UUID, baseRevision: Revision, invitationId: SGTasksWire.UUID, decision: InviteDecision) {
            self.taskId = taskId
            self.baseRevision = baseRevision
            self.invitationId = invitationId
            self.decision = decision
        }
    }

    public struct InviteRevoke: Hashable, Sendable {
        public let taskId: SGTasksWire.UUID
        public let baseRevision: Revision
        public let invitationId: SGTasksWire.UUID

        public init(taskId: SGTasksWire.UUID, baseRevision: Revision, invitationId: SGTasksWire.UUID) {
            self.taskId = taskId
            self.baseRevision = baseRevision
            self.invitationId = invitationId
        }
    }

    public struct SenderBlock: Hashable, Sendable {
        public let invitationId: SGTasksWire.UUID

        public init(invitationId: SGTasksWire.UUID) {
            self.invitationId = invitationId
        }
    }

    public struct SenderUnblock: Hashable, Sendable {
        public let senderTgId: TelegramId

        public init(senderTgId: TelegramId) {
            self.senderTgId = senderTgId
        }
    }

    /// `task.patch` (`$defs.TaskPatch`, R4 only; single route or batch): field-level edit of an own
    /// task. Each `set` field must still hold its `expect` value (or already hold the `set` one),
    /// else 409 `field_changed` naming those fields; only stored values → 200 `unchanged`.
    /// `expect` has exactly `set`'s fields, and every value sits under its own field — checked when
    /// a `PatchRequest` is sealed or restored, not here.
    public struct TaskPatch: Hashable, Sendable {
        public let taskId: SGTasksWire.UUID
        public let set: [ContentField: FieldValue]
        /// The values the client last saw (its server shadow).
        public let expect: [ContentField: FieldValue]

        public init(taskId: SGTasksWire.UUID, set: [ContentField: FieldValue], expect: [ContentField: FieldValue]) {
            self.taskId = taskId
            self.set = set
            self.expect = expect
        }

        /// `set`'s fields in content order.
        public var fields: [ContentField] {
            return ContentField.allCases.filter { self.set[$0] != nil }
        }
    }

    public enum Operation: Hashable, Sendable {
        case listCreate(ListCreate)
        case listUpdate(ListUpdate)
        case listDelete(ListDelete)
        case taskCreate(TaskCreate)
        case taskUpdate(TaskUpdate)
        case taskComplete(TaskComplete)
        case taskDelete(TaskDelete)
        case inviteRequest(InviteRequest)
        case inviteRespond(InviteRespond)
        case inviteRevoke(InviteRevoke)
        case senderBlock(SenderBlock)
        case senderUnblock(SenderUnblock)

        public var kind: OperationKind {
            switch self {
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
    }

    /// The `mutation` object of `POST /v1/tasks/mutations` — business identity plus operation, and
    /// nothing transport-related: `creation_proof` and every credential are chosen per attempt by
    /// the transport and are never part of this value, its bytes or its hash.
    ///
    /// SEALED: `wireJSON` is computed once, here, and is exactly what every attempt sends. Persist
    /// those bytes and restore with `init(wireJSON:)`; the business identity can never drift.
    public struct MutationRequest: Hashable, Sendable {
        public let mutationId: SGTasksWire.UUID
        public let operation: Operation
        /// The canonical bytes of the `mutation` object.
        public let wireJSON: Data

        /// `{"mutation":` + `}` around the sealed bytes.
        static let envelopeOverhead = 13

        /// Validates every field rule of the wire plus the native sealing rules (trimmed, visible,
        /// grapheme and UTF-8 ceilings) and seals the bytes. Throws `SGTasksWire.ValidationError`.
        public init(mutationId: SGTasksWire.UUID, operation: Operation) throws {
            try SGTasksWireValidation.validate(operation, level: .sealing)
            let bytes = SGTasksJSON.encode(SGTasksWireCodec.mutationValue(mutationId: mutationId, operation: operation))
            guard bytes.count + MutationRequest.envelopeOverhead <= SGTasksWire.maxRequestBytes else {
                throw ValidationError(path: "mutation")
            }
            self.mutationId = mutationId
            self.operation = operation
            self.wireJSON = bytes
        }

        /// Restores sealed bytes. Strict: duplicate or unknown keys, a wrong schema version, broken
        /// field rules or bytes that are not exactly the canonical encoding all throw. Grapheme
        /// ceilings are NOT re-applied — they were checked when sealing, and a later OS's grapheme
        /// segmentation must not strand an already-sealed mutation.
        public init(wireJSON: Data) throws {
            try self.init(restoring: try SGTasksWire.parseSealed(wireJSON), wireJSON: wireJSON)
        }

        init(restoring value: SGTasksJSON.Value, wireJSON: Data) throws {
            let (mutationId, operation) = try SGTasksWireCodec.decodeMutation(value)
            try SGTasksWireValidation.validate(operation, level: .structural)
            guard SGTasksJSON.encode(value) == wireJSON, SGTasksJSON.encode(SGTasksWireCodec.mutationValue(mutationId: mutationId, operation: operation)) == wireJSON else {
                throw ValidationError(path: "mutation")
            }
            self.mutationId = mutationId
            self.operation = operation
            self.wireJSON = wireJSON
        }

        /// `["zenlygram-tasks-business-v1", principal, mutation_id, kind, ordered_arguments]` as
        /// canonical UTF-8 JSON, no trailing LF. `principal` is the authenticated canonical account
        /// id (`SGEntitlement.tasksPrincipal(accountPeerId:)`), byte for byte, never re-cased.
        public func canonicalBusinessBytes(principal: String) -> Data {
            return SGTasksWire.canonicalBusinessBytes(principal: principal, mutationId: self.mutationId, kind: self.operation.kind.rawValue, arguments: SGTasksWireCodec.orderedArguments(self.operation))
        }

        /// Lowercase hex SHA-256 of `canonicalBusinessBytes(principal:)`.
        public func businessHash(principal: String) -> String {
            return SGTasksWire.hexSHA256(self.canonicalBusinessBytes(principal: principal))
        }
    }

    /// R4: a sealed `task.patch` — `MutationRequest`'s sibling, with the same sealing, restore and
    /// business-hash rules (the R3 `Operation` set is closed, so the one R4-only operation lives
    /// here). Its bytes are the `mutation` object of the single route and a batch item alike.
    public struct PatchRequest: Hashable, Sendable {
        public let mutationId: SGTasksWire.UUID
        public let patch: TaskPatch
        /// The canonical bytes of the `mutation` object (`set` / `expect` keys in content order).
        public let wireJSON: Data

        /// `set` must satisfy the native sealing rules (it will be stored), `expect` the wire's
        /// structural ones (it is only compared, and holds the server's own values: a stricter
        /// local rule must never make a stored task unpatchable); `expect` has exactly `set`'s
        /// fields and every value sits under its own field. Throws `SGTasksWire.ValidationError`.
        public init(mutationId: SGTasksWire.UUID, patch: TaskPatch) throws {
            try SGTasksWireValidation.validate(patch, level: .sealing)
            let bytes = SGTasksJSON.encode(SGTasksWireCodec.patchMutationValue(mutationId: mutationId, patch: patch))
            // A user patch may fall back to the single route, so it must fit that route too.
            guard bytes.count + MutationRequest.envelopeOverhead <= SGTasksWire.maxRequestBytes else {
                throw ValidationError(path: "mutation")
            }
            self.mutationId = mutationId
            self.patch = patch
            self.wireJSON = bytes
        }

        /// Restores sealed bytes, as strictly as `MutationRequest(wireJSON:)`.
        public init(wireJSON: Data) throws {
            try self.init(restoring: try SGTasksWire.parseSealed(wireJSON), wireJSON: wireJSON)
        }

        init(restoring value: SGTasksJSON.Value, wireJSON: Data) throws {
            let (mutationId, patch) = try SGTasksWireCodec.decodePatchMutation(value)
            try SGTasksWireValidation.validate(patch, level: .structural)
            guard SGTasksJSON.encode(value) == wireJSON, SGTasksJSON.encode(SGTasksWireCodec.patchMutationValue(mutationId: mutationId, patch: patch)) == wireJSON else {
                throw ValidationError(path: "mutation")
            }
            self.mutationId = mutationId
            self.patch = patch
            self.wireJSON = wireJSON
        }

        /// `x-mutation-identity.arguments["task.patch"]`: `[task_id, set pairs, expect pairs]`.
        public func canonicalBusinessBytes(principal: String) -> Data {
            return SGTasksWire.canonicalBusinessBytes(principal: principal, mutationId: self.mutationId, kind: MutationKind.taskPatch.rawValue, arguments: SGTasksWireCodec.patchArguments(self.patch))
        }

        public func businessHash(principal: String) -> String {
            return SGTasksWire.hexSHA256(self.canonicalBusinessBytes(principal: principal))
        }
    }

    /// R4: any sealed mutation — an R3 `MutationRequest` or a `PatchRequest`. What the single route
    /// (`SGEntitlement.tasksMutation`) and a batch item take, and what an outbox restores.
    public enum SealedMutation: Hashable, Sendable {
        case mutation(MutationRequest)
        case patch(PatchRequest)

        /// Restores whichever the sealed bytes are, by each type's own strict rules.
        public init(wireJSON: Data) throws {
            let value = try SGTasksWire.parseSealed(wireJSON)
            if SGTasksWireCodec.operationKind(ofMutation: value) == MutationKind.taskPatch.rawValue {
                self = .patch(try PatchRequest(restoring: value, wireJSON: wireJSON))
            } else {
                self = .mutation(try MutationRequest(restoring: value, wireJSON: wireJSON))
            }
        }

        public var mutationId: SGTasksWire.UUID {
            switch self {
            case let .mutation(request):
                return request.mutationId
            case let .patch(request):
                return request.mutationId
            }
        }

        public var wireJSON: Data {
            switch self {
            case let .mutation(request):
                return request.wireJSON
            case let .patch(request):
                return request.wireJSON
            }
        }

        public var kind: MutationKind {
            switch self {
            case let .mutation(request):
                return .operation(request.operation.kind)
            case .patch:
                return .taskPatch
            }
        }

        /// Carries something only an R4 server accepts (`task.patch`, `base_members_revision`). An
        /// R3 server answers it 422 `tasks_invalid_request`, a definite non-commit
        /// (`x-wire-negotiation.downgrade`); everything else is valid on every wire.
        public var requiresWire4: Bool {
            switch self {
            case let .mutation(request):
                if case let .listDelete(op) = request.operation {
                    return op.baseMembersRevision != nil
                }
                return false
            case .patch:
                return true
            }
        }

        public func canonicalBusinessBytes(principal: String) -> Data {
            switch self {
            case let .mutation(request):
                return request.canonicalBusinessBytes(principal: principal)
            case let .patch(request):
                return request.canonicalBusinessBytes(principal: principal)
            }
        }

        public func businessHash(principal: String) -> String {
            return SGTasksWire.hexSHA256(self.canonicalBusinessBytes(principal: principal))
        }
    }

    static func parseSealed(_ wireJSON: Data) throws -> SGTasksJSON.Value {
        do {
            return try SGTasksJSON.parse(wireJSON, maxBytes: SGTasksWire.maxRequestBytes, maxDepth: SGTasksWire.maxDepth)
        } catch {
            throw ValidationError(path: "mutation")
        }
    }

    static func canonicalBusinessBytes(principal: String, mutationId: SGTasksWire.UUID, kind: String, arguments: SGTasksJSON.Value) -> Data {
        return SGTasksJSON.encode(.array([
            .string(SGTasksWire.businessDomain),
            .string(principal),
            .string(mutationId.rawValue),
            .string(kind),
            arguments
        ]))
    }

    /// Lowercase hex SHA-256.
    static func hexSHA256(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The field rules. `.structural` is the JSON Schema of the wire (patterns are already enforced by
/// the scalar types); `.sealing` adds the native rules a new mutation must satisfy before it is
/// sealed (`x-permissions-and-state.limits` / `visible_text`, the same rule as
/// `TodoStorage.validatedTitle`): no boundary whitespace, a visible character, grapheme ceilings and
/// UTF-8 byte ceilings. Nothing is trimmed or normalised — a value that would need it is refused.
enum SGTasksWireValidation {
    enum Level {
        case structural
        case sealing
    }

    struct TextRule {
        let minScalars: Int
        let maxScalars: Int
        let maxGraphemes: Int
        let maxUTF8Bytes: Int
        let requiresVisibleTrimmed: Bool
    }

    static let taskTitle = TextRule(minScalars: 1, maxScalars: 8192, maxGraphemes: 200, maxUTF8Bytes: 8192, requiresVisibleTrimmed: true)
    static let listTitle = TextRule(minScalars: 1, maxScalars: 8192, maxGraphemes: 100, maxUTF8Bytes: 8192, requiresVisibleTrimmed: true)
    static let displayName = TextRule(minScalars: 1, maxScalars: 4096, maxGraphemes: 256, maxUTF8Bytes: 4096, requiresVisibleTrimmed: true)
    static let description = TextRule(minScalars: 0, maxScalars: 16384, maxGraphemes: 4096, maxUTF8Bytes: 16384, requiresVisibleTrimmed: false)

    static func check(_ text: String, _ rule: TextRule, level: Level, path: String) throws {
        let scalars = text.unicodeScalars.count
        guard scalars >= rule.minScalars, scalars <= rule.maxScalars else {
            throw SGTasksWire.ValidationError(path: path)
        }
        guard level == .sealing else {
            return
        }
        guard text.utf8.count <= rule.maxUTF8Bytes, text.count <= rule.maxGraphemes else {
            throw SGTasksWire.ValidationError(path: path)
        }
        if rule.requiresVisibleTrimmed {
            guard text.trimmingCharacters(in: .whitespacesAndNewlines) == text, self.containsVisibleScalar(text) else {
                throw SGTasksWire.ValidationError(path: path)
            }
        }
    }

    /// At least one scalar outside Cc, Cf, Mn, Mc, Me, Zs, Zl, Zp.
    static func containsVisibleScalar(_ text: String) -> Bool {
        return text.unicodeScalars.contains(where: { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .nonspacingMark, .spacingMark, .enclosingMark, .spaceSeparator, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        })
    }

    static func checkDeadline(_ value: SGTasksWire.Deadline?, path: String) throws {
        if let value, value < 0 {
            throw SGTasksWire.ValidationError(path: path)
        }
    }

    static func validate(_ content: SGTasksWire.Content, level: Level, path: String) throws {
        try self.check(content.title, self.taskTitle, level: level, path: path + ".title")
        if let description = content.description {
            try self.check(description, self.description, level: level, path: path + ".description")
        }
        try self.checkDeadline(content.dueAt, path: path + ".due_at")
        guard (0 ... 4).contains(content.priority) else {
            throw SGTasksWire.ValidationError(path: path + ".priority")
        }
        if let annotation = content.annotation {
            try self.check(annotation.displayName, self.displayName, level: level, path: path + ".annotation.display_name")
        }
    }

    /// `x-permissions-and-state.creation_data`: an explicit historical date is 1970 or later. The
    /// upper bound (server now + 300 s) is the server's to judge; an earlier date would only seal a
    /// guaranteed 422 under an identity that can never change.
    static func checkHistorical(_ instant: SGTasksWire.Instant?, level: Level, path: String) throws {
        if level == .sealing, let instant, instant.epochSeconds < 0 {
            throw SGTasksWire.ValidationError(path: path)
        }
    }

    static func validate(_ operation: SGTasksWire.Operation, level: Level) throws {
        let path = "mutation.operation"
        switch operation {
        case let .listCreate(value):
            try self.check(value.title, self.listTitle, level: level, path: path + ".title")
            try self.checkHistorical(value.createdAt, level: level, path: path + ".created_at")
        case let .listUpdate(value):
            try self.check(value.title, self.listTitle, level: level, path: path + ".title")
        case let .taskCreate(value):
            try self.validate(value.content, level: level, path: path + ".content")
            if !value.isCompleted && value.completedAt != nil {
                throw SGTasksWire.ValidationError(path: path + ".completed_at")
            }
            try self.checkHistorical(value.createdAt, level: level, path: path + ".created_at")
            try self.checkHistorical(value.completedAt, level: level, path: path + ".completed_at")
        case let .taskUpdate(value):
            try self.validate(value.content, level: level, path: path + ".content")
        case .listDelete, .taskComplete, .taskDelete, .inviteRequest, .inviteRespond, .inviteRevoke, .senderBlock, .senderUnblock:
            break
        }
    }

    /// `set` non-empty, `expect` with exactly its fields, every value under its own field; `set`
    /// at `level`, `expect` always at `.structural` (see `PatchRequest`). Checked in content order,
    /// so the reported path does not depend on dictionary order.
    static func validate(_ patch: SGTasksWire.TaskPatch, level: Level) throws {
        let path = "mutation.operation"
        guard !patch.set.isEmpty else {
            throw SGTasksWire.ValidationError(path: path + ".set")
        }
        guard Set(patch.expect.keys) == Set(patch.set.keys) else {
            throw SGTasksWire.ValidationError(path: path + ".expect")
        }
        for field in SGTasksWire.ContentField.allCases {
            if let value = patch.set[field] {
                try self.validate(value, as: field, level: level, path: path + ".set." + field.rawValue)
            }
            if let value = patch.expect[field] {
                try self.validate(value, as: field, level: .structural, path: path + ".expect." + field.rawValue)
            }
        }
    }

    /// One field value by its `Content` rule.
    static func validate(_ value: SGTasksWire.FieldValue, as field: SGTasksWire.ContentField, level: Level, path: String) throws {
        guard value.field == field else {
            throw SGTasksWire.ValidationError(path: path)
        }
        switch value {
        case .listId, .sortOrder:
            break
        case let .title(title):
            try self.check(title, self.taskTitle, level: level, path: path)
        case let .description(description):
            if let description {
                try self.check(description, self.description, level: level, path: path)
            }
        case let .dueAt(dueAt):
            try self.checkDeadline(dueAt, path: path)
        case let .priority(priority):
            guard (0 ... 4).contains(priority) else {
                throw SGTasksWire.ValidationError(path: path)
            }
        case let .annotation(annotation):
            if let annotation {
                try self.check(annotation.displayName, self.displayName, level: level, path: path + ".display_name")
            }
        }
    }
}
