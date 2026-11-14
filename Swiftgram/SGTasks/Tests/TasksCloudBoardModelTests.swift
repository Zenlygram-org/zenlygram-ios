import Foundation
import SGEntitlement

// Host tests for TasksCloudBoardModel.swift (the synced board's pure UI state) and, through
// TasksBoardSourceTests, the one-board resolver with the device archive's banner model
// (TasksBoardSource.swift), run against the real repository value types (SGTasksCloudModels.swift)
// and wire types. No database, network or UIKit: every value is built in memory.
@main
struct TasksCloudBoardModelTests {
    private static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        precondition(condition, "line \(line): \(message)")
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func uuid(_ n: Int) -> SGTasksWire.UUID {
        let suffix = String(format: "%012d", n)
        return SGTasksWire.UUID("00000000-0000-4000-8000-\(suffix)")!
    }

    private static func tg(_ value: Int64) -> SGTasksWire.TelegramId {
        return SGTasksWire.TelegramId(int64: value)!
    }

    private static func list(_ n: Int, _ title: String, order: Int32, problem: SGTasksCloudProblem? = nil) -> SGTasksCloudList {
        return SGTasksCloudList(id: uuid(n), title: title, sortOrder: order, revision: SGTasksWire.Revision("1"), createdAt: nil, isPending: problem != nil, problem: problem)
    }

    private static func task(
        _ n: Int,
        list: Int? = nil,
        order: Int32 = 0,
        role: SGTasksWire.ViewerRole = .owner,
        completedAt: Date? = nil,
        completed: Bool? = nil,
        assignment: SGTasksCloudAssignment? = nil,
        revision: String? = "3",
        isPending: Bool = false,
        problem: SGTasksCloudProblem? = nil,
        annotation: SGTasksWire.Annotation? = nil,
        dueAt: Int32? = nil
    ) -> SGTasksCloudTask {
        return SGTasksCloudTask(
            id: uuid(n),
            listId: list.map { uuid($0) },
            title: "Task \(n)",
            description: nil,
            dueAt: dueAt,
            priority: 0,
            sortOrder: order,
            annotation: annotation,
            isCompleted: completed ?? (completedAt != nil),
            completedAt: completedAt,
            createdAt: nil,
            viewerRole: role,
            ownerTgId: tg(role == .owner ? 10 : 77),
            assignment: assignment,
            revision: revision.flatMap { SGTasksWire.Revision($0) },
            isPending: isPending,
            problem: problem
        )
    }

    private static func entry(_ id: Int64, _ kind: SGTasksWire.OperationKind, _ status: SGTasksCloudEntry.Status) -> SGTasksCloudEntry {
        return SGTasksCloudEntry(id: id, kind: kind, resourceId: uuid(Int(id)).rawValue, status: status, attempts: 1, nextAttemptAt: nil, displayTitle: "T", lastServerTime: nil)
    }

    private static func cloud(
        phase: SGTasksCloudState.Phase = .idle,
        complete: Bool = true,
        lists: [SGTasksCloudList] = [],
        tasks: [SGTasksCloudTask] = [],
        invitations: [SGTasksCloudInvitation] = [],
        entries: [SGTasksCloudEntry] = [],
        notices: [SGTasksCloudNotice] = [],
        serverTime: Date? = now
    ) -> SGTasksCloudState {
        var state = SGTasksCloudState.empty
        state.phase = phase
        state.hasCompleteSnapshot = complete
        state.serverTime = serverTime
        // Received "now", so the estimated server clock equals `serverTime` at the board's `now`.
        state.serverTimeReceivedAt = serverTime == nil ? nil : now
        state.lists = lists
        state.tasks = tasks
        state.invitations = invitations
        state.entries = entries
        state.notices = notices
        return state
    }

    private static func board(_ cloud: SGTasksCloudState, linked: Bool = true, filter: TasksBoardFilter = .all, expanded: Bool = false, withdrawn: Bool = false, syncedCopy: Bool = false) -> TasksCloudBoardState {
        return TasksCloudBoardState(cloud: cloud, isLinked: linked, now: now, filter: filter, isCompletedExpanded: expanded, isConsentWithdrawn: withdrawn, isSyncedCopy: syncedCopy)
    }

    /// `cloud(...)` with an R4 consent state (`phaseRefinement`) and resolution notices.
    private static func held(_ refinement: SGTasksCloudState.PhaseRefinement?, phase: SGTasksCloudState.Phase = .idle, complete: Bool = true, tasks: [SGTasksCloudTask] = [], entries: [SGTasksCloudEntry] = [], resolutionNotices: [SGTasksCloudResolutionNotice] = []) -> SGTasksCloudState {
        var state = cloud(phase: phase, complete: complete, tasks: tasks, entries: entries)
        state.phaseRefinement = refinement
        state.resolutionNotices = resolutionNotices
        return state
    }

    private static func taskIds(_ rows: [TasksCloudBoardRow]) -> [String] {
        return rows.compactMap { row in
            if case let .task(id) = row { return id }
            return nil
        }
    }

