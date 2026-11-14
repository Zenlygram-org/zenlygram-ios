import Foundation
import SGEntitlement

// Host tests for the contact rule (wf15 §5.3, D2): the pure `SGTasksAutoAcceptPolicy` matrix, the
// durable manual answers (`SGTasksInviteAnswers`, kept in the harness's own UserDefaults suite) and
// the automatic accept engine of SGTasksCloudRepository (`runAutoAccept`, the reseal after
// `revision_changed`, the quiet drops). No `@main`: `SGTasksCloudRepositoryTests.main` appends
// `cases`. Every repository case installs `.allowed` and restores `.legacy` when it ends. The
// scripted server stands in for the SGEntitlement facade; it proves repository behaviour, not
// backend behaviour. Nothing here touches the host's standard defaults.

enum SGTasksAutoAcceptTests {
    static let cases: [(String, () async throws -> Void)] = [
        ("wf15 I5a: the policy matrix — contact / non-contact, shadow block, expired, queued answer, manual answer, refused task, attempts cap 3, permission, own id, Telegram block (loaded / not loaded / unblocked), contact added later", policyMatrix),
        ("wf15 I5a: the durable manual answers — JSON shape, the 8-day prune of invitation ids, the 500 cap of task ids (newest kept), task refusals survive the prune, the per-account key", inviteAnswersDurability),
        ("wf15 I5a: runAutoAccept queues exactly invitation.respond {accept} for a contact's invitation (base = task_revision), nothing for a stranger; a contact added later accepts; the blocked list not loaded records nothing; an invitation that arrives with a pull is accepted in the same cycle; a withdrawal clears the records", engineAcceptsContacts),
        ("wf15 I5a: a manual decline, leave, block or queued accept is never overridden — a later epoch of a refused task waits in Takliflar even from a contact, also after a simulated last logout and re-login", manualAnswersAreDurable),
        ("wf15 I5a: revision_changed reseals the automatic accept from the re-upserted invitation at most twice, then drops it quietly; invitation_expired, completed_task, invitation_changed, 404 and 422 drop it quietly — no Unsent Changes row, no sharedAccessLost notice, no manual-conflict event; a manual accept's 404 still notices", conflictsAndQuietDrops),
        ("wf15 review E-2 / E-3 / E-4: a first-time sender's invitation that arrives with a pull is not accepted in that cycle (its Telegram block flag was never read) and records nothing; the run after the flag was read accepts it, or leaves it in Takliflar when the flag says blocked; cleared inputs (teardown, a permission that is no longer allowed, a withdrawal) accept nothing until fresh ones arrive; an automatic accept dropped because its invitation left the inbox raises no sharedAccessLost notice", firstTimeSenderAndStaleInputs)
    ]

    // MARK: - Fixtures

    private static let contactTg = SGTasksWire.TelegramId("555000111")!
    private static let strangerTg = SGTasksWire.TelegramId("777000222")!

    private static func allow(_ permission: SGTasksSyncPermission = .allowed) {
        SGTasksCloudRepository.trafficPermission = { _ in permission }
    }

    private static func restoreLegacy() {
        SGTasksCloudRepository.trafficPermission = { _ in .legacy }
    }

    private static func r4Board(_ items: [SGTasksWire.Projection] = [], harness: Harness? = nil, account: Int64 = 42) async throws -> (Harness, SGTasksCloudRepository) {
        let harness = try harness ?? Harness()
        harness.server.defaultServerWire = 4
        let repository = harness.repository(account)
        try await harness.bootstrap(repository, items: items)
        return (harness, repository)
    }

    private static func invitation(_ id: SGTasksWire.UUID, task: SGTasksWire.UUID = SGTasksWire.UUID.generate(), rev: String = "1", from owner: SGTasksWire.TelegramId = contactTg, title: String = "Offer", expires: TimeInterval = 7 * 86400) -> SGTasksWire.Invitation {
        return SGTasksWire.Invitation(id: id, taskId: task, taskRevision: revision(rev), ownerTgId: owner, title: title, dueAt: nil, expiresAt: instant(expires))
    }

    /// `checked` — the senders whose cached Telegram block flag the coordinator has read — defaults
    /// to everyone in play (the contacts and the blocked ids): the state once the coordinator's
    /// flag subscription has delivered. The cases about a first-time sender pass it explicitly.
    private static func inputs(contacts: Set<Int64> = [contactTg.int64Value], blocked: Set<Int64> = [], loaded: Bool = true, checked: Set<Int64>? = nil) -> SGTasksAutoAcceptInputs {
        return SGTasksAutoAcceptInputs(contactTgIds: contacts, telegramBlockedIds: blocked, telegramBlockedListLoaded: loaded, telegramBlockCheckedSenderIds: checked ?? contacts.union(blocked))
    }

    private static func inviteRespond(_ mutation: SGTasksWire.SealedMutation) -> SGTasksWire.InviteRespond? {
        if case let .mutation(request) = mutation, case let .inviteRespond(op) = request.operation {
            return op
        }
        return nil
    }

    /// Every mutation every batch carried, in send order.
    private static func sentMutations(_ harness: Harness) -> [SGTasksWire.SealedMutation] {
        return harness.server.sentBatches.flatMap { $0.items.map { $0.mutation } }
    }

    private static func sentAccepts(_ harness: Harness) -> [(mutationId: String, op: SGTasksWire.InviteRespond)] {
        return harness.server.sentBatches.flatMap { $0.items }.compactMap { item in
            inviteRespond(item.mutation).map { (item.mutation.mutationId.rawValue, $0) }
        }
    }

