import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGEntitlementUI
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AlertUI
import UndoUI

// Zenlygram — Tasks: a task-first board. Open tasks are on the main screen, filtered by "All" or one
// list; a composer pinned above the keyboard / tab bar adds tasks without choosing a list first
// ("All" files them in a lazily created inbox list); completed tasks collapse under a disclosure.
//
// One board (wf15 §3). There is no switch and no second scope: the pure resolver
// (`TasksBoardSourceResolver`, TasksBoardSource.swift, host-tested row by row) reads plain facts —
// the account's traffic permission, its cut-over, its migration record, the device owner marker,
// the device rows, the synced store's snapshot / consent hold / cached rows, the explicit copy's
// count — and answers which board is shown (the device database while sync is off or not usable
// yet, the account's synced board otherwise), the at most one status line under it ("Sinxronlash
// oʻchiq", "Akkaunt bogʻlangach sinxronlash boshlanadi" + Bogʻlash, the older rows' progress, the
// offer to sync older rows, the one-time other-account notice), the Roʻyxatlar entry that keeps
// every row reachable read-only ("Eski vazifalar" / "Sinxronlangan nusxa", TasksLegacyBoardController)
// and whether a Masʼul can be assigned here. This controller gathers the facts, renders the answer
// (`TasksBoardHostNode`) and re-resolves on every input change; nothing here decides by itself. The
// device board shown here is always writable (the storage fence still answers a write the cut-over
// forbids with a note, never an error alert); the only read-only device view is Eski vazifalar.
//
// Pro policy: only CREATING (a task or a list) passes `sgEntitlementGate(.createTask)`. Reading,
// editing, completing, deleting and undoing a delete are never gated.

/// The Tasks screen. One factory for both entries: the bottom tab bar (tab root, no Back) and
/// Swiftgram Settings ▸ Tasks (pushed; the navigation bar draws the system Back button).
public func tasksTabController(context: AccountContext) -> ViewController {
    return TasksBoardController(context: context)
}

/// wf15 §4.4: what the device board's Masʼul pill and editor row do instead of the contact picker
/// while sync is off or not usable yet (D1: assigning needs consent and a link). The resolver's
/// answer is read at tap time; `turnOnSync` is the Data & consent hook of §6, `link` the account
/// linking screen.
struct TasksDeviceAssignGate {
    let availability: () -> TasksAssignAvailability
    let turnOnSync: () -> Void
    let link: () -> Void
}

/// True when today's local contact picker may open (S1, `legacyLocal`, only). Otherwise the
/// needs-sync sheet (`needsConsent` → "Sinxronlashni yoqish"; `needsLink` → the link action) or the
/// wait toast (`wait`), nothing is stored, and false. No new local assignee outside S1 (D1).
func tasksDeviceAssignAllowsPicker(_ gate: TasksDeviceAssignGate?, context: AccountContext, present: (ViewController) -> Void, presentToast: (UndoOverlayController) -> Void) -> Bool {
    guard let gate else {
        return true
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let l10n = SGTasksL10n(presentationData.strings)
    let sheet: (String, @escaping () -> Void) -> ViewController = { actionTitle, action in
        return textAlertController(context: context, title: l10n.tasks_assign_needsSync_title, text: l10n.tasks_assign_needsSync_text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: actionTitle, action: action)
        ])
    }
    switch gate.availability() {
    case .legacyLocal:
        return true
    case .needsConsent:
        present(sheet(l10n.tasks_assign_needsSync_action, gate.turnOnSync))
        return false
    case .needsLink:
        present(sheet(l10n.tasks_cloud_link_action, gate.link))
        return false
    case .wait, .available:
        // `available` never meets a device row (the synced board is shown then); a device editor
        // still open across the flip waits like S5.
        presentToast(tasksNoticeToast(context: context, text: l10n.tasks_assign_waitForSync))
        return false
    }
}

final class TasksBoardController: ViewController {
    private let context: AccountContext
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    private var state: TasksBoardState
    /// The composer's assignee/deadline, kept until a task is actually created with it.
    private var quickAddMetadata = TasksTaskMetadataDraft.empty
    /// Set while a storage-unavailable error has been shown and storage has not recovered.
    private var isReportingStorageUnavailable = false
    private let tasksIcon = UIImage(bundleImageName: "Chat/Context Menu/FormatChecklist")
    private var assigneePickerClosedDisposable: Disposable?
    private var timeContextObserver: TasksTimeContextObserver?
    private let accountPeerId: Int64
    private var observers: [NSObjectProtocol] = []
    /// A re-resolve is scheduled (coalesces the repository's change notices during a sync cycle).
    private var isPresentationRefreshScheduled = false
    /// The last transient note (R4 write fence): one at a time.
    private weak var noticeController: UndoOverlayController?
    /// Created the first time the synced board is shown; kept while the board lives so its drafts
    /// survive a flip back to the device board (S7 → S5 never happens, but S2 ↔ S4 can).
    private var cloudPresenter: TasksCloudBoardPresenter?
    /// Between viewWillAppear and viewDidDisappear.
    private var isBoardVisible = false
    /// Between viewDidAppear and viewDidDisappear: the one-time legacy assignee sheet (wf15 §7.1) is
    /// presented only over a board that is fully on screen.
    private var isBoardOnScreen = false
    /// The D4 sheet while it is up (never two).
    private weak var legacyAssigneeSheet: ViewController?
    /// The resolver's answer for the current facts (§3.2).
    private var presentation: TasksBoardPresentation
    /// The resolver's Roʻyxatlar entry, kept current for the Lists screens while they are open.
    private let olderEntryPromise = ValuePromise<TasksOlderEntry?>(nil, ignoreRepeated: true)

    private var hostNode: TasksBoardHostNode {
        return self.displayNode as! TasksBoardHostNode
    }

    /// The device board node, once the display node is loaded.
    private var boardNode: TasksBoardNode? {
        return self.isNodeLoaded ? self.hostNode.localNode : nil
    }

    /// S9: the one-time other-account notice was dismissed for this account.
    private var otherAccountNoticeKey: String {
        return "sgtasks.notice.otherAccount.\(self.accountPeerId)"
    }

