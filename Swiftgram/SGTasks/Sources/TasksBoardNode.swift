import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import ItemListUI

// Zenlygram — Tasks board display node: filter chips under the navigation bar, the task table (with
// the List / Calendar header scrolling inside it), and the quick-add composer pinned above the
// keyboard / tab bar. The controller owns storage and state; this node only renders
// `TasksBoardState` and reports what the user did. The List / Calendar choice and the selected day
// are view state of this node (in memory only): they filter what is shown, never what is stored.
//
// Read-only mode (`TasksBoardState.isReadOnly`, wf15 §3.4: the pushed "Eski vazifalar" screen): the
// composer is hidden (its draft is kept), rows offer no completion, swipe or removal, and opening a
// row shows it read-only. Filters and the calendar keep working. No banner: the screen's footer says
// why. The host node (TasksBoardHostNode) may reserve a footer strip above the composer for the
// one status line of the single board.

struct TasksBoardInteraction {
    let selectFilter: (TasksBoardFilter) -> Void
    let createList: () -> Void
    let toggleCompletedSection: () -> Void
    let rowActions: TasksRowActions
    /// Returns true when the task was stored (the composer then clears its draft).
    let submitQuickAdd: (String) -> Bool
    /// The composer's assignee/deadline controls; the controller owns the draft values.
    let pickQuickAddAssignee: () -> Void
    let clearQuickAddAssignee: () -> Void
    let pickQuickAddDeadline: () -> Void
    let clearQuickAddDeadline: () -> Void
    /// The List / Calendar header switched to Calendar (analytics).
    let calendarShown: () -> Void
}

final class TasksBoardNode: ASDisplayNode, UITableViewDataSource, UITableViewDelegate {
    private let interaction: TasksBoardInteraction
    private var presentationData: PresentationData
    private var state: TasksBoardState
    private var sections: [[TasksBoardRow]] = []
    private var quickAddMetadata: TasksTaskMetadataDraft

