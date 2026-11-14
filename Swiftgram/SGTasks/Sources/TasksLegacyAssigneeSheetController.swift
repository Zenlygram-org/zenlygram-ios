import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import ItemListUI
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — Tasks: the one-time legacy assignee sheet (wf15 §7, D4 "Eski (qurilmadagi)
// masʼullar"). "N ta vazifada masʼul bor — ularga yuborilsinmi?" lists every device-row candidate as
// "title → name" (a greyed suffix for a row that cannot be sent) and offers exactly two buttons,
// Yuborish and Keyinroq. Nothing is sent until Yuborish: it records every allowed task in the
// durable sent set first, then enqueues one `invitation.request` per task to the candidate's
// Telegram id — only the id, never the name, no annotation — spaced ten per minute within the
// pacer's allowance (§7.3, §12.1); the rows the allowance leaves out keep their per-task "Hali
// yuborilmagan · Yuborish" and the Lists entry. Keyinroq sends nothing and says how to come back.
// Either way the marker (§7.4) is written for the account's migration record, so the sheet never
// returns by itself; the Lists entry reopens it while candidates remain. A swipe that dismisses the
// card counts as Keyinroq.
//
// Accessibility: the body carries `sgtasks.legacy.sheet`, the buttons `sgtasks.legacy.send` and
// `sgtasks.legacy.later`; every row's label is the `tasks_legacySheet_row` text.

/// What the sheet needs from its host.
struct TasksLegacyAssigneeSheetHost {
    let repository: SGTasksCloudRepository
    let assignment: TasksAssignmentCoordinator
    /// The migration record the marker is bound to (`record.claimedAt`).
    let claimedAt: Int64
    /// A transient note after the sheet closed (`tasks_legacySheet_sentToast`, the paced sentence,
    /// `tasks_legacySheet_laterHint`), presented by the host.
    let presentToast: (String) -> Void
    /// The sheet closed by any path; the host recomputes the offer and the presentation.
    let finished: () -> Void
}

/// The sheet as a modal card (`navigationPresentation = .modal`, pushed by the host).
func tasksLegacyAssigneeSheetController(context: AccountContext, offer: SGTasksLegacyAssigneeOffer, host: TasksLegacyAssigneeSheetHost) -> ViewController {
    let repository = host.repository
    let accountPeerId = repository.accountPeerId
    let l10n: () -> SGTasksL10n = {
        return SGTasksL10n(context.sharedContext.currentPresentationData.with { $0 }.strings)
    }
    var dismissImpl: (() -> Void)?
    /// Yuborish or Keyinroq was tapped (a dismissal without either is Keyinroq).
    var decided = false
    /// The allowance as it stood when the sheet opened: the paced sentence under the rows.
    let openingPlan = offer.plan(snapshot: repository.invitationPacerSnapshot() ?? .zero, now: Date())

    let later: () -> Void = {
        guard !decided else {
            return
        }
        decided = true
        SGTasksLocalMarkers.setLegacyOfferMarker(.later, accountPeerId: accountPeerId, claimedAt: host.claimedAt)
        dismissImpl?()
        host.presentToast(l10n().tasks_legacySheet_laterHint)
        host.finished()
    }

    let send: () -> Void = {
        guard !decided else {
            return
        }
        let l10n = l10n()
        // R4: nothing is queued while the consent hold makes the board read-only.
        if let reason = repository.readOnlyReason(repository.state) {
            host.presentToast(l10n.tasks_cloud_readOnly(reason))
            return
        }
        decided = true
        // Only what the sheet listed (§7.2 item 3): the offer is recomputed at the tap so that a
        // row which stopped being a candidate is dropped, but a task → person pair that became one
        // while the sheet was open is not sent — no row named it.
        let confirmed = offer.confirmedSendable(at: host.assignment.refreshLegacyOffer())
        // The allowance at tap time (§7.3): per recipient ≤ 5 − sent today, in all ≤ 95 − sent today,
        // pending < 95; entry k due at now + floor((k + sentThisMinute) / 10) minutes.
        let plan = SGTasksLegacyAssigneeOffer.plan(sendable: confirmed, snapshot: repository.invitationPacerSnapshot() ?? .zero, now: Date())
        var sent = 0
        for item in plan.sends {
            guard let recipient = item.candidate.recipient else {
                continue
            }
            // The sent set first (§7.4), then the request; a refusal at enqueue takes the id back.
            host.assignment.markLegacySent(item.candidate.cloudTaskId)
            do {
                try repository.assignTask(id: item.candidate.cloudTaskId, recipient: recipient, nextAttemptAt: item.dueAt)
                sent += 1
            } catch let error as SGTasksCloudError {
                host.assignment.unmarkLegacySent(item.candidate.cloudTaskId)
                if error == .storageUnavailable || error == .accountRemoved {
                    break
                }
            } catch {
                host.assignment.unmarkLegacySent(item.candidate.cloudTaskId)
            }
        }
        SGTasksLocalMarkers.setLegacyOfferMarker(.done, accountPeerId: accountPeerId, claimedAt: host.claimedAt)
        host.assignment.refreshLegacyOffer()
        dismissImpl?()
        // The paced sentence names only what the pacer left for later; a row whose enqueue was
        // refused (completed or assigned elsewhere meanwhile) is not "later, up to 5 a day".
        var texts: [String] = []
        if plan.isCapped {
            texts.append(l10n.tasks_legacySheet_paced(now: sent, later: plan.later))
        }
        if sent > 0 {
            texts.append(l10n.tasks_legacySheet_sentToast(sent))
        }
        if !texts.isEmpty {
            host.presentToast(texts.joined(separator: " "))
        }
        host.finished()
    }

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let l10n = SGTasksL10n(presentationData.strings)
        let form = TasksCloudForm()
        let text = l10n.tasks_legacySheet_text
        form.add("text", key: text) { presentationData, section in
            let item = ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
            return TasksCloudIdentifiedItem(item, identifier: TasksBoardAccessibilityId.legacySheet)
        }
        form.newSection()
        for candidate in offer.candidates {
            let row = l10n.tasks_legacySheet_row(title: tasksIsolatedDisplayText(candidate.title), name: tasksIsolatedDisplayText(candidate.name))
            let suffix: String
            if candidate.isSelf {
                suffix = l10n.tasks_legacySheet_self
            } else if candidate.recipient == nil {
                suffix = l10n.tasks_legacySheet_notSendable
            } else {
                suffix = ""
            }
            form.disclosure("row.\(candidate.cloudTaskId.rawValue)", row, label: suffix, enabled: candidate.isSendable, action: nil)
        }
        if openingPlan.isCapped {
            form.footer("paced", l10n.tasks_legacySheet_paced(now: openingPlan.sends.count, later: openingPlan.later))
        }
        form.newSection()
        let sendTitle = l10n.tasks_legacySheet_send
        form.add("send", key: sendTitle) { presentationData, section in
            let item = ItemListActionItem(presentationData: presentationData, title: sendTitle, kind: .generic, alignment: .center, sectionId: section, style: .blocks, action: send)
            return TasksCloudIdentifiedItem(item, identifier: TasksBoardAccessibilityId.legacySheetSend)
        }
        let laterTitle = l10n.tasks_legacySheet_later
        form.add("later", key: laterTitle) { presentationData, section in
            let item = ItemListActionItem(presentationData: presentationData, title: laterTitle, kind: .neutral, alignment: .center, sectionId: section, style: .blocks, action: later)
            return TasksCloudIdentifiedItem(item, identifier: TasksBoardAccessibilityId.legacySheetLater)
        }
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(l10n.tasks_legacySheet_title(offer.candidates.count)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: form.entries, style: .blocks), ()))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    controller.didDisappear = { [weak controller] _ in
        // Gone without a tap (a swipe down, a system dismissal): Keyinroq.
        guard let controller, !decided, controller.navigationController == nil, controller.presentingViewController == nil else {
            return
        }
        later()
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}
