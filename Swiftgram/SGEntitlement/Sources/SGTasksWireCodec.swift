import Foundation

/// Zenlygram — maps `SGTasksJSON.Value` to and from the `SGTasksWire` types, exactly as the wire's
/// `$defs` say: every listed key required (nullable means an explicit `null`), no other key allowed,
/// `kind` / `action` / enum strings exact, and the schema's conditional rules enforced. Field PATHS
/// go into `ValidationError`; values never do.
enum SGTasksWireCodec {
    typealias Value = SGTasksJSON.Value
    typealias Member = SGTasksJSON.Member
    typealias ValidationError = SGTasksWire.ValidationError

    // MARK: - Reading

    /// One JSON object whose key set is exactly `required` plus any of `optional`.
    struct Reader {
        let path: String
        private let fields: [String: Value]

        init(_ value: Value, path: String, required: [String], optional: [String] = []) throws {
            guard case let .object(members) = value else {
                throw ValidationError(path: path)
            }
            var fields: [String: Value] = [:]
            for member in members {
                fields[member.name] = member.value
            }
            let allowed = Set(required).union(optional)
            guard required.allSatisfy({ fields[$0] != nil }), fields.keys.allSatisfy({ allowed.contains($0) }) else {
                throw ValidationError(path: path)
            }
            self.path = path
            self.fields = fields
        }

        func has(_ key: String) -> Bool {
            return self.fields[key] != nil
        }

        func value(_ key: String) throws -> Value {
            guard let value = self.fields[key] else {
                throw ValidationError(path: self.path + "." + key)
            }
            return value
        }

        func isNull(_ key: String) throws -> Bool {
            if case .null = try self.value(key) {
                return true
            }
            return false
        }

        func string(_ key: String) throws -> String {
            guard case let .string(text) = try self.value(key) else {
                throw ValidationError(path: self.path + "." + key)
            }
            return text
        }

        func nullableString(_ key: String) throws -> String? {
            return try self.isNull(key) ? nil : try self.string(key)
        }

        func constant(_ key: String, _ expected: String) throws {
            guard try self.string(key) == expected else {
                throw ValidationError(path: self.path + "." + key)
            }
        }

        func integer(_ key: String) throws -> Int64 {
            guard case let .integer(number) = try self.value(key) else {
                throw ValidationError(path: self.path + "." + key)
            }
            return number
        }

        func int32(_ key: String) throws -> Int32 {
            guard let number = Int32(exactly: try self.integer(key)) else {
                throw ValidationError(path: self.path + "." + key)
            }
            return number
        }

        func deadline(_ key: String) throws -> SGTasksWire.Deadline? {
            if try self.isNull(key) {
                return nil
            }
            let number = try self.int32(key)
            guard number >= 0 else {
                throw ValidationError(path: self.path + "." + key)
            }
            return number
        }

        func bool(_ key: String) throws -> Bool {
            guard case let .bool(flag) = try self.value(key) else {
                throw ValidationError(path: self.path + "." + key)
            }
            return flag
        }

        func array(_ key: String, maxCount: Int) throws -> [Value] {
            guard case let .array(elements) = try self.value(key), elements.count <= maxCount else {
                throw ValidationError(path: self.path + "." + key)
            }
            return elements
        }

        func scalar<T>(_ key: String, _ make: (String) -> T?) throws -> T {
            guard let value = make(try self.string(key)) else {
                throw ValidationError(path: self.path + "." + key)
            }
            return value
        }

        func nullableScalar<T>(_ key: String, _ make: (String) -> T?) throws -> T? {
            return try self.isNull(key) ? nil : try self.scalar(key, make)
        }

        func enumeration<T: RawRepresentable>(_ key: String, _ type: T.Type) throws -> T where T.RawValue == String {
            return try self.scalar(key, { T(rawValue: $0) })
        }

        func uuid(_ key: String) throws -> SGTasksWire.UUID {
            return try self.scalar(key, SGTasksWire.UUID.init)
        }

        func nullableUUID(_ key: String) throws -> SGTasksWire.UUID? {
            return try self.nullableScalar(key, SGTasksWire.UUID.init)
        }

        func revision(_ key: String) throws -> SGTasksWire.Revision {
            return try self.scalar(key, SGTasksWire.Revision.init)
        }

        func telegramId(_ key: String) throws -> SGTasksWire.TelegramId {
            return try self.scalar(key, { SGTasksWire.TelegramId($0) })
        }

        func instant(_ key: String) throws -> SGTasksWire.Instant {
            return try self.scalar(key, { SGTasksWire.Instant($0) })
        }

        func nullableInstant(_ key: String) throws -> SGTasksWire.Instant? {
            return try self.nullableScalar(key, { SGTasksWire.Instant($0) })
        }

        func cursor(_ key: String) throws -> SGTasksWire.Cursor {
            return try self.scalar(key, SGTasksWire.Cursor.init)
        }

        func schemaVersion() throws {
            guard try self.integer("schema_version") == SGTasksWire.schemaVersion else {
                throw ValidationError(path: self.path + ".schema_version")
            }
        }
    }

    // MARK: - Writing helpers

    private static func string(_ text: String) -> Value {
        return .string(text)
    }

    private static func nullable<T>(_ value: T?, _ map: (T) -> Value) -> Value {
        return value.map(map) ?? .null
    }

    private static func integer<T: BinaryInteger>(_ number: T) -> Value {
        return .integer(Int64(number))
    }

    private static func object(_ pairs: [(String, Value)]) -> Value {
        return .object(pairs.map { Member(name: $0.0, value: $0.1) })
    }

    // MARK: - Content

    static func annotationValue(_ annotation: SGTasksWire.Annotation) -> Value {
        return self.object([
            ("telegram_user_id", .string(annotation.telegramUserId.rawValue)),
            ("display_name", .string(annotation.displayName))
        ])
    }

    static func contentValue(_ content: SGTasksWire.Content) -> Value {
        return self.object([
            ("list_id", self.nullable(content.listId) { .string($0.rawValue) }),
            ("title", .string(content.title)),
            ("description", self.nullable(content.description) { .string($0) }),
            ("due_at", self.nullable(content.dueAt) { self.integer($0) }),
            ("priority", self.integer(content.priority)),
            ("sort_order", self.integer(content.sortOrder)),
            ("annotation", self.nullable(content.annotation, self.annotationValue))
        ])
    }