    private var tableView: UITableView?
    private let filterBar = TasksFilterBarView()
    private let composer = TasksComposerView()
    private let calendarCoordinator = TasksBoardCalendarCoordinator()

    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat, footerHeight: CGFloat)?

    /// Keyboard / tab-bar inset plus the composer: the host lifts its status line and the Undo
    /// toast above it.
    private(set) var bottomOccupiedHeight: CGFloat = 0.0

    /// wf15 §4.4: on the device board under the one-board model (sync off or not usable yet) an
    /// existing local assignee is an old entry that was never sent — "Ism (eski yozuv)". The host sets
    /// it from the resolver's Masʼul answer (false only for S1, today's local assignee); the read-only
    /// Eski vazifalar view marks them always (§3.4).
    var marksLegacyAssignees = false {
        didSet {
            if self.marksLegacyAssignees != oldValue {
                self.reloadContent()
            }
        }
    }

    init(state: TasksBoardState, quickAddMetadata: TasksTaskMetadataDraft, presentationData: PresentationData, interaction: TasksBoardInteraction) {
        self.state = state
        self.quickAddMetadata = quickAddMetadata
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
        self.tableView = tableView
        self.calendarCoordinator.attach(to: tableView)

        self.view.addSubview(tableView)
        self.view.addSubview(self.filterBar)
        self.view.addSubview(self.composer)

        self.applyPresentationData()
        self.reloadContent()
    }

    // MARK: - Updates

    func update(state: TasksBoardState) {
        let wasReadOnly = self.state.isReadOnly
        self.state = state
        if state.isReadOnly && !wasReadOnly && self.isNodeLoaded {
            // The composer goes away with its draft intact; the keyboard must not stay up for it.
            self.view.endEditing(true)
        }
        self.reloadContent()
        if wasReadOnly != state.isReadOnly, let validLayout = self.validLayout {
            self.containerLayoutUpdated(validLayout.layout, navigationHeight: validLayout.navigationHeight, footerHeight: validLayout.footerHeight, transition: .immediate)
        }
    }

    /// The composer's typed title (not yet submitted); nil or empty when there is none. wf15 §3.3:
    /// when the board flips from the device rows to the synced board once (S5 → S7), the host hands
    /// this draft to the synced composer.
    var quickAddDraftTitle: String? {
        guard self.isNodeLoaded else {
            return nil
        }
        return self.composer.textField.text
    }

    /// Clears the composer's typed title (after the host carried it over).
    func clearQuickAddDraftTitle() {
        guard self.isNodeLoaded else {
            return
        }
        self.composer.textField.text = nil
        self.composer.textField.sendActions(for: .editingChanged)
    }

    /// Shows the composer's current assignee/deadline draft. A chosen value can change the
    /// composer's height: the controller requests a layout afterwards (which also moves the Undo
    /// toast above the composer).
    func updateQuickAddMetadata(_ metadata: TasksTaskMetadataDraft) {
        self.quickAddMetadata = metadata
        if self.isNodeLoaded {
            self.updateComposer(l10n: SGTasksL10n(self.presentationData.strings))
        }
    }

    /// True while the quick-add title field has the keyboard.
    var isEditingQuickAddTitle: Bool {
        return self.isNodeLoaded && self.composer.isEditingTitle
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

    private var usesMilitaryTime: Bool {
        return self.presentationData.dateTimeFormat.timeFormat == .military
    }

    private func deadlineText(_ dueAt: Int32?, l10n: SGTasksL10n) -> String? {
        return dueAt.map { l10n.tasks_deadline_text($0, use24HourClock: self.usesMilitaryTime) }
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
        // One calendar and one "now" for the header and the rows, so they agree on every day.
        let calendar = l10n.tasks_deadlineCalendar
        let now = Date()
        // Device storage is read in full: its counts are always complete.
        self.calendarCoordinator.update(dueDates: self.state.calendarDueDates, countsComplete: true, isAvailable: true, presentationData: self.presentationData, calendar: calendar, now: now)
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
        if let folder = self.state.selectedFolder {
            placeholder = l10n.tasks_quickAdd_placeholderInList(folder.title)
        } else {
            placeholder = l10n.tasks_quickAdd_placeholder
        }
        // A contact's name is external text: isolated so it cannot reorder neighbouring text.
        let metadata = TasksComposerMetadata(assigneeName: self.quickAddMetadata.assignee.map { tasksIsolatedDisplayText($0.displayName) }, deadlineText: self.deadlineText(self.quickAddMetadata.dueAt, l10n: l10n))
        self.composer.update(placeholder: placeholder, submitTitle: l10n.tasks_quickAdd_submit, doneTitle: self.presentationData.strings.Common_Done, metadata: metadata, l10n: l10n, theme: self.presentationData.theme, fontSize: self.fontSize)
    }

    /// Scrolls a task into view (after quick add, so the new row is visible above the composer). In
    /// Calendar mode a task outside the selected day first switches to its own day (or No Deadline),
    /// so it never vanishes; its deadline is left as it is.
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
    /// board's status line, or a read-only screen's footer); 0 when there is none.
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, footerHeight: CGFloat = 0.0, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationHeight, footerHeight)
        guard let tableView = self.tableView else {
            return
        }
        let size = layout.size
        let horizontalInsets = (left: layout.safeInsets.left, right: layout.safeInsets.right)

        // The keyboard and the tab bar / home indicator overlap the same bottom strip: take the larger
        // one, never the sum. `intrinsicInsets.bottom` already contains the tab bar when this is a tab
        // root and the home-indicator inset when it is pushed.
        let bottomInset = max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0.0)
        // Read-only (Eski vazifalar) takes no new task: no composer, so nothing reaches a refused write.
        let showsComposer = !self.state.isReadOnly
        self.composer.isHidden = !showsComposer
        self.composer.accessibilityElementsHidden = !showsComposer
        self.composer.horizontalInsets = horizontalInsets
        let composerHeight = showsComposer ? self.composer.preferredHeight(width: size.width) : 0.0
        let availableHeight = max(0.0, size.height - bottomInset - navigationHeight)

        // Compact height with the keyboard up (landscape, large text): the filter chips step aside
        // only when the composer, the footer strip and at least one task row would not fit under
        // them otherwise. The composer never moves above the navigation bar; drafts are untouched
        // either way.
        let filterHeight = TasksFilterBarView.height(fontSize: self.fontSize)
        let hidesFilter = filterHeight + composerHeight + footerHeight + tasksMinimumHitSize > availableHeight
        self.filterBar.isHidden = hidesFilter
        self.filterBar.accessibilityElementsHidden = hidesFilter
        let filterFrame = CGRect(x: 0.0, y: navigationHeight, width: size.width, height: hidesFilter ? 0.0 : filterHeight)
        self.filterBar.horizontalInsets = horizontalInsets
        transition.updateFrame(view: self.filterBar, frame: filterFrame)

        // Never taller than the space under the navigation bar: if its content needs more (compact
        // height, keyboard, large text), the composer scrolls its own content instead.
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
        // The table ends at the composer, so only a little air is added below the last row. The inset
        // grouped cards follow the window's safe area horizontally on their own.
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
        case let .emptyMessage(kind):
            let cell = tableView.dequeueReusableCell(withIdentifier: TasksEmptyCell.reuseIdentifier, for: indexPath) as! TasksEmptyCell
            let (title, text) = self.emptyTexts(kind: kind, l10n: l10n)
            cell.configure(title: title, text: text, theme: theme, fontSize: self.fontSize)
            return cell
        case let .completedHeader(count, isExpanded):
            let cell = tableView.dequeueReusableCell(withIdentifier: TasksCompletedHeaderCell.reuseIdentifier, for: indexPath) as! TasksCompletedHeaderCell
            cell.configure(count: count, isExpanded: isExpanded, theme: theme, l10n: l10n, fontSize: self.fontSize, toggle: self.interaction.toggleCompletedSection)
            return cell
        case let .task(id):
            let cell = tableView.dequeueReusableCell(withIdentifier: TasksTaskCell.reuseIdentifier, for: indexPath) as! TasksTaskCell
            if let task = self.state.task(id: id) {
                // The list name only helps while tasks of several lists are mixed.
                let listTitle = self.state.filter == .all ? self.state.folderTitle(for: task) : nil
                // A read-only row (Eski vazifalar) has no write rights: no completion and no removal,
                // and it opens read-only. A writable device row carries no rights at all (every action
                // is the user's).
                let isReadOnly = self.state.isReadOnly
                // wf15 §3.4 / §4.4: a local assignee outside S1 is an old entry, never sent.
                let marksLegacy = isReadOnly || self.marksLegacyAssignees
                let assigneeName = task.assignee.map { assignee -> String in
                    let name = tasksIsolatedDisplayText(assignee.displayName)
                    return marksLegacy ? name + " " + l10n.tasks_assign_oldEntry : name
                }
                let model = TasksTaskRowModel(taskId: task.id, title: task.title, isCompleted: task.isCompleted, listTitle: listTitle, assigneeName: assigneeName, deadlineText: self.deadlineText(task.dueAt, l10n: l10n), cloudAccess: isReadOnly ? TasksCloudTaskPermissions(task: nil) : nil, openHint: isReadOnly ? l10n.tasks_a11y_openReadOnlyHint : nil)
                cell.configure(model: model, actions: self.interaction.rowActions, theme: theme, strings: self.presentationData.strings, fontSize: self.fontSize)
            }
            return cell
        }
    }

    private func emptyTexts(kind: TasksBoardEmptyKind, l10n: SGTasksL10n) -> (String, String) {
        if self.state.isReadOnly && kind == .noTasks {
            // Nothing here to add to: the text says why instead of pointing at a hidden composer.
            return (l10n.tasks_empty_noTasks_title, l10n.tasks_older_readOnly)
        }
        if let texts = self.calendarCoordinator.emptyTexts(kind: kind, l10n: l10n) {
            return texts
        }
        switch kind {
        case .allDone:
            return (l10n.tasks_empty_allDone_title, l10n.tasks_empty_allDone_text)
        case .noTasks:
            let text = self.state.filter == .all ? l10n.tasks_empty_noTasks_text : l10n.tasks_empty_listEmpty_text
            return (l10n.tasks_empty_noTasks_title, text)
        }
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 {
            return 8.0
        }
        return self.sections[section].isEmpty ? CGFloat.leastNonzeroMagnitude : 16.0
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return CGFloat.leastNonzeroMagnitude
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        return UIView()
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return UIView()
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch self.sections[indexPath.section][indexPath.row] {
        case .emptyMessage:
            return false
        case .task, .completedHeader:
            return true
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch self.sections[indexPath.section][indexPath.row] {
        case .emptyMessage:
            break
        case .completedHeader:
            self.interaction.toggleCompletedSection()
        case let .task(id):
            self.interaction.rowActions.edit(id)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        // Read-only (Eski vazifalar) offers no removal.
        guard !self.state.isReadOnly, case let .task(id) = self.sections[indexPath.section][indexPath.row] else {
            return nil
        }
        let delete = UIContextualAction(style: .destructive, title: self.presentationData.strings.Common_Delete) { [weak self] _, _, completion in
            self?.interaction.rowActions.delete(id, nil)
            completion(true)
        }
        delete.backgroundColor = self.presentationData.theme.list.itemDisclosureActions.destructive.fillColor
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        // Deleting needs a tap on the revealed action; a full swipe alone never deletes.
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case let .task(id) = self.sections[indexPath.section][indexPath.row], let task = self.state.task(id: id) else {
            return nil
        }
        let l10n = SGTasksL10n(self.presentationData.strings)
        let actions = self.interaction.rowActions
        let strings = self.presentationData.strings
        if self.state.isReadOnly {
            // Read-only (Eski vazifalar): the task opens read-only, nothing else.
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                return UIMenu(title: "", children: [UIAction(title: l10n.tasks_action_open, image: UIImage(systemName: "doc.text")) { _ in
                    actions.edit(id)
                }])
            }
        }
        // The target state is the one the menu shows: a change arriving meanwhile is not flipped back.
        let targetCompleted = !task.isCompleted
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let toggle = UIAction(title: task.isCompleted ? l10n.tasks_a11y_markNotDone : l10n.tasks_a11y_markDone, image: UIImage(systemName: task.isCompleted ? "circle" : "checkmark.circle")) { _ in
                actions.setCompleted(id, targetCompleted, nil)
            }
            let edit = UIAction(title: l10n.tasks_action_edit, image: UIImage(systemName: "pencil")) { _ in
                actions.edit(id)
            }
            let delete = UIAction(title: strings.Common_Delete, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                actions.delete(id, nil)
            }
            return UIMenu(title: "", children: [toggle, edit, delete])
        }
    }
}

