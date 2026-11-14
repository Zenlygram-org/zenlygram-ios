import Foundation
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// MARK: - Zenlygram Tasks wf15 §7: the legacy assignee sheet's candidates (D4), pure
//
// "Eski (qurilmadagi) masʼullar": once, after the account's older device tasks are synced, the
// board asks "N ta vazifada masʼul bor — ularga yuborilsinmi?" (Yuborish / Keyinroq, never
// automatic). The sheet, `remaining` and the Lists entry cover DEVICE-ROW candidates only (§7.2
// item 1, revision 3): device tasks with a local assignee, joined through the account's import
// mappings of the current scope with the synced task they were copied to; kept while that task is
// the owner's, live, not completed, without a live (pending / accepted) assignment, and not in the
// durable sent set (§7.4). A task whose legacy Masʼul exists only as a server-side `annotation`
// written by an older client is never a sheet row (it would come back on every device and after
// the last logout); it keeps the per-task "Hali yuborilmagan · Yuborish" (`candidate(forCloudTaskId:)`).
//
// Everything here is a pure function of values the host reads: the device rows
// (`TodoDatabase.liveTasksWithAssignee()`), the mappings (`existingCloudImportMappings`), the
// repository's state, the account's own Telegram id and the sent set. Nothing is sent from here.

/// One device row of the sheet (§7.2 items 1, 3, 4): a synced task the row was copied to, the
/// row's title and owner-entered assignee name, and the recipient — nil when the local peer id
/// is not a Telegram user (listed greyed, `tasks_legacySheet_notSendable`); the account itself is
/// listed greyed too (`tasks_legacySheet_self`). Only the Telegram id is ever sent, never the name.
public struct SGTasksLegacyAssigneeCandidate: Equatable {
    public let cloudTaskId: SGTasksWire.UUID
    public let deviceTaskId: String
    public let title: String
    public let name: String
    public let recipient: SGTasksWire.TelegramId?
    public let isSelf: Bool

    public init(cloudTaskId: SGTasksWire.UUID, deviceTaskId: String, title: String, name: String, recipient: SGTasksWire.TelegramId?, isSelf: Bool) {
        self.cloudTaskId = cloudTaskId
        self.deviceTaskId = deviceTaskId
        self.title = title
        self.name = name
        self.recipient = recipient
        self.isSelf = isSelf
    }

    /// A row the sheet's Yuborish may send.
    public var isSendable: Bool {
        return self.recipient != nil && !self.isSelf
    }
}

/// The offer for one account at one moment.
public struct SGTasksLegacyAssigneeOffer: Equatable {
    /// The sheet's rows in their order (§7.2 item 4: the device row's `created_at`, then its id),
    /// greyed rows included; de-duplicated by cloud task id.
    public let candidates: [SGTasksLegacyAssigneeCandidate]
    /// §5.6 fallback (1): cloud task id → the owner-entered assignee of the device row mapped to it,
    /// for every mapped row whose id is a Telegram user (candidate or not).
    public let deviceAssignees: [String: TasksLegacyDeviceAssignee]

    public init(candidates: [SGTasksLegacyAssigneeCandidate], deviceAssignees: [String: TasksLegacyDeviceAssignee]) {
        self.candidates = candidates
        self.deviceAssignees = deviceAssignees
    }

    public static let empty = SGTasksLegacyAssigneeOffer(candidates: [], deviceAssignees: [:])

    /// The rows Yuborish may send, in order.
    public var sendable: [SGTasksLegacyAssigneeCandidate] {
        return self.candidates.filter { $0.isSendable }
    }

    /// `sgtasks.legacyAssignees.remaining.<accountPeerId>` (§7.4): the device-row candidates still
    /// unsent that a tap could send.
    public var remaining: Int {
        return self.sendable.count
    }

    /// §7.1: the sheet has something to offer.
    public var offersSheet: Bool {
        return self.remaining > 0
    }