    /// `content_order` / `annotation_order` of the business hash.
    static func contentArguments(_ content: SGTasksWire.Content) -> Value {
        return .array([
            self.nullable(content.listId) { .string($0.rawValue) },
            .string(content.title),
            self.nullable(content.description) { .string($0) },
            self.nullable(content.dueAt) { self.integer($0) },
            self.integer(content.priority),
            self.integer(content.sortOrder),
            self.nullable(content.annotation) { .array([.string($0.telegramUserId.rawValue), .string($0.displayName)]) }
        ])
    }

    /// A nullable `Annotation` under `key`.
    static func decodeAnnotation(_ reader: Reader, _ key: String) throws -> SGTasksWire.Annotation? {
        if try reader.isNull(key) {
            return nil
        }
        let inner = try Reader(try reader.value(key), path: reader.path + "." + key, required: ["telegram_user_id", "display_name"])
        return SGTasksWire.Annotation(telegramUserId: try inner.telegramId("telegram_user_id"), displayName: try inner.string("display_name"))
    }

    static func decodeContent(_ value: Value, path: String) throws -> SGTasksWire.Content {
        let reader = try Reader(value, path: path, required: ["list_id", "title", "description", "due_at", "priority", "sort_order", "annotation"])
        let annotation = try self.decodeAnnotation(reader, "annotation")
        let priority = try reader.integer("priority")
        guard (0 ... 4).contains(priority) else {
            throw ValidationError(path: path + ".priority")
        }
        let content = SGTasksWire.Content(
            listId: try reader.nullableUUID("list_id"),
            title: try reader.string("title"),
            description: try reader.nullableString("description"),
            dueAt: try reader.deadline("due_at"),
            priority: Int(priority),
            sortOrder: try reader.int32("sort_order"),
            annotation: annotation
        )
        try SGTasksWireValidation.validate(content, level: .structural, path: path)
        return content
    }

    // MARK: - Operations

    static func mutationValue(mutationId: SGTasksWire.UUID, operation: SGTasksWire.Operation) -> Value {
        return self.object([
            ("schema_version", .integer(SGTasksWire.schemaVersion)),
            ("mutation_id", .string(mutationId.rawValue)),
            ("operation", self.operationValue(operation))
        ])
    }

    static func operationValue(_ operation: SGTasksWire.Operation) -> Value {
        let kind: (String, Value) = ("kind", .string(operation.kind.rawValue))
        switch operation {
        case let .listCreate(op):
            return self.object([kind, ("list_id", .string(op.listId.rawValue)), ("title", .string(op.title)), ("sort_order", self.integer(op.sortOrder)), ("created_at", self.nullable(op.createdAt) { .string($0.rawValue) })])
        case let .listUpdate(op):
            return self.object([kind, ("list_id", .string(op.listId.rawValue)), ("base_revision", .string(op.baseRevision.rawValue)), ("title", .string(op.title)), ("sort_order", self.integer(op.sortOrder))])
        case let .listDelete(op):
            var pairs: [(String, Value)] = [kind, ("list_id", .string(op.listId.rawValue)), ("base_revision", .string(op.baseRevision.rawValue))]
            if let members = op.baseMembersRevision {
                pairs.append(("base_members_revision", .string(members.rawValue)))
            }
            return self.object(pairs)
        case let .taskCreate(op):
            return self.object([kind, ("task_id", .string(op.taskId.rawValue)), ("content", self.contentValue(op.content)), ("created_at", self.nullable(op.createdAt) { .string($0.rawValue) }), ("is_completed", .bool(op.isCompleted)), ("completed_at", self.nullable(op.completedAt) { .string($0.rawValue) })])
        case let .taskUpdate(op):
            return self.object([kind, ("task_id", .string(op.taskId.rawValue)), ("base_revision", .string(op.baseRevision.rawValue)), ("content", self.contentValue(op.content))])
        case let .taskComplete(op):
            return self.object([kind, ("task_id", .string(op.taskId.rawValue)), ("base_revision", .string(op.baseRevision.rawValue)), ("invitation_id", self.nullable(op.invitationId) { .string($0.rawValue) }), ("is_completed", .bool(op.isCompleted))])
        case let .taskDelete(op):
            return self.object([kind, ("task_id", .string(op.taskId.rawValue)), ("base_revision", .string(op.baseRevision.rawValue))])
        case let .inviteRequest(op):
            return self.object([kind, ("task_id", .string(op.taskId.rawValue)), ("base_revision", .string(op.baseRevision.rawValue)), ("invitation_id", .string(op.invitationId.rawValue)), ("recipient_tg_id", .string(op.recipientTgId.rawValue))])
        case let .inviteRespond(op):
            return self.object([kind, ("task_id", .string(op.taskId.rawValue)), ("base_revision", .string(op.baseRevision.rawValue)), ("invitation_id", .string(op.invitationId.rawValue)), ("decision", .string(op.decision.rawValue))])
        case let .inviteRevoke(op):
            return self.object([kind, ("task_id", .string(op.taskId.rawValue)), ("base_revision", .string(op.baseRevision.rawValue)), ("invitation_id", .string(op.invitationId.rawValue))])
        case let .senderBlock(op):
            return self.object([kind, ("invitation_id", .string(op.invitationId.rawValue))])
        case let .senderUnblock(op):
            return self.object([kind, ("sender_tg_id", .string(op.senderTgId.rawValue))])
        }
    }

