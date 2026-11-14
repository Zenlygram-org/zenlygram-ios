import Foundation

/// Zenlygram — the Tasks wire v1 (`urn:zenlygram:tasks-wire:1:review-r4`), as Swift values.
///
/// Every nested type is named after the wire's `$defs` entry it models and has the same fields in
/// camelCase. The values are produced only by the strict codec (`SGTasksJSON` / `SGTasksWireCodec`)
/// or by validating initialisers, never by `Codable`: decimal identifiers stay decimal STRINGS
/// (a revision or Telegram id never goes through `Double`), every nullable field is an explicit
/// `null` on the wire, unknown fields are refused and nothing is defaulted.
///
/// R4 (`X-Tasks-Wire: 4`, `x-wire-negotiation`) is additive: the R3 shapes, operations and reasons
/// stay valid, and the R3 vocabularies `Operation`, `OperationKind`, `ConflictReason` and
/// `SGTasksError.Kind` stay CLOSED — the cloud engine and the board switch over them exhaustively.
/// What R4 adds therefore comes as new types beside them: `TaskPatch` / `PatchRequest` /
/// `SealedMutation`, `MutationKind`, `ErrorReason`, the batch types, and `SGTasksError.refinement`.
///
/// Names inside this namespace shadow `Swift.Error`, `Swift.Sequence`, Foundation's `UUID` and the
/// concurrency `Task`; code in this namespace spells those out in full.
public enum SGTasksWire {
    public static let schemaVersion: Int64 = 1
    /// The first element of every canonical business array (`x-mutation-identity.hash`).
    public static let businessDomain = "zenlygram-tasks-business-v1"
    /// The highest wire revision whose semantics this core implements (R4): what a `server_wire >= 4`
    /// seals (`task.patch`, the members fence, the batch route) and what an R4 echo or projection
    /// proves. Not by itself the value a request sends: a build sends `SGTasksShippedWire.requestWire`
    /// (`sg_config.tasks_wire`, 4 or 5, wf15 §8.2), which this core only bounds.
    public static let wireRevision = 4
    /// The highest `X-Tasks-Wire` value a build may send (wire 5: the assignee note and `completed_by`,
    /// wf15 §8.1). A server that does not accept a value answers 422 before authentication on every
    /// request (F1a), so the request wire is a build-time value and is never probed; an echo outside
    /// `wireRevision ... maximumWire` proves nothing.
    public static let maximumWire = 5
    /// `POST /v1/tasks/mutations`: request ceiling in UTF-8 bytes, and JSON depth for every route.
    public static let maxRequestBytes = 65536
    /// `POST /v1/tasks/mutations/batch` (R4): request ceiling in UTF-8 bytes and item count.
    public static let maxBatchRequestBytes = 524288
    public static let maxBatchItems = 100
    public static let maxDepth = 16
    /// Snapshot / changes page bounds (`limit` 1...100, default 50).
    public static let maxPageLimit = 100
    public static let defaultPageLimit = 50

    public typealias SortOrder = Int32
    /// `Deadline` is `integer|null` in 0...2147483647; the nullable half is `Deadline?`.
    public typealias Deadline = Int32

    /// A field that broke a wire rule. Carries the field PATH only, never the offending content.
    public struct ValidationError: Swift.Error, Equatable, Hashable, Sendable {
        public let path: String

        public init(path: String) {
            self.path = path
        }
    }

    // MARK: - Scalars

    /// `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` — lowercase v4 only.
    public struct UUID: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init?(_ raw: String) {
            guard SGTasksWire.UUID.isValid(raw) else {
                return nil
            }
            self.rawValue = raw
        }

        /// A fresh random version-4 identifier in the wire's lowercase form.
        public static func generate() -> SGTasksWire.UUID {
            // Foundation's random UUID is RFC 4122 version 4 / variant 10xx.
            guard let value = SGTasksWire.UUID(Foundation.UUID().uuidString.lowercased()) else {
                preconditionFailure("Foundation.UUID() is not an RFC 4122 v4 identifier")
            }
            return value
        }