    /// D1 "bir marta" (§6.2): the one consent prompt was presented from Vazifalar for this account;
    /// never asked from here again (Data & consent → Give consent still works). Removed with the
    /// other per-account `sgtasks.*` keys at the last logout (§7.4).
    private var consentPromptedKey: String {
        return "sgtasks.consentPrompted.\(self.accountPeerId)"
    }

    /// The accounts whose Vazifalar already asked the consent hook in this process (once per account
    /// per process, §6.2), whatever the hook answered.
    private static var consentPromptAsked = Set<Int64>()

    /// The sync-off line is plain text once the installed hook answered that there is no Data &
    /// consent screen (never expected in an active build, §6.1).
    private var consentEntryUnavailable = false

    init(context: AccountContext) {
        let accountPeerId = context.account.peerId.toInt64()
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.accountPeerId = accountPeerId
        // The retired Cloud / device switch's remembered scopes: removed once (§3.3), never read.
        TasksBoardSource.removeLegacyScopeKeys(defaults: .standard)
        self.state = TasksBoardState(folders: TodoStorage.loadFolders(), tasks: TodoStorage.loadTasks())
        self.presentation = TasksBoardPresentation(source: .device(writable: true), line: .none, olderEntry: nil, assign: .legacyLocal)

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))

        self.presentation = TasksBoardSourceResolver.resolve(self.resolveInputs())
        self.olderEntryPromise.set(self.presentation.olderEntry)
        self.applyStrings()
        self.updateTabBarItem()

        self.scrollToTop = { [weak self] in
            guard let self, self.isNodeLoaded else {
                return
            }
            self.hostNode.scrollToTop()
        }

        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            guard let self else {
                return
            }
            let previous = self.presentationData
            self.presentationData = presentationData
            if previous.theme !== presentationData.theme || previous.strings !== presentationData.strings || previous.listsFontSize != presentationData.listsFontSize || previous.dateTimeFormat != presentationData.dateTimeFormat {
                self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
                self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: presentationData), transition: .immediate)
                self.applyStrings()
                self.updateTabBarItem()
                self.cloudPresenter?.updatePresentationData(presentationData)
                if self.isNodeLoaded {
                    self.hostNode.updatePresentationData(presentationData)
                    // The line's texts are the strings': rendered again in the new language.
                    self.hostNode.update(line: self.lineContent(self.presentation.line))
                }
            }
        })

        // "Today"/"Tomorrow" deadline text goes stale across midnight or a time-zone change.
        self.timeContextObserver = TasksTimeContextObserver(changed: { [weak self] in
            self?.refreshTimeDependentText()
        })

        let center = NotificationCenter.default
        // The coordinator recomputed the cut-over (and with it the permission may have moved).
        self.observers.append(center.addObserver(forName: SGTasksSyncCoordinator.cutOverDidChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self, notification.userInfo?["accountPeerId"] as? Int64 == self.accountPeerId else {
                return
            }
            self.refreshPresentation()
        }))
        // The account's synced store changed: a snapshot completed, the consent hold moved with the
        // gate (`permissionChanged` rebuilds the state), a copy's confirmations arrived, cached rows
        // came or went. Coalesced: a sync cycle posts several.
        self.observers.append(center.addObserver(forName: SGTasksCloudRepository.didChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self, notification.userInfo?["accountPeerId"] as? Int64 == self.accountPeerId else {
                return
            }
            self.schedulePresentationRefresh()
        }))
        // A withdrawal or erasure released the account's claim on the device rows.
        self.observers.append(center.addObserver(forName: SGTasksCloudRepository.migrationDidChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self, notification.userInfo?["accountPeerId"] as? Int64 == self.accountPeerId else {
                return
            }
            self.schedulePresentationRefresh()
        }))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
        self.assigneePickerClosedDisposable?.dispose()
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func applyStrings() {
        let l10n = SGTasksL10n(self.presentationData.strings)
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.title = l10n.tab_tasks
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: l10n.tasks_lists_title, style: .plain, target: self, action: #selector(self.listsPressed))
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
    }

    // Match the neighboring tab glyphs' 30 pt canvas and text-color tint. The glass tab bar
    // does not tint static images, so both states are regenerated on theme changes.
    // Keep the image available from init: TabBarController's ready waits for every tab icon.
    private func updateTabBarItem() {
        let tabBarTheme = self.presentationData.theme.rootController.tabBar
        self.tabBarItem.title = SGTasksL10n(self.presentationData.strings).tab_tasks
        let iconSize = CGSize(width: 30.0, height: 30.0)
        self.tabBarItem.image = generateTintedImage(image: self.tasksIcon, color: tabBarTheme.textColor, customSize: iconSize)
        self.tabBarItem.selectedImage = generateTintedImage(image: self.tasksIcon, color: tabBarTheme.selectedTextColor, customSize: iconSize)
    }

    override func loadDisplayNode() {
        // Device rows carry no cloud access (always nil here): every action on them is the user's.
        let rowActions = TasksRowActions(
            setCompleted: { [weak self] id, isCompleted, _ in self?.setTaskCompleted(id: id, isCompleted: isCompleted) },
            edit: { [weak self] id in self?.editTask(id: id) },
            delete: { [weak self] id, _ in self?.deleteTask(id: id) }
        )
        let interaction = TasksBoardInteraction(
            selectFilter: { [weak self] filter in
                self?.updateState { $0.select(filter) }
            },
            createList: { [weak self] in
                self?.createList()
            },
            toggleCompletedSection: { [weak self] in
                self?.updateState { $0.isCompletedExpanded.toggle() }
            },
            rowActions: rowActions,
            submitQuickAdd: { [weak self] text in
                return self?.submitQuickAdd(text) ?? false
            },
            pickQuickAddAssignee: { [weak self] in
                self?.pickQuickAddAssignee()
            },
            clearQuickAddAssignee: { [weak self] in
                self?.updateQuickAddMetadata { $0.assignee = nil }
            },
            pickQuickAddDeadline: { [weak self] in
                self?.pickQuickAddDeadline()
            },
            clearQuickAddDeadline: { [weak self] in
                self?.updateQuickAddMetadata { $0.dueAt = nil }
            },
            calendarShown: { [weak self] in
                self?.emitCalendarShown()
            }
        )
        let localNode = TasksBoardNode(state: self.state, quickAddMetadata: self.quickAddMetadata, presentationData: self.presentationData, interaction: interaction)
        var cloudNode: TasksCloudBoardNode?
        if case .synced = self.presentation.source {
            cloudNode = self.ensureCloudPresenter().makeNode()
        }
        localNode.marksLegacyAssignees = self.presentation.assign != .legacyLocal
        self.displayNode = TasksBoardHostNode(localNode: localNode, cloudNode: cloudNode, source: self.presentation.source, presentationData: self.presentationData)
        self.hostNode.update(line: self.lineContent(self.presentation.line))
        self.displayNodeDidLoad()
        // The Undo toast is laid out by hand (below) so it sits above the composer and the line.
        self.automaticallyControlPresentationContextLayout = false
    }

    // MARK: - The one board (wf15 §3)

    private func ensureCloudPresenter() -> TasksCloudBoardPresenter {
        if let cloudPresenter = self.cloudPresenter {
            return cloudPresenter
        }
        let presenter = TasksCloudBoardPresenter(context: self.context, presentationData: self.presentationData, host: TasksCloudBoardHost(
            present: { [weak self] controller in
                self?.presentInWindow(controller)
            },
            presentUndo: { [weak self] controller in
                self?.present(controller, in: .current)
            },
            navigationController: { [weak self] in
                return self?.navigationController as? NavigationController
            },
            sourceView: { [weak self] in
                guard let self, self.isViewLoaded else {
                    return nil
                }
                return self.view
            },
            requestLayout: { [weak self] in
                guard let self, self.isNodeLoaded else {
                    return
                }
                self.requestLayout(transition: .immediate)
            },
            boardFactsChanged: { [weak self] in
                self?.refreshPresentation()
            }
        ))
        // wf15 §3.2 S4: the synced board of an account that waits for its link assigns nothing.
        presenter.assignment.assignGate = self.assignGate
        self.cloudPresenter = presenter
        return presenter
    }

    /// Whether the sync-off line can open the Data & consent screen (§6.1): through the installed
    /// consent entry hook (`SGTasksConsentEntry.dataConsentController`), or — with no hook installed —
    /// the Settings route `tg://sg/settings?row=dataConsent`, which this build always has. Plain
    /// text only once the hook answered nil.
    private var consentEntryAvailable: Bool {
        return !self.consentEntryUnavailable
    }

    /// The plain facts of §3.1, gathered from the coordinator, the device database, the account's
    /// synced store (only when its permission admits one) and this screen.
    private func resolveInputs() -> TasksBoardSourceInputs {
        let coordinator = SGTasksSyncCoordinator.shared
        let permission = coordinator.permission(accountPeerId: self.accountPeerId)
        let cutOver = coordinator.cutOver(accountPeerId: self.accountPeerId)
        let database = SGTasksCloudRepository.environment.legacy()
        let record = try? database.cloudMigrationRecord(accountPeerId: self.accountPeerId)
        let owner = try? database.cloudDeviceOwner()
        let deviceOwnedByThisOrFree = owner == nil || owner?.accountPeerId == self.accountPeerId

        var snapshotComplete = false
        var cloudReadOnly: TasksCloudReadOnlyReason?
        var hasOwnCachedSyncedRows = false
        switch permission {
        case .legacy:
            break
        case .forbidden:
            // The Sinxronlangan nusxa (F12): only an existing store is looked at; none is created.
            if SGTasksCloudRepository.environment.files.storeExists(accountPeerId: self.accountPeerId) {
                hasOwnCachedSyncedRows = SGTasksCloudRepository.repository(accountPeerId: self.accountPeerId).state.tasks.contains { $0.viewerRole == .owner }
            }
        case .waiting, .allowed:
            let repository = SGTasksCloudRepository.repository(accountPeerId: self.accountPeerId)
            let cloud = repository.state
            snapshotComplete = cloud.hasCompleteSnapshot
            cloudReadOnly = repository.readOnlyReason(cloud)
        }

        return TasksBoardSourceInputs(
            permission: permission,
            cutOver: cutOver,
            recordState: record?.state,
            recordReason: record?.reason,
            deviceOwnedByThisOrFree: deviceOwnedByThisOrFree,
            deviceLiveRows: self.state.tasks.count,
            importableDeviceRows: self.cloudPresenter?.importableDeviceRows,
            importNeedsCorrection: self.cloudPresenter?.importNeedsCorrection ?? 0,
            archive: TasksBoardController.archive(accountPeerId: self.accountPeerId, cutOver: cutOver),
            snapshotComplete: snapshotComplete,
            cloudReadOnly: cloudReadOnly,
            hasOwnCachedSyncedRows: hasOwnCachedSyncedRows,
            consentEntryAvailable: self.consentEntryAvailable,
            otherAccountNoticeDismissed: UserDefaults.standard.bool(forKey: self.otherAccountNoticeKey)
        )
    }

    /// The archive facts of the account's cut-over for the resolver (S4/S7/S8), with the copy's
    /// progress: under `archive(migrating)` read live (each sync cycle confirms some of the queued
    /// copies) together with whether the copy is in this account's cloud store on this device, by
    /// the cut-over's own I1 (`SGTasksMigration.archiveProgress`); else the coordinator's cached
    /// progress. A completed copy shows no progress, and neither does a copy that is not in the
    /// store (a logout purged it): the line then reads as loading until the snapshot is back.
    private static func archive(accountPeerId: Int64, cutOver: TasksCutOver) -> TasksBoardArchive? {
        if case .none = cutOver {
            return nil
        }
        var progress = SGTasksSyncCoordinator.shared.migrationProgress(accountPeerId: accountPeerId)
        var copyOnDevice = true
        if case .archive(.migrating) = cutOver, let record = try? SGTasksCloudRepository.environment.legacy().cloudMigrationRecord(accountPeerId: accountPeerId) {
            let archived = SGTasksMigration.archiveProgress(record, repository: SGTasksCloudRepository.repository(accountPeerId: accountPeerId))
            progress = archived.progress
            copyOnDevice = archived.copyOnDevice
        }
        return TasksBoardArchive(cutOver: cutOver, done: progress?.done ?? 0, total: progress?.total ?? 0, keptLocal: progress?.keptLocal ?? 0, recordState: progress?.state, copyOnDevice: copyOnDevice)
    }

    private func schedulePresentationRefresh() {
        guard !self.isPresentationRefreshScheduled else {
            return
        }
        self.isPresentationRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else {
                return
            }
            self.isPresentationRefreshScheduled = false
            self.refreshPresentation()
        }
    }

    /// Re-resolves the board from the current facts and renders the answer: the shown board (a flip
    /// carries the composer's draft, §3.3), the line and the Roʻyxatlar entry.
    private func refreshPresentation() {
        let presentation = TasksBoardSourceResolver.resolve(self.resolveInputs())
        let previous = self.presentation
        self.presentation = presentation
        self.olderEntryPromise.set(presentation.olderEntry)
        if previous.source != presentation.source {
            self.applySource(presentation.source, previous: previous.source)
        }
        if self.isNodeLoaded {
            // wf15 §4.4: outside S1 a local assignee is an old entry ("(eski yozuv)").
            self.boardNode?.marksLegacyAssignees = presentation.assign != .legacyLocal
            self.hostNode.update(line: self.lineContent(presentation.line))
            self.requestLayout(transition: .immediate)
        }
        // wf15 §7.1: the facts moved (the snapshot completed, the cut-over changed, a copy was
        // confirmed): the one-time sheet may be due now.
        self.offerLegacyAssigneesIfNeeded()
    }

    // MARK: - The legacy assignee sheet (wf15 §7, D4)

    /// §7.1: the offer and the record it is bound to when the sheet is due now — the synced,
    /// writable board with Masʼul `available` (the account is `allowed` and linked), a `completed` or
    /// skipped(existing_mappings | scope_changed) record without a marker bound to its `claimedAt`,
    /// and at least one sendable device-row candidate. nil otherwise (nothing is ever sent from here).
    private func dueLegacyAssigneeOffer() -> (offer: SGTasksLegacyAssigneeOffer, claimedAt: Int64)? {
        guard case .synced(readOnly: false) = self.presentation.source, self.presentation.assign == .available, let presenter = self.cloudPresenter else {
            return nil
        }
        guard let record = try? SGTasksCloudRepository.environment.legacy().cloudMigrationRecord(accountPeerId: self.accountPeerId) else {
            return nil
        }
        let marker = SGTasksLocalMarkers.legacyOfferMarker(accountPeerId: self.accountPeerId, claimedAt: record.claimedAt)
        let offer = presenter.legacyAssigneeOffer()
        guard SGTasksLegacyAssigneeOffer.isDue(recordState: record.state, recordReason: record.reason, marker: marker, hasSendableCandidate: offer.offersSheet) else {
            return nil
        }
        return (offer, record.claimedAt)
    }

    /// Presents the sheet once per record when it is due, the board is on screen and no consent
    /// screen is up (`SGTasksConsentEntry.installed?.isConsentScreenUp`).
    private func offerLegacyAssigneesIfNeeded() {
        guard self.isBoardOnScreen, self.legacyAssigneeSheet == nil else {
            return
        }
        guard let due = self.dueLegacyAssigneeOffer() else {
            return
        }
        if SGTasksConsentEntry.installed?.isConsentScreenUp(self.context) == true {
            return
        }
        self.presentLegacyAssigneeSheet(offer: due.offer, claimedAt: due.claimedAt)
    }

    /// The Lists entry "Yuborilmagan masʼullar (n)" (§7.3): reopens the sheet while device-row
    /// candidates remain, whatever the marker says.
    private func openUnsentAssignees() {
        guard self.legacyAssigneeSheet == nil, let presenter = self.cloudPresenter else {
            return
        }
        // The sheet's Yuborish queues invitations: not before the link (S4), as every other pick.
        guard presenter.assignment.allowsAssigning(present: { [weak self] c in self?.presentOnScreen(c) }, presentToast: { [weak self] c in self?.presentOnScreen(c) }) else {
            return
        }
        let offer = presenter.legacyAssigneeOffer()
        guard offer.offersSheet else {
            return
        }
        let record = try? SGTasksCloudRepository.environment.legacy().cloudMigrationRecord(accountPeerId: self.accountPeerId)
        self.presentLegacyAssigneeSheet(offer: offer, claimedAt: record?.claimedAt ?? 0)
    }

    private func presentLegacyAssigneeSheet(offer: SGTasksLegacyAssigneeOffer, claimedAt: Int64) {
        guard let presenter = self.cloudPresenter, let navigationController = self.navigationController as? NavigationController else {
            return
        }
        self.view.endEditing(true)
        let controller = tasksLegacyAssigneeSheetController(context: self.context, offer: offer, host: TasksLegacyAssigneeSheetHost(
            repository: presenter.repository,
            assignment: presenter.assignment,
            claimedAt: claimedAt,
            presentToast: { [weak self] text in
                self?.presentLegacySheetToast(text)
            },
            finished: { [weak self] in
                self?.refreshPresentation()
            }
        ))
        self.legacyAssigneeSheet = controller
        navigationController.pushViewController(controller)
    }

    /// The sheet's closing toast (§7.3). The sheet is opened over the board or — from Lists ›
    /// "Yuborilmagan masʼullar" — over the Lists screen, which covers this controller: its view is
    /// then off the window and a `.window` presentation from it would go nowhere. The toast is
    /// presented by the topmost controller of the stack that is on screen (the sheet itself, which
    /// is closing, is skipped).
    private func presentLegacySheetToast(_ text: String) {
        self.presentOnScreen(tasksNoticeToast(context: self.context, text: text))
    }

    /// A window-level presentation (a toast, an alert) from whichever controller of the stack is on
    /// screen: this one, or the screen that covers it (Lists). The legacy sheet is skipped — it is
    /// closing when its toast is shown.
    private func presentOnScreen(_ controller: ViewController) {
        let stack = (self.navigationController as? NavigationController)?.viewControllers ?? []
        let onScreen = stack.reversed().compactMap { $0 as? ViewController }.first { $0 !== self.legacyAssigneeSheet && $0.window != nil }
        (onScreen ?? self).present(controller, in: .window(.root))
    }

    /// wf15 §4.4: the device board's Masʼul gate; nil only for S1 (today's local assignee).
    private var deviceAssignGate: TasksDeviceAssignGate? {
        guard self.presentation.assign != .legacyLocal else {
            return nil
        }
        return self.assignGate
    }

    /// The resolver's `assign` answer, read at tap time, with the two ways forward (§4.4). The
    /// device board uses it outside S1; the synced board whenever the answer is not `available` (S4).
    private var assignGate: TasksDeviceAssignGate {
        return TasksDeviceAssignGate(
            availability: { [weak self] in
                return self?.presentation.assign ?? .wait
            },
            turnOnSync: { [weak self] in
                self?.openDataConsent()
            },
            link: { [weak self] in
                self?.openLinkAccount()
            }
        )
    }

    /// Shows the board the resolver named. Any open Undo toast is committed first (it belongs to
    /// the board being left); both boards keep their scroll positions and nothing moves between the
    /// stores — except the device composer's draft, carried to the synced composer when the board
    /// flips there (S5 → S7).
    private func applySource(_ source: TasksBoardSource, previous: TasksBoardSource) {
        if self.isViewLoaded {
            self.view.endEditing(true)
        }
        self.forEachController { controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
            return true
        }
        switch source {
        case .synced:
            let presenter = self.ensureCloudPresenter()
            if self.isNodeLoaded {
                self.hostNode.setCloudNode(presenter.makeNode())
            }
            if case .device = previous {
                self.carryQuickAddDraft(to: presenter)
            }
            if self.isBoardVisible {
                presenter.appear()
                self.emitSourceAnalytics()
            }
        case .device:
            self.cloudPresenter?.disappear()
            self.reload()
        }
        if self.isNodeLoaded {
            self.hostNode.update(source: source)
            self.requestLayout(transition: .immediate)
        }
    }

    private func carryQuickAddDraft(to presenter: TasksCloudBoardPresenter) {
        let title = (self.boardNode?.quickAddDraftTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = self.quickAddMetadata
        guard !title.isEmpty || metadata != .empty else {
            return
        }
        presenter.adoptQuickAddDraft(title: title.isEmpty ? nil : title, dueAt: metadata.dueAt, assignee: metadata.assignee)
        self.boardNode?.clearQuickAddDraftTitle()
        self.updateQuickAddMetadata { $0 = .empty }
    }

    /// The status line (§3.2) as the host renders it; nil for no line. S11's `fenced` draws no second
    /// row: the synced board's own banner already carries `tasks_cloud_consentFenced`, and the
    /// resolver's override has already suppressed every other line and the Masʼul.
    private func lineContent(_ line: TasksSyncLine) -> TasksSyncLineContent? {
        let l10n = self.l10n
        switch line {
        case .none, .fenced:
            return nil
        case let .syncOff(tappable):
            return TasksSyncLineContent(
                identifier: TasksSyncLineAccessibilityId.syncOff,
                text: l10n.tasks_sync_off,
                hint: tappable ? l10n.tasks_sync_off_a11yHint : nil,
                tap: tappable ? { [weak self] in self?.openDataConsent() } : nil
            )
        case .waitingLink:
            return TasksSyncLineContent(
                identifier: TasksSyncLineAccessibilityId.line,
                text: l10n.tasks_sync_waitingLink,
                actions: [TasksSyncLineAction(title: l10n.tasks_cloud_link_action, identifier: TasksSyncLineAccessibilityId.action("link"), isPrimary: true, action: { [weak self] in
                    self?.openLinkAccount()
                })]
            )
        case .turningOn:
            return TasksSyncLineContent(identifier: TasksSyncLineAccessibilityId.line, text: l10n.tasks_sync_turningOn)
        case let .progress(done, total, keptLocal):
            return TasksSyncLineContent(
                identifier: TasksSyncLineAccessibilityId.line,
                text: l10n.tasks_sync_progress(done: done, total: total),
                secondaryText: keptLocal > 0 ? l10n.tasks_sync_keptLocal(keptLocal) : nil,
                hint: l10n.tasks_sync_olderHint,
                tap: { [weak self] in self?.openOlderTasks() }
            )
        case let .loading(keptLocal):
            return TasksSyncLineContent(
                identifier: TasksSyncLineAccessibilityId.line,
                text: l10n.tasks_cloud_status_loading,
                secondaryText: keptLocal > 0 ? l10n.tasks_sync_keptLocal(keptLocal) : nil,
                hint: l10n.tasks_sync_olderHint,
                tap: { [weak self] in self?.openOlderTasks() }
            )
        case let .newRows(count, keptLocal):
            return TasksSyncLineContent(
                identifier: TasksSyncLineAccessibilityId.line,
                text: l10n.tasks_sync_newRows(count),
                secondaryText: keptLocal > 0 ? l10n.tasks_sync_keptLocal(keptLocal) : nil,
                hint: l10n.tasks_sync_olderHint,
                tap: { [weak self] in self?.openOlderTasks() },
                actions: [TasksSyncLineAction(title: l10n.tasks_sync_newRows_action, identifier: TasksSyncLineAccessibilityId.action("sync"), isPrimary: true, action: { [weak self] in
                    self?.openImport()
                })]
            )
        case .otherAccountNotice:
            return TasksSyncLineContent(
                identifier: TasksSyncLineAccessibilityId.line,
                text: l10n.tasks_sync_otherAccount,
                actions: [
                    TasksSyncLineAction(title: l10n.tasks_sync_view_action, identifier: TasksSyncLineAccessibilityId.action("view"), isPrimary: true, action: { [weak self] in
                        self?.openOlderTasks()
                    }),
                    TasksSyncLineAction(title: l10n.tasks_assign_explainer_ok, identifier: TasksSyncLineAccessibilityId.action("dismiss"), isPrimary: false, action: { [weak self] in
                        self?.dismissOtherAccountNotice()
                    })
                ]
            )
        }
    }

    // MARK: - The line's and the entry's targets

    /// "Eski vazifalar": the device rows, read-only, with the footer of the resolver's reason.
    private func openOlderTasks() {
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        self.view.endEditing(true)
        let controller = TasksLegacyBoardController(context: self.context, accountPeerId: self.accountPeerId, kind: .older(reason: { [weak self] in
            if case let .older(reason)? = self?.presentation.olderEntry {
                return reason
            }
            return nil
        }))
        navigationController.pushViewController(controller)
    }

    /// "Sinxronlangan nusxa": the account's own cached synced rows after sync went off (F12).
    private func openSyncedCopy() {
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        self.view.endEditing(true)
        navigationController.pushViewController(TasksLegacyBoardController(context: self.context, accountPeerId: self.accountPeerId, kind: .syncedCopy))
    }

    /// The Lists screens' entry.
    private func openOlder(_ entry: TasksOlderEntry) {
        switch entry {
        case .older:
            self.openOlderTasks()
        case .syncedCopy:
            self.openSyncedCopy()
        }
    }

    /// The sync-off line: Settings › Zenlygram › Maʼlumotlar va rozilik (§6.1). The installed hook's
    /// screen is pushed here (the same controller the Settings hub row pushes); with no hook the
    /// Settings route opens the row; a hook that answers nil turns the line into plain text.
    private func openDataConsent() {
        guard let entry = SGTasksConsentEntry.installed else {
            self.context.sharedContext.applicationBindings.openUrl(SGTasksConsentEntry.dataConsentFallbackURL)
            return
        }
        guard let controller = entry.dataConsentController(self.context) else {
            self.consentEntryUnavailable = true
            self.refreshPresentation()
            return
        }
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        self.view.endEditing(true)
        navigationController.pushViewController(controller)
    }

    /// D1 (§6.2): at the first open of Vazifalar the account's one consent prompt is asked through
    /// the installed hook — once per account per process, never once it was presented from here
    /// (`consentPromptedKey`), and not while a D4 sheet is about to show. In required mode the hook
    /// answers false without a prompt (the wall at launch decided); in optional mode it presents the
    /// first prompt only if the account never decided and this attach showed none.
    private func promptForConsentIfNeeded() {
        guard !TasksBoardController.consentPromptAsked.contains(self.accountPeerId) else {
            return
        }
        guard !UserDefaults.standard.bool(forKey: self.consentPromptedKey) else {
            return
        }
        guard !self.legacyAssigneeSheetWillShow else {
            return
        }
        TasksBoardController.consentPromptAsked.insert(self.accountPeerId)
        guard let entry = SGTasksConsentEntry.installed else {
            return
        }
        if entry.promptIfUndecided(self.context) {
            UserDefaults.standard.set(true, forKey: self.consentPromptedKey)
        }
    }

    /// Whether the legacy assignee sheet (D4, §7.1) is about to be presented on this appearance, in
    /// which case the consent prompt is not asked now.
    private var legacyAssigneeSheetWillShow: Bool {
        return self.legacyAssigneeSheet != nil || self.dueLegacyAssigneeOffer() != nil
    }

    /// The waiting line's Bogʻlash (S3 over the device board, S4 over the synced one).
    private func openLinkAccount() {
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        self.view.endEditing(true)
        tasksPushLinkAccountController(context: self.context, accountPeerId: self.accountPeerId, presentationData: self.presentationData, navigationController: navigationController)
    }

    /// The S6b / S8 line's "Sinxronlash": the existing explicit, CREATE-gated copy.
    private func openImport() {
        self.view.endEditing(true)
        self.ensureCloudPresenter().openImport()
    }

    private func dismissOtherAccountNotice() {
        UserDefaults.standard.set(true, forKey: self.otherAccountNoticeKey)
        self.refreshPresentation()
    }

    // MARK: - Analytics (taxonomy v1 screen / feature events)

    /// `featureUsed("tasks_cloud")` when the synced board appears (the `tasks_scope` dimension of the
    /// per-action events stays cloud/device by board source).
    private func emitSourceAnalytics() {
        if case .synced = self.presentation.source {
            SGTasksAnalytics.emit(.featureUsed("tasks_cloud"), accountPeerId: self.accountPeerId)
        }
    }

    private func emitCalendarShown() {
        SGTasksAnalytics.emit(.screen("tasks.calendar"), accountPeerId: self.accountPeerId)
        SGTasksAnalytics.emit(.featureUsed("tasks_calendar"), accountPeerId: self.accountPeerId)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.hostNode.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: transition)

        var presentationLayout = layout
        presentationLayout.intrinsicInsets.bottom = self.hostNode.bottomOccupiedHeight
        presentationLayout.inputHeight = nil
        self.presentationContext.containerLayoutUpdated(presentationLayout, transition: transition)
    }

    // Tasks change on the Lists screen and (for the same database) on the other entry point, so
    // re-read on every appearance. A selected list deleted meanwhile falls back to "All".
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.isBoardVisible = true
        self.reload()
        self.refreshPresentation()
        if case .synced = self.presentation.source {
            self.ensureCloudPresenter().appear()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.isBoardOnScreen = true
        SGTasksAnalytics.emit(.screen("tasks.board"), accountPeerId: self.accountPeerId)
        SGTasksAnalytics.emit(.featureUsed("tasks"), accountPeerId: self.accountPeerId)
        self.emitSourceAnalytics()
        self.promptForConsentIfNeeded()
        // wf15 §7.1: the one-time sheet, on appear (and again from every fact change while on screen).
        self.offerLegacyAssigneesIfNeeded()
    }

    /// Leaving the board ends cloud polling and promotes a held cloud delete (its toast commits).
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.isBoardVisible = false
        self.isBoardOnScreen = false
        self.cloudPresenter?.disappear()
    }

    /// Re-renders the loaded board (rows and the composer's deadline) with the same state: deadline
    /// text is derived at render time. The composer's text, assignee and deadline draft are kept.
    private func refreshTimeDependentText() {
        guard self.isNodeLoaded else {
            return
        }
        self.boardNode?.update(state: self.state)
        self.cloudPresenter?.refreshTimeDependentText()
        // The composer's deadline text can change length, and with it the composer's height.
        self.requestLayout(transition: .immediate)
    }

    // MARK: - State

    private func updateState(_ f: (inout TasksBoardState) -> Void) {
        var state = self.state
        f(&state)
        guard state != self.state else {
            return
        }
        self.state = state
        self.boardNode?.update(state: state)
    }

    /// Re-reads the board. If the database cannot be opened (schema setup failed, store closed) the
    /// board keeps what it showed — never a misleading empty board — and the user is told once per
    /// failing streak. Drafts are untouched either way. (Read failures of an open database still go
    /// through the legacy load APIs, which are unchanged.)
    ///
    /// Returns true when this call scheduled the storage-unavailable alert, so a failed action does
    /// not stack its own generic error on top of it.
    @discardableResult
    private func reload() -> Bool {
        do {
            try TodoStorage.checkAvailability()
        } catch {
            return self.reportStorageUnavailable()
        }
        self.isReportingStorageUnavailable = false
        let folders = TodoStorage.loadFolders()
        let tasks = TodoStorage.loadTasks()
        let rowCount = self.state.tasks.count
        self.updateState { $0.update(folders: folders, tasks: tasks) }
        if tasks.count != rowCount {
            // The device rows count is a resolver input (S5/S6/S6b): a first row or the last one gone
            // can move the board.
            self.schedulePresentationRefresh()
        }
        return false
    }

    private func reportStorageUnavailable() -> Bool {
        guard !self.isReportingStorageUnavailable else {
            return false
        }
        self.isReportingStorageUnavailable = true
        // Deferred: reload runs inside viewWillAppear and other transitions.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.presentError(self.l10n.tasks_error_generic)
        }
        return true
    }

    /// After a failed action: re-read, and show `text` unless the reload already reports storage.
    private func reloadAfterFailure(showing text: String) {
        if !self.reload() {
            self.presentError(text)
        }
    }

    private var l10n: SGTasksL10n {
        return SGTasksL10n(self.presentationData.strings)
    }

    private func presentInWindow(_ controller: ViewController) {
        self.present(controller, in: .window(.root))
    }

    private func presentError(_ text: String) {
        self.presentInWindow(tasksErrorAlert(context: self.context, text: text))
    }

    /// A transient note above the composer (R4 write fence); never an error alert.
    private func presentNotice(_ text: String) {
        self.noticeController?.dismiss()
        let notice = tasksNoticeToast(context: self.context, text: text)
        self.noticeController = notice
        self.present(notice, in: .current)
    }

    /// A refused write. The R4 fence answers with a note and the caller keeps the user's input: a
    /// migration step is copying the device rows (try again), or the device rows became read-only
    /// (the account's copy exists: the board flips to the synced one with the refreshed facts).
    /// Anything else is the usual reload and alert.
    private func handleWriteFailure(_ error: Error, showing text: String) {
        if let notice = tasksWriteFenceNotice(error, accountPeerId: self.accountPeerId, l10n: self.l10n) {
            if case .archived? = error as? TodoDatabaseError {
                self.refreshPresentation()
            }
            self.presentNotice(notice)
            return
        }
        self.reloadAfterFailure(showing: text)
    }

    // MARK: - Actions

    /// The quick-add CREATE path. Returns true only after the task is stored, so a rejected title, a
    /// declined paywall or a storage failure all keep the draft — title, assignee and deadline.
    private func submitQuickAdd(_ rawTitle: String) -> Bool {
        let title: String
        switch tasksValidateTitle(rawTitle, limit: TasksTitleLimit.task) {
        case .empty:
            return false
        case .tooLong:
            self.presentError(self.l10n.tasks_error_titleTooLong(limit: TasksTitleLimit.task))
            return false
        case let .valid(validTitle):
            title = validTitle
        }
        // MARK: Zenlygram — the gate runs before anything is written, so a lapse creates neither the
        // task nor the inbox list.
        guard tasksCreateGate(context: self.context, present: { [weak self] c in self?.presentInWindow(c) }) else {
            return false
        }
        let metadata = self.quickAddMetadata
        let folderId = self.state.quickAddFolderId
        do {
            let task = try TodoStorage.createQuickTask(folderId: folderId, title: title, inboxTitle: self.l10n.tasks_inbox_title, assignee: metadata.assignee, dueAt: metadata.dueAt, asAccount: self.accountPeerId)
            SGTasksAnalytics.emit(.taskCreated(cloud: false, hasDue: task.dueAt != nil, priority: task.priority, inList: folderId != nil), accountPeerId: self.accountPeerId)
            self.updateQuickAddMetadata { $0 = .empty }
            self.reload()
            self.boardNode?.reveal(taskId: task.id)
            return true
        } catch {
            // e.g. the selected list was deleted meanwhile: the reload falls back to "All" and the
            // draft stays, so sending again files it in the inbox. A fenced write keeps it too.
            self.handleWriteFailure(error, showing: self.l10n.tasks_error_generic)
            return false
        }
    }

    private func updateQuickAddMetadata(_ f: (inout TasksTaskMetadataDraft) -> Void) {
        var metadata = self.quickAddMetadata
        f(&metadata)
        guard metadata != self.quickAddMetadata else {
            return
        }
        self.quickAddMetadata = metadata
        if let boardNode = self.boardNode {
            boardNode.updateQuickAddMetadata(metadata)
            // A chosen value can change the composer's height (and so the Undo toast's position).
            self.requestLayout(transition: .immediate)
        }
    }

    /// Pickers take the keyboard away; it returns to the title field afterwards if it was there and
    /// the board is still on screen.
    private func takeKeyboardForPicker() -> () -> Void {
        let wasEditing = self.boardNode?.isEditingQuickAddTitle ?? false
        self.view.endEditing(true)
        return { [weak self] in
            guard wasEditing, let self, self.isNodeLoaded, self.view.window != nil else {
                return
            }
            self.boardNode?.focusQuickAddTitle()
        }
    }

    /// The device composer's Masʼul pill. Under the one-board model it opens the needs-sync sheet or
    /// the wait toast (wf15 §4.4); only S1 still picks today's local assignee (a local annotation; the
    /// contact is not messaged or notified). The keyboard comes back however the picker closes,
    /// including a swipe or an outside tap.
    private func pickQuickAddAssignee() {
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        guard tasksDeviceAssignAllowsPicker(self.deviceAssignGate, context: self.context, present: { [weak self] c in self?.presentInWindow(c) }, presentToast: { [weak self] toast in self?.present(toast, in: .current) }) else {
            return
        }
        let restoreKeyboard = self.takeKeyboardForPicker()
        let closedDisposable = pushTasksAssigneePicker(context: self.context, navigationController: navigationController, completion: { [weak self] assignee in
            if let assignee {
                self?.updateQuickAddMetadata { $0.assignee = assignee }
            }
        }, closed: restoreKeyboard)
        if let closedDisposable {
            self.assigneePickerClosedDisposable?.dispose()
            self.assigneePickerClosedDisposable = closedDisposable
        }
    }

    private func pickQuickAddDeadline() {
        let restoreKeyboard = self.takeKeyboardForPicker()
        presentTasksDeadlinePicker(from: self.view, currentDueAt: self.quickAddMetadata.dueAt, presentationData: self.presentationData, commit: { [weak self] result in
            switch result {
            case let .set(dueAt):
                self?.updateQuickAddMetadata { $0.dueAt = dueAt }
            case .clear:
                self?.updateQuickAddMetadata { $0.dueAt = nil }
            }
        }, dismissed: restoreKeyboard)
    }

    private func createList() {
        presentTasksCreateListAlert(context: self.context, present: { [weak self] c in self?.presentInWindow(c) }, created: { [weak self] folder in
            self?.reload()
            self?.updateState { $0.select(.folder(id: folder.id)) }
        })
    }

    /// An explicit target state (what the row or menu showed), never a toggle: if the task was
    /// completed or reopened meanwhile, repeating that state is a no-op in storage, not a flip back.
    private func setTaskCompleted(id: String, isCompleted: Bool) {
        guard let task = self.state.task(id: id) else {
            return
        }
        do {
            try TodoStorage.setTaskCompleted(id: id, isCompleted: isCompleted, asAccount: self.accountPeerId)
        } catch {
            self.handleWriteFailure(error, showing: self.l10n.tasks_error_generic)
            return
        }
        if task.isCompleted != isCompleted {
            SGTasksAnalytics.emit(.taskCompleted(cloud: false, reopened: !isCompleted), accountPeerId: self.accountPeerId)
        }
        self.reload()
    }

    /// Name, assignee and deadline of an existing task. Never gated: it edits, it does not create.
    private func editTask(id: String) {
        guard let task = self.state.task(id: id) else {
            return
        }
        guard let navigationController = self.navigationController as? NavigationController, !(navigationController.topViewController is TasksTaskEditorController) else {
            return
        }
        self.view.endEditing(true)
        let controller = TasksTaskEditorController(context: self.context, task: task, accountPeerId: self.accountPeerId, readOnly: false, assignGate: self.deviceAssignGate, saved: { [weak self] in
            self?.reload()
        })
        navigationController.pushViewController(controller)
    }

    /// Deletes at once and offers Undo with the exact stored row (id, list, metadata, order).
    private func deleteTask(id: String) {
        let snapshot: TodoDeletedTaskSnapshot?
        do {
            snapshot = try TodoStorage.deleteTaskForUndo(id: id, asAccount: self.accountPeerId)
        } catch {
            self.handleWriteFailure(error, showing: self.l10n.tasks_error_generic)
            return
        }
        self.reload()
        guard let snapshot else {
            // Already gone (deleted elsewhere): nothing to undo.
            return
        }
        self.presentUndo(for: snapshot)
    }

    /// The storage's opaque token is kept as-is for the toast's lifetime; it is never rebuilt, so an
    /// Undo after a logout wipe or on another database is refused by storage. `text`: why an earlier
    /// Undo did not apply yet (a migration step was copying the device rows), so it can be tapped again.
    private func presentUndo(for snapshot: TodoDeletedTaskSnapshot, text: String? = nil) {
        // One toast at a time: an earlier one is committed (its task stays deleted).
        self.forEachController { controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
            return true
        }
        let accountPeerId = self.accountPeerId
        var isSettled = false
        let undo = UndoOverlayController(
            presentationData: self.presentationData,
            content: .removedChat(context: self.context, title: NSAttributedString(string: self.l10n.tasks_taskDeleted), text: text),
            elevatedLayout: false,
            action: { [weak self] action in
                guard !isSettled else {
                    return true
                }
                switch action {
                case .undo:
                    isSettled = true
                    self?.restore(snapshot)
                case .commit:
                    // The delete stands once its Undo is gone (as the cloud board's held delete).
                    isSettled = true
                    SGTasksAnalytics.emit(.taskDeleted(cloud: false), accountPeerId: accountPeerId)
                case .info:
                    break
                }
                return true
            }
        )
        self.present(undo, in: .current)
    }

    /// Never gated: undo restores an existing task, it does not create one. If its list was deleted
    /// meanwhile the restore fails (the list is not recreated) and the user is told. A migration
    /// step in progress offers the same Undo again; read-only device rows explain themselves.
    private func restore(_ snapshot: TodoDeletedTaskSnapshot) {
        do {
            try TodoStorage.restoreDeletedTask(snapshot, asAccount: self.accountPeerId)
        } catch TodoDatabaseError.migrating {
            // After the tapped toast has gone (it is still closing while its action runs).
            let text = self.l10n.tasks_migration_busy
            DispatchQueue.main.async { [weak self] in
                self?.presentUndo(for: snapshot, text: text)
            }
            return
        } catch {
            self.handleWriteFailure(error, showing: self.l10n.tasks_error_restore)
            return
        }
        self.reload()
    }

    @objc private func listsPressed() {
        let olderEntry = self.olderEntryPromise.get()
        let openOlder: (TasksOlderEntry) -> Void = { [weak self] entry in
            self?.openOlder(entry)
        }
        if case .synced = self.presentation.source, let cloudPresenter = self.cloudPresenter {
            cloudPresenter.openLists(olderEntry: olderEntry, openOlder: openOlder, openUnsentAssignees: { [weak self] in
                self?.openUnsentAssignees()
            })
            return
        }
        let controller = tasksListsController(context: self.context, olderEntry: olderEntry, openOlder: openOlder, openList: { [weak self] folder in
            self?.reload()
            self?.updateState { $0.select(.folder(id: folder.id)) }
        })
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }
}

/// Calls `changed` on the main queue when the app becomes active or the system reports a significant
/// time change (midnight, a time-zone or daylight-saving change, a clock update), so relative deadline
/// text ("Today", "Tomorrow") is re-derived. A suspended app gets the time change on resume. No timer
/// and no background work; the observers are removed when this object is released.
final class TasksTimeContextObserver {
    private let observers: [NSObjectProtocol]

    init(changed: @escaping () -> Void) {
        let center = NotificationCenter.default
        self.observers = [UIApplication.didBecomeActiveNotification, UIApplication.significantTimeChangeNotification].map { name in
            return center.addObserver(forName: name, object: nil, queue: .main, using: { _ in
                changed()
            })
        }
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