    /// `x-mutation-identity.arguments`, in exactly that order.
    static func orderedArguments(_ operation: SGTasksWire.Operation) -> Value {
        switch operation {
        case let .listCreate(op):
            return .array([.string(op.listId.rawValue), .string(op.title), self.integer(op.sortOrder), self.nullable(op.createdAt) { .string($0.rawValue) }])
        case let .listUpdate(op):
            return .array([.string(op.listId.rawValue), .string(op.baseRevision.rawValue), .string(op.title), self.integer(op.sortOrder)])
        case let .listDelete(op):
            // `base_members_revision` only when present (R4): an R3 delete hashes as before.
            var arguments: [Value] = [.string(op.listId.rawValue), .string(op.baseRevision.rawValue)]
            if let members = op.baseMembersRevision {
                arguments.append(.string(members.rawValue))
            }
            return .array(arguments)
        case let .taskCreate(op):
            return .array([.string(op.taskId.rawValue), self.contentArguments(op.content), self.nullable(op.createdAt) { .string($0.rawValue) }, .bool(op.isCompleted), self.nullable(op.completedAt) { .string($0.rawValue) }])
        case let .taskUpdate(op):
            return .array([.string(op.taskId.rawValue), .string(op.baseRevision.rawValue), self.contentArguments(op.content)])
        case let .taskComplete(op):
            return .array([.string(op.taskId.rawValue), .string(op.baseRevision.rawValue), self.nullable(op.invitationId) { .string($0.rawValue) }, .bool(op.isCompleted)])
        case let .taskDelete(op):
            return .array([.string(op.taskId.rawValue), .string(op.baseRevision.rawValue)])
        case let .inviteRequest(op):
            return .array([.string(op.taskId.rawValue), .string(op.baseRevision.rawValue), .string(op.invitationId.rawValue), .string(op.recipientTgId.rawValue)])
        case let .inviteRespond(op):
            return .array([.string(op.taskId.rawValue), .string(op.baseRevision.rawValue), .string(op.invitationId.rawValue), .string(op.decision.rawValue)])
        case let .inviteRevoke(op):
            return .array([.string(op.taskId.rawValue), .string(op.baseRevision.rawValue), .string(op.invitationId.rawValue)])
        case let .senderBlock(op):
            return .array([.string(op.invitationId.rawValue)])
        case let .senderUnblock(op):
            return .array([.string(op.senderTgId.rawValue)])
        }
    }

    static func decodeMutation(_ value: Value) throws -> (SGTasksWire.UUID, SGTasksWire.Operation) {
        let reader = try Reader(value, path: "mutation", required: ["schema_version", "mutation_id", "operation"])
        try reader.schemaVersion()
        return (try reader.uuid("mutation_id"), try self.decodeOperation(try reader.value("operation"), path: "mutation.operation"))
    }

    static func decodeOperation(_ value: Value, path: String) throws -> SGTasksWire.Operation {
        guard case let .object(members) = value, let kindValue = members.first(where: { $0.name == "kind" })?.value, case let .string(rawKind) = kindValue, let kind = SGTasksWire.OperationKind(rawValue: rawKind) else {
            throw ValidationError(path: path + ".kind")
        }
        func reader(_ fields: [String], optional: [String] = []) throws -> Reader {
            return try Reader(value, path: path, required: ["kind"] + fields, optional: optional)
        }
        switch kind {
        case .listCreate:
            let r = try reader(["list_id", "title", "sort_order", "created_at"])
            return .listCreate(SGTasksWire.ListCreate(listId: try r.uuid("list_id"), title: try r.string("title"), sortOrder: try r.int32("sort_order"), createdAt: try r.nullableInstant("created_at")))
        case .listUpdate:
            let r = try reader(["list_id", "base_revision", "title", "sort_order"])
            return .listUpdate(SGTasksWire.ListUpdate(listId: try r.uuid("list_id"), baseRevision: try r.revision("base_revision"), title: try r.string("title"), sortOrder: try r.int32("sort_order")))
        case .listDelete:
            let r = try reader(["list_id", "base_revision"], optional: ["base_members_revision"])
            let members = r.has("base_members_revision") ? try r.revision("base_members_revision") : nil
            return .listDelete(SGTasksWire.ListDelete(listId: try r.uuid("list_id"), baseRevision: try r.revision("base_revision"), baseMembersRevision: members))
        case .taskCreate:
            let r = try reader(["task_id", "content", "created_at", "is_completed", "completed_at"])
            return .taskCreate(SGTasksWire.TaskCreate(taskId: try r.uuid("task_id"), content: try self.decodeContent(try r.value("content"), path: path + ".content"), createdAt: try r.nullableInstant("created_at"), isCompleted: try r.bool("is_completed"), completedAt: try r.nullableInstant("completed_at")))
        case .taskUpdate:
            let r = try reader(["task_id", "base_revision", "content"])
            return .taskUpdate(SGTasksWire.TaskUpdate(taskId: try r.uuid("task_id"), baseRevision: try r.revision("base_revision"), content: try self.decodeContent(try r.value("content"), path: path + ".content")))
        case .taskComplete:
            let r = try reader(["task_id", "base_revision", "invitation_id", "is_completed"])
            return .taskComplete(SGTasksWire.TaskComplete(taskId: try r.uuid("task_id"), baseRevision: try r.revision("base_revision"), invitationId: try r.nullableUUID("invitation_id"), isCompleted: try r.bool("is_completed")))
        case .taskDelete:
            let r = try reader(["task_id", "base_revision"])
            return .taskDelete(SGTasksWire.TaskDelete(taskId: try r.uuid("task_id"), baseRevision: try r.revision("base_revision")))
        case .inviteRequest:
            let r = try reader(["task_id", "base_revision", "invitation_id", "recipient_tg_id"])
            return .inviteRequest(SGTasksWire.InviteRequest(taskId: try r.uuid("task_id"), baseRevision: try r.revision("base_revision"), invitationId: try r.uuid("invitation_id"), recipientTgId: try r.telegramId("recipient_tg_id")))
        case .inviteRespond:
            let r = try reader(["task_id", "base_revision", "invitation_id", "decision"])
            return .inviteRespond(SGTasksWire.InviteRespond(taskId: try r.uuid("task_id"), baseRevision: try r.revision("base_revision"), invitationId: try r.uuid("invitation_id"), decision: try r.enumeration("decision", SGTasksWire.InviteDecision.self)))
        case .inviteRevoke:
            let r = try reader(["task_id", "base_revision", "invitation_id"])
            return .inviteRevoke(SGTasksWire.InviteRevoke(taskId: try r.uuid("task_id"), baseRevision: try r.revision("base_revision"), invitationId: try r.uuid("invitation_id")))
        case .senderBlock:
            let r = try reader(["invitation_id"])
            return .senderBlock(SGTasksWire.SenderBlock(invitationId: try r.uuid("invitation_id")))
        case .senderUnblock:
            let r = try reader(["sender_tg_id"])
            return .senderUnblock(SGTasksWire.SenderUnblock(senderTgId: try r.telegramId("sender_tg_id")))
        }
    }

