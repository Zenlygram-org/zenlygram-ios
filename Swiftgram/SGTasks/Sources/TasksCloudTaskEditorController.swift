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
import UndoUI
import SGEntitlementUI
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — Cloud Tasks: one cloud task, opened from the cloud board.
//
// Who may do what is `TasksCloudTaskPermissions` (the UI mirror of the repository's checks, which
// stay authoritative): the screen draws from it and every action re-reads it on the CURRENT task when
// invoked, so a row drawn before access changed can never act; a refusal is explained, never retried.
// A "Who Can Do What" section states those rights in words (no switches: there are no other roles).
//
// Owner: title, notes, list, deadline, priority, completion, the Masʼul section (wf15 §4: picking a
// contact IS the `invitation.request`; the row reads "Masʼul: Ism · holat" with its footer and one
// action — Masʼulni almashtirish / olib tashlash, Qayta yuborish, Yuborish; the replace alert only
// when someone loses access; assignment applies at once, independent of Save), and delete (handed
// back to the board, which holds it with Undo). The owner-only annotation is never written here
// (§4.1): a legacy one is read as the display fallback and as the per-task "Hali yuborilmagan"
// candidate. Editing is never gated by sync state: unsent or refused changes keep the owner's
// content and completion rights offline.
//
// Assignee (wf15 §5.2, "Topshirilgan vazifa"): who assigned it ("Topshirdi: Ism" — the viewer's own
// contact name, else the numeric id; never a sender-chosen name), the rights line, the content
// read-only, completion, a confirmed "Vazifadan chiqish" and "Yuboruvchini bloklash" (the accepted
// epoch's invitation; accepted tasks stay until left), all bound to the accepted invitation. A
// shared task without an accepted invitation offers nothing (fail closed). The izoh section is wire
// 5 only (WP-I8). A PROVISIONAL row (an automatic accept on its way) opens
// `tasksCloudProvisionalTaskController`: the invitation preview, no action.
//
// A remote change while the editor is open is never silently overwritten: Save asks first. Unsaved
// owner edits outlive the task itself: if it vanishes (or is no longer the user's to edit) the edits
// stay on screen and Done offers to keep them as a new task or discard them.
//
// Repair mode (from Unsent Changes, for a task create/update the server refused as invalid): the
// same owner content controls on the user's unsent content, nothing else. Only an explicit Done with
// an actual change hands the corrected draft to `repair(entryId:taskDraft:)`, which seals it as a new
// change; an unchanged draft is never resubmitted. A vanished entry or a moved revision is refused by
// the repository and reported, never merged.
//
// R4 (design 30 §5.6): while the account's consent hold makes Cloud read-only, the task opens
// read-only (its content and why, no action); edits typed before the hold began stay on screen, but
// nothing is queued until it ends.

struct TasksCloudEditorHostActions {
    /// Owner delete: the board holds it and shows the Undo toast (the editor has already closed).
    let requestDelete: (SGTasksWire.UUID) -> Void
    let openUnsentChanges: () -> Void
    /// wf15 §4: the board's assignment coordinator (explainer, picker, names, legacy facts). nil for
    /// a host without one (the read-only Sinxronlangan nusxa): no Masʼul section.
    var assignment: TasksAssignmentCoordinator? = nil
}

/// A list item with an accessibility identifier on its node (the ItemList items carry none of their
/// own and cannot be subclassed from here): the Masʼul row `sgtasks.task.<id>.assignee` and its
/// action `sgtasks.task.<id>.assignee.resend` (wf15 §4.3), the legacy assignee sheet's body and
/// buttons (`sgtasks.legacy.*`, §7). Everything else is the wrapped item's.
final class TasksCloudIdentifiedItem<Item: ListViewItem & ItemListItem>: ListViewItem, ItemListItem {
    private let item: Item
    private let identifier: String

    init(_ item: Item, identifier: String) {
        self.item = item
        self.identifier = identifier
    }

    var sectionId: ItemListSectionId {
        return self.item.sectionId
    }

    var selectable: Bool {
        return self.item.selectable
    }

    func selected(listView: ListView) {
        self.item.selected(listView: listView)
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        let identifier = self.identifier
        self.item.nodeConfiguredForParams(async: async, params: params, synchronousLoads: synchronousLoads, previousItem: previousItem, nextItem: nextItem, completion: { node, apply in
            node.accessibilityIdentifier = identifier
            completion(node, apply)
        })
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        let identifier = self.identifier
        self.item.updateNode(async: async, node: {
            let node = node()
            node.accessibilityIdentifier = identifier
            return node
        }, params: params, previousItem: previousItem, nextItem: nextItem, animation: animation, completion: completion)
    }
}

enum TasksCloudEditorMode {
    /// Opened from the board: full owner editor or recipient view.
    case edit(TasksCloudEditorHostActions)
    /// Correcting a refused unsent task change (owner content only), starting from that entry's own
    /// sealed content (`SGTasksCloudRepository.entryTaskDraft`), not from newer unsent edits.
    case repair(entryId: Int64, draft: SGTasksCloudTaskDraft)
}

/// The packed native peer id for a raw cloud-user Telegram id (the inverse of the transport's
/// `TelegramId(cloudUserPeerId:)`), so an existing assignee round-trips through a draft unchanged.
func tasksCloudPackedUserPeerId(_ telegramId: SGTasksWire.TelegramId) -> Int64 {
    return EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(telegramId.int64Value)).toInt64()
}

/// A contact's name from the user's own Telegram data (never a name supplied by another user).
func tasksCloudLocalUserName(_ peer: EnginePeer?, presentationData: PresentationData) -> String? {
    guard case let .user(user)? = peer else {
        return nil
    }
    let names = [user.firstName, user.lastName].compactMap { name -> String? in
        guard let name, !name.isEmpty else {
            return nil
        }
        return name
    }
    guard !names.isEmpty else {
        return nil
    }
    if case .lastFirst = presentationData.nameDisplayOrder {
        return names.reversed().joined(separator: " ")
    }
    return names.joined(separator: " ")
}

/// wf15 §5.6: the name shown for the person who assigned a task to the viewer — the viewer's own
/// contact name (isolated: external text), else the numeric "Telegram foydalanuvchisi N".
func tasksCloudSenderDisplayName(_ ownerTgId: SGTasksWire.TelegramId?, contactName: String?, l10n: SGTasksL10n) -> String {
    if let contactName = contactName?.trimmingCharacters(in: .whitespacesAndNewlines), !contactName.isEmpty {
        return tasksIsolatedDisplayText(contactName)
    }
    return l10n.tasks_cloud_telegramUser(ownerTgId?.rawValue ?? "")
}