    /// §7.2 item 3 (every row lists title → name: the confirmation is of the rows SHOWN): what
    /// Yuborish may send at the tap. `self` is the offer the sheet listed when it opened, `current`
    /// the offer recomputed at the tap. A listed row is sent only while it is still a sendable
    /// candidate with the same recipient (a row that stopped being one — assigned, completed, sent
    /// from its task meanwhile — is dropped); a task → person pair that became a candidate while the
    /// sheet was open (a sync landed) was never shown and is not sent — it keeps its per-task "Hali
    /// yuborilmagan · Yuborish" and the Lists entry, which opens a sheet that lists it. Sheet order.
    public func confirmedSendable(at current: SGTasksLegacyAssigneeOffer) -> [SGTasksLegacyAssigneeCandidate] {
        return self.sendable.compactMap { listed in
            current.sendable.first { $0.cloudTaskId == listed.cloudTaskId && $0.recipient == listed.recipient }
        }
    }

    // MARK: Candidates (§7.2 item 1)

    /// - Parameters:
    ///   - deviceRows: `TodoDatabase.liveTasksWithAssignee()` (any order; sorted here).
    ///   - mappings: `existingCloudImportMappings(accountPeerId:principalScope:)` of the CURRENT
    ///     import scope (a scope_changed account's old-scope mappings are not these).
    ///   - cloud: the repository's state (the shadow with the overlay: a queued pick shows as a
    ///     pending assignment and ends the candidacy).
    ///   - ownTelegramId: the account's own id (self rows are listed greyed).
    ///   - sentTaskIds: the durable sent set.
    ///   - serverNow: the estimated server time (a pending assignment past its expiry is ended).
    public static func compute(deviceRows: [TodoLiveAssigneeRow], mappings: [TodoCloudImportMapping], cloud: SGTasksCloudState, ownTelegramId: SGTasksWire.TelegramId?, sentTaskIds: Set<String>, serverNow: Date?) -> SGTasksLegacyAssigneeOffer {
        var mappingsByLegacyId: [String: [TodoCloudImportMapping]] = [:]
        for mapping in mappings where mapping.kind == .task {
            mappingsByLegacyId[mapping.legacyId, default: []].append(mapping)
        }
        var tasksById: [String: SGTasksCloudTask] = [:]
        for task in cloud.tasks {
            tasksById[task.id.rawValue] = task
        }
        let rows = deviceRows.sorted { lhs, rhs in
            if lhs.task.createdDate != rhs.task.createdDate {
                return lhs.task.createdDate < rhs.task.createdDate
            }
            return lhs.task.id < rhs.task.id
        }
        var deviceAssignees: [String: TasksLegacyDeviceAssignee] = [:]
        var candidates: [SGTasksLegacyAssigneeCandidate] = []
        var seen = Set<String>()
        for row in rows {
            guard let assignee = row.task.assignee, let rowMappings = mappingsByLegacyId[row.task.id], !rowMappings.isEmpty else {
                continue
            }
            // The mapping minted under the row's current parent incarnation, else the row's only one.
            let mapping = rowMappings.first { $0.legacyIncarnation == row.folderIncarnation } ?? rowMappings[0]
            let cloudId = mapping.cloudId
            let recipient = SGTasksWire.TelegramId(cloudUserPeerId: assignee.peerId)
            if let recipient, deviceAssignees[cloudId] == nil {
                deviceAssignees[cloudId] = TasksLegacyDeviceAssignee(recipient: recipient, name: assignee.displayName)
            }
            guard !seen.contains(cloudId), let cloudTaskId = SGTasksWire.UUID(cloudId), let task = tasksById[cloudId] else {
                continue
            }
            guard Self.acceptsLegacyAssignee(task, sentTaskIds: sentTaskIds, serverNow: serverNow) else {
                continue
            }
            seen.insert(cloudId)
            candidates.append(SGTasksLegacyAssigneeCandidate(
                cloudTaskId: cloudTaskId,
                deviceTaskId: row.task.id,
                title: row.task.title,
                name: assignee.displayName,
                recipient: recipient,
                isSelf: recipient != nil && recipient == ownTelegramId
            ))
        }
        return SGTasksLegacyAssigneeOffer(candidates: candidates, deviceAssignees: deviceAssignees)
    }

