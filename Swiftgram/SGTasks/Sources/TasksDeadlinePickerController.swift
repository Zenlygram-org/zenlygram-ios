import Foundation
import UIKit
import TelegramPresentationData

// Zenlygram — Tasks: the deadline sheet. Today / Tomorrow / In a Week shortcuts above the system
// date-and-time picker (inline calendar on iOS 14+, wheels on iOS 13) in the app language and the
// device time zone, bounded to what storage accepts. Shortcuts and the picker only change the sheet's
// draft; Save commits it, Remove Deadline clears, Cancel, escape and swipe-down change nothing. A
// deadline is a local annotation only: no reminder, notification or message is scheduled. On iOS 16+
// the sheet is only as tall as its content (bottom-anchored, never jumping to full height); content
// taller than the screen allows (landscape, accessibility text sizes) scrolls inside the sheet.

extension TasksBoardAccessibilityId {
    static func deadlineShortcut(_ shortcut: TasksDeadlineShortcut) -> String {
        switch shortcut {
        case .today:
            return "sgtasks.deadline.today"
        case .tomorrow:
            return "sgtasks.deadline.tomorrow"
        case .nextWeek:
            return "sgtasks.deadline.nextWeek"
        }
    }
}

enum TasksDeadlinePickerResult: Equatable {
    case set(Int32)
    case clear
}

/// Presents the deadline sheet above whatever `sourceView`'s window currently shows (the Tasks board
/// or the task editor). `commit` is called at most once, never on cancel. Does nothing while a
/// deadline sheet is already shown or still appearing (a fast double tap).
func presentTasksDeadlinePicker(
    from sourceView: UIView,
    currentDueAt: Int32?,
    presentationData: PresentationData,
    commit: @escaping (TasksDeadlinePickerResult) -> Void,
    dismissed: (() -> Void)? = nil
) {
    guard var presenter = sourceView.window?.rootViewController else {
        return
    }
    while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
        if let navigationController = presented as? UINavigationController, navigationController.viewControllers.first is TasksDeadlinePickerViewController {
            return
        }
        presenter = presented
    }
    let picker = TasksDeadlinePickerViewController(currentDueAt: currentDueAt, presentationData: presentationData, commit: commit, dismissed: dismissed)
    let navigationController = TasksDeadlineNavigationController(rootViewController: picker)
    navigationController.modalPresentationStyle = .pageSheet
    navigationController.overrideUserInterfaceStyle = presentationData.theme.overallDarkAppearance ? .dark : .light
    navigationController.navigationBar.tintColor = presentationData.theme.list.itemAccentColor
    navigationController.presentationController?.delegate = picker
    picker.loadViewIfNeeded()
    if #available(iOS 16.0, *), let sheet = navigationController.sheetPresentationController {
        picker.fitToContent(sheet)
    }
    presenter.present(navigationController, animated: true)
}

