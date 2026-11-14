import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import AlertUI
import UndoUI
import SGEntitlementUI
import SGPayWall
import SGBindAttest
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — synced Tasks: the synced half of the one Tasks screen (wf15 §3). Owned by the board
// controller from the first time the resolver says `synced`; it holds the active account's
// repository, turns repository/entitlement changes into `TasksCloudBoardState`, performs every
// synced action the board, editor and secondary screens offer, and computes the two facts the
// resolver reads from it (`importableDeviceRows` / `importNeedsCorrection`, S6b). No SQL, no
// network: the repository does both.
//
// Lifecycle: `appear()` while the board is on screen with the synced board shown (the repository
// syncs and polls), `disappear()` when it leaves (polling stops and any held delete is promoted —
// its Undo toast is committed first so the UI never offers an Undo the repository no longer honours).
//
// Gate policy: only creating (quick-add task, new list, re-creating a vanished task, import) passes
// `sgEntitlementGate(.createTask)`. Editing, completing, sharing, answering invitations, leaving,
// deleting and Undo are never gated.
//
// R4 (design 30 §5.6): the state also carries the account's cut-over (the sync coordinator's) and the
// consent hold of `phaseRefinement`; while the hold makes the board read-only, every change here
// is refused with its reason before anything is queued.

/// `tasksCloudErrorText` plus the R4 refusal: a change refused because the account's consent was
/// withdrawn says so, never a generic failure.
func tasksCloudRefusalText(_ error: Error, l10n: SGTasksL10n) -> String {
    if case .consentWithdrawn? = error as? SGTasksCloudError {
        return l10n.tasks_cloud_withdrawn
    }
    return tasksCloudErrorText(error, l10n: l10n)
}

extension SGTasksCloudRepository {
    /// R4: why this account's cached cloud content is read-only now; nil when changes may be made.
    /// The withdrawn flag is read on the repository queue only while a consent hold applies.
    func readOnlyReason(_ cloud: SGTasksCloudState) -> TasksCloudReadOnlyReason? {
        guard cloud.phaseRefinement != nil else {
            return nil
        }
        let isWithdrawn = self.onQueue { self.isConsentWithdrawn }
        return tasksCloudReadOnlyReason(cloud, isConsentWithdrawn: isWithdrawn)
    }
}

/// The existing Telegram-account linking screen, in Tasks proof mode: a stored (e.g. Apple-only)
/// session is not a Telegram link, so the screen always runs a fresh Telegram proof and never touches
/// the stored session or install key on failure. Linking is the ONLY recovery for an unlinked or
/// paused account; the not-linked pause is cleared solely from the screen's "bound in this screen"
/// callback (nothing is wiped meanwhile). Pushed by the banners' link action and by the status
/// line's Bogʻlash (S3 shows it over the device board, before any presenter exists).
func tasksPushLinkAccountController(context: AccountContext, accountPeerId: Int64, presentationData: PresentationData, navigationController: NavigationController) {
    let repository = SGTasksCloudRepository.repository(accountPeerId: accountPeerId)
    navigationController.pushViewController(sgLinkTelegramAccountController(
        accountPeerId: accountPeerId,
        presentationData: presentationData,
        requiresTelegramProof: true,
        linked: {
            repository.resumeAfterLinking()
        },
        telegram: sgLinkAccountTelegram(context: context)
    ))
}

extension SGTasksCloudRepository {
    /// wf15 §8.3: the server has spoken wire 5 for this account (`server_wire` meta ≥ 5), read for the
    /// owner's texts (the `_noNote` variants otherwise). A wire-4 build never sees it.
    var isServerWire5Now: Bool {
        return self.onQueue { (try? self.store.map { try Self.isServerWire5($0) }) ?? false }
    }

}

/// The owner's state word (`tasks_assign_state_*`) for a Masʼul state (wf15 §4.3).
func tasksAssigneeStateWord(_ state: TasksAssigneeDisplayState, l10n: SGTasksL10n) -> String {
    switch state {
    case .sending:
        return l10n.tasks_assign_state_sending
    case .queued:
        return l10n.tasks_assign_state_queued
    case .sent:
        return l10n.tasks_assign_state_sent
    case .accepted:
        return l10n.tasks_assign_state_accepted
    case .done:
        return l10n.tasks_assign_state_done
    case .completed:
        return l10n.tasks_assign_state_completed
    case .declined:
        return l10n.tasks_assign_state_declined
    case .left:
        return l10n.tasks_assign_state_left
    case .expired:
        return l10n.tasks_assign_state_expired
    case .removed:
        return l10n.tasks_assign_state_removed
    case .notSent:
        return l10n.tasks_assign_state_notSent
    }
}