    private static func receipt(_ mutation: SGTasksWire.SealedMutation, revision: String? = "2") -> SGTasksWire.BatchItemResult {
        guard case let .success(response) = ack(mutation, revision: revision) else {
            preconditionFailure("ack() always succeeds")
        }
        return .receipt(response.receipt)
    }

    private static func itemError(_ kind: SGTasksError.Kind, status: Int) -> SGTasksWire.BatchItemResult {
        return .error(status: status, SGTasksError(kind: kind, retryAfter: nil, serverTime: nil, outcomeUnknown: false, refinement: nil))
    }

    private static func answer(_ request: SGTasksWire.MutationBatchRequest, _ result: (SGTasksWire.MutationBatchRequest.Item) -> SGTasksWire.BatchItemResult) -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        return .success(SGTasksWire.MutationBatchResponse(batchId: request.batchId, results: request.items.map(result), retryAfter: nil, serverTime: instant(), serverWire: 4))
    }

    private static func meta(_ harness: Harness, _ key: String, account: Int64 = 42) throws -> String? {
        return try harness.cloudText("SELECT value FROM meta WHERE key = '\(key)';", accountPeerId: account)
    }

    private static func autoAcceptRecord(_ harness: Harness, _ invitationId: SGTasksWire.UUID, account: Int64 = 42) throws -> (mutationId: String, attempts: Int)? {
        return try meta(harness, "auto_accept.\(invitationId.rawValue)", account: account).flatMap(SGTasksCloudRepository.decodeAutomaticAccept)
    }

    private static func capture() -> (events: () -> [SGTasksAnalyticsEvent], stop: () -> Void) {
        let lock = NSLock()
        var events: [SGTasksAnalyticsEvent] = []
        SGTasksAnalytics.sink = { event, _ in
            lock.lock()
            events.append(event)
            lock.unlock()
        }
        return ({
            lock.lock()
            defer { lock.unlock() }
            return events
        }, {
            SGTasksAnalytics.sink = nil
        })
    }

    private static func answersKey(_ account: Int64 = 42) -> String {
        return "sgtasks.inviteAnswers.\(account)"
    }

    // MARK: - The pure policy (§5.3)

    private static func policyMatrix() async throws {
        let id = SGTasksWire.UUID.generate(), taskId = SGTasksWire.UUID.generate()
        let offer = invitation(id, task: taskId)
        let now = Date(timeIntervalSince1970: baseTime)
        func context(permission: SGTasksSyncPermission = .allowed, contacts: Set<Int64> = [contactTg.int64Value], own: SGTasksWire.TelegramId? = ownTg, blockedSenders: Set<SGTasksWire.TelegramId> = [], listLoaded: Bool = true, telegramBlocked: Set<Int64> = [], serverNow: Date? = now, unresolved: Set<String> = [], answers: SGTasksInviteAnswers = .empty, attempts: [SGTasksWire.UUID: Int] = [:], checked: Set<Int64>? = nil) -> SGTasksAutoAcceptPolicy.Context {
            // `checked` defaults to everyone in play: the senders' block flags have been read.
            return SGTasksAutoAcceptPolicy.Context(permission: permission, contactTgIds: contacts, ownTelegramId: own, blockedSenderIds: blockedSenders, telegramBlockedListLoaded: listLoaded, telegramBlockedIds: telegramBlocked, telegramBlockCheckedSenderIds: checked ?? contacts.union(telegramBlocked), estimatedServerNow: serverNow, hasUnresolvedEntry: { unresolved.contains($0) }, manualAnswers: answers, automaticAttempts: attempts)
        }
        typealias Policy = SGTasksAutoAcceptPolicy
        try check(Policy.decide(offer, context: context()) == .accept, "a contact's invitation was not accepted")
        try check(Policy.decide(offer, context: context(contacts: [strangerTg.int64Value])) == .leaveForUser, "a non-contact's invitation was accepted")
        try check(Policy.decide(offer, context: context(contacts: [])) == .leaveForUser, "an empty contact set (Postbox not loaded yet) accepted")
        try check(Policy.decide(offer, context: context(blockedSenders: [contactTg])) == .leaveForUser, "a shadow-blocked sender was accepted")
        try check(Policy.decide(offer, context: context(serverNow: now.addingTimeInterval(7 * 86400))) == .leaveForUser, "an expired invitation was accepted")
        try check(Policy.decide(offer, context: context(serverNow: now.addingTimeInterval(7 * 86400 - 1))) == .accept, "an invitation one second before its expiry was left")
        try check(Policy.decide(offer, context: context(serverNow: nil)) == .accept, "no server time yet refused the accept (the server stays authoritative for expiry)")
        try check(Policy.decide(offer, context: context(unresolved: [SGTasksCloudKey.invitation(id)])) == .leaveForUser, "a queued answer was doubled")
        try check(Policy.decide(offer, context: context(unresolved: [SGTasksCloudKey.task(taskId)])) == .accept, "an unrelated unresolved task entry blocked the accept")
        var answered = SGTasksInviteAnswers.empty
        answered.recordInvitation(id, at: now)
        try check(Policy.decide(offer, context: context(answers: answered)) == .leaveForUser, "a manually answered invitation was accepted")
        var refused = SGTasksInviteAnswers.empty
        refused.recordRefusedTask(taskId, at: now)
        let laterEpoch = invitation(SGTasksWire.UUID.generate(), task: taskId, rev: "3")
        try check(Policy.decide(laterEpoch, context: context(answers: refused)) == .leaveForUser, "a later epoch of a task declined or left by hand was accepted")
        try check(Policy.decide(invitation(SGTasksWire.UUID.generate()), context: context(answers: refused)) == .accept, "a refusal of one task spilled over to another")
        try check(Policy.decide(offer, context: context(attempts: [id: 2])) == .accept, "the third attempt was refused")
        try check(Policy.decide(offer, context: context(attempts: [id: 3])) == .leaveForUser, "a fourth attempt was allowed")
        try check(Policy.decide(offer, context: context(attempts: [SGTasksWire.UUID.generate(): 3])) == .accept, "another invitation's attempts counted")
        for permission in [SGTasksSyncPermission.waiting, .forbidden, .legacy] {
            try check(Policy.decide(offer, context: context(permission: permission)) == .leaveForUser, "permission \(permission) accepted")
        }
        try check(Policy.decide(invitation(SGTasksWire.UUID.generate(), from: ownTg), context: context(contacts: [ownTg.int64Value])) == .leaveForUser, "an invitation from the account's own id was accepted")
        try check(Policy.decide(offer, context: context(own: nil)) == .accept, "an unknown own id refused a contact")
        // Revision 3: Telegram-level blocks.
        try check(Policy.decide(offer, context: context(telegramBlocked: [contactTg.int64Value])) == .leaveForUser, "a contact blocked in Telegram was accepted")
        try check(Policy.decide(offer, context: context(listLoaded: false)) == .leaveForUser, "the blocked list not loaded yet did not fail closed")
        try check(Policy.decide(offer, context: context(listLoaded: true, telegramBlocked: [strangerTg.int64Value])) == .accept, "a loaded list without the sender refused the accept")
        // Review E-2: the blocked list is a one-time read, so a sender whose own block flag has not
        // been read yet (a first-time sender, in the cycle whose pull delivered the invitation) is
        // never accepted; once read: accepted when not blocked, left when blocked.
        try check(Policy.decide(offer, context: context(checked: [])) == .leaveForUser, "a sender whose block flag was never read was accepted")
        try check(Policy.decide(offer, context: context(checked: [strangerTg.int64Value])) == .leaveForUser, "another sender's read flag counted for this one")
        try check(Policy.decide(offer, context: context(checked: [contactTg.int64Value])) == .accept, "a checked, unblocked contact was left")
        try check(Policy.decide(offer, context: context(telegramBlocked: [contactTg.int64Value], checked: [contactTg.int64Value])) == .leaveForUser, "a checked sender whose flag says blocked was accepted")
        // Contact added later: the same invitation, a changed set → accepted.
        try check(Policy.decide(offer, context: context(contacts: [])) == .leaveForUser && Policy.decide(offer, context: context(contacts: [strangerTg.int64Value, contactTg.int64Value])) == .accept, "adding the sender as a contact did not accept")
    }

    // MARK: - The durable manual answers (§5.3)

    private static func inviteAnswersDurability() async throws {
        let now = Date(timeIntervalSince1970: baseTime)
        let a = SGTasksWire.UUID.generate(), b = SGTasksWire.UUID.generate(), t = SGTasksWire.UUID.generate()
        var answers = SGTasksInviteAnswers.empty
        answers.recordInvitation(a, at: now)
        answers.recordInvitation(b, at: now.addingTimeInterval(-9 * 86400))
        answers.recordRefusedTask(t, at: now.addingTimeInterval(-100 * 86400))
        // The JSON shape `{"i":{id: seconds},"t":{id: seconds}}` round-trips.
        let object = try JSONSerialization.jsonObject(with: answers.json) as? [String: Any]
        let i = object?["i"] as? [String: Any], tt = object?["t"] as? [String: Any]
        try check(object?.count == 2 && (i?[a.rawValue] as? NSNumber)?.int64Value == Int64(baseTime) && i?.count == 2 && (tt?[t.rawValue] as? NSNumber) != nil && tt?.count == 1, "the JSON shape: \(String(decoding: answers.json, as: UTF8.self))")
        try check(SGTasksInviteAnswers(json: answers.json) == answers, "the JSON did not round-trip")
        try check(SGTasksInviteAnswers(json: Data("{\"i\":{\"not-a-uuid\":1,\"\(a.rawValue)\":\"x\"},\"t\":[]}".utf8)) == .empty, "garbage was not ignored")
        try check(SGTasksInviteAnswers(json: Data("nope".utf8)) == nil, "a non-object decoded")
        // The prune: invitation ids older than 8 days go, task ids never age out (only the cap).
        answers.prune(now: now)
        try check(answers.answered(invitationId: a) && !answers.answered(invitationId: b) && answers.refused(taskId: t), "the prune: \(answers)")
        try check(answers.answered(invitationId: a) == true, "a fresh id was pruned")
        var exactly = SGTasksInviteAnswers.empty
        exactly.recordInvitation(a, at: now.addingTimeInterval(-8 * 86400))
        exactly.prune(now: now)
        try check(!exactly.answered(invitationId: a), "an id exactly 8 days old survived")
        var capped = SGTasksInviteAnswers.empty
        var newest: [SGTasksWire.UUID] = []
        for index in 0 ..< 520 {
            let id = SGTasksWire.UUID.generate()
            capped.recordRefusedTask(id, at: now.addingTimeInterval(TimeInterval(index)))
            if index >= 20 {
                newest.append(id)
            }
        }
        capped.prune(now: now.addingTimeInterval(1000))
        try check(capped.refusedTaskIds.count == 500 && newest.allSatisfy { capped.refused(taskId: $0) }, "the cap did not keep the 500 newest task ids: \(capped.refusedTaskIds.count)")
        // The store: per-account key, prune on load, removal when empty.
        let suite = "sgtasks-auto-accept-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(SGTasksInviteAnswersStore.key(accountPeerId: 42) == answersKey(42) && SGTasksInviteAnswersStore.keyPrefix == "sgtasks.inviteAnswers.", "the key")
        SGTasksInviteAnswersStore.recordInvitation(a, refusedTaskId: t, defaults: defaults, accountPeerId: 42, now: now)
        SGTasksInviteAnswersStore.recordInvitation(b, defaults: defaults, accountPeerId: 7, now: now)
        let loaded = SGTasksInviteAnswersStore.load(defaults: defaults, accountPeerId: 42, now: now)
        try check(loaded.answered(invitationId: a) && loaded.refused(taskId: t) && !loaded.answered(invitationId: b), "the store did not keep the account's answers apart: \(loaded)")
        try check(defaults.string(forKey: answersKey(42)) != nil && defaults.string(forKey: answersKey(7)) != nil, "the keys were not written")
        let later = SGTasksInviteAnswersStore.load(defaults: defaults, accountPeerId: 42, now: now.addingTimeInterval(9 * 86400))
        try check(!later.answered(invitationId: a) && later.refused(taskId: t), "the task refusal did not survive the invitation-id prune")
        SGTasksInviteAnswersStore.save(.empty, defaults: defaults, accountPeerId: 7)
        try check(defaults.object(forKey: answersKey(7)) == nil, "an empty record was not removed")
    }

    // MARK: - The engine (§5.3)

    private static func engineAcceptsContacts() async throws {
        allow()
        defer { restoreLegacy() }
        let analytics = capture()
        defer { analytics.stop() }
        let fromContact = SGTasksWire.UUID.generate(), fromStranger = SGTasksWire.UUID.generate()
        let contactTask = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([
            .invitation(invitation(fromContact, task: contactTask, rev: "4")),
            .invitation(invitation(fromStranger, from: strangerTg))
        ])
        try check(repository.state.invitations.count == 2 && repository.state.automaticAcceptInvitationIds.isEmpty && harness.server.sentBatches.isEmpty, "the board did not start with two pending invitations and nothing sent")
        // Before the coordinator hands anything in, nothing is accepted (no inputs).
        await repository.syncNow()
        try check(try harness.outboxBodies().isEmpty, "something was queued without inputs")
        // The blocked list not loaded yet: fail closed, nothing recorded.
        repository.runAutoAccept(inputs(loaded: false))
        try check(try harness.outboxBodies().isEmpty && harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key GLOB 'auto_accept.*';") == 0, "an accept was queued or recorded before the blocked list was read")
        // Loaded: exactly the contact's invitation is accepted — queued, provisional, sealed on the
        // invitation's task_revision; the stranger's waits in Takliflar.
        repository.runAutoAccept(inputs())
        let queued = try harness.outboxBodies().map { try SGTasksWire.SealedMutation(wireJSON: $0) }
        guard queued.count == 1, let accept = inviteRespond(queued[0]) else { throw CloudTestFailure.assertion("the outbox is not one invitation.respond: \(queued.map { $0.kind })") }
        try check(accept.invitationId == fromContact && accept.taskId == contactTask && accept.decision == .accept && accept.baseRevision.rawValue == "4", "the automatic accept is wrong: \(accept)")
        try check(repository.state.automaticAcceptInvitationIds == [fromContact], "the provisional set: \(repository.state.automaticAcceptInvitationIds)")
        try check(repository.state.invitations.first { $0.id == fromContact }?.isResponsePending == true && repository.state.invitations.first { $0.id == fromStranger }?.isResponsePending == false, "the overlay does not show the queued answer")
        let record = try autoAcceptRecord(harness, fromContact)
        try check(record?.mutationId == queued[0].mutationId.rawValue && record?.attempts == 1, "the bookkeeping row: \(String(describing: record))")
        try check(analytics.events().filter { $0 == .shared(action: "invite_accepted") }.count == 1, "the analytics action is not the manual accept's: \(analytics.events())")
        // A second run queues nothing more (one answer at a time).
        repository.runAutoAccept(inputs())
        try check(try harness.outboxBodies().count == 1, "the accept was doubled")
        // Only `invitation.respond {accept}` leaves the device; the receipt ends the bookkeeping.
        harness.server.batchScript = [{ request in answer(request) { item in receipt(item.mutation) } }]
        await repository.syncNow()
        let sent = sentMutations(harness)
        try check(sent.count == 1 && inviteRespond(sent[0])?.decision == .accept && inviteRespond(sent[0])?.invitationId == fromContact, "something other than the accept left the device: \(sent.map { $0.kind })")
        // Acknowledged but not proven yet (the server still shows the invitation until the next
        // pull): the row stays provisional, the record stays, and nothing is accepted twice.
        try check(try autoAcceptRecord(harness, fromContact)?.attempts == 1 && repository.state.automaticAcceptInvitationIds == [fromContact], "the acknowledged accept lost its provisional state before the proof")
        repository.runAutoAccept(inputs())
        await repository.syncNow()
        try check(sentAccepts(harness).count == 1, "an acknowledged accept was sent again before the proof")
        try check(repository.state.notices.isEmpty && repository.state.resolutionNotices.isEmpty, "a notice appeared")
        // The proof (the invitation leaves the snapshot) ends the bookkeeping. Contact added later:
        // the stranger's still-pending invitation is accepted on that run.
        repository.runAutoAccept(inputs(contacts: [contactTg.int64Value, strangerTg.int64Value]))
        harness.server.changesScript = [changesPage([remove(.invitation(fromContact))], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { item in receipt(item.mutation) } }]
        await repository.syncNow()
        try check(try autoAcceptRecord(harness, fromContact) == nil, "the proof did not end the bookkeeping")
        try check(sentAccepts(harness).map { $0.op.invitationId } == [fromContact, fromStranger], "the later contact's invitation was not accepted: \(sentAccepts(harness).map { $0.op.invitationId })")
        // An invitation that arrives with a pull is accepted in the same cycle, before the drain,
        // with the last inputs; a blocked contact's (revision 3) is not.
        let arriving = SGTasksWire.UUID.generate(), blockedContactTg = SGTasksWire.TelegramId("888000333")!, fromBlocked = SGTasksWire.UUID.generate()
        repository.runAutoAccept(inputs(contacts: [contactTg.int64Value, strangerTg.int64Value, blockedContactTg.int64Value], blocked: [blockedContactTg.int64Value]))
        // The accepted invitations leave the recipient's inbox, as the server does once accepted.
        harness.server.changesScript = [changesPage([remove(.invitation(fromStranger)), upsert(.invitation(invitation(arriving, rev: "9"))), upsert(.invitation(invitation(fromBlocked, from: blockedContactTg)))], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { item in receipt(item.mutation) } }]
        await repository.syncNow()
        let third = sentAccepts(harness).dropFirst(2)
        try check(third.count == 1 && third.first?.op.invitationId == arriving && third.first?.op.baseRevision.rawValue == "9", "the arriving invitation was not accepted in its cycle: \(third.map { $0.op.invitationId })")
        try check(repository.state.invitations.filter { !$0.isResponsePending }.map { $0.id } == [fromBlocked], "the Telegram-blocked contact's invitation did not wait in Takliflar: \(repository.state.invitations.map { ($0.id, $0.isResponsePending) })")
        // Unblocked later → accepted on the next run; a withdrawal's discard clears the records.
        repository.runAutoAccept(inputs(contacts: [blockedContactTg.int64Value]))
        // (`arriving` is acknowledged and still provisional until its proof.)
        try check(try autoAcceptRecord(harness, fromBlocked)?.attempts == 1 && repository.state.automaticAcceptInvitationIds == [arriving, fromBlocked], "the unblocked contact's invitation was not accepted: \(repository.state.automaticAcceptInvitationIds)")
        _ = repository.discardAfterConsentWithdrawal()
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key GLOB 'auto_accept.*';") == 0 && repository.state.automaticAcceptInvitationIds.isEmpty, "the withdrawal left an automatic-accept record")
        try check(!analytics.events().contains(.syncIssue(kind: "conflict_manual")), "a manual conflict was reported")
    }

    private static func manualAnswersAreDurable() async throws {
        allow()
        defer { restoreLegacy() }
        let declined = SGTasksWire.UUID.generate(), declinedTask = SGTasksWire.UUID.generate()
        let accepted = SGTasksWire.UUID.generate(), acceptedTask = SGTasksWire.UUID.generate()
        let blocked = SGTasksWire.UUID.generate(), blockerTg = SGTasksWire.TelegramId("999000444")!
        let leftTask = SGTasksWire.UUID.generate(), leftEpoch = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([
            .invitation(invitation(declined, task: declinedTask)),
            .invitation(invitation(accepted, task: acceptedTask)),
            .invitation(invitation(blocked, from: blockerTg)),
            assignedTask(leftTask, rev: "2", title: "Left later", invitation: leftEpoch)
        ])
        let defaults = harness.legacyDefaults
        let account = repository.accountPeerId
        // Manual answers, recorded: a decline (invitation + task), an accept (invitation), a block
        // (invitation), a leave (task + epoch).
        try repository.respondToInvitation(id: declined, accept: false)
        try repository.respondToInvitation(id: accepted, accept: true)
        try repository.blockSender(invitationId: blocked)
        try repository.leaveTask(id: leftTask, expectedInvitationId: leftEpoch)
        let recorded = SGTasksInviteAnswersStore.load(defaults: defaults, accountPeerId: account, now: harness.clock)
        try check(recorded.answered(invitationId: declined) && recorded.refused(taskId: declinedTask), "the decline was not recorded for the invitation and the task")
        try check(recorded.answered(invitationId: accepted) && !recorded.refused(taskId: acceptedTask), "the accept recorded a task refusal, or was not recorded")
        try check(recorded.answered(invitationId: blocked) && recorded.answered(invitationId: leftEpoch) && recorded.refused(taskId: leftTask), "the block or the leave was not recorded")
        try check(defaults.string(forKey: answersKey(account)) != nil, "the durable key is missing")
        // The queued manual answers are never doubled by the engine, and the server's answers go out
        // as the user decided: nothing automatic in the outbox.
        repository.runAutoAccept(inputs(contacts: [contactTg.int64Value, blockerTg.int64Value]))
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key GLOB 'auto_accept.*';") == 0 && harness.outboxBodies().count == 4, "the engine touched a manually answered invitation")
        harness.server.batchScript = [{ request in answer(request) { item in receipt(item.mutation) } }]
        await repository.syncNow()
        // Qayta yuborish: new epochs of the declined and the left task, from a contact — they wait in
        // Takliflar; a fresh task of the same contact is accepted.
        let declinedAgain = SGTasksWire.UUID.generate(), leftAgain = SGTasksWire.UUID.generate(), fresh = SGTasksWire.UUID.generate()
        harness.server.changesScript = [changesPage([
            remove(.invitation(declined)), remove(.invitation(accepted)), remove(.invitation(blocked)), remove(.task(leftTask)),
            upsert(.invitation(invitation(declinedAgain, task: declinedTask, rev: "5"))),
            upsert(.invitation(invitation(leftAgain, task: leftTask, rev: "3"))),
            upsert(.invitation(invitation(fresh)))
        ], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { item in receipt(item.mutation) } }]
        await repository.syncNow()
        // The three manual `invitation.respond` (decline, accept, leave) went first; then only `fresh`.
        try check(sentAccepts(harness).count == 4 && sentAccepts(harness).dropFirst(3).map { $0.op.invitationId } == [fresh], "the refused tasks' new epochs were not left in Takliflar, or the fresh task was: \(sentAccepts(harness).map { ($0.op.invitationId, $0.op.decision) })")
        try check(Set(repository.state.invitations.filter { !$0.isResponsePending }.map { $0.id }) == [declinedAgain, leftAgain], "Takliflar does not hold exactly the two refused tasks' epochs: \(repository.state.invitations.map { ($0.id, $0.isResponsePending) })")
        // A queued manual accept the logout purged keeps its invitation id: after a simulated LAST
        // logout (the account store purged, the device database wiped) and a re-login, the server
        // still shows that invitation and a contact's Qayta yuborish of the declined task — both
        // wait in Takliflar, because `sgtasks.inviteAnswers.<id>` survived.
        let offline = SGTasksWire.UUID.generate()
        harness.server.changesScript = [changesPage([upsert(.invitation(invitation(offline, from: strangerTg)))], serverWire: 4)]
        await repository.syncNow()
        try repository.respondToInvitation(id: offline, accept: true)
        try check(repository.state.invitations.first { $0.id == offline }?.isResponsePending == true, "the manual accept was not queued")
        repository.stop()
        harness.files.purge(accountPeerId: account)
        harness.legacy.removeAllData()
        try check(defaults.string(forKey: answersKey(account)) != nil, "the last logout took the manual answers (it must not: SGTasksLocalMarkers.removeAll skips the key)")
        let again = SGTasksWire.UUID.generate()
        let (_, relogin) = try await r4Board([
            .invitation(invitation(offline, from: strangerTg)),
            .invitation(invitation(again, task: declinedTask, rev: "6")),
            .invitation(invitation(fresh, title: "Still pending"))
        ], harness: harness, account: account)
        harness.server.batchScript = [{ request in answer(request) { item in receipt(item.mutation) } }]
        // The stranger became a contact meanwhile: the invitation answered by hand still waits.
        relogin.runAutoAccept(inputs(contacts: [contactTg.int64Value, strangerTg.int64Value]))
        await relogin.syncNow()
        let afterRelogin = sentAccepts(harness).dropFirst(4).map { $0.op.invitationId }
        try check(afterRelogin == [fresh], "after the re-login the purged manual accept or the refused task's new epoch was accepted automatically: \(afterRelogin)")
        try check(Set(relogin.state.invitations.filter { !$0.isResponsePending }.map { $0.id }) == [offline, again], "Takliflar after the re-login: \(relogin.state.invitations.map { $0.id })")
    }

    private static func conflictsAndQuietDrops() async throws {
        allow()
        defer { restoreLegacy() }
        let analytics = capture()
        defer { analytics.stop() }
        let resealed = SGTasksWire.UUID.generate(), resealedTask = SGTasksWire.UUID.generate()
        let expired = SGTasksWire.UUID.generate(), completed = SGTasksWire.UUID.generate(), changed = SGTasksWire.UUID.generate(), gone = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([
            .invitation(invitation(resealed, task: resealedTask, rev: "1")),
            .invitation(invitation(expired)),
            .invitation(invitation(completed)),
            .invitation(invitation(changed)),
            .invitation(invitation(gone))
        ])
        repository.runAutoAccept(inputs())
        try check(repository.state.automaticAcceptInvitationIds.count == 5, "the five accepts were not queued")
        // Cycle 1 — every refusal at once: revision_changed on the first (the automatic row), the
        // four definite refusals on the others.
        harness.server.batchScript = [{ request in
            answer(request) { item in
                switch inviteRespond(item.mutation)?.invitationId {
                case resealed?: return itemError(.conflict(.revisionChanged), status: 409)
                case expired?: return itemError(.conflict(.invitationExpired), status: 409)
                case completed?: return itemError(.conflict(.completedTask), status: 409)
                case changed?: return itemError(.conflict(.invitationChanged), status: 409)
                default: return itemError(.notFound, status: 404)
                }
            }
        }]
        await repository.syncNow()
        try check(repository.state.entries.count == 1 && repository.state.entries[0].status == .conflict(.revisionChanged), "the four definite refusals left a row, or the conflict is missing: \(repository.state.entries.map { ($0.resourceId, $0.status) })")
        try check(repository.state.notices.isEmpty && repository.state.resolutionNotices.isEmpty, "a quiet drop left a notice (sharedAccessLost or other)")
        for id in [expired, completed, changed, gone] {
            let record = try autoAcceptRecord(harness, id)
            try check(record?.attempts == SGTasksAutoAcceptPolicy.maximumAttempts, "a dropped accept did not record its attempts at the cap: \(String(describing: record))")
        }
        try check(repository.state.automaticAcceptInvitationIds == [resealed], "the provisional set after the drops: \(repository.state.automaticAcceptInvitationIds)")
        // The dropped ones are not retried (the attempts), and they wait in Takliflar while pending.
        repository.runAutoAccept(inputs())
        try check(repository.state.entries.count == 1 && Set(repository.state.invitations.filter { !$0.isResponsePending }.map { $0.id }) == [expired, completed, changed, gone], "a dropped accept was retried, or Takliflar is wrong: \(repository.state.invitations.map { ($0.id, $0.isResponsePending) })")
        // Cycle 2 — the pull re-upserts the invitation with the task's new revision (as the server
        // does, TasksProjection.php:107-108); the conflict is resolved right after it: resealed on
        // base 2, same invitation id, new mutation id, attempts 2, the record following it; the
        // server refuses again.
        let firstAttempt = sentAccepts(harness).first { $0.op.invitationId == resealed }
        harness.server.changesScript = [changesPage([upsert(.invitation(invitation(resealed, task: resealedTask, rev: "2")))], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { _ in itemError(.conflict(.revisionChanged), status: 409) } }]
        await repository.syncNow()
        let second = sentAccepts(harness).filter { $0.op.invitationId == resealed }
        try check(second.count == 2 && second[1].op.baseRevision.rawValue == "2" && second[1].mutationId != firstAttempt?.mutationId && second[1].op.decision == .accept && second[1].op.invitationId == resealed, "the first reseal is wrong: \(second.map { ($0.mutationId, $0.op.baseRevision.rawValue) })")
        let afterFirstReseal = try autoAcceptRecord(harness, resealed)
        let openConflicts = repository.state.entries.filter { $0.status == .conflict(.revisionChanged) }.count
        try check(afterFirstReseal?.attempts == 2 && repository.state.entries.count == 1 && openConflicts == 1, "the record did not follow the first reseal: \(String(describing: afterFirstReseal))")
        // Cycle 3 — the second reseal (attempts 3, base 3) meets a third revision_changed: the
        // automatic row is spent (two automatic resolutions) → dropped quietly, nothing for the user.
        harness.server.changesScript = [changesPage([upsert(.invitation(invitation(resealed, task: resealedTask, rev: "3")))], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { _ in itemError(.conflict(.revisionChanged), status: 409) } }]
        await repository.syncNow()
        let third = sentAccepts(harness).filter { $0.op.invitationId == resealed }
        try check(third.count == 3 && third[2].op.baseRevision.rawValue == "3", "the second reseal is wrong: \(third.map { $0.op.baseRevision.rawValue })")
        try check(repository.state.entries.isEmpty && repository.state.notices.isEmpty && repository.state.resolutionNotices.isEmpty, "the third conflict was not dropped quietly: \(repository.state.entries.map { $0.status })")
        let afterDrop = try autoAcceptRecord(harness, resealed)
        try check(afterDrop?.attempts == 3 && repository.state.automaticAcceptInvitationIds.isEmpty, "the attempts after the drop: \(String(describing: afterDrop))")
        harness.server.changesScript = [changesPage([upsert(.invitation(invitation(resealed, task: resealedTask, rev: "4")))], serverWire: 4)]
        repository.runAutoAccept(inputs())
        await repository.syncNow()
        try check(sentAccepts(harness).filter { $0.op.invitationId == resealed }.count == 3 && repository.state.invitations.first { $0.id == resealed }?.isResponsePending == false, "a fourth automatic attempt was made")
        try check(!analytics.events().contains(.syncIssue(kind: "conflict_manual")) && !analytics.events().contains(.syncIssue(kind: "invalid")), "a quiet drop was reported as a manual conflict or an invalid entry: \(analytics.events())")
        // 422 on the automatic accept (a one-entry batch's envelope answer): dropped quietly too.
        let invalid = SGTasksWire.UUID.generate()
        harness.server.changesScript = [changesPage([upsert(.invitation(invitation(invalid)))], serverWire: 4)]
        harness.server.batchScript = [{ (_: SGTasksWire.MutationBatchRequest) -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> in failure(.invalidRequest) }]
        await repository.syncNow()
        let afterInvalid = try autoAcceptRecord(harness, invalid)
        try check(sentAccepts(harness).last?.op.invitationId == invalid && repository.state.entries.isEmpty && afterInvalid?.attempts == 3, "the 422 did not drop the automatic accept quietly: \(repository.state.entries.map { $0.status }) \(String(describing: afterInvalid))")
        try check(!analytics.events().contains(.syncIssue(kind: "invalid")), "the quiet 422 was reported as an invalid entry")
        // Contrast: a MANUAL accept's 404 still forgets the shared resource with the notice.
        let manual = SGTasksWire.UUID.generate()
        harness.server.changesScript = [changesPage([upsert(.invitation(invitation(manual, from: strangerTg)))], serverWire: 4)]
        await repository.syncNow()
        try repository.respondToInvitation(id: manual, accept: true)
        harness.server.batchScript = [{ request in answer(request) { _ in itemError(.notFound, status: 404) } }]
        await repository.syncNow()
        let noticeKinds: [SGTasksCloudNotice.Kind] = repository.state.notices.map { $0.kind }
        try check(noticeKinds == [SGTasksCloudNotice.Kind.sharedAccessLost] && repository.state.entries.isEmpty, "the manual accept's 404 lost its notice: \(noticeKinds)")
    }

    // MARK: - Review E-2 / E-3 / E-4

    /// E-2 (privacy P1): the coordinator reads the Telegram blocked list once per process; a block
    /// made later reaches the policy only through the sender's cached flag, which it subscribes for
    /// the senders of invitations already pending. The cycle whose pull delivers a first-time
    /// sender's invitation runs the policy with the inputs handed in before that — the sender is
    /// not among the checked ones, so nothing is accepted until the flag has been read.
    /// E-3 (privacy P4): inputs the coordinator no longer stands behind are not used.
    /// E-4: a queued automatic accept whose invitation leaves the inbox goes without a notice.
    private static func firstTimeSenderAndStaleInputs() async throws {
        allow()
        defer { restoreLegacy() }
        let (harness, repository) = try await r4Board()
        func autoAcceptRecords() throws -> Int64 {
            return try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key GLOB 'auto_accept.*';")
        }
        // The app has been running: the contact set is known, the blocked list was read (the block
        // of X came after it, so the list does not name X), and no invitation was pending — no
        // sender's flag has been read.
        repository.runAutoAccept(inputs(checked: []))
        let first = SGTasksWire.UUID.generate()
        harness.server.changesScript = [changesPage([upsert(.invitation(invitation(first, rev: "3")))], serverWire: 4)]
        await repository.syncNow()
        try check(harness.server.sentBatches.isEmpty && (try harness.outboxBodies().isEmpty), "a first-time sender's invitation was accepted in the cycle that delivered it: \(sentMutations(harness).map { $0.kind })")
        try check(try autoAcceptRecords() == 0 && repository.state.automaticAcceptInvitationIds.isEmpty, "the wait recorded something")
        try check(repository.state.invitations.map { $0.id } == [first] && repository.state.invitations[0].isResponsePending == false, "the invitation does not simply wait: \(repository.state.invitations.map { ($0.id, $0.isResponsePending) })")
        // The coordinator subscribed X's flag; it says blocked: the invitation waits in Takliflar,
        // nothing is recorded (unblocking later accepts it).
        repository.runAutoAccept(inputs(blocked: [contactTg.int64Value], checked: [contactTg.int64Value]))
        await repository.syncNow()
        try check(harness.server.sentBatches.isEmpty && (try autoAcceptRecords()) == 0 && repository.state.automaticAcceptInvitationIds.isEmpty, "a sender blocked after the list was read was accepted")
        // The flag says not blocked (or the user unblocked X): accepted on that run.
        repository.runAutoAccept(inputs(checked: [contactTg.int64Value]))
        let queued = try harness.outboxBodies().map { try SGTasksWire.SealedMutation(wireJSON: $0) }
        try check(queued.count == 1 && inviteRespond(queued[0])?.invitationId == first && inviteRespond(queued[0])?.decision == .accept && inviteRespond(queued[0])?.baseRevision.rawValue == "3", "the checked, unblocked sender's invitation was not accepted: \(queued.map { $0.kind })")

        // E-4: before the accept is sent the owner removes the assignee — the invitation leaves the
        // inbox with the next pull. The queued automatic accept goes quietly: no entry, no notice.
        harness.server.changesScript = [changesPage([remove(.invitation(first))], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { _ in itemError(.notFound, status: 404) } }]
        await repository.syncNow()
        try check(repository.state.entries.isEmpty && (try harness.outboxBodies().isEmpty), "the automatic accept of a vanished invitation stayed: \(repository.state.entries.map { ($0.resourceId, $0.status) })")
        try check(repository.state.notices.isEmpty && repository.state.resolutionNotices.isEmpty, "a dropped automatic accept raised a notice: \(repository.state.notices.map { $0.kind })")
        try check(sentAccepts(harness).isEmpty, "the accept of a vanished invitation was sent")
        // Contrast: a MANUAL answer queued for an invitation that vanishes still gets the notice.
        let manual = SGTasksWire.UUID.generate()
        harness.server.changesScript = [changesPage([upsert(.invitation(invitation(manual, from: strangerTg)))], serverWire: 4)]
        await repository.syncNow()
        SGTasksCloudRepository.trafficPermission = { _ in .waiting }
        try repository.respondToInvitation(id: manual, accept: true)
        allow()
        harness.server.changesScript = [changesPage([remove(.invitation(manual))], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { _ in itemError(.notFound, status: 404) } }]
        await repository.syncNow()
        try check(repository.state.notices.map { $0.kind } == [SGTasksCloudNotice.Kind.sharedAccessLost], "the manual answer of a vanished invitation lost its notice: \(repository.state.notices.map { $0.kind })")

        // E-3: the coordinator tore its sources down — its inputs are forgotten, and a contact's
        // invitation that arrives with a pull before fresh ones are handed in is not accepted.
        repository.runAutoAccept(inputs())
        repository.clearAutoAcceptInputs()
        try check(repository.onQueue { repository.autoAcceptInputs == nil }, "clearAutoAcceptInputs kept the inputs")
        let afterTeardown = SGTasksWire.UUID.generate()
        harness.server.changesScript = [changesPage([upsert(.invitation(invitation(afterTeardown)))], serverWire: 4)]
        await repository.syncNow()
        try check(sentAccepts(harness).isEmpty && (try autoAcceptRecords()) == 0, "stale inputs accepted an invitation after the teardown")
        // The gate stopped allowing the account: the inputs go with the permission.
        repository.runAutoAccept(inputs(checked: []))
        SGTasksCloudRepository.trafficPermission = { _ in .waiting }
        repository.permissionChanged()
        try check(repository.onQueue { repository.autoAcceptInputs == nil }, "a permission that is no longer allowed kept the inputs")
        allow()
        repository.permissionChanged()
        try check(repository.onQueue { repository.autoAcceptInputs == nil }, "the inputs came back by themselves")
        // A withdrawal clears them too; fresh inputs after it accept the still-pending invitation.
        repository.runAutoAccept(inputs(checked: []))
        _ = repository.discardAfterConsentWithdrawal()
        try check(repository.onQueue { repository.autoAcceptInputs == nil }, "a withdrawal kept the inputs")
    }
}