func tasksCloudDraft(from task: SGTasksCloudTask) -> SGTasksCloudTaskDraft {
    return SGTasksCloudTaskDraft(
        listId: task.listId,
        title: task.title,
        description: task.description,
        dueAt: task.dueAt,
        priority: task.priority,
        annotation: task.annotation.map { SGTasksCloudAnnotationDraft(cloudUserPeerId: tasksCloudPackedUserPeerId($0.telegramUserId), displayName: $0.displayName) },
        sortOrder: task.sortOrder
    )
}

/// Confirmed Leave for a task shared with the user: no hold and no Undo.
func presentTasksCloudLeaveConfirmation(context: AccountContext, present: @escaping (ViewController) -> Void, confirmed: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let l10n = SGTasksL10n(presentationData.strings)
    present(textAlertController(context: context, title: l10n.tasks_cloud_leave_title, text: l10n.tasks_cloud_leave_text, actions: [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .destructiveAction, title: l10n.tasks_cloud_editor_leave, action: confirmed)
    ]))
}

private struct TasksCloudEditorState: Equatable {
    var draft: SGTasksCloudTaskDraft
    let original: SGTasksCloudTaskDraft
    /// The server revision the draft was based on; a different one at Save means a remote change.
    let openedRevision: SGTasksWire.Revision?
    /// Latched once the draft differed from the original, so a recovered draft whose task is gone
    /// does not collapse mid-typing when it is edited back to the original.
    var hasEverChanged = false

    /// Compared after the normalization Save applies (trimmed title, blank notes = none), so a
    /// whitespace-only edit is not a change and never queues a no-op or re-seals refused content.
    var hasChanges: Bool {
        return tasksCloudDraftHasChanges(self.draft, from: self.original)
    }
}