/// wf15 §4 (owner side): the one path every Masʼul pick on the synced board takes — the composer pill
/// and the editor row. The first pick per account shows the explainer (`tasks_assign_explainer_*`,
/// marker `sgtasks.assignExplainer.<accountPeerId>`, content-free) → "Tushunarli" → the existing
/// contact picker → the pick-time check (`checkAssignment`: self, non-user, the pacer; a toast,
/// nothing queued). It also carries the device-local facts §4.3 / §5.6 / §7 read: the viewer's
/// contact names (`TasksPeerNameResolver`), the mapped device rows with their owner-entered
/// assignees (the legacy assignee offer of §7.2 and its `remaining`, `SGTasksLocalMarkers`), the
/// durable sent set of §7.4 (`sgtasks.legacyAssignees.sent.<accountPeerId>`, cloud task ids,
/// written before a Yuborish enqueues its request) and whether the server speaks wire 5.
final class TasksAssignmentCoordinator {
    let context: AccountContext
    let repository: SGTasksCloudRepository
    let accountPeerId: Int64
    let names: TasksPeerNameResolver
    /// §7.2 item 1: the device rows with a local assignee and their mappings (recomputed by the
    /// presenter where the import facts are: on appearance, after a pushed screen, on a cut-over
    /// change, at the first complete snapshot).
    private var legacyDeviceFacts: TasksLegacyDeviceFacts = .empty
    /// §5.6 fallback (1): cloud task id → the mapped device row's assignee.
    private(set) var legacyDeviceAssignees: [String: TasksLegacyDeviceAssignee] = [:]
    /// §7.4 `remaining`: the device-row candidates still unsent, as last computed (the Lists entry
    /// `tasks_legacySheet_listsEntry(n)` follows it while the screen is open).
    let unsentLegacyAssignees = ValuePromise<Int>(0, ignoreRepeated: true)
    private var pickerClosedDisposable: Disposable?
    /// wf15 §3.2 S4 / D1 (assigning needs consent AND a link): the one-board resolver's `assign`
    /// answer with the two ways forward, installed by the board controller. The synced board is
    /// also shown while the account waits for its link (S4) — nothing may be queued then. nil (the
    /// synced-copy screen, which never assigns) = no gate.
    var assignGate: TasksDeviceAssignGate?

    init(context: AccountContext, repository: SGTasksCloudRepository) {
        self.context = context
        self.repository = repository
        self.accountPeerId = repository.accountPeerId
        self.names = TasksPeerNameResolver(context: context)
    }

    deinit {
        self.pickerClosedDisposable?.dispose()
    }

    private var l10n: SGTasksL10n {
        return SGTasksL10n(self.context.sharedContext.currentPresentationData.with { $0 }.strings)
    }

    // MARK: Facts

    private var explainerKey: String {
        return "sgtasks.assignExplainer.\(self.accountPeerId)"
    }

    /// §7.4: the durable sent set (`SGTasksLocalMarkers`, `sgtasks.legacyAssignees.sent.<id>`). It
    /// has the lifetime of the D4 marker: it survives a non-last logout and goes at the last one.
    var legacySentTaskIds: Set<String> {
        return SGTasksLocalMarkers.legacySentTaskIds(defaults: self.markerDefaults, accountPeerId: self.accountPeerId)
    }

    /// `.standard` in production (the repository's environment; host tests inject a suite).
    private var markerDefaults: UserDefaults {
        return self.repository.environment.defaults
    }

    /// Recorded BEFORE the `invitation.request` is enqueued (§4.2 item 7, §7.3), so the task never
    /// reads "Hali yuborilmagan" again on this device.
    func markLegacySent(_ taskId: SGTasksWire.UUID) {
        SGTasksLocalMarkers.markLegacySent([taskId.rawValue], defaults: self.markerDefaults, accountPeerId: self.accountPeerId)
    }

    /// A send that queued nothing (a pick-time refusal) is not a send.
    func unmarkLegacySent(_ taskId: SGTasksWire.UUID) {
        SGTasksLocalMarkers.unmarkLegacySent(taskId.rawValue, defaults: self.markerDefaults, accountPeerId: self.accountPeerId)
    }

    var serverSupportsNote: Bool {
        return self.repository.isServerWire5Now
    }

    /// Re-reads the device rows and the mappings (the slow half of the offer).
    func refreshDeviceAssignees() {
        self.legacyDeviceFacts = self.repository.legacyDeviceFacts()
    }

    /// §7.2: the legacy assignee offer over the cached device facts, the board as it stands and the
    /// sent set; the §5.6 name map and `remaining` (§7.4) are rewritten from it.
    @discardableResult
    func refreshLegacyOffer() -> SGTasksLegacyAssigneeOffer {
        let offer = self.repository.legacyAssigneeOffer(facts: self.legacyDeviceFacts)
        self.legacyDeviceAssignees = offer.deviceAssignees
        SGTasksLocalMarkers.setUnsentLegacyAssignees(offer.remaining, defaults: self.markerDefaults, accountPeerId: self.accountPeerId)
        self.unsentLegacyAssignees.set(offer.remaining)
        return offer
    }

    /// The §4.3 row of a task as the repository's state and the device-local facts give it now.
    func display(for task: SGTasksCloudTask, cloud: SGTasksCloudState) -> TasksAssigneeDisplay? {
        let id = task.id.rawValue
        return tasksAssigneeDisplay(task: task, cloud: cloud, serverNow: cloud.estimatedServerNow(), legacyDeviceAssignee: self.legacyDeviceAssignees[id], isLegacySent: self.legacySentTaskIds.contains(id))
    }

    /// §5.6: contact name → device-row name → annotation name → numeric, the three names isolated
    /// (external text), the numeric sentence as the strings give it.
    func displayName(for display: TasksAssigneeDisplay, contactName: String?) -> String {
        let l10n = self.l10n
        return TasksAssigneeNameFallback.resolve(
            contactName: contactName.map { tasksIsolatedDisplayText($0) },
            deviceRowName: display.deviceRowName.map { tasksIsolatedDisplayText($0) },
            annotationName: display.annotationName.map { tasksIsolatedDisplayText($0) },
            numeric: l10n.tasks_cloud_telegramUser(display.recipient.rawValue)
        )
    }

