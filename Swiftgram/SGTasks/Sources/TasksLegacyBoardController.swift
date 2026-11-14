import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import UndoUI
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — Tasks: the two read-only screens of wf15 §3.4, pushed from the status line or from
// Roʻyxatlar so that no row is ever stranded (§3.3).
//
// "Eski vazifalar" = the device rows in the board node's read-only mode: no composer, no completion,
// swipe or removal, context menu "Open" only; filters and the calendar keep working; a footer says
// why the rows are here (`tasks_older_footer_*`, by the resolver's reason); a row opens the read-only
// device editor ("Eski vazifa"). The rows are never written: the main board's write fence would
// refuse it anyway while the account's copy exists.
//
// "Sinxronlangan nusxa" = the synced board node in its read-only copy mode over the account's cached
// store after sync went off (F12, the promise of DataConsent.Withdraw.Confirm.Text): owner-role rows
// only, no status cards, the synced-copy footer; a row opens the synced editor, which re-reads the
// consent hold and is read-only under it. Nothing is queued, nothing is sent, no sync is started.

/// Which read-only view the screen shows.
enum TasksLegacyBoardKind {
    /// "Eski vazifalar". `reason` is re-read on every refresh so the footer follows the cut-over; nil
    /// (the entry went away while the screen is open) keeps the last footer.
    case older(reason: () -> TasksOlderReason?)
    /// "Sinxronlangan nusxa".
    case syncedCopy
}

final class TasksLegacyBoardController: ViewController {
    private let context: AccountContext
    private let accountPeerId: Int64
    private let kind: TasksLegacyBoardKind
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    private var observers: [NSObjectProtocol] = []
    private weak var noticeController: UndoOverlayController?
    private var isRefreshScheduled = false

    // Eski vazifalar.
    private var deviceState: TasksBoardState?
    private var deviceNode: TasksBoardNode?
    private var lastReason: TasksOlderReason?

    // Sinxronlangan nusxa.
    private var repository: SGTasksCloudRepository?
    private var copyState: TasksCloudBoardState?
    private var copyNode: TasksCloudBoardNode?

    /// The editor this screen pushed, while it is on the navigation stack.
    private weak var openEditor: ViewController?

    private var hostNode: TasksBoardHostNode {
        return self.displayNode as! TasksBoardHostNode
    }