func tasksCloudTaskEditorController(context: AccountContext, repository: SGTasksCloudRepository, task initialTask: SGTasksCloudTask, mode: TasksCloudEditorMode) -> ViewController {
    let repairEntryId: Int64?
    let startDraft: SGTasksCloudTaskDraft
    if case let .repair(entryId, draft) = mode {
        repairEntryId = entryId
        startDraft = draft
    } else {
        repairEntryId = nil
        startDraft = tasksCloudDraft(from: initialTask)
    }
    let taskId = initialTask.id
    /// Unsaved edits made as the owner are kept even if the task later disappears.
    let openedAsOwner = initialTask.viewerRole == .owner
    let initialState = TasksCloudEditorState(draft: startDraft, original: startDraft, openedRevision: initialTask.revision)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((inout TasksCloudEditorState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            if state.hasChanges {
                state.hasEverChanged = true
            }
            return state
        })
    }

    var presentImpl: ((ViewController) -> Void)?
    var presentToastImpl: ((UndoOverlayController) -> Void)?
    var dismissImpl: (() -> Void)?
    var navigationControllerImpl: (() -> NavigationController?)?
    var deadlineSourceView: (() -> UIView?)?
    var isClosing = false
    /// At most one discard confirmation: Cancel, swipe-back and the VoiceOver escape can all ask.
    var isConfirmingDiscard = false
    /// wf15 §4: the board's assignment coordinator; nil in repair mode and for a host without one.
    let assignment: TasksAssignmentCoordinator?
    if case let .edit(host) = mode {
        assignment = host.assignment
    } else {
        assignment = nil
    }

    let currentTask: () -> SGTasksCloudTask? = {
        return repository.state.tasks.first(where: { $0.id == taskId })
    }
    let presentationData: () -> PresentationData = {
        return context.sharedContext.currentPresentationData.with { $0 }
    }
    let l10n: () -> SGTasksL10n = {
        return SGTasksL10n(presentationData().strings)
    }
    let presentError: (String) -> Void = { text in
        presentImpl?(tasksErrorAlert(context: context, text: text))
    }
    let perform: (() throws -> Void) -> Bool = { body in
        // R4: nothing is queued while the consent hold makes Cloud read-only.
        if let reason = repository.readOnlyReason(repository.state) {
            presentError(l10n().tasks_cloud_readOnly(reason))
            return false
        }
        do {
            try body()
            return true
        } catch {
            presentError(tasksCloudRefusalText(error, l10n: l10n()))
            return false
        }
    }
    /// The current task if the user still has `permission` on it, else nil after explaining why
    /// (gone, or `refusal`). Never retries and never starts another change.
    let permittedTask: (KeyPath<TasksCloudTaskPermissions, Bool>, String) -> SGTasksCloudTask? = { permission, refusal in
        guard let task = currentTask() else {
            presentError(l10n().tasks_cloud_error_gone)
            return nil
        }
        guard TasksCloudTaskPermissions(task: task)[keyPath: permission] else {
            presentError(refusal)
            return nil
        }
        return task
    }
    let close: () -> Void = {
        guard !isClosing else {
            return
        }
        isClosing = true
        dismissImpl?()
    }
    let confirmDiscard: () -> Void = {
        guard !isClosing, !isConfirmingDiscard else {
            return
        }
        isConfirmingDiscard = true
        let l10n = l10n()
        presentImpl?(textAlertController(context: context, title: l10n.tasks_discardChanges_title, text: l10n.tasks_discardChanges_text, actions: [
            TextAlertAction(type: .genericAction, title: l10n.tasks_discardChanges_keepEditing, action: {
                isConfirmingDiscard = false
            }),
            TextAlertAction(type: .destructiveAction, title: l10n.tasks_discardChanges_discard, action: {
                isConfirmingDiscard = false
                close()
            })
        ], dismissOnOutsideTap: false))
    }

    let commitDraft: (SGTasksCloudTaskDraft) -> Void = { draft in
        let committed: Bool
        if let repairEntryId {
            committed = perform({ try repository.repair(entryId: repairEntryId, taskDraft: draft) })
        } else {
            committed = perform({ try repository.updateTask(id: taskId, draft: draft) })
        }
        if committed {
            close()
        }
    }

    let save: () -> Void = {
        guard !isClosing else {
            return
        }
        let state = stateValue.with { $0 }
        guard state.hasChanges else {
            if repairEntryId != nil {
                // Resending the same refused content would only be refused again.
                presentError(l10n().tasks_cloud_repair_unchanged)
            } else {
                close()
            }
            return
        }
        let l10n = l10n()
        var draft = state.draft
        switch tasksValidateTitle(draft.title, limit: TasksTitleLimit.task) {
        case .empty:
            presentError(l10n.tasks_cloud_error_title)
            return
        case .tooLong:
            presentError(l10n.tasks_error_titleTooLong(limit: TasksTitleLimit.task))
            return
        case let .valid(title):
            draft.title = title
        }
        switch tasksCloudValidateDescription(draft.description ?? "") {
        case .tooLong:
            presentError(l10n.tasks_cloud_error_description)
            return
        case let .valid(description):
            draft.description = description
        }
        // Deleted, no longer accessible, or no longer the user's to edit: the edits are kept only by
        // an explicit choice — a NEW task (a creation, so it passes the create gate) or discard.
        guard let current = currentTask(), TasksCloudTaskPermissions(task: current).canEditContent else {
            let strings = presentationData().strings
            presentImpl?(textAlertController(context: context, title: l10n.tasks_cloud_editor_goneWithChanges_title, text: l10n.tasks_cloud_editor_goneWithChanges_text, actions: [
                TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: l10n.tasks_discardChanges_discard, action: close),
                TextAlertAction(type: .defaultAction, title: l10n.tasks_cloud_issue_saveAsNew, action: {
                    guard tasksCreateGate(context: context, present: { presentImpl?($0) }) else {
                        return
                    }
                    var copy = draft
                    if let listId = copy.listId, !repository.state.lists.contains(where: { $0.id == listId }) {
                        copy.listId = nil
                    }
                    copy.sortOrder = nil
                    if perform({ let _ = try repository.createTask(copy) }) {
                        close()
                    }
                })
            ], actionLayout: .vertical, dismissOnOutsideTap: false))
            return
        }
        // Changed elsewhere since the editor opened: the user decides, nothing is merged. (A repair
        // replaces the user's own unsent change; the repository refuses it if that entry moved on.)
        if repairEntryId == nil && current.revision != state.openedRevision && tasksCloudDraftChangedElsewhere(tasksCloudDraft(from: current), opened: state.original) {
            let strings = presentationData().strings
            presentImpl?(textAlertController(context: context, title: l10n.tasks_cloud_conflict_title, text: l10n.tasks_cloud_conflict_text, actions: [
                TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                TextAlertAction(type: .genericAction, title: l10n.tasks_cloud_issue_keepServer, action: close),
                TextAlertAction(type: .defaultAction, title: l10n.tasks_cloud_issue_applyMine, action: {
                    commitDraft(draft)
                })
            ], actionLayout: .vertical, dismissOnOutsideTap: false))
            return
        }
        commitDraft(draft)
    }

    let requestCancel: () -> Void = {
        guard !isClosing else {
            return
        }
        if stateValue.with({ $0.hasChanges }) {
            confirmDiscard()
        } else {
            close()
        }
    }

    let pickList: () -> Void = {
        let presentationData = presentationData()
        let l10n = SGTasksL10n(presentationData.strings)
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        let choose: (SGTasksWire.UUID?) -> Void = { listId in
            updateState { state in
                if state.draft.listId != listId {
                    state.draft.listId = listId
                    // A moved task goes to the end of its new list.
                    state.draft.sortOrder = listId == state.original.listId ? state.original.sortOrder : nil
                }
            }
        }
        // The current choice is marked (a checkmark, not color), so it is visible and spoken.
        let currentListId = stateValue.with { $0.draft.listId }
        items.append(ActionSheetCheckboxItem(title: l10n.tasks_cloud_inbox_title, label: "", value: currentListId == nil, action: { [weak actionSheet] _ in
            actionSheet?.dismissAnimated()
            choose(nil)
        }))
        for list in repository.state.lists {
            let listId = list.id
            items.append(ActionSheetCheckboxItem(title: tasksIsolatedDisplayText(list.title), label: "", value: currentListId == listId, action: { [weak actionSheet] _ in
                actionSheet?.dismissAnimated()
                choose(listId)
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        presentImpl?(actionSheet)
    }

    let pickPriority: () -> Void = {
        let presentationData = presentationData()
        let l10n = SGTasksL10n(presentationData.strings)
        let actionSheet = ActionSheetController(presentationData: presentationData)
        let currentPriority = stateValue.with { $0.draft.priority }
        let items: [ActionSheetItem] = (0...4).map { value in
            ActionSheetCheckboxItem(title: l10n.tasks_cloud_priority(value), label: "", value: currentPriority == value, action: { [weak actionSheet] _ in
                actionSheet?.dismissAnimated()
                updateState { $0.draft.priority = value }
            })
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        presentImpl?(actionSheet)
    }

    let pickDeadline: () -> Void = {
        guard let view = deadlineSourceView?() else {
            return
        }
        view.endEditing(true)
        presentTasksDeadlinePicker(from: view, currentDueAt: stateValue.with { $0.draft.dueAt }, presentationData: presentationData(), commit: { result in
            switch result {
            case let .set(dueAt):
                updateState { $0.draft.dueAt = dueAt }
            case .clear:
                updateState { $0.draft.dueAt = nil }
            }
        })
    }

    /// The Masʼul row (wf15 §4.2 items 1–5): explainer once → the contact picker → the pick-time
    /// check; then `assignTask` at once — after the one confirmation when someone currently has the
    /// task (a live epoch), directly otherwise. Independent of Save.
    let pickAssignee: () -> Void = {
        let l10n = l10n()
        guard let assignment, let task = permittedTask(\.canManageSharing, l10n.tasks_cloud_error_notOwner) else {
            return
        }
        if task.isCompleted {
            presentError(l10n.tasks_assign_footer_completedTask)
            return
        }
        guard let navigationController = navigationControllerImpl?() else {
            return
        }
        deadlineSourceView?()?.endEditing(true)
        assignment.pick(navigationController: navigationController, present: { presentImpl?($0) }, presentToast: { presentToastImpl?($0) }, closed: {}, completion: { recipient in
            guard let current = currentTask(), TasksCloudTaskPermissions(task: current).canManageSharing else {
                presentError(l10n.tasks_cloud_error_gone)
                return
            }
            let assign: () -> Void = {
                let _ = perform { try repository.assignTask(id: taskId, recipientCloudUserPeerId: recipient.peerId) }
            }
            let display = assignment.display(for: current, cloud: repository.state)
            guard let display, display.state.someoneLosesAccess else {
                assign()
                return
            }
            // The only assign confirmation: the current assignee loses the task (§4.2 item 5).
            let name = assignment.cachedDisplayName(for: display)
            presentImpl?(textAlertController(context: context, title: l10n.tasks_assign_replace_title, text: l10n.tasks_assign_replace_text(name), actions: [
                TextAlertAction(type: .genericAction, title: presentationData().strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultAction, title: l10n.tasks_assign_replace_confirm, action: assign)
            ], dismissOnOutsideTap: false))
        })
    }

    /// Masʼulni olib tashlash (§4.2 item 6): a live epoch is revoked after the one confirmation
    /// (the assignee loses the task); a legacy annotation-only entry is cleared without one (nobody
    /// has access to lose).
    let removeAssignee: () -> Void = {
        let l10n = l10n()
        guard let assignment, let task = permittedTask(\.canManageSharing, l10n.tasks_cloud_error_notOwner), let display = assignment.display(for: task, cloud: repository.state) else {
            return
        }
        let remove: () -> Void = {
            guard let current = currentTask(), TasksCloudTaskPermissions(task: current).canManageSharing else {
                presentError(l10n.tasks_cloud_error_gone)
                return
            }
            if let live = current.assignment, live.state == .pending || live.state == .accepted {
                let _ = perform { try repository.revokeInvitation(taskId: taskId, expectedInvitationId: live.invitationId) }
            } else if current.annotation != nil {
                let _ = perform { try repository.removeLegacyAnnotation(taskId: taskId) }
            } else {
                presentError(l10n.tasks_cloud_error_changedElsewhere)
            }
        }
        guard display.state.someoneLosesAccess else {
            remove()
            return
        }
        let name = assignment.cachedDisplayName(for: display)
        presentImpl?(textAlertController(context: context, title: l10n.tasks_assign_remove_title, text: l10n.tasks_assign_replace_text(name), actions: [
            TextAlertAction(type: .genericAction, title: presentationData().strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: l10n.tasks_assign_remove_confirm, action: remove)
        ]))
    }

    /// Qayta yuborish (§4.2 item 7): the same recipient, a new epoch; the pacer applies.
    let resendAssignment: () -> Void = {
        guard permittedTask(\.canManageSharing, l10n().tasks_cloud_error_notOwner) != nil else {
            return
        }
        // Nothing is queued before the link (S4): the needs-sync sheet or the wait toast instead.
        guard assignment?.allowsAssigning(present: { presentImpl?($0) }, presentToast: { presentToastImpl?($0) }) ?? true else {
            return
        }
        let _ = perform { try repository.resendAssignment(taskId: taskId) }
    }

    /// Yuborish on a legacy candidate (§4.2 item 7): the cloud task id goes into the durable sent set
    /// first, then the `invitation.request` to the candidate's Telegram id; a refusal that queued
    /// nothing takes the id back out.
    let sendLegacyAssignee: () -> Void = {
        let l10n = l10n()
        guard let assignment, let task = permittedTask(\.canManageSharing, l10n.tasks_cloud_error_notOwner) else {
            return
        }
        guard let display = assignment.display(for: task, cloud: repository.state), display.state == .notSent else {
            presentError(l10n.tasks_cloud_error_changedElsewhere)
            return
        }
        guard assignment.allowsAssigning(present: { presentImpl?($0) }, presentToast: { presentToastImpl?($0) }) else {
            return
        }
        assignment.markLegacySent(taskId)
        if !perform({ try repository.assignTask(id: taskId, recipient: display.recipient) }) {
            assignment.unmarkLegacySent(taskId)
        }
    }

    /// The target state is the one the row showed: a change arriving meanwhile is not flipped back
    /// (the repository treats repeating the current state as a no-op). `displayed` is the permission
    /// the row was drawn under (role and, for a recipient, accepted invitation epoch); a row from
    /// another role or epoch never acts. The repository still fences the actual send.
    let setCompleted: (Bool, TasksCloudTaskPermissions) -> Void = { isCompleted, displayed in
        guard let task = permittedTask(\.canSetCompletion, l10n().tasks_cloud_error_notAssignee) else {
            return
        }
        guard TasksCloudTaskPermissions(task: task) == displayed else {
            presentError(l10n().tasks_cloud_error_changedElsewhere)
            return
        }
        let _ = perform { try repository.setTaskCompleted(id: taskId, isCompleted: isCompleted) }
    }

    let delete: () -> Void = {
        guard case let .edit(host) = mode, permittedTask(\.canDelete, l10n().tasks_cloud_error_notOwner) != nil else {
            return
        }
        close()
        host.requestDelete(taskId)
    }

    let openUnsentChanges: () -> Void = {
        if case let .edit(host) = mode {
            host.openUnsentChanges()
        }
    }

    /// `displayed` is the permission the Leave row was drawn under; a row from another role or
    /// invitation epoch never acts, and the confirmation is bound to that exact epoch (the repository
    /// refuses any other).
    let leave: (TasksCloudTaskPermissions) -> Void = { displayed in
        guard let task = permittedTask(\.canLeave, l10n().tasks_cloud_error_notAssignee) else {
            return
        }
        guard TasksCloudTaskPermissions(task: task) == displayed, let invitationId = displayed.recipientInvitationId else {
            presentError(l10n().tasks_cloud_error_changedElsewhere)
            return
        }
        presentTasksCloudLeaveConfirmation(context: context, present: { presentImpl?($0) }, confirmed: {
            if perform({ try repository.leaveTask(id: taskId, expectedInvitationId: invitationId) }) {
                close()
            }
        })
    }

    /// Yuboruvchini bloklash (wf15 §5.2): the sender of the accepted epoch, after the confirmation
    /// (which says accepted tasks stay until left). Bound to the rights the row was drawn under,
    /// like Leave; the repository refuses it again if an answer or block got queued meanwhile.
    let blockSender: (TasksCloudTaskPermissions, String) -> Void = { displayed, senderName in
        guard let task = permittedTask(\.canLeave, l10n().tasks_cloud_error_notAssignee) else {
            return
        }
        guard TasksCloudTaskPermissions(task: task) == displayed, let invitationId = displayed.recipientInvitationId else {
            presentError(l10n().tasks_cloud_error_changedElsewhere)
            return
        }
        let l10n = l10n()
        presentImpl?(textAlertController(context: context, title: l10n.tasks_cloud_invitation_block, text: l10n.tasks_cloud_invitation_blockConfirm_text(senderName), actions: [
            TextAlertAction(type: .genericAction, title: presentationData().strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: l10n.tasks_cloud_invitation_block, action: {
                let _ = perform { try repository.blockSender(invitationId: invitationId) }
            })
        ]))
    }

    // The other party's contact name from the viewer's own contacts (wf15 §5.6): for the owner the
    // current Masʼul (the device-row and annotation fallbacks and the numeric id are applied where
    // the line is built); for the assignee the person who assigned the task ("Topshirdi: Ism").
    let counterpartName: Signal<String?, NoError> = tasksCloudStateSignal(repository)
    |> map { state -> SGTasksWire.TelegramId? in
        guard let assignment, let task = state.tasks.first(where: { $0.id == taskId }) else {
            return nil
        }
        if task.viewerRole == .assignee {
            return task.ownerTgId
        }
        return assignment.display(for: task, cloud: state)?.recipient
    }
    |> distinctUntilChanged
    |> mapToSignal { recipient -> Signal<String?, NoError> in
        guard let assignment, let recipient else {
            return .single(nil)
        }
        return assignment.names.names(for: [recipient])
        |> map { names -> String? in
            return names[recipient]
        }
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get(), tasksCloudStateSignal(repository), counterpartName)
    |> map { presentationData, editorState, cloudState, counterpartName -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let l10n = SGTasksL10n(presentationData.strings)
        let task = cloudState.tasks.first(where: { $0.id == taskId })
        let form = TasksCloudForm()
        let permissions = TasksCloudTaskPermissions(task: task)
        // The Masʼul row's facts (wf15 §4.3, §5.6), from the same coordinator the board reads.
        var assignee: TasksCloudEditorAssignee?
        if let assignment, let task, let display = assignment.display(for: task, cloud: cloudState) {
            assignee = TasksCloudEditorAssignee(display: display, name: assignment.displayName(for: display, contactName: counterpartName), serverSupportsNote: assignment.serverSupportsNote)
        }
        // R4: a consent hold shows the task read-only, unless the user already typed edits (they stay
        // on screen; Done then says why nothing can be saved yet).
        let readOnly = repository.readOnlyReason(cloudState)
        let showsReadOnly = readOnly != nil && !editorState.hasEverChanged
        // Unsaved owner edits stay on screen (with Cancel/Done) even when the task vanished or is no
        // longer the user's to edit, so Done can offer "Save as new task" instead of losing them.
        let keepsOwnerDraft = !showsReadOnly && (permissions.canEditContent || (openedAsOwner && editorState.hasEverChanged))
        let ownerActions = TasksCloudOwnerEditorActions(
            titleChanged: { text in updateState { $0.draft.title = text } },
            notesChanged: { text in updateState { $0.draft.description = text.isEmpty ? nil : text } },
            pickList: pickList,
            pickDeadline: pickDeadline,
            clearDeadline: { updateState { $0.draft.dueAt = nil } },
            pickPriority: pickPriority,
            pickAssignee: pickAssignee,
            removeAssignee: removeAssignee,
            resendAssignment: resendAssignment,
            sendLegacyAssignee: sendLegacyAssignee,
            setCompleted: setCompleted,
            delete: delete,
            openUnsentChanges: openUnsentChanges
        )
        if let readOnly, showsReadOnly {
            form.footer("readOnly", l10n.tasks_cloud_readOnly(readOnly))
            if let task {
                tasksCloudReadOnlyEntries(form: form, task: task, cloud: cloudState, presentationData: presentationData, l10n: l10n)
            } else {
                form.footer("gone", l10n.tasks_cloud_error_gone)
            }
        } else if let task, permissions.canEditContent {
            tasksCloudOwnerEditorEntries(form: form, task: task, state: editorState, cloud: cloudState, isRepair: repairEntryId != nil, assignee: assignee, showsAssigneeSection: assignment != nil, presentationData: presentationData, l10n: l10n, actions: ownerActions)
        } else if keepsOwnerDraft {
            form.footer("goneDraft", l10n.tasks_cloud_editor_goneDraft_footer)
            tasksCloudOwnerContentEntries(form: form, draft: editorState.draft, cloud: cloudState, presentationData: presentationData, l10n: l10n, actions: ownerActions)
        } else if let task, task.viewerRole == .assignee {
            let senderName = tasksCloudSenderDisplayName(task.ownerTgId, contactName: counterpartName, l10n: l10n)
            tasksCloudRecipientEntries(form: form, task: task, permissions: permissions, senderName: senderName, serverSupportsNote: assignment?.serverSupportsNote ?? repository.isServerWire5Now, presentationData: presentationData, l10n: l10n, setCompleted: setCompleted, leave: leave, blockSender: blockSender)
        } else {
            form.footer("gone", l10n.tasks_cloud_error_gone)
        }
        // wf15 §5.2: a task assigned to the user is titled as such; the owner's editor keeps its title.
        let isAssignedTask = task?.viewerRole == .assignee && !keepsOwnerDraft

        let leftButton: ItemListNavigationButton?
        let rightButton: ItemListNavigationButton
        if keepsOwnerDraft {
            leftButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Cancel), style: .regular, enabled: true, action: requestCancel)
            rightButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Done), style: .bold, enabled: editorState.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, action: save)
        } else {
            leftButton = nil
            rightButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Done), style: .bold, enabled: true, action: close)
        }
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(repairEntryId != nil ? l10n.tasks_cloud_issue_repairTitle : (isAssignedTask ? l10n.tasks_assigned_editorTitle : l10n.tasks_cloud_editor_editTitle)),
            leftNavigationButton: leftButton,
            rightNavigationButton: rightButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: form.entries, style: .blocks)
        return (controllerState, (listState, ()))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .flatModal
    controller.didAppear = { (_: Bool) in
        SGTasksAnalytics.emit(.screen("tasks.task_editor"), accountPeerId: repository.accountPeerId)
    }
    controller.attemptNavigation = { _ in
        if isClosing || !stateValue.with({ $0.hasChanges }) {
            return true
        }
        confirmDiscard()
        return false
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    presentToastImpl = { [weak controller] toast in
        controller?.present(toast, in: .current)
    }
    dismissImpl = { [weak controller] in
        controller?.view.endEditing(true)
        controller?.dismiss()
    }
    deadlineSourceView = { [weak controller] in
        return controller?.view
    }
    navigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    return controller
}