    /// The `operation.kind` string of a `mutation` object, or nil.
    static func operationKind(ofMutation value: Value) -> String? {
        guard case let .object(members) = value, case let .object(operation)? = members.first(where: { $0.name == "operation" })?.value, case let .string(kind)? = operation.first(where: { $0.name == "kind" })?.value else {
            return nil
        }
        return kind
    }

    // MARK: - task.patch (R4)

    /// A field value as it travels in `set` / `expect`: exactly its `Content` encoding.
    static func fieldValue(_ value: SGTasksWire.FieldValue) -> Value {
        switch value {
        case let .listId(listId):
            return self.nullable(listId) { .string($0.rawValue) }
        case let .title(title):
            return .string(title)
        case let .description(description):
            return self.nullable(description) { .string($0) }
        case let .dueAt(dueAt):
            return self.nullable(dueAt) { self.integer($0) }
        case let .priority(priority):
            return self.integer(priority)
        case let .sortOrder(sortOrder):
            return self.integer(sortOrder)
        case let .annotation(annotation):
            return self.nullable(annotation, self.annotationValue)
        }
    }

    /// The same value in the business hash: an annotation as `annotation_order`.
    static func fieldArgument(_ value: SGTasksWire.FieldValue) -> Value {
        if case let .annotation(annotation) = value {
            return self.nullable(annotation) { .array([.string($0.telegramUserId.rawValue), .string($0.displayName)]) }
        }
        return self.fieldValue(value)
    }

    /// `set` / `expect` as an object, keys in content order (the canonical sealed form).
    static func patchFieldsValue(_ fields: [SGTasksWire.ContentField: SGTasksWire.FieldValue]) -> Value {
        return .object(SGTasksWire.ContentField.allCases.compactMap { field in
            return fields[field].map { Member(name: field.rawValue, value: self.fieldValue($0)) }
        })
    }

    /// `[[field, value], …]` in content order.
    static func patchFieldsArguments(_ fields: [SGTasksWire.ContentField: SGTasksWire.FieldValue]) -> Value {
        return .array(SGTasksWire.ContentField.allCases.compactMap { field in
            return fields[field].map { .array([.string(field.rawValue), self.fieldArgument($0)]) }
        })
    }

    static func patchValue(_ patch: SGTasksWire.TaskPatch) -> Value {
        return self.object([("kind", .string(SGTasksWire.MutationKind.taskPatch.rawValue)), ("task_id", .string(patch.taskId.rawValue)), ("set", self.patchFieldsValue(patch.set)), ("expect", self.patchFieldsValue(patch.expect))])
    }

    static func patchMutationValue(mutationId: SGTasksWire.UUID, patch: SGTasksWire.TaskPatch) -> Value {
        return self.object([
            ("schema_version", .integer(SGTasksWire.schemaVersion)),
            ("mutation_id", .string(mutationId.rawValue)),
            ("operation", self.patchValue(patch))
        ])
    }

    /// `x-mutation-identity.arguments["task.patch"]`: `[task_id, set pairs, expect pairs]`.
    static func patchArguments(_ patch: SGTasksWire.TaskPatch) -> Value {
        return .array([.string(patch.taskId.rawValue), self.patchFieldsArguments(patch.set), self.patchFieldsArguments(patch.expect)])
    }

    static func decodePatchMutation(_ value: Value) throws -> (SGTasksWire.UUID, SGTasksWire.TaskPatch) {
        let reader = try Reader(value, path: "mutation", required: ["schema_version", "mutation_id", "operation"])
        try reader.schemaVersion()
        return (try reader.uuid("mutation_id"), try self.decodePatch(try reader.value("operation"), path: "mutation.operation"))
    }

    static func decodePatch(_ value: Value, path: String) throws -> SGTasksWire.TaskPatch {
        let r = try Reader(value, path: path, required: ["kind", "task_id", "set", "expect"])
        try r.constant("kind", SGTasksWire.MutationKind.taskPatch.rawValue)
        return SGTasksWire.TaskPatch(
            taskId: try r.uuid("task_id"),
            set: try self.decodePatchFields(try r.value("set"), path: path + ".set"),
            expect: try self.decodePatchFields(try r.value("expect"), path: path + ".expect")
        )
    }

    /// `$defs.PatchFields`: a non-empty object of `ContentField` keys, each value of its field's
    /// type (the text rules are `SGTasksWireValidation`'s).
    static func decodePatchFields(_ value: Value, path: String) throws -> [SGTasksWire.ContentField: SGTasksWire.FieldValue] {
        let r = try Reader(value, path: path, required: [], optional: SGTasksWire.ContentField.allCases.map { $0.rawValue })
        var fields: [SGTasksWire.ContentField: SGTasksWire.FieldValue] = [:]
        for field in SGTasksWire.ContentField.allCases where r.has(field.rawValue) {
            let key = field.rawValue
            switch field {
            case .listId:
                fields[field] = .listId(try r.nullableUUID(key))
            case .title:
                fields[field] = .title(try r.string(key))
            case .description:
                fields[field] = .description(try r.nullableString(key))
            case .dueAt:
                fields[field] = .dueAt(try r.deadline(key))
            case .priority:
                let priority = try r.integer(key)
                guard (0 ... 4).contains(priority) else {
                    throw ValidationError(path: path + "." + key)
                }
                fields[field] = .priority(Int(priority))
            case .sortOrder:
                fields[field] = .sortOrder(try r.int32(key))
            case .annotation:
                fields[field] = .annotation(try self.decodeAnnotation(r, key))
            }
        }
        guard !fields.isEmpty else {
            throw ValidationError(path: path)
        }
        return fields
    }

    // MARK: - Projections