// MARK: - Calendar view (shared by the device and cloud boards)

extension TasksCalendarHeaderColors {
    init(theme: PresentationTheme) {
        self.init(
            background: theme.list.blocksBackgroundColor,
            card: theme.list.itemBlocksBackgroundColor,
            primaryText: theme.list.itemPrimaryTextColor,
            accent: theme.list.itemAccentColor,
            isDark: theme.overallDarkAppearance
        )
    }
}

/// One board's List / Calendar header (the task table's `tableHeaderView`) and the view state behind
/// it: the mode and the selected day or No Deadline. In memory only and per board, so the device and
/// cloud boards keep their own choice. It only picks the projection filter; the rows come from the
/// board model's `calendarSections`, so ownership, sync rows and privacy stay the model's. It never
/// touches a quick-add draft or a stored deadline.
final class TasksBoardCalendarCoordinator {
    let headerView = TasksCalendarHeaderView()
    private var mode: TasksBoardViewMode = .list
    /// A civil day (year/month/day), so a time zone or language change keeps the same named day.
    /// nil until the user picks one: then it is today, re-derived on every render (follows midnight).
    private var selection: TasksCalendarSelection?
    private var isAvailable = true
    /// Set when quick add switched the day: the next render announces the new summary.
    private var announcesRevealedSelection = false
    private weak var tableView: UITableView?