private struct TasksCloudOwnerEditorActions {
    let titleChanged: (String) -> Void
    let notesChanged: (String) -> Void
    let pickList: () -> Void
    let pickDeadline: () -> Void
    let clearDeadline: () -> Void
    let pickPriority: () -> Void
    let pickAssignee: () -> Void
    let removeAssignee: () -> Void
    let resendAssignment: () -> Void
    let sendLegacyAssignee: () -> Void
    let setCompleted: (Bool, TasksCloudTaskPermissions) -> Void
    let delete: () -> Void
    let openUnsentChanges: () -> Void
}

/// The Masʼul row's facts for one render: the §4.3 row, the name per §5.6 and the wire-5 fact.
private struct TasksCloudEditorAssignee {
    let display: TasksAssigneeDisplay
    let name: String
    let serverSupportsNote: Bool
}

private func tasksCloudSyncStatusEntries(form: TasksCloudForm, task: SGTasksCloudTask, l10n: SGTasksL10n, openUnsentChanges: @escaping () -> Void) {
    let status: String?
    switch task.problem {
    case .none, .some(.waitingForDependency):
        status = task.isPending ? l10n.tasks_cloud_syncConfirmationPending : nil
    case .some:
        status = l10n.tasks_cloud_row_needsAttention
    }
    guard let status else {
        return
    }
    form.newSection()
    form.disclosure("syncStatus", status, label: l10n.tasks_cloud_status_review, action: openUnsentChanges)
}

