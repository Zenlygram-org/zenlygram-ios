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
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — Tasks ▸ Takliflar (wf15 §5.2): the incoming invitations the contact rule left for the
// user (preview only: title, deadline, the sender, expiry) with Accept / Decline / Block Sender, and
// the user's own blocked senders with Unblock. One top line says why most invitations never show
// here (a contact's task is accepted on the phone, `tasks_invitations_hint`); an invitation whose
// automatic accept is on its way is a provisional "Menga topshirilgan" row, not an entry here. The
// sender is named only when they are one of the viewer's own Telegram contacts (§5.6) — the wire
// carries no verified name and a sender-chosen one is never shown — so in practice the sender reads
// as the numeric Telegram id, as the footer explains. Answers are queued like every other cloud
// change; a queued answer says so instead of pretending it was delivered. R4: while the account's
// consent hold makes Cloud read-only, no answer, block or unblock is queued (the reason is shown
// instead).

func tasksCloudFormattedInstant(_ date: Date, presentationData: PresentationData) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: presentationData.strings.baseLanguageCode)
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func tasksCloudInvitationsController(context: AccountContext, repository: SGTasksCloudRepository, names: TasksPeerNameResolver? = nil) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?

    let l10n: () -> SGTasksL10n = {
        return SGTasksL10n(context.sharedContext.currentPresentationData.with { $0 }.strings)
    }
    let perform: (() throws -> Void) -> Void = { body in
        // R4: nothing is queued while the consent hold makes Cloud read-only.
        if let reason = repository.readOnlyReason(repository.state) {
            presentImpl?(tasksNoticeToast(context: context, text: l10n().tasks_cloud_readOnly(reason)))
            return
        }
        do {
            try body()
        } catch {
            presentImpl?(tasksErrorAlert(context: context, text: tasksCloudRefusalText(error, l10n: l10n())))
        }
    }
    /// Re-read at tap time: an invitation that expired (by the estimated server clock) or already has
    /// a queued answer is never answered again, whatever the row showed when it was drawn.
    let answerableInvitation: (SGTasksWire.UUID) -> SGTasksCloudInvitation? = { id in
        let state = repository.state
        guard let invitation = state.invitations.first(where: { $0.id == id }) else {
            presentImpl?(tasksErrorAlert(context: context, text: l10n().tasks_cloud_error_gone))
            return nil
        }
        if invitation.isResponsePending {
            presentImpl?(tasksErrorAlert(context: context, text: l10n().tasks_cloud_error_alreadyPending))
            return nil
        }
        return invitation
    }
    let respond: (SGTasksWire.UUID, Bool) -> Void = { id, accept in
        guard let invitation = answerableInvitation(id) else {
            return
        }
        if invitation.isExpired(serverTime: repository.state.estimatedServerNow()) {
            presentImpl?(tasksErrorAlert(context: context, text: l10n().tasks_cloud_error_invitationExpired))
            return
        }
        perform { try repository.respondToInvitation(id: id, accept: accept) }
    }
    let block: (SGTasksWire.UUID, String) -> Void = { id, sender in
        guard answerableInvitation(id) != nil else {
            return
        }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let l10n = l10n()
        presentImpl?(textAlertController(context: context, title: l10n.tasks_cloud_invitation_block, text: l10n.tasks_cloud_invitation_blockConfirm_text(sender), actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: l10n.tasks_cloud_invitation_block, action: {
                // The repository refuses again if an answer or block got queued meanwhile.
                perform { try repository.blockSender(invitationId: id) }
            })
        ]))
    }
    let unblock: (SGTasksWire.TelegramId) -> Void = { senderId in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let l10n = l10n()
        presentImpl?(textAlertController(context: context, title: l10n.tasks_cloud_unblock_title, text: l10n.tasks_cloud_unblock_footer, actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: l10n.tasks_cloud_unblock, action: {
                perform { try repository.unblockSender(senderId) }
            })
        ]))
    }

    // wf15 §5.6: the senders' contact names (the viewer's own contacts only), re-read when the set
    // of senders changes.
    let senderNames: Signal<[SGTasksWire.TelegramId: String], NoError> = tasksCloudStateSignal(repository)
    |> map { Set($0.invitations.map { $0.ownerTgId }) }
    |> distinctUntilChanged
    |> mapToSignal { senders -> Signal<[SGTasksWire.TelegramId: String], NoError> in
        guard let names else {
            return .single([:])
        }
        return names.names(for: senders)
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, tasksCloudStateSignal(repository), senderNames)
    |> map { presentationData, cloud, senderNames -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let l10n = SGTasksL10n(presentationData.strings)
        let use24HourClock = presentationData.dateTimeFormat.timeFormat == .military
        let form = TasksCloudForm()

        // wf15 §5.2: the one top line (recipient-side only; the sender never sees it).
        form.footer("hint", l10n.tasks_invitations_hint)
        // An invitation whose automatic accept is queued or in flight is a provisional "Menga
        // topshirilgan" row on the board, not a Takliflar entry (it returns here if that accept fails).
        let invitations = cloud.invitations.filter { !cloud.automaticAcceptInvitationIds.contains($0.id) }
        if invitations.isEmpty {
            form.newSection()
            form.footer("empty", l10n.tasks_cloud_invitations_empty)
        }
        for invitation in invitations {
            let id = invitation.id
            let key = id.rawValue
            let sender = tasksCloudSenderDisplayName(invitation.ownerTgId, contactName: senderNames[invitation.ownerTgId], l10n: l10n)
            let isExpired = invitation.isExpired(serverTime: cloud.estimatedServerNow())
            form.newSection()
            form.header("from.\(key)", l10n.tasks_cloud_invitation_from(sender))
            let deadline = invitation.dueAt.map { l10n.tasks_deadline_text($0, use24HourClock: use24HourClock) } ?? l10n.tasks_metadata_none
            // Another user's text: isolated so it cannot reorder the surrounding UI text, never linkified.
            form.info("title.\(key)", label: l10n.tasks_deadline_title + ": " + deadline, text: tasksIsolatedDisplayText(invitation.title))
            let expiry = isExpired ? l10n.tasks_cloud_invitation_expired : l10n.tasks_cloud_invitation_expires(tasksCloudFormattedInstant(invitation.expiresAt, presentationData: presentationData))
            let canAnswer = !isExpired && !invitation.isResponsePending
            form.action("accept.\(key)", l10n.tasks_cloud_invitation_accept, kind: canAnswer ? .generic : .disabled, action: {
                respond(id, true)
            })
            form.action("decline.\(key)", l10n.tasks_cloud_invitation_decline, kind: canAnswer ? .generic : .disabled, action: {
                respond(id, false)
            })
            form.action("block.\(key)", l10n.tasks_cloud_invitation_block, kind: invitation.isResponsePending ? .disabled : .destructive, action: {
                block(id, sender)
            })
            form.footer("status.\(key)", invitation.isResponsePending ? l10n.tasks_cloud_syncConfirmationPending : expiry)
        }
        // What accepting would change: rights begin only after acceptance (a pending invitation is a
        // preview, never access), and the sender's lists and other tasks are never part of it. The
        // izoh is named only once the server speaks wire 5 (`_noNote` otherwise).
        form.newSection()
        form.info("accessBefore", label: l10n.tasks_cloud_invitations_access_beforeLabel, text: l10n.tasks_cloud_invitations_access_before)
        form.info("accessAfter", label: l10n.tasks_cloud_invitations_access_afterLabel, text: repository.isServerWire5Now ? l10n.tasks_cloud_invitations_access_after : l10n.tasks_cloud_invitations_access_after_noNote)
        form.footer("explain", l10n.tasks_cloud_invitations_footer)

        if !cloud.blocks.isEmpty {
            form.newSection()
            form.header("blockedHeader", l10n.tasks_cloud_blocked_header)
            for blockEntry in cloud.blocks {
                let senderId = blockEntry.id
                form.disclosure("blocked.\(senderId.rawValue)", l10n.tasks_cloud_telegramUser(senderId.rawValue), label: l10n.tasks_cloud_unblock, action: {
                    unblock(senderId)
                })
            }
            form.footer("blockedFooter", l10n.tasks_cloud_unblock_footer)
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(l10n.tasks_cloud_invitations_title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: form.entries, style: .blocks), ()))
    }

    // No refresh on appearance: the board's repository is already syncing while started, and an
    // explicit refresh here could clear a pause that only linking may clear.
    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { (_: Bool) in
        SGTasksAnalytics.emit(.screen("tasks.invitations"), accountPeerId: repository.accountPeerId)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
