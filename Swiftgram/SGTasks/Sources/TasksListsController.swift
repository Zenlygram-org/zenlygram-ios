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
import SGEntitlement

// Zenlygram — Tasks ▸ Lists: the former folder-first Tasks screen, now reached from the board's
// "Lists" button. It keeps every list capability the old screen had — create (gated), open,
// rename and delete with the cascade confirmation — while the tasks themselves live on the board.
//
// R4 (design 30 §5.6): every write names the account (`asAccount:`). While the account's cut-over
// forbids device writes the screen is read-only (lists open, nothing else); a write the storage
// fence refuses shows a note instead of an error alert, and a write during a migration step keeps
// the typed name for another try. wf15 §3.3: the one-board resolver's Roʻyxatlar entry ("Eski
// vazifalar" / "Sinxronlangan nusxa") leads the screen whenever rows exist that the board does not
// show, so no row is ever stranded.

private enum TasksListsSection: Int32 {
    case main = 0
}

private enum TasksListsEntry: ItemListNodeEntry {
    /// wf15: the read-only rows the board does not show (Eski vazifalar / Sinxronlangan nusxa).
    case older(PresentationTheme, TasksOlderEntry, String)
    /// Why the lists are read-only (the cut-over forbids device writes).
    case archiveNotice(PresentationTheme, String)
    case header(PresentationTheme, String)
    // SG: Tasks — audit #45 follow-up: `slot` is the list's identity for the ItemList diff, so deleting
    // the 3rd of 5 lists animates that row away instead of the last one. `index` is the display order.
    case folder(index: Int, slot: Int32, theme: PresentationTheme, folder: TodoFolder, doneCount: Int, totalCount: Int)
    case empty(PresentationTheme, String)

    var section: ItemListSectionId { TasksListsSection.main.rawValue }

    var stableId: Int32 {
        // Reserved ids: list slots are handed out from 0 upwards, so they never collide with these.
        switch self {
        case .older: return -102
        case .archiveNotice: return -101
        case .header: return -100
        case .empty: return -99
        case let .folder(_, slot, _, _, _, _):
            return slot
        }
    }

    private var sortIndex: Int {
        switch self {
        case .older: return -4
        case .archiveNotice: return -3
        case .header: return -2
        case .empty: return -1
        case let .folder(index, _, _, _, _, _):
            return index
        }
    }

