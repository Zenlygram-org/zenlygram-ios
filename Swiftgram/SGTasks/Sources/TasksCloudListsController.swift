import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import ItemListUI
import AlertUI
import SGEntitlementUI
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — synced Tasks ▸ Lists: the owner's synced lists (create — gated, open, rename, delete
// with a confirmation and no Undo). The virtual Inbox is not a list and is not shown here. A list
// the server refused to create keeps its tasks on this device; moving them to the Inbox is an
// explicit choice offered here. R4: while the account's consent hold makes the board read-only,
// lists only open (no "+", rename, delete or move) and the reason is shown on top. wf15 §3.3: the
// one-board resolver's entry ("Eski vazifalar") leads the screen whenever device rows exist that the
// synced board does not show.

/// The single CREATE path for a cloud list (board chip and Lists "+"). Same gate as device lists:
/// a lapse shows the paywall and creates nothing. The server may still refuse; the list then stays
/// as an unsent draft with an explicit repair.
func presentTasksCloudCreateListAlert(context: AccountContext, repository: SGTasksCloudRepository, present: @escaping (ViewController) -> Void, created: @escaping (SGTasksWire.UUID) -> Void) {
    guard tasksCreateGate(context: context, present: present) else {
        return
    }
    let l10n = SGTasksL10n(context.sharedContext.currentPresentationData.with { $0 }.strings)
    present(sgTaskNameAlertController(
        context: context,
        title: l10n.tasks_newFolder_title,
        text: l10n.tasks_newFolder_prompt,
        placeholder: l10n.tasks_newFolder_placeholder,
        value: nil,
        characterLimit: TasksTitleLimit.folder,
        apply: { rawTitle in
            switch tasksValidateTitle(rawTitle, limit: TasksTitleLimit.folder) {
            case .empty:
                present(tasksErrorAlert(context: context, text: l10n.tasks_cloud_error_title))
            case .tooLong:
                present(tasksErrorAlert(context: context, text: l10n.tasks_error_titleTooLong(limit: TasksTitleLimit.folder)))
            case let .valid(title):
                guard tasksCreateGate(context: context, present: present) else {
                    return
                }
                do {
                    created(try repository.createList(title: title))
                } catch {
                    present(tasksErrorAlert(context: context, text: tasksCloudRefusalText(error, l10n: l10n)))
                }
            }
        }
    ))
}

