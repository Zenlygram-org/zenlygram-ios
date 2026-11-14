import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — synced Tasks board display node: list chips, the task table (status cards above, open
// tasks, completed disclosure, the privacy note) and the quick-add composer. The presenter owns the
// repository and state; this node only renders `TasksCloudBoardState`. The same node draws the
// read-only "Sinxronlangan nusxa" view (`TasksCloudBoardState.isSyncedCopy`: own rows, no status
// cards, the synced-copy footer).
//
// R4 (design 30 §5.6): a consent hold (`TasksCloudBoardState.readOnlyReason`) keeps the cached board
// visible but read-only — no composer, no completion, swipe or removal; rows open read-only — and
// says why in its banner. Automatic-resolution notices are cards like the R3 notices. No glyph here
// names a cloud (wf15 F19, §15.4 rule a): the gate and the unavailable banner use the warning
// triangle, the offline banner the crossed-out wifi. The host node may reserve a footer strip above
// the composer for the single board's status line.
//
// wf15 §5.2: the tasks assigned to the user sit in their own section, "Menga topshirilgan", whose
// header (`sgtasks.assigned.header`) is drawn only while the section has a row: the accepted rows
// (subtitle "Topshirdi: Ism") and the provisional rows of a queued automatic accept (the same
// subtitle, the status "Sinxronlash tasdigʻi kutilmoqda", no completion, opens a read-only preview).

extension TasksCloudAccessibilityId {
    /// wf15 §5.2: the "Menga topshirilgan" section header.
    static let assignedHeader = "sgtasks.assigned.header"
}

/// The "Menga topshirilgan" section header: a grouped-table header line (UIKit aligns a
/// header-footer view's content with the inset groups) that is one accessibility element (a
/// header), so the rows under it are found "under `sgtasks.assigned.header`". Wraps at any text size.
private final class TasksCloudSectionHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "TasksCloudSectionHeaderView"

    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        self.label.numberOfLines = 0
        self.label.lineBreakMode = .byWordWrapping
        self.label.translatesAutoresizingMaskIntoConstraints = false
        self.label.isAccessibilityElement = true
        self.label.accessibilityTraits = .header
        self.contentView.addSubview(self.label)
        NSLayoutConstraint.activate([
            self.label.leadingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.leadingAnchor),
            self.label.trailingAnchor.constraint(lessThanOrEqualTo: self.contentView.layoutMarginsGuide.trailingAnchor),
            self.label.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 16.0),
            self.label.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -6.0)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, identifier: String, font: UIFont, color: UIColor) {
        self.label.text = title
        self.label.font = font
        self.label.textColor = color
        self.label.accessibilityIdentifier = identifier
        self.label.accessibilityLabel = title
    }
}

struct TasksCloudBoardInteraction {
    let selectFilter: (TasksBoardFilter) -> Void
    let createList: () -> Void
    let toggleCompletedSection: () -> Void
    /// setCompleted = complete/reopen to an explicit target (owner or accepted recipient); edit =
    /// editor or read-only view (always offered, it explains missing access); delete = the row's
    /// removal (owner: delete with Undo; accepted recipient: confirmed Leave). Completion and removal
    /// carry the `TasksCloudTaskPermissions` the row was drawn under.
    let rowActions: TasksRowActions
    /// Returns true once the task is saved on this device (the composer then clears its draft).
    let submitQuickAdd: (String) -> Bool
    /// The composer's assignee (the owner-only annotation of the task to be created) and deadline
    /// controls; the presenter owns the draft values, as the device board's controller does.
    let pickQuickAddAssignee: () -> Void
    let clearQuickAddAssignee: () -> Void
    let pickQuickAddDeadline: () -> Void
    let clearQuickAddDeadline: () -> Void
    let openLinkAccount: () -> Void
    let retrySync: () -> Void
    let openUnsentChanges: () -> Void
    let openInvitations: () -> Void
    let dismissNotice: (Int64) -> Void
    /// wf15 §5.6: the name shown for a row's Masʼul (the viewer's contact name, the mapped device
    /// row's or the annotation's owner-entered name, else the numeric id), already isolated. nil
    /// (the read-only Sinxronlangan nusxa) skips the contact lookup and keeps the other fallbacks.
    var assigneeName: ((TasksAssigneeDisplay) -> String)? = nil
    /// wf15 §5.6: the viewer's contact name for the sender of an assigned or provisional row (the
    /// raw Telegram id), already isolated; nil = not a contact (the row shows the numeric id).
    var senderName: ((String) -> String?)? = nil
    /// wf15 §5.2: a provisional row was tapped (its invitation id): the read-only preview.
    var openProvisional: (String) -> Void = { _ in }
    /// The List / Calendar header switched to Calendar (analytics).
    let calendarShown: () -> Void
}

