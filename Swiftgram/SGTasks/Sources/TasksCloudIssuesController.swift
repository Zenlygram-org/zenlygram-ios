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

// Zenlygram — Cloud Tasks ▸ Unsent Changes: every change saved on this device that the server has not
// confirmed, with why it is waiting and — only where the repository allows it — the explicit choices:
// send again (same identity), discard (this device only), keep the server's version, apply the change
// again on top of the current version (a new change), save a vanished own task as a new task, repair
// a refused title, or move a refused list's tasks to the Cloud Inbox. Nothing is merged or re-sent
// without one of these taps. Re-creating anything passes the same CREATE gate as a new task or list.
//
// R4 (design 30 §5.6): an edit whose fields changed on another device (`field_changed`) names them
// and offers "Keep mine" (the edit again over the new values) or "Use the other version" (discard);
// a list delete whose tasks changed (`members_changed`) asks again with the current task count. A
// queued change reads the consent hold first; while it makes the board read-only only Discard runs.

/// The owner's tasks in a cloud list now (`members_changed` asks with this count).
private func tasksCloudListTaskCount(_ cloud: SGTasksCloudState, listId: String) -> Int {
    guard let listId = SGTasksWire.UUID(listId) else {
        return 0
    }
    return cloud.tasks.filter { $0.viewerRole == .owner && $0.listId == listId }.count
}