/// The owner's editable content (title, notes, list, deadline, priority, assignee), shared by the
/// normal and repair editor and by the recovery view of unsaved edits whose task is gone.
private func tasksCloudOwnerContentEntries(form: TasksCloudForm, draft: SGTasksCloudTaskDraft, cloud: SGTasksCloudState, presentationData: PresentationData, l10n: SGTasksL10n, actions: TasksCloudOwnerEditorActions) {
    let none = l10n.tasks_metadata_none
    let use24HourClock = presentationData.dateTimeFormat.timeFormat == .military

    // Each text field gets a visible section label: ItemList input fields expose their placeholder
    // only as a hint, so a filled field would otherwise have no spoken name.
    form.newSection()
    form.header("titleHeader", l10n.tasks_cloud_editor_titlePlaceholder)
    form.add("title", key: draft.title) { itemPresentationData, section in
        ItemListSingleLineInputItem(presentationData: itemPresentationData, title: NSAttributedString(), text: draft.title, placeholder: l10n.tasks_cloud_editor_titlePlaceholder, sectionId: section, textUpdated: actions.titleChanged, action: {})
    }

    form.newSection()
    form.header("notesHeader", l10n.tasks_cloud_editor_notesPlaceholder)
    form.add("notes", key: draft.description ?? "") { itemPresentationData, section in
        ItemListMultilineInputItem(presentationData: itemPresentationData, text: draft.description ?? "", placeholder: l10n.tasks_cloud_editor_notesPlaceholder, maxLength: nil, sectionId: section, style: .blocks, textUpdated: actions.notesChanged)
    }

    form.newSection()
    let listTitle = draft.listId.flatMap { listId in cloud.lists.first(where: { $0.id == listId })?.title }.map { tasksIsolatedDisplayText($0) } ?? l10n.tasks_cloud_inbox_title
    form.disclosure("list", l10n.tasks_cloud_editor_list, label: listTitle, action: actions.pickList)
    form.disclosure("deadline", l10n.tasks_deadline_title, label: draft.dueAt.map { l10n.tasks_deadline_text($0, use24HourClock: use24HourClock) } ?? none, action: actions.pickDeadline)
    if draft.dueAt != nil {
        form.action("deadlineClear", l10n.tasks_deadline_remove, action: actions.clearDeadline)
    }
    form.disclosure("priority", l10n.tasks_cloud_editor_priority, label: l10n.tasks_cloud_priority(draft.priority), action: actions.pickPriority)
}