final class TasksDeadlinePickerViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let currentDueAt: Int32?
    private let initialDate: Date
    private let presentationData: PresentationData
    private let commit: (TasksDeadlinePickerResult) -> Void
    private let dismissed: (() -> Void)?

    private static let contentInset: CGFloat = 16.0

    private let scrollView = UIScrollView()
    /// Holds everything below the navigation bar; framed by `layoutContent` at its fitting height.
    private let contentView = UIView()
    private let shortcutStack = UIStackView()
    private var shortcutButtons: [TasksDeadlineShortcutButton] = []
    private let picker = UIDatePicker()
    /// The sheet's draft. nil until the picker or a shortcut changes it, so saving an untouched sheet
    /// keeps the stored value to the second (no re-derivation from the minute-precision picker).
    private var chosenDate: Date?
    private var didFinish = false
    /// The sheet height the fitted detent last asked for, so a content change re-resolves it once.
    private var resolvedSheetHeight: CGFloat?

    init(currentDueAt: Int32?, presentationData: PresentationData, commit: @escaping (TasksDeadlinePickerResult) -> Void, dismissed: (() -> Void)?) {
        let validCurrent = currentDueAt.flatMap { $0 >= TasksDeadlineBounds.minimumTimestamp ? $0 : nil }
        self.currentDueAt = validCurrent
        self.initialDate = tasksDeadlineInitialDate(current: validCurrent, now: Date(), calendar: SGTasksL10n(presentationData.strings).tasks_deadlineCalendar)
        self.presentationData = presentationData
        self.commit = commit
        self.dismissed = dismissed
        super.init(nibName: nil, bundle: nil)
    }

    // VoiceOver's two-finger scrub is Cancel.
    override func loadView() {
        let view = TasksDeadlinePickerRootView()
        view.escape = { [weak self] in
            self?.cancelPressed()
            return self != nil
        }
        self.view = view
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var l10n: SGTasksL10n {
        return SGTasksL10n(self.presentationData.strings)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = self.presentationData.theme
        let l10n = self.l10n
        let strings = self.presentationData.strings

        self.title = l10n.tasks_deadline_title
        self.view.backgroundColor = theme.list.blocksBackgroundColor

        let cancelItem = UIBarButtonItem(title: strings.Common_Cancel, style: .plain, target: self, action: #selector(self.cancelPressed))
        cancelItem.accessibilityIdentifier = TasksBoardAccessibilityId.deadlineCancel
        let saveItem = UIBarButtonItem(title: strings.Common_Save, style: .done, target: self, action: #selector(self.savePressed))
        saveItem.accessibilityIdentifier = TasksBoardAccessibilityId.deadlineSave
        self.navigationItem.leftBarButtonItem = cancelItem
        self.navigationItem.rightBarButtonItem = saveItem

        self.picker.datePickerMode = .dateAndTime
        if #available(iOS 13.4, *) {
            if #available(iOS 14.0, *) {
                self.picker.preferredDatePickerStyle = .inline
            } else {
                self.picker.preferredDatePickerStyle = .wheels
            }
        }
        // App language and device time zone, with Telegram's 12/24-hour choice (the same one the
        // board uses to show the saved deadline). Calendar and zone: `applyClockContext`.
        self.picker.locale = l10n.tasks_deadlinePickerLocale(use24HourClock: self.presentationData.dateTimeFormat.timeFormat == .military)
        self.applyClockContext()
        self.picker.minimumDate = TasksDeadlineBounds.minimumDate
        self.picker.maximumDate = TasksDeadlineBounds.maximumDate
        self.picker.date = self.initialDate
        self.picker.tintColor = theme.list.itemAccentColor
        self.picker.accessibilityIdentifier = TasksBoardAccessibilityId.deadlinePicker
        self.picker.accessibilityLabel = l10n.tasks_deadline_title
        self.picker.addTarget(self, action: #selector(self.pickerChanged), for: .valueChanged)
        self.picker.translatesAutoresizingMaskIntoConstraints = false

        self.shortcutStack.spacing = 8.0
        self.shortcutStack.distribution = .fillEqually
        self.shortcutStack.alignment = .fill
        self.shortcutStack.translatesAutoresizingMaskIntoConstraints = false
        for shortcut in TasksDeadlineShortcut.allCases {
            let button = TasksDeadlineShortcutButton(shortcut: shortcut, title: self.shortcutTitle(shortcut), theme: theme)
            button.accessibilityHint = l10n.tasks_a11y_deadlineShortcutHint
            button.accessibilityIdentifier = TasksBoardAccessibilityId.deadlineShortcut(shortcut)
            button.addTarget(self, action: #selector(self.shortcutPressed(_:)), for: .touchUpInside)
            self.shortcutButtons.append(button)
            self.shortcutStack.addArrangedSubview(button)
        }
        self.updateShortcuts()
        // "Today" moves at midnight, on a time zone change and while the app was in the background.
        NotificationCenter.default.addObserver(self, selector: #selector(self.clockChanged), name: UIApplication.significantTimeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.clockChanged), name: UIApplication.didBecomeActiveNotification, object: nil)
        // A text-size change re-measures the content (shortcut axis, wrapped titles) and refits the sheet.
        NotificationCenter.default.addObserver(self, selector: #selector(self.contentSizeCategoryChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)

        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.alwaysBounceVertical = true
        self.view.addSubview(self.scrollView)
        // Horizontal safe-area insets are folded into the margins by `layoutContent`.
        self.contentView.insetsLayoutMarginsFromSafeArea = false
        self.contentView.preservesSuperviewLayoutMargins = false
        self.scrollView.addSubview(self.contentView)
        self.contentView.addSubview(self.shortcutStack)
        self.contentView.addSubview(self.picker)

        let margins = self.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            self.scrollView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.scrollView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.scrollView.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.scrollView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),

            self.shortcutStack.topAnchor.constraint(equalTo: margins.topAnchor),
            self.shortcutStack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            self.shortcutStack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            self.picker.topAnchor.constraint(equalTo: self.shortcutStack.bottomAnchor, constant: 8.0),
            self.picker.centerXAnchor.constraint(equalTo: margins.centerXAnchor),
            self.picker.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor),
            self.picker.trailingAnchor.constraint(lessThanOrEqualTo: margins.trailingAnchor)
        ])
        // Only an existing deadline can be removed; a new one is simply not saved (Cancel), so the
        // sheet does not reserve room for the button.
        let bottomConstraint: NSLayoutConstraint
        if self.currentDueAt != nil {
            let clearButton = TasksDeadlineRemoveButton(title: l10n.tasks_deadline_remove, color: theme.list.itemDestructiveColor)
            clearButton.accessibilityIdentifier = TasksBoardAccessibilityId.deadlineClear
            clearButton.addTarget(self, action: #selector(self.clearPressed), for: .touchUpInside)
            clearButton.translatesAutoresizingMaskIntoConstraints = false
            self.contentView.addSubview(clearButton)
            NSLayoutConstraint.activate([
                clearButton.topAnchor.constraint(equalTo: self.picker.bottomAnchor, constant: 16.0),
                clearButton.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                clearButton.trailingAnchor.constraint(equalTo: margins.trailingAnchor)
            ])
            bottomConstraint = clearButton.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
        } else {
            bottomConstraint = self.picker.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
        }
        // The parent assigns the measured frame after layout. Let the previous frame yield while
        // measuring a new text size or width, rather than breaking a required content constraint.
        bottomConstraint.priority = UILayoutPriority(rawValue: UILayoutPriority.required.rawValue - 1.0)
        bottomConstraint.isActive = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let contentHeight = self.layoutContent() else {
            return
        }
        self.refitSheetIfNeeded(contentHeight: contentHeight)
    }

    /// Frames the content at its fitting height for the current width and returns that height.
    private func layoutContent() -> CGFloat? {
        let width = self.view.bounds.width
        guard width > 0.0 else {
            return nil
        }
        let contentHeight = self.measureContentHeight(width: width)
        let contentFrame = CGRect(x: 0.0, y: 0.0, width: width, height: contentHeight)
        if self.contentView.frame != contentFrame {
            self.contentView.frame = contentFrame
        }
        if self.scrollView.contentSize != contentFrame.size {
            self.scrollView.contentSize = contentFrame.size
        }
        return contentHeight
    }

    /// Height of everything below the navigation bar at `width`: depends on width, safe-area insets
    /// and text size only, never on the sheet's own height (so fitting cannot feed back into itself).
    private func measureContentHeight(width: CGFloat) -> CGFloat {
        let safeInsets = self.view.safeAreaInsets
        let inset = TasksDeadlinePickerViewController.contentInset
        let margins = UIEdgeInsets(top: inset, left: inset + safeInsets.left, bottom: inset, right: inset + safeInsets.right)
        if self.contentView.layoutMargins != margins {
            self.contentView.layoutMargins = margins
        }
        self.updateShortcutStackAxis(rowWidth: width - margins.left - margins.right)
        let size = self.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(size.height)
    }

    /// Navigation bar plus content: the sheet height that shows everything without scrolling. A
    /// detent's height excludes the bottom safe area, which the scroll view already insets.
    private func fittedSheetHeight(contentHeight: CGFloat) -> CGFloat {
        let topInset = self.view.safeAreaInsets.top
        // Before the first layout the safe area is still empty; the bar's own height stands in and
        // `refitSheetIfNeeded` corrects it once the sheet has laid out.
        let barHeight = topInset > 0.0 ? topInset : (self.navigationController?.navigationBar.frame.height ?? 0.0)
        return ceil(barHeight + contentHeight)
    }

    /// One bottom-anchored detent sized to the content, capped at the tallest sheet the screen
    /// allows (then the content scrolls). Scrolling never grows the sheet.
    @available(iOS 16.0, *)
    func fitToContent(_ sheet: UISheetPresentationController) {
        sheet.detents = [.custom(identifier: UISheetPresentationController.Detent.Identifier("sgtasks.deadline.fitted")) { [weak self] context in
            guard let self, let width = self.sheetWidth else {
                return context.maximumDetentValue
            }
            let fitted = self.fittedSheetHeight(contentHeight: self.measureContentHeight(width: width))
            self.resolvedSheetHeight = fitted
            return min(fitted, context.maximumDetentValue)
        }]
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
    }

    /// The width the content is measured at: the sheet's own once laid out, the window's before.
    private var sheetWidth: CGFloat? {
        let width = self.view.bounds.width
        if width > 0.0 {
            return width
        }
        let windowWidth = self.navigationController?.presentingViewController?.view.window?.bounds.width ?? 0.0
        return windowWidth > 0.0 ? windowWidth : nil
    }

    @objc private func contentSizeCategoryChanged() {
        self.view.setNeedsLayout()
    }

    /// Text size, safe area or width changed the content height: resolve the fitted detent again.
    private func refitSheetIfNeeded(contentHeight: CGFloat) {
        guard #available(iOS 16.0, *),
              let navigationController = self.navigationController,
              let sheet = navigationController.sheetPresentationController,
              let resolvedSheetHeight = self.resolvedSheetHeight else {
            return
        }
        let fitted = self.fittedSheetHeight(contentHeight: contentHeight)
        guard abs(fitted - resolvedSheetHeight) >= 0.5 else {
            return
        }
        self.resolvedSheetHeight = fitted
        if navigationController.isBeingPresented || self.view.window == nil {
            sheet.invalidateDetents()
        } else {
            sheet.animateChanges {
                sheet.invalidateDetents()
            }
        }
    }

    private func shortcutTitle(_ shortcut: TasksDeadlineShortcut) -> String {
        switch shortcut {
        case .today:
            return self.l10n.tasks_relative_today
        case .tomorrow:
            return self.l10n.tasks_relative_tomorrow
        case .nextWeek:
            return self.l10n.tasks_deadline_nextWeek
        }
    }

    /// One row of equal-width buttons while every title word fits its column at the current text
    /// size; otherwise (and at accessibility text sizes) a column, so no word is ever split.
    private func updateShortcutStackAxis(rowWidth: CGFloat) {
        guard rowWidth > 0.0 else {
            return
        }
        let count = CGFloat(self.shortcutButtons.count)
        let titleWidth = (rowWidth - self.shortcutStack.spacing * (count - 1.0)) / count - TasksDeadlineShortcutButton.horizontalPadding * 2.0
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: self.traitCollection)
        let wordsFit = self.shortcutButtons.allSatisfy { $0.longestWordWidth(font: font) <= titleWidth }
        let axis: NSLayoutConstraint.Axis = wordsFit && !self.traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .horizontal : .vertical
        if self.shortcutStack.axis != axis {
            self.shortcutStack.axis = axis
        }
    }

    /// The draft date shortcuts start from: the exact stored or suggested date until something changes.
    private var selectedDate: Date {
        return self.chosenDate ?? self.initialDate
    }

    /// Gregorian in the app language and the current device time zone, like the saved deadline text.
    private func applyClockContext() {
        let calendar = self.l10n.tasks_deadlineCalendar
        self.picker.calendar = calendar
        self.picker.timeZone = calendar.timeZone
    }

    /// Disables a shortcut whose date storage cannot hold and marks the one whose day is selected.
    private func updateShortcuts() {
        let selectedDate = self.selectedDate
        let selectedTimestamp = tasksDeadlineTimestamp(for: selectedDate)
        let now = Date()
        let calendar = self.l10n.tasks_deadlineCalendar
        for button in self.shortcutButtons {
            let target = tasksDeadlineShortcutDate(button.shortcut, selectedDate: selectedDate, now: now, calendar: calendar)
            button.isEnabled = target != nil
            // Same day: the helper returns the selected instant itself.
            button.isSelected = target.flatMap(tasksDeadlineTimestamp(for:)).map { $0 == selectedTimestamp } ?? false
        }
    }

    /// Midnight, a time zone change or a return from the background: re-read the zone, then "today".
    @objc private func clockChanged() {
        self.applyClockContext()
        self.updateShortcuts()
    }

    @objc private func pickerChanged() {
        self.chosenDate = self.picker.date
        self.updateShortcuts()
    }

    /// Changes the draft only (date and picker); nothing is stored until Save.
    @objc private func shortcutPressed(_ sender: TasksDeadlineShortcutButton) {
        let selectedDate = self.selectedDate
        guard !self.didFinish,
              let target = tasksDeadlineShortcutDate(sender.shortcut, selectedDate: selectedDate, now: Date(), calendar: self.l10n.tasks_deadlineCalendar),
              let timestamp = tasksDeadlineTimestamp(for: target) else {
            self.updateShortcuts()
            return
        }
        if target != selectedDate {
            self.chosenDate = target
            self.picker.setDate(target, animated: true)
        }
        self.updateShortcuts()
        let text = self.l10n.tasks_deadline_text(timestamp, use24HourClock: self.presentationData.dateTimeFormat.timeFormat == .military)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    @objc private func cancelPressed() {
        self.finish(result: nil)
    }

    @objc private func savePressed() {
        guard let chosenDate = self.chosenDate else {
            if let currentDueAt = self.currentDueAt {
                self.finish(result: .set(currentDueAt))
            } else if let timestamp = tasksDeadlineTimestamp(for: self.picker.date) {
                self.finish(result: .set(timestamp))
            }
            return
        }
        guard let timestamp = tasksDeadlineTimestamp(for: chosenDate) else {
            // The picker and shortcuts are bounded, so this is unreachable in practice; never store a wrapped value.
            return
        }
        self.finish(result: .set(timestamp))
    }

    @objc private func clearPressed() {
        self.finish(result: .clear)
    }

    private func finish(result: TasksDeadlinePickerResult?) {
        guard !self.didFinish else {
            return
        }
        self.didFinish = true
        let commit = self.commit
        let dismissed = self.dismissed
        self.dismiss(animated: true, completion: {
            if let result {
                commit(result)
            }
            dismissed?()
        })
    }

    // Swipe-down is Cancel.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !self.didFinish else {
            return
        }
        self.didFinish = true
        self.dismissed?()
    }
}