    static func projectionValue(_ projection: SGTasksWire.Projection) -> Value {
        switch projection {
        case let .list(list):
            var pairs: [(String, Value)] = [("kind", .string("list")), ("id", .string(list.id.rawValue)), ("revision", .string(list.revision.rawValue))]
            if let members = list.membersRevision {
                pairs.append(("members_revision", .string(members.rawValue)))
            }
            pairs += [("title", .string(list.title)), ("sort_order", self.integer(list.sortOrder)), ("created_at", .string(list.createdAt.rawValue)), ("updated_at", .string(list.updatedAt.rawValue))]
            return self.object(pairs)
        case let .task(task):
            let assignment = self.nullable(task.assignment) { assignment in
                self.object([("invitation_id", .string(assignment.invitationId.rawValue)), ("recipient_tg_id", .string(assignment.recipientTgId.rawValue)), ("state", .string(assignment.state.rawValue)), ("expires_at", .string(assignment.expiresAt.rawValue))])
            }
            return self.object([("kind", .string("task")), ("id", .string(task.id.rawValue)), ("revision", .string(task.revision.rawValue)), ("owner_tg_id", .string(task.ownerTgId.rawValue)), ("viewer_role", .string(task.viewerRole.rawValue)), ("content", self.contentValue(task.content)), ("is_completed", .bool(task.isCompleted)), ("completed_at", self.nullable(task.completedAt) { .string($0.rawValue) }), ("created_at", .string(task.createdAt.rawValue)), ("updated_at", .string(task.updatedAt.rawValue)), ("assignment", assignment)])
        case let .invitation(invitation):
            return self.object([("kind", .string("invitation")), ("id", .string(invitation.id.rawValue)), ("task_id", .string(invitation.taskId.rawValue)), ("task_revision", .string(invitation.taskRevision.rawValue)), ("owner_tg_id", .string(invitation.ownerTgId.rawValue)), ("title", .string(invitation.title)), ("due_at", self.nullable(invitation.dueAt) { self.integer($0) }), ("expires_at", .string(invitation.expiresAt.rawValue))])
        case let .block(block):
            return self.object([("kind", .string("block")), ("id", .string(block.id.rawValue)), ("created_at", .string(block.createdAt.rawValue))])
        }
    }

    static func decodeProjection(_ value: Value, path: String) throws -> SGTasksWire.Projection {
        guard case let .object(members) = value, let kindValue = members.first(where: { $0.name == "kind" })?.value, case let .string(kind) = kindValue else {
            throw ValidationError(path: path + ".kind")
        }
        switch kind {
        case "list":
            // `members_revision` is `$defs.ListR4` (an R4 server always sends it, an R3 one never).
            let r = try Reader(value, path: path, required: ["kind", "id", "revision", "title", "sort_order", "created_at", "updated_at"], optional: ["members_revision"])
            let title = try r.string("title")
            try SGTasksWireValidation.check(title, SGTasksWireValidation.listTitle, level: .structural, path: path + ".title")
            let members = r.has("members_revision") ? try r.revision("members_revision") : nil
            return .list(SGTasksWire.List(id: try r.uuid("id"), revision: try r.revision("revision"), title: title, sortOrder: try r.int32("sort_order"), createdAt: try r.instant("created_at"), updatedAt: try r.instant("updated_at"), membersRevision: members))
        case "task":
            return .task(try self.decodeTask(value, path: path))
        case "invitation":
            let r = try Reader(value, path: path, required: ["kind", "id", "task_id", "task_revision", "owner_tg_id", "title", "due_at", "expires_at"])
            let title = try r.string("title")
            try SGTasksWireValidation.check(title, SGTasksWireValidation.taskTitle, level: .structural, path: path + ".title")
            return .invitation(SGTasksWire.Invitation(id: try r.uuid("id"), taskId: try r.uuid("task_id"), taskRevision: try r.revision("task_revision"), ownerTgId: try r.telegramId("owner_tg_id"), title: title, dueAt: try r.deadline("due_at"), expiresAt: try r.instant("expires_at")))
        case "block":
            let r = try Reader(value, path: path, required: ["kind", "id", "created_at"])
            return .block(SGTasksWire.Block(id: try r.telegramId("id"), createdAt: try r.instant("created_at")))
        default:
            throw ValidationError(path: path + ".kind")
        }
    }

    private static func decodeTask(_ value: Value, path: String) throws -> SGTasksWire.Task {
        let r = try Reader(value, path: path, required: ["kind", "id", "revision", "owner_tg_id", "viewer_role", "content", "is_completed", "completed_at", "created_at", "updated_at", "assignment"])
        let assignment: SGTasksWire.Assignment?
        if try r.isNull("assignment") {
            assignment = nil
        } else {
            let a = try Reader(try r.value("assignment"), path: path + ".assignment", required: ["invitation_id", "recipient_tg_id", "state", "expires_at"])
            assignment = SGTasksWire.Assignment(invitationId: try a.uuid("invitation_id"), recipientTgId: try a.telegramId("recipient_tg_id"), state: try a.enumeration("state", SGTasksWire.AssignmentState.self), expiresAt: try a.instant("expires_at"))
        }
        let task = SGTasksWire.Task(
            id: try r.uuid("id"),
            revision: try r.revision("revision"),
            ownerTgId: try r.telegramId("owner_tg_id"),
            viewerRole: try r.enumeration("viewer_role", SGTasksWire.ViewerRole.self),
            content: try self.decodeContent(try r.value("content"), path: path + ".content"),
            isCompleted: try r.bool("is_completed"),
            completedAt: try r.nullableInstant("completed_at"),
            createdAt: try r.instant("created_at"),
            updatedAt: try r.instant("updated_at"),
            assignment: assignment
        )
        // An assignee sees no owner list, no private annotation, and only an accepted assignment.
        if task.viewerRole == .assignee {
            guard task.content.listId == nil, task.content.annotation == nil, task.assignment?.state == .accepted else {
                throw ValidationError(path: path + ".viewer_role")
            }
        }
        if !task.isCompleted && task.completedAt != nil {
            throw ValidationError(path: path + ".completed_at")
        }
        return task
    }

    // MARK: - Responses

    /// `serverWire` (every response decoder) is the answer's `X-Tasks-Wire` header, carried through.
    static func decodeMutationResponse(_ value: Value, serverWire: Int? = nil) throws -> SGTasksWire.MutationResponse {
        let r = try Reader(value, path: "response", required: ["schema_version", "receipt", "server_time"])
        try r.schemaVersion()
        return SGTasksWire.MutationResponse(
            receipt: try self.decodeReceipt(try r.value("receipt"), path: "response.receipt"),
            serverTime: try r.instant("server_time"),
            serverWire: serverWire
        )
    }