    /// The owner's live, open task without a live assignment and outside the sent set (§7.2).
    static func acceptsLegacyAssignee(_ task: SGTasksCloudTask, sentTaskIds: Set<String>, serverNow: Date?) -> Bool {
        guard task.viewerRole == .owner, !task.isCompleted, !sentTaskIds.contains(task.id.rawValue) else {
            return false
        }
        guard let assignment = task.assignment else {
            return true
        }
        switch assignment.state {
        case .accepted:
            return false
        case .pending:
            return assignment.isExpired(serverTime: serverNow)
        case .declined, .left, .expired, .revoked:
            return true
        }
    }

    // MARK: The per-task candidate (§7.2 item 2, §4.3 "Hali yuborilmagan")

    /// Where a per-task candidate's recipient comes from.
    public enum Source: Equatable {
        /// A mapped device row (also a sheet row).
        case deviceRow
        /// The task's owner-only `annotation` written by an older client (never a sheet row).
        case annotation
    }

    public struct PerTaskCandidate: Equatable {
        public let recipient: SGTasksWire.TelegramId
        public let name: String
        public let source: Source

        public init(recipient: SGTasksWire.TelegramId, name: String, source: Source) {
            self.recipient = recipient
            self.name = name
            self.source = source
        }
    }

    /// The editor's "Hali yuborilmagan · Yuborish" of one task: the mapped device row's Masʼul when
    /// there is one, else the task's legacy annotation; nil for a completed task, a task with a live
    /// assignment, a task in the sent set, or a task without either.
    public static func candidate(forCloudTaskId id: SGTasksWire.UUID, cloud: SGTasksCloudState, deviceAssignee: TasksLegacyDeviceAssignee?, sentTaskIds: Set<String>, serverNow: Date?) -> PerTaskCandidate? {
        guard let task = cloud.tasks.first(where: { $0.id == id }), Self.acceptsLegacyAssignee(task, sentTaskIds: sentTaskIds, serverNow: serverNow) else {
            return nil
        }
        if let deviceAssignee {
            return PerTaskCandidate(recipient: deviceAssignee.recipient, name: deviceAssignee.name, source: .deviceRow)
        }
        if let annotation = task.annotation {
            return PerTaskCandidate(recipient: annotation.telegramUserId, name: annotation.displayName, source: .annotation)
        }
        return nil
    }

    // MARK: When (§7.1)

    /// Whether the record and the marker admit the one-time sheet: a `completed` record, or a
    /// skipped(existing_mappings) / skipped(scope_changed) one (revision 2), with no marker bound to
    /// that record's `claimedAt`, and at least one sendable device-row candidate. The host adds the
    /// account's permission (`allowed`), the consent screen check and the board's visibility.
    public static func isDue(recordState: TodoCloudMigrationRecord.State?, recordReason: TodoCloudMigrationRecord.Reason?, marker: SGTasksLocalMarkers.LegacyOfferMarker?, hasSendableCandidate: Bool) -> Bool {
        guard marker == nil, hasSendableCandidate else {
            return false
        }
        switch recordState {
        case .completed:
            return true
        case .skipped:
            return recordReason == .existingMappings || recordReason == .scopeChanged
        case .claimed, .enqueued, .released, nil:
            return false
        }
    }

    // MARK: The paced send (§7.3, §12.1)

    public struct Send: Equatable {
        public let candidate: SGTasksLegacyAssigneeCandidate
        /// `SGTasksInvitationPacer.spacedDate`: entry k is due at now + floor((k + sentThisMinute) / 10) min.
        public let dueAt: Date

        public init(candidate: SGTasksLegacyAssigneeCandidate, dueAt: Date) {
            self.candidate = candidate
            self.dueAt = dueAt
        }
    }

    public struct SendPlan: Equatable {
        /// The candidates one tap sends now, in sheet order, each with its due time.
        public let sends: [Send]
        /// The sendable candidates left for later (`tasks_legacySheet_paced(now, later)` when > 0).
        public let later: Int