private func tasksCloudOwnerEditorEntries(form: TasksCloudForm, task: SGTasksCloudTask, state: TasksCloudEditorState, cloud: SGTasksCloudState, isRepair: Bool, assignee: TasksCloudEditorAssignee?, showsAssigneeSection: Bool, presentationData: PresentationData, l10n: SGTasksL10n, actions: TasksCloudOwnerEditorActions) {
    if isRepair {
        form.footer("repairExplanation", l10n.tasks_cloud_repair_explanation)
    } else {
        tasksCloudSyncStatusEntries(form: form, task: task, l10n: l10n, openUnsentChanges: actions.openUnsentChanges)
    }

    tasksCloudOwnerContentEntries(form: form, draft: state.draft, cloud: cloud, presentationData: presentationData, l10n: l10n, actions: actions)

    // A repair corrects the refused content only; the Masʼul, completion and delete stay on the board.
    if isRepair {
        return
    }

    if showsAssigneeSection {
        tasksCloudAssigneeEntries(form: form, task: task, assignee: assignee, l10n: l10n, actions: actions)
    }

    // The target is the state this title names (the title is part of the row's content key).
    let targetCompleted = !task.isCompleted
    // Row id per role, so a role change rebuilds the row (and its closure) even under the same title.
    let displayed = TasksCloudTaskPermissions(task: task)
    form.newSection()
    form.action("completion.owner", task.isCompleted ? l10n.tasks_cloud_editor_reopen : l10n.tasks_cloud_editor_complete, action: { actions.setCompleted(targetCompleted, displayed) })

    form.newSection()
    form.action("delete", l10n.tasks_cloud_editor_deleteTask, kind: .destructive, action: actions.delete)
}