    static func decodeReceipt(_ value: Value, path p: String) throws -> SGTasksWire.Receipt {
        let receipt = try Reader(value, path: p, required: ["mutation_id", "operation", "outcome", "resource_kind", "resource_id", "resource_revision", "committed_at"])
        let operation = try receipt.enumeration("operation", SGTasksWire.MutationKind.self)
        let kind = try receipt.enumeration("resource_kind", SGTasksWire.ResourceKind.self)
        let rawId = try receipt.string("resource_id")
        let revision = try receipt.nullableScalar("resource_revision", SGTasksWire.Revision.init)
        // `x-mutation-identity.receipt_projection`: list.* names its list, task.* / invitation.* the
        // task, sender.* the inviter's Telegram id with no revision.
        let resourceId: SGTasksWire.ResourceId
        switch operation {
        case .operation(.senderBlock), .operation(.senderUnblock):
            guard kind == .block, let id = SGTasksWire.TelegramId(rawId), revision == nil else {
                throw ValidationError(path: p + ".resource_id")
            }
            resourceId = .telegramId(id)
        case .operation, .taskPatch:
            let listKinds: [SGTasksWire.MutationKind] = [.operation(.listCreate), .operation(.listUpdate), .operation(.listDelete)]
            let expected: SGTasksWire.ResourceKind = listKinds.contains(operation) ? .list : .task
            guard kind == expected, let id = SGTasksWire.UUID(rawId), revision != nil else {
                throw ValidationError(path: p + ".resource_id")
            }
            resourceId = .uuid(id)
        }
        return SGTasksWire.Receipt(
            mutationId: try receipt.uuid("mutation_id"),
            operation: operation,
            outcome: try receipt.enumeration("outcome", SGTasksWire.ReceiptOutcome.self),
            resourceKind: kind,
            resourceId: resourceId,
            resourceRevision: revision,
            committedAt: try receipt.instant("committed_at")
        )
    }

    /// The receipt is for THIS mutation: same id, same operation, and the resource it names is the
    /// one the operation targets (`x-mutation-identity.receipt_projection`).
    static func receipt(_ receipt: SGTasksWire.Receipt, answers mutation: SGTasksWire.SealedMutation) -> Bool {
        guard receipt.mutationId == mutation.mutationId, receipt.operation == mutation.kind else {
            return false
        }
        let request: SGTasksWire.MutationRequest
        switch mutation {
        case let .patch(patch):
            return receipt.resourceId == .uuid(patch.patch.taskId)
        case let .mutation(value):
            request = value
        }
        switch request.operation {
        case let .listCreate(op):
            return receipt.resourceId == .uuid(op.listId)
        case let .listUpdate(op):
            return receipt.resourceId == .uuid(op.listId)
        case let .listDelete(op):
            return receipt.resourceId == .uuid(op.listId)
        case let .taskCreate(op):
            return receipt.resourceId == .uuid(op.taskId)
        case let .taskUpdate(op):
            return receipt.resourceId == .uuid(op.taskId)
        case let .taskComplete(op):
            return receipt.resourceId == .uuid(op.taskId)
        case let .taskDelete(op):
            return receipt.resourceId == .uuid(op.taskId)
        case let .inviteRequest(op):
            return receipt.resourceId == .uuid(op.taskId)
        case let .inviteRespond(op):
            return receipt.resourceId == .uuid(op.taskId)
        case let .inviteRevoke(op):
            return receipt.resourceId == .uuid(op.taskId)
        case .senderBlock:
            // The inviter is resolved by the server from the invitation.
            if case .telegramId = receipt.resourceId {
                return true
            }
            return false
        case let .senderUnblock(op):
            return receipt.resourceId == .telegramId(op.senderTgId)
        }
    }

    static func decodeSnapshotResponse(_ value: Value, limit: Int, serverWire: Int? = nil) throws -> SGTasksWire.SnapshotResponse {
        let r = try Reader(value, path: "response", required: ["schema_version", "items", "next_cursor", "changes_cursor", "server_time"])
        try r.schemaVersion()
        let elements = try r.array("items", maxCount: min(limit, SGTasksWire.maxPageLimit))
        var items: [SGTasksWire.Projection] = []
        var seen = Set<String>()
        for (index, element) in elements.enumerated() {
            let item = try self.decodeProjection(element, path: "response.items[\(index)]")
            // A page is in stable (kind, id) order; one projection twice is not a page.
            guard seen.insert(self.identity(of: item)).inserted else {
                throw ValidationError(path: "response.items[\(index)]")
            }
            items.append(item)
        }
        return SGTasksWire.SnapshotResponse(
            items: items,
            nextCursor: try r.nullableScalar("next_cursor", SGTasksWire.Cursor.init),
            changesCursor: try r.cursor("changes_cursor"),
            serverTime: try r.instant("server_time"),
            serverWire: serverWire
        )
    }

    static func decodeChangesResponse(_ value: Value, limit: Int, serverWire: Int? = nil) throws -> SGTasksWire.ChangesResponse {
        let r = try Reader(value, path: "response", required: ["schema_version", "changes", "next_cursor", "has_more", "server_time"])
        try r.schemaVersion()
        let elements = try r.array("changes", maxCount: min(limit, SGTasksWire.maxPageLimit))
        var changes: [SGTasksWire.Change] = []
        for (index, element) in elements.enumerated() {
            let change = try self.decodeChange(element, path: "response.changes[\(index)]")
            // Positions are unique committed sequences returned ascending.
            if let previous = changes.last, !(previous.position < change.position) {
                throw ValidationError(path: "response.changes[\(index)].position")
            }
            changes.append(change)
        }
        return SGTasksWire.ChangesResponse(changes: changes, nextCursor: try r.cursor("next_cursor"), hasMore: try r.bool("has_more"), serverTime: try r.instant("server_time"), serverWire: serverWire)
    }