final class TasksCloudBoardNode: ASDisplayNode, UITableViewDataSource, UITableViewDelegate {
    private let interaction: TasksCloudBoardInteraction
    private var presentationData: PresentationData
    private var state: TasksCloudBoardState
    private var sections: [[TasksCloudBoardRow]] = []
    private var quickAddDueAt: Int32?
    /// The composer's chosen assignee (display name only; the presenter holds the draft).
    private var quickAddAssigneeName: String?

    private var tableView: UITableView?
    private let filterBar = TasksFilterBarView()
    private let composer = TasksComposerView()
    /// List / Calendar header and selected day of the cloud board, independent of the device board's.
    private let calendarCoordinator = TasksBoardCalendarCoordinator()

    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat, footerHeight: CGFloat)?

    private(set) var bottomOccupiedHeight: CGFloat = 0.0

    init(state: TasksCloudBoardState, quickAddDueAt: Int32?, quickAddAssigneeName: String?, presentationData: PresentationData, interaction: TasksCloudBoardInteraction) {
        self.state = state
        self.quickAddDueAt = quickAddDueAt
        self.quickAddAssigneeName = quickAddAssigneeName
        self.presentationData = presentationData
        self.interaction = interaction
        super.init()

        self.filterBar.selectFilter = interaction.selectFilter
        self.filterBar.createList = interaction.createList
        self.composer.submit = interaction.submitQuickAdd
        self.composer.pickAssignee = interaction.pickQuickAddAssignee
        self.composer.clearAssignee = interaction.clearQuickAddAssignee
        self.composer.pickDeadline = interaction.pickQuickAddDeadline
        self.composer.clearDeadline = interaction.clearQuickAddDeadline
        self.calendarCoordinator.contentChanged = { [weak self] in
            self?.reloadContent()
        }
        self.calendarCoordinator.calendarShown = interaction.calendarShown
    }

    override func didLoad() {
        super.didLoad()

        let tableView = UITableView(frame: CGRect(), style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52.0
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.register(TasksTaskCell.self, forCellReuseIdentifier: TasksTaskCell.reuseIdentifier)
        tableView.register(TasksCompletedHeaderCell.self, forCellReuseIdentifier: TasksCompletedHeaderCell.reuseIdentifier)
        tableView.register(TasksEmptyCell.self, forCellReuseIdentifier: TasksEmptyCell.reuseIdentifier)
        tableView.register(TasksCloudCardCell.self, forCellReuseIdentifier: TasksCloudCardCell.reuseIdentifier)
        tableView.register(TasksCloudDisclosureCell.self, forCellReuseIdentifier: TasksCloudDisclosureCell.reuseIdentifier)
        tableView.register(TasksCloudSectionHeaderView.self, forHeaderFooterViewReuseIdentifier: TasksCloudSectionHeaderView.reuseIdentifier)
        // The "Menga topshirilgan" header is self-sizing (its text wraps); every other header returns
        // an explicit height.
        tableView.estimatedSectionHeaderHeight = 40.0
        self.tableView = tableView
        self.calendarCoordinator.attach(to: tableView)

        self.view.addSubview(tableView)
        self.view.addSubview(self.filterBar)
        self.view.addSubview(self.composer)

        self.applyPresentationData()
        self.reloadContent()
    }

    // MARK: - Updates

    func update(state: TasksCloudBoardState) {
        let wasUsable = self.state.isUsable
        let couldCompose = self.state.canCompose
        self.state = state
        if couldCompose && !state.canCompose && self.isNodeLoaded {
            // The composer goes away with its draft intact; the keyboard must not stay up for it.
            self.view.endEditing(true)
        }
        self.reloadContent()
        if wasUsable != state.isUsable || couldCompose != state.canCompose, let validLayout = self.validLayout {
            self.containerLayoutUpdated(validLayout.layout, navigationHeight: validLayout.navigationHeight, footerHeight: validLayout.footerHeight, transition: .immediate)
        }
    }

    /// wf15 §3.3: the device composer's typed title, carried over when the board flips from the
    /// device rows to the synced board (S5 → S7).
    func setQuickAddDraftTitle(_ title: String) {
        guard self.isNodeLoaded else {
            return
        }
        self.composer.textField.text = title
        self.composer.textField.sendActions(for: .editingChanged)
    }

    func updateQuickAddDueAt(_ dueAt: Int32?) {
        self.quickAddDueAt = dueAt
        if self.isNodeLoaded {
            self.updateComposer(l10n: SGTasksL10n(self.presentationData.strings))
        }
    }

    /// Shows the composer's chosen assignee (nil: none). A chosen name can change the composer's
    /// height: the presenter requests a layout afterwards, as for the deadline.
    func updateQuickAddAssigneeName(_ name: String?) {
        self.quickAddAssigneeName = name
        if self.isNodeLoaded {
            self.updateComposer(l10n: SGTasksL10n(self.presentationData.strings))
        }
    }

    var isEditingQuickAddTitle: Bool {
        return self.isNodeLoaded && self.composer.isEditingTitle
    }

    /// More contact names arrived: the Masʼul lines are rendered again from the same state.
    func reloadAssigneeNames() {
        self.reloadContent()
    }

    func focusQuickAddTitle() {
        self.composer.focusTitle()
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        guard self.isNodeLoaded else {
            return
        }
        self.applyPresentationData()
        self.reloadContent()
        if let validLayout = self.validLayout {
            self.containerLayoutUpdated(validLayout.layout, navigationHeight: validLayout.navigationHeight, footerHeight: validLayout.footerHeight, transition: .immediate)
        }
    }

    private var fontSize: CGFloat {
        return self.presentationData.listsFontSize.itemListBaseFontSize
    }

    private func deadlineText(_ dueAt: Int32?, l10n: SGTasksL10n) -> String? {
        return dueAt.map { l10n.tasks_deadline_text($0, use24HourClock: self.presentationData.dateTimeFormat.timeFormat == .military) }
    }

    private func applyPresentationData() {
        let theme = self.presentationData.theme
        self.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView?.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView?.separatorColor = theme.list.itemBlocksSeparatorColor
        self.tableView?.indicatorStyle = theme.overallDarkAppearance ? .white : .black
    }

    private func reloadContent() {
        guard self.isNodeLoaded else {
            return
        }
        let l10n = SGTasksL10n(self.presentationData.strings)
        // A gated board (no service, no storage) shows only its gate: no calendar header, no markers.
        // Before the first complete snapshot the cloud tasks may not all be here: no counts are claimed.
        let calendar = l10n.tasks_deadlineCalendar
        let now = Date()
        self.calendarCoordinator.update(dueDates: self.state.calendarDueDates, countsComplete: self.state.cloud.hasCompleteSnapshot, isAvailable: self.state.isUsable, presentationData: self.presentationData, calendar: calendar, now: now)
        if self.calendarCoordinator.isCalendarShown {
            self.sections = self.state.calendarSections(filter: self.calendarCoordinator.filter(calendar: calendar, now: now), calendar: calendar)
        } else {
            self.sections = self.state.sections
        }
        self.tableView?.reloadData()
        self.filterBar.update(chips: self.state.chips, l10n: l10n, theme: self.presentationData.theme, fontSize: self.fontSize)
        self.updateComposer(l10n: l10n)
    }

    private func updateComposer(l10n: SGTasksL10n) {
        let placeholder: String
        if let list = self.state.selectedList {
            // A user-named list inside a sentence: isolated so it cannot reorder the surrounding text.
            placeholder = l10n.tasks_quickAdd_placeholderInList(tasksIsolatedDisplayText(list.title))
        } else {
            placeholder = l10n.tasks_quickAdd_placeholderInList(l10n.tasks_cloud_inbox_title)
        }
        // A contact's name is external text: isolated so it cannot reorder neighbouring text.
        let metadata = TasksComposerMetadata(assigneeName: self.quickAddAssigneeName.map { tasksIsolatedDisplayText($0) }, deadlineText: self.deadlineText(self.quickAddDueAt, l10n: l10n))
        self.composer.update(placeholder: placeholder, submitTitle: l10n.tasks_quickAdd_submit, doneTitle: self.presentationData.strings.Common_Done, metadata: metadata, assigneeHint: l10n.tasks_a11y_pickAssigneeHint, l10n: l10n, theme: self.presentationData.theme, fontSize: self.fontSize)
    }

    /// After quick add. In Calendar mode a task outside the selected day first switches to its own day
    /// (or No Deadline), so it never vanishes; its deadline is left as it is.
    func reveal(taskId: String) {
        guard let tableView = self.tableView else {
            return
        }
        if let task = self.state.task(id: taskId), self.calendarCoordinator.reveal(dueAt: task.dueAt, calendar: SGTasksL10n(self.presentationData.strings).tasks_deadlineCalendar, now: Date()) {
            self.reloadContent()
        }
        for (sectionIndex, rows) in self.sections.enumerated() {
            if let rowIndex = rows.firstIndex(of: .task(id: taskId)) {
                tableView.layoutIfNeeded()
                tableView.scrollToRow(at: IndexPath(row: rowIndex, section: sectionIndex), at: .none, animated: true)
                return
            }
        }
    }

    func scrollToTop() {
        guard let tableView = self.tableView else {
            return
        }
        tableView.setContentOffset(CGPoint(x: 0.0, y: -tableView.contentInset.top), animated: true)
    }

    // MARK: - Layout

    /// `footerHeight`: a strip the host keeps free between the table and the composer (the single
    /// board's status line); 0 when there is none.
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, footerHeight: CGFloat = 0.0, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationHeight, footerHeight)
        guard let tableView = self.tableView else {
            return
        }
        let size = layout.size
        let horizontalInsets = (left: layout.safeInsets.left, right: layout.safeInsets.right)
        let bottomInset = max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0.0)
        let availableHeight = max(0.0, size.height - bottomInset - navigationHeight)

        // A gated board (no service, no storage) has no lists to filter and nothing to add to; a
        // read-only one (R4 consent hold, the synced copy) keeps its filters but takes no new task.
        let isUsable = self.state.isUsable
        let showsComposer = self.state.canCompose
        self.composer.isHidden = !showsComposer
        self.composer.accessibilityElementsHidden = !showsComposer
        self.composer.horizontalInsets = horizontalInsets
        let composerHeight = showsComposer ? self.composer.preferredHeight(width: size.width) : 0.0

        let filterHeight = TasksFilterBarView.height(fontSize: self.fontSize)
        let hidesFilter = !isUsable || filterHeight + composerHeight + footerHeight + tasksMinimumHitSize > availableHeight
        self.filterBar.isHidden = hidesFilter
        self.filterBar.accessibilityElementsHidden = hidesFilter
        let filterFrame = CGRect(x: 0.0, y: navigationHeight, width: size.width, height: hidesFilter ? 0.0 : filterHeight)
        self.filterBar.horizontalInsets = horizontalInsets
        transition.updateFrame(view: self.filterBar, frame: filterFrame)

        let composerFrameHeight = min(composerHeight, availableHeight)
        let composerY = size.height - bottomInset - composerFrameHeight
        let composerFrame = CGRect(x: 0.0, y: composerY, width: size.width, height: composerFrameHeight)
        self.bottomOccupiedHeight = size.height - composerY
        transition.updateFrame(view: self.composer, frame: composerFrame)

        // The host's footer strip (status line) sits between the table and the composer.
        let tableFrame = CGRect(x: 0.0, y: filterFrame.maxY, width: size.width, height: max(0.0, composerFrame.minY - footerHeight - filterFrame.maxY))
        transition.updateFrame(view: tableView, frame: tableFrame)
        // The header scrolls with the rows: it never takes room from the composer or the keyboard.
        self.calendarCoordinator.headerView.horizontalInsets = horizontalInsets
        self.calendarCoordinator.layoutHeader()
        let tableInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 8.0, right: 0.0)
        if tableView.contentInset != tableInsets {
            tableView.contentInset = tableInsets
        }
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return self.sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.sections[section].count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let theme = self.presentationData.theme
        let l10n = SGTasksL10n(self.presentationData.strings)
        switch self.sections[indexPath.section][indexPath.row] {
        case let .gate(gate):
            return self.cardCell(tableView, indexPath: indexPath) { cell in
                self.configureGate(cell, gate: gate, l10n: l10n)
            }
        case let .banner(banner):
            return self.cardCell(tableView, indexPath: indexPath) { cell in
                self.configureBanner(cell, banner: banner, l10n: l10n)
            }
        case let .notice(id, kind):
            return self.cardCell(tableView, indexPath: indexPath) { cell in
                let text: String
                switch kind {
                case .sharedAccessLost:
                    text = l10n.tasks_cloud_notice_removed
                case .ownResourceMissing:
                    // The user's own change met a task or list of theirs that no longer exists (deleted
                    // on another device): not "a task assigned to you". The change waits in Unsent Changes.
                    text = l10n.tasks_cloud_error_gone
                case .importFolderBlocked:
                    text = l10n.tasks_cloud_notice_importBlocked
                }
                var actions: [TasksCloudCardAction] = []
                if kind == .importFolderBlocked || kind == .ownResourceMissing {
                    actions.append(TasksCloudCardAction(title: l10n.tasks_cloud_status_review, identifier: TasksCloudAccessibilityId.action("noticeReview"), isPrimary: true, action: self.interaction.openUnsentChanges))
                }
                actions.append(TasksCloudCardAction(title: self.presentationData.strings.Common_OK, identifier: TasksCloudAccessibilityId.action("noticeDismiss"), isPrimary: false, action: { [weak self] in
                    self?.interaction.dismissNotice(id)
                }))
                cell.configure(symbolName: "info.circle", title: nil, text: text, actions: actions, identifier: TasksCloudAccessibilityId.notice(id), isPlain: false, theme: theme, fontSize: self.fontSize)
            }
        case let .resolutionNotice(id, kind):
            return self.cardCell(tableView, indexPath: indexPath) { cell in
                let text: String
                var actions: [TasksCloudCardAction] = []
                switch kind {
                case .deleteKept:
                    text = l10n.tasks_cloud_notice_deleteKept
                case let .changedElsewhere(fields):
                    // That part of the edit waits for a choice in Unsent Changes.
                    text = l10n.tasks_cloud_conflict_fields(l10n.tasks_cloud_fieldList(fields))
                    actions.append(TasksCloudCardAction(title: l10n.tasks_cloud_status_review, identifier: TasksCloudAccessibilityId.action("noticeReview"), isPrimary: true, action: self.interaction.openUnsentChanges))
                }
                actions.append(TasksCloudCardAction(title: self.presentationData.strings.Common_OK, identifier: TasksCloudAccessibilityId.action("noticeDismiss"), isPrimary: false, action: { [weak self] in
                    self?.interaction.dismissNotice(id)
                }))
                cell.configure(symbolName: "info.circle", title: nil, text: text, actions: actions, identifier: TasksCloudAccessibilityId.notice(id), isPlain: false, theme: theme, fontSize: self.fontSize)
            }
        case let .unsent(pending, attention):
            let cell = tableView.dequeueReusableCell(withIdentifier: TasksCloudDisclosureCell.reuseIdentifier, for: indexPath) as! TasksCloudDisclosureCell
            let title = attention > 0 ? l10n.tasks_cloud_status_issues(attention) : l10n.tasks_cloud_status_pending(pending)
            cell.configure(symbolName: attention > 0 ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath", title: title, hint: l10n.tasks_cloud_issues_title, identifier: TasksCloudAccessibilityId.unsent, theme: theme, fontSize: self.fontSize, activate: self.interaction.openUnsentChanges)
            return cell
        case let .invitations(count):
            let cell = tableView.dequeueReusableCell(withIdentifier: TasksCloudDisclosureCell.reuseIdentifier, for: indexPath) as! TasksCloudDisclosureCell
            // Count 0: no invitation waits, the row is kept for the blocked senders' Unblock.
            cell.configure(symbolName: count > 0 ? "envelope.badge" : "envelope", title: count > 0 ? l10n.tasks_cloud_invitations_banner(count) : l10n.tasks_cloud_invitations_title, hint: l10n.tasks_cloud_invitations_title, identifier: TasksCloudAccessibilityId.invitations, theme: theme, fontSize: self.fontSize, activate: self.interaction.openInvitations)
            return cell
        case .privacyNote:
            return self.cardCell(tableView, indexPath: indexPath) { cell in
                cell.configure(symbolName: nil, title: nil, text: l10n.tasks_cloud_privacyFooter, actions: [], identifier: TasksCloudAccessibilityId.privacy, isPlain: true, theme: theme, fontSize: self.fontSize)
            }
        case .syncedCopyNote:
            return self.cardCell(tableView, indexPath: indexPath) { cell in
                cell.configure(symbolName: nil, title: nil, text: l10n.tasks_syncedCopy_footer, actions: [], identifier: TasksCloudAccessibilityId.syncedCopy, isPlain: true, theme: theme, fontSize: self.fontSize)
            }
        case let .emptyMessage(kind):
            let cell = tableView.dequeueReusableCell(withIdentifier: TasksEmptyCell.reuseIdentifier, for: indexPath) as! TasksEmptyCell
            if let texts = self.calendarCoordinator.emptyTexts(kind: kind, l10n: l10n) {
                cell.configure(title: texts.0, text: texts.1, theme: theme, fontSize: self.fontSize)
                return cell
            }
            switch kind {
            case .allDone:
                cell.configure(title: l10n.tasks_empty_allDone_title, text: l10n.tasks_empty_allDone_text, theme: theme, fontSize: self.fontSize)
            case .noTasks:
                let text = self.state.filter == .all ? l10n.tasks_empty_noTasks_text : l10n.tasks_empty_listEmpty_text
                cell.configure(title: l10n.tasks_empty_noTasks_title, text: text, theme: theme, fontSize: self.fontSize)
            }
            return cell
        case let .completedHeader(count, isExpanded):
            let cell = tableView.dequeueReusableCell(withIdentifier: TasksCompletedHeaderCell.reuseIdentifier, for: indexPath) as! TasksCompletedHeaderCell
            cell.configure(count: count, isExpanded: isExpanded, theme: theme, l10n: l10n, fontSize: self.fontSize, toggle: self.interaction.toggleCompletedSection)
            return cell
        case let .task(id):
            let cell = tableView.dequeueReusableCell(withIdentifier: TasksTaskCell.reuseIdentifier, for: indexPath) as! TasksTaskCell
            if let task = self.state.task(id: id) {
                cell.configure(model: self.rowModel(self.state.display(task), access: self.rowAccess(task), l10n: l10n), actions: self.interaction.rowActions, theme: theme, strings: self.presentationData.strings, fontSize: self.fontSize)
            }
            return cell
        case let .provisionalTask(invitationId):
            let cell = tableView.dequeueReusableCell(withIdentifier: TasksTaskCell.reuseIdentifier, for: indexPath) as! TasksTaskCell
            if let provisional = self.state.provisionalTask(invitationId: invitationId) {
                cell.configure(model: self.provisionalRowModel(provisional, l10n: l10n), actions: self.interaction.rowActions, theme: theme, strings: self.presentationData.strings, fontSize: self.fontSize)
            }
            return cell
        }
    }

    /// wf15 §5.6: "Topshirdi: Ism" for the sender of a row assigned to the user — the viewer's own
    /// contact name, else the numeric "Telegram foydalanuvchisi N" (never a sender-chosen name).
    private func assignedByLine(ownerTelegramId: String, l10n: SGTasksL10n) -> String {
        let name = self.interaction.senderName?(ownerTelegramId) ?? l10n.tasks_cloud_telegramUser(ownerTelegramId)
        return l10n.tasks_assigned_by(name)
    }

    /// wf15 §5.2: a provisional "Menga topshirilgan" row from the invitation preview — the title,
    /// the deadline, the sender and the status "Sinxronlash tasdigʻi kutilmoqda". No access: the
    /// completion control is disabled, no swipe, no menu; the row opens a read-only preview. It
    /// carries the task's id, which the accepted row keeps when it arrives in its place.
    private func provisionalRowModel(_ provisional: TasksCloudProvisionalTask, l10n: SGTasksL10n) -> TasksTaskRowModel {
        return TasksTaskRowModel(
            taskId: provisional.taskId.rawValue,
            title: provisional.title,
            isCompleted: false,
            listTitle: self.assignedByLine(ownerTelegramId: provisional.ownerTgId.rawValue, l10n: l10n),
            assigneeName: nil,
            deadlineText: self.deadlineText(provisional.dueAt, l10n: l10n),
            cloudAccess: TasksCloudTaskPermissions(task: nil),
            statusText: l10n.tasks_cloud_syncConfirmationPending,
            removalTitle: nil,
            openHint: l10n.tasks_cloud_a11y_openHint
        )
    }

    private func cardCell(_ tableView: UITableView, indexPath: IndexPath, configure: (TasksCloudCardCell) -> Void) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TasksCloudCardCell.reuseIdentifier, for: indexPath) as! TasksCloudCardCell
        configure(cell)
        return cell
    }

    /// The two gate cards left (wf15 §3.2): no Tasks service in this build, no cloud storage. Neither
    /// offers a way to another board — there is one board — and the glyph is the warning triangle.
    private func configureGate(_ cell: TasksCloudCardCell, gate: TasksCloudGate, l10n: SGTasksL10n) {
        let text: String
        let actions: [TasksCloudCardAction]
        switch gate {
        case .notConfigured:
            text = l10n.tasks_cloud_notConfigured_text
            actions = []
        case .storageUnavailable:
            text = l10n.tasks_error_generic
            actions = [TasksCloudCardAction(title: l10n.tasks_cloud_status_retry, identifier: TasksCloudAccessibilityId.action("retry"), isPrimary: true, action: self.interaction.retrySync)]
        }
        cell.configure(symbolName: "exclamationmark.triangle", title: l10n.tasks_cloud_unavailable_title, text: text, actions: actions, identifier: TasksCloudAccessibilityId.gate, isPlain: false, theme: self.presentationData.theme, fontSize: self.fontSize)
    }

    private func configureBanner(_ cell: TasksCloudCardCell, banner: TasksCloudBanner, l10n: SGTasksL10n) {
        let retry = TasksCloudCardAction(title: l10n.tasks_cloud_status_retry, identifier: TasksCloudAccessibilityId.action("retry"), isPrimary: true, action: self.interaction.retrySync)
        let link = TasksCloudCardAction(title: l10n.tasks_cloud_link_action, identifier: TasksCloudAccessibilityId.action("link"), isPrimary: true, action: self.interaction.openLinkAccount)
        let symbol: String
        let title: String?
        let text: String
        let actions: [TasksCloudCardAction]
        switch banner {
        case .loading:
            symbol = "arrow.triangle.2.circlepath"
            title = nil
            text = l10n.tasks_cloud_status_loading
            actions = []
        case .paused:
            symbol = "pause.circle"
            title = l10n.tasks_cloud_paused_title
            text = l10n.tasks_cloud_paused_text
            actions = [link]
        case .notSignedIn:
            symbol = "person.crop.circle.badge.questionmark"
            title = l10n.tasks_cloud_paused_title
            text = l10n.tasks_cloud_notSignedIn_text
            actions = [link]
        case .sessionInvalid:
            symbol = "person.crop.circle.badge.exclamationmark"
            title = l10n.tasks_cloud_paused_title
            text = l10n.tasks_cloud_status_sessionProblem
            actions = [link]
        case .offline:
            symbol = "wifi.slash"
            title = nil
            text = l10n.tasks_cloud_status_offline
            actions = [retry]
        case .unavailable:
            symbol = "exclamationmark.triangle"
            title = nil
            text = l10n.tasks_cloud_status_unavailable
            actions = [retry]
        case let .rateLimited(seconds):
            symbol = "hourglass"
            title = nil
            text = l10n.tasks_cloud_status_rateLimited(seconds: seconds)
            actions = []
        case let .consentRequired(withdrawn):
            // Consent is the customer layer's (Data & consent); nothing here can turn it on.
            symbol = "hand.raised"
            title = nil
            text = withdrawn ? l10n.tasks_cloud_withdrawn : l10n.tasks_cloud_consentOff
            actions = []
        case .consentFenced:
            symbol = "pause.circle"
            title = nil
            text = l10n.tasks_cloud_consentFenced
            actions = []
        }
        cell.configure(symbolName: symbol, title: title, text: text, actions: actions, identifier: TasksCloudAccessibilityId.banner, isPlain: false, theme: self.presentationData.theme, fontSize: self.fontSize)
    }

    /// The rights a row is drawn under. A read-only board (R4 consent hold) grants none: no
    /// completion and no removal, and the row opens read-only.
    private func rowAccess(_ task: SGTasksCloudTask) -> TasksCloudTaskPermissions {
        return self.state.isReadOnly ? TasksCloudTaskPermissions(task: nil) : TasksCloudTaskPermissions(task: task)
    }

    private func rowModel(_ display: TasksCloudTaskDisplay, access: TasksCloudTaskPermissions, l10n: SGTasksL10n) -> TasksTaskRowModel {
        let listTitle: String?
        switch display.placement {
        case .cloudInbox:
            listTitle = self.state.filter == .all ? l10n.tasks_cloud_inbox_title : nil
        case let .list(title):
            listTitle = self.state.filter == .all ? title : nil
        case let .sharedBy(ownerTelegramId):
            // wf15 §5.2: "Topshirdi: Ism" (the viewer's contact name, else the numeric id).
            listTitle = self.assignedByLine(ownerTelegramId: ownerTelegramId, l10n: l10n)
        }
        // A local change may already be in flight or acknowledged: it waits for confirmation and is
        // never claimed as "not sent". The Masʼul's own state is its line (wf15 §4.3), never here.
        var status: [String] = []
        switch display.syncStatus {
        case .synced:
            break
        case .notSent:
            status.append(l10n.tasks_cloud_syncConfirmationPending)
        case .needsAttention:
            status.append(l10n.tasks_cloud_row_needsAttention)
        }
        // Why a shared row offers nothing but Open (the circle is disabled): visible and spoken. A
        // read-only board (R4) says why once, in its banner.
        if access.role == .noAccess && !self.state.isReadOnly {
            status.append(l10n.tasks_cloud_access_recipientInactive)
        }
        // wf15 §4.3: the owner's Masʼul line "Masʼul: Ism · holat" (the model gives none for a shared
        // row, so a recipient never sees it); the name comes isolated from the presenter.
        var assigneeLine: String?
        var assigneeState: String?
        if let assignee = display.assignee {
            let word = tasksAssigneeStateWord(assignee.state, l10n: l10n)
            let name = self.interaction.assigneeName?(assignee) ?? TasksAssigneeNameFallback.resolve(
                contactName: nil,
                deviceRowName: assignee.deviceRowName.map { tasksIsolatedDisplayText($0) },
                annotationName: assignee.annotationName.map { tasksIsolatedDisplayText($0) },
                numeric: l10n.tasks_cloud_telegramUser(assignee.recipient.rawValue)
            )
            assigneeLine = l10n.tasks_assign_line(name: name, state: word)
            assigneeState = word
        }
        return TasksTaskRowModel(
            taskId: display.id,
            title: display.title,
            isCompleted: display.isCompleted,
            listTitle: listTitle,
            // The owner's Masʼul has its own line; the metadata keeps only the deadline here.
            assigneeName: nil,
            deadlineText: self.deadlineText(display.dueAt, l10n: l10n),
            cloudAccess: access,
            statusText: status.isEmpty ? nil : status.joined(separator: " · "),
            // Leave only with an accepted invitation; nil = Delete, offered only to the owner.
            removalTitle: access.canLeave ? l10n.tasks_cloud_action_leave : nil,
            // A shared task opens read-only: the hint must not promise editing.
            openHint: self.state.isReadOnly ? l10n.tasks_a11y_openReadOnlyHint : (display.removal == .leave ? l10n.tasks_cloud_a11y_openHint : nil),
            assigneeLine: assigneeLine,
            assigneeState: assigneeState
        )
    }

    // MARK: - UITableViewDelegate

    private var sectionHeaderFont: UIFont {
        return Font.regular(floor(self.fontSize * 13.0 / 17.0))
    }

    /// wf15 §5.2: the "Menga topshirilgan" header exists only while its section has a row.
    private func showsAssignedHeader(_ section: Int) -> Bool {
        return section == TasksCloudBoardState.assignedSection && !self.sections[section].isEmpty
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 {
            return 8.0
        }
        if self.showsAssignedHeader(section) {
            return UITableView.automaticDimension
        }
        return self.sections[section].isEmpty ? CGFloat.leastNonzeroMagnitude : 16.0
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return CGFloat.leastNonzeroMagnitude
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard self.showsAssignedHeader(section), let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: TasksCloudSectionHeaderView.reuseIdentifier) as? TasksCloudSectionHeaderView else {
            return UIView()
        }
        header.update(title: SGTasksL10n(self.presentationData.strings).tasks_assigned_header, identifier: TasksCloudAccessibilityId.assignedHeader, font: self.sectionHeaderFont, color: self.presentationData.theme.list.sectionHeaderTextColor)
        return header
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return UIView()
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch self.sections[indexPath.section][indexPath.row] {
        case .task, .provisionalTask, .completedHeader, .unsent, .invitations:
            return true
        default:
            return false
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch self.sections[indexPath.section][indexPath.row] {
        case .completedHeader:
            self.interaction.toggleCompletedSection()
        case let .task(id):
            self.interaction.rowActions.edit(id)
        case let .provisionalTask(invitationId):
            self.interaction.openProvisional(invitationId)
        case .unsent:
            self.interaction.openUnsentChanges()
        case .invitations:
            self.interaction.openInvitations()
        default:
            break
        }
    }

    /// The removal the viewer may take: Leave (accepted recipient), Delete (owner), or nothing (a
    /// shared row without an accepted invitation).
    private func removalTitle(for access: TasksCloudTaskPermissions) -> String? {
        if access.canLeave {
            return SGTasksL10n(self.presentationData.strings).tasks_cloud_action_leave
        }
        if access.canDelete {
            return self.presentationData.strings.Common_Delete
        }
        return nil
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case let .task(id) = self.sections[indexPath.section][indexPath.row], let task = self.state.task(id: id) else {
            return nil
        }
        let access = self.rowAccess(task)
        guard let title = self.removalTitle(for: access) else {
            return nil
        }
        let action = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, completion in
            self?.interaction.rowActions.delete(id, access)
            completion(true)
        }
        action.backgroundColor = self.presentationData.theme.list.itemDisclosureActions.destructive.fillColor
        let configuration = UISwipeActionsConfiguration(actions: [action])
        // Delete/Leave needs a tap on the revealed action; a full swipe alone never removes.
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case let .task(id) = self.sections[indexPath.section][indexPath.row], let task = self.state.task(id: id) else {
            return nil
        }
        let l10n = SGTasksL10n(self.presentationData.strings)
        let actions = self.interaction.rowActions
        // Every item comes from the same rights the row was drawn under; the presenter refuses the
        // action if they changed before the tap. Open is always there, so the menu is never empty.
        let access = self.rowAccess(task)
        let removalTitle = self.removalTitle(for: access)
        let targetCompleted = !task.isCompleted
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var children: [UIMenuElement] = []
            if access.canSetCompletion {
                // The target state is the one the menu shows: a change arriving meanwhile is not flipped back.
                children.append(UIAction(title: task.isCompleted ? l10n.tasks_a11y_markNotDone : l10n.tasks_a11y_markDone, image: UIImage(systemName: task.isCompleted ? "circle" : "checkmark.circle")) { _ in
                    actions.setCompleted(id, targetCompleted, access)
                })
            }
            children.append(UIAction(title: access.canEditContent ? l10n.tasks_action_edit : l10n.tasks_action_open, image: UIImage(systemName: access.canEditContent ? "pencil" : "doc.text")) { _ in
                actions.edit(id)
            })
            if let removalTitle {
                children.append(UIAction(title: removalTitle, image: UIImage(systemName: access.canLeave ? "rectangle.portrait.and.arrow.right" : "trash"), attributes: .destructive) { _ in
                    actions.delete(id, access)
                })
            }
            return UIMenu(title: "", children: children)
        }
    }
}
