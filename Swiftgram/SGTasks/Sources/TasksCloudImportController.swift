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

// Zenlygram — Cloud Tasks ▸ Copy to Cloud: the explicit consent screen for copying device tasks into
// this account's cloud. It previews exactly what will be copied — the rows not in this account's cloud
// yet, under the R4 rules the automatic migration uses too: the device Inbox under its default title
// goes to the Cloud Inbox, every other list becomes its own cloud list, titles that do not fit are
// adjusted instead of refused — says that assignees stay on this device (nobody is invited or
// notified), that the server stores and processes the copies without end-to-end encryption, and
// that originals stay on this device. Nothing happens until "Copy to Cloud"; creating passes the
// same CREATE gate as a new task. While the account's consent hold makes Cloud read-only it does not open.

/// Prepares the consent snapshot and pushes the screen; a refusal (cloud still syncing, storage, a
/// consent hold) is told instead of opening an empty screen.
func pushTasksCloudImportController(context: AccountContext, repository: SGTasksCloudRepository, navigationController: NavigationController, present: @escaping (ViewController) -> Void) {
    let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
    let l10n = SGTasksL10n(strings)
    if let reason = repository.readOnlyReason(repository.state) {
        present(tasksNoticeToast(context: context, text: l10n.tasks_cloud_readOnly(reason)))
        return
    }
    // Placeholder language of the copy when the account has no migration record yet (prepare and
    // commit use the same one).
    let locale = TodoCloudMigrationRecord.Locale(languageCode: strings.primaryComponent.languageCode)
    let preview: SGTasksCloudImportPreview
    do {
        preview = try repository.prepareLegacyImport(locale: locale)
    } catch {
        present(tasksErrorAlert(context: context, text: tasksCloudRefusalText(error, l10n: l10n)))
        return
    }
    switch preview.availability {
    case .nothingOnDevice:
        present(tasksErrorAlert(context: context, text: l10n.tasks_cloud_import_nothing))
        return
    case .alreadyDone:
        present(tasksErrorAlert(context: context, text: l10n.tasks_cloud_import_alreadyDone))
        return
    case .waitingOnEarlierCopy:
        present(tasksErrorAlert(context: context, text: l10n.tasks_cloud_import_waitingOnEarlier))
        return
    case .canCopy, .onlyNeedsCorrection:
        break
    }
    navigationController.pushViewController(tasksCloudImportController(context: context, repository: repository, preview: preview, locale: locale))
}

private func tasksCloudNeedsCorrection(_ status: SGTasksCloudImportPreview.ItemStatus) -> Bool {
    if case .needsCorrection = status {
        return true
    }
    return false
}

/// R4 rules: the device Inbox under its default title creates no list, its tasks go to the Cloud
/// Inbox (exactly R3 — a build without a Tasks backend — keeps it a list of its own).
private func tasksCloudImportMapsToCloudInbox(_ folder: SGTasksCloudImportPreview.Folder, isR4: Bool) -> Bool {
    return isR4 && folder.isLegacyInbox && SGTasksMigrationNormalizer.isCloudInbox(folderId: folder.legacyId, title: folder.title)
}

private func tasksCloudImportController(context: AccountContext, repository: SGTasksCloudRepository, preview initialPreview: SGTasksCloudImportPreview, locale: TodoCloudMigrationRecord.Locale) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?
    var preview = initialPreview
    let previewPromise = Promise<SGTasksCloudImportPreview>(initialPreview)
    var isCommitting = false
    let isR4 = repository.permission != .legacy

    let commit: () -> Void = {
        guard !isCommitting else {
            return
        }
        let l10n = SGTasksL10n(context.sharedContext.currentPresentationData.with { $0 }.strings)
        if let reason = repository.readOnlyReason(repository.state) {
            presentImpl?(tasksNoticeToast(context: context, text: l10n.tasks_cloud_readOnly(reason)))
            return
        }
        guard tasksCreateGate(context: context, present: { presentImpl?($0) }) else {
            return
        }
        isCommitting = true
        do {
            let result = try repository.commitLegacyImport(preview, locale: locale)
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            var text = l10n.tasks_cloud_import_started
            let notCopied = result.blocked + result.needsCorrection
            if notCopied > 0 {
                text += "\n\n" + l10n.tasks_cloud_import_result_notCopied(notCopied)
            }
            presentImpl?(textAlertController(context: context, title: l10n.tasks_cloud_import_done, text: text, actions: [
                TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})
            ]))
            popImpl?()
        } catch {
            isCommitting = false
            // A stale consent snapshot is never committed: the preview is rebuilt for a fresh look.
            if let refreshed = try? repository.prepareLegacyImport(locale: locale) {
                preview = refreshed
                previewPromise.set(.single(refreshed))
            }
            presentImpl?(tasksErrorAlert(context: context, text: tasksCloudRefusalText(error, l10n: l10n)))
        }
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, previewPromise.get())
    |> map { presentationData, preview -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let l10n = SGTasksL10n(presentationData.strings)
        let form = TasksCloudForm()
        form.footer("summary", l10n.tasks_cloud_import_summary(lists: preview.importableFolderCount, tasks: preview.importableTaskCount))

        if !preview.folders.isEmpty {
            form.newSection()
            form.header("listsHeader", l10n.tasks_cloud_import_listsHeader)
            for folder in preview.folders {
                let status = tasksCloudImportMapsToCloudInbox(folder, isR4: isR4) ? l10n.tasks_cloud_import_status_cloudInbox : l10n.tasks_cloud_import_status(folder.status, taskCount: folder.taskCount)
                form.info("folder.\(folder.legacyId)", label: status, text: tasksIsolatedDisplayText(folder.title))
            }
            if preview.folders.contains(where: { tasksCloudImportMapsToCloudInbox($0, isR4: isR4) }) {
                form.footer("inboxNote", l10n.tasks_cloud_import_inboxNote)
            }
        }

        let allStatuses = preview.folders.map { $0.status } + preview.tasks.map { $0.status }
        let skippedTasks = preview.tasks.filter { tasksCloudNeedsCorrection($0.status) }.count
        form.newSection()
        // The assignee never travels with a copy (R4), so an unconvertible one blocks nothing.
        form.footer("annotationsNote", l10n.tasks_cloud_import_annotationsNote)
        form.footer("normalizationNote", l10n.tasks_cloud_import_normalizationNote)
        if skippedTasks > 0 {
            form.footer("skipped", l10n.tasks_cloud_import_skipped(skippedTasks))
        }
        if allStatuses.contains(.resendPreviousAttempt) {
            form.footer("resendNote", l10n.tasks_cloud_import_resendNote)
        }
        if allStatuses.contains(.removedFromCloud) {
            form.footer("removedNote", l10n.tasks_cloud_import_removedNote)
        }
        if allStatuses.contains(.importBlocked) || allStatuses.contains(.importPending) {
            form.footer("earlierNote", l10n.tasks_cloud_import_waitingOnEarlier)
        }
        form.footer("privacyNote", l10n.tasks_cloud_import_privacyNote)

        form.newSection()
        let canCommit = preview.importableFolderCount + preview.importableTaskCount > 0
        form.action("confirm", l10n.tasks_cloud_import_confirm, kind: canCommit ? .generic : .disabled, action: commit)

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(l10n.tasks_cloud_import_title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: form.entries, style: .blocks), ()))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    popImpl = { [weak controller] in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}