    /// The cached contact name of the display's recipient, through the same order.
    func cachedDisplayName(for display: TasksAssigneeDisplay) -> String {
        return self.displayName(for: display, contactName: self.names.cachedName(for: display.recipient))
    }

    // MARK: The pick (§4.2 items 1–3)

    /// Explainer (once per account) → picker → pick-time check. `completion` receives a contact that
    /// passed the check; a refusal is a toast and nothing is queued. `closed` runs once the picker
    /// left the stack by any path (the callers hand the keyboard back).
    func pick(navigationController: NavigationController, present: @escaping (ViewController) -> Void, presentToast: @escaping (UndoOverlayController) -> Void, closed: @escaping () -> Void, completion: @escaping (TodoAssignee) -> Void) {
        guard self.allowsAssigning(present: present, presentToast: presentToast) else {
            closed()
            return
        }
        let proceed: () -> Void = { [weak self, weak navigationController] in
            guard let self, let navigationController else {
                return
            }
            self.pushPicker(navigationController: navigationController, presentToast: presentToast, closed: closed, completion: completion)
        }
        guard !UserDefaults.standard.bool(forKey: self.explainerKey) else {
            proceed()
            return
        }
        let l10n = self.l10n
        let text = self.serverSupportsNote ? l10n.tasks_assign_explainer_text : l10n.tasks_assign_explainer_text_noNote
        let explainerKey = self.explainerKey
        present(textAlertController(context: self.context, title: l10n.tasks_assign_explainer_title, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: l10n.tasks_assign_explainer_ok, action: {
                UserDefaults.standard.set(true, forKey: explainerKey)
                proceed()
            })
        ], dismissOnOutsideTap: false))
    }

    /// True when a pick, a Qayta yuborish or a Yuborish may queue its `invitation.request` now: the
    /// resolver says `available`. Otherwise — the synced board of an account whose link dropped
    /// (S4, `needsLink`) or that is not ready yet (`wait`) — the same answer as on the device board
    /// (§4.4): the needs-sync sheet with its action, or the wait toast; nothing is queued, the pacer
    /// is not charged, and false.
    func allowsAssigning(present: (ViewController) -> Void, presentToast: (UndoOverlayController) -> Void) -> Bool {
        guard let gate = self.assignGate, gate.availability() != .available else {
            return true
        }
        return tasksDeviceAssignAllowsPicker(gate, context: self.context, present: present, presentToast: presentToast)
    }

    private func pushPicker(navigationController: NavigationController, presentToast: @escaping (UndoOverlayController) -> Void, closed: @escaping () -> Void, completion: @escaping (TodoAssignee) -> Void) {
        let disposable = pushTasksAssigneePicker(context: self.context, navigationController: navigationController, title: { strings in SGTasksL10n(strings).tasks_assignee_pickerTitle }, completion: { [weak self] assignee in
            guard let self, let assignee else {
                return
            }
            // Refused at pick time (self, non-user, the pacer): a sentence, nothing queued.
            do {
                try self.repository.checkAssignment(recipientCloudUserPeerId: assignee.peerId)
            } catch {
                presentToast(tasksNoticeToast(context: self.context, text: tasksCloudRefusalText(error, l10n: self.l10n)))
                return
            }
            completion(assignee)
        }, closed: closed)
        if let disposable {
            self.pickerClosedDisposable?.dispose()
            self.pickerClosedDisposable = disposable
        }
    }
}

struct TasksCloudBoardHost {
    let present: (ViewController) -> Void
    let presentUndo: (UndoOverlayController) -> Void
    let navigationController: () -> NavigationController?
    let sourceView: () -> UIView?
    let requestLayout: () -> Void
    /// A fact the one-board resolver reads changed (the snapshot completed, the consent hold, the
    /// phase, the count of older device rows the explicit copy would still enqueue): the board
    /// controller re-resolves its presentation.
    let boardFactsChanged: () -> Void
}

/// The facts of the synced board that the one-board resolver reads (wf15 §3.1); compared so the host
/// is told only when one of them changed.
private struct TasksCloudBoardFacts: Equatable {
    var importableDeviceRows: Int?
    var importNeedsCorrection: Int
    var snapshotComplete: Bool
    var readOnly: TasksCloudReadOnlyReason?
    var phase: SGTasksCloudState.Phase
    /// wf15 §7: the device-row candidates of the legacy assignee sheet still unsent.
    var unsentLegacyAssignees: Int
}