    static func ==(lhs: TasksListsEntry, rhs: TasksListsEntry) -> Bool {
        switch lhs {
        case let .older(lhsTheme, lhsEntry, lhsTitle):
            if case let .older(rhsTheme, rhsEntry, rhsTitle) = rhs, lhsTheme === rhsTheme, lhsEntry == rhsEntry, lhsTitle == rhsTitle { return true }
            return false
        case let .archiveNotice(lhsTheme, lhsText):
            if case let .archiveNotice(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText { return true }
            return false
        case let .header(lhsTheme, lhsText):
            if case let .header(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText { return true }
            return false
        case let .folder(lhsIndex, lhsSlot, lhsTheme, lhsFolder, lhsDone, lhsTotal):
            if case let .folder(rhsIndex, rhsSlot, rhsTheme, rhsFolder, rhsDone, rhsTotal) = rhs, lhsIndex == rhsIndex, lhsSlot == rhsSlot, lhsTheme === rhsTheme, lhsFolder == rhsFolder, lhsDone == rhsDone, lhsTotal == rhsTotal { return true }
            return false
        case let .empty(lhsTheme, lhsText):
            if case let .empty(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText { return true }
            return false
        }
    }

    static func <(lhs: TasksListsEntry, rhs: TasksListsEntry) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! TasksListsArguments
        switch self {
        case let .older(_, entry, title):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: "",
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openOlder(entry)
                }
            )
        case let .archiveNotice(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .folder(_, _, _, folder, doneCount, totalCount):
            let label = totalCount > 0 ? "\(doneCount)/\(totalCount)" : "0"
            let badgeColor = doneCount == totalCount && totalCount > 0
                ? UIColor(rgb: 0x34c759)
                : presentationData.theme.list.itemAccentColor
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: folder.title,
                label: label,
                labelStyle: .badge(badgeColor),
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openFolder(folder)
                }
            )
        case let .empty(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private final class TasksListsArguments {
    let openFolder: (TodoFolder) -> Void
    let openOlder: (TasksOlderEntry) -> Void

    init(openOlder: @escaping (TasksOlderEntry) -> Void, openFolder: @escaping (TodoFolder) -> Void) {
        self.openOlder = openOlder
        self.openFolder = openFolder
    }
}

/// The title of the resolver's Roʻyxatlar entry (wf15 §3.3).
func tasksOlderEntryTitle(_ entry: TasksOlderEntry, l10n: SGTasksL10n) -> String {
    switch entry {
    case .older:
        return l10n.tasks_older_title
    case .syncedCopy:
        return l10n.tasks_syncedCopy_title
    }
}

private struct TasksListsState: Equatable {
    private(set) var folders: [TodoFolder]
    var tasks: [TodoTask]
    // List id -> row slot, for this screen's lifetime only; never reused, so a row's stable id
    // survives insertions, deletions and reordering around it.
    private var slotsById: [String: Int32]
    private var nextSlot: Int32

    init() {
        self.folders = []
        self.tasks = TodoStorage.loadTasks()
        self.slotsById = [:]
        self.nextSlot = 0
        self.setFolders(TodoStorage.loadFolders())
    }

    mutating func setFolders(_ folders: [TodoFolder]) {
        for folder in folders where self.slotsById[folder.id] == nil {
            self.slotsById[folder.id] = self.nextSlot
            self.nextSlot &+= 1
        }
        self.folders = folders
    }

    func slot(for folder: TodoFolder) -> Int32 {
        return self.slotsById[folder.id] ?? Int32.max
    }
}

private func tasksListsEntries(presentationData: PresentationData, state: TasksListsState, archiveNotice: String?, olderEntry: TasksOlderEntry?) -> [TasksListsEntry] {
    let l10n = SGTasksL10n(presentationData.strings)
    var entries: [TasksListsEntry] = []
    if let olderEntry {
        entries.append(.older(presentationData.theme, olderEntry, tasksOlderEntryTitle(olderEntry, l10n: l10n)))
    }
    if let archiveNotice {
        entries.append(.archiveNotice(presentationData.theme, archiveNotice))
    }
    if state.folders.isEmpty {
        entries.append(.empty(presentationData.theme, l10n.tasks_folders_empty))
        return entries
    }

    let totalDone = state.tasks.filter { $0.isCompleted }.count
    let totalAll = state.tasks.count
    let header: String
    if totalAll == 0 {
        header = l10n.tasks_section_folders_headerWithCount(state.folders.count)
    } else {
        header = l10n.tasks_section_folders_headerWithProgress(folders: state.folders.count, done: totalDone, total: totalAll)
    }
    entries.append(.header(presentationData.theme, header))

    for (index, folder) in state.folders.enumerated() {
        let folderTasks = state.tasks.filter { $0.folderId == folder.id }
        let doneCount = folderTasks.filter { $0.isCompleted }.count
        entries.append(.folder(index: index, slot: state.slot(for: folder), theme: presentationData.theme, folder: folder, doneCount: doneCount, totalCount: folderTasks.count))
    }
    return entries
}

/// A one-button alert for a failed Tasks action. Storage errors are never shown verbatim.
func tasksErrorAlert(context: AccountContext, text: String) -> ViewController {
    let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
    return textAlertController(context: context, title: nil, text: text, actions: [
        TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})
    ])
}

/// The CREATE gate of every Tasks create path (`sgEntitlementGate(.createTask)`), recording the
/// paywall entry right before the gate presents the paywall (taxonomy v1, `.paywallEntry`).
func tasksCreateGate(context: AccountContext, present: (ViewController) -> Void) -> Bool {
    if case .blocked = SGEntitlement.gate(.createTask) {
        SGTasksAnalytics.emit(.paywallEntry, accountPeerId: context.account.peerId.toInt64())
    }
    return sgEntitlementGate(.createTask, context: context, present: present)
}

/// A transient note (R4: a write the storage fence refused) — never an error alert.
func tasksNoticeToast(context: AccountContext, text: String) -> UndoOverlayController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    return UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return true })
}

/// What a local write the R4 fence refused says instead of an error alert (design 30 §5.6): a
/// migration step is copying the device rows (try again), or the device rows are read-only now
/// (the account's copy exists: `tasks_older_readOnly`, wf15 §15.2). nil for any other error.
func tasksWriteFenceNotice(_ error: Error, accountPeerId: Int64, l10n: SGTasksL10n) -> String? {
    switch error as? TodoDatabaseError {
    case .migrating?:
        return l10n.tasks_migration_busy
    case .archived?:
        return l10n.tasks_older_readOnly
    default:
        return nil
    }
}