private final class TasksDeadlineNavigationController: UINavigationController {
    override func accessibilityPerformEscape() -> Bool {
        // Navigation-bar focus does not pass through the picker's root view.
        return self.topViewController?.view.accessibilityPerformEscape() ?? false
    }
}

private final class TasksDeadlinePickerRootView: UIView {
    var escape: (() -> Bool)?

    override func accessibilityPerformEscape() -> Bool {
        return self.escape?() ?? false
    }
}

/// A Today / Tomorrow / In a Week choice: at least 44 pt tall, title wrapping between words only.
/// Primary text in every enabled state; the selected one gets a light accent tint plus an accent
/// border, so selection never relies on low-contrast text over a solid accent fill.
private final class TasksDeadlineShortcutButton: UIControl {
    static let horizontalPadding: CGFloat = 8.0
    private static let selectedBorderWidth: CGFloat = 2.0
    private static let selectedFillAlpha: CGFloat = 0.12

    let shortcut: TasksDeadlineShortcut
    private let title: String
    private let titleLabel = UILabel()
    private let theme: PresentationTheme

    init(shortcut: TasksDeadlineShortcut, title: String, theme: PresentationTheme) {
        self.shortcut = shortcut
        self.title = title
        self.theme = theme
        super.init(frame: .zero)
        self.layer.cornerRadius = 10.0
        self.layer.cornerCurve = .continuous
        self.titleLabel.text = title
        self.titleLabel.font = UIFont.preferredFont(forTextStyle: .body)
        self.titleLabel.adjustsFontForContentSizeCategory = true
        self.titleLabel.numberOfLines = 0
        self.titleLabel.lineBreakMode = .byWordWrapping
        self.titleLabel.textAlignment = .center
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.titleLabel)
        NSLayoutConstraint.activate([
            self.titleLabel.topAnchor.constraint(equalTo: self.topAnchor, constant: 10.0),
            self.titleLabel.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -10.0),
            self.titleLabel.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: TasksDeadlineShortcutButton.horizontalPadding),
            self.titleLabel.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -TasksDeadlineShortcutButton.horizontalPadding),
            self.heightAnchor.constraint(greaterThanOrEqualToConstant: tasksMinimumHitSize)
        ])
        self.isAccessibilityElement = true
        self.accessibilityLabel = title
        self.updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Width of the title's widest word in `font`: the narrowest title area that splits no word.
    func longestWordWidth(font: UIFont) -> CGFloat {
        let words = self.title.components(separatedBy: .whitespacesAndNewlines)
        return words.reduce(0.0) { widest, word in
            max(widest, ceil((word as NSString).size(withAttributes: [.font: font]).width))
        }
    }

    override var isSelected: Bool {
        didSet {
            self.updateAppearance()
        }
    }

    override var isEnabled: Bool {
        didSet {
            self.updateAppearance()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            self.alpha = self.isHighlighted ? 0.6 : 1.0
        }
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            var traits: UIAccessibilityTraits = .button
            if self.isSelected {
                traits.insert(.selected)
            }
            if !self.isEnabled {
                traits.insert(.notEnabled)
            }
            return traits
        }
        set {
        }
    }

    private func updateAppearance() {
        let list = self.theme.list
        let isMarked = self.isSelected && self.isEnabled
        self.backgroundColor = isMarked ? list.itemAccentColor.withAlphaComponent(TasksDeadlineShortcutButton.selectedFillAlpha) : list.itemBlocksBackgroundColor
        self.layer.borderColor = list.itemAccentColor.cgColor
        self.layer.borderWidth = isMarked ? TasksDeadlineShortcutButton.selectedBorderWidth : 0.0
        self.titleLabel.textColor = self.isEnabled ? list.itemPrimaryTextColor : list.itemDisabledTextColor
    }
}

