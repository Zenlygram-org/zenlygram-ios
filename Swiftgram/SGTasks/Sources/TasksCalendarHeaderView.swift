import Foundation
import UIKit

// Zenlygram — Tasks calendar: the List / Calendar switch and, in Calendar mode, Today / No Deadline,
// a summary disclosure and the month calendar it shows or hides. It is the task table's header, so it
// scrolls with the tasks and never pushes the quick-add composer (pinned above the keyboard) off screen.
//
// Inputs are Foundation / UIKit values only: the board resolves strings, colours and per-day counts
// (from the board model's projection) before calling `update(content:)`; this view never reads
// storage, the theme or the network, and it never sets its own frame (the board sizes it with
// `preferredHeight(width:)`). On iOS 16.2+ a compact UIKit month presentation retains task counts
// and a non-colour Today marker without UICalendarView's extra decoration spacing. Before 16.2 the
// wheel UIDatePicker remains: the same day agenda, without per-day markers. Its
// dependencies are the Foundation-only TasksCalendarModel.swift and UIKit-only
// TasksCalendarMonthGridView.swift; these compile together without the app graph.

/// Apple's minimum touch target, the same 44 pt as the board's `tasksMinimumHitSize`; local so this
/// file needs no UI file of the module.
private let tasksCalendarMinimumHitSize: CGFloat = 44.0

/// Stable accessibility identifiers for UI tests. Ids only, never a title.
enum TasksCalendarAccessibilityId {
    static let viewMode = "sgtasks.view.mode"
    static let calendar = "sgtasks.calendar"
    static let today = "sgtasks.calendar.today"
    static let noDeadline = "sgtasks.calendar.noDeadline"
    static let summary = "sgtasks.calendar.summary"
}

/// How a board shows its tasks. Kept in memory per board (device and cloud independently).
enum TasksBoardViewMode: Equatable {
    case list
    case calendar
}

/// What Calendar mode shows: one day's tasks or the tasks without a deadline.
enum TasksCalendarSelection: Equatable {
    case day(TasksCalendarDay)
    case noDeadline
}

struct TasksCalendarHeaderColors: Equatable {
    var background: UIColor
    var card: UIColor
    var primaryText: UIColor
    var accent: UIColor
    var isDark: Bool
}

struct TasksCalendarHeaderTexts: Equatable {
    var listMode: String
    var calendarMode: String
    var today: String
    var todayHint: String
    var noDeadline: String
    var noDeadlineHint: String
    /// How many tasks have no deadline, as VoiceOver reads it.
    var noDeadlineCount: String
    var calendarLabel: String
    /// The selected day in full (or "No Deadline") and how many tasks it holds, or a neutral note
    /// while that is not known yet. The disclosure's VoiceOver label and every announcement.
    var summary: String
    /// The same with a short date ("Today", "Wed, Oct 29"): the disclosure's visible title.
    var summaryVisible: String
    var monthToggleHint: String
    /// The disclosure's VoiceOver value while the month is shown / hidden.
    var monthShownValue: String
    var monthHiddenValue: String
    var previousMonth: String
    var nextMonth: String
    var chooseMonth: String
    var monthPickerDone: String
    /// Only distinct positive counts from the same complete projection as `dayCounts`.
    var positiveTaskCountDescriptions: [Int: String]
}

struct TasksCalendarHeaderContent: Equatable {
    var mode: TasksBoardViewMode
    var selection: TasksCalendarSelection
    /// The deadline calendar: its locale and time zone also drive the month calendar.
    var calendar: Calendar
    var today: TasksCalendarDay
    var dayCounts: [TasksCalendarDay: Int]
    var undatedCount: Int
    var texts: TasksCalendarHeaderTexts
    var colors: TasksCalendarHeaderColors
    var fontSize: CGFloat
}

final class TasksCalendarHeaderView: UIView {
    private static let sideInset: CGFloat = 16.0
    private static let spacing: CGFloat = 8.0
    private static let cardPadding: CGFloat = 8.0