final class TasksCloudBoardPresenter {
    private let context: AccountContext
    let repository: SGTasksCloudRepository
    private let accountPeerId: Int64
    private let host: TasksCloudBoardHost
    private(set) var state: TasksCloudBoardState
    /// S6b (wf15 §3.2): the older device rows the explicit, CREATE-gated copy would still enqueue
    /// (`prepareLegacyImport`'s items whose status `isEnqueuedByConsent`, counted as tasks); nil until
    /// the account's snapshot is complete and the count is known; 0 = nothing left to copy.
    private(set) var importableDeviceRows: Int?
    /// S6b: the preview's tasks that need a correction first (the resolver shows them as kept local).
    private(set) var importNeedsCorrection: Int = 0
    private var lastBoardFacts: TasksCloudBoardFacts?
    /// The composer's deadline and Masʼul drafts, kept (like the device board's) across pickers,
    /// reloads and list switches; cleared when a task is created with them or the user clears them.
    /// The Masʼul is the recipient of the `invitation.request` the create chains (wf15 §4.2 item 4).
    private var quickAddDueAt: Int32?
    private var quickAddAssignee: TodoAssignee?
    /// wf15 §4: the explainer, the picker with its pick-time check, the names and the legacy facts.
    let assignment: TasksAssignmentCoordinator
    private var presentationData: PresentationData
    private var observers: [NSObjectProtocol] = []
    private var isActive = false
    /// The Undo toast currently offered for a held delete (at most one).
    private weak var undoController: UndoOverlayController?
    /// The cloud editor this board pushed, while it is on the navigation stack.
    private weak var openEditor: ViewController?
    /// A delete chosen in the editor while the board was off screen; held once the board is back.
    private var pendingEditorDelete: SGTasksWire.UUID?

    private(set) var node: TasksCloudBoardNode?