/// Remove Deadline: destructive body text that wraps between words at large text sizes and grows the
/// control with it (a system button keeps a one-line height and lets wrapped text spill out), so the
/// fitted sheet measures it fully. At least 44 pt tall.
private final class TasksDeadlineRemoveButton: UIControl {
    private let titleLabel = UILabel()

    init(title: String, color: UIColor) {
        super.init(frame: .zero)
        self.titleLabel.text = title
        self.titleLabel.textColor = color
        self.titleLabel.font = UIFont.preferredFont(forTextStyle: .body)
        self.titleLabel.adjustsFontForContentSizeCategory = true
        self.titleLabel.numberOfLines = 0
        self.titleLabel.lineBreakMode = .byWordWrapping
        self.titleLabel.textAlignment = .center
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.titleLabel)
        NSLayoutConstraint.activate([
            self.titleLabel.topAnchor.constraint(equalTo: self.topAnchor, constant: 10.0),
            self.titleLabel.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -10.0),
            self.titleLabel.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.titleLabel.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.heightAnchor.constraint(greaterThanOrEqualToConstant: tasksMinimumHitSize)
        ])
        self.isAccessibilityElement = true
        self.accessibilityLabel = title
        self.accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            self.alpha = self.isHighlighted ? 0.6 : 1.0
        }
    }
}