    private static func gregorian(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private static func localDate(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func stamp(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Int32 {
        return Int32(localDate(calendar, year, month, day, hour, minute).timeIntervalSince1970)
    }

    /// Order-independent view of due dates; nil (no deadline) is kept distinct from timestamp 0.
    private static func dueKeys(_ values: [Int32?]) -> [String] {
        return values.map { $0.map { String($0) } ?? "nil" }.sorted()
    }

    static func main() {
        unlinkedAccountsKeepTheirContentBehindBanners()
        gatesUnusableBuildsAndStorage()
        reportsHonestSyncBanners()
        countsPendingAndAttentionSeparately()
        excludesHeldDeleteFromUnsentList()
        mapsQueuedEntryToAccountReason()
        mapsEveryProblemStatus()
        quickAddUsesSelectedListOrVirtualInbox()
        recoversDeletedListSelection()
        ordersInboxListsThenSharedTasks()
        filtersHideSharedTasksFromOwnerLists()
        completedNewestFirstUnknownLast()
        sharedRowsHideOwnerPrivateDataAndOfferLeave()
        rowSyncStatusDistinguishesNotSentFromNeedsAttention()
        listsOnlyActionableInvitations()
        footerIsThePrivacyNoteNeverAnImportRow()
        syncedCopyShowsOwnRowsReadOnly()
        validatesDescriptionWithoutTruncating()
        comparesNormalizedDraftsSoNoOpsAreNotResubmitted()
        refusesUnchangedListRepair()
        offersMoveToInboxOnlyForRefusedListCreates()
        neverResumesLinkingPausesFromRetry()
        expiresByEstimatedServerClock()
        decidesImportAvailabilityFromRowStates()
        calendarAllReproducesEveryCloudBoard()
        calendarDayKeepsStatusAndFooterAndFiltersTasksInBoardOrder()
        calendarUsesTheProjectedSnapshotForPendingEditsAndDeletes()
        calendarKeepsSharedTasksOutOfListsAndAssigneesOwnerOnly()
        gatedCloudCalendarShowsNoCachedTasks()
        emptyClaimWaitsForACompleteSnapshot()
        ownerPermissionsDoNotDependOnSyncState()
        acceptedRecipientMayOnlyCompleteOrLeave()
        recipientWithoutAcceptedInvitationFailsClosed()
        projectionReflectsAccessChangesBetweenSnapshots()
        // R4 (design 30 §5.6, §5.7).
        deviceArchiveFollowsEveryCutOver()
        consentOffShowsCachedContentReadOnly()
        consentFenceKeepsQueuedChangesReadOnly()
        waitingConsentKeepsTheBoardUsableWithoutABanner()
        configurationAndStorageGatesBeatTheConsentHold()
        queuedEntriesReadTheConsentHoldFirst()
        conflictsReadTheirR4Refinement()
        listsResolutionNotices()
        retryIsNotOfferedWhileConsentHolds()
        logoutNoticeNeverClaimsAFakeZero()
        // wf15 (§4.3, §5.6): the owner's Masʼul state words and the name fallback order.
        assigneeStateWordsFollowTheTable()
        assigneeStateWordsWire4VersusWire5()
        assigneeStateDeferredAndQueuedRequestsComeFirst()
        assigneeStateRecipientWithoutZenlygramReadsSentThenExpired()
        assigneeStateDetachLeavesNoAssignee()
        assigneeStateLegacyCandidateNeverReturnsOnceSent()
        assigneeStateActionsFootersAndAccessLoss()
        assigneeNameFallbackOrder()
        boardAssigneeDisplayJoinsTheFacts()
        // wf15 (§5.2): the assignee's board — Menga topshirilgan, provisional rows, the Takliflar count.
        assignedSectionGroupsTasksAssignedToTheUser()
        provisionalRowsFollowTheQueuedAutomaticAccept()
        invitationsCountExcludesContactAcceptPending()
        invitationsRowStaysWhileASenderIsBlocked()
        // wf15 (§3): the one-board resolver, the archive banner model and the scope-key cleanup.
        TasksBoardSourceTests.run()
        print("PASS: Cloud Tasks board model (the two gates left, banners incl. not-signed-in, unsent counts, problem mapping, filters, ordering, shared rows, invitations, footer note, synced copy (own rows, read-only, no status cards), sharing rules, description limits, normalized drafts, repair/move rules, retry pause rule, server clock, calendar day/undated projection, empty state before a complete snapshot, task permissions, recipient access; R4: device archive per cut-over, consent / consent-fence states, consent waiting for the link without a banner, R4 issue lines, resolution notices, logout notice; wf15 §5.2: Menga topshirilgan grouping, provisional rows, the Takliflar count without contact-accept-pending invitations)")
    }

    // MARK: - R4

    static func deviceArchiveFollowsEveryCutOver() {
        check(TasksBoardArchive(cutOver: .none, done: 3, total: 9, keptLocal: 1) == nil, "none: the device board is writable")
        check(TasksBoardArchive(cutOver: .archive(.migrating), done: 3, total: 9, keptLocal: 1) == TasksBoardArchive(reason: .migrating(done: 3, total: 9), keptLocal: 1), "migrating carries its progress")
        check(TasksBoardArchive(cutOver: .archive(.migrating), done: 12, total: 9, keptLocal: 0)?.reason == .migrating(done: 9, total: 9), "done never exceeds total")
        check(TasksBoardArchive(cutOver: .archive(.migrating), done: -1, total: -4, keptLocal: -2) == TasksBoardArchive(reason: .migrating(done: 0, total: 0), keptLocal: 0), "unknown counts read as nothing counted yet")
        let newRows = TasksBoardArchive(cutOver: .archive(.newRows(4)), done: 9, total: 9, keptLocal: 2)
        check(newRows == TasksBoardArchive(reason: .newRows(4), keptLocal: 2) && newRows?.offersCopy == true, "new rows offer the explicit copy")
        let other = TasksBoardArchive(cutOver: .archive(.otherAccount), done: 5, total: 9, keptLocal: 3)
        check(other == TasksBoardArchive(reason: .otherAccount) && other?.keptLocal == 0 && other?.offersCopy == false, "another account's copy carries none of this account's counts")
        let retired = TasksBoardArchive(cutOver: .retired, done: 9, total: 9, keptLocal: 0)
        check(retired == TasksBoardArchive(reason: .retired) && retired?.offersCopy == false, "retired")
        check(TasksBoardArchive(cutOver: .archive(.migrating), done: 0, total: 0, keptLocal: 0)?.offersCopy == false, "migrating offers no copy")
    }

    static func consentOffShowsCachedContentReadOnly() {
        let cached = board(held(.consentRequired(waiting: false), tasks: [task(1)]))
        check(cached.gate == nil && cached.isUsable, "cached content stays visible")
        check(cached.readOnlyReason == .consentOff && cached.isReadOnly && !cached.canCompose, "consent off: read-only, no composer")
        check(cached.banner == .consentRequired(withdrawn: false), "the consent-off banner")
        check(cached.sections[0].first == .banner(.consentRequired(withdrawn: false)), "the banner leads the status section")
        check(taskIds(cached.sections[1]) == [uuid(1).rawValue], "the cached task is shown")
        check(cached.sections[4] == [.privacyNote], "the footer stays the privacy note (no copy offer row exists any more)")

        let withdrawn = board(held(.consentRequired(waiting: false), tasks: [task(1)]), withdrawn: true)
        check(withdrawn.readOnlyReason == .withdrawn && withdrawn.banner == .consentRequired(withdrawn: true), "a withdrawal says so")

        let unlinkedEmpty = board(held(.consentRequired(waiting: false), complete: false), linked: false)
        check(unlinkedEmpty.gate == nil, "no link gate: linking would not turn Cloud on")
        check(unlinkedEmpty.banner == .consentRequired(withdrawn: false) && !unlinkedEmpty.canCompose, "the consent state explains it")
        check(unlinkedEmpty.sections[1].isEmpty, "nothing is claimed missing before a complete snapshot")

        let offline = board(held(.consentRequired(waiting: false), phase: .offline(retryAt: nil), tasks: [task(1)]))
        check(offline.banner == .consentRequired(withdrawn: false), "the consent hold is read before the phase")
        check(tasksCloudReadOnlyReason(held(nil), isConsentWithdrawn: true) == nil, "no refinement: writable (the flag alone does not decide)")
    }

    static func consentFenceKeepsQueuedChangesReadOnly() {
        let fenced = board(held(.consentFenced(effectiveAt: "2026-11-01T10:00:00Z"), phase: .unavailable(retryAt: nil), tasks: [task(1)], entries: [entry(1, .taskCreate, .queued)]))
        check(fenced.gate == nil && fenced.isReadOnly && !fenced.canCompose, "fenced: cached content read-only, no composer")
        check(fenced.readOnlyReason == .consentFenced && fenced.banner == .consentFenced, "the fence banner, not the 503 one")
        check(fenced.sections[0].contains(.unsent(pending: 1, attention: 0)), "queued changes are kept and counted")
        check(fenced.sections[4] == [.privacyNote], "the footer stays the privacy note while fenced")
    }

    /// wf15 §3.2 S3/S4: consent given, the link pending. The synced board (S4) is usable — changes
    /// queue on this device — and shows no banner of its own: the status line under the board says
    /// "Akkaunt bogʻlangach sinxronlash boshlanadi" with the link action. No link gate exists any more.
    static func waitingConsentKeepsTheBoardUsableWithoutABanner() {
        let waiting = held(.consentRequired(waiting: true), complete: false)
        let unlinked = board(waiting, linked: false)
        check(unlinked.gate == nil && unlinked.canCompose && !unlinked.isReadOnly, "unlinked: no gate, drafts queue")
        check(unlinked.banner == nil, "no banner: the line says it")
        check(unlinked.sections[0].isEmpty && unlinked.sections[1].isEmpty, "nothing claimed missing before the first snapshot, no status card")
        let linked = board(waiting, linked: true)
        check(linked.gate == nil && linked.banner == nil && linked.canCompose, "linked, confirmation on its way: usable, quiet")
        let noSession = board(held(.consentRequired(waiting: true), phase: .notSignedIn, complete: false), linked: false)
        check(noSession.gate == nil && noSession.banner == nil && noSession.canCompose, "no session yet: the same usable state")
        let cached = board(held(.consentRequired(waiting: true), tasks: [task(1)]), linked: false)
        check(cached.gate == nil && cached.banner == nil && taskIds(cached.sections[1]) == [uuid(1).rawValue], "cached content of an unlinked account stays visible, no banner")
    }

    static func configurationAndStorageGatesBeatTheConsentHold() {
        check(board(held(.consentRequired(waiting: false), phase: .notConfigured, tasks: [task(1)])).gate == .notConfigured, "no service: its gate")
        check(board(held(.consentFenced(effectiveAt: nil), phase: .storageUnavailable)).gate == .storageUnavailable, "no storage: its gate")
        check(board(held(.consentRequired(waiting: true), phase: .storageUnavailable)).gate == .storageUnavailable, "even while consent waits for the link")
        check(board(held(.consentRequired(waiting: false), phase: .storageUnavailable, tasks: [task(1)]), syncedCopy: true).sections == [[.gate(.storageUnavailable)]], "the synced copy of a store that does not open shows the storage gate")
    }

    static func queuedEntriesReadTheConsentHoldFirst() {
        let queued = entry(1, .taskUpdate, .queued)
        check(tasksCloudIssueDisplayState(queued, phase: .offline(retryAt: nil), refinement: .consentRequired(waiting: false), now: now) == .consentRequired, "consent off before offline")
        check(tasksCloudIssueDisplayState(queued, phase: .unavailable(retryAt: nil), refinement: .consentFenced(effectiveAt: nil), now: now) == .consentFenced, "the fence before the 503 class")
        check(tasksCloudIssueDisplayState(queued, phase: .pausedNotLinked, refinement: .consentRequired(waiting: true), now: now) == .waiting, "consent waiting for the link: plain waiting")
        check(tasksCloudIssueDisplayState(queued, phase: .offline(retryAt: nil), refinement: nil, now: now) == .offline, "no refinement: the R3 reason")
        check(tasksCloudIssueDisplayState(entry(2, .taskCreate, .stalled), phase: .idle, refinement: .consentFenced(effectiveAt: nil), now: now) == .stalled, "a problem keeps its own line")
    }

    static func conflictsReadTheirR4Refinement() {
        let fields: [SGTasksWire.ContentField] = [.title, .dueAt]
        let patch = SGTasksCloudEntry(id: 1, kind: .taskUpdate, resourceId: uuid(1).rawValue, status: .conflict(.revisionChanged), attempts: 1, nextAttemptAt: nil, displayTitle: "T", lastServerTime: nil, mutationKind: .taskPatch, conflictFields: fields)
        check(tasksCloudIssueDisplayState(patch, phase: .idle, now: now) == .fieldsChanged(fields), "field_changed names its fields")
        check(patch.allowedActions == [.reapply, .discard], "Keep mine (reapply) / Use the other version (discard)")
        check(tasksCloudOperationDisplayKind(patch.mutationKind) == .taskUpdate, "a patch reads as a task edit")
        let members = SGTasksCloudEntry(id: 2, kind: .listDelete, resourceId: uuid(100).rawValue, status: .conflict(.revisionChanged), attempts: 1, nextAttemptAt: nil, displayTitle: "L", lastServerTime: nil, isMembersConflict: true)
        check(tasksCloudIssueDisplayState(members, phase: .idle, now: now) == .membersChanged, "members_changed")
        check(members.allowedActions == [.reapply, .discard], "delete again with the current tasks, or keep the list")
        check(tasksCloudOperationDisplayKind(members.mutationKind) == .listDelete, "an R3 kind maps one to one")
        check(tasksCloudIssueDisplayState(entry(3, .taskUpdate, .conflict(.revisionChanged)), phase: .idle, now: now) == .conflict(.revisionChanged), "an R3 conflict stays one")
    }

    static func listsResolutionNotices() {
        let notices = [
            SGTasksCloudResolutionNotice(id: 7, kind: .deleteKept, date: now),
            SGTasksCloudResolutionNotice(id: 8, kind: .changedElsewhere(fields: [.description]), date: now)
        ]
        let state = board(held(nil, resolutionNotices: notices))
        check(state.sections[0] == [.resolutionNotice(id: 7, kind: .deleteKept), .resolutionNotice(id: 8, kind: .changedElsewhere(fields: [.description]))], "resolution notices follow the R3 notices in the status section")
        check(board(held(nil, phase: .notConfigured, resolutionNotices: notices)).sections == [[.gate(.notConfigured)]], "never behind a gate")
    }

    static func retryIsNotOfferedWhileConsentHolds() {
        check(!tasksCloudRetryResumesSync(cloud: held(.consentRequired(waiting: false)), now: now), "consent off")
        check(!tasksCloudRetryResumesSync(cloud: held(.consentRequired(waiting: true)), now: now), "consent waiting")
        check(!tasksCloudRetryResumesSync(cloud: held(.consentFenced(effectiveAt: nil), phase: .unavailable(retryAt: nil)), now: now), "fenced")
        check(tasksCloudRetryResumesSync(cloud: held(nil, phase: .offline(retryAt: nil)), now: now), "R3: offline retries")
        check(!tasksCloudRetryResumesSync(cloud: held(nil, phase: .pausedNotLinked), now: now), "R3: only linking clears a not-linked pause")
    }

    static func logoutNoticeNeverClaimsAFakeZero() {
        // The five existing cases with `unsentAssignees: 0`.
        check(TasksLogoutNotice(counts: nil, unsentAssignees: 0) == .generic(unsentAssignees: 0), "unknown counts: the generic notice")
        check(TasksLogoutNotice(counts: (user: 0, migration: 0), unsentAssignees: 0) == nil, "nothing waiting: no Tasks line")
        check(TasksLogoutNotice(counts: (user: 3, migration: 0), unsentAssignees: 0) == .details(unsent: 3, migrationPending: false, unsentAssignees: 0), "the unsent count")
        check(TasksLogoutNotice(counts: (user: 0, migration: 5), unsentAssignees: 0) == .details(unsent: 0, migrationPending: true, unsentAssignees: 0), "only the migration line")
        check(TasksLogoutNotice(counts: (user: 1, migration: 2), unsentAssignees: 0) == .details(unsent: 1, migrationPending: true, unsentAssignees: 0), "both lines")
        check(TasksLogoutNotice(counts: (user: -1, migration: 0), unsentAssignees: 0) == nil, "a negative count is no change")
        // wf15 §7.4 (revision 3): the unsent-assignees paragraph is decided here, never in the renderer.
        check(TasksLogoutNotice(counts: (user: 0, migration: 0), unsentAssignees: 2) == .details(unsent: 0, migrationPending: false, unsentAssignees: 2), "only unsent assignees: the paragraph alone")
        check(TasksLogoutNotice(counts: nil, unsentAssignees: 2) == .generic(unsentAssignees: 2), "unreadable counts + unsent assignees: the generic notice followed by the paragraph")
        check(TasksLogoutNotice(counts: nil, unsentAssignees: 0) == .generic(unsentAssignees: 0), "unreadable counts, no assignees: the generic notice alone")
        check(TasksLogoutNotice(counts: (user: 3, migration: 0), unsentAssignees: 2) == .details(unsent: 3, migrationPending: false, unsentAssignees: 2), "the unsent count and the paragraph")
        check(TasksLogoutNotice(counts: (user: 0, migration: 0), unsentAssignees: 0) == nil, "nothing at all waiting: nil")
        check(TasksLogoutNotice(counts: (user: 0, migration: 0), unsentAssignees: -3) == nil, "a negative assignee count is no paragraph")
        check(TasksLogoutNotice(counts: nil, unsentAssignees: 2)?.unsentAssignees == 2 && TasksLogoutNotice(counts: (user: 1, migration: 0), unsentAssignees: 0)?.unsentAssignees == 0, "the paragraph count accessor")
    }

    /// wf15 §3.2: the unlinked / notSignedIn gate cards are gone. An unlinked account without a
    /// consent refinement (a build whose permission is not R4) keeps the R3 paused banner; a missing
    /// session is a banner with the link action; cached content is never hidden behind a gate.
    static func unlinkedAccountsKeepTheirContentBehindBanners() {
        let empty = board(cloud(phase: .idle, complete: false), linked: false)
        check(empty.gate == nil && empty.isUsable, "unlinked with nothing cached: no gate")
        check(empty.banner == .paused, "the R3 paused banner (link) instead of the gate")
        check(empty.sections == [[.banner(.paused)], [], [], [], [.privacyNote]], "the banner, nothing claimed missing, the privacy note")

        let cached = board(cloud(phase: .pausedNotLinked, tasks: [task(1)]), linked: false)
        check(cached.gate == nil, "cached cloud content is never hidden behind a gate")
        check(cached.banner == .paused, "account-level pause is reported, content kept")
        check(taskIds(cached.sections[1]) == [uuid(1).rawValue], "the cached task stays visible")

        let notSignedIn = board(cloud(phase: .notSignedIn, complete: false), linked: false)
        check(notSignedIn.gate == nil && notSignedIn.banner == .notSignedIn, "no session: a banner with the link action, no gate card")
        check(notSignedIn.sections[0] == [.banner(.notSignedIn)], "the not-signed-in banner leads the status section")
        check(board(cloud(phase: .notSignedIn, tasks: [task(1)]), linked: true).banner == .notSignedIn, "even with cached content and a link flag")
    }

    static func gatesUnusableBuildsAndStorage() {
        check(board(cloud(phase: .notConfigured, tasks: [task(1)])).gate == .notConfigured, "no service configured: gate even with cache")
        // What the repository publishes for an unconfigured build without a session: the
        // notConfigured gate alone (no link recovery, no paused/link banner).
        let unconfiguredUnlinked = board(cloud(phase: .notConfigured, complete: false), linked: false)
        check(unconfiguredUnlinked.gate == .notConfigured, "no service beats no session/link")
        check(unconfiguredUnlinked.sections == [[.gate(.notConfigured)]], "an unconfigured board shows only its gate")
        check(unconfiguredUnlinked.banner == nil, "no paused/link banner without a service")
        check(board(cloud(phase: .storageUnavailable)).gate == .storageUnavailable, "storage failure: gate")
        check(board(cloud(phase: .idle)).gate == nil, "linked idle board is usable")
    }

    static func reportsHonestSyncBanners() {
        check(board(cloud(phase: .syncing, complete: false)).banner == .loading, "first snapshot loading")
        check(board(cloud(phase: .syncing, complete: true)).banner == nil, "routine sync is quiet")
        check(board(cloud(phase: .offline(retryAt: nil))).banner == .offline, "offline")
        check(board(cloud(phase: .unavailable(retryAt: nil))).banner == .unavailable, "503")
        check(board(cloud(phase: .sessionInvalid)).banner == .sessionInvalid, "session refused")
        check(board(cloud(phase: .rateLimited(retryAt: now.addingTimeInterval(90.2)))).banner == .rateLimited(seconds: 91), "retry-after rounds up")
        check(board(cloud(phase: .rateLimited(retryAt: now.addingTimeInterval(-5)))).banner == .rateLimited(seconds: nil), "elapsed retry-after has no countdown")
        check(board(cloud(phase: .idle, complete: false)).banner == .loading, "idle before the first complete snapshot is still loading")
    }

    static func countsPendingAndAttentionSeparately() {
        let state = board(cloud(entries: [
            entry(1, .taskCreate, .queued),
            entry(2, .taskUpdate, .sending),
            entry(3, .taskComplete, .awaitingSync),
            entry(4, .taskCreate, .creationNotPermitted),
            entry(5, .taskUpdate, .conflict(.revisionChanged)),
            entry(6, .taskDelete, .held)
        ]))
        check(state.pendingCount == 3, "queued/sending/awaiting count as waiting")
        check(state.attentionCount == 2, "refusal and conflict need a choice")
        check(state.sections[0].contains(.unsent(pending: 3, attention: 2)), "status row carries both counts")
    }

    static func excludesHeldDeleteFromUnsentList() {
        let visible = tasksCloudVisibleEntries([entry(1, .taskDelete, .held), entry(2, .taskCreate, .queued)])
        check(visible.map { $0.id } == [2], "a delete inside its Undo window is not an unsent change")
        let onlyHeld = board(cloud(entries: [entry(1, .taskDelete, .held)]))
        check(!onlyHeld.sections[0].contains(where: { if case .unsent = $0 { return true }; return false }), "no unsent row for a held delete alone")
    }

    static func mapsQueuedEntryToAccountReason() {
        let queued = entry(1, .taskUpdate, .queued)
        check(tasksCloudIssueDisplayState(queued, phase: .pausedNotLinked, now: now) == .paused, "paused account")
        check(tasksCloudIssueDisplayState(queued, phase: .offline(retryAt: nil), now: now) == .offline, "offline")
        check(tasksCloudIssueDisplayState(queued, phase: .unavailable(retryAt: nil), now: now) == .serviceUnavailable, "503 is the service, not the connection")
        check(tasksCloudIssueDisplayState(queued, phase: .sessionInvalid, now: now) == .sessionProblem, "refused session waits for linking, not the network")
        check(tasksCloudIssueDisplayState(queued, phase: .notSignedIn, now: now) == .sessionProblem, "missing session waits for linking")
        check(tasksCloudIssueDisplayState(queued, phase: .rateLimited(retryAt: now.addingTimeInterval(30)), now: now) == .rateLimited(seconds: 30), "rate limited")
        check(tasksCloudIssueDisplayState(queued, phase: .idle, now: now) == .waiting, "plain waiting")
    }

    static func mapsEveryProblemStatus() {
        let cases: [(SGTasksCloudEntry.Status, TasksCloudIssueDisplayState)] = [
            (.sending, .sending),
            (.waitingForDependency, .waitingForEarlierChange),
            (.awaitingSync, .awaitingSync),
            (.creationNotPermitted, .creationNotPermitted),
            (.invalid, .invalid),
            (.integrityQuarantine, .integrity),
            (.conflict(.invitationExpired), .conflict(.invitationExpired)),
            (.conflict(.completedTask), .conflict(.completedTask)),
            (.notFound, .notFound),
            (.stalled, .stalled),
            (.accountChanged, .accountChanged)
        ]
        for (status, expected) in cases {
            check(tasksCloudIssueDisplayState(entry(1, .taskUpdate, status), phase: .idle, now: now) == expected, "status \(status)")
        }
        check(tasksCloudOperationDisplayKind(.inviteRespond) == .inviteRespond, "operation kinds map one to one")
        check(tasksCloudOperationDisplayKind(.senderUnblock) == .senderUnblock, "operation kinds map one to one")
    }

    static func quickAddUsesSelectedListOrVirtualInbox() {
        let lists = [list(100, "Work", order: 0)]
        var state = board(cloud(lists: lists))
        check(state.quickAddListId == nil, "All files into the virtual Cloud Inbox, never a hidden list")
        state.select(.folder(id: uuid(100).rawValue))
        check(state.quickAddListId == uuid(100), "selected list receives quick add")
    }

    static func recoversDeletedListSelection() {
        var state = board(cloud(lists: [list(100, "Work", order: 0)]), filter: .folder(id: uuid(100).rawValue))
        check(state.filter == .folder(id: uuid(100).rawValue), "known list selected")
        state.update(cloud: cloud(lists: []), isLinked: true, now: now)
        check(state.filter == .all, "a vanished list falls back to All")
        state.select(.folder(id: "not-a-list"))
        check(state.filter == .all, "unknown ids select All")
    }

    static func ordersInboxListsThenSharedTasks() {
        let lists = [list(100, "A", order: 0), list(101, "B", order: 1)]
        let tasks = [
            task(1, role: .assignee),
            task(2, list: 101, order: 0),
            task(3, list: 100, order: 5),
            task(4, list: 100, order: 1),
            task(5)
        ]
        let state = board(cloud(lists: lists, tasks: tasks))
        check(state.activeTasks.map { $0.id } == [uuid(5), uuid(4), uuid(3), uuid(2), uuid(1)], "inbox, lists in order by sort order, then shared")
        let chips = state.chips
        check(chips.count == 3 && chips[0].activeCount == 5, "All counts every open task including shared")
        check(chips[1].activeCount == 2 && chips[2].activeCount == 1, "list chips count owner tasks")
    }

    static func filtersHideSharedTasksFromOwnerLists() {
        let lists = [list(100, "A", order: 0)]
        let state = board(cloud(lists: lists, tasks: [task(1, list: 100), task(2, role: .assignee), task(3)]), filter: .folder(id: uuid(100).rawValue))
        check(state.activeTasks.map { $0.id } == [uuid(1)], "a list shows only its own owner tasks")
    }

    static func completedNewestFirstUnknownLast() {
        let tasks = [
            task(1, completed: true),
            task(2, completedAt: now.addingTimeInterval(-100)),
            task(3, completedAt: now.addingTimeInterval(-10))
        ]
        let collapsed = board(cloud(tasks: tasks))
        check(collapsed.sections[1] == [.emptyMessage(.allDone)], "everything done")
        check(collapsed.sections[3] == [.completedHeader(count: 3, isExpanded: false)], "collapsed by default")
        let expanded = board(cloud(tasks: tasks), expanded: true)
        check(taskIds(expanded.sections[3]) == [uuid(3).rawValue, uuid(2).rawValue, uuid(1).rawValue], "newest first, unknown (imported) completion last")
    }

    static func sharedRowsHideOwnerPrivateDataAndOfferLeave() {
        let annotation = SGTasksWire.Annotation(telegramUserId: tg(55), displayName: "Private")
        let shared = task(1, role: .assignee, assignment: SGTasksCloudAssignment(invitationId: uuid(9), recipientTgId: tg(10), state: .accepted, expiresAt: nil, isPending: false), annotation: annotation)
        let state = board(cloud(tasks: [shared]))
        let display = state.display(shared)
        check(display.removal == .leave, "recipient leaves, never deletes")
        check(display.assigneeName == nil, "no assignee on shared rows")
        check(display.placement == .sharedBy(ownerTelegramId: "77"), "owner shown as neutral numeric id")

        let own = task(2, annotation: annotation)
        let ownDisplay = board(cloud(tasks: [own])).display(own)
        check(ownDisplay.removal == .delete && ownDisplay.assigneeName == "Private" && ownDisplay.placement == .cloudInbox, "owner row: delete, own assignee, Cloud Inbox")
    }

    static func rowSyncStatusDistinguishesNotSentFromNeedsAttention() {
        let state = board(cloud())
        check(state.display(task(1, isPending: true)).syncStatus == .notSent, "pending")
        check(state.display(task(1, isPending: true, problem: .waitingForDependency)).syncStatus == .notSent, "waiting on an earlier change is still just not sent")
        check(state.display(task(1, isPending: true, problem: .creationNotPermitted)).syncStatus == .needsAttention, "refusal needs attention")
        check(state.display(task(1)).syncStatus == .synced, "synced")
    }

    static func listsOnlyActionableInvitations() {
        let live = SGTasksCloudInvitation(id: uuid(1), taskId: uuid(2), ownerTgId: tg(5), title: "A", dueAt: nil, expiresAt: now.addingTimeInterval(60), isResponsePending: false)
        let expired = SGTasksCloudInvitation(id: uuid(3), taskId: uuid(4), ownerTgId: tg(5), title: "B", dueAt: nil, expiresAt: now.addingTimeInterval(-60), isResponsePending: false)
        let state = board(cloud(invitations: [live, expired]))
        check(state.actionableInvitations.map { $0.id } == [uuid(1)], "expired invitations are not offered")
        check(state.sections[0].contains(.invitations(count: 1)), "invitation row counts actionable ones")
    }

    /// wf15 §3.2: the copy of older device rows is the status line's offer (S6b/S8, CREATE-gated
    /// import), never a row of the synced board; the footer is always exactly the privacy note.
    static func footerIsThePrivacyNoteNeverAnImportRow() {
        check(board(cloud()).sections[4] == [.privacyNote], "complete snapshot")
        check(board(cloud(complete: false)).sections[4] == [.privacyNote], "before a complete snapshot")
        check(board(cloud(phase: .pausedNotLinked, tasks: [task(1)]), linked: false).sections[4] == [.privacyNote], "unlinked")
        check(board(held(.consentRequired(waiting: true), complete: false), linked: false).sections[4] == [.privacyNote], "consent waiting for the link")
    }

    /// wf15 §3.4 (F12): "Sinxronlangan nusxa" — the account's own cached rows after sync went off,
    /// read-only, without any status card, with the synced-copy footer.
    static func syncedCopyShowsOwnRowsReadOnly() {
        let lists = [list(100, "A", order: 0)]
        let accepted = SGTasksCloudAssignment(invitationId: uuid(60), recipientTgId: tg(10), state: .accepted, expiresAt: nil, isPending: false)
        let tasks = [
            task(1, list: 100, order: 0),
            task(2, role: .assignee, assignment: accepted),
            task(3),
            task(4, completedAt: now.addingTimeInterval(-10)),
            task(5, role: .assignee, completedAt: now, assignment: accepted)
        ]
        let live = SGTasksCloudInvitation(id: uuid(50), taskId: uuid(51), ownerTgId: tg(5), title: "A", dueAt: nil, expiresAt: now.addingTimeInterval(60), isResponsePending: false)
        let snapshot = held(.consentRequired(waiting: false), phase: .offline(retryAt: nil), tasks: tasks, entries: [entry(1, .taskUpdate, .queued)])
        var withInvitations = snapshot
        withInvitations.lists = lists
        withInvitations.invitations = [live]
        withInvitations.notices = [SGTasksCloudNotice(id: 3, kind: .sharedAccessLost, date: now)]
        let copy = board(withInvitations, linked: false, withdrawn: true, syncedCopy: true)
        check(copy.isSyncedCopy && copy.isReadOnly && !copy.canCompose && copy.isUsable, "read-only, no composer, usable")
        check(copy.banner == nil && copy.sections[0].isEmpty, "no banner, no unsent, no invitations, no notices")
        check(taskIds(copy.sections[1]) == [uuid(3).rawValue, uuid(1).rawValue], "own open rows only (inbox first, then the list), the shared row left out")
        check(copy.sections[2].isEmpty, "no Menga topshirilgan in the copy (the shared row is not part of it)")
        check(copy.sections[3] == [.completedHeader(count: 1, isExpanded: false)], "own completed rows only")
        check(copy.sections[4] == [.syncedCopyNote], "the synced-copy footer instead of the privacy note")
        check(copy.chips.map { $0.activeCount } == [2, 1], "chips count own tasks only")
        check(dueKeys(copy.calendarDueDates) == dueKeys([nil, nil, nil]), "calendar markers come from the own rows only")
        let newYork = gregorian("America/New_York")
        check(copy.calendarSections(filter: .all, calendar: newYork) == copy.sections, "the All calendar filter is exactly the copy")
        check(copy.calendarSections(filter: .noDeadline, calendar: newYork)[0].isEmpty && copy.calendarSections(filter: .noDeadline, calendar: newYork)[4] == [.syncedCopyNote], "a calendar projection keeps the quiet status section and the footer")
        // Without a consent hold the copy is read-only all the same (the view decides, not the store).
        let stillReadOnly = board(cloud(tasks: [task(1)]), syncedCopy: true)
        check(stillReadOnly.isReadOnly && stillReadOnly.readOnlyReason == nil && stillReadOnly.banner == nil, "read-only without a hold")
        check(board(cloud(), syncedCopy: true).sections == [[], [.emptyMessage(.noTasks)], [], [], [.syncedCopyNote]], "an empty copy says No Tasks and keeps its footer")
        check(!board(cloud(tasks: tasks)).isSyncedCopy && board(cloud(tasks: tasks)).sections[4] == [.privacyNote] && taskIds(board(cloud(tasks: tasks)).sections[1]) == [uuid(3).rawValue, uuid(1).rawValue] && taskIds(board(cloud(tasks: tasks)).sections[2]) == [uuid(2).rawValue], "the board itself keeps the shared row (under Menga topshirilgan) and the privacy note")
    }

    static func comparesNormalizedDraftsSoNoOpsAreNotResubmitted() {
        let original = SGTasksCloudTaskDraft(title: "Buy milk", description: nil)
        check(!tasksCloudDraftHasChanges(SGTasksCloudTaskDraft(title: "  Buy milk \n", description: nil), from: original), "whitespace-only title edit is not a change")
        check(!tasksCloudDraftHasChanges(SGTasksCloudTaskDraft(title: "Buy milk", description: "  \n "), from: original), "blank notes equal no notes")
        check(tasksCloudDraftHasChanges(SGTasksCloudTaskDraft(title: "Buy oat milk", description: nil), from: original), "a real title change")
        check(tasksCloudDraftHasChanges(SGTasksCloudTaskDraft(title: "Buy milk", description: "2 l"), from: original), "a real notes change")
        check(tasksCloudDraftHasChanges(SGTasksCloudTaskDraft(title: "Buy milk", priority: 2), from: original), "priority counts")
        check(tasksCloudNormalizedDraft(SGTasksCloudTaskDraft(title: " x ", description: " ")) == SGTasksCloudTaskDraft(title: "x", description: nil), "normalization trims and clears")
        check(tasksCloudNormalizedDraft(SGTasksCloudTaskDraft(title: "\u{200B}")).title == "\u{200B}", "an invalid title is left for Save to refuse, not rewritten")
        // wf15 §4.1 (review E-1): the editor's "changed elsewhere" question ignores the owner-only
        // annotation — Save never writes it, and the user's own clear changes it under an open editor.
        let ali = SGTasksCloudAnnotationDraft(cloudUserPeerId: 123, displayName: "Ali")
        let opened = SGTasksCloudTaskDraft(title: "Buy milk", annotation: ali, sortOrder: 4)
        check(!tasksCloudDraftChangedElsewhere(SGTasksCloudTaskDraft(title: "Buy milk", annotation: nil, sortOrder: 4), opened: opened), "the user's own annotation clear is not a change elsewhere")
        check(!tasksCloudDraftChangedElsewhere(SGTasksCloudTaskDraft(title: "Buy milk", annotation: ali, sortOrder: 4), opened: SGTasksCloudTaskDraft(title: "Buy milk", sortOrder: 4)), "an annotation written elsewhere is not a field Save writes")
        check(tasksCloudDraftChangedElsewhere(SGTasksCloudTaskDraft(title: "Buy oat milk", annotation: ali, sortOrder: 4), opened: opened), "a title changed elsewhere still asks")
        check(tasksCloudDraftChangedElsewhere(SGTasksCloudTaskDraft(title: "Buy milk", dueAt: 5, sortOrder: 4), opened: opened), "a due date changed elsewhere still asks, with the annotation cleared too")
        check(!tasksCloudDraftChangedElsewhere(opened, opened: opened), "an unchanged task never asks")
    }

    static func refusesUnchangedListRepair() {
        check(!tasksCloudListRepairChangesTitle("Work", refused: "Work"), "same name")
        check(!tasksCloudListRepairChangesTitle("Work", refused: " Work "), "same after trimming")
        check(tasksCloudListRepairChangesTitle("Work 2", refused: "Work"), "renamed")
        check(tasksCloudListRepairChangesTitle("Work", refused: nil), "unknown refused name never blocks")
    }

    static func offersMoveToInboxOnlyForRefusedListCreates() {
        for status: SGTasksCloudEntry.Status in [.creationNotPermitted, .invalid, .integrityQuarantine] {
            check(tasksCloudCanMoveListTasksToInbox(kind: .listCreate, status: status), "refused create \(status)")
        }
        for status: SGTasksCloudEntry.Status in [.stalled, .conflict(.revisionChanged), .notFound, .accountChanged, .queued, .sending] {
            check(!tasksCloudCanMoveListTasksToInbox(kind: .listCreate, status: status), "not for \(status)")
        }
        check(!tasksCloudCanMoveListTasksToInbox(kind: .listUpdate, status: .invalid), "only list creation")
        check(tasksCloudCanMoveListTasksToInbox(problem: .integrityQuarantine), "lists screen: quarantined")
        check(!tasksCloudCanMoveListTasksToInbox(problem: .stalled), "lists screen: stalled")
        check(!tasksCloudCanMoveListTasksToInbox(problem: nil), "lists screen: healthy")
    }

    static func neverResumesLinkingPausesFromRetry() {
        for phase: SGTasksCloudState.Phase in [.pausedNotLinked, .notSignedIn, .sessionInvalid, .notConfigured] {
            check(!tasksCloudRetryResumesSync(phase: phase, now: now), "retry must not touch \(phase)")
        }
        for phase: SGTasksCloudState.Phase in [.idle, .syncing, .offline(retryAt: now.addingTimeInterval(60)), .unavailable(retryAt: nil), .rateLimited(retryAt: nil), .storageUnavailable] {
            check(tasksCloudRetryResumesSync(phase: phase, now: now), "retry allowed for \(phase)")
        }
        // An account-wide rate limit is a durable gate: no Retry before it ends, Retry after.
        check(!tasksCloudRetryResumesSync(phase: .rateLimited(retryAt: now.addingTimeInterval(30)), now: now), "retry offered inside the rate-limit window")
        check(tasksCloudRetryResumesSync(phase: .rateLimited(retryAt: now.addingTimeInterval(-1)), now: now), "retry withheld after the window")
    }

    static func decidesImportAvailabilityFromRowStates() {
        check(tasksCloudImportAvailability(statuses: []) == .nothingOnDevice, "nothing on device")
        check(tasksCloudImportAvailability(statuses: [.alreadyInCloud, .resendPreviousAttempt]) == .canCopy, "a resend is something consent enqueues")
        check(tasksCloudImportAvailability(statuses: [.alreadyInCloud, .needsCorrection(.invalidTitle)]) == .onlyNeedsCorrection, "explain rows that can't be copied")
        check(tasksCloudImportAvailability(statuses: [.alreadyInCloud, .importBlocked]) == .waitingOnEarlierCopy, "a refused earlier copy is resolved in Unsent Changes, not re-copied")
        check(tasksCloudImportAvailability(statuses: [.importPending]) == .waitingOnEarlierCopy, "an earlier copy still in flight")
        check(tasksCloudImportAvailability(statuses: [.alreadyInCloud, .removedFromCloud]) == .alreadyDone, "removed-in-cloud rows are never re-created")
    }

    static func expiresByEstimatedServerClock() {
        // Server said "now" 10 minutes of local time ago; the invitation expired 5 minutes after that.
        var state = cloud(invitations: [SGTasksCloudInvitation(id: uuid(1), taskId: uuid(2), ownerTgId: tg(5), title: "A", dueAt: nil, expiresAt: now.addingTimeInterval(300), isResponsePending: false)])
        state.serverTimeReceivedAt = now.addingTimeInterval(-600)
        check(board(state).actionableInvitations.isEmpty, "expiry follows the advanced server clock, not the stale server time")
        state.serverTimeReceivedAt = nil
        check(board(state).actionableInvitations.count == 1, "no clock estimate: nothing is guessed expired")
    }

    static func validatesDescriptionWithoutTruncating() {
        check(tasksCloudValidateDescription("") == .valid(nil), "empty clears")
        check(tasksCloudValidateDescription(" \n ") == .valid(nil), "whitespace clears")
        check(tasksCloudValidateDescription(" keep spacing ") == .valid(" keep spacing "), "kept verbatim")
        check(tasksCloudValidateDescription(String(repeating: "a", count: 4096)) == .valid(String(repeating: "a", count: 4096)), "at the grapheme limit")
        check(tasksCloudValidateDescription(String(repeating: "a", count: 4097)) == .tooLong, "over the grapheme limit")
        check(tasksCloudValidateDescription(String(repeating: "ж", count: 4096)) == .valid(String(repeating: "ж", count: 4096)), "8192 bytes is within the byte limit")
        check(tasksCloudValidateDescription(String(repeating: "😀", count: 4097)) == .tooLong, "over both limits")
    }

    static func calendarAllReproducesEveryCloudBoard() {
        let newYork = gregorian("America/New_York")
        let lists = [list(100, "A", order: 0)]
        let tasks = [
            task(1, list: 100, dueAt: stamp(newYork, 2026, 3, 8)),
            task(2, dueAt: 0),
            task(3, role: .assignee, dueAt: nil),
            task(4, completedAt: now.addingTimeInterval(-10), dueAt: nil)
        ]
        let live = SGTasksCloudInvitation(id: uuid(50), taskId: uuid(51), ownerTgId: tg(5), title: "A", dueAt: nil, expiresAt: now.addingTimeInterval(60), isResponsePending: false)
        let boards = [
            board(cloud(phase: .notConfigured, tasks: tasks)),
            board(cloud(phase: .idle, complete: false), linked: false),
            board(cloud(phase: .offline(retryAt: nil), lists: lists, tasks: tasks, invitations: [live], entries: [entry(1, .taskUpdate, .queued), entry(2, .taskCreate, .invalid)])),
            board(cloud(lists: lists, tasks: tasks), expanded: true),
            board(cloud(lists: lists, tasks: tasks), filter: .folder(id: uuid(100).rawValue)),
            board(cloud(phase: .pausedNotLinked, tasks: tasks), linked: false),
            board(cloud(lists: lists, tasks: tasks), syncedCopy: true)
        ]
        for state in boards {
            check(state.calendarSections(filter: .all, calendar: newYork) == state.sections, "the All calendar filter is exactly the existing cloud board")
        }
    }

    static func calendarDayKeepsStatusAndFooterAndFiltersTasksInBoardOrder() {
        let newYork = gregorian("America/New_York")
        // 1 November 2026 is a 25-hour day in New York: 23:30 is past a fixed 86,400-second window.
        let inDay = stamp(newYork, 2026, 11, 1, 23, 30)
        let nextMidnight = stamp(newYork, 2026, 11, 2, 0, 0)
        let lists = [list(100, "A", order: 0), list(101, "B", order: 1)]
        let accepted = SGTasksCloudAssignment(invitationId: uuid(60), recipientTgId: tg(10), state: .accepted, expiresAt: nil, isPending: false)
        let tasks = [
            task(1, role: .assignee, assignment: accepted, dueAt: inDay),
            task(2, list: 101, order: 0, dueAt: inDay),
            task(3, list: 100, order: 5, dueAt: stamp(newYork, 2026, 11, 1, 0, 0)),
            task(4, list: 100, order: 1, dueAt: nextMidnight),
            task(5, dueAt: nil),
            task(6, dueAt: 0),
            task(7, list: 100, completedAt: now.addingTimeInterval(-10), dueAt: inDay),
            task(8, completedAt: now.addingTimeInterval(-100), dueAt: stamp(newYork, 2026, 11, 1, 9)),
            task(9, completedAt: now, dueAt: nextMidnight)
        ]
        let live = SGTasksCloudInvitation(id: uuid(50), taskId: uuid(51), ownerTgId: tg(5), title: "A", dueAt: inDay, expiresAt: now.addingTimeInterval(60), isResponsePending: false)
        let snapshot = cloud(phase: .offline(retryAt: nil), lists: lists, tasks: tasks, invitations: [live], entries: [entry(1, .taskUpdate, .queued), entry(2, .taskCreate, .conflict(.revisionChanged))])
        let state = board(snapshot)
        let day = TasksCalendarFilter.day(localDate(newYork, 2026, 11, 1))
        let sections = state.calendarSections(filter: day, calendar: newYork)

        check(sections.count == 5, "the calendar keeps the board's five sections")
        check(sections[0] == state.sections[0], "banner, unsent and invitation rows are account state, never filtered by day")
        check(sections[0].contains(.banner(.offline)) && sections[0].contains(.invitations(count: 1)) && sections[0].contains(.unsent(pending: 1, attention: 1)), "fixture: status rows are present")
        check(sections[4] == [.privacyNote], "the privacy note stays")
        check(taskIds(sections[1]) == [uuid(3).rawValue, uuid(2).rawValue] && taskIds(sections[2]) == [uuid(1).rawValue], "the day's open tasks keep inbox, list order; the day's assigned task is under Menga topshirilgan")
        check(sections[3] == [.completedHeader(count: 2, isExpanded: false)], "the collapsed header counts the day's completed tasks only")
        check(state.sections[3] == [.completedHeader(count: 3, isExpanded: false)], "the default board still counts every completed task")

        let expanded = board(snapshot, expanded: true).calendarSections(filter: day, calendar: newYork)
        check(expanded[3] == [.completedHeader(count: 2, isExpanded: true), .task(id: uuid(7).rawValue), .task(id: uuid(8).rawValue)], "expanded: the day's completed tasks, newest first")

        let nextDay = state.calendarSections(filter: .day(localDate(newYork, 2026, 11, 2)), calendar: newYork)
        check(taskIds(nextDay[1]) == [uuid(4).rawValue] && nextDay[3] == [.completedHeader(count: 1, isExpanded: false)], "the next local midnight opens the next day")

        let undated = state.calendarSections(filter: .noDeadline, calendar: newYork)
        check(taskIds(undated[1]) == [uuid(5).rawValue] && undated[2].isEmpty && undated[3].isEmpty, "only the task without a deadline is undated")
        let epochDay = state.calendarSections(filter: .day(localDate(newYork, 1969, 12, 31)), calendar: newYork)
        check(taskIds(epochDay[1]) == [uuid(6).rawValue], "timestamp 0 is a real deadline on its local day")

        let quiet = state.calendarSections(filter: .day(localDate(newYork, 2026, 11, 5)), calendar: newYork)
        check(quiet[1] == [.emptyMessage(.noTasks)] && quiet[2].isEmpty && quiet[3].isEmpty, "a day without tasks shows the no-tasks message")
        check(dueKeys(state.calendarDueDates) == dueKeys(tasks.map { $0.dueAt }), "All marks every visible task, completed and shared included")
    }

    /// "No Tasks" / "All Done" claim the whole account: never before the first complete snapshot
    /// (the status card speaks instead), while rows this device already holds still show.
    static func emptyClaimWaitsForACompleteSnapshot() {
        let loading = board(cloud(phase: .syncing, complete: false))
        check(loading.banner == .loading, "fixture: first snapshot loading")
        check(loading.sections[1].isEmpty && loading.sections[2].isEmpty && loading.sections[3].isEmpty, "no empty claim while the first snapshot loads")

        let offlineUnsent = board(cloud(phase: .offline(retryAt: nil), complete: false, tasks: [task(1, revision: nil, isPending: true)]))
        check(offlineUnsent.banner == .offline, "fixture: offline before any complete snapshot")
        check(taskIds(offlineUnsent.sections[1]) == [uuid(1).rawValue], "a task created on this device still shows offline")
        let emptyOffline = board(cloud(phase: .offline(retryAt: nil), complete: false))
        check(emptyOffline.banner == .offline && emptyOffline.sections[1].isEmpty, "offline with nothing cached: the offline card, no No Tasks claim")
        let emptyUnavailable = board(cloud(phase: .unavailable(retryAt: nil), complete: false))
        check(emptyUnavailable.banner == .unavailable && emptyUnavailable.sections[1].isEmpty, "service unavailable with nothing cached: no No Tasks claim")

        let onlyCompleted = board(cloud(phase: .idle, complete: false, tasks: [task(2, completedAt: now)]))
        check(onlyCompleted.sections[1].isEmpty, "no All Done claim before a complete snapshot")
        check(onlyCompleted.sections[3] == [.completedHeader(count: 1, isExpanded: false)], "known completed tasks keep their header")
        let expandedCompleted = board(cloud(phase: .idle, complete: false, tasks: [task(2, completedAt: now)]), expanded: true)
        check(expandedCompleted.sections[1].isEmpty, "expanded: still no All Done claim")
        check(expandedCompleted.sections[3] == [.completedHeader(count: 1, isExpanded: true), .task(id: uuid(2).rawValue)], "expanded: the known completed task row itself still shows")

        let newYork = gregorian("America/New_York")
        let dated = board(cloud(phase: .idle, complete: false, tasks: [task(3, dueAt: stamp(newYork, 2026, 3, 9))]))
        check(dated.calendarSections(filter: .day(localDate(newYork, 2026, 3, 8)), calendar: newYork)[1].isEmpty, "a quiet calendar day makes no claim either")
        check(dated.calendarSections(filter: .noDeadline, calendar: newYork)[1].isEmpty, "nor does the undated view")

        // Controls: a complete snapshot still says so, and a gate still replaces everything.
        check(board(cloud()).sections[1] == [.emptyMessage(.noTasks)], "complete and empty: No Tasks")
        check(board(cloud(tasks: [task(2, completedAt: now)])).sections[1] == [.emptyMessage(.allDone)], "complete with only completed tasks: All Done")
        let otherListHasTasks = board(cloud(lists: [list(100, "A", order: 0), list(101, "B", order: 1)], tasks: [task(1, list: 101)]), filter: .folder(id: uuid(100).rawValue))
        check(otherListHasTasks.sections[1] == [.emptyMessage(.noTasks)], "complete: an empty selected list says No Tasks while another list has tasks")
        let completeDated = board(cloud(tasks: [task(3, dueAt: stamp(newYork, 2026, 3, 9))]))
        check(completeDated.calendarSections(filter: .day(localDate(newYork, 2026, 3, 8)), calendar: newYork)[1] == [.emptyMessage(.noTasks)], "complete: a quiet day still says No Tasks")
        check(completeDated.calendarSections(filter: .noDeadline, calendar: newYork)[1] == [.emptyMessage(.noTasks)], "complete: no undated tasks says No Tasks")
        check(board(cloud(phase: .idle, complete: false), linked: false).sections[1].isEmpty, "an unlinked empty board before its first snapshot still claims nothing missing")
    }

    static func calendarUsesTheProjectedSnapshotForPendingEditsAndDeletes() {
        let newYork = gregorian("America/New_York")
        let monday = stamp(newYork, 2026, 3, 9, 10)
        let tuesday = stamp(newYork, 2026, 3, 10, 10)
        // The repository publishes the projected snapshot: task 1's unsent deadline edit moved it from
        // Monday to Tuesday, task 2's held delete removed it, task 3 is an unsent creation on Monday and
        // task 4's unsent edit cleared its deadline.
        let projected = cloud(
            tasks: [
                task(1, isPending: true, dueAt: tuesday),
                task(3, revision: nil, isPending: true, dueAt: monday),
                task(4, isPending: true, dueAt: nil)
            ],
            entries: [entry(1, .taskUpdate, .queued), entry(2, .taskDelete, .held), entry(3, .taskCreate, .queued), entry(4, .taskUpdate, .sending)]
        )
        let state = board(projected)
        let mondayRows = state.calendarSections(filter: .day(localDate(newYork, 2026, 3, 9)), calendar: newYork)
        check(taskIds(mondayRows[1]) == [uuid(3).rawValue], "Monday shows the unsent creation, not the moved or deleted tasks")
        check(taskIds(state.calendarSections(filter: .day(localDate(newYork, 2026, 3, 10)), calendar: newYork)[1]) == [uuid(1).rawValue], "an unsent deadline edit shows on its new day")
        check(taskIds(state.calendarSections(filter: .noDeadline, calendar: newYork)[1]) == [uuid(4).rawValue], "an unsent cleared deadline is undated")
        check(dueKeys(state.calendarDueDates) == dueKeys([tuesday, monday, nil]), "markers follow the projected snapshot; a held delete leaves no marker")
        check(mondayRows[0] == state.sections[0] && mondayRows[0].contains(.unsent(pending: 3, attention: 0)), "unsent changes stay counted on every day")
        check(state.display(state.task(id: uuid(1).rawValue)!).syncStatus == .notSent, "a projected row still reads as not sent")
    }

    static func calendarKeepsSharedTasksOutOfListsAndAssigneesOwnerOnly() {
        let newYork = gregorian("America/New_York")
        let due = stamp(newYork, 2026, 3, 8, 15)
        let annotation = SGTasksWire.Annotation(telegramUserId: tg(55), displayName: "Private")
        let accepted = SGTasksCloudAssignment(invitationId: uuid(60), recipientTgId: tg(10), state: .accepted, expiresAt: nil, isPending: false)
        let shared = task(1, role: .assignee, assignment: accepted, annotation: annotation, dueAt: due)
        let own = task(2, list: 100, annotation: annotation, dueAt: due)
        let snapshot = cloud(lists: [list(100, "A", order: 0)], tasks: [shared, own])
        let day = TasksCalendarFilter.day(localDate(newYork, 2026, 3, 8))

        let all = board(snapshot)
        check(taskIds(all.calendarSections(filter: day, calendar: newYork)[1]) == [uuid(2).rawValue] && taskIds(all.calendarSections(filter: day, calendar: newYork)[2]) == [uuid(1).rawValue], "under All the accepted shared task joins its day under Menga topshirilgan, after the owner tasks")
        let sharedDisplay = all.display(shared)
        check(sharedDisplay.assigneeName == nil && sharedDisplay.assignee == nil && sharedDisplay.removal == .leave, "a shared row on a day still hides the owner's assignee and only offers Leave")
        check(all.display(own).assigneeName == "Private" && all.display(own).removal == .delete, "the owner's own row keeps its assignee and Undo delete")
        check(dueKeys(all.calendarDueDates) == dueKeys([due, due]), "All marks the shared task's day")

        let listed = board(snapshot, filter: .folder(id: uuid(100).rawValue))
        check(taskIds(listed.calendarSections(filter: day, calendar: newYork)[1]) == [uuid(2).rawValue], "a list's day never includes a task shared with the user")
        check(dueKeys(listed.calendarDueDates) == dueKeys([due]), "a list marks only its own owner tasks")
    }

    static func gatedCloudCalendarShowsNoCachedTasks() {
        let newYork = gregorian("America/New_York")
        let due = stamp(newYork, 2026, 3, 8)
        let cached = [task(1, dueAt: due), task(2, completedAt: now, dueAt: nil)]
        let gated: [(TasksCloudBoardState, TasksCloudGate)] = [
            (board(cloud(phase: .notConfigured, tasks: cached)), .notConfigured),
            (board(cloud(phase: .storageUnavailable, tasks: cached)), .storageUnavailable),
            (board(cloud(phase: .storageUnavailable, tasks: cached), syncedCopy: true), .storageUnavailable)
        ]
        for (state, gate) in gated {
            for filter: TasksCalendarFilter in [.all, .day(localDate(newYork, 2026, 3, 8)), .noDeadline] {
                check(state.calendarSections(filter: filter, calendar: newYork) == [[.gate(gate)]], "a gated board shows only its gate on every calendar filter")
            }
            check(state.calendarDueDates.isEmpty, "a gated board marks no cached deadline")
        }
        let paused = board(cloud(phase: .pausedNotLinked, tasks: cached), linked: false)
        check(dueKeys(paused.calendarDueDates) == dueKeys([due, nil]), "content kept visible while paused keeps its markers")
        let unlinked = board(cloud(phase: .idle, complete: false, tasks: cached), linked: false)
        check(dueKeys(unlinked.calendarDueDates) == dueKeys([due, nil]), "an unlinked account's cached rows keep their markers (no gate any more)")
        let noSession = board(cloud(phase: .notSignedIn, tasks: cached), linked: false)
        check(dueKeys(noSession.calendarDueDates) == dueKeys([due, nil]), "so do a missing session's")
    }

    private static func assignment(_ state: SGTasksWire.AssignmentState, invitation: Int = 9, expiresAt: Date? = nil, isPending: Bool = false) -> SGTasksCloudAssignment {
        return SGTasksCloudAssignment(invitationId: uuid(invitation), recipientTgId: tg(5), state: state, expiresAt: expiresAt, isPending: isPending)
    }

    private static func checkOwnerRights(_ permissions: TasksCloudTaskPermissions, _ message: String, line: Int = #line) {
        check(permissions.role == .owner, "\(message): owner role", line: line)
        check(permissions.canEditContent && permissions.canSetCompletion && permissions.canDelete && permissions.canManageSharing, "\(message): every owner right", line: line)
        check(!permissions.canLeave && permissions.recipientInvitationId == nil, "\(message): an owner never leaves their own task", line: line)
    }

    private static func checkNoAccess(_ permissions: TasksCloudTaskPermissions, _ message: String, line: Int = #line) {
        check(permissions.role == .noAccess, "\(message): no access", line: line)
        check(!permissions.canEditContent && !permissions.canSetCompletion && !permissions.canDelete && !permissions.canManageSharing && !permissions.canLeave, "\(message): nothing is offered", line: line)
        check(permissions.recipientInvitationId == nil, "\(message): no invitation to bind an action to", line: line)
    }

    static func ownerPermissionsDoNotDependOnSyncState() {
        checkOwnerRights(TasksCloudTaskPermissions(task: task(1)), "settled owner task")
        // Offline/unsent: a never-acknowledged creation, an edit waiting behind an earlier change and a
        // refused change all keep the owner's content, completion and delete rights (the repository allows
        // them; a Masʼul pick is refused at pick time by the repository, not here).
        let unsentCreate = task(1, revision: nil, isPending: true)
        checkOwnerRights(TasksCloudTaskPermissions(task: unsentCreate), "unsent creation")
        checkOwnerRights(TasksCloudTaskPermissions(task: task(1, isPending: true, problem: .waitingForDependency)), "queued behind an earlier change")
        checkOwnerRights(TasksCloudTaskPermissions(task: task(1, isPending: true, problem: .invalid)), "refused change")
        checkOwnerRights(TasksCloudTaskPermissions(task: task(1, completedAt: now)), "completed task can still be reopened and edited")
        // The owner's own task carries the recipient's accepted invitation; it must never become a Leave handle.
        checkOwnerRights(TasksCloudTaskPermissions(task: task(1, assignment: assignment(.accepted))), "owner of a shared task")
    }

    static func acceptedRecipientMayOnlyCompleteOrLeave() {
        let accepted = task(1, role: .assignee, assignment: assignment(.accepted))
        let permissions = TasksCloudTaskPermissions(task: accepted)
        check(permissions.role == .acceptedRecipient, "accepted invitation: recipient role")
        check(permissions.canSetCompletion && permissions.canLeave, "recipient may complete/reopen and leave")
        check(permissions.recipientInvitationId == uuid(9), "completion/leave are bound to the accepted invitation epoch")
        check(!permissions.canEditContent && !permissions.canDelete && !permissions.canManageSharing, "recipient never edits, deletes or shares")

        // Accepted access does not expire at the (past) pending-invitation deadline.
        let pastDeadline = task(1, role: .assignee, assignment: assignment(.accepted, expiresAt: now.addingTimeInterval(-86_400)))
        check(TasksCloudTaskPermissions(task: pastDeadline) == permissions, "accepted past the invitation expiry keeps the same rights")
        // A recipient's own queued completion leaves the task pending; access is unchanged.
        let queuedCompletion = task(1, role: .assignee, completed: true, assignment: assignment(.accepted), isPending: true)
        check(TasksCloudTaskPermissions(task: queuedCompletion).canSetCompletion && TasksCloudTaskPermissions(task: queuedCompletion).canLeave, "a queued recipient completion can still be reopened or left")
    }

    static func recipientWithoutAcceptedInvitationFailsClosed() {
        checkNoAccess(TasksCloudTaskPermissions(task: nil), "task gone")
        checkNoAccess(TasksCloudTaskPermissions(task: task(1, role: .assignee)), "shared row without any invitation")
        let notAccepted: [SGTasksWire.AssignmentState] = [.pending, .declined, .revoked, .left, .expired]
        for state in notAccepted {
            checkNoAccess(TasksCloudTaskPermissions(task: task(1, role: .assignee, assignment: assignment(state, expiresAt: now.addingTimeInterval(3_600)))), "shared row with a \(state) invitation")
        }
    }

    /// Pure projection only: each snapshot of the same task yields that snapshot's rights. Whether an
    /// editor action re-reads the current snapshot when tapped is not covered here.
    static func projectionReflectsAccessChangesBetweenSnapshots() {
        let accepted = TasksCloudTaskPermissions(task: task(1, role: .assignee, assignment: assignment(.accepted)))
        check(accepted.canLeave, "fixture: recipient with access")
        // The owner stopped sharing while the editor was open: the next projection withdraws everything.
        checkNoAccess(TasksCloudTaskPermissions(task: task(1, role: .assignee, assignment: assignment(.revoked))), "access revoked meanwhile")
        // Re-invited and accepted again: a NEW epoch, so a confirmation shown for the old one is stale.
        let reaccepted = TasksCloudTaskPermissions(task: task(1, role: .assignee, assignment: assignment(.accepted, invitation: 10)))
        check(reaccepted.canLeave && reaccepted.recipientInvitationId == uuid(10) && reaccepted != accepted, "a new accepted epoch replaces the old binding")
        // The same id read under another role never keeps owner rights.
        checkOwnerRights(TasksCloudTaskPermissions(task: task(1)), "fixture: owner")
        check(!TasksCloudTaskPermissions(task: task(1, role: .assignee, assignment: assignment(.accepted))).canEditContent, "an owner→recipient change drops content editing")
    }

    // MARK: - wf15 §4.3: the owner's Masʼul state words (pure `TasksAssigneeDisplayState`)

    private static func assigneeState(_ inputs: TasksAssigneeDisplayInputs) -> TasksAssigneeDisplayState? {
        return TasksAssigneeDisplayState.resolve(inputs)
    }

    /// Every row of the table in order: the word for each server state of the current epoch.
    static func assigneeStateWordsFollowTheTable() {
        let live = now.addingTimeInterval(3_600)
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.pending, expiresAt: live), serverNow: now)) == .sent, "pending, not expired → Yuborildi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.accepted), serverNow: now)) == .accepted, "accepted, task open → Qabul qildi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.accepted), isTaskCompleted: true, serverNow: now)) == .completed, "accepted, completed, nobody named → Bajarildi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.declined), serverNow: now)) == .declined, "declined → Rad etdi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.left), serverNow: now)) == .left, "left → Vazifadan chiqdi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.expired), serverNow: now)) == .expired, "expired on the server → 7 kun ichida qabul qilinmadi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.pending, expiresAt: now.addingTimeInterval(-1)), serverNow: now)) == .expired, "pending past expires_at by the server clock → expired")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.pending, expiresAt: now.addingTimeInterval(-1)), serverNow: nil)) == .sent, "no server clock yet: expiry is never guessed")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.revoked), serverNow: now)) == .removed, "revoked → Olib tashlandi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.revoked, isPending: true), serverNow: now)) == .removed, "a queued revoke already reads Olib tashlandi (the owner's own act)")
        check(assigneeState(TasksAssigneeDisplayInputs(isLegacyCandidate: true, serverNow: now)) == .notSent, "no assignment + a legacy candidate → Hali yuborilmagan")
        check(assigneeState(TasksAssigneeDisplayInputs(serverNow: now)) == nil, "no assignment, no candidate → no assignee (pick)")
        // A completed task with an ended epoch keeps the epoch's word (the editor disables the row).
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.declined), isTaskCompleted: true, serverNow: now)) == .declined, "completed task keeps Rad etdi")
    }

    /// Wire 5 names who completed; wire 4 cannot, so the owner reads Bajarildi, never Bajardi.
    static func assigneeStateWordsWire4VersusWire5() {
        let accepted = assignment(.accepted)
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: accepted, isTaskCompleted: true, completedByAssignee: true, serverNow: now)) == .done, "wire 5, completed_by == assignee → Bajardi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: accepted, isTaskCompleted: true, completedByAssignee: false, serverNow: now)) == .completed, "wire 5, completed by the owner → Bajarildi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: accepted, isTaskCompleted: true, completedByAssignee: false, serverNow: now)) == .completed, "wire 4 (no completed_by) → Bajarildi")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: accepted, isTaskCompleted: false, completedByAssignee: true, serverNow: now)) == .accepted, "completed_by without completion means nothing: Qabul qildi")
        check(TasksAssigneeDisplayState.done.footer == .accepted && TasksAssigneeDisplayState.completed.footer == .accepted, "both completed words keep the accepted footer and actions")
        check(TasksAssigneeDisplayState.done.action == .replaceOrRemove && TasksAssigneeDisplayState.completed.action == .replaceOrRemove, "both completed words keep replace / remove")
    }

    /// The two local rows come before every server state: a request on its way, then a deferral.
    static func assigneeStateDeferredAndQueuedRequestsComeFirst() {
        let live = now.addingTimeInterval(3_600)
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.pending, isPending: true), serverNow: now)) == .sending, "the overlay's pending assignment of a queued request → Yuborilmoqda…")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.declined), hasQueuedRequest: true, serverNow: now)) == .sending, "a queued request over an ended epoch → Yuborilmoqda…")
        check(assigneeState(TasksAssigneeDisplayInputs(hasQueuedRequest: true, serverNow: now)) == .sending, "a queued request on a task without a shadow assignment yet → Yuborilmoqda…")
        check(assigneeState(TasksAssigneeDisplayInputs(isDeferred: true, serverNow: now)) == .queued, "a deferral alone → Navbatda")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.declined), isDeferred: true, serverNow: now)) == .queued, "a deferral over the ended epoch it replaces → Navbatda")
        check(assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.pending, expiresAt: live), hasQueuedRequest: true, isDeferred: true, serverNow: now)) == .sending, "a newer queued pick beats a stale deferral")
        check(TasksAssigneeDisplayState.sending.action == .none && TasksAssigneeDisplayState.sending.footer == .none, "Yuborilmoqda…: no action, no footer")
        check(TasksAssigneeDisplayState.queued.action == .none && TasksAssigneeDisplayState.queued.footer == .queued, "Navbatda: no action, the queued footer")
    }

    /// A recipient without Zenlygram, without consent or with sync off looks exactly like anyone
    /// else (anti-oracle): Yuborildi with the general pending footer, and after 7 days the expired
    /// row with Qayta yuborish.
    static func assigneeStateRecipientWithoutZenlygramReadsSentThenExpired() {
        let expiresAt = now.addingTimeInterval(7 * 86_400)
        let pending = assignment(.pending, expiresAt: expiresAt)
        let before = assigneeState(TasksAssigneeDisplayInputs(assignment: pending, serverNow: now))
        check(before == .sent, "pending, whoever the recipient is → Yuborildi")
        check(before?.footer == .pending && before?.action == .replaceOrRemove, "the general pending footer; replace / remove")
        let sixDays = assigneeState(TasksAssigneeDisplayInputs(assignment: pending, serverNow: now.addingTimeInterval(6 * 86_400)))
        check(sixDays == .sent, "still Yuborildi on day 6 (F17: it reaches them if they start within 7 days)")
        let after = assigneeState(TasksAssigneeDisplayInputs(assignment: pending, serverNow: expiresAt))
        check(after == .expired, "at expires_at by the server clock → 7 kun ichida qabul qilinmadi")
        check(after?.action == .resend && after?.footer == .ended && after?.offersSendAction == true, "→ Qayta yuborish (sgtasks.task.<id>.assignee.resend) with the ended footer")
        let serverExpired = assigneeState(TasksAssigneeDisplayInputs(assignment: assignment(.expired, expiresAt: expiresAt), serverNow: now))
        check(serverExpired == .expired, "the server's own expired state reads the same")
    }

    /// The assignee's consent withdrawal or account erasure deletes the invitation and detaches the
    /// task at once (TasksErasure.php:285-303); the server's 3-day detach of an ended epoch does the
    /// same later. The owner then sees no assignee and simply picks — no explanation.
    static func assigneeStateDetachLeavesNoAssignee() {
        let detached = assigneeState(TasksAssigneeDisplayInputs(assignment: nil, serverNow: now))
        check(detached == nil, "no assignment after the detach → no assignee → pick")
        let detachedButSent = assigneeState(TasksAssigneeDisplayInputs(assignment: nil, isLegacyCandidate: false, serverNow: now))
        check(detachedButSent == nil, "a detached legacy send (in the sent set) is not a candidate again")
        let detachedCandidate = assigneeState(TasksAssigneeDisplayInputs(assignment: nil, isLegacyCandidate: true, serverNow: now))
        check(detachedCandidate == .notSent, "a legacy candidate that was never sent still offers Yuborish")
    }

    /// §7.2 item 5 (revision 3): once sent, a device-row Masʼul leaves the candidates for good on this
    /// device — after decline / left / expired the row shows that state with Qayta yuborish, after the
    /// detach it shows no assignee, never "Hali yuborilmagan" again.
    static func assigneeStateLegacyCandidateNeverReturnsOnceSent() {
        let legacy = task(1, annotation: SGTasksWire.Annotation(telegramUserId: tg(5), displayName: "QA Outsider"))
        let base = cloud(tasks: [legacy])
        var state = board(base)
        check(state.assigneeDisplay(for: legacy)?.state == .notSent, "an annotation-only task not in the sent set → Hali yuborilmagan")
        check(state.assigneeDisplay(for: legacy)?.recipient == tg(5) && state.assigneeDisplay(for: legacy)?.annotationName == "QA Outsider", "its recipient and name come from the annotation")
        state.updateAssignmentFacts(legacyDeviceAssignees: [:], legacySentTaskIds: [legacy.id.rawValue], serverSupportsNote: false)
        check(state.assigneeDisplay(for: legacy) == nil, "in the sent set with no assignment (detached) → no assignee")
        let declined = task(1, assignment: assignment(.declined), annotation: SGTasksWire.Annotation(telegramUserId: tg(5), displayName: "QA Outsider"))
        var declinedState = board(cloud(tasks: [declined]))
        declinedState.updateAssignmentFacts(legacyDeviceAssignees: [:], legacySentTaskIds: [declined.id.rawValue], serverSupportsNote: false)
        check(declinedState.assigneeDisplay(for: declined)?.state == .declined, "sent and declined → Rad etdi, not Hali yuborilmagan")
        let completed = task(2, completed: true, annotation: SGTasksWire.Annotation(telegramUserId: tg(5), displayName: "QA Outsider"))
        check(board(cloud(tasks: [completed])).assigneeDisplay(for: completed) == nil, "a completed task is never a legacy candidate")
        let shared = task(3, role: .assignee, assignment: assignment(.accepted), annotation: SGTasksWire.Annotation(telegramUserId: tg(5), displayName: "x"))
        check(board(cloud(tasks: [shared])).assigneeDisplay(for: shared) == nil, "a shared row never shows the owner's Masʼul line")
    }

    /// The action and footer of every word, and which words ask before a replace / remove.
    static func assigneeStateActionsFootersAndAccessLoss() {
        let expectations: [(TasksAssigneeDisplayState, TasksAssigneeDisplayState.Action, TasksAssigneeDisplayState.Footer, Bool)] = [
            (.sending, .none, .none, false),
            (.queued, .none, .queued, false),
            (.sent, .replaceOrRemove, .pending, true),
            (.accepted, .replaceOrRemove, .accepted, true),
            (.done, .replaceOrRemove, .accepted, true),
            (.completed, .replaceOrRemove, .accepted, true),
            (.declined, .resend, .ended, false),
            (.left, .resend, .ended, false),
            (.expired, .resend, .ended, false),
            (.removed, .pickAgain, .ended, false),
            (.notSent, .send, .notSent, false)
        ]
        check(expectations.count == TasksAssigneeDisplayState.allCases.count, "every word is listed")
        for (state, action, footer, losesAccess) in expectations {
            check(state.action == action, "\(state): action")
            check(state.footer == footer, "\(state): footer")
            check(state.someoneLosesAccess == losesAccess, "\(state): replace alert only when someone loses access")
            check(state.offersSendAction == (action == .resend || action == .send), "\(state): the resend / send a11y action")
            check(state.isEnded == (action == .resend), "\(state): ended")
        }
        // Review E-13: the row itself picks in every state but "Yuborilmoqda…" — in "Navbatda" too,
        // where the newer pick is what cancels the deferral (§12.2); its action column stays empty.
        for state in TasksAssigneeDisplayState.allCases {
            check(state.rowPicks == (state != .sending), "\(state): the row opens the picker")
        }
        check(TasksAssigneeDisplayState.queued.rowPicks && TasksAssigneeDisplayState.queued.action == .none && !TasksAssigneeDisplayState.queued.someoneLosesAccess, "Navbatda: the row picks, without an action row or a replace alert")
    }

    /// §5.6 (revision 3): contact name → the mapped device row's owner-entered name (same id only) →
    /// the annotation's name (same id only) → the numeric id.
    static func assigneeNameFallbackOrder() {
        let numeric = "Telegram foydalanuvchisi 5"
        check(TasksAssigneeNameFallback.resolve(contactName: "Contact", deviceRowName: "Device", annotationName: "Annotation", numeric: numeric) == "Contact", "the viewer's own contact name first")
        check(TasksAssigneeNameFallback.resolve(contactName: nil, deviceRowName: "Device", annotationName: "Annotation", numeric: numeric) == "Device", "then the device row's owner-entered name")
        check(TasksAssigneeNameFallback.resolve(contactName: nil, deviceRowName: nil, annotationName: "Annotation", numeric: numeric) == "Annotation", "then the annotation's name")
        check(TasksAssigneeNameFallback.resolve(contactName: nil, deviceRowName: nil, annotationName: nil, numeric: numeric) == numeric, "the numeric id last")
        check(TasksAssigneeNameFallback.resolve(contactName: " ", deviceRowName: "", annotationName: nil, numeric: numeric) == numeric, "blank names count as absent")
        // The id checks: a non-contact recipient with a mapped device row of the same id shows the
        // owner-entered device name; a row of another id is ignored; the annotation likewise.
        let annotation = SGTasksWire.Annotation(telegramUserId: tg(5), displayName: "QA Outsider (annotation)")
        check(TasksAssigneeNameFallback.resolve(recipient: tg(5), contactName: nil, deviceRow: (tg(5), "QA Outsider"), annotation: annotation, numeric: numeric) == "QA Outsider", "device row of the same id wins over the annotation")
        check(TasksAssigneeNameFallback.resolve(recipient: tg(5), contactName: nil, deviceRow: (tg(6), "Someone Else"), annotation: annotation, numeric: numeric) == "QA Outsider (annotation)", "a device row of another id is ignored; the annotation of this id comes next")
        check(TasksAssigneeNameFallback.resolve(recipient: tg(5), contactName: nil, deviceRow: (tg(6), "Someone Else"), annotation: SGTasksWire.Annotation(telegramUserId: tg(7), displayName: "Other"), numeric: numeric) == numeric, "neither matches the recipient → numeric")
        check(TasksAssigneeNameFallback.resolve(recipient: tg(5), contactName: "QA Assignee", deviceRow: (tg(5), "QA Outsider"), annotation: annotation, numeric: numeric) == "QA Assignee", "a contact name always comes first")
    }

    /// The board state joins the repository's state with the host's facts: the deferral's recipient,
    /// the queued request, the mapped device row (same id only) and the sent set.
    static func boardAssigneeDisplayJoinsTheFacts() {
        let live = now.addingTimeInterval(3_600)
        let sent = task(1, assignment: assignment(.pending, expiresAt: live))
        let declinedWithDeferral = task(2, assignment: assignment(.declined))
        let queued = task(3)
        let deviceMapped = task(4)
        let otherIdRow = task(5, assignment: assignment(.pending, expiresAt: live))
        var cloudState = cloud(tasks: [sent, declinedWithDeferral, queued, deviceMapped, otherIdRow], entries: [
            SGTasksCloudEntry(id: 30, kind: .inviteRequest, resourceId: queued.id.rawValue, status: .queued, attempts: 0, nextAttemptAt: nil, displayTitle: nil, lastServerTime: nil)
        ])
        cloudState.deferredAssignments = [SGTasksCloudDeferredAssignment(taskId: declinedWithDeferral.id, recipientTgId: tg(8), after: now.addingTimeInterval(600))]
        var state = board(cloudState)
        state.updateAssignmentFacts(legacyDeviceAssignees: [
            deviceMapped.id.rawValue: TasksLegacyDeviceAssignee(recipient: tg(5), name: "QA Outsider"),
            otherIdRow.id.rawValue: TasksLegacyDeviceAssignee(recipient: tg(9), name: "Another Row")
        ], legacySentTaskIds: [], serverSupportsNote: false)

        let sentDisplay = state.display(sent).assignee
        check(sentDisplay?.state == .sent && sentDisplay?.recipient == tg(5) && sentDisplay?.deviceRowName == nil && sentDisplay?.annotationName == nil, "a plain pending assignment: Yuborildi for its recipient, no local name")
        let deferred = state.display(declinedWithDeferral).assignee
        check(deferred?.state == .queued && deferred?.recipient == tg(8), "a deferral reads Navbatda for the deferred pick's recipient, not the ended epoch's")
        check(state.display(queued).assignee == nil, "a queued request without a shadow assignment has no recipient to show yet (the overlay normally supplies one)")
        let mapped = state.display(deviceMapped).assignee
        check(mapped?.state == .notSent && mapped?.recipient == tg(5) && mapped?.deviceRowName == "QA Outsider", "a mapped device row without an assignment → Hali yuborilmagan with the owner-entered name")
        let other = state.display(otherIdRow).assignee
        check(other?.state == .sent && other?.deviceRowName == nil, "a device row of another id is ignored for the name")
        state.updateAssignmentFacts(legacyDeviceAssignees: state.legacyDeviceAssignees, legacySentTaskIds: [deviceMapped.id.rawValue], serverSupportsNote: true)
        check(state.display(deviceMapped).assignee == nil, "once in the sent set the mapped row is no candidate")
        check(state.serverSupportsNote, "the wire-5 fact is carried for the footers")
    }

    // MARK: - wf15 §5.2: the assignee's board

    private static func invitation(_ n: Int, task: Int, owner: Int64 = 5, title: String = "Inv", dueAt: Int32? = nil, expiresIn: TimeInterval = 60, responsePending: Bool = false) -> SGTasksCloudInvitation {
        return SGTasksCloudInvitation(id: uuid(n), taskId: uuid(task), ownerTgId: tg(owner), title: title, dueAt: dueAt, expiresAt: now.addingTimeInterval(expiresIn), isResponsePending: responsePending)
    }

    /// "Menga topshirilgan": the accepted assignee rows form their own section after the user's own
    /// open rows (header only when there is a row), completed ones stay under Completed, a list
    /// filter shows none, and a board with assigned rows only claims nothing empty.
    static func assignedSectionGroupsTasksAssignedToTheUser() {
        let accepted = SGTasksCloudAssignment(invitationId: uuid(60), recipientTgId: tg(10), state: .accepted, expiresAt: nil, isPending: false)
        let lists = [list(100, "A", order: 0)]
        let tasks = [
            task(1, order: 1, role: .assignee, assignment: accepted),
            task(2, list: 100),
            task(3, order: 0, role: .assignee, assignment: accepted),
            task(4),
            task(5, role: .assignee, completedAt: now, assignment: accepted)
        ]
        let state = board(cloud(lists: lists, tasks: tasks))
        check(TasksCloudBoardState.assignedSection == 2, "the section right after the own open rows")
        check(taskIds(state.sections[1]) == [uuid(4).rawValue, uuid(2).rawValue], "own open rows: inbox first, then the list; no assignee row among them")
        check(taskIds(state.sections[TasksCloudBoardState.assignedSection]) == [uuid(3).rawValue, uuid(1).rawValue], "Menga topshirilgan: the accepted rows in their sort order")
        check(state.sections[3] == [.completedHeader(count: 1, isExpanded: false)], "a completed assigned task sits under Completed, not in the section")
        check(state.activeAssignedTasks.map { $0.id } == [uuid(3), uuid(1)] && state.activeOwnTasks.map { $0.id } == [uuid(4), uuid(2)], "the two halves of activeTasks")
        check(state.activeTasks.map { $0.id } == [uuid(4), uuid(2), uuid(3), uuid(1)], "activeTasks itself still lists the assigned rows last")
        check(board(cloud(tasks: [task(2), task(4)])).sections[TasksCloudBoardState.assignedSection].isEmpty, "no assigned row: the section (and its header) does not exist")
        let onlyAssigned = board(cloud(tasks: [task(1, role: .assignee, assignment: accepted)]))
        check(onlyAssigned.sections[1].isEmpty && taskIds(onlyAssigned.sections[2]) == [uuid(1).rawValue], "assigned rows only: nothing is claimed empty above them")
        check(board(cloud()).sections[1] == [.emptyMessage(.noTasks)], "without any row the empty message stays")
        let listed = board(cloud(lists: lists, tasks: tasks), filter: .folder(id: uuid(100).rawValue))
        check(taskIds(listed.sections[1]) == [uuid(2).rawValue] && listed.sections[2].isEmpty, "a list filter shows the user's own tasks only: no assigned section")
        check(state.display(tasks[0]).placement == .sharedBy(ownerTelegramId: "77"), "the row's subtitle names the sender by id (the UI shows the contact name, else the numeric id)")
    }

    /// A provisional row is an invitation whose automatic accept is queued or in flight: built from
    /// the preview only, after the accepted rows, gone the moment the id leaves the set (the
    /// invitation, still pending, is back in Takliflar); none in the synced copy or under a list.
    static func provisionalRowsFollowTheQueuedAutomaticAccept() {
        let accepted = SGTasksCloudAssignment(invitationId: uuid(60), recipientTgId: tg(10), state: .accepted, expiresAt: nil, isPending: false)
        let fromContact = invitation(50, task: 51, owner: 5, title: "Hisobot", dueAt: 1_700_000_000, responsePending: true)
        let fromStranger = invitation(52, task: 53, owner: 6, title: "Boshqa")
        var snapshot = cloud(tasks: [task(1, role: .assignee, assignment: accepted), task(2)], invitations: [fromContact, fromStranger])
        snapshot.automaticAcceptInvitationIds = [uuid(50)]
        let state = board(snapshot)
        check(state.provisionalTasks == [TasksCloudProvisionalTask(invitationId: uuid(50), taskId: uuid(51), title: "Hisobot", dueAt: 1_700_000_000, ownerTgId: tg(5))], "a provisional row is the invitation preview: title, due, sender")
        check(state.sections[2] == [.task(id: uuid(1).rawValue), .provisionalTask(invitationId: uuid(50).rawValue)], "it follows the accepted rows in Menga topshirilgan")
        check(state.provisionalTask(invitationId: uuid(50).rawValue)?.taskId == uuid(51) && state.provisionalTask(taskId: uuid(51).rawValue)?.invitationId == uuid(50), "found by either id")
        check(state.actionableInvitations.map { $0.id } == [uuid(52)] && state.sections[0].contains(.invitations(count: 1)), "Takliflar counts the stranger's invitation only")
        check(dueKeys(state.calendarDueDates).contains(dueKeys([1_700_000_000])[0]), "the calendar marks the provisional row's day")

        var failed = snapshot
        failed.automaticAcceptInvitationIds = []
        let afterFailure = board(failed)
        check(afterFailure.provisionalTasks.isEmpty && afterFailure.sections[2] == [.task(id: uuid(1).rawValue)], "the accept failed: no provisional row")
        check(afterFailure.actionableInvitations.map { $0.id } == [uuid(50), uuid(52)] && afterFailure.sections[0].contains(.invitations(count: 2)), "the still-pending invitation is back in Takliflar")

        var alone = cloud(invitations: [fromContact])
        alone.automaticAcceptInvitationIds = [uuid(50)]
        check(board(alone).sections[1].isEmpty && board(alone).sections[2] == [.provisionalTask(invitationId: uuid(50).rawValue)], "a provisional row alone is a row: nothing is claimed empty")
        check(board(snapshot, syncedCopy: true).provisionalTasks.isEmpty && board(snapshot, syncedCopy: true).sections[2].isEmpty, "the synced copy (own rows only) shows no provisional row")
        var listed = snapshot
        listed.lists = [list(100, "A", order: 0)]
        check(board(listed, filter: .folder(id: uuid(100).rawValue)).sections[2].isEmpty, "a list filter shows no provisional row")
    }

    /// Takliflar counts only the invitations the policy left for the user: a contact's invitation
    /// on its way to acceptance is a provisional row instead (a queued manual answer still lists).
    static func invitationsCountExcludesContactAcceptPending() {
        let a = invitation(1, task: 2)
        let b = invitation(3, task: 4, responsePending: true)
        let expired = invitation(5, task: 6, expiresIn: -60)
        var snapshot = cloud(invitations: [a, b, expired])
        check(board(snapshot).actionableInvitations.map { $0.id } == [uuid(1), uuid(3)], "without a queued automatic accept both live invitations wait for the user")
        snapshot.automaticAcceptInvitationIds = [uuid(3)]
        let state = board(snapshot)
        check(state.actionableInvitations.map { $0.id } == [uuid(1)], "a contact's invitation being accepted is not a Takliflar entry")
        check(state.sections[0] == [.invitations(count: 1)], "the row counts one")
        snapshot.automaticAcceptInvitationIds = [uuid(1), uuid(3)]
        check(!board(snapshot).sections[0].contains(where: { if case .invitations = $0 { return true }; return false }), "no Takliflar row while every live invitation is being accepted")
        check(board(snapshot).sections[2] == [.provisionalTask(invitationId: uuid(1).rawValue), .provisionalTask(invitationId: uuid(3).rawValue)], "they are provisional rows instead, in snapshot order (the expired one is neither)")
    }

    /// wf15 §5.1 (review, product P1): "Blocked senders → Unblock" lives only in Takliflar, whose
    /// only entry is this row — it stays while a sender is blocked, even with nothing pending.
    static func invitationsRowStaysWhileASenderIsBlocked() {
        func hasRow(_ state: TasksCloudBoardState) -> Bool {
            return state.sections[0].contains(where: { if case .invitations = $0 { return true }; return false })
        }
        let block = SGTasksWire.Block(id: tg(77), createdAt: SGTasksWire.Instant(date: now)!)
        check(!hasRow(board(cloud())), "nothing pending and nobody blocked: no row")
        var blocked = cloud()
        blocked.blocks = [block]
        check(board(blocked).sections[0] == [.invitations(count: 0)], "a blocked sender keeps the row, with no count")
        check(board(blocked).actionableInvitations.isEmpty, "the row does not invent an invitation")
        // A contact's invitation on its way to acceptance is still not counted.
        blocked.invitations = [invitation(3, task: 4, responsePending: true)]
        blocked.automaticAcceptInvitationIds = [uuid(3)]
        check(board(blocked).sections[0] == [.invitations(count: 0)], "an automatic accept in flight is not counted next to a block")
        blocked.invitations.append(invitation(1, task: 2))
        check(board(blocked).sections[0] == [.invitations(count: 1)], "a stranger's invitation is counted as before")
        check(!hasRow(board(blocked, linked: false, withdrawn: true, syncedCopy: true)), "the synced copy shows no row")
    }
}