/// - Parameters:
///   - olderEntry: the resolver's Roʻyxatlar entry (wf15 §3.3), kept current while the screen is open.
///   - openOlder: pushes the read-only screen the entry names (this screen stays underneath).
///   - unsentAssignees: wf15 §7.3 — the legacy device-row Masʼuls still unsent (`remaining`); while
///     > 0 the entry "Yuborilmagan masʼullar (n)" reopens the D4 sheet (after Keyinroq or a paced send).
///   - openUnsentAssignees: presents that sheet over this screen.
func tasksCloudListsController(context: AccountContext, repository: SGTasksCloudRepository, olderEntry: Signal<TasksOlderEntry?, NoError>, openOlder: @escaping (TasksOlderEntry) -> Void, unsentAssignees: Signal<Int, NoError> = .single(0), openUnsentAssignees: @escaping () -> Void = {}, openList: @escaping (SGTasksWire.UUID) -> Void, openUnsentChanges: @escaping () -> Void) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?

    let perform: (() throws -> Void) -> Void = { body in
        do {
            try body()
        } catch {
            let l10n = SGTasksL10n(context.sharedContext.currentPresentationData.with { $0 }.strings)
            presentImpl?(tasksErrorAlert(context: context, text: tasksCloudRefusalText(error, l10n: l10n)))
        }
    }
    /// R4: read at tap time, so a consent hold that began after the screen was drawn changes nothing.
    let readOnlyReason: () -> TasksCloudReadOnlyReason? = {
        return repository.readOnlyReason(repository.state)
    }

    let openActions: (SGTasksWire.UUID) -> Void = { listId in
        guard let list = repository.state.lists.first(where: { $0.id == listId }) else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let l10n = SGTasksL10n(strings)
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        items.append(ActionSheetButtonItem(title: l10n.tasks_action_open, color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            openList(listId)
            popImpl?()
        }))
        // Read-only (R4 consent hold): lists open, nothing else.
        let isReadOnly = readOnlyReason() != nil
        if list.problem != nil && !isReadOnly {
            items.append(ActionSheetButtonItem(title: l10n.tasks_cloud_status_review, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                openUnsentChanges()
            }))
            if tasksCloudCanMoveListTasksToInbox(problem: list.problem) {
                items.append(ActionSheetButtonItem(title: l10n.tasks_cloud_issue_moveListTasksToInbox, color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    perform { try repository.moveBlockedImportTasksToCloudInbox(listId: listId) }
                }))
            }
        }
        if isReadOnly {
            actionSheet.setItemGroups([
                ActionSheetItemGroup(items: items),
                ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })])
            ])
            presentImpl?(actionSheet)
            return
        }
        items.append(ActionSheetButtonItem(title: l10n.tasks_action_rename, color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            // The version the user is renaming: a rename made elsewhere meanwhile is refused by the
            // repository (`.changedElsewhere`), never silently overwritten.
            guard let opened = repository.state.lists.first(where: { $0.id == listId }) else {
                return
            }
            presentImpl?(sgTaskNameAlertController(
                context: context,
                title: l10n.tasks_renameFolder_title,
                text: l10n.tasks_newFolder_prompt,
                placeholder: l10n.tasks_newFolder_placeholder,
                value: opened.title,
                characterLimit: TasksTitleLimit.folder,
                apply: { rawTitle in
                    switch tasksValidateTitle(rawTitle, limit: TasksTitleLimit.folder) {
                    case .empty:
                        presentImpl?(tasksErrorAlert(context: context, text: l10n.tasks_cloud_error_title))
                    case .tooLong:
                        presentImpl?(tasksErrorAlert(context: context, text: l10n.tasks_error_titleTooLong(limit: TasksTitleLimit.folder)))
                    case let .valid(title):
                        guard title != opened.title else {
                            return
                        }
                        perform { try repository.updateList(id: listId, title: title, sortOrder: opened.sortOrder, expectedRevision: opened.revision) }
                    }
                }
            ))
        }))
        items.append(ActionSheetButtonItem(title: strings.Common_Delete, color: .destructive, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            let opened = repository.state.lists.first(where: { $0.id == listId })
            let expectedRevision = opened?.revision
            let taskCount = repository.state.tasks.filter { $0.viewerRole == .owner && $0.listId == listId }.count
            presentImpl?(textAlertController(context: context, title: l10n.tasks_deleteFolder_title, text: l10n.tasks_cloud_deleteList_text(taskCount: taskCount), actions: [
                TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: strings.Common_Delete, action: {
                    // Deletes exactly the version (and so the member set) the confirmation counted.
                    perform { try repository.deleteList(id: listId, expectedRevision: expectedRevision) }
                })
            ]))
        }))
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        presentImpl?(actionSheet)
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, tasksCloudStateSignal(repository), olderEntry, unsentAssignees)
    |> map { presentationData, cloud, olderEntry, unsentAssignees -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let l10n = SGTasksL10n(presentationData.strings)
        let form = TasksCloudForm()
        if let olderEntry {
            form.disclosure("older", tasksOlderEntryTitle(olderEntry, l10n: l10n), label: "", action: {
                openOlder(olderEntry)
            })
            form.newSection()
        }
        if unsentAssignees > 0 {
            // wf15 §7.3: the sheet's way back while device-row candidates remain.
            form.disclosure("unsentAssignees", l10n.tasks_legacySheet_listsEntry(unsentAssignees), label: "", action: openUnsentAssignees)
            form.newSection()
        }
        let readOnly = repository.readOnlyReason(cloud)
        if let readOnly {
            form.footer("readOnly", l10n.tasks_cloud_readOnly(readOnly))
            form.newSection()
        }
        if cloud.lists.isEmpty {
            form.footer("empty", l10n.tasks_folders_empty)
        } else {
            form.header("header", l10n.tasks_section_folders_headerWithCount(cloud.lists.count))
            for list in cloud.lists {
                let listTasks = cloud.tasks.filter { $0.viewerRole == .owner && $0.listId == list.id }
                let done = listTasks.filter { $0.isCompleted }.count
                let label: String
                if list.problem != nil {
                    label = l10n.tasks_cloud_row_needsAttention
                } else if list.isPending {
                    label = l10n.tasks_cloud_row_notSent
                } else {
                    label = listTasks.isEmpty ? l10n.tasks_cloud_taskCount(0) : l10n.tasks_cloud_listProgress(done: done, total: listTasks.count)
                }
                let listId = list.id
                form.disclosure("list.\(list.id.rawValue)", tasksIsolatedDisplayText(list.title), label: label, action: {
                    openActions(listId)
                })
            }
        }
        form.footer("footer", l10n.tasks_cloud_lists_footer)

        let rightButton: ItemListNavigationButton? = readOnly != nil ? nil : ItemListNavigationButton(content: .icon(.add), style: .regular, enabled: true, action: {
            guard readOnlyReason() == nil else {
                return
            }
            presentTasksCloudCreateListAlert(context: context, repository: repository, present: { presentImpl?($0) }, created: { _ in })
        })
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(l10n.tasks_lists_title),
            leftNavigationButton: nil,
            rightNavigationButton: rightButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: form.entries, style: .blocks), ()))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { (_: Bool) in
        SGTasksAnalytics.emit(.screen("tasks.lists"), accountPeerId: repository.accountPeerId)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    popImpl = { [weak controller] in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}