    init(context: AccountContext, accountPeerId: Int64, kind: TasksLegacyBoardKind) {
        self.context = context
        self.accountPeerId = accountPeerId
        self.kind = kind
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        switch kind {
        case let .older(reason):
            self.lastReason = reason()
            self.deviceState = TasksBoardState(folders: TodoStorage.loadFolders(), tasks: TodoStorage.loadTasks(), isReadOnly: true)
        case .syncedCopy:
            let repository = SGTasksCloudRepository.repository(accountPeerId: accountPeerId)
            let cloud = repository.state
            self.repository = repository
            self.copyState = TasksCloudBoardState(
                cloud: cloud,
                isLinked: SGEntitlement.shared.isLinked(accountPeerId: accountPeerId),
                now: Date(),
                isConsentWithdrawn: repository.readOnlyReason(cloud) == .withdrawn,
                isSyncedCopy: true
            )
        }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))

        self.applyStrings()

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
                if self.isNodeLoaded {
                    self.hostNode.updatePresentationData(presentationData)
                    self.refresh()
                }
            }
        })

        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: SGTasksSyncCoordinator.cutOverDidChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self, notification.userInfo?["accountPeerId"] as? Int64 == self.accountPeerId else {
                return
            }
            self.scheduleRefresh()
        }))
        self.observers.append(center.addObserver(forName: SGTasksCloudRepository.didChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self, notification.userInfo?["accountPeerId"] as? Int64 == self.accountPeerId else {
                return
            }
            self.scheduleRefresh()
        }))
        self.observers.append(center.addObserver(forName: SGTasksCloudRepository.migrationDidChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self, notification.userInfo?["accountPeerId"] as? Int64 == self.accountPeerId else {
                return
            }
            self.scheduleRefresh()
        }))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private var l10n: SGTasksL10n {
        return SGTasksL10n(self.presentationData.strings)
    }

    private func applyStrings() {
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        switch self.kind {
        case .older:
            self.title = self.l10n.tasks_older_title
        case .syncedCopy:
            self.title = self.l10n.tasks_syncedCopy_title
        }
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
    }

    override func loadDisplayNode() {
        switch self.kind {
        case .older:
            let rowActions = TasksRowActions(
                setCompleted: { [weak self] _, _, _ in self?.refuseWrite() },
                edit: { [weak self] id in self?.openDeviceTask(id: id) },
                delete: { [weak self] _, _ in self?.refuseWrite() }
            )
            let interaction = TasksBoardInteraction(
                selectFilter: { [weak self] filter in self?.updateDeviceState { $0.select(filter) } },
                createList: { [weak self] in self?.refuseWrite() },
                toggleCompletedSection: { [weak self] in self?.updateDeviceState { $0.isCompletedExpanded.toggle() } },
                rowActions: rowActions,
                submitQuickAdd: { _ in false },
                pickQuickAddAssignee: {},
                clearQuickAddAssignee: {},
                pickQuickAddDeadline: {},
                clearQuickAddDeadline: {},
                calendarShown: { [weak self] in self?.emitCalendarShown() }
            )
            let node = TasksBoardNode(state: self.deviceState ?? TasksBoardState(folders: [], tasks: [], isReadOnly: true), quickAddMetadata: .empty, presentationData: self.presentationData, interaction: interaction)
            self.deviceNode = node
            self.displayNode = TasksBoardHostNode(localNode: node, cloudNode: nil, source: .device(writable: false), presentationData: self.presentationData)
        case .syncedCopy:
            let rowActions = TasksRowActions(
                setCompleted: { [weak self] _, _, _ in self?.refuseWrite() },
                edit: { [weak self] id in self?.openSyncedTask(id: id) },
                delete: { [weak self] _, _ in self?.refuseWrite() }
            )
            let interaction = TasksCloudBoardInteraction(
                selectFilter: { [weak self] filter in self?.updateCopyState { $0.select(filter) } },
                createList: { [weak self] in self?.refuseWrite() },
                toggleCompletedSection: { [weak self] in self?.updateCopyState { $0.isCompletedExpanded.toggle() } },
                rowActions: rowActions,
                submitQuickAdd: { _ in false },
                pickQuickAddAssignee: {},
                clearQuickAddAssignee: {},
                pickQuickAddDeadline: {},
                clearQuickAddDeadline: {},
                openLinkAccount: {},
                retrySync: {},
                openUnsentChanges: {},
                openInvitations: {},
                dismissNotice: { _ in },
                calendarShown: { [weak self] in self?.emitCalendarShown() }
            )
            let node = TasksCloudBoardNode(state: self.copyState ?? TasksCloudBoardState(cloud: .empty, isLinked: false, now: Date(), isSyncedCopy: true), quickAddDueAt: nil, quickAddAssigneeName: nil, presentationData: self.presentationData, interaction: interaction)
            self.copyNode = node
            self.displayNode = TasksBoardHostNode(localNode: nil, cloudNode: node, source: .synced(readOnly: true), presentationData: self.presentationData)
        }
        self.displayNodeDidLoad()
        self.automaticallyControlPresentationContextLayout = false
        self.refresh()
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .older = self.kind {
            SGTasksAnalytics.emit(.screen("tasks.archive"), accountPeerId: self.accountPeerId)
        }
    }

    // MARK: - State

    private func scheduleRefresh() {
        guard !self.isRefreshScheduled else {
            return
        }
        self.isRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else {
                return
            }
            self.isRefreshScheduled = false
            self.refresh()
        }
    }

    /// Re-reads the rows and the footer. Device rows change only on the main board; the footer's
    /// reason and the cached synced rows follow the coordinator and the repository.
    private func refresh() {
        guard self.isNodeLoaded else {
            return
        }
        switch self.kind {
        case let .older(reason):
            if let current = reason() {
                self.lastReason = current
            }
            let folders = TodoStorage.loadFolders()
            let tasks = TodoStorage.loadTasks()
            self.updateDeviceState { $0.update(folders: folders, tasks: tasks) }
            self.hostNode.update(line: self.footer(for: self.lastReason))
        case .syncedCopy:
            guard let repository = self.repository else {
                return
            }
            let cloud = repository.state
            let isLinked = SGEntitlement.shared.isLinked(accountPeerId: self.accountPeerId)
            let isWithdrawn = repository.readOnlyReason(cloud) == .withdrawn
            self.updateCopyState { $0.update(cloud: cloud, isLinked: isLinked, now: Date(), isConsentWithdrawn: isWithdrawn) }
        }
        self.requestLayout(transition: .immediate)
    }

    private func updateDeviceState(_ f: (inout TasksBoardState) -> Void) {
        guard var state = self.deviceState else {
            return
        }
        f(&state)
        guard state != self.deviceState else {
            return
        }
        self.deviceState = state
        self.deviceNode?.update(state: state)
    }

    private func updateCopyState(_ f: (inout TasksCloudBoardState) -> Void) {
        guard var state = self.copyState else {
            return
        }
        f(&state)
        guard state != self.copyState else {
            return
        }
        self.copyState = state
        self.copyNode?.update(state: state)
        self.requestLayout(transition: .immediate)
    }

    /// The footer of Eski vazifalar by the resolver's reason (`tasks_older_footer_*`); plain text.
    private func footer(for reason: TasksOlderReason?) -> TasksSyncLineContent? {
        let l10n = self.l10n
        let text: String
        switch reason {
        case .migrating?:
            text = l10n.tasks_older_footer_migrating
        case .awaiting?:
            text = l10n.tasks_older_footer_awaiting
        case let .newRows(count)?:
            text = l10n.tasks_older_footer_newRows(count)
        case .checking?:
            text = l10n.tasks_older_footer_checking
        case .otherAccount?:
            text = l10n.tasks_older_footer_otherAccount
        case nil:
            text = l10n.tasks_older_readOnly
        }
        return TasksSyncLineContent(identifier: TasksSyncLineAccessibilityId.olderFooter, text: text)
    }

    // MARK: - Actions (all read-only)

    /// A write path reached anyway (the "New List" chip, a stale row action): say why, write nothing.
    private func refuseWrite() {
        let text: String
        switch self.kind {
        case .older:
            text = self.l10n.tasks_older_readOnly
        case .syncedCopy:
            let reason = self.repository.flatMap { $0.readOnlyReason($0.state) } ?? .consentOff
            text = self.l10n.tasks_cloud_readOnly(reason)
        }
        self.noticeController?.dismiss()
        let notice = tasksNoticeToast(context: self.context, text: text)
        self.noticeController = notice
        self.present(notice, in: .current)
    }

    private func openDeviceTask(id: String) {
        guard let task = self.deviceState?.task(id: id), let navigationController = self.navigationController as? NavigationController else {
            return
        }
        if let openEditor = self.openEditor, navigationController.viewControllers.contains(where: { $0 === openEditor }) {
            return
        }
        let controller = TasksTaskEditorController(context: self.context, task: task, accountPeerId: self.accountPeerId, readOnly: true, saved: {})
        self.openEditor = controller
        navigationController.pushViewController(controller)
    }

    private func openSyncedTask(id: String) {
        guard let repository = self.repository, let task = self.copyState?.task(id: id), let navigationController = self.navigationController as? NavigationController else {
            return
        }
        if let openEditor = self.openEditor, navigationController.viewControllers.contains(where: { $0 === openEditor }) {
            return
        }
        // The editor re-reads the consent hold (sync off) and opens read-only under it; a delete is
        // never requested from a read-only editor, so the host actions do nothing.
        let controller = tasksCloudTaskEditorController(context: self.context, repository: repository, task: task, mode: .edit(TasksCloudEditorHostActions(
            requestDelete: { _ in },
            openUnsentChanges: {}
        )))
        self.openEditor = controller
        navigationController.pushViewController(controller)
    }

    private func emitCalendarShown() {
        SGTasksAnalytics.emit(.screen("tasks.calendar"), accountPeerId: self.accountPeerId)
        SGTasksAnalytics.emit(.featureUsed("tasks_calendar"), accountPeerId: self.accountPeerId)
    }
}