        public init(sends: [Send], later: Int) {
            self.sends = sends
            self.later = later
        }

        public var isCapped: Bool {
            return self.later > 0
        }
    }

    /// The pacer's allowance over the sendable rows (per recipient ≤ 5 − sent today, in all ≤ 95 −
    /// sent today, pending < 95; the first rows in sheet order win) and the ten-per-minute spacing.
    public static func plan(sendable: [SGTasksLegacyAssigneeCandidate], snapshot: SGTasksInvitationPacer.Snapshot, now: Date) -> SendPlan {
        let sendable = sendable.filter { $0.isSendable }
        let allowed = Set(SGTasksInvitationPacer.allowance(
            candidates: sendable.compactMap { candidate in candidate.recipient.map { (id: candidate.cloudTaskId, recipient: $0) } },
            recipientToday: { snapshot.recipientToday[$0] ?? 0 },
            today: snapshot.today,
            pending: snapshot.pending
        ))
        var sends: [Send] = []
        for candidate in sendable where allowed.contains(candidate.cloudTaskId) {
            sends.append(Send(candidate: candidate, dueAt: SGTasksInvitationPacer.spacedDate(index: sends.count, sentThisMinute: snapshot.thisMinute, now: now)))
        }
        return SendPlan(sends: sends, later: sendable.count - sends.count)
    }

    public func plan(snapshot: SGTasksInvitationPacer.Snapshot, now: Date) -> SendPlan {
        return Self.plan(sendable: self.sendable, snapshot: snapshot, now: now)
    }
}

// MARK: - The host reads (the device rows, the mappings, the board)

extension SGTasksCloudRepository {
    /// wf15 §7.2 item 1, §5.6 fallback (1): the device rows with a local assignee
    /// (`TodoDatabase.liveTasksWithAssignee()`) and the account's import mappings of the CURRENT
    /// import scope (origin + bound principal). The pure offer joins them with the board
    /// (`SGTasksLegacyAssigneeOffer.compute`). Empty before the link or without such rows.
    func legacyDeviceFacts() -> TasksLegacyDeviceFacts {
        guard let principal = self.environment.transport.principal(accountPeerId: self.accountPeerId) else {
            return .empty
        }
        let rows = self.environment.legacy().liveTasksWithAssignee()
        guard !rows.isEmpty else {
            return .empty
        }
        let scope = Self.importScope(origin: self.environment.originScope, principal: principal)
        guard let mappings = try? self.environment.legacy().existingCloudImportMappings(accountPeerId: self.accountPeerId, principalScope: scope) else {
            return .empty
        }
        return TasksLegacyDeviceFacts(rows: rows, mappings: mappings.filter { $0.kind == .task })
    }

    /// §7.2: the legacy assignee offer as the device facts and the board stand now.
    func legacyAssigneeOffer(facts: TasksLegacyDeviceFacts? = nil) -> SGTasksLegacyAssigneeOffer {
        let facts = facts ?? self.legacyDeviceFacts()
        guard !facts.rows.isEmpty, !facts.mappings.isEmpty else {
            return .empty
        }
        let cloud = self.state
        return SGTasksLegacyAssigneeOffer.compute(
            deviceRows: facts.rows,
            mappings: facts.mappings,
            cloud: cloud,
            ownTelegramId: cloud.ownTelegramId,
            sentTaskIds: SGTasksLocalMarkers.legacySentTaskIds(defaults: self.environment.defaults, accountPeerId: self.accountPeerId),
            serverNow: cloud.estimatedServerNow()
        )
    }
}

/// The two device-local reads behind the legacy assignee offer (wf15 §7.2 item 1), cached by the
/// assignment coordinator between the moments the import facts are recomputed.
struct TasksLegacyDeviceFacts: Equatable {
    let rows: [TodoLiveAssigneeRow]
    let mappings: [TodoCloudImportMapping]

    static let empty = TasksLegacyDeviceFacts(rows: [], mappings: [])
}