    private let modeControl = UISegmentedControl(items: ["", ""])
    private let calendarCard = UIView()
    private let calendarControl: TasksCalendarControl
    private let todayButton = TasksCalendarActionButton()
    private let noDeadlineButton = TasksCalendarActionButton()
    /// The selected day and its count; tapping it shows or hides the month calendar.
    private let summaryButton = TasksCalendarActionButton()
    /// Presentation only, per header (so per board): kept across updates and List / Calendar switches.
    /// Starts collapsed, so the day's tasks come first; the user's later choice is kept.
    private var isMonthExpanded = false
    /// Whether the month was on screen at the last update: only then may a change inside it animate.
    private var wasMonthVisible = false
    private var content: TasksCalendarHeaderContent?
    private var countFormatter = NumberFormatter()
    /// The month calendar's fitting height for a width; dropped when its content may have changed size.
    private var calendarHeightCache: (width: CGFloat, height: CGFloat, validated: Bool)?
    private var calendarHeightGeneration: UInt = 0
    private var calendarHeightUpdateQueued = false
    private var parentHeightUpdatePending = false
    /// Set by a user's choice of day, so the resulting summary (with the count) is announced once.
    private var announcesNextSummary = false
    private var contentSizeObserver: NSObjectProtocol?

    var selectMode: ((TasksBoardViewMode) -> Void)?
    var selectCalendar: ((TasksCalendarSelection) -> Void)?
    /// The preferred height may have changed (visible month, text size): the board re-measures.
    var heightDidChange: (() -> Void)?

    /// The container layout's left/right safe insets (landscape notch), set by the board.
    var horizontalInsets: (left: CGFloat, right: CGFloat) = (0.0, 0.0) {
        didSet { self.setNeedsLayout() }
    }

    override init(frame: CGRect) {
        if #available(iOS 16.2, *) {
            self.calendarControl = TasksCompactCalendarControl()
        } else {
            self.calendarControl = TasksDatePickerCalendarControl()
        }
        super.init(frame: frame)