        static func isValid(_ raw: String) -> Bool {
            let bytes = Array(raw.utf8)
            guard bytes.count == 36 else {
                return false
            }
            for (index, byte) in bytes.enumerated() {
                switch index {
                case 8, 13, 18, 23:
                    guard byte == UInt8(ascii: "-") else {
                        return false
                    }
                case 14:
                    guard byte == UInt8(ascii: "4") else {
                        return false
                    }
                case 19:
                    guard byte == UInt8(ascii: "8") || byte == UInt8(ascii: "9") || byte == UInt8(ascii: "a") || byte == UInt8(ascii: "b") else {
                        return false
                    }
                default:
                    guard (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte) else {
                        return false
                    }
                }
            }
            return true
        }

        public static func < (lhs: SGTasksWire.UUID, rhs: SGTasksWire.UUID) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }

        public var description: String {
            return self.rawValue
        }
    }

    /// A RAW positive MTProto CloudUser id as a canonical decimal string (`^[1-9][0-9]{0,18}$`) that
    /// fits a signed 64-bit integer (`x-permissions-and-state.limits`). Never a packed `PeerId`.
    public struct TelegramId: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public let int64Value: Int64

        public init?(_ raw: String) {
            guard let value = SGTasksDecimal.value(raw, allowZero: false) else {
                return nil
            }
            self.rawValue = raw
            self.int64Value = value
        }

        public init?(int64 value: Int64) {
            guard value > 0 else {
                return nil
            }
            self.rawValue = String(value)
            self.int64Value = value
        }

        /// The raw user id of a packed `PeerId.toInt64()` value, or nil when that value is not a
        /// CloudUser. The exact inverse of Postbox's packing (`submodules/Postbox/Sources/Peer.swift`,
        /// `PeerId.init(_ n: Int64)` / `_toInt64()`): bits 32...34 are the namespace, the id's low 32
        /// bits stay in place and its high bits are shifted left by three. CloudUser is namespace 0
        /// (`Namespaces.Peer.CloudUser`, `SyncCore_Namespaces.swift`), so a group (1), channel (2),
        /// secret chat (3) or any other namespace is refused, as is anything outside Postbox's own
        /// 56-bit `PeerId.Id` domain. Same decode as `SGEntitlementAccountIdentity.telegramUserId`.
        public init?(cloudUserPeerId packed: Int64) {
            guard let raw = SGEntitlementAccountIdentity.telegramUserId(accountPeerId: packed), raw <= SGTasksWire.TelegramId.maxPostboxUserId else {
                return nil
            }
            self.init(int64: raw)
        }

        /// `PeerId.Id` asserts its non-negative raw value fits 56 bits.
        static let maxPostboxUserId: Int64 = 0x00ff_ffff_ffff_ffff

        public static func < (lhs: SGTasksWire.TelegramId, rhs: SGTasksWire.TelegramId) -> Bool {
            return lhs.int64Value < rhs.int64Value
        }

        public var description: String {
            return self.rawValue
        }
    }

    /// A resource revision: canonical positive decimal string within `Int64`.
    public struct Revision: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public let int64Value: Int64

        public init?(_ raw: String) {
            guard let value = SGTasksDecimal.value(raw, allowZero: false) else {
                return nil
            }
            self.rawValue = raw
            self.int64Value = value
        }

        public static func < (lhs: SGTasksWire.Revision, rhs: SGTasksWire.Revision) -> Bool {
            return lhs.int64Value < rhs.int64Value
        }

        public var description: String {
            return self.rawValue
        }
    }

    /// A feed position: canonical non-negative decimal string within `Int64`.
    public struct Sequence: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public let int64Value: Int64

        public init?(_ raw: String) {
            guard let value = SGTasksDecimal.value(raw, allowZero: true) else {
                return nil
            }
            self.rawValue = raw
            self.int64Value = value
        }

        public static func < (lhs: SGTasksWire.Sequence, rhs: SGTasksWire.Sequence) -> Bool {
            return lhs.int64Value < rhs.int64Value
        }

        public var description: String {
            return self.rawValue
        }
    }

    /// `YYYY-MM-DDTHH:MM:SSZ`, UTC, whole seconds, a real proleptic-Gregorian calendar instant.
    public struct Instant: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let rawValue: String
        /// Seconds since 1970-01-01T00:00:00Z.
        public let epochSeconds: Int64

        public init?(_ raw: String) {
            guard let seconds = SGTasksCivilTime.epochSeconds(raw) else {
                return nil
            }
            self.rawValue = raw
            self.epochSeconds = seconds
        }

        /// The whole UTC second at or before `date`; nil outside the years 0000...9999.
        public init?(date: Date) {
            let interval = date.timeIntervalSince1970.rounded(.down)
            guard interval.isFinite, interval >= Double(SGTasksCivilTime.minimumEpochSeconds), interval <= Double(SGTasksCivilTime.maximumEpochSeconds) else {
                return nil
            }
            let seconds = Int64(interval)
            self.rawValue = SGTasksCivilTime.format(seconds)
            self.epochSeconds = seconds
        }

        public var date: Date {
            return Date(timeIntervalSince1970: TimeInterval(self.epochSeconds))
        }

        public static func < (lhs: SGTasksWire.Instant, rhs: SGTasksWire.Instant) -> Bool {
            return lhs.epochSeconds < rhs.epochSeconds
        }

        public var description: String {
            return self.rawValue
        }
    }

    /// An opaque server cursor, 1...4096 characters. Never parsed, never logged.
    public struct Cursor: Hashable, Sendable {
        public let rawValue: String

        public init?(_ raw: String) {
            let count = raw.unicodeScalars.count
            guard count >= 1, count <= 4096 else {
                return nil
            }
            self.rawValue = raw
        }
    }

    // MARK: - Objects

    public struct Annotation: Hashable, Sendable {
        public let telegramUserId: TelegramId
        public let displayName: String

        public init(telegramUserId: TelegramId, displayName: String) {
            self.telegramUserId = telegramUserId
            self.displayName = displayName
        }
    }

    public struct Content: Hashable, Sendable {
        public let listId: SGTasksWire.UUID?
        public let title: String
        public let description: String?
        public let dueAt: Deadline?
        public let priority: Int
        public let sortOrder: SortOrder
        public let annotation: Annotation?

        public init(listId: SGTasksWire.UUID?, title: String, description: String?, dueAt: Deadline?, priority: Int, sortOrder: SortOrder, annotation: Annotation?) {
            self.listId = listId
            self.title = title
            self.description = description
            self.dueAt = dueAt
            self.priority = priority
            self.sortOrder = sortOrder
            self.annotation = annotation
        }

        /// This content with `values` written over it: what a `task.patch` with `set == values`
        /// leaves behind (the overlay; the R3 `task.update` a patch is re-encoded as after a
        /// downgrade). Each value lands in its own field.
        public func applying(_ values: [ContentField: FieldValue]) -> Content {
            var listId = self.listId
            var title = self.title
            var description = self.description
            var dueAt = self.dueAt
            var priority = self.priority
            var sortOrder = self.sortOrder
            var annotation = self.annotation
            for value in values.values {
                switch value {
                case let .listId(newValue):
                    listId = newValue
                case let .title(newValue):
                    title = newValue
                case let .description(newValue):
                    description = newValue
                case let .dueAt(newValue):
                    dueAt = newValue
                case let .priority(newValue):
                    priority = newValue
                case let .sortOrder(newValue):
                    sortOrder = newValue
                case let .annotation(newValue):
                    annotation = newValue
                }
            }
            return Content(listId: listId, title: title, description: description, dueAt: dueAt, priority: priority, sortOrder: sortOrder, annotation: annotation)
        }
    }

    /// A `Content` field (`$defs.ContentField`). Declared, and ordered, in
    /// `x-mutation-identity.content_order`: `allCases` and `<` are that order.
    public enum ContentField: String, Hashable, Sendable, CaseIterable, Comparable {
        case listId = "list_id"
        case title
        case description
        case dueAt = "due_at"
        case priority
        case sortOrder = "sort_order"
        case annotation

        var contentOrder: Int {
            switch self {
            case .listId:
                return 0
            case .title:
                return 1
            case .description:
                return 2
            case .dueAt:
                return 3
            case .priority:
                return 4
            case .sortOrder:
                return 5
            case .annotation:
                return 6
            }
        }

        public static func < (lhs: ContentField, rhs: ContentField) -> Bool {
            return lhs.contentOrder < rhs.contentOrder
        }
    }

    /// One `Content` field's value, typed by that field (a `task.patch` `set` / `expect` entry).
    public enum FieldValue: Hashable, Sendable {
        case listId(SGTasksWire.UUID?)
        case title(String)
        case description(String?)
        case dueAt(Deadline?)
        case priority(Int)
        case sortOrder(SortOrder)
        case annotation(Annotation?)

        public var field: ContentField {
            switch self {
            case .listId:
                return .listId
            case .title:
                return .title
            case .description:
                return .description
            case .dueAt:
                return .dueAt
            case .priority:
                return .priority
            case .sortOrder:
                return .sortOrder
            case .annotation:
                return .annotation
            }
        }

        /// `field`'s value in `content` (an `expect` value from the server shadow).
        public init(_ field: ContentField, of content: Content) {
            switch field {
            case .listId:
                self = .listId(content.listId)
            case .title:
                self = .title(content.title)
            case .description:
                self = .description(content.description)
            case .dueAt:
                self = .dueAt(content.dueAt)
            case .priority:
                self = .priority(content.priority)
            case .sortOrder:
                self = .sortOrder(content.sortOrder)
            case .annotation:
                self = .annotation(content.annotation)
            }
        }
    }

    public enum AssignmentState: String, Hashable, Sendable, CaseIterable {
        case pending
        case accepted
        case declined
        case revoked
        case left
        case expired
    }

    public struct Assignment: Hashable, Sendable {
        public let invitationId: SGTasksWire.UUID
        public let recipientTgId: TelegramId
        public let state: AssignmentState
        public let expiresAt: Instant

        public init(invitationId: SGTasksWire.UUID, recipientTgId: TelegramId, state: AssignmentState, expiresAt: Instant) {
            self.invitationId = invitationId
            self.recipientTgId = recipientTgId
            self.state = state
            self.expiresAt = expiresAt
        }
    }

    public struct List: Hashable, Sendable {
        public let id: SGTasksWire.UUID
        /// Covers `title` and `sort_order` only (every wire, `x-permissions-and-state.lists`).
        public let revision: Revision
        /// `$defs.ListR4.members_revision`: advances on every member-task and invitation change; the
        /// base of a members-fenced `list.delete`. nil in an R3 projection.
        public let membersRevision: Revision?
        public let title: String
        public let sortOrder: SortOrder
        public let createdAt: Instant
        public let updatedAt: Instant

        public init(id: SGTasksWire.UUID, revision: Revision, title: String, sortOrder: SortOrder, createdAt: Instant, updatedAt: Instant, membersRevision: Revision? = nil) {
            self.id = id
            self.revision = revision
            self.membersRevision = membersRevision
            self.title = title
            self.sortOrder = sortOrder
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public enum ViewerRole: String, Hashable, Sendable, CaseIterable {
        case owner
        case assignee
    }

    public struct Task: Hashable, Sendable {
        public let id: SGTasksWire.UUID
        public let revision: Revision
        public let ownerTgId: TelegramId
        public let viewerRole: ViewerRole
        public let content: Content
        public let isCompleted: Bool
        public let completedAt: Instant?
        public let createdAt: Instant
        public let updatedAt: Instant
        public let assignment: Assignment?

        public init(id: SGTasksWire.UUID, revision: Revision, ownerTgId: TelegramId, viewerRole: ViewerRole, content: Content, isCompleted: Bool, completedAt: Instant?, createdAt: Instant, updatedAt: Instant, assignment: Assignment?) {
            self.id = id
            self.revision = revision
            self.ownerTgId = ownerTgId
            self.viewerRole = viewerRole
            self.content = content
            self.isCompleted = isCompleted
            self.completedAt = completedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.assignment = assignment
        }
    }

    public struct Invitation: Hashable, Sendable {
        public let id: SGTasksWire.UUID
        public let taskId: SGTasksWire.UUID
        public let taskRevision: Revision
        public let ownerTgId: TelegramId
        public let title: String
        public let dueAt: Deadline?
        public let expiresAt: Instant

        public init(id: SGTasksWire.UUID, taskId: SGTasksWire.UUID, taskRevision: Revision, ownerTgId: TelegramId, title: String, dueAt: Deadline?, expiresAt: Instant) {
            self.id = id
            self.taskId = taskId
            self.taskRevision = taskRevision
            self.ownerTgId = ownerTgId
            self.title = title
            self.dueAt = dueAt
            self.expiresAt = expiresAt
        }
    }

    public struct Block: Hashable, Sendable {
        public let id: TelegramId
        public let createdAt: Instant

        public init(id: TelegramId, createdAt: Instant) {
            self.id = id
            self.createdAt = createdAt
        }
    }

    public enum Projection: Hashable, Sendable {
        case list(List)
        case task(Task)
        case invitation(Invitation)
        case block(Block)
    }

    /// A `Change` with `action: "remove"`: the kind and an id of the type that kind uses.
    public enum RemovalTarget: Hashable, Sendable {
        case list(SGTasksWire.UUID)
        case task(SGTasksWire.UUID)
        case invitation(SGTasksWire.UUID)
        case block(TelegramId)
    }

    public enum Change: Hashable, Sendable {
        case upsert(position: SGTasksWire.Sequence, item: Projection)
        case remove(position: SGTasksWire.Sequence, target: RemovalTarget)

        public var position: SGTasksWire.Sequence {
            switch self {
            case let .upsert(position, _), let .remove(position, _):
                return position
            }
        }
    }

    public enum ResourceKind: String, Hashable, Sendable, CaseIterable {
        case list
        case task
        case block
    }

    public enum ResourceId: Hashable, Sendable {
        case uuid(SGTasksWire.UUID)
        case telegramId(TelegramId)
    }

    public enum ReceiptOutcome: String, Hashable, Sendable, CaseIterable {
        case committed
        case unchanged
    }

    public struct Receipt: Hashable, Sendable {
        public let mutationId: SGTasksWire.UUID
        /// `task.patch` only in an answer to a `task.patch` (R4).
        public let operation: MutationKind
        public let outcome: ReceiptOutcome
        public let resourceKind: ResourceKind
        public let resourceId: ResourceId
        public let resourceRevision: Revision?
        public let committedAt: Instant

        public init(mutationId: SGTasksWire.UUID, operation: MutationKind, outcome: ReceiptOutcome, resourceKind: ResourceKind, resourceId: ResourceId, resourceRevision: Revision?, committedAt: Instant) {
            self.mutationId = mutationId
            self.operation = operation
            self.outcome = outcome
            self.resourceKind = resourceKind
            self.resourceId = resourceId
            self.resourceRevision = resourceRevision
            self.committedAt = committedAt
        }

        /// A receipt of one of the twelve R3 operations.
        public init(mutationId: SGTasksWire.UUID, operation: OperationKind, outcome: ReceiptOutcome, resourceKind: ResourceKind, resourceId: ResourceId, resourceRevision: Revision?, committedAt: Instant) {
            self.init(mutationId: mutationId, operation: .operation(operation), outcome: outcome, resourceKind: resourceKind, resourceId: resourceId, resourceRevision: resourceRevision, committedAt: committedAt)
        }
    }

    /// `serverWire` on every response type is the `X-Tasks-Wire` echo of the HTTP answer (R4 servers
    /// send `4`; nil when absent — an R3 server, or a rolled-back one: the downgrade signal of
    /// `x-wire-negotiation`). It is transport metadata, never part of the body.
    public struct MutationResponse: Hashable, Sendable {
        public let receipt: Receipt
        public let serverTime: Instant
        public let serverWire: Int?

        public init(receipt: Receipt, serverTime: Instant, serverWire: Int? = nil) {
            self.receipt = receipt
            self.serverTime = serverTime
            self.serverWire = serverWire
        }
    }

    public struct SnapshotResponse: Hashable, Sendable {
        public let items: [Projection]
        public let nextCursor: Cursor?
        public let changesCursor: Cursor
        public let serverTime: Instant
        public let serverWire: Int?

        public init(items: [Projection], nextCursor: Cursor?, changesCursor: Cursor, serverTime: Instant, serverWire: Int? = nil) {
            self.items = items
            self.nextCursor = nextCursor
            self.changesCursor = changesCursor
            self.serverTime = serverTime
            self.serverWire = serverWire
        }
    }

    public struct ChangesResponse: Hashable, Sendable {
        public let changes: [Change]
        public let nextCursor: Cursor
        public let hasMore: Bool
        public let serverTime: Instant
        public let serverWire: Int?

        public init(changes: [Change], nextCursor: Cursor, hasMore: Bool, serverTime: Instant, serverWire: Int? = nil) {
            self.changes = changes
            self.nextCursor = nextCursor
            self.hasMore = hasMore
            self.serverTime = serverTime
            self.serverWire = serverWire
        }
    }

    /// The four R3 `tasks_conflict` reasons. A closed set (see the namespace note): R4's
    /// `field_changed` / `members_changed` are `ErrorReason`s, and `SGTasksError` reports them as
    /// `.conflict(.revisionChanged)` — "changed since your base", their R3 class — with the exact
    /// R4 reason in `refinement`.
    public enum ConflictReason: String, Hashable, Sendable, CaseIterable {
        case revisionChanged = "revision_changed"
        case invitationChanged = "invitation_changed"
        case invitationExpired = "invitation_expired"
        case completedTask = "completed_task"
    }

    /// Every `reason` an R4 error body may carry (`$defs.Error.reason`); which code carries which is
    /// `$defs.ErrorRules`: `tasks_conflict` one of the six conflict reasons (required),
    /// `tasks_consent_required` `withdrawn` (required), `tasks_unavailable` `batch_disabled` /
    /// `migration_paused` (optional), every other code none.
    public enum ErrorReason: String, Hashable, Sendable, CaseIterable {
        case revisionChanged = "revision_changed"
        case invitationChanged = "invitation_changed"
        case invitationExpired = "invitation_expired"
        case completedTask = "completed_task"
        /// `task.patch` (R4): a stored value is neither `expect` nor `set`; `fields` names them.
        case fieldChanged = "field_changed"
        /// Members-fenced `list.delete` (R4): `base_members_revision` is not the list's.
        case membersChanged = "members_changed"
        /// `tasks_consent_required` (every wire): a processed consent withdrawal stands.
        case withdrawn
        /// `503` on the batch route while it is switched off (answered before authentication).
        case batchDisabled = "batch_disabled"
        /// `503` on a `migration`-origin batch item while migrations are paused.
        case migrationPaused = "migration_paused"

        /// The R3 conflict reason this is; nil for every R4-only reason.
        public var conflictReason: ConflictReason? {
            return ConflictReason(rawValue: self.rawValue)
        }

        static let conflictReasons: Set<ErrorReason> = [.revisionChanged, .invitationChanged, .invitationExpired, .completedTask, .fieldChanged, .membersChanged]
        static let unavailableReasons: Set<ErrorReason> = [.batchDisabled, .migrationPaused]
    }

    /// The wire's `Error` body. `message` is server copy for support only: never shown, never logged.
    public struct Error: Hashable, Sendable {
        public let error: String
        public let message: String
        public let serverTime: Instant
        public let reason: ErrorReason?
        /// `field_changed` only: the conflicting fields, in content order; empty otherwise.
        public let fields: [ContentField]
        /// `tasks_consent_required` only: when the standing withdrawal took effect.
        public let effectiveAt: Instant?

        public init(error: String, message: String, serverTime: Instant, reason: ErrorReason?, fields: [ContentField] = [], effectiveAt: Instant? = nil) {
            self.error = error
            self.message = message
            self.serverTime = serverTime
            self.reason = reason
            self.fields = fields
            self.effectiveAt = effectiveAt
        }
    }

    // MARK: - Batch (R4)

    /// `BatchItem.origin`. `migration` marks a create of data that existed locally before the
    /// account's cloud (charged to the `import` budget, exempt within the migration window); only
    /// `list.create` / `task.create` may carry it, and only the batch route does. Not hashed.
    public enum MutationOrigin: String, Hashable, Sendable, CaseIterable {
        case user
        case migration
    }

    /// `POST /v1/tasks/mutations/batch` (R4 only): up to 100 sealed mutations sent as one request,
    /// each executed — and answered — on its own. The body is the sealed bytes of every item,
    /// byte for byte (`SGTasksWireCodec.batchBody`), so a later single-route resend of the same
    /// mutation is a replay. Validated when made; nothing transport-related is part of it.
    public struct MutationBatchRequest: Hashable, Sendable {
        public struct Item: Hashable, Sendable {
            public let mutation: SealedMutation
            public let origin: MutationOrigin

            public init(_ mutation: SealedMutation, origin: MutationOrigin = .user) {
                self.mutation = mutation
                self.origin = origin
            }
        }

        /// The request's `Idempotency-Key` too.
        public let batchId: SGTasksWire.UUID
        public let items: [Item]
        /// UTF-8 bytes of the request body WITHOUT `creation_proof` (a proof is added only while
        /// the body stays within `maxBatchRequestBytes`).
        public let bodyBytes: Int

        /// Throws `ValidationError` for 0 or more than `maxBatchItems` items, a repeated mutation id,
        /// a `migration` origin on anything but a create, or a body past `maxBatchRequestBytes`.
        public init(batchId: SGTasksWire.UUID, items: [Item]) throws {
            guard (1 ... SGTasksWire.maxBatchItems).contains(items.count) else {
                throw ValidationError(path: "mutations")
            }
            var seen = Set<SGTasksWire.UUID>()
            for (index, item) in items.enumerated() {
                guard seen.insert(item.mutation.mutationId).inserted else {
                    throw ValidationError(path: "mutations[\(index)].mutation_id")
                }
                if item.origin == .migration, !item.mutation.kind.isCreation {
                    throw ValidationError(path: "mutations[\(index)].origin")
                }
            }
            let bytes = MutationBatchRequest.bodyBytes(of: items)
            guard bytes <= SGTasksWire.maxBatchRequestBytes else {
                throw ValidationError(path: "batch")
            }
            self.batchId = batchId
            self.items = items
            self.bodyBytes = bytes
        }

        /// Whether any item is a create, the only kind a `creation_proof` may accompany.
        public var containsCreation: Bool {
            return self.items.contains(where: { $0.mutation.kind.isCreation })
        }

        /// `{"schema_version":1,"batch_id":"<36>","mutations":[` + items + `]}`; a `user` item is its
        /// sealed bytes, a `migration` one the same bytes behind `"origin":"migration",`. For sizing
        /// a batch before it is made.
        public static func bodyBytes(of items: [Item]) -> Int {
            var total = SGTasksWire.batchEnvelopeOverhead + max(items.count - 1, 0)
            for item in items {
                total += item.mutation.wireJSON.count
                if item.origin == .migration {
                    total += SGTasksWire.migrationOriginPrefix.count - 1
                }
            }
            return total
        }
    }

    /// One `BatchItemResult`, in the request's order. A `.receipt` answers its item's mutation (it
    /// was checked); `.error` carries the item's HTTP-like status and its classification, exactly
    /// as the single route would have classified it; `.skipped` never started — resend later with
    /// the SAME mutation, no attempt counted.
    public enum BatchItemResult: Equatable {
        case receipt(Receipt)
        case error(status: Int, SGTasksError)
        case skipped
    }

    public struct MutationBatchResponse: Equatable {
        public let batchId: SGTasksWire.UUID
        /// One per request item, same order.
        public let results: [BatchItemResult]
        /// Seconds from the item that stopped the batch with a 429 / 503, clamped to 0...86400.
        public let retryAfter: Int?
        public let serverTime: Instant
        /// The `X-Tasks-Wire` echo (see `MutationResponse`).
        public let serverWire: Int?

        public init(batchId: SGTasksWire.UUID, results: [BatchItemResult], retryAfter: Int?, serverTime: Instant, serverWire: Int?) {
            self.batchId = batchId
            self.results = results
            self.retryAfter = retryAfter
            self.serverTime = serverTime
            self.serverWire = serverWire
        }
    }

    /// `{"schema_version":1,"batch_id":"` (32) + 36 + `","mutations":[` (15) … `]}` (2).
    static let batchEnvelopeOverhead = 85
    /// Replaces a migration item's leading `{`.
    static let migrationOriginPrefix = Array("{\"origin\":\"migration\",".utf8)
}

/// Canonical decimal strings that must fit `Int64` (`x-permissions-and-state.limits`).
enum SGTasksDecimal {
    static func value(_ raw: String, allowZero: Bool) -> Int64? {
        let bytes = Array(raw.utf8)
        guard !bytes.isEmpty, bytes.count <= 19, bytes.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        if bytes[0] == UInt8(ascii: "0") {
            return allowZero && bytes.count == 1 ? 0 : nil
        }
        return Int64(raw)
    }
}

/// The wire `Instant` without a date formatter: exact `YYYY-MM-DDTHH:MM:SSZ`, real calendar dates
/// only (no Feb 30, no leap second), converted with Howard Hinnant's civil-day algorithms.
enum SGTasksCivilTime {
    /// 0000-01-01T00:00:00Z and 9999-12-31T23:59:59Z.
    static let minimumEpochSeconds: Int64 = -62_167_219_200
    static let maximumEpochSeconds: Int64 = 253_402_300_799

    static func epochSeconds(_ raw: String) -> Int64? {
        let bytes = Array(raw.utf8)
        guard bytes.count == 20, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: "Z") else {
            return nil
        }
        func number(_ range: Range<Int>) -> Int64? {
            var value: Int64 = 0
            for index in range {
                let byte = bytes[index]
                guard (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) else {
                    return nil
                }
                value = value * 10 + Int64(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0 ..< 4), let month = number(5 ..< 7), let day = number(8 ..< 10), let hour = number(11 ..< 13), let minute = number(14 ..< 16), let second = number(17 ..< 19) else {
            return nil
        }
        guard (1 ... 12).contains(month), day >= 1, day <= self.daysInMonth(year: year, month: month), hour <= 23, minute <= 59, second <= 59 else {
            return nil
        }
        return self.daysFromCivil(year: year, month: month, day: day) * 86400 + hour * 3600 + minute * 60 + second
    }

    static func format(_ seconds: Int64) -> String {
        var days = seconds / 86400
        var remainder = seconds % 86400
        if remainder < 0 {
            remainder += 86400
            days -= 1
        }
        let (year, month, day) = self.civilFromDays(days)
        func pad(_ value: Int64, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(remainder / 3600, 2)):\(pad(remainder % 3600 / 60, 2)):\(pad(remainder % 60, 2))Z"
    }

    private static func isLeap(_ year: Int64) -> Bool {
        return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysInMonth(year: Int64, month: Int64) -> Int64 {
        switch month {
        case 2:
            return self.isLeap(year) ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (month <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, month, day)
    }
}