    /// The mode or the selected day changed: the board re-renders its rows.
    var contentChanged: (() -> Void)?
    /// The user switched to Calendar (analytics: `tasks.calendar`, `tasks_calendar`).
    var calendarShown: (() -> Void)?

    init() {
        self.headerView.selectMode = { [weak self] mode in
            self?.select(mode: mode)
        }
        self.headerView.selectCalendar = { [weak self] selection in
            self?.select(selection)
        }
        self.headerView.heightDidChange = { [weak self] in
            self?.layoutHeader()
        }
    }

    func attach(to tableView: UITableView) {
        self.tableView = tableView
    }

    /// Calendar mode is on and the board can show content (a gated cloud board shows neither).
    var isCalendarShown: Bool {
        return self.isAvailable && self.mode == .calendar
    }

    private func resolvedSelection(today: TasksCalendarDay) -> TasksCalendarSelection {
        return self.selection ?? .day(today)
    }

    /// What the rows are filtered by: `.all` in List mode, so List is exactly the original board.
    func filter(calendar: Calendar, now: Date) -> TasksCalendarFilter {
        guard self.isCalendarShown else {
            return .all
        }
        switch self.resolvedSelection(today: TasksCalendarDay(date: now, calendar: calendar)) {
        case let .day(day):
            return .day(day.date(calendar: calendar) ?? now)
        case .noDeadline:
            return .noDeadline
        }
    }