        self.modeControl.selectedSegmentIndex = 0
        self.modeControl.accessibilityIdentifier = TasksCalendarAccessibilityId.viewMode
        self.modeControl.addTarget(self, action: #selector(self.modeChanged), for: .valueChanged)
        self.addSubview(self.modeControl)

        self.calendarCard.layer.cornerRadius = 12.0
        self.calendarControl.view.accessibilityIdentifier = TasksCalendarAccessibilityId.calendar
        self.calendarCard.addSubview(self.calendarControl.view)

        self.todayButton.accessibilityIdentifier = TasksCalendarAccessibilityId.today
        self.todayButton.addTarget(self, action: #selector(self.todayPressed), for: .touchUpInside)
        self.addSubview(self.todayButton)
        self.noDeadlineButton.accessibilityIdentifier = TasksCalendarAccessibilityId.noDeadline
        self.noDeadlineButton.addTarget(self, action: #selector(self.noDeadlinePressed), for: .touchUpInside)
        self.addSubview(self.noDeadlineButton)

        self.summaryButton.accessibilityIdentifier = TasksCalendarAccessibilityId.summary
        self.summaryButton.addTarget(self, action: #selector(self.toggleMonthPressed), for: .touchUpInside)
        self.addSubview(self.summaryButton)
        self.addSubview(self.calendarCard)

        self.calendarControl.selectDay = { [weak self] day in
            self?.userSelected(.day(day))
        }
        self.calendarControl.heightDidChange = { [weak self] in
            self?.calendarHeightChanged()
        }
        self.calendarControl.formatCount = { [weak self] count in
            return self?.countText(count) ?? "\(count)"
        }
        // The month calendar follows the system text size: re-measure it when that changes.
        self.contentSizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.calendarHeightChanged()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let contentSizeObserver = self.contentSizeObserver {
            NotificationCenter.default.removeObserver(contentSizeObserver)
        }
    }

    // MARK: - Content

    func update(content: TasksCalendarHeaderContent) {
        let previous = self.content
        self.content = content
        let colors = content.colors
        let texts = content.texts
        if previous?.calendar != content.calendar || previous?.fontSize != content.fontSize {
            self.invalidateCalendarHeight()
        }
        if previous?.calendar.locale != content.calendar.locale {
            let formatter = NumberFormatter()
            formatter.locale = content.calendar.locale
            formatter.numberStyle = .decimal
            self.countFormatter = formatter
        }

        self.backgroundColor = colors.background
        let font = UIFont.systemFont(ofSize: max(13.0, content.fontSize - 2.0), weight: .medium)

        if self.modeControl.titleForSegment(at: 0) != texts.listMode {
            self.modeControl.setTitle(texts.listMode, forSegmentAt: 0)
        }
        if self.modeControl.titleForSegment(at: 1) != texts.calendarMode {
            self.modeControl.setTitle(texts.calendarMode, forSegmentAt: 1)
        }
        self.modeControl.selectedSegmentIndex = content.mode == .list ? 0 : 1
        // Neutral: the selected segment is a card on the board background, its title semibold, so the
        // selection reads by contrast and weight rather than by an accent fill.
        let selectedModeFont = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        self.modeControl.setTitleTextAttributes([.font: font, .foregroundColor: colors.primaryText], for: .normal)
        self.modeControl.setTitleTextAttributes([.font: selectedModeFont, .foregroundColor: colors.primaryText], for: .selected)
        self.modeControl.selectedSegmentTintColor = colors.card
        self.modeControl.backgroundColor = colors.background

        let showsCalendar = content.mode == .calendar
        let showsMonth = showsCalendar && self.isMonthExpanded
        for view in [self.todayButton, self.noDeadlineButton, self.summaryButton] as [UIView] {
            view.isHidden = !showsCalendar
        }
        self.calendarCard.isHidden = !showsMonth
        if !showsMonth {
            self.calendarControl.view.endEditing(false)
        }
        if showsCalendar {
            self.calendarCard.backgroundColor = colors.card
            // Updated while collapsed too, so the selection, Today's month and the markers stay current.
            // Only a change inside a month already on screen moves; Reduce Motion never animates.
            let animated = self.wasMonthVisible && showsMonth && !UIAccessibility.isReduceMotionEnabled
            self.calendarControl.update(content: content, animated: animated)
            self.calendarControl.view.accessibilityLabel = texts.calendarLabel

            let isTodaySelected = content.selection == .day(content.today)
            self.todayButton.update(symbolName: isTodaySelected ? "checkmark.circle.fill" : "calendar", title: texts.today, isChosen: isTodaySelected, colors: colors, font: font)
            self.todayButton.accessibilityLabel = texts.today
            self.todayButton.accessibilityHint = texts.todayHint

            let isUndatedSelected = content.selection == .noDeadline
            var undatedTitle = texts.noDeadline
            if content.undatedCount > 0 {
                undatedTitle += "  " + self.countText(content.undatedCount)
            }
            self.noDeadlineButton.update(symbolName: isUndatedSelected ? "checkmark.circle.fill" : "calendar.badge.minus", title: undatedTitle, isChosen: isUndatedSelected, colors: colors, font: font)
            self.noDeadlineButton.accessibilityLabel = texts.noDeadline
            self.noDeadlineButton.accessibilityValue = texts.noDeadlineCount
            self.noDeadlineButton.accessibilityHint = texts.noDeadlineHint

            self.updateSummaryButton()
        }
        self.wasMonthVisible = showsMonth
        if self.announcesNextSummary {
            self.announcesNextSummary = false
            if showsCalendar {
                UIAccessibility.post(notification: .announcement, argument: texts.summary)
            }
        }
        self.setNeedsLayout()
    }

    /// Task counts on the calendar and the No Deadline button: localized digits, capped so a busy day
    /// still fits under its date.
    private func countText(_ count: Int) -> String {
        let capped = min(count, 99)
        let text = self.countFormatter.string(from: NSNumber(value: capped)) ?? "\(capped)"
        return count > 99 ? text + "+" : text
    }

    // MARK: - Layout

    private struct Layout {
        var mode: CGRect = .zero
        var card: CGRect = .zero
        var calendar: CGRect = .zero
        var today: CGRect = .zero
        var noDeadline: CGRect = .zero
        var summary: CGRect = .zero
        var height: CGFloat = 0.0
    }

    private var modeControlHeight: CGFloat {
        let fontSize = max(13.0, (self.content?.fontSize ?? 17.0) - 2.0)
        return max(tasksCalendarMinimumHitSize, ceil(UIFont.systemFont(ofSize: fontSize, weight: .medium).lineHeight) + 16.0)
    }

    private func invalidateCalendarHeight() {
        self.calendarHeightCache = nil
        self.calendarHeightGeneration &+= 1
    }

    private func calendarHeight(width: CGFloat) -> CGFloat {
        if let cache = self.calendarHeightCache, cache.width == width {
            return cache.height
        }
        self.invalidateCalendarHeight()
        let height = self.calendarControl.fittingHeight(width: width)
        self.calendarHeightCache = (width, height, false)
        return height
    }

    /// Top to bottom: the List / Calendar switch; in Calendar mode Today / No Deadline, the summary
    /// disclosure and (while expanded) the month. A collapsed month is not measured at all.
    private func makeLayout(width: CGFloat) -> Layout {
        var layout = Layout()
        let left = TasksCalendarHeaderView.sideInset + self.horizontalInsets.left
        let rowWidth = max(0.0, width - left - TasksCalendarHeaderView.sideInset - self.horizontalInsets.right)
        let spacing = TasksCalendarHeaderView.spacing
        var y = spacing

        layout.mode = CGRect(x: left, y: y, width: rowWidth, height: self.modeControlHeight)
        y = layout.mode.maxY

        if self.content?.mode == .calendar {
            y += spacing
            // Side by side while both fit on one line in half the width; stacked (each wrapping)
            // otherwise. Today leads: on the right in a right-to-left layout.
            let halfWidth = floor((rowWidth - spacing) / 2.0)
            let otherWidth = max(0.0, rowWidth - halfWidth - spacing)
            if self.todayButton.singleLineWidth <= halfWidth && self.noDeadlineButton.singleLineWidth <= otherWidth {
                let height = max(self.todayButton.rowHeight(forWidth: halfWidth), self.noDeadlineButton.rowHeight(forWidth: otherWidth))
                let leading = CGRect(x: left, y: y, width: halfWidth, height: height)
                let trailing = CGRect(x: left + halfWidth + spacing, y: y, width: otherWidth, height: height)
                let isRightToLeft = self.effectiveUserInterfaceLayoutDirection == .rightToLeft
                layout.today = isRightToLeft ? trailing : leading
                layout.noDeadline = isRightToLeft ? leading : trailing
                y += height
            } else {
                let todayHeight = self.todayButton.rowHeight(forWidth: rowWidth)
                layout.today = CGRect(x: left, y: y, width: rowWidth, height: todayHeight)
                y += todayHeight + spacing
                let undatedHeight = self.noDeadlineButton.rowHeight(forWidth: rowWidth)
                layout.noDeadline = CGRect(x: left, y: y, width: rowWidth, height: undatedHeight)
                y += undatedHeight
            }
            y += spacing

            let summaryHeight = self.summaryButton.rowHeight(forWidth: rowWidth)
            layout.summary = CGRect(x: left, y: y, width: rowWidth, height: summaryHeight)
            y = layout.summary.maxY

            if self.isMonthExpanded {
                y += spacing
                let padding = TasksCalendarHeaderView.cardPadding
                let calendarWidth = max(0.0, rowWidth - padding * 2.0)
                let calendarHeight = self.calendarHeight(width: calendarWidth)
                layout.card = CGRect(x: left, y: y, width: rowWidth, height: calendarHeight + padding * 2.0)
                layout.calendar = CGRect(x: padding, y: padding, width: calendarWidth, height: calendarHeight)
                y = layout.card.maxY
            }
        }
        layout.height = ceil(y + spacing)
        return layout
    }

    /// The height this header needs at `width` for the current content and `horizontalInsets`.
    func preferredHeight(width: CGFloat) -> CGFloat {
        return self.makeLayout(width: width).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = self.makeLayout(width: self.bounds.width)
        self.modeControl.frame = layout.mode
        self.calendarCard.frame = layout.card
        self.calendarControl.view.frame = layout.calendar
        self.todayButton.frame = layout.today
        self.noDeadlineButton.frame = layout.noDeadline
        self.summaryButton.frame = layout.summary
        if self.canMeasureCalendar, self.calendarHeightCache?.validated == false {
            self.queueCalendarHeightUpdate()
        }
    }

    private var canMeasureCalendar: Bool {
        return self.content?.mode == .calendar && self.isMonthExpanded && !self.isHidden && !self.calendarCard.isHidden
    }

    private func calendarHeightChanged() {
        self.invalidateCalendarHeight()
        self.setNeedsLayout()
        if self.canMeasureCalendar {
            self.queueCalendarHeightUpdate(notifyParent: true)
        }
    }

    private func queueCalendarHeightUpdate(notifyParent: Bool = false) {
        self.parentHeightUpdatePending = self.parentHeightUpdatePending || notifyParent
        guard !self.calendarHeightUpdateQueued else {
            return
        }
        self.calendarHeightUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.calendarHeightUpdateQueued = false
            guard self.canMeasureCalendar else {
                self.parentHeightUpdatePending = false
                return
            }
            self.reconcileCalendarHeight()
            guard self.canMeasureCalendar else {
                self.parentHeightUpdatePending = false
                return
            }
            if self.parentHeightUpdatePending {
                self.parentHeightUpdatePending = false
                self.heightDidChange?()
            }
        }
    }

    private func reconcileCalendarHeight() {
        let view = self.calendarControl.view
        guard let cache = self.calendarHeightCache, !cache.validated, cache.width > 0.0, view.bounds.width == cache.width else {
            return
        }
        let generation = self.calendarHeightGeneration
        // UIKit's first fitting pass can precede its real width/layout. Validate once at that width,
        // outside the header's layout stack; ordinary scrolling/layout reuses the validated cache.
        view.layoutIfNeeded()
        guard generation == self.calendarHeightGeneration, self.canMeasureCalendar, view.bounds.width == cache.width else {
            return
        }
        let height = self.calendarControl.fittingHeight(width: cache.width)
        guard generation == self.calendarHeightGeneration, self.canMeasureCalendar, view.bounds.width == cache.width else {
            return
        }
        self.calendarHeightCache = (cache.width, height, true)
        if height != cache.height {
            self.setNeedsLayout()
            self.parentHeightUpdatePending = true
        }
    }

    /// The disclosure's title, chevron and VoiceOver value from the last content and the expanded
    /// state. The chevron shows the state without relying on colour.
    private func updateSummaryButton() {
        guard let content = self.content else {
            return
        }
        let font = UIFont.systemFont(ofSize: max(13.0, content.fontSize - 2.0), weight: .medium)
        self.summaryButton.update(symbolName: self.isMonthExpanded ? "chevron.up" : "chevron.down", title: content.texts.summaryVisible, isChosen: false, colors: content.colors, font: font)
        self.summaryButton.accessibilityLabel = content.texts.summary
        // Voice Control matches what is on screen (the short date) as well as the full label.
        let visible = content.texts.summaryVisible
        self.summaryButton.accessibilityUserInputLabels = visible == content.texts.summary ? [visible] : [visible, content.texts.summary]
        self.summaryButton.accessibilityValue = self.isMonthExpanded ? content.texts.monthShownValue : content.texts.monthHiddenValue
        self.summaryButton.accessibilityHint = content.texts.monthToggleHint
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        self.selectMode?(self.modeControl.selectedSegmentIndex == 1 ? .calendar : .list)
    }

    @objc private func todayPressed() {
        guard let today = self.content?.today else {
            return
        }
        // Today also brings its month back after browsing other months, even if it was selected. A
        // collapsed month moves without animation (it is not on screen).
        self.calendarControl.showMonth(of: today, animated: self.isMonthExpanded && !UIAccessibility.isReduceMotionEnabled)
        self.userSelected(.day(today))
    }

    @objc private func noDeadlinePressed() {
        self.userSelected(.noDeadline)
    }

    /// Presentation only: no selection, mode or data change. The board re-sizes the header through
    /// `heightDidChange`; VoiceOver focus then returns to the same disclosure.
    @objc private func toggleMonthPressed() {
        self.isMonthExpanded.toggle()
        self.calendarCard.isHidden = !self.isMonthExpanded
        if !self.isMonthExpanded {
            self.calendarControl.view.endEditing(false)
        }
        // The first update after showing it again never animates (the month was not on screen).
        self.wasMonthVisible = false
        self.updateSummaryButton()
        self.invalidateCalendarHeight()
        self.setNeedsLayout()
        self.heightDidChange?()
        UIAccessibility.post(notification: .layoutChanged, argument: self.summaryButton)
    }

    private func userSelected(_ selection: TasksCalendarSelection) {
        self.announcesNextSummary = true
        self.selectCalendar?(selection)
        // Nothing changed (the same day again): the board does not update, so nothing is announced.
        self.announcesNextSummary = false
    }
}

// MARK: - Month calendar

/// The compact month presentation (iOS 16.2+) or the unchanged older-system wheel picker.
@MainActor
private protocol TasksCalendarControl: AnyObject {
    var view: UIView { get }
    var selectDay: ((TasksCalendarDay) -> Void)? { get set }
    var heightDidChange: (() -> Void)? { get set }
    /// Localized, capped digits for a day's task count.
    var formatCount: ((Int) -> String)? { get set }
    /// Diffs against what this calendar itself last showed, so markers of days that lost their tasks
    /// (while the calendar was hidden too) are cleared.
    func update(content: TasksCalendarHeaderContent, animated: Bool)
    /// Brings the month containing `day` into view (no selection change).
    func showMonth(of day: TasksCalendarDay, animated: Bool)
    func fittingHeight(width: CGFloat) -> CGFloat
}

@MainActor
private func tasksCalendarFittingHeight(_ view: UIView, width: CGFloat) -> CGFloat {
    let size = view.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    return ceil(size.height)
}

@MainActor
private final class TasksCompactCalendarControl: TasksCalendarControl {
    private let monthView = TasksCalendarMonthGridView()

    var view: UIView { return self.monthView }
    var selectDay: ((TasksCalendarDay) -> Void)? {
        get { return self.monthView.selectDay }
        set { self.monthView.selectDay = newValue }
    }
    var heightDidChange: (() -> Void)? {
        get { return self.monthView.heightDidChange }
        set { self.monthView.heightDidChange = newValue }
    }
    var formatCount: ((Int) -> String)? {
        get { return self.monthView.formatCount }
        set { self.monthView.formatCount = newValue }
    }

    func update(content: TasksCalendarHeaderContent, animated: Bool) {
        self.monthView.update(content: content)
    }

    func showMonth(of day: TasksCalendarDay, animated: Bool) {
        self.monthView.showMonth(of: day)
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        return self.monthView.preferredHeight(width: width)
    }
}

@MainActor
private final class TasksDatePickerCalendarControl: NSObject, TasksCalendarControl {
    private let picker = UIDatePicker()

    var selectDay: ((TasksCalendarDay) -> Void)?
    var heightDidChange: (() -> Void)?
    /// Unused: the picker shows no per-day markers.
    var formatCount: ((Int) -> String)?

    var view: UIView {
        return self.picker
    }

    /// Wheels, not the inline calendar: their height does not depend on the shown month, so the
    /// header never needs a month-change callback (which older systems do not have).
    override init() {
        super.init()
        self.picker.datePickerMode = .date
        if #available(iOS 13.4, *) {
            self.picker.preferredDatePickerStyle = .wheels
        }
        self.picker.addTarget(self, action: #selector(self.pickerChanged), for: .valueChanged)
    }

    func update(content: TasksCalendarHeaderContent, animated: Bool) {
        let calendar = content.calendar
        if self.picker.calendar != calendar {
            self.picker.calendar = calendar
        }
        if self.picker.locale != calendar.locale {
            self.picker.locale = calendar.locale
        }
        if self.picker.timeZone != calendar.timeZone {
            self.picker.timeZone = calendar.timeZone
        }
        self.picker.tintColor = content.colors.accent
        self.picker.overrideUserInterfaceStyle = content.colors.isDark ? .dark : .light
        // The picker always shows a date; under No Deadline the buttons and the summary say so.
        if case let .day(day) = content.selection, TasksCalendarDay(date: self.picker.date, calendar: calendar) != day, let date = day.date(calendar: calendar) {
            self.picker.setDate(date, animated: animated)
        }
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        return tasksCalendarFittingHeight(self.picker, width: width)
    }

    func showMonth(of day: TasksCalendarDay, animated: Bool) {
        guard let date = day.date(calendar: self.picker.calendar) else {
            return
        }
        self.picker.setDate(date, animated: animated)
    }

    @objc private func pickerChanged() {
        self.selectDay?(TasksCalendarDay(date: self.picker.date, calendar: self.picker.calendar))
    }
}


// MARK: - Today / No Deadline

/// An icon plus text. Plain (clear, primary text, accent icon) until chosen; chosen: a subtle card
/// fill, accent text, a checkmark icon and the selected trait, so the state never depends on colour
/// alone. Text wraps instead of being cut; never under 44 pt tall.
private final class TasksCalendarActionButton: UIControl {
    private static let horizontalInset: CGFloat = 12.0
    private static let verticalInset: CGFloat = 8.0
    private static let iconSpacing: CGFloat = 6.0

    private let iconView = UIImageView()
    private let label = UILabel()
    private var font = UIFont.systemFont(ofSize: 15.0, weight: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerRadius = 12.0
        self.iconView.contentMode = .center
        self.iconView.isUserInteractionEnabled = false
        self.label.numberOfLines = 0
        self.label.lineBreakMode = .byWordWrapping
        self.label.isUserInteractionEnabled = false
        self.addSubview(self.iconView)
        self.addSubview(self.label)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(symbolName: String, title: String, isChosen: Bool, colors: TasksCalendarHeaderColors, font: UIFont) {
        self.font = font
        let foreground = isChosen ? colors.accent : colors.primaryText
        self.backgroundColor = isChosen ? colors.card : .clear
        self.iconView.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium))
        self.iconView.tintColor = colors.accent
        self.label.font = font
        self.label.textColor = foreground
        self.label.text = title
        self.accessibilityTraits = isChosen ? [.button, .selected] : .button
        self.setNeedsLayout()
    }

    private var iconWidth: CGFloat {
        return ceil(self.font.pointSize * 1.4)
    }

    private func textWidth(forWidth width: CGFloat) -> CGFloat {
        return max(1.0, width - TasksCalendarActionButton.horizontalInset * 2.0 - self.iconWidth - TasksCalendarActionButton.iconSpacing)
    }

    private func textHeight(forWidth width: CGFloat) -> CGFloat {
        let size = self.label.sizeThatFits(CGSize(width: self.textWidth(forWidth: width), height: CGFloat.greatestFiniteMagnitude))
        return max(ceil(self.font.lineHeight), ceil(size.height))
    }

    /// The width that shows the whole title on one line.
    var singleLineWidth: CGFloat {
        let size = self.label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return TasksCalendarActionButton.horizontalInset * 2.0 + self.iconWidth + TasksCalendarActionButton.iconSpacing + ceil(size.width)
    }

    func rowHeight(forWidth width: CGFloat) -> CGFloat {
        return max(tasksCalendarMinimumHitSize, self.textHeight(forWidth: width) + TasksCalendarActionButton.verticalInset * 2.0)
    }

    /// Icon then text in reading order: mirrored in a right-to-left layout.
    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = TasksCalendarActionButton.horizontalInset
        let iconWidth = self.iconWidth
        let textWidth = self.textWidth(forWidth: self.bounds.width)
        let textHeight = min(self.bounds.height, self.textHeight(forWidth: self.bounds.width))
        let isRightToLeft = self.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let iconX = isRightToLeft ? self.bounds.width - inset - iconWidth : inset
        self.iconView.frame = CGRect(x: iconX, y: floor((self.bounds.height - iconWidth) / 2.0), width: iconWidth, height: iconWidth)
        let labelX = isRightToLeft ? iconX - TasksCalendarActionButton.iconSpacing - textWidth : iconX + iconWidth + TasksCalendarActionButton.iconSpacing
        self.label.frame = CGRect(x: labelX, y: floor((self.bounds.height - textHeight) / 2.0), width: textWidth, height: textHeight)
        self.label.textAlignment = isRightToLeft ? .right : .left
    }

    override var isHighlighted: Bool {
        didSet {
            self.alpha = self.isHighlighted ? 0.6 : 1.0
        }
    }
}
