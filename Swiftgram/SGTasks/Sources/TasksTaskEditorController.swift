import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import UndoUI

// Zenlygram — Tasks: editing an existing task's name, assignee and deadline, plus the Telegram contact
// picker that chooses an assignee. The assignee stays LOCAL: it is never copied to Cloud; with data
// consent the task and its deadline are copied once by the R4 migration. The chosen contact is not
// notified (the stock picker's contact search itself uses the network).
// Editing is never gated (only creating is). Leaving with unsaved changes asks first; neither Cancel
// nor Discard ever writes. R4: the save names the account (`asAccount:`); while the account's device
// board is an archive the task opens read-only, and a save the storage fence refuses keeps the draft
// on screen with a note (never an error alert).

// MARK: - Assignee picker

/// The assignee for a picked contact, or nil when it cannot be one: only the user's own Telegram
/// contacts (not global search results, bots, device-only contacts, groups or channels) with a visible
/// name. The phone number is never used, even as a fallback name.
func tasksAssignee(from peer: ContactListPeer, lastNameFirst: Bool) -> TodoAssignee? {
    guard case let .peer(enginePeer, isGlobal, _) = peer, !isGlobal, case let .user(user) = enginePeer, user.botInfo == nil else {
        return nil
    }
    let names = [user.firstName, user.lastName].compactMap { name -> String? in
        guard let name, !name.isEmpty else {
            return nil
        }
        return name
    }
    let displayName = (lastNameFirst ? names.reversed() : names).joined(separator: " ")
    return try? TodoStorage.validatedAssignee(peerId: user.id.toInt64(), displayName: displayName)
}

/// Pushes Telegram's own contact picker (single selection, cloud contacts only) unless one is already
/// on top (a fast double tap). `completion` follows the picker's result signal, which emits on Cancel
/// or a chosen contact but NOT when the picker is swiped or tapped away; the draft is then unchanged.
/// `closed` therefore watches the navigation stack instead: it runs once, asynchronously after the
/// picker has left the stack by any path (and after `completion`), so callers can hand the keyboard
/// back. Choosing a contact only stores a local annotation: the contact is not messaged or notified.
///
/// Returns the stack watch (dispose it when the caller goes away), or nil when nothing was pushed.
func pushTasksAssigneePicker(context: AccountContext, navigationController: NavigationController, title: ((PresentationStrings) -> String)? = nil, completion: @escaping (TodoAssignee?) -> Void, closed: @escaping () -> Void) -> Disposable? {
    if navigationController.topViewController is ContactSelectionController {
        return nil
    }
    let picker = tasksAssigneePickerController(context: context, title: title ?? { strings in SGTasksL10n(strings).tasks_assignee_pickerTitle }, completion: completion)
    navigationController.pushViewController(picker)
    // Subscribed after the push, so the current stack (which holds the picker) is not a "close".
    return (navigationController.viewControllersSignal
    |> filter { [weak picker] controllers in
        guard let picker else {
            return true
        }
        return !controllers.contains(where: { $0 === picker })
    }
    |> take(1)).startStandalone(next: { _ in
        // The stack signal fires inside the navigation update; touch the first responder after it.
        DispatchQueue.main.async(execute: closed)
    })
}

private func tasksAssigneePickerController(context: AccountContext, title: @escaping (PresentationStrings) -> String, completion: @escaping (TodoAssignee?) -> Void) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    var lastNameFirst = false
    if case .lastFirst = presentationData.nameDisplayOrder {
        lastNameFirst = true
    }
    let candidate: (ContactListPeer) -> TodoAssignee? = { peer in
        return tasksAssignee(from: peer, lastNameFirst: lastNameFirst)
    }
    let controller = context.sharedContext.makeContactSelectionController(ContactSelectionControllerParams(
        context: context,
        title: title,
        displayDeviceContacts: false,
        multipleSelection: .disabled,
        confirmation: { peer in .single(candidate(peer) != nil) },
        isPeerEnabled: { peer in candidate(peer) != nil }
    ))
    controller.navigationPresentation = .modal
    let _ = (controller.result
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: { result in
        guard let result, let peer = result.0.first else {
            completion(nil)
            return
        }
        completion(candidate(peer))
    })
    return controller
}