    /// `dueDates` is the board model's `calendarDueDates` (the tasks the current list filter shows,
    /// open and completed); it is only evaluated while Calendar mode is on, so List mode does no
    /// per-day work. `countsComplete` is false while those tasks may not all be on this device yet
    /// (Cloud before its first complete snapshot): then no number is shown or announced — no day
    /// markers, no No Deadline count — only neutral text; the controls and the today bar stay. An
    /// unavailable board (cloud gate) removes the header altogether.
    func update(dueDates: @autoclosure () -> [Int32?], countsComplete: Bool, isAvailable: Bool, presentationData: PresentationData, calendar: Calendar, now: Date) {
        self.isAvailable = isAvailable
        guard isAvailable else {
            if let tableView = self.tableView, tableView.tableHeaderView != nil {
                tableView.tableHeaderView = nil
            }
            return
        }
        let l10n = SGTasksL10n(presentationData.strings)
        let today = TasksCalendarDay(date: now, calendar: calendar)
        let selection = self.resolvedSelection(today: today)
        // List mode shows only the switch, and unknown counts are never shown: no counts either way
        // (switching to Calendar, or the snapshot completing, re-renders with them).
        let showsCounts = self.mode == .calendar && countsComplete
        let counts: (days: [TasksCalendarDay: Int], undated: Int) = showsCounts ? tasksCalendarDueDateCounts(dueDates(), calendar: calendar) : ([:], 0)
        // Full date for VoiceOver and announcements; a short one (same calendar and `now`) on screen.
        let selectionTitle: String
        let visibleTitle: String
        let selectedCount: Int
        switch selection {
        case let .day(day):
            let date = day.date(calendar: calendar)
            selectionTitle = date.map { l10n.tasks_calendar_dayTitle($0, isToday: day == today, calendar: calendar) } ?? l10n.tasks_calendar_viewCalendar
            visibleTitle = date.map { l10n.tasks_calendar_shortDayTitle($0, isToday: day == today, now: now, calendar: calendar) } ?? l10n.tasks_calendar_viewCalendar
            selectedCount = counts.days[day] ?? 0
        case .noDeadline:
            selectionTitle = l10n.tasks_calendar_noDeadline
            visibleTitle = selectionTitle
            selectedCount = counts.undated
        }
        let texts = TasksCalendarHeaderTexts(
            listMode: l10n.tasks_calendar_viewList,
            calendarMode: l10n.tasks_calendar_viewCalendar,
            today: l10n.tasks_relative_today,
            todayHint: l10n.tasks_calendar_todayHint,
            noDeadline: l10n.tasks_calendar_noDeadline,
            noDeadlineHint: l10n.tasks_calendar_noDeadlineHint,
            noDeadlineCount: showsCounts ? l10n.tasks_calendar_taskCount(counts.undated) : l10n.tasks_calendar_countsIncomplete,
            calendarLabel: l10n.tasks_calendar_label,
            summary: showsCounts ? l10n.tasks_calendar_summary(selectionTitle, count: selectedCount) : l10n.tasks_calendar_summaryIncomplete(selectionTitle),
            summaryVisible: showsCounts ? l10n.tasks_calendar_summary(visibleTitle, count: selectedCount) : l10n.tasks_calendar_summaryIncomplete(visibleTitle),
            monthToggleHint: l10n.tasks_calendar_monthToggleHint,
            monthShownValue: l10n.tasks_calendar_monthShown,
            monthHiddenValue: l10n.tasks_calendar_monthHidden,
            previousMonth: l10n.tasks_calendar_previousMonth,
            nextMonth: l10n.tasks_calendar_nextMonth,
            chooseMonth: l10n.tasks_calendar_chooseMonth,
            monthPickerDone: presentationData.strings.Common_Done,
            positiveTaskCountDescriptions: counts.days.values.reduce(into: [Int: String]()) { descriptions, count in
                if count > 0 && descriptions[count] == nil {
                    descriptions[count] = l10n.tasks_calendar_taskCount(count)
                }
            }
        )
        self.headerView.update(content: TasksCalendarHeaderContent(
            mode: self.mode,
            selection: selection,
            calendar: calendar,
            today: today,
            dayCounts: counts.days,
            undatedCount: counts.undated,
            texts: texts,
            colors: TasksCalendarHeaderColors(theme: presentationData.theme),
            fontSize: presentationData.listsFontSize.itemListBaseFontSize
        ))
        self.layoutHeader()
        if self.announcesRevealedSelection {
            self.announcesRevealedSelection = false
            // Queued and on the next run loop, so it follows (never cuts off) an "added" announcement.
            let summary = NSAttributedString(string: texts.summary, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            DispatchQueue.main.async {
                UIAccessibility.post(notification: .announcement, argument: summary)
            }
        }
    }

    /// Sizes the header for the table's width. A table header is not self-sizing: a new height only
    /// takes effect when the header is assigned again.
    func layoutHeader() {
        guard self.isAvailable, let tableView = self.tableView else {
            return
        }
        let width = tableView.bounds.width
        guard width > 0.0 else {
            return
        }
        let size = CGSize(width: width, height: self.headerView.preferredHeight(width: width))
        if self.headerView.frame.size != size || tableView.tableHeaderView !== self.headerView {
            self.headerView.frame = CGRect(origin: CGPoint(), size: size)
            tableView.tableHeaderView = self.headerView
        }
    }

    /// After quick add: a task outside the selected day switches the calendar to the task's own day
    /// (or No Deadline) so it stays visible. Returns true when the selection changed.
    func reveal(dueAt: Int32?, calendar: Calendar, now: Date) -> Bool {
        guard self.isCalendarShown, !tasksCalendarMatches(dueAt: dueAt, filter: self.filter(calendar: calendar, now: now), calendar: calendar) else {
            return false
        }
        if let dueAt {
            self.selection = .day(TasksCalendarDay(date: Date(timeIntervalSince1970: TimeInterval(dueAt)), calendar: calendar))
        } else {
            self.selection = .noDeadline
        }
        self.announcesRevealedSelection = true
        return true
    }

    /// The empty agenda names what is empty (this day, or tasks without a deadline); nil in List mode
    /// and for "all done" (the existing wording fits there).
    func emptyTexts(kind: TasksBoardEmptyKind, l10n: SGTasksL10n) -> (String, String)? {
        guard self.isCalendarShown, kind == .noTasks else {
            return nil
        }
        if self.selection == .noDeadline {
            return (l10n.tasks_calendar_emptyUndated_title, l10n.tasks_calendar_emptyUndated_text)
        }
        return (l10n.tasks_calendar_emptyDay_title, l10n.tasks_calendar_emptyDay_text)
    }

    private func select(mode: TasksBoardViewMode) {
        guard mode != self.mode else {
            return
        }
        self.mode = mode
        self.contentChanged?()
        if mode == .calendar {
            self.calendarShown?()
        }
    }

    private func select(_ selection: TasksCalendarSelection) {
        guard selection != self.selection else {
            return
        }
        self.selection = selection
        self.contentChanged?()
    }
}