    private static func decodeChange(_ value: Value, path: String) throws -> SGTasksWire.Change {
        guard case let .object(members) = value, let actionValue = members.first(where: { $0.name == "action" })?.value, case let .string(action) = actionValue else {
            throw ValidationError(path: path + ".action")
        }
        switch action {
        case "upsert":
            let r = try Reader(value, path: path, required: ["position", "action", "item"])
            return .upsert(position: try r.scalar("position", SGTasksWire.Sequence.init), item: try self.decodeProjection(try r.value("item"), path: path + ".item"))
        case "remove":
            let r = try Reader(value, path: path, required: ["position", "action", "kind", "id"])
            let position = try r.scalar("position", SGTasksWire.Sequence.init)
            let kind = try r.string("kind")
            let target: SGTasksWire.RemovalTarget
            switch kind {
            case "list":
                target = .list(try r.uuid("id"))
            case "task":
                target = .task(try r.uuid("id"))
            case "invitation":
                target = .invitation(try r.uuid("id"))
            case "block":
                target = .block(try r.telegramId("id"))
            default:
                throw ValidationError(path: path + ".kind")
            }
            return .remove(position: position, target: target)
        default:
            throw ValidationError(path: path + ".action")
        }
    }

    private static func identity(of projection: SGTasksWire.Projection) -> String {
        switch projection {
        case let .list(list):
            return "list:" + list.id.rawValue
        case let .task(task):
            return "task:" + task.id.rawValue
        case let .invitation(invitation):
            return "invitation:" + invitation.id.rawValue
        case let .block(block):
            return "block:" + block.id.rawValue
        }
    }

    /// The wire `Error` body, strictly (`$defs.Error` + `$defs.ErrorRules`). Middleware envelopes
    /// that are not this shape return nil and are classified by status (`SGTasksError`).
    static func decodeError(_ value: Value) -> SGTasksWire.Error? {
        guard let r = try? Reader(value, path: "error", required: ["error", "message", "server_time"], optional: ["reason", "fields", "effective_at"]),
              let code = try? r.string("error"), (1 ... 80).contains(code.unicodeScalars.count),
              let message = try? r.string("message"), message.unicodeScalars.count <= 256,
              let serverTime = try? r.instant("server_time"),
              let extras = self.errorExtras(code: code, reader: r) else {
            return nil
        }
        return SGTasksWire.Error(error: code, message: message, serverTime: serverTime, reason: extras.reason, fields: extras.fields, effectiveAt: extras.effectiveAt)
    }

    /// What `$defs.ErrorRules` governs in an error object, checked against its code.
    struct ErrorExtras: Equatable {
        let reason: SGTasksWire.ErrorReason?
        let fields: [SGTasksWire.ContentField]
        let effectiveAt: SGTasksWire.Instant?
    }

    /// `$defs.ErrorRules`, strictly: `tasks_conflict` requires one of the six conflict reasons,
    /// `tasks_consent_required` requires `withdrawn` and `effective_at`, `tasks_unavailable` allows
    /// `batch_disabled` / `migration_paused`, every other code carries no reason; `fields` exactly
    /// with `field_changed`, `effective_at` only with `tasks_consent_required`. nil when broken.
    static func errorExtras(code: String, reader r: Reader) -> ErrorExtras? {
        var reason: SGTasksWire.ErrorReason?
        if r.has("reason") {
            guard let value = try? r.enumeration("reason", SGTasksWire.ErrorReason.self) else {
                return nil
            }
            reason = value
        }
        switch code {
        case "tasks_conflict":
            guard let reason, SGTasksWire.ErrorReason.conflictReasons.contains(reason) else {
                return nil
            }
        case "tasks_consent_required":
            guard reason == .withdrawn, r.has("effective_at") else {
                return nil
            }
        case "tasks_unavailable":
            if let reason, !SGTasksWire.ErrorReason.unavailableReasons.contains(reason) {
                return nil
            }
        default:
            guard reason == nil else {
                return nil
            }
        }
        var effectiveAt: SGTasksWire.Instant?
        if r.has("effective_at") {
            guard code == "tasks_consent_required", let instant = try? r.instant("effective_at") else {
                return nil
            }
            effectiveAt = instant
        }
        var fields: [SGTasksWire.ContentField] = []
        if reason == .fieldChanged {
            guard let value = try? r.value("fields"), let parsed = self.conflictFields(value) else {
                return nil
            }
            fields = parsed
        } else if r.has("fields") {
            return nil
        }
        return ErrorExtras(reason: reason, fields: fields, effectiveAt: effectiveAt)
    }

    /// `$defs.Error.fields`: 1...7 distinct `ContentField`s, in content order.
    static func conflictFields(_ value: Value) -> [SGTasksWire.ContentField]? {
        guard case let .array(elements) = value, (1 ... SGTasksWire.ContentField.allCases.count).contains(elements.count) else {
            return nil
        }
        var fields: [SGTasksWire.ContentField] = []
        for element in elements {
            guard case let .string(raw) = element, let field = SGTasksWire.ContentField(rawValue: raw) else {
                return nil
            }
            if let last = fields.last, !(last < field) {
                return nil
            }
            fields.append(field)
        }
        return fields
    }

    // MARK: - Batch (R4)

    /// `$defs.BatchItemError`: the error object of one batch item — no `server_time` (the batch
    /// has one), `retry_after` (1...) only under 429 / 503.
    struct BatchItemError: Equatable {
        let code: String
        let extras: ErrorExtras
        let retryAfter: Int?
    }

    static func decodeBatchItemError(_ value: Value, status: Int, path: String) throws -> BatchItemError {
        let r = try Reader(value, path: path, required: ["error", "message"], optional: ["reason", "fields", "retry_after", "effective_at"])
        let code = try r.string("error")
        let message = try r.string("message")
        guard (1 ... 80).contains(code.unicodeScalars.count), message.unicodeScalars.count <= 256, let extras = self.errorExtras(code: code, reader: r) else {
            throw ValidationError(path: path)
        }
        var retryAfter: Int?
        if r.has("retry_after") {
            let seconds = try r.integer("retry_after")
            guard status == 429 || status == 503, seconds >= 1 else {
                throw ValidationError(path: path + ".retry_after")
            }
            retryAfter = Int(clamping: seconds)
        }
        return BatchItemError(code: code, extras: extras, retryAfter: retryAfter)
    }

    /// `BatchItemResult.status` of an error result.
    static let batchItemErrorStatuses: Set<Int64> = [401, 403, 404, 409, 422, 429, 503]

    /// A decoded batch answer plus what the transport still owes it.
    struct DecodedBatch {
        let response: SGTasksWire.MutationBatchResponse
        /// Item 401s of the DeviceAuth family (the principal merged or the binding revoked after
        /// authentication), applied like an envelope 401 to the captured credential.
        let sessionFailures: [SGEntitlementRequestError]
    }