// MARK: - Editor

private struct TasksTaskEditorDraft: Equatable {
    var title: String
    var assignee: TodoAssignee?
    var dueAt: Int32?

    /// What Save would compare: the validated title when it is valid, otherwise the raw text.
    private static func comparableTitle(_ title: String) -> String {
        if case let .valid(validTitle) = tasksValidateTitle(title, limit: TasksTitleLimit.task) {
            return validTitle
        }
        return title
    }

    /// Title, assignee and deadline all count; editing back to the original value is clean, and
    /// so is whitespace that Save would trim away.
    func hasChanges(from original: TasksTaskEditorDraft) -> Bool {
        if self.assignee != original.assignee || self.dueAt != original.dueAt {
            return true
        }
        if self.title == original.title {
            return false
        }
        return TasksTaskEditorDraft.comparableTitle(self.title) != TasksTaskEditorDraft.comparableTitle(original.title)
    }
}

/// Where focus goes back after a picker or the discard confirmation closes.
private enum TasksTaskEditorFocus {
    case title
    case assignee
    case deadline
}

final class TasksTaskEditorController: ViewController {
    private let context: AccountContext
    private let accountPeerId: Int64
    /// Read-only (wf15 §3.4, a row of "Eski vazifalar", or a write the cut-over's fence refused
    /// meanwhile): no field, picker or Save.
    private var isReadOnly: Bool
    /// wf15 §4.4: the device board's Masʼul gate (the needs-sync sheet / wait toast instead of the
    /// picker); nil for S1 and for the read-only view. An existing local assignee stays removable.
    private let assignGate: TasksDeviceAssignGate?
    private let taskId: String
    private let original: TasksTaskEditorDraft
    private var draft: TasksTaskEditorDraft
    private let saved: () -> Void
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    private var assigneePickerClosedDisposable: Disposable?
    private var timeContextObserver: TasksTimeContextObserver?
    /// Set once the editor is leaving (saved, unchanged or discarded): no further prompt or save.
    private var isClosing = false
    /// The discard confirmation on screen, if any: at most one at a time.
    private weak var discardConfirmation: ViewController?
    private weak var noticeController: UndoOverlayController?

    private var editorNode: TasksTaskEditorNode {
        return self.displayNode as! TasksTaskEditorNode
    }