func tasksCloudIssuesController(context: AccountContext, repository: SGTasksCloudRepository) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?

    let l10n: () -> SGTasksL10n = {
        return SGTasksL10n(context.sharedContext.currentPresentationData.with { $0 }.strings)
    }
    let perform: (() throws -> Void) -> Void = { body in
        do {
            try body()
        } catch {
            presentImpl?(tasksErrorAlert(context: context, text: tasksCloudRefusalText(error, l10n: l10n())))
        }
    }
    let currentEntry: (Int64) -> SGTasksCloudEntry? = { id in
        return repository.state.entries.first(where: { $0.id == id })
    }
    let passesCreateGate: () -> Bool = {
        return tasksCreateGate(context: context, present: { presentImpl?($0) })
    }
    /// R4: while the consent hold makes the board read-only, only Discard (this device only) runs.
    let refuseReadOnlyChange: () -> Bool = {
        guard let reason = repository.readOnlyReason(repository.state) else {
            return false
        }
        presentImpl?(tasksNoticeToast(context: context, text: l10n().tasks_cloud_readOnly(reason)))
        return true
    }

    let retry: (Int64) -> Void = { id in
        guard !refuseReadOnlyChange(), let entry = currentEntry(id) else {
            return
        }
        if entry.kind.isCreation && !passesCreateGate() {
            return
        }
        perform { try repository.retry(entryId: id) }
    }
    /// `title`: the confirming button (Discard Change, Keep Current Version, Use the other version).
    let discard: (Int64, String) -> Void = { id, title in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let l10n = l10n()
        presentImpl?(textAlertController(context: context, title: l10n.tasks_cloud_issue_discard_title, text: l10n.tasks_cloud_issue_discard_text, actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: title, action: {
                perform { try repository.discard(entryId: id) }
            })
        ]))
    }
    /// "Apply My Change Again" / "Keep mine" (a new patch over the current values) / a members-fenced
    /// list delete confirmed again with the current tasks.
    let reapply: (Int64) -> Void = { id in
        guard !refuseReadOnlyChange() else {
            return
        }
        perform { try repository.reapplyOnCurrentVersion(entryId: id) }
    }
    /// `members_changed`: the delete is confirmed again with the list's tasks as they are now (there is
    /// no Undo for a list), then sent with the current members fence.
    let confirmMembersDelete: (Int64) -> Void = { id in
        guard !refuseReadOnlyChange(), let entry = currentEntry(id) else {
            return
        }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let l10n = l10n()
        let taskCount = tasksCloudListTaskCount(repository.state, listId: entry.resourceId)
        presentImpl?(textAlertController(context: context, title: l10n.tasks_deleteFolder_title, text: l10n.tasks_cloud_members_changed(taskCount), actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: strings.Common_Delete, action: {
                reapply(id)
            })
        ]))
    }
    let recreate: (Int64) -> Void = { id in
        guard !refuseReadOnlyChange(), let entry = currentEntry(id) else {
            return
        }
        let run: () -> Void = {
            guard passesCreateGate() else {
                return
            }
            perform { let _ = try repository.recreateAsNewCopy(entryId: id) }
        }
        guard entry.status == .accountChanged else {
            run()
            return
        }
        // Decided under a previous Zenlygram account: copying it is a new creation in the account
        // linked now, so the user is told before anything is created.
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let l10n = l10n()
        presentImpl?(textAlertController(context: context, title: l10n.tasks_cloud_accountChanged_copy_title, text: l10n.tasks_cloud_accountChanged_copy_text, actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: l10n.tasks_cloud_issue_saveAsNew, action: run)
        ]))
    }
    let moveToInbox: (SGTasksWire.UUID) -> Void = { listId in
        guard !refuseReadOnlyChange() else {
            return
        }
        perform { try repository.moveBlockedImportTasksToCloudInbox(listId: listId) }
    }
    /// A refused task create/update opens the owner editor on THAT entry's own sealed content (not on
    /// newer unsent edits of the same task); the server may have refused the title, the notes or the
    /// assignee. Only an explicit Done with a real change seals a replacement. A refused list
    /// create/update only has a name to fix, and the same name is not resubmitted. Repairing a refused
    /// create seals a new creation, so it passes the create gate like any other.
    let repair: (Int64) -> Void = { id in
        guard !refuseReadOnlyChange(), let entry = currentEntry(id) else {
            return
        }
        let l10n = l10n()
        let isList = entry.kind == .listCreate || entry.kind == .listUpdate
        if entry.kind.isCreation && !passesCreateGate() {
            return
        }
        if !isList {
            guard let task = SGTasksWire.UUID(entry.resourceId).flatMap({ taskId in repository.state.tasks.first(where: { $0.id == taskId }) }), task.viewerRole == .owner, let draft = repository.entryTaskDraft(entryId: id) else {
                presentImpl?(tasksErrorAlert(context: context, text: l10n.tasks_cloud_error_gone))
                return
            }
            pushImpl?(tasksCloudTaskEditorController(context: context, repository: repository, task: task, mode: .repair(entryId: id, draft: draft)))
            return
        }
        let refusedTitle = repository.entryListTitle(entryId: id) ?? entry.displayTitle
        let limit = TasksTitleLimit.folder
        presentImpl?(sgTaskNameAlertController(
            context: context,
            title: l10n.tasks_renameFolder_title,
            text: l10n.tasks_cloud_error_title,
            placeholder: l10n.tasks_newFolder_placeholder,
            value: refusedTitle,
            characterLimit: limit,
            apply: { rawTitle in
                switch tasksValidateTitle(rawTitle, limit: limit) {
                case .empty:
                    presentImpl?(tasksErrorAlert(context: context, text: l10n.tasks_cloud_error_title))
                case .tooLong:
                    presentImpl?(tasksErrorAlert(context: context, text: l10n.tasks_error_titleTooLong(limit: limit)))
                case let .valid(title):
                    guard tasksCloudListRepairChangesTitle(title, refused: refusedTitle) else {
                        presentImpl?(tasksErrorAlert(context: context, text: l10n.tasks_cloud_repair_unchanged))
                        return
                    }
                    perform { try repository.repair(entryId: id, listTitle: title) }
                }
            }
        ))
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, tasksCloudStateSignal(repository))
    |> map { presentationData, cloud -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let l10n = SGTasksL10n(presentationData.strings)
        let form = TasksCloudForm()
        let entries = tasksCloudVisibleEntries(cloud.entries)
        if entries.isEmpty {
            form.footer("empty", l10n.tasks_cloud_issues_empty)
        }
        let now = Date()
        for entry in entries {
            let id = entry.id
            let key = String(id)
            let operation = l10n.tasks_cloud_issue_operation(tasksCloudOperationDisplayKind(entry.mutationKind), title: nil)
            let displayState = tasksCloudIssueDisplayState(entry, phase: cloud.phase, refinement: cloud.phaseRefinement, now: now)
            let state: String
            switch displayState {
            case .membersChanged:
                // The delete is asked again with the list's tasks as they are now.
                state = l10n.tasks_cloud_members_changed(tasksCloudListTaskCount(cloud, listId: entry.resourceId))
            default:
                state = l10n.tasks_cloud_issue_state(displayState)
            }
            // Short operation name above; the (isolated, wrapping) title and why it waits below.
            let content = [entry.displayTitle.map { tasksIsolatedDisplayText($0) }, state].compactMap { $0 }.joined(separator: "\n")
            form.newSection()
            form.info("entry.\(key)", label: operation, text: content)
            let allowed = entry.allowedActions
            if allowed.contains(.retry) {
                form.action("retry.\(key)", l10n.tasks_cloud_issue_retry, action: { retry(id) })
            }
            if allowed.contains(.reapply) {
                let title: String
                switch displayState {
                case .fieldsChanged:
                    title = l10n.tasks_cloud_conflict_keepMine
                case .membersChanged:
                    title = presentationData.strings.Common_Delete
                default:
                    title = l10n.tasks_cloud_issue_applyMine
                }
                if displayState == .membersChanged {
                    form.action("reapply.\(key)", title, kind: .destructive, action: { confirmMembersDelete(id) })
                } else {
                    form.action("reapply.\(key)", title, action: { reapply(id) })
                }
            }
            if allowed.contains(.recreateCopy) {
                form.action("recreate.\(key)", l10n.tasks_cloud_issue_saveAsNew, action: { recreate(id) })
            }
            if allowed.contains(.repair) {
                let isList = entry.kind == .listCreate || entry.kind == .listUpdate
                form.action("repair.\(key)", isList ? l10n.tasks_cloud_issue_repairList : l10n.tasks_cloud_issue_repairTask, action: { repair(id) })
            }
            if tasksCloudCanMoveListTasksToInbox(kind: entry.kind, status: entry.status), let listId = SGTasksWire.UUID(entry.resourceId) {
                form.action("moveToInbox.\(key)", l10n.tasks_cloud_issue_moveListTasksToInbox, action: { moveToInbox(listId) })
            }
            if allowed.contains(.discard) {
                let discardTitle: String
                switch (displayState, entry.status) {
                case (.fieldsChanged, _):
                    discardTitle = l10n.tasks_cloud_conflict_useOther
                case (_, .conflict):
                    discardTitle = l10n.tasks_cloud_issue_keepServer
                default:
                    discardTitle = l10n.tasks_cloud_issue_discard
                }
                form.action("discard.\(key)", discardTitle, kind: .destructive, action: { discard(id, discardTitle) })
            }
        }
        form.newSection()
        form.footer("footer", l10n.tasks_cloud_issues_footer)

        // A plain refresh never resolves a pause only linking can clear, nor sends before an
        // account-wide rate limit ends, nor while the consent gate holds every request (R4), so it
        // is not offered then.
        let rightButton: ItemListNavigationButton? = tasksCloudRetryResumesSync(cloud: cloud, now: Date()) ? ItemListNavigationButton(content: .text(l10n.tasks_cloud_status_retry), style: .regular, enabled: true, action: {
            repository.refresh()
        }) : nil
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(l10n.tasks_cloud_issues_title),
            leftNavigationButton: nil,
            rightNavigationButton: rightButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: form.entries, style: .blocks), ()))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { (_: Bool) in
        SGTasksAnalytics.emit(.screen("tasks.unsent_changes"), accountPeerId: repository.accountPeerId)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}