    init(context: AccountContext, presentationData: PresentationData, host: TasksCloudBoardHost) {
        let accountPeerId = context.account.peerId.toInt64()
        let repository = SGTasksCloudRepository.repository(accountPeerId: accountPeerId)
        self.context = context
        self.accountPeerId = accountPeerId
        self.repository = repository
        self.host = host
        self.presentationData = presentationData
        self.assignment = TasksAssignmentCoordinator(context: context, repository: repository)
        let cloud = repository.state
        self.state = TasksCloudBoardState(
            cloud: cloud,
            isLinked: SGEntitlement.shared.isLinked(accountPeerId: accountPeerId),
            now: Date(),
            isConsentWithdrawn: repository.readOnlyReason(cloud) == .withdrawn
        )
        self.assignment.names.changed = { [weak self] in
            // More contact names are known: the Masʼul lines are rendered again.
            self?.node?.reloadAssigneeNames()
        }
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: SGTasksCloudRepository.didChangeNotification, object: self.repository, queue: .main, using: { [weak self] _ in
            self?.reloadState()
        }))
        // Linking (or unlinking) changes what Cloud can show. It never resumes a paused account by
        // itself: a not-linked pause clears only through the explicit linking flow (wire R3), and
        // routine syncing is the repository's own job while the board is started.
        self.observers.append(center.addObserver(forName: SGEntitlement.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.reloadState()
        }))
        self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            // The repository promotes held deletes on background; the toast must not outlive that.
            self?.commitUndo()
        }))
        // R4: a migration step changes what the explicit copy would still enqueue (S6b's count).
        self.observers.append(center.addObserver(forName: SGTasksSyncCoordinator.cutOverDidChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self, notification.userInfo?["accountPeerId"] as? Int64 == self.accountPeerId else {
                return
            }
            self.reloadState(recheckImport: true)
        }))
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.undoController?.dismissWithCommitAction()
        if self.isActive {
            self.repository.stop()
        }
    }

    private var l10n: SGTasksL10n {
        return SGTasksL10n(self.presentationData.strings)
    }

    func makeNode() -> TasksCloudBoardNode {
        if let node = self.node {
            return node
        }
        let rowActions = TasksRowActions(
            setCompleted: { [weak self] id, isCompleted, displayed in self?.setTaskCompleted(id: id, isCompleted: isCompleted, displayed: displayed) },
            edit: { [weak self] id in self?.openTask(id: id) },
            delete: { [weak self] id, displayed in self?.removeTask(id: id, displayed: displayed) }
        )
        let interaction = TasksCloudBoardInteraction(
            selectFilter: { [weak self] filter in self?.updateState { $0.select(filter) } },
            createList: { [weak self] in self?.createList() },
            toggleCompletedSection: { [weak self] in self?.updateState { $0.isCompletedExpanded.toggle() } },
            rowActions: rowActions,
            submitQuickAdd: { [weak self] text in self?.submitQuickAdd(text) ?? false },
            pickQuickAddAssignee: { [weak self] in self?.pickQuickAddAssignee() },
            clearQuickAddAssignee: { [weak self] in self?.updateQuickAddAssignee(nil) },
            pickQuickAddDeadline: { [weak self] in self?.pickQuickAddDeadline() },
            clearQuickAddDeadline: { [weak self] in self?.updateQuickAddDueAt(nil) },
            openLinkAccount: { [weak self] in self?.openLinkAccount() },
            retrySync: { [weak self] in self?.retrySync() },
            openUnsentChanges: { [weak self] in self?.openUnsentChanges() },
            openInvitations: { [weak self] in self?.openInvitations() },
            dismissNotice: { [weak self] id in self?.repository.dismissNotice(id: id) },
            assigneeName: { [weak self] display in
                guard let self else {
                    return ""
                }
                return self.assignment.cachedDisplayName(for: display)
            },
            senderName: { [weak self] rawTelegramId in
                // wf15 §5.6: a name only for the viewer's own contacts; the node shows the numeric id otherwise.
                guard let self, let id = SGTasksWire.TelegramId(rawTelegramId), let name = self.assignment.names.cachedName(for: id) else {
                    return nil
                }
                return tasksIsolatedDisplayText(name)
            },
            openProvisional: { [weak self] invitationId in self?.openProvisional(invitationId: invitationId) },
            calendarShown: { [weak self] in
                guard let self else {
                    return
                }
                SGTasksAnalytics.emit(.screen("tasks.calendar"), accountPeerId: self.accountPeerId)
                SGTasksAnalytics.emit(.featureUsed("tasks_calendar"), accountPeerId: self.accountPeerId)
            }
        )
        let node = TasksCloudBoardNode(state: self.state, quickAddDueAt: self.quickAddDueAt, quickAddAssigneeName: self.quickAddAssignee?.displayName, presentationData: self.presentationData, interaction: interaction)
        self.node = node
        return node
    }

    // MARK: - Lifecycle

    func appear() {
        guard !self.isActive else {
            // Back from a pushed screen (the import among them): the copy's count is re-asked.
            self.reloadState(recheckImport: true)
            return
        }
        self.isActive = true
        self.reloadState(recheckImport: true)
        self.repository.start()
        if let taskId = self.pendingEditorDelete {
            self.pendingEditorDelete = nil
            self.deleteTask(taskId)
        }
    }

    /// wf15 §3.3: the device composer's draft, carried over when the board flips from the device
    /// rows to the synced board (S5 → S7). The chosen contact becomes the Masʼul the create will
    /// send the task to, as a pick on this board would (the pick-time check runs at the create).
    func adoptQuickAddDraft(title: String?, dueAt: Int32?, assignee: TodoAssignee?) {
        if let dueAt {
            self.updateQuickAddDueAt(dueAt)
        }
        if let assignee {
            self.updateQuickAddAssignee(assignee)
        }
        if let title, !title.isEmpty {
            self.node?.setQuickAddDraftTitle(title)
            self.host.requestLayout()
        }
    }

    func disappear() {
        guard self.isActive else {
            return
        }
        self.isActive = false
        self.commitUndo()
        self.repository.stop()
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
    }

    func refreshTimeDependentText() {
        self.reloadState()
    }

    /// `recheckImport` re-asks how many older device rows are not yet in this account's synced board
    /// (on appearance, after a pushed screen, on a cut-over change, and once the first complete
    /// snapshot arrives), so the S6b offer disappears after everything was copied instead of
    /// lingering because the originals stay on the device. The host is told when a fact the
    /// resolver reads changed.
    private func reloadState(recheckImport: Bool = false) {
        let cloud = self.repository.state
        let becameComplete = cloud.hasCompleteSnapshot && !self.state.cloud.hasCompleteSnapshot
        if recheckImport || becameComplete || (!cloud.hasCompleteSnapshot && self.importableDeviceRows != nil) {
            let facts = self.importFacts(cloud: cloud)
            self.importableDeviceRows = facts.importable
            self.importNeedsCorrection = facts.needsCorrection
            // The mapped device rows (§5.6 fallback 1) move with the same facts; the contacts may
            // have changed while another screen was up.
            self.assignment.refreshDeviceAssignees()
            self.assignment.names.invalidate()
        }
        let isLinked = SGEntitlement.shared.isLinked(accountPeerId: self.accountPeerId)
        let readOnly = self.repository.readOnlyReason(cloud)
        // wf15 §7.2 / §7.4: the offer follows every board change (an assignment that ended, a sent
        // set entry); the §5.6 name map and `remaining` come from it.
        let offer = self.assignment.refreshLegacyOffer()
        let legacyDeviceAssignees = offer.deviceAssignees
        let legacySentTaskIds = self.assignment.legacySentTaskIds
        let serverSupportsNote = self.assignment.serverSupportsNote
        self.updateState { state in
            state.update(cloud: cloud, isLinked: isLinked, now: Date(), isConsentWithdrawn: readOnly == .withdrawn)
            state.updateAssignmentFacts(legacyDeviceAssignees: legacyDeviceAssignees, legacySentTaskIds: legacySentTaskIds, serverSupportsNote: serverSupportsNote)
        }
        // The names of every Masʼul on the board and of everyone who assigned a task to the user —
        // the accepted rows' owners and the provisional rows' senders (contacts only; the rest stay
        // numeric, wf15 §5.6).
        var peers = Set(cloud.tasks.compactMap { self.state.assigneeDisplay(for: $0)?.recipient })
        peers.formUnion(cloud.tasks.filter { $0.viewerRole == .assignee }.compactMap { $0.ownerTgId })
        peers.formUnion(self.state.provisionalTasks.map { $0.ownerTgId })
        self.assignment.names.resolve(peers)
        let boardFacts = TasksCloudBoardFacts(importableDeviceRows: self.importableDeviceRows, importNeedsCorrection: self.importNeedsCorrection, snapshotComplete: cloud.hasCompleteSnapshot, readOnly: readOnly, phase: cloud.phase, unsentLegacyAssignees: offer.remaining)
        if boardFacts != self.lastBoardFacts {
            self.lastBoardFacts = boardFacts
            self.host.boardFactsChanged()
        }
    }

    /// S6b's two counts (wf15 §3.1 `importableDeviceRows` / `importNeedsCorrection`): nil until the
    /// snapshot is complete; then the tasks the explicit copy would enqueue when the preview's
    /// availability is `canCopy` (rows that can never be copied as they are, or whose earlier copy
    /// waits in Unsent Changes, do not count), and the tasks that need a correction first. Under R4
    /// rules every row the migration copied is mapped, so the offer ends with the copy.
    private func importFacts(cloud: SGTasksCloudState) -> (importable: Int?, needsCorrection: Int) {
        guard cloud.hasCompleteSnapshot else {
            return (nil, 0)
        }
        guard !TodoStorage.loadTasks().isEmpty, let preview = try? self.repository.prepareLegacyImport(locale: self.importLocale) else {
            return (0, 0)
        }
        let needsCorrection = preview.tasks.filter { item in
            if case .needsCorrection = item.status {
                return true
            }
            return false
        }.count
        guard preview.availability == .canCopy else {
            return (0, needsCorrection)
        }
        return (preview.importableTaskCount, needsCorrection)
    }

    /// Placeholder language of an R4 copy for an account without a migration record yet.
    private var importLocale: TodoCloudMigrationRecord.Locale {
        return TodoCloudMigrationRecord.Locale(languageCode: self.presentationData.strings.primaryComponent.languageCode)
    }

    /// The board's Retry: a user-initiated sync attempt. Never offered for (and never clears) a pause
    /// only linking can resolve, nor while the consent gate holds every request.
    private func retrySync() {
        guard tasksCloudRetryResumesSync(cloud: self.repository.state, now: Date()) else {
            return
        }
        self.repository.refresh()
    }

    /// R4: while the consent hold makes the board read-only, a change says why and queues nothing.
    private func refuseReadOnlyChange() -> Bool {
        guard let reason = self.repository.readOnlyReason(self.repository.state) else {
            return false
        }
        self.host.presentUndo(tasksNoticeToast(context: self.context, text: self.l10n.tasks_cloud_readOnly(reason)))
        return true
    }

    private func updateState(_ f: (inout TasksCloudBoardState) -> Void) {
        var state = self.state
        f(&state)
        guard state != self.state else {
            return
        }
        self.state = state
        self.node?.update(state: state)
        self.host.requestLayout()
    }

    private func presentError(_ error: Error) {
        self.host.present(tasksErrorAlert(context: self.context, text: tasksCloudRefusalText(error, l10n: self.l10n)))
    }

    private func push(_ controller: ViewController) {
        self.host.navigationController()?.pushViewController(controller)
    }

    // MARK: - Quick add

    private func submitQuickAdd(_ rawTitle: String) -> Bool {
        if self.refuseReadOnlyChange() {
            return false
        }
        let title: String
        switch tasksValidateTitle(rawTitle, limit: TasksTitleLimit.task) {
        case .empty:
            return false
        case .tooLong:
            self.host.present(tasksErrorAlert(context: self.context, text: self.l10n.tasks_error_titleTooLong(limit: TasksTitleLimit.task)))
            return false
        case let .valid(validTitle):
            title = validTitle
        }
        guard tasksCreateGate(context: self.context, present: self.host.present) else {
            return false
        }
        // wf15 §4.2 item 4: the chosen Masʼul goes with the create — one transaction enqueues the
        // `task.create` (annotation null) and the `invitation.request` on the same task key. A
        // refused pick (self, non-user, the pacer) queues nothing, the create included: the error is
        // shown and the whole draft stays, never silently dropped.
        do {
            let id = try self.repository.createTask(SGTasksCloudTaskDraft(listId: self.state.quickAddListId, title: title, dueAt: self.quickAddDueAt), assignee: self.quickAddAssignee?.peerId)
            self.updateQuickAddDueAt(nil)
            self.updateQuickAddAssignee(nil)
            self.reloadState()
            self.node?.reveal(taskId: id.rawValue)
            UIAccessibility.post(notification: .announcement, argument: self.l10n.tasks_cloud_a11y_added(title))
            return true
        } catch {
            self.presentError(error)
            return false
        }
    }

    private func updateQuickAddDueAt(_ dueAt: Int32?) {
        guard self.quickAddDueAt != dueAt else {
            return
        }
        self.quickAddDueAt = dueAt
        self.node?.updateQuickAddDueAt(dueAt)
        self.host.requestLayout()
    }

    private func updateQuickAddAssignee(_ assignee: TodoAssignee?) {
        guard self.quickAddAssignee != assignee else {
            return
        }
        self.quickAddAssignee = assignee
        self.node?.updateQuickAddAssigneeName(assignee?.displayName)
        self.host.requestLayout()
    }

    /// Pickers take the keyboard away; it returns to the title field afterwards if it was there and
    /// the board is still on screen (the device board's `takeKeyboardForPicker`).
    private func takeKeyboardForPicker(from view: UIView) -> () -> Void {
        let wasEditing = self.node?.isEditingQuickAddTitle ?? false
        view.endEditing(true)
        return { [weak self] in
            guard wasEditing, let self, self.host.sourceView()?.window != nil else {
                return
            }
            self.node?.focusQuickAddTitle()
        }
    }

    /// The composer's Masʼul pill (wf15 §4.2): the explainer once per account, then Telegram's
    /// contact picker, then the pick-time check; the contact becomes the recipient the create sends
    /// the task to ("Qoʻshish" chains the `invitation.request`). The keyboard comes back however
    /// the picker closes, including a swipe or an outside tap.
    private func pickQuickAddAssignee() {
        guard let navigationController = self.host.navigationController(), let view = self.host.sourceView() else {
            return
        }
        let restoreKeyboard = self.takeKeyboardForPicker(from: view)
        self.assignment.pick(navigationController: navigationController, present: self.host.present, presentToast: self.host.presentUndo, closed: restoreKeyboard, completion: { [weak self] assignee in
            self?.updateQuickAddAssignee(assignee)
        })
    }

    private func pickQuickAddDeadline() {
        guard let view = self.host.sourceView() else {
            return
        }
        let restoreKeyboard = self.takeKeyboardForPicker(from: view)
        presentTasksDeadlinePicker(from: view, currentDueAt: self.quickAddDueAt, presentationData: self.presentationData, commit: { [weak self] result in
            switch result {
            case let .set(dueAt):
                self?.updateQuickAddDueAt(dueAt)
            case .clear:
                self?.updateQuickAddDueAt(nil)
            }
        }, dismissed: restoreKeyboard)
    }

    private func createList() {
        if self.refuseReadOnlyChange() {
            return
        }
        presentTasksCloudCreateListAlert(context: self.context, repository: self.repository, present: self.host.present, created: { [weak self] listId in
            self?.reloadState()
            self?.updateState { $0.select(.folder(id: listId.rawValue)) }
        })
    }

    // MARK: - Rows

    private func task(id: String) -> SGTasksCloudTask? {
        return self.state.task(id: id)
    }

    /// The task as the repository holds it NOW, when the viewer still has exactly the rights the row
    /// was drawn under (role and, for a recipient, accepted invitation epoch) and they allow the
    /// action. Otherwise the refusal is explained and nil returned; nothing is sent or retried. nil
    /// `displayed` rights come only from device rows and are never accepted here. The repository
    /// still fences the actual change.
    private func permittedTask(id: String, displayed: TasksCloudTaskPermissions?, allows: (TasksCloudTaskPermissions) -> Bool) -> SGTasksCloudTask? {
        guard let task = self.repository.state.tasks.first(where: { $0.id.rawValue == id }) else {
            self.host.present(tasksErrorAlert(context: self.context, text: self.l10n.tasks_cloud_error_gone))
            return nil
        }
        let current = TasksCloudTaskPermissions(task: task)
        guard allows(current) else {
            self.host.present(tasksErrorAlert(context: self.context, text: self.l10n.tasks_cloud_error_notAssignee))
            return nil
        }
        guard let displayed, displayed == current else {
            self.host.present(tasksErrorAlert(context: self.context, text: self.l10n.tasks_cloud_error_changedElsewhere))
            return nil
        }
        return task
    }

    /// An explicit target state (row button and context menu pass what the user saw), so a change
    /// that arrived while the menu was open never flips the task the other way.
    private func setTaskCompleted(id: String, isCompleted: Bool, displayed: TasksCloudTaskPermissions?) {
        guard !self.refuseReadOnlyChange(), let task = self.permittedTask(id: id, displayed: displayed, allows: { $0.canSetCompletion }), task.isCompleted != isCompleted else {
            return
        }
        do {
            try self.repository.setTaskCompleted(id: task.id, isCompleted: isCompleted)
        } catch {
            self.presentError(error)
            return
        }
        UIAccessibility.post(notification: .announcement, argument: isCompleted ? self.l10n.tasks_cloud_a11y_markedDone(task.title) : self.l10n.tasks_cloud_a11y_markedOpen(task.title))
    }

    private func openTask(id: String) {
        guard let task = self.task(id: id) else {
            // wf15 §5.2: a provisional row carries its task's id and opens the read-only preview.
            if let provisional = self.state.provisionalTask(taskId: id) {
                self.openProvisional(provisional)
            }
            return
        }
        guard let navigationController = self.host.navigationController() else {
            return
        }
        // A fast double tap must not push a second editor over the first.
        if let openEditor = self.openEditor, navigationController.viewControllers.contains(where: { $0 === openEditor }) {
            return
        }
        self.host.sourceView()?.endEditing(true)
        // A read-only board (R4 consent hold) opens the task read-only; the editor re-reads the hold.
        let controller = tasksCloudTaskEditorController(context: self.context, repository: self.repository, task: task, mode: .edit(TasksCloudEditorHostActions(
            requestDelete: { [weak self] taskId in
                self?.requestDeleteFromEditor(taskId)
            },
            openUnsentChanges: { [weak self] in
                self?.openUnsentChanges()
            },
            assignment: self.assignment
        )))
        self.openEditor = controller
        navigationController.pushViewController(controller)
    }

    /// wf15 §5.2: a provisional "Menga topshirilgan" row (an automatic accept on its way) opens the
    /// invitation preview, read-only; no action lives there.
    private func openProvisional(invitationId: String) {
        guard let provisional = self.state.provisionalTask(invitationId: invitationId) else {
            return
        }
        self.openProvisional(provisional)
    }

    private func openProvisional(_ provisional: TasksCloudProvisionalTask) {
        guard let navigationController = self.host.navigationController() else {
            return
        }
        if let openEditor = self.openEditor, navigationController.viewControllers.contains(where: { $0 === openEditor }) {
            return
        }
        self.host.sourceView()?.endEditing(true)
        let controller = tasksCloudProvisionalTaskController(context: self.context, repository: self.repository, invitationId: provisional.invitationId, taskId: provisional.taskId, names: self.assignment.names)
        self.openEditor = controller
        navigationController.pushViewController(controller)
    }

    /// The editor has closed itself. The hold (and its Undo toast) starts only once the board is on
    /// screen again, so the toast's lifetime covers the whole hold instead of appearing late.
    private func requestDeleteFromEditor(_ taskId: SGTasksWire.UUID) {
        if self.isActive {
            self.deleteTask(taskId)
        } else {
            self.pendingEditorDelete = taskId
        }
    }

    /// Owner: delete with Undo. Accepted recipient: confirmed Leave, bound to the invitation epoch the
    /// row showed and re-checked when confirmed (a revoke or re-invite meanwhile is refused).
    private func removeTask(id: String, displayed: TasksCloudTaskPermissions?) {
        guard !self.refuseReadOnlyChange(), let task = self.permittedTask(id: id, displayed: displayed, allows: { $0.canDelete || $0.canLeave }) else {
            return
        }
        let current = TasksCloudTaskPermissions(task: task)
        if current.canDelete {
            self.deleteTask(task.id)
            return
        }
        guard let invitationId = current.recipientInvitationId else {
            return
        }
        let taskId = task.id
        presentTasksCloudLeaveConfirmation(context: self.context, present: self.host.present, confirmed: { [weak self] in
            guard let self, self.permittedTask(id: id, displayed: current, allows: { $0.canLeave }) != nil else {
                return
            }
            do {
                try self.repository.leaveTask(id: taskId, expectedInvitationId: invitationId)
            } catch {
                self.presentError(error)
            }
        })
    }

    /// Owner delete: the repository HOLDS it (nothing is sent) until the toast commits — dismissed
    /// without Undo, timed out, the board left or the app backgrounded. Undo restores atomically.
    private func deleteTask(_ taskId: SGTasksWire.UUID) {
        if self.refuseReadOnlyChange() {
            return
        }
        let handle: SGTasksCloudUndoHandle
        do {
            handle = try self.repository.deleteTask(id: taskId)
        } catch {
            self.presentError(error)
            return
        }
        self.commitUndo()
        let undo = UndoOverlayController(
            presentationData: self.presentationData,
            content: .removedChat(context: self.context, title: NSAttributedString(string: self.l10n.tasks_taskDeleted), text: nil),
            elevatedLayout: false,
            action: { [weak self] action in
                switch action {
                case .undo:
                    if !handle.undo() {
                        // The hold already ended (background, board left): the delete was queued.
                        if let self {
                            self.host.present(tasksErrorAlert(context: self.context, text: self.l10n.tasks_error_restore))
                        }
                    }
                case .commit, .info:
                    handle.commit()
                }
                return true
            }
        )
        self.undoController = undo
        self.host.presentUndo(undo)
    }

    private func commitUndo() {
        self.undoController?.dismissWithCommitAction()
        self.undoController = nil
    }

    // MARK: - Secondary screens

    /// Roʻyxatlar of the synced board. `olderEntry` / `openOlder`: the "Eski vazifalar" /
    /// "Sinxronlangan nusxa" entry the one-board resolver offers (wf15 §3.3), kept current while the
    /// screen is open.
    func openLists(olderEntry: Signal<TasksOlderEntry?, NoError>, openOlder: @escaping (TasksOlderEntry) -> Void, openUnsentAssignees: @escaping () -> Void) {
        let controller = tasksCloudListsController(context: self.context, repository: self.repository, olderEntry: olderEntry, openOlder: openOlder, unsentAssignees: self.assignment.unsentLegacyAssignees.get(), openUnsentAssignees: openUnsentAssignees, openList: { [weak self] listId in
            self?.updateState { $0.select(.folder(id: listId.rawValue)) }
        }, openUnsentChanges: { [weak self] in
            self?.openUnsentChanges()
        })
        self.push(controller)
    }

    /// wf15 §7: the legacy assignee offer as it stands now (the tab controller decides when the
    /// one-time sheet shows and presents it); `remaining` is rewritten on the way.
    func legacyAssigneeOffer() -> SGTasksLegacyAssigneeOffer {
        return self.assignment.refreshLegacyOffer()
    }

    private func openUnsentChanges() {
        self.push(tasksCloudIssuesController(context: self.context, repository: self.repository))
    }

    private func openInvitations() {
        // wf15 §5.2: Takliflar with the hint line; senders named only when they are the viewer's contacts.
        self.push(tasksCloudInvitationsController(context: self.context, repository: self.repository, names: self.assignment.names))
    }

    /// The explicit, CREATE-gated copy of the older device rows (the status line's "Sinxronlash" in
    /// S6b / S8, wf15 §3.2); nothing else reaches it.
    func openImport() {
        guard let navigationController = self.host.navigationController() else {
            return
        }
        if self.refuseReadOnlyChange() {
            return
        }
        pushTasksCloudImportController(context: self.context, repository: self.repository, navigationController: navigationController, present: self.host.present)
    }

    /// The banners' link action (`tasksPushLinkAccountController`).
    private func openLinkAccount() {
        guard let navigationController = self.host.navigationController() else {
            return
        }
        tasksPushLinkAccountController(context: self.context, accountPeerId: self.accountPeerId, presentationData: self.presentationData, navigationController: navigationController)
    }
}