    init(context: AccountContext, task: TodoTask, accountPeerId: Int64, readOnly: Bool, assignGate: TasksDeviceAssignGate? = nil, saved: @escaping () -> Void) {
        self.context = context
        self.accountPeerId = accountPeerId
        self.isReadOnly = readOnly
        self.assignGate = assignGate
        self.taskId = task.id
        let original = TasksTaskEditorDraft(title: task.title, assignee: task.assignee, dueAt: task.dueAt)
        self.original = original
        self.draft = original
        self.saved = saved
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        // The editor draws its own Cancel/Save bar so both carry stable accessibility identifiers.
        super.init(navigationBarPresentationData: nil)
        // Card dim-taps bypass attemptNavigation; explicit Cancel/Save must own draft dismissal.
        self.navigationPresentation = .flatModal
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style

        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            guard let self else {
                return
            }
            self.presentationData = presentationData
            self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
            if self.isNodeLoaded {
                self.editorNode.update(presentationData: presentationData)
            }
        })

        // Retain the guard for navigation-driven closes. Modal continuations are empty, so an
        // explicit Discard closes the editor itself rather than relying on that continuation.
        self.attemptNavigation = { [weak self] _ in
            guard let self else {
                return true
            }
            if self.isClosing || !self.draft.hasChanges(from: self.original) {
                return true
            }
            self.confirmDiscard()
            return false
        }

        // "Today"/"Tomorrow" deadline text goes stale across midnight or a time-zone change.
        self.timeContextObserver = TasksTimeContextObserver(changed: { [weak self] in
            guard let self, self.isNodeLoaded else {
                return
            }
            self.editorNode.refreshDeadlineText()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
        self.assigneePickerClosedDisposable?.dispose()
    }

    private var l10n: SGTasksL10n {
        return SGTasksL10n(self.presentationData.strings)
    }

    override func loadDisplayNode() {
        let actions = TasksTaskEditorActions(
            titleChanged: { [weak self] title in self?.draft.title = title },
            cancel: { [weak self] in self?.requestClose() },
            save: { [weak self] in self?.save() },
            pickAssignee: { [weak self] in self?.pickAssignee() },
            clearAssignee: { [weak self] in self?.updateDraft { $0.assignee = nil } },
            pickDeadline: { [weak self] in self?.pickDeadline() },
            clearDeadline: { [weak self] in self?.updateDraft { $0.dueAt = nil } }
        )
        // wf15 §3.4 / §4.4: outside S1 (and in the read-only view) a local assignee is an old entry.
        let marksLegacyAssignee = self.isReadOnly || (self.assignGate.map { $0.availability() != .legacyLocal } ?? false)
        self.displayNode = TasksTaskEditorNode(draft: self.draft, readOnly: self.isReadOnly, marksLegacyAssignee: marksLegacyAssignee, presentationData: self.presentationData, actions: actions)
        self.displayNodeDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        SGTasksAnalytics.emit(.screen("tasks.task_editor"), accountPeerId: self.accountPeerId)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.editorNode.containerLayoutUpdated(layout, transition: transition)
    }

    private func updateDraft(_ f: (inout TasksTaskEditorDraft) -> Void) {
        f(&self.draft)
        if self.isNodeLoaded {
            self.editorNode.update(draft: self.draft)
        }
    }

    /// The keyboard returns to the title if it was there; otherwise VoiceOver returns to the row that
    /// opened the picker.
    private func takeFocusForPicker(row: TasksTaskEditorFocus) -> TasksTaskEditorFocus {
        let focus: TasksTaskEditorFocus = self.editorNode.isEditingTitle ? .title : row
        self.view.endEditing(true)
        return focus
    }

    private func restoreFocus(_ focus: TasksTaskEditorFocus) {
        guard !self.isClosing, self.isNodeLoaded, self.discardConfirmation == nil else {
            return
        }
        self.editorNode.restoreFocus(focus)
    }

    private func pickAssignee() {
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        // wf15 §4.4: no new local assignee outside S1 — the needs-sync sheet or the wait toast.
        guard tasksDeviceAssignAllowsPicker(self.assignGate, context: self.context, present: { [weak self] c in self?.present(c, in: .window(.root)) }, presentToast: { [weak self] toast in self?.present(toast, in: .current) }) else {
            return
        }
        let focus = self.takeFocusForPicker(row: .assignee)
        let closedDisposable = pushTasksAssigneePicker(context: self.context, navigationController: navigationController, completion: { [weak self] assignee in
            guard let self, let assignee else {
                return
            }
            self.updateDraft { $0.assignee = assignee }
        }, closed: { [weak self] in
            self?.restoreFocus(focus)
        })
        if let closedDisposable {
            self.assigneePickerClosedDisposable?.dispose()
            self.assigneePickerClosedDisposable = closedDisposable
        }
    }

    private func pickDeadline() {
        let focus = self.takeFocusForPicker(row: .deadline)
        presentTasksDeadlinePicker(from: self.view, currentDueAt: self.draft.dueAt, presentationData: self.presentationData, commit: { [weak self] result in
            switch result {
            case let .set(dueAt):
                self?.updateDraft { $0.dueAt = dueAt }
            case .clear:
                self?.updateDraft { $0.dueAt = nil }
            }
        }, dismissed: { [weak self] in
            self?.restoreFocus(focus)
        })
    }

    // MARK: Leaving

    /// Cancel (button or VoiceOver escape): a clean editor closes at once, a dirty one asks first.
    private func requestClose() {
        guard !self.isClosing else {
            return
        }
        if self.draft.hasChanges(from: self.original) {
            self.confirmDiscard()
        } else {
            self.close()
        }
    }

    /// Keep Editing leaves the draft untouched; Discard closes without writing anything.
    private func confirmDiscard() {
        guard !self.isClosing, self.discardConfirmation == nil else {
            return
        }
        let returnFocus: TasksTaskEditorFocus? = self.isNodeLoaded && self.editorNode.isEditingTitle ? .title : nil
        self.view.endEditing(true)
        let l10n = self.l10n
        let alert = textAlertController(
            context: self.context,
            title: l10n.tasks_discardChanges_title,
            text: l10n.tasks_discardChanges_text,
            actions: [
                TextAlertAction(type: .genericAction, title: l10n.tasks_discardChanges_keepEditing, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.discardConfirmation = nil
                    guard let returnFocus else {
                        return
                    }
                    // The alert ends editing as it closes, right after this action runs.
                    DispatchQueue.main.async { [weak self] in
                        self?.restoreFocus(returnFocus)
                    }
                }),
                TextAlertAction(type: .destructiveAction, title: l10n.tasks_discardChanges_discard, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.discardConfirmation = nil
                    self.close()
                })
            ],
            // Only an explicit choice closes it, so a stray tap cannot discard or silently keep.
            dismissOnOutsideTap: false
        )
        self.discardConfirmation = alert
        self.present(alert, in: .window(.root))
    }

    private func close() {
        guard !self.isClosing else {
            return
        }
        self.isClosing = true
        self.view.endEditing(true)
        self.dismiss()
    }

    /// Never gated (it edits an existing task). Any refusal keeps the editor open with the draft;
    /// an unchanged draft closes without writing.
    private func save() {
        guard !self.isClosing else {
            return
        }
        if !self.draft.hasChanges(from: self.original) {
            self.close()
            return
        }
        let title: String
        switch tasksValidateTitle(self.draft.title, limit: TasksTitleLimit.task) {
        case .empty:
            return
        case .tooLong:
            self.presentError(self.l10n.tasks_error_titleTooLong(limit: TasksTitleLimit.task))
            return
        case let .valid(validTitle):
            title = validTitle
        }
        guard !self.isReadOnly else {
            return
        }
        do {
            try TodoStorage.updateTaskDetails(id: self.taskId, title: title, assignee: self.draft.assignee, dueAt: self.draft.dueAt, asAccount: self.accountPeerId)
        } catch {
            if let notice = tasksWriteFenceNotice(error, accountPeerId: self.accountPeerId, l10n: self.l10n) {
                if case .archived? = error as? TodoDatabaseError {
                    // The device rows became read-only meanwhile (the account's copy exists): the
                    // draft stays visible, read-only.
                    self.isReadOnly = true
                    if self.isNodeLoaded {
                        self.editorNode.update(readOnly: true)
                    }
                }
                self.presentNotice(notice)
                return
            }
            self.presentError(self.l10n.tasks_error_generic)
            return
        }
        self.saved()
        self.close()
    }

    private func presentError(_ text: String) {
        self.present(tasksErrorAlert(context: self.context, text: text), in: .window(.root))
    }

    /// A transient note (R4 write fence); never an error alert.
    private func presentNotice(_ text: String) {
        self.noticeController?.dismiss()
        let notice = tasksNoticeToast(context: self.context, text: text)
        self.noticeController = notice
        self.present(notice, in: .current)
    }
}