    /// `$defs.BatchResponse`, strictly, as the answer to exactly `request`: the same `batch_id`,
    /// one result per item in the request's order and with its mutation id, every receipt for its
    /// own item's mutation, every error a valid `BatchItemError` under an item status.
    static func decodeBatchResponse(_ value: Value, request: SGTasksWire.MutationBatchRequest, serverWire: Int?) throws -> DecodedBatch {
        let r = try Reader(value, path: "response", required: ["schema_version", "batch_id", "results", "retry_after", "server_time"])
        try r.schemaVersion()
        guard try r.uuid("batch_id") == request.batchId else {
            throw ValidationError(path: "response.batch_id")
        }
        let serverTime = try r.instant("server_time")
        var retryAfter: Int?
        if try !r.isNull("retry_after") {
            let seconds = try r.integer("retry_after")
            guard seconds >= 1 else {
                throw ValidationError(path: "response.retry_after")
            }
            retryAfter = min(Int(clamping: seconds), SGTasksErrorClassifier.maxRetryAfter)
        }
        let elements = try r.array("results", maxCount: SGTasksWire.maxBatchItems)
        guard elements.count == request.items.count else {
            throw ValidationError(path: "response.results")
        }
        var results: [SGTasksWire.BatchItemResult] = []
        var sessionFailures: [SGEntitlementRequestError] = []
        for (index, element) in elements.enumerated() {
            let path = "response.results[\(index)]"
            let mutation = request.items[index].mutation
            guard case let .object(members) = element, let status = members.first(where: { $0.name == "status" })?.value else {
                throw ValidationError(path: path)
            }
            let fields: [String]
            switch status {
            case .integer(200):
                fields = ["mutation_id", "status", "receipt"]
            case .null:
                fields = ["mutation_id", "status", "skipped"]
            case let .integer(code) where self.batchItemErrorStatuses.contains(code):
                fields = ["mutation_id", "status", "error"]
            default:
                throw ValidationError(path: path + ".status")
            }
            let item = try Reader(element, path: path, required: fields)
            guard try item.uuid("mutation_id") == mutation.mutationId else {
                throw ValidationError(path: path + ".mutation_id")
            }
            switch status {
            case .integer(200):
                let receipt = try self.decodeReceipt(try item.value("receipt"), path: path + ".receipt")
                guard self.receipt(receipt, answers: mutation) else {
                    throw ValidationError(path: path + ".receipt")
                }
                results.append(.receipt(receipt))
            case let .integer(code):
                let itemStatus = Int(code)
                guard let classified = SGTasksErrorClassifier.classifyItem(status: itemStatus, error: try item.value("error"), serverTime: serverTime.date, retryAfter: retryAfter) else {
                    throw ValidationError(path: path + ".error")
                }
                if let session = classified.sessionError {
                    sessionFailures.append(session)
                }
                results.append(.error(status: itemStatus, classified.error))
            default:
                guard try item.bool("skipped") else {
                    throw ValidationError(path: path + ".skipped")
                }
                results.append(.skipped)
            }
        }
        return DecodedBatch(
            response: SGTasksWire.MutationBatchResponse(batchId: request.batchId, results: results, retryAfter: retryAfter, serverTime: serverTime, serverWire: serverWire),
            sessionFailures: sessionFailures
        )
    }

    /// The batch request body: `{"schema_version":1,"batch_id":"…","mutations":[item…]` +
    /// optional `,"creation_proof":{"jws":…}` + `}`. A `user` item is its sealed bytes unchanged, a
    /// `migration` item `{"origin":"migration",` + the sealed bytes without their first `{`, so the
    /// sealed bytes always travel byte for byte. `creationProof` (already length-checked by the
    /// caller) is added only with a create and only while the body stays within
    /// `maxBatchRequestBytes`: it is optional evidence, the items are not.
    static func batchBody(_ request: SGTasksWire.MutationBatchRequest, creationProof: String?) -> Data {
        var bytes = Array("{\"schema_version\":1,\"batch_id\":".utf8)
        SGTasksJSON.appendString(request.batchId.rawValue, to: &bytes)
        bytes.append(contentsOf: Array(",\"mutations\":[".utf8))
        for (index, item) in request.items.enumerated() {
            if index > 0 {
                bytes.append(UInt8(ascii: ","))
            }
            switch item.origin {
            case .user:
                bytes.append(contentsOf: item.mutation.wireJSON)
            case .migration:
                bytes.append(contentsOf: SGTasksWire.migrationOriginPrefix)
                bytes.append(contentsOf: item.mutation.wireJSON.dropFirst())
            }
        }
        bytes.append(UInt8(ascii: "]"))
        if let creationProof, request.containsCreation {
            var proof = Array(",\"creation_proof\":{\"jws\":".utf8)
            SGTasksJSON.appendString(creationProof, to: &proof)
            proof.append(UInt8(ascii: "}"))
            if bytes.count + proof.count + 1 <= SGTasksWire.maxBatchRequestBytes {
                bytes.append(contentsOf: proof)
            }
        }
        bytes.append(UInt8(ascii: "}"))
        return Data(bytes)
    }
}

extension SGTasksWire.Projection {
    /// Canonical bytes of this projection, for a persisted server shadow row.
    public var wireJSON: Data {
        return SGTasksJSON.encode(SGTasksWireCodec.projectionValue(self))
    }

    /// Strict decode of `wireJSON` (the same rules as a snapshot item).
    public init(wireJSON: Data) throws {
        let value: SGTasksJSON.Value
        do {
            value = try SGTasksJSON.parse(wireJSON, maxBytes: SGTasksWireCodec.maxProjectionBytes, maxDepth: SGTasksWire.maxDepth)
        } catch {
            throw SGTasksWire.ValidationError(path: "item")
        }
        self = try SGTasksWireCodec.decodeProjection(value, path: "item")
    }
}

extension SGTasksWireCodec {
    /// One projection's ceiling: the largest task (8192 + 16384 + 4096 scalars of up to 4 bytes,
    /// worst-case `\u00xx` escaping of C0 controls) stays far below this.
    static let maxProjectionBytes = 1 << 20
}