/// The Masʼul section (wf15 §4.3): the row "Masʼul" with the value "Masʼul: Ism · holat" (or
/// "Yoʻq"), its footer, and the one action of the state — Masʼulni almashtirish / Masʼulni olib
/// tashlash while someone has the task, Qayta yuborish after it ended, Yuborish for a legacy
/// candidate (with its own clear when the candidate is an annotation). A completed task's row is
/// disabled with `tasks_assign_footer_completedTask` (a live assignee can still be removed). The
/// row carries `sgtasks.task.<id>.assignee`, the send action `sgtasks.task.<id>.assignee.resend`.
private func tasksCloudAssigneeEntries(form: TasksCloudForm, task: SGTasksCloudTask, assignee: TasksCloudEditorAssignee?, l10n: SGTasksL10n, actions: TasksCloudOwnerEditorActions) {
    let taskId = task.id.rawValue
    let rowValue: String
    if let assignee {
        rowValue = l10n.tasks_assign_line(name: assignee.name, state: tasksAssigneeStateWord(assignee.display.state, l10n: l10n))
    } else {
        rowValue = l10n.tasks_metadata_none
    }
    // The row picks (or replaces) unless the task is completed or a request is still on its way; a
    // deferred assignment ("Navbatda") can be replaced by a newer pick, which cancels the deferral.
    let rowEnabled: Bool
    if task.isCompleted {
        rowEnabled = false
    } else if let assignee {
        rowEnabled = assignee.display.state.rowPicks
    } else {
        rowEnabled = true
    }
    form.newSection()
    let rowTitle = l10n.tasks_assignee_title
    let rowAction: (() -> Void)? = rowEnabled ? actions.pickAssignee : nil
    form.add("assignee", key: [AnyHashable(rowTitle), AnyHashable(rowValue), AnyHashable(rowEnabled)]) { presentationData, section in
        let titleColor = rowEnabled ? presentationData.theme.list.itemPrimaryTextColor : presentationData.theme.list.itemDisabledTextColor
        let attributedTitle = NSAttributedString(string: rowTitle, font: Font.regular(presentationData.fontSize.itemListBaseFontSize), textColor: titleColor)
        let item = ItemListDisclosureItem(presentationData: presentationData, title: rowTitle, attributedTitle: attributedTitle, enabled: rowEnabled, label: rowValue, labelStyle: .multilineDetailText, sectionId: section, style: .blocks, disclosureStyle: rowAction == nil ? .none : .arrow, action: rowAction)
        return TasksCloudIdentifiedItem(item, identifier: TasksBoardAccessibilityId.taskAssignee(taskId))
    }

    if let assignee {
        switch assignee.display.state.action {
        case .none, .pickAgain:
            break
        case .replaceOrRemove:
            if !task.isCompleted {
                form.action("assigneeChange", l10n.tasks_assign_change, action: actions.pickAssignee)
            }
            form.action("assigneeRemove", l10n.tasks_assignee_remove, kind: .destructive, action: actions.removeAssignee)
        case .resend:
            if !task.isCompleted {
                let title = l10n.tasks_assign_resend
                form.add("assigneeResend", key: title) { presentationData, section in
                    let item = ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: actions.resendAssignment)
                    return TasksCloudIdentifiedItem(item, identifier: TasksBoardAccessibilityId.taskAssigneeResend(taskId))
                }
            }
        case .send:
            // A completed task is never a candidate (§7.2), so the action is always offered here.
            let title = l10n.tasks_assign_send
            form.add("assigneeSend", key: title) { presentationData, section in
                let item = ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: actions.sendLegacyAssignee)
                return TasksCloudIdentifiedItem(item, identifier: TasksBoardAccessibilityId.taskAssigneeResend(taskId))
            }
            if task.annotation != nil {
                // The legacy annotation's clear (§4.2 item 6); a mapped device row has nothing to clear here.
                form.action("assigneeRemove", l10n.tasks_assignee_remove, kind: .destructive, action: actions.removeAssignee)
            }
        }
    }

    let footer: String?
    if let assignee {
        switch assignee.display.state.footer {
        case .none:
            footer = task.isCompleted ? l10n.tasks_assign_footer_completedTask : nil
        case .queued:
            footer = l10n.tasks_assign_footer_queued
        case .pending:
            footer = l10n.tasks_assign_footer_pending(assignee.name)
        case .accepted:
            footer = assignee.serverSupportsNote ? l10n.tasks_assign_footer_accepted(assignee.name) : l10n.tasks_assign_footer_accepted_noNote(assignee.name)
        case .ended:
            footer = task.isCompleted ? l10n.tasks_assign_footer_completedTask : l10n.tasks_assign_footer_ended
        case .notSent:
            footer = l10n.tasks_assign_footer_notSent(assignee.name)
        }
    } else {
        footer = task.isCompleted ? l10n.tasks_assign_footer_completedTask : nil
    }
    if let footer {
        form.footer("assigneeFooter", footer)
    }
}

/// R4: the task's content while the consent hold makes Cloud read-only — nothing to change, no
/// action. Row ids are prefixed "readOnly." (an on-screen node is never updated with another item class).
private func tasksCloudReadOnlyEntries(form: TasksCloudForm, task: SGTasksCloudTask, cloud: SGTasksCloudState, presentationData: PresentationData, l10n: SGTasksL10n) {
    let use24HourClock = presentationData.dateTimeFormat.timeFormat == .military
    form.newSection()
    form.info("readOnly.title", label: l10n.tasks_cloud_editor_titlePlaceholder, text: tasksIsolatedDisplayText(task.title))
    if let description = task.description {
        // Its own row, so no isolation is needed (and isolates would not span its paragraphs anyway).
        form.info("readOnly.notes", label: l10n.tasks_cloud_editor_notesPlaceholder, text: description)
    }
    if task.viewerRole == .owner {
        let listTitle = task.listId.flatMap { listId in cloud.lists.first(where: { $0.id == listId })?.title }.map { tasksIsolatedDisplayText($0) } ?? l10n.tasks_cloud_inbox_title
        form.info("readOnly.list", label: l10n.tasks_cloud_editor_list, text: listTitle)
    }
    form.info("readOnly.deadline", label: l10n.tasks_deadline_title, text: task.dueAt.map { l10n.tasks_deadline_text($0, use24HourClock: use24HourClock) } ?? l10n.tasks_metadata_none)
    if task.viewerRole == .owner {
        form.info("readOnly.priority", label: l10n.tasks_cloud_editor_priority, text: l10n.tasks_cloud_priority(task.priority))
    }
}