// MARK: - Editor node

private struct TasksTaskEditorActions {
    let titleChanged: (String) -> Void
    let cancel: () -> Void
    let save: () -> Void
    let pickAssignee: () -> Void
    let clearAssignee: () -> Void
    let pickDeadline: () -> Void
    let clearDeadline: () -> Void
}

private enum TasksTaskEditorRow {
    case title
    case assignee
    case removeAssignee
    case deadline
    case removeDeadline
}

private final class TasksTaskEditorNode: ASDisplayNode, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let actions: TasksTaskEditorActions
    private var draft: TasksTaskEditorDraft
    /// Read-only (Eski vazifalar, or the cut-over's fence): no field, picker or Save.
    private var isReadOnly: Bool
    /// wf15 §4.4: the local assignee is an old entry never sent ("(eski yozuv)", the local footer).
    private let marksLegacyAssignee: Bool
    private var presentationData: PresentationData
    private var sections: [[TasksTaskEditorRow]] = []

    private let headerView = UIView()
    private let headerSeparator = UIView()
    private let headerTitleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let titleField = UITextField()
    /// One title cell for the editor's lifetime: reloads never move the field (or its keyboard).
    private let titleCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private var titleFieldMinimumHeight: NSLayoutConstraint?
    private var tableView: UITableView?
    private var validLayout: ContainerViewLayout?

    init(draft: TasksTaskEditorDraft, readOnly: Bool, marksLegacyAssignee: Bool, presentationData: PresentationData, actions: TasksTaskEditorActions) {
        self.draft = draft
        self.isReadOnly = readOnly
        self.marksLegacyAssignee = marksLegacyAssignee
        self.presentationData = presentationData
        self.actions = actions
        super.init()
        self.setViewBlock({
            return TasksTaskEditorRootView()
        })
    }

    override func didLoad() {
        super.didLoad()
        // VoiceOver's two-finger scrub is Cancel (which asks first when there are changes).
        (self.view as? TasksTaskEditorRootView)?.escape = { [weak self] in
            guard let self else {
                return false
            }
            self.actions.cancel()
            return true
        }
        let tableView = UITableView(frame: CGRect(), style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52.0
        tableView.keyboardDismissMode = .interactive
        tableView.contentInsetAdjustmentBehavior = .never
        self.tableView = tableView
        self.view.addSubview(tableView)

        self.titleField.delegate = self
        self.titleField.returnKeyType = .done
        self.titleField.autocapitalizationType = .sentences
        self.titleField.clearButtonMode = .whileEditing
        self.titleField.text = self.draft.title
        self.titleField.accessibilityIdentifier = TasksBoardAccessibilityId.editTitle
        self.titleField.addTarget(self, action: #selector(self.titleChanged), for: .editingChanged)
        self.titleCell.selectionStyle = .none
        self.titleField.translatesAutoresizingMaskIntoConstraints = false
        self.titleCell.contentView.addSubview(self.titleField)
        let titleFieldMinimumHeight = self.titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: tasksMinimumHitSize)
        self.titleFieldMinimumHeight = titleFieldMinimumHeight
        NSLayoutConstraint.activate([
            self.titleField.leadingAnchor.constraint(equalTo: self.titleCell.contentView.layoutMarginsGuide.leadingAnchor),
            self.titleField.trailingAnchor.constraint(equalTo: self.titleCell.contentView.layoutMarginsGuide.trailingAnchor),
            self.titleField.topAnchor.constraint(equalTo: self.titleCell.contentView.topAnchor, constant: 4.0),
            self.titleField.bottomAnchor.constraint(equalTo: self.titleCell.contentView.bottomAnchor, constant: -4.0),
            titleFieldMinimumHeight
        ])

        self.headerTitleLabel.textAlignment = .center
        self.headerTitleLabel.accessibilityTraits = .header
        self.cancelButton.accessibilityIdentifier = TasksBoardAccessibilityId.editCancel
        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)
        self.saveButton.accessibilityIdentifier = TasksBoardAccessibilityId.editSave
        self.saveButton.addTarget(self, action: #selector(self.savePressed), for: .touchUpInside)
        for button in [self.cancelButton, self.saveButton] {
            button.titleLabel?.lineBreakMode = .byTruncatingTail
        }
        for subview in [self.headerTitleLabel, self.cancelButton, self.saveButton, self.headerSeparator] {
            self.headerView.addSubview(subview)
        }
        self.view.addSubview(self.headerView)

        self.applyPresentationData(stringsChanged: true)
    }

    func update(draft: TasksTaskEditorDraft) {
        self.draft = draft
        self.reloadRows(metadataOnly: true)
    }

    /// The device rows became read-only while the editor was open (the draft stays visible).
    func update(readOnly: Bool) {
        self.isReadOnly = readOnly
        guard self.isNodeLoaded else {
            return
        }
        self.view.endEditing(true)
        self.applyPresentationData(stringsChanged: true)
        if let validLayout = self.validLayout {
            self.containerLayoutUpdated(validLayout, transition: .immediate)
        }
    }

    /// True while the title field has the keyboard.
    var isEditingTitle: Bool {
        return self.titleField.isFirstResponder
    }

    /// The title gets the keyboard back; a row gets VoiceOver focus back.
    func restoreFocus(_ focus: TasksTaskEditorFocus) {
        switch focus {
        case .title:
            self.titleField.becomeFirstResponder()
        case .assignee:
            if let section = self.sections.firstIndex(where: { $0.first == .assignee }) {
                self.focusSelectRow(section: section)
            }
        case .deadline:
            if let section = self.sections.firstIndex(where: { $0.first == .deadline }) {
                self.focusSelectRow(section: section)
            }
        }
    }

    /// Re-derives the deadline text ("Today"/"Tomorrow" move with the clock and time zone) without
    /// touching the draft, the title field or its keyboard.
    func refreshDeadlineText() {
        guard self.draft.dueAt != nil, let tableView = self.tableView, let section = self.sections.firstIndex(where: { $0.first == .deadline }), section < tableView.numberOfSections else {
            return
        }
        tableView.reloadRows(at: [IndexPath(row: 0, section: section)], with: .none)
    }

    func update(presentationData: PresentationData) {
        let stringsChanged = self.presentationData.strings !== presentationData.strings
        self.presentationData = presentationData
        guard self.isNodeLoaded else {
            return
        }
        self.applyPresentationData(stringsChanged: stringsChanged)
        if let validLayout = self.validLayout {
            self.containerLayoutUpdated(validLayout, transition: .immediate)
        }
    }

    private var fontSize: CGFloat {
        return self.presentationData.listsFontSize.itemListBaseFontSize
    }

    private var l10n: SGTasksL10n {
        return SGTasksL10n(self.presentationData.strings)
    }

    private func applyPresentationData(stringsChanged: Bool) {
        let theme = self.presentationData.theme
        let strings = self.presentationData.strings
        self.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView?.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView?.separatorColor = theme.list.itemBlocksSeparatorColor
        self.headerView.backgroundColor = theme.rootController.navigationBar.opaqueBackgroundColor
        self.headerSeparator.backgroundColor = theme.rootController.navigationBar.separatorColor
        self.headerTitleLabel.font = Font.semibold(self.fontSize)
        self.headerTitleLabel.textColor = theme.rootController.navigationBar.primaryTextColor
        // Read-only (Eski vazifa): its own title, one Done that closes, no Save.
        self.headerTitleLabel.text = self.isReadOnly ? self.l10n.tasks_older_editorTitle : self.l10n.tasks_editTask_screenTitle
        self.cancelButton.setTitle(self.isReadOnly ? strings.Common_Done : strings.Common_Cancel, for: .normal)
        self.cancelButton.titleLabel?.font = Font.regular(self.fontSize)
        self.saveButton.setTitle(strings.Common_Save, for: .normal)
        self.saveButton.titleLabel?.font = Font.semibold(self.fontSize)
        self.saveButton.isHidden = self.isReadOnly
        self.titleField.isEnabled = !self.isReadOnly
        for button in [self.cancelButton, self.saveButton] {
            button.tintColor = theme.rootController.navigationBar.accentTextColor
        }
        self.titleField.font = Font.regular(self.fontSize)
        self.titleField.textColor = theme.list.itemPrimaryTextColor
        self.titleField.tintColor = theme.list.itemAccentColor
        self.titleField.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
        self.titleField.attributedPlaceholder = NSAttributedString(string: self.l10n.tasks_newTask_placeholder, attributes: [.font: Font.regular(self.fontSize), .foregroundColor: theme.list.itemPlaceholderTextColor])
        self.titleField.accessibilityLabel = self.l10n.tasks_editTask_nameHeader
        self.titleFieldMinimumHeight?.constant = max(tasksMinimumHitSize, ceil(Font.regular(self.fontSize).lineHeight) + 16.0)
        self.titleCell.backgroundColor = theme.list.itemBlocksBackgroundColor
        // A theme or font change keeps the title section (and the keyboard); only new strings need
        // the section header rebuilt.
        self.reloadRows(metadataOnly: !stringsChanged)
    }

    /// `metadataOnly` reloads just the assignee/deadline sections. A full reload keeps the title
    /// field's keyboard if it had it.
    private func reloadRows(metadataOnly: Bool = false) {
        self.sections = [
            [.title],
            self.draft.assignee == nil || self.isReadOnly ? [.assignee] : [.assignee, .removeAssignee],
            self.draft.dueAt == nil || self.isReadOnly ? [.deadline] : [.deadline, .removeDeadline]
        ]
        self.updateSaveEnabled()
        guard let tableView = self.tableView else {
            return
        }
        if metadataOnly && tableView.numberOfSections == self.sections.count {
            tableView.reloadSections(IndexSet(integersIn: 1 ..< self.sections.count), with: .automatic)
        } else {
            let wasEditingTitle = self.titleField.isFirstResponder
            tableView.reloadData()
            if wasEditingTitle && !self.titleField.isFirstResponder {
                tableView.layoutIfNeeded()
                self.titleField.becomeFirstResponder()
            }
        }
    }

    /// After a remove row disappears, VoiceOver focus moves to the select row of the same section.
    private func focusSelectRow(section: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let tableView = self.tableView, section < tableView.numberOfSections else {
                return
            }
            let cell = tableView.cellForRow(at: IndexPath(row: 0, section: section))
            UIAccessibility.post(notification: .layoutChanged, argument: cell)
        }
    }

    private func updateSaveEnabled() {
        self.saveButton.isEnabled = tasksValidateTitle(self.draft.title, limit: TasksTitleLimit.task) != .empty
    }

    // MARK: Layout

    private static func headerHeight(fontSize: CGFloat) -> CGFloat {
        return max(56.0, ceil(Font.semibold(fontSize).lineHeight) + 24.0)
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout
        guard let tableView = self.tableView else {
            return
        }
        let insets = layout.insets(options: [.statusBar, .input])
        let size = layout.size
        let headerHeight = TasksTaskEditorNode.headerHeight(fontSize: self.fontSize)
        let headerFrame = CGRect(x: 0.0, y: 0.0, width: size.width, height: insets.top + headerHeight)
        transition.updateFrame(view: self.headerView, frame: headerFrame)

        let sideInset: CGFloat = 8.0
        let left = layout.safeInsets.left + sideInset
        let right = layout.safeInsets.right + sideInset
        let buttonWidth = min(140.0, max(tasksMinimumHitSize, floor(size.width * 0.28)))
        let buttonY = insets.top + floor((headerHeight - tasksMinimumHitSize) / 2.0)
        self.cancelButton.frame = CGRect(x: left, y: buttonY, width: buttonWidth, height: tasksMinimumHitSize)
        self.cancelButton.contentHorizontalAlignment = .leading
        self.saveButton.frame = CGRect(x: size.width - right - buttonWidth, y: buttonY, width: buttonWidth, height: tasksMinimumHitSize)
        self.saveButton.contentHorizontalAlignment = .trailing
        let titleX = self.cancelButton.frame.maxX + 8.0
        self.headerTitleLabel.frame = CGRect(x: titleX, y: insets.top, width: max(0.0, self.saveButton.frame.minX - 8.0 - titleX), height: headerHeight)
        self.headerSeparator.frame = CGRect(x: 0.0, y: headerFrame.height - UIScreenPixel, width: size.width, height: UIScreenPixel)

        let tableFrame = CGRect(x: 0.0, y: headerFrame.maxY, width: size.width, height: max(0.0, size.height - headerFrame.maxY))
        transition.updateFrame(view: tableView, frame: tableFrame)
        // The keyboard (or the home indicator) covers the table's bottom; scroll content above it.
        let tableInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: insets.bottom, right: 0.0)
        if tableView.contentInset != tableInsets {
            tableView.contentInset = tableInsets
            tableView.scrollIndicatorInsets = tableInsets
        }
    }

    // MARK: Actions

    @objc private func titleChanged() {
        self.draft.title = self.titleField.text ?? ""
        self.actions.titleChanged(self.draft.title)
        self.updateSaveEnabled()
    }

    /// The controller ends editing itself, after noting whether the title had the keyboard.
    @objc private func cancelPressed() {
        self.actions.cancel()
    }

    @objc private func savePressed() {
        self.view.endEditing(true)
        self.actions.save()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        let updated = (current as NSString).replacingCharacters(in: range, with: string)
        return tasksAcceptsDraftEdit(current: current, updated: updated)
    }

    // MARK: UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return self.sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.sections[section].count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? self.l10n.tasks_editTask_nameHeader : nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == self.sections.count - 1 else {
            return nil
        }
        if self.isReadOnly {
            return self.l10n.tasks_older_readOnly
        }
        // wf15 §4.4: an old local assignee was never sent; assigning now needs sync. S1 (today's
        // local assignee of a build without a Tasks backend) says nothing, and so does a task that
        // has no assignee: the sentence is about "this assignee".
        return self.marksLegacyAssignee && self.draft.assignee != nil ? self.l10n.tasks_metadata_localFooter : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let theme = self.presentationData.theme
        let l10n = self.l10n
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = theme.list.itemBlocksBackgroundColor
        let highlight = UIView()
        highlight.backgroundColor = theme.list.itemHighlightedBackgroundColor
        cell.selectedBackgroundView = highlight
        let font = Font.regular(self.fontSize)
        cell.textLabel?.font = font
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = font
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.textColor = theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = theme.list.itemSecondaryTextColor
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: self.fontSize, weight: .regular)

        switch self.sections[indexPath.section][indexPath.row] {
        case .title:
            return self.titleCell
        case .assignee:
            let value = self.draft.assignee.map { assignee -> String in
                let name = tasksIsolatedDisplayText(assignee.displayName)
                return self.marksLegacyAssignee ? name + " " + l10n.tasks_assign_oldEntry : name
            }
            self.configureValueCell(cell, symbolName: "person.crop.circle", symbolConfiguration: symbolConfiguration, title: l10n.tasks_assignee_title, value: value, hint: l10n.tasks_a11y_pickAssigneeHint, identifier: TasksBoardAccessibilityId.editAssignee)
        case .deadline:
            let value = self.draft.dueAt.map { l10n.tasks_deadline_text($0, use24HourClock: self.presentationData.dateTimeFormat.timeFormat == .military) }
            self.configureValueCell(cell, symbolName: "calendar", symbolConfiguration: symbolConfiguration, title: l10n.tasks_deadline_title, value: value, hint: l10n.tasks_a11y_pickDeadlineHint, identifier: TasksBoardAccessibilityId.editDeadline)
        case .removeAssignee:
            self.configureRemoveCell(cell, title: l10n.tasks_assignee_remove, identifier: TasksBoardAccessibilityId.editAssigneeClear)
        case .removeDeadline:
            self.configureRemoveCell(cell, title: l10n.tasks_deadline_remove, identifier: TasksBoardAccessibilityId.editDeadlineClear)
        }
        return cell
    }

    private func configureValueCell(_ cell: UITableViewCell, symbolName: String, symbolConfiguration: UIImage.SymbolConfiguration, title: String, value: String?, hint: String, identifier: String) {
        let l10n = self.l10n
        cell.imageView?.image = UIImage(systemName: symbolName, withConfiguration: symbolConfiguration)
        cell.imageView?.tintColor = self.presentationData.theme.list.itemAccentColor
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = value ?? l10n.tasks_metadata_none
        // Read-only (R4 archive): a value, not a control.
        cell.accessoryType = self.isReadOnly ? .none : .disclosureIndicator
        cell.selectionStyle = self.isReadOnly ? .none : .default
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = self.isReadOnly ? .staticText : .button
        cell.accessibilityLabel = title
        cell.accessibilityValue = value ?? l10n.tasks_metadata_none
        cell.accessibilityHint = self.isReadOnly ? nil : hint
        cell.accessibilityIdentifier = identifier
    }

    private func configureRemoveCell(_ cell: UITableViewCell, title: String, identifier: String) {
        cell.textLabel?.text = title
        cell.textLabel?.textColor = self.presentationData.theme.list.itemDestructiveColor
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .button
        cell.accessibilityLabel = title
        cell.accessibilityIdentifier = identifier
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if self.isReadOnly {
            return false
        }
        if case .title = self.sections[indexPath.section][indexPath.row] {
            return false
        }
        return true
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !self.isReadOnly else {
            return
        }
        switch self.sections[indexPath.section][indexPath.row] {
        case .title:
            self.titleField.becomeFirstResponder()
        case .assignee:
            self.actions.pickAssignee()
        case .removeAssignee:
            self.actions.clearAssignee()
            self.focusSelectRow(section: indexPath.section)
        case .deadline:
            self.actions.pickDeadline()
        case .removeDeadline:
            self.actions.clearDeadline()
            self.focusSelectRow(section: indexPath.section)
        }
    }
}

private final class TasksTaskEditorRootView: UIView {
    var escape: (() -> Bool)?

    override func accessibilityPerformEscape() -> Bool {
        return self.escape?() ?? false
    }
}