/// The account's cut-over now and on every change (main queue).
func tasksCutOverSignal(accountPeerId: Int64) -> Signal<TasksCutOver, NoError> {
    return Signal { subscriber in
        subscriber.putNext(SGTasksSyncCoordinator.shared.cutOver(accountPeerId: accountPeerId))
        let observer = NotificationCenter.default.addObserver(forName: SGTasksSyncCoordinator.cutOverDidChangeNotification, object: nil, queue: .main, using: { notification in
            guard notification.userInfo?["accountPeerId"] as? Int64 == accountPeerId else {
                return
            }
            subscriber.putNext(SGTasksSyncCoordinator.shared.cutOver(accountPeerId: accountPeerId))
        })
        return ActionDisposable {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    |> runOn(Queue.mainQueue())
}

/// The single CREATE path for a list (board chip and Lists screen "+"). Gated: a lapse shows the
/// paywall and creates nothing.
func presentTasksCreateListAlert(context: AccountContext, present: @escaping (ViewController) -> Void, created: @escaping (TodoFolder) -> Void) {
    presentTasksCreateListAlert(context: context, value: nil, text: nil, present: present, created: created)
}

/// `value` / `text`: the name typed before and why it was not created yet (a migration step was
/// copying the device rows), so another try keeps it.
private func presentTasksCreateListAlert(context: AccountContext, value: String?, text: String?, present: @escaping (ViewController) -> Void, created: @escaping (TodoFolder) -> Void) {
    // MARK: Zenlygram — Tasks is a paid feature and this is a CREATE path: a new list. Reading,
    // editing, completing and DELETING existing lists and tasks are never gated.
    guard tasksCreateGate(context: context, present: present) else {
        return
    }
    let l10n = SGTasksL10n(context.sharedContext.currentPresentationData.with { $0 }.strings)
    let accountPeerId = context.account.peerId.toInt64()
    let controller = sgTaskNameAlertController(
        context: context,
        title: l10n.tasks_newFolder_title,
        text: text ?? l10n.tasks_newFolder_prompt,
        placeholder: l10n.tasks_newFolder_placeholder,
        value: value,
        characterLimit: TasksTitleLimit.folder,
        apply: { rawTitle in
            switch tasksValidateTitle(rawTitle, limit: TasksTitleLimit.folder) {
            case .empty:
                // Whitespace-only is already blocked by the alert; this is an invisible-only name
                // (zero-width / combining characters) that storage would refuse.
                present(tasksErrorAlert(context: context, text: l10n.tasks_error_generic))
            case .tooLong:
                present(tasksErrorAlert(context: context, text: l10n.tasks_error_titleTooLong(limit: TasksTitleLimit.folder)))
            case let .valid(title):
                // The entitlement can lapse while the name alert is open: answer the gate again
                // immediately before the write. A denial shows the paywall and creates nothing.
                guard tasksCreateGate(context: context, present: present) else {
                    return
                }
                do {
                    let folder = try TodoStorage.createFolder(title: title, asAccount: accountPeerId)
                    SGTasksAnalytics.emit(.listCreated(cloud: false), accountPeerId: accountPeerId)
                    created(folder)
                } catch TodoDatabaseError.migrating {
                    // The alert has closed: the same name again, with why it is not there yet.
                    DispatchQueue.main.async {
                        presentTasksCreateListAlert(context: context, value: rawTitle, text: l10n.tasks_migration_busy, present: present, created: created)
                    }
                } catch {
                    if let notice = tasksWriteFenceNotice(error, accountPeerId: accountPeerId, l10n: l10n) {
                        present(tasksNoticeToast(context: context, text: notice))
                    } else {
                        present(tasksErrorAlert(context: context, text: l10n.tasks_error_generic))
                    }
                }
            }
        }
    )
    present(controller)
}

/// - Parameters:
///   - olderEntry: the resolver's Roʻyxatlar entry (wf15 §3.3), kept current while the screen is open.
///   - openOlder: pushes the read-only screen the entry names (this screen stays underneath).
///   - openList: selects the list on the board; this screen pops itself afterwards.
func tasksListsController(context: AccountContext, olderEntry: Signal<TasksOlderEntry?, NoError>, openOlder: @escaping (TasksOlderEntry) -> Void, openList: @escaping (TodoFolder) -> Void) -> ViewController {
    // One initial value for both holders, so the slot table does not differ on the first reload.
    let initialState = TasksListsState()
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((TasksListsState) -> TasksListsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var presentControllerImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?
    let accountPeerId = context.account.peerId.toInt64()
    /// R4: read at tap time, so an archive that began after the screen was drawn writes nothing.
    let isArchived: () -> Bool = {
        return SGTasksSyncCoordinator.shared.cutOver(accountPeerId: accountPeerId).isReadOnly
    }
    /// A write the storage fence refused: a note, never an error alert; anything else as before.
    let presentWriteFailure: (Error) -> Void = { error in
        let l10n = SGTasksL10n(context.sharedContext.currentPresentationData.with { $0 }.strings)
        if let notice = tasksWriteFenceNotice(error, accountPeerId: accountPeerId, l10n: l10n) {
            presentControllerImpl?(tasksNoticeToast(context: context, text: notice))
        } else {
            presentControllerImpl?(tasksErrorAlert(context: context, text: l10n.tasks_error_generic))
        }
    }

    // One full re-read of lists AND tasks, so every mutation refreshes the done/total badges.
    let reloadState: () -> Void = {
        updateState { state in
            var state = state
            state.setFolders(TodoStorage.loadFolders())
            state.tasks = TodoStorage.loadTasks()
            return state
        }
    }

    // Rename keeps the typed name when a migration step refused it (`text` says why).
    func presentRename(_ folder: TodoFolder, value: String, text: String?) {
        let l10n = SGTasksL10n(context.sharedContext.currentPresentationData.with { $0 }.strings)
        let controller = sgTaskNameAlertController(
            context: context,
            title: l10n.tasks_renameFolder_title,
            text: text ?? l10n.tasks_newFolder_prompt,
            placeholder: l10n.tasks_newFolder_placeholder,
            value: value,
            characterLimit: TasksTitleLimit.folder,
            apply: { newTitle in
                do {
                    try TodoStorage.renameFolder(id: folder.id, title: newTitle, asAccount: accountPeerId)
                } catch TodoDatabaseError.migrating {
                    DispatchQueue.main.async {
                        presentRename(folder, value: newTitle, text: l10n.tasks_migration_busy)
                    }
                    return
                } catch TodoDatabaseError.folderNotFound {
                    // Deleted meanwhile: the re-read drops it.
                } catch {
                    presentWriteFailure(error)
                }
                reloadState()
            }
        )
        presentControllerImpl?(controller)
    }

    let arguments = TasksListsArguments(openOlder: openOlder, openFolder: { folder in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let l10n = SGTasksL10n(strings)
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []

        items.append(ActionSheetButtonItem(title: l10n.tasks_action_open, color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            openList(folder)
            popImpl?()
        }))

        // The archive (R4) opens lists, nothing else.
        let isReadOnly = isArchived()
        if !isReadOnly {
            items.append(ActionSheetButtonItem(title: l10n.tasks_action_rename, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                presentRename(folder, value: folder.title, text: nil)
            }))
        }

        // SG: Tasks — audit #45: deleting a list (and, via ON DELETE CASCADE, all of its tasks) asks
        // first and names the task count. There is no undo for a list.
        if !isReadOnly {
            items.append(ActionSheetButtonItem(title: strings.Common_Delete, color: .destructive, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                let taskCount = TodoStorage.countActiveAndTotal(folderId: folder.id).total
                let alert = textAlertController(
                    context: context,
                    title: l10n.tasks_deleteFolder_title,
                    text: l10n.tasks_deleteFolder_text(taskCount: taskCount),
                    actions: [
                        TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                        TextAlertAction(type: .destructiveAction, title: strings.Common_Delete, action: {
                            do {
                                try TodoStorage.removeFolder(id: folder.id, asAccount: accountPeerId)
                                SGTasksAnalytics.emit(.listDeleted(cloud: false, tasks: taskCount), accountPeerId: accountPeerId)
                            } catch {
                                presentWriteFailure(error)
                            }
                            reloadState()
                        })
                    ]
                )
                presentControllerImpl?(alert)
            }))
        }

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    })

    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get(),
        tasksCutOverSignal(accountPeerId: accountPeerId),
        olderEntry
    ) |> deliverOnMainQueue
        |> map { presentationData, state, cutOver, olderEntry -> (ItemListControllerState, (ItemListNodeState, TasksListsArguments)) in
            let l10n = SGTasksL10n(presentationData.strings)
            // Read-only device rows (the account's copy exists) create nothing: no "+", and the
            // reason on top.
            let archiveNotice: String? = cutOver.isReadOnly ? l10n.tasks_older_readOnly : nil
            let rightButton: ItemListNavigationButton? = archiveNotice != nil ? nil : ItemListNavigationButton(content: .icon(.add), style: .regular, enabled: true, action: {
                guard !isArchived() else {
                    return
                }
                presentTasksCreateListAlert(context: context, present: { c in presentControllerImpl?(c) }, created: { _ in
                    reloadState()
                })
            })
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(l10n.tasks_lists_title),
                leftNavigationButton: nil,
                rightNavigationButton: rightButton,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: tasksListsEntries(presentationData: presentationData, state: state, archiveNotice: archiveNotice, olderEntry: olderEntry),
                style: .blocks
            )
            return (controllerState, (listState, arguments))
        }

    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { (_: Bool) in
        reloadState()
        SGTasksAnalytics.emit(.screen("tasks.lists"), accountPeerId: accountPeerId)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    popImpl = { [weak controller] in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}