/// A task assigned to the user (wf15 §5.2): who assigned it, the content as the owner wrote it
/// (read-only), the rights line, then completion, a confirmed Leave and Block Sender. Only an
/// accepted invitation shows the task and offers the actions; without one (missing or ended)
/// nothing of the task and no action is shown, only why (fail closed).
/// Row ids are prefixed "recipient." where the owner editor uses the same id with another item class
/// (an on-screen node is never updated with a different item type).
private func tasksCloudRecipientEntries(form: TasksCloudForm, task: SGTasksCloudTask, permissions: TasksCloudTaskPermissions, senderName: String, serverSupportsNote: Bool, presentationData: PresentationData, l10n: SGTasksL10n, setCompleted: @escaping (Bool, TasksCloudTaskPermissions) -> Void, leave: @escaping (TasksCloudTaskPermissions) -> Void, blockSender: @escaping (TasksCloudTaskPermissions, String) -> Void) {
    guard permissions.role == .acceptedRecipient else {
        form.footer("noAccess", l10n.tasks_cloud_access_recipientInactive)
        return
    }
    let use24HourClock = presentationData.dateTimeFormat.timeFormat == .military

    // "Topshirdi: Ism" (the viewer's own contact name, else the numeric id — a sender-chosen name
    // is never shown), the task read-only, and what the assignee may do (`_noNote` while the
    // server does not speak wire 5: no izoh yet).
    form.newSection()
    form.header("recipient.assignedBy", l10n.tasks_assigned_by(senderName))
    form.info("recipient.title", label: l10n.tasks_cloud_editor_titlePlaceholder, text: tasksIsolatedDisplayText(task.title))
    if let description = task.description {
        // Its own row, so no isolation is needed (and isolates would not span its paragraphs anyway).
        form.info("recipient.notes", label: l10n.tasks_cloud_editor_notesPlaceholder, text: description)
    }
    form.info("recipient.deadline", label: l10n.tasks_deadline_title, text: task.dueAt.map { l10n.tasks_deadline_text($0, use24HourClock: use24HourClock) } ?? l10n.tasks_metadata_none)
    form.footer("recipient.rights", serverSupportsNote ? l10n.tasks_assigned_rights : l10n.tasks_assigned_rights_noNote)

    if task.isPending || task.problem != nil {
        form.newSection()
        form.footer("recipient.syncStatus", task.problem == nil || task.problem == .waitingForDependency ? l10n.tasks_cloud_syncConfirmationPending : l10n.tasks_cloud_row_needsAttention)
    }

    // The row ids carry the role and accepted invitation epoch, so a new epoch rebuilds the rows (and
    // their closures); the content key alone (title + kind) would keep the old closures.
    let epoch = permissions.recipientInvitationId?.rawValue ?? ""
    let targetCompleted = !task.isCompleted
    form.newSection()
    form.action("completion.recipient.\(epoch)", task.isCompleted ? l10n.tasks_cloud_editor_reopen : l10n.tasks_cloud_editor_complete, action: { setCompleted(targetCompleted, permissions) })

    form.newSection()
    form.action("leave.\(epoch)", l10n.tasks_cloud_editor_leave, kind: .destructive, action: { leave(permissions) })
    form.action("block.\(epoch)", l10n.tasks_cloud_invitation_block, kind: .destructive, action: { blockSender(permissions, senderName) })
}

/// wf15 §5.2: the read-only preview a provisional "Menga topshirilgan" row opens — the invitation
/// preview (title, deadline, "Topshirdi: Ism") with the status "Sinxronlash tasdigʻi kutilmoqda".
/// No completion, no izoh, no action: a provisional row is not access. Once the automatic accept is
/// proven the task is shown as it arrived (the board's own row then offers the actions); once the
/// accept failed the invitation reads as a Takliflar entry again (its expiry), and when nothing is
/// left the screen says so.
func tasksCloudProvisionalTaskController(context: AccountContext, repository: SGTasksCloudRepository, invitationId: SGTasksWire.UUID, taskId: SGTasksWire.UUID, names: TasksPeerNameResolver?) -> ViewController {
    let senderName: Signal<String?, NoError> = tasksCloudStateSignal(repository)
    |> map { state -> SGTasksWire.TelegramId? in
        if let invitation = state.invitations.first(where: { $0.id == invitationId }) {
            return invitation.ownerTgId
        }
        return state.tasks.first(where: { $0.id == taskId })?.ownerTgId
    }
    |> distinctUntilChanged
    |> mapToSignal { owner -> Signal<String?, NoError> in
        guard let names, let owner else {
            return .single(nil)
        }
        return names.names(for: [owner])
        |> map { $0[owner] }
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, tasksCloudStateSignal(repository), senderName)
    |> map { presentationData, cloudState, contactName -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let l10n = SGTasksL10n(presentationData.strings)
        let use24HourClock = presentationData.dateTimeFormat.timeFormat == .military
        let deadline: (Int32?) -> String = { dueAt in
            return dueAt.map { l10n.tasks_deadline_text($0, use24HourClock: use24HourClock) } ?? l10n.tasks_metadata_none
        }
        let form = TasksCloudForm()
        if let invitation = cloudState.invitations.first(where: { $0.id == invitationId }) {
            form.newSection()
            form.header("preview.assignedBy", l10n.tasks_assigned_by(tasksCloudSenderDisplayName(invitation.ownerTgId, contactName: contactName, l10n: l10n)))
            // Another user's text: isolated so it cannot reorder the surrounding UI text, never linkified.
            form.info("preview.title", label: l10n.tasks_cloud_editor_titlePlaceholder, text: tasksIsolatedDisplayText(invitation.title))
            form.info("preview.deadline", label: l10n.tasks_deadline_title, text: deadline(invitation.dueAt))
            if cloudState.automaticAcceptInvitationIds.contains(invitationId) {
                form.footer("preview.status", l10n.tasks_cloud_syncConfirmationPending)
            } else if invitation.isExpired(serverTime: cloudState.estimatedServerNow()) {
                form.footer("preview.status", l10n.tasks_cloud_invitation_expired)
            } else {
                // The accept did not go through: the invitation waits in Takliflar for the user's answer.
                form.footer("preview.status", l10n.tasks_cloud_invitation_expires(tasksCloudFormattedInstant(invitation.expiresAt, presentationData: presentationData)))
            }
        } else if let task = cloudState.tasks.first(where: { $0.id == taskId }), task.viewerRole == .assignee {
            form.newSection()
            form.header("arrived.assignedBy", l10n.tasks_assigned_by(tasksCloudSenderDisplayName(task.ownerTgId, contactName: contactName, l10n: l10n)))
            form.info("arrived.title", label: l10n.tasks_cloud_editor_titlePlaceholder, text: tasksIsolatedDisplayText(task.title))
            if let description = task.description {
                form.info("arrived.notes", label: l10n.tasks_cloud_editor_notesPlaceholder, text: description)
            }
            form.info("arrived.deadline", label: l10n.tasks_deadline_title, text: deadline(task.dueAt))
            form.footer("arrived.rights", repository.isServerWire5Now ? l10n.tasks_assigned_rights : l10n.tasks_assigned_rights_noNote)
        } else {
            form.footer("gone", l10n.tasks_cloud_error_gone)
        }
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(l10n.tasks_assigned_editorTitle),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: form.entries, style: .blocks), ()))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { (_: Bool) in
        SGTasksAnalytics.emit(.screen("tasks.task_editor"), accountPeerId: repository.accountPeerId)
    }
    return controller
}
