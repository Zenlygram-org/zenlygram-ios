import Foundation
import UIKit

/// Presentation only. All dates come from the board's calendar and existing civil-day type.
/// Narrow/large-text layouts use the same date buttons as a chronological list, never smaller targets.
final class TasksCalendarMonthGridView: UIView, UIPickerViewDataSource, UIPickerViewDelegate, UIPickerViewAccessibilityDelegate {
    private static let minimumTarget: CGFloat = 44.0
    private static let gap: CGFloat = 4.0
    private let supportedDates = DateInterval(start: .distantPast, end: .distantFuture)
    private let monthButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let picker = UIPickerView()
    private let doneButton = UIButton(type: .system)
    private let measuringLabel = UILabel()
    private let monthFormatter = DateFormatter()
    private let dayFormatter = DateFormatter()
    private let numberFormatter = NumberFormatter()
    private var weekdays: [UILabel] = []
    private var dayButtons: [TasksCalendarGridDayButton] = []
    private var content: TasksCalendarHeaderContent?
    private var visibleMonth: TasksCalendarDay?
    private var days: [TasksCalendarDay] = []
    private var dayPositions: [(row: Int, column: Int)] = []
    private var weekRowCount = 0
    private var monthNames: [String] = []
    private var yearRange: ClosedRange<Int>?
    private var pickerMonths: [Int] = []
    private var isPickingMonth = false
    private var focusedDay: TasksCalendarDay?
    private var keyboardFocusVisible = false
    private var focusGeneration: UInt = 0
    private var dateFont = UIFont.systemFont(ofSize: 20.0)
    private var countFont = UIFont.systemFont(ofSize: 10.0, weight: .semibold)
    private var navigationFont = UIFont.systemFont(ofSize: 17.0, weight: .semibold)

    var selectDay: ((TasksCalendarDay) -> Void)?
    var heightDidChange: (() -> Void)?
    var formatCount: ((Int) -> String)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.monthButton.titleLabel?.numberOfLines = 0
        self.monthButton.addTarget(self, action: #selector(togglePicker), for: .touchUpInside)
        self.previousButton.addTarget(self, action: #selector(previousMonth), for: .touchUpInside)
        self.nextButton.addTarget(self, action: #selector(nextMonth), for: .touchUpInside)
        self.doneButton.addTarget(self, action: #selector(closePicker), for: .touchUpInside)
        self.picker.dataSource = self
        self.picker.delegate = self
        self.picker.isHidden = true
        self.doneButton.isHidden = true
        for view in [self.monthButton, self.previousButton, self.nextButton, self.picker, self.doneButton] {
            self.addSubview(view)
        }
        for _ in 0..<7 {
            let label = UILabel()
            label.textAlignment = .center
            label.isAccessibilityElement = false
            self.addSubview(label)
            self.weekdays.append(label)
        }
        self.measuringLabel.numberOfLines = 0
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let gesture = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            gesture.direction = direction
            self.addGestureRecognizer(gesture)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(content: TasksCalendarHeaderContent) {
        guard self.content != content else { return }
        let previous = self.content
        self.content = content
        let calendarChanged = previous?.calendar != content.calendar
        if previous?.selection != content.selection || calendarChanged {
            self.clearKeyboardCursor()
        }
        if calendarChanged {
            for formatter in [self.monthFormatter, self.dayFormatter] {
                formatter.calendar = content.calendar
                formatter.locale = content.calendar.locale
                formatter.timeZone = content.calendar.timeZone
            }
            self.monthFormatter.setLocalizedDateFormatFromTemplate("yMMMM")
            self.dayFormatter.dateStyle = .full
            self.dayFormatter.timeStyle = .none
            self.numberFormatter.locale = content.calendar.locale
            self.numberFormatter.numberStyle = .decimal
            self.numberFormatter.usesGroupingSeparator = false
            self.monthNames = content.calendar.standaloneMonthSymbols
            let first = content.calendar.component(.year, from: self.supportedDates.start)
            let last = content.calendar.component(.year, from: self.supportedDates.end)
            let lower = self.availableMonths(in: first).isEmpty ? first + 1 : first
            let upper = self.availableMonths(in: last).isEmpty ? last - 1 : last
            self.yearRange = lower <= upper ? lower...upper : nil
        }
        if previous?.fontSize != content.fontSize {
            self.updateFonts()
        }
        if self.visibleMonth == nil {
            if case let .day(day) = content.selection {
                self.visibleMonth = TasksCalendarDay(year: day.year, month: day.month, day: 1)
            } else {
                self.visibleMonth = TasksCalendarDay(year: content.today.year, month: content.today.month, day: 1)
            }
        } else if case let .day(day) = content.selection, previous?.selection != content.selection || calendarChanged {
            self.visibleMonth = TasksCalendarDay(year: day.year, month: day.month, day: 1)
        }
        self.rebuildMonth()
    }

    func showMonth(of day: TasksCalendarDay) {
        self.browseMonth(TasksCalendarDay(year: day.year, month: day.month, day: 1))
    }

    private func updateFonts() {
        let baseSize = max(17.0, self.content?.fontSize ?? 17.0)
        self.dateFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: baseSize + 3.0), compatibleWith: self.traitCollection)
        self.countFont = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 10.0, weight: .semibold), compatibleWith: self.traitCollection)
        self.navigationFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: baseSize, weight: .semibold), compatibleWith: self.traitCollection)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != self.traitCollection.preferredContentSizeCategory || previousTraitCollection?.layoutDirection != self.traitCollection.layoutDirection {
            self.updateFonts()
            self.rebuildMonth()
        }
    }

    private func monthDate(_ month: TasksCalendarDay) -> Date? {
        guard let calendar = self.content?.calendar, let date = month.date(calendar: calendar), calendar.component(.year, from: date) == month.year, calendar.component(.month, from: date) == month.month, let interval = calendar.dateInterval(of: .month, for: date), self.intersectsSupportedDates(interval) else {
            return nil
        }
        return date
    }

    private func intersectsSupportedDates(_ interval: DateInterval) -> Bool {
        // A civil day is available when any of it is inside the native calendar's original range.
        return interval.start <= self.supportedDates.end && interval.end > self.supportedDates.start
    }

    private func supportedDayDate(_ day: TasksCalendarDay) -> Date? {
        guard let calendar = self.content?.calendar, let date = day.date(calendar: calendar), TasksCalendarDay(date: date, calendar: calendar) == day, let interval = calendar.dateInterval(of: .day, for: date), self.intersectsSupportedDates(interval) else { return nil }
        return date
    }

    private func availableMonths(in year: Int) -> [Int] {
        return (1...12).filter { self.monthDate(TasksCalendarDay(year: year, month: $0, day: 1)) != nil }
    }

    private func adjacentMonth(_ offset: Int) -> TasksCalendarDay? {
        guard let calendar = self.content?.calendar, let month = self.visibleMonth, let date = self.monthDate(month), let adjacent = calendar.date(byAdding: .month, value: offset, to: date) else {
            return nil
        }
        let day = TasksCalendarDay(date: adjacent, calendar: calendar)
        let result = TasksCalendarDay(year: day.year, month: day.month, day: 1)
        return self.monthDate(result) == nil ? nil : result
    }

    private func rebuildMonth() {
        guard let content = self.content, let month = self.visibleMonth, let first = self.monthDate(month), let range = content.calendar.range(of: .day, in: .month, for: first) else {
            return
        }
        self.days = []
        self.dayPositions = []
        self.weekRowCount = 0
        var previousWeek: Date?
        for number in range {
            let day = TasksCalendarDay(year: month.year, month: month.month, day: number)
            guard let date = day.date(calendar: content.calendar), TasksCalendarDay(date: date, calendar: content.calendar) == day, let week = content.calendar.dateInterval(of: .weekOfYear, for: date) else { continue }
            if previousWeek != week.start {
                self.weekRowCount += 1
                previousWeek = week.start
            }
            guard self.supportedDayDate(day) != nil else { continue }
            self.days.append(day)
            let column = (content.calendar.component(.weekday, from: date) - content.calendar.firstWeekday + 7) % 7
            self.dayPositions.append((self.weekRowCount - 1, column))
        }
        while self.dayButtons.count < self.days.count {
            let button = TasksCalendarGridDayButton()
            button.addTarget(self, action: #selector(dayPressed(_:)), for: .touchUpInside)
            button.focusChanged = { [weak self] day in
                self?.focusedDay = day
                self?.clearKeyboardCursor()
            }
            button.focusEnded = { [weak self] in self?.clearKeyboardCursor() }
            self.addSubview(button)
            self.dayButtons.append(button)
        }
        self.updateNavigation()
        let symbols = content.calendar.shortStandaloneWeekdaySymbols
        for index in 0..<7 {
            let label = self.weekdays[index]
            label.text = symbols[(content.calendar.firstWeekday - 1 + index) % 7]
            label.font = self.countFont
            label.textColor = content.colors.primaryText
        }
        for (index, button) in self.dayButtons.enumerated() {
            guard index < self.days.count else {
                button.isHidden = true
                button.day = nil
                continue
            }
            let day = self.days[index]
            guard let date = day.date(calendar: content.calendar) else { continue }
            let count = content.dayCounts[day] ?? 0
            let fullDate = self.dayFormatter.string(from: date)
            let isToday = day == content.today
            button.configure(day: day, number: self.numberFormatter.string(from: NSNumber(value: day.day)) ?? String(day.day), fullDate: fullDate, count: count > 0 ? self.formatCount?(count) : nil, countDescription: count > 0 ? content.texts.positiveTaskCountDescriptions[count] : nil, isToday: isToday, todayText: content.texts.today, selected: content.selection == .day(day), dateFont: self.dateFont, countFont: self.countFont, colors: content.colors)
            button.keyboardFocusOverride = self.keyboardFocusVisible ? self.focusedDay == day : nil
        }
        self.reloadPicker()
        self.setNeedsLayout()
        self.heightDidChange?()
    }

    private func updateNavigation() {
        guard let content = self.content, let month = self.visibleMonth, let date = self.monthDate(month) else { return }
        let rtl = self.effectiveUserInterfaceLayoutDirection == .rightToLeft
        self.monthButton.setTitle(self.monthFormatter.string(from: date), for: .normal)
        self.monthButton.accessibilityHint = content.texts.chooseMonth
        self.monthButton.accessibilityTraits = self.isPickingMonth ? [.button, .selected] : [.button]
        self.previousButton.setImage(UIImage(systemName: rtl ? "chevron.right" : "chevron.left"), for: .normal)
        self.nextButton.setImage(UIImage(systemName: rtl ? "chevron.left" : "chevron.right"), for: .normal)
        self.previousButton.accessibilityLabel = content.texts.previousMonth
        self.nextButton.accessibilityLabel = content.texts.nextMonth
        self.previousButton.isEnabled = self.adjacentMonth(-1) != nil
        self.nextButton.isEnabled = self.adjacentMonth(1) != nil
        for button in [self.monthButton, self.previousButton, self.nextButton, self.doneButton] {
            button.tintColor = content.colors.accent
            button.titleLabel?.font = self.navigationFont
        }
        self.doneButton.setTitle(content.texts.monthPickerDone, for: .normal)
        self.picker.accessibilityLabel = content.texts.chooseMonth
        self.picker.overrideUserInterfaceStyle = content.colors.isDark ? .dark : .light
    }

    private struct Layout {
        var title: CGRect = .zero
        var previous: CGRect = .zero
        var next: CGRect = .zero
        var weekdays: [CGRect] = []
        var days: [CGRect] = []
        var picker: CGRect = .zero
        var done: CGRect = .zero
        var isList = false
        var height: CGFloat = 0.0
    }

    private func layout(width: CGFloat) -> Layout {
        var result = Layout()
        let target = Self.minimumTarget
        let gap = Self.gap
        let rtl = self.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let titleWidth = max(0.0, width - target * 2.0 - gap * 2.0)
        self.measuringLabel.font = self.navigationFont
        self.measuringLabel.text = self.monthButton.title(for: .normal)
        let titleSize = self.measuringLabel.sizeThatFits(CGSize(width: max(1.0, titleWidth), height: .greatestFiniteMagnitude))
        let stacksNavigation = titleSize.height > self.navigationFont.lineHeight * 1.5 || titleWidth < target
        if stacksNavigation {
            let height = max(target, ceil(self.measuringLabel.sizeThatFits(CGSize(width: max(1.0, width), height: .greatestFiniteMagnitude)).height) + gap * 2.0)
            result.title = CGRect(x: 0, y: 0, width: width, height: height)
            result.previous = CGRect(x: rtl ? width - target : 0, y: height + gap, width: target, height: target)
            result.next = CGRect(x: rtl ? 0 : width - target, y: height + gap, width: target, height: target)
            result.height = height + gap + target
        } else {
            let height = max(target, ceil(titleSize.height) + gap * 2.0)
            result.title = CGRect(x: rtl ? target * 2.0 + gap * 2.0 : 0, y: 0, width: titleWidth, height: height)
            result.previous = CGRect(x: rtl ? target + gap : width - target * 2.0 - gap, y: 0, width: target, height: height)
            result.next = CGRect(x: rtl ? 0 : width - target, y: 0, width: target, height: height)
            result.height = height
        }
        if self.isPickingMonth {
            let natural = self.picker.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let pickerHeight = max(natural, self.pickerRowHeight(width: width) * 3.0)
            result.picker = CGRect(x: 0, y: result.height + gap, width: width, height: pickerHeight)
            result.done = CGRect(x: 0, y: result.picker.maxY + gap, width: width, height: max(target, ceil(self.navigationFont.lineHeight) + gap * 2.0))
            result.height = result.done.maxY + gap
            return result
        }
        let activeButtons = self.dayButtons.prefix(self.days.count)
        let minimumColumn = activeButtons.reduce(target) { max($0, $1.minimumGridWidth) }
        let weekdayMinimum = self.weekdays.reduce(CGFloat.zero) { max($0, ceil($1.intrinsicContentSize.width) + gap) }
        result.isList = width < max(minimumColumn, weekdayMinimum) * 7.0
        var y = result.height + gap * 2.0
        if result.isList {
            for button in activeButtons {
                let height = button.preferredHeight(width: width, asList: true)
                result.days.append(CGRect(x: 0, y: y, width: width, height: height))
                y += height + gap
            }
        } else {
            let columnWidth = width / 7.0
            let weekdayHeight = ceil(self.countFont.lineHeight) + gap * 2.0
            for index in 0..<7 {
                let column = rtl ? 6 - index : index
                result.weekdays.append(CGRect(x: CGFloat(column) * columnWidth, y: y, width: columnWidth, height: weekdayHeight))
            }
            y += weekdayHeight + gap
            let rowHeight = activeButtons.reduce(target) { max($0, $1.preferredHeight(width: columnWidth, asList: false)) }
            for position in self.dayPositions {
                let column = rtl ? 6 - position.column : position.column
                result.days.append(CGRect(x: CGFloat(column) * columnWidth, y: y + CGFloat(position.row) * rowHeight, width: columnWidth, height: rowHeight))
            }
            y += CGFloat(self.weekRowCount) * rowHeight
        }
        result.height = ceil(y + gap)
        return result
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        return self.layout(width: width).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = self.layout(width: self.bounds.width)
        self.monthButton.frame = layout.title
        self.previousButton.frame = layout.previous
        self.nextButton.frame = layout.next
        self.picker.isHidden = !self.isPickingMonth
        self.doneButton.isHidden = !self.isPickingMonth
        self.picker.frame = layout.picker
        self.doneButton.frame = layout.done
        for (index, label) in self.weekdays.enumerated() {
            label.isHidden = self.isPickingMonth || layout.isList
            if index < layout.weekdays.count { label.frame = layout.weekdays[index] }
        }
        for (index, button) in self.dayButtons.enumerated() {
            button.isHidden = index >= layout.days.count
            if index < layout.days.count {
                button.setListPresentation(layout.isList)
                button.frame = layout.days[index]
            }
        }
        let navigation: [Any] = [self.monthButton, self.previousButton, self.nextButton]
        let choices: [Any] = self.isPickingMonth ? [self.picker, self.doneButton] : self.dayButtons.prefix(self.days.count).map { $0 as Any }
        self.accessibilityElements = navigation + choices
    }

    private func browseMonth(_ month: TasksCalendarDay) {
        guard self.monthDate(month) != nil, self.visibleMonth != month else { return }
        self.visibleMonth = month
        self.focusGeneration &+= 1
        self.rebuildMonth()
    }

    private func navigateMonth(_ offset: Int) {
        guard let month = self.adjacentMonth(offset) else { return }
        self.browseMonth(month)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: self.monthButton.title(for: .normal))
        }
    }

    @objc private func previousMonth() { self.navigateMonth(-1) }
    @objc private func nextMonth() { self.navigateMonth(1) }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard !self.isPickingMonth else { return }
        let isNext = (gesture.direction == .left) != (self.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        self.navigateMonth(isNext ? 1 : -1)
    }

    @objc private func dayPressed(_ button: TasksCalendarGridDayButton) {
        guard let day = button.day else { return }
        self.clearKeyboardCursor()
        self.focusedDay = day
        self.selectDay?(day)
    }

    @objc private func togglePicker() {
        self.isPickingMonth.toggle()
        self.reloadPicker()
        self.updateNavigation()
        self.setNeedsLayout()
        self.heightDidChange?()
        self.endEditing(false)
        self.focusGeneration &+= 1
        let generation = self.focusGeneration
        let opensPicker = self.isPickingMonth
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.focusGeneration, self.window != nil, !self.isHidden, self.superview?.isHidden == false, self.isPickingMonth == opensPicker else { return }
            self.layoutIfNeeded()
            guard !opensPicker || !self.picker.isHidden else { return }
            UIAccessibility.post(notification: .layoutChanged, argument: opensPicker ? self.picker : self.monthButton)
        }
    }

    @objc private func closePicker() {
        guard self.isPickingMonth else { return }
        self.togglePicker()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard self.isPickingMonth else { return false }
        self.closePicker()
        return true
    }

    private var monthPickerComponent: Int {
        return self.effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 : 0
    }

    private func reloadPicker() {
        guard let month = self.visibleMonth else { return }
        self.pickerMonths = self.availableMonths(in: month.year)
        self.picker.reloadAllComponents()
        if let row = self.pickerMonths.firstIndex(of: month.month) {
            self.picker.selectRow(row, inComponent: self.monthPickerComponent, animated: false)
        }
        if let yearRange = self.yearRange, yearRange.contains(month.year) {
            self.picker.selectRow(month.year - yearRange.lowerBound, inComponent: 1 - self.monthPickerComponent, animated: false)
        }
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int { return 2 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return component == self.monthPickerComponent ? self.pickerMonths.count : (self.yearRange?.count ?? 0)
    }

    private func pickerTitle(row: Int, component: Int) -> String {
        if component == self.monthPickerComponent {
            guard self.pickerMonths.indices.contains(row) else { return "" }
            let month = self.pickerMonths[row]
            return self.monthNames.indices.contains(month - 1) ? self.monthNames[month - 1] : ""
        }
        guard let yearRange = self.yearRange, row >= 0, row < yearRange.count else { return "" }
        let year = yearRange.lowerBound + row
        return self.numberFormatter.string(from: NSNumber(value: year)) ?? String(year)
    }

    private func pickerRowHeight(width: CGFloat) -> CGFloat {
        self.measuringLabel.font = self.navigationFont
        let available = max(1.0, width / 2.0 - Self.gap * 2.0)
        return self.monthNames.reduce(max(Self.minimumTarget, ceil(self.navigationFont.lineHeight) + Self.gap * 2.0)) { height, title in
            self.measuringLabel.text = title
            return max(height, ceil(self.measuringLabel.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height) + Self.gap * 2.0)
        }
    }

    func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat {
        return self.pickerRowHeight(width: pickerView.bounds.width)
    }

    func pickerView(_ pickerView: UIPickerView, widthForComponent component: Int) -> CGFloat {
        return pickerView.bounds.width / 2.0
    }

    func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
        let label = (view as? UILabel) ?? UILabel()
        label.text = self.pickerTitle(row: row, component: component)
        label.font = self.navigationFont
        label.textColor = self.content?.colors.primaryText
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }

    func pickerView(_ pickerView: UIPickerView, accessibilityLabelForComponent component: Int) -> String? {
        guard let month = self.visibleMonth else { return self.content?.texts.chooseMonth }
        return component == self.monthPickerComponent ? self.monthNames[month.month - 1] : self.numberFormatter.string(from: NSNumber(value: month.year))
    }

    func pickerView(_ pickerView: UIPickerView, accessibilityHintForComponent component: Int) -> String? {
        return self.content?.texts.chooseMonth
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        guard let month = self.visibleMonth, let yearRange = self.yearRange else { self.reloadPicker(); return }
        let year = component == self.monthPickerComponent ? month.year : yearRange.lowerBound + row
        let chosenMonth: Int
        if component == self.monthPickerComponent {
            guard self.pickerMonths.indices.contains(row) else { self.reloadPicker(); return }
            chosenMonth = self.pickerMonths[row]
        } else {
            guard yearRange.contains(year) else { self.reloadPicker(); return }
            let available = self.availableMonths(in: year)
            guard let validMonth = available.min(by: { abs($0 - month.month) < abs($1 - month.month) }) else { self.reloadPicker(); return }
            chosenMonth = validMonth
        }
        self.browseMonth(TasksCalendarDay(year: year, month: chosenMonth, day: 1))
    }

    private func clearKeyboardCursor() {
        self.keyboardFocusVisible = false
        self.focusGeneration &+= 1
        for button in self.dayButtons { button.keyboardFocusOverride = nil }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if self.keyboardFocusVisible, let day = self.focusedDay, let button = self.dayButtons.first(where: { $0.day == day && !$0.isHidden }) {
            return [button]
        }
        return super.preferredFocusEnvironments
    }

    override var keyCommands: [UIKeyCommand]? {
        if self.isPickingMonth {
            return [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleKey(_:)))]
        }
        guard self.dayButtons.contains(where: { $0.isFirstResponder }) else { return super.keyCommands }
        return [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", " ", UIKeyCommand.inputEscape].map {
            UIKeyCommand(input: $0, modifierFlags: [], action: #selector(handleKey(_:)))
        }
    }

    @objc private func handleKey(_ command: UIKeyCommand) {
        guard let input = command.input, let content = self.content else { return }
        if input == UIKeyCommand.inputEscape { self.closePicker(); return }
        let start = self.focusedDay.flatMap { self.days.contains($0) ? $0 : nil } ?? self.days.first(where: { content.selection == .day($0) }) ?? self.days.first
        guard let start else { return }
        if input == "\r" || input == " " { self.selectDay?(start); return }
        let rtl = self.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let offset: Int
        switch input {
        case UIKeyCommand.inputLeftArrow: offset = rtl ? 1 : -1
        case UIKeyCommand.inputRightArrow: offset = rtl ? -1 : 1
        case UIKeyCommand.inputUpArrow: offset = self.layout(width: self.bounds.width).isList ? -1 : -7
        case UIKeyCommand.inputDownArrow: offset = self.layout(width: self.bounds.width).isList ? 1 : 7
        default: return
        }
        guard let date = start.date(calendar: content.calendar), let nextDate = content.calendar.date(byAdding: .day, value: offset, to: date) else { return }
        let day = TasksCalendarDay(date: nextDate, calendar: content.calendar)
        guard self.supportedDayDate(day) != nil else { return }
        self.focusedDay = day
        self.keyboardFocusVisible = true
        self.showMonth(of: day)
        for button in self.dayButtons { button.keyboardFocusOverride = button.day == day }
        self.focusGeneration &+= 1
        let generation = self.focusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.focusGeneration, self.focusedDay == day, self.window != nil, !self.isHidden, self.superview?.isHidden == false, self.content?.mode == .calendar, !self.isPickingMonth else { return }
            self.layoutIfNeeded()
            guard let button = self.dayButtons.first(where: { $0.day == day && !$0.isHidden }) else { return }
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            _ = button.becomeFirstResponder()
            var ancestor = self.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    scrollView.scrollRectToVisible(button.convert(button.bounds, to: scrollView), animated: !UIAccessibility.isReduceMotionEnabled)
                    break
                }
                ancestor = view.superview
            }
            if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .layoutChanged, argument: button) }
        }
    }
}

private final class TasksCalendarGridDayButton: UIControl {
    var day: TasksCalendarDay?
    var focusChanged: ((TasksCalendarDay) -> Void)?
    var focusEnded: (() -> Void)?
    private let dateLabel = UILabel()
    private let countLabel = UILabel()
    private let todayBar = UIView()
    private let selectionBackground = UIView()
    private var shortDate = ""
    private var fullDate = ""
    private var isList = false
    private var dateFont = UIFont.systemFont(ofSize: 20.0)
    private var countFont = UIFont.systemFont(ofSize: 10.0)
    var keyboardFocusOverride: Bool? {
        didSet { self.updateFocusAppearance() }
    }

    private func updateFocusAppearance() {
        self.layer.borderWidth = (self.keyboardFocusOverride ?? self.isFocused) ? 2.0 : 0.0
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = true
        self.layer.cornerRadius = 6.0
        for view in [self.selectionBackground, self.dateLabel, self.countLabel, self.todayBar] {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            self.addSubview(view)
        }
        self.selectionBackground.layer.cornerRadius = 6.0
        self.todayBar.layer.cornerRadius = 1.5
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { return self.isEnabled && !self.isHidden }
    override var canBecomeFirstResponder: Bool { return true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self, let day = self.day {
            _ = self.becomeFirstResponder()
            self.focusChanged?(day)
        } else if context.previouslyFocusedView === self {
            _ = self.resignFirstResponder()
        }
        self.updateFocusAppearance()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            self.keyboardFocusOverride = nil
            self.focusEnded?()
        }
        return resigned
    }

    override func accessibilityActivate() -> Bool {
        guard self.isEnabled, !self.isHidden, self.day != nil else { return false }
        self.sendActions(for: .touchUpInside)
        return true
    }

    func configure(day: TasksCalendarDay, number: String, fullDate: String, count: String?, countDescription: String?, isToday: Bool, todayText: String, selected: Bool, dateFont: UIFont, countFont: UIFont, colors: TasksCalendarHeaderColors) {
        self.day = day
        self.shortDate = number
        self.fullDate = fullDate
        self.dateFont = dateFont
        self.countFont = countFont
        self.dateLabel.font = dateFont
        self.dateLabel.textColor = colors.primaryText
        self.countLabel.font = countFont
        self.countLabel.text = count
        self.countLabel.textColor = colors.accent
        self.countLabel.isHidden = count == nil
        self.todayBar.isHidden = !isToday
        self.todayBar.backgroundColor = colors.accent
        self.selectionBackground.backgroundColor = colors.accent.withAlphaComponent(colors.isDark ? 0.28 : 0.14)
        self.selectionBackground.isHidden = !selected
        self.selectionBackground.layer.borderWidth = selected ? 1.0 : 0.0
        self.selectionBackground.layer.borderColor = colors.accent.cgColor
        self.layer.borderColor = colors.accent.cgColor
        self.accessibilityLabel = isToday ? "\(todayText), \(fullDate)" : fullDate
        self.accessibilityValue = countDescription
        self.accessibilityTraits = selected ? [.button, .selected] : [.button]
        self.accessibilityIdentifier = "sgtasks.calendar.day.\(day.year).\(day.month).\(day.day)"
        self.accessibilityUserInputLabels = [number, fullDate]
        self.setListPresentation(self.isList)
    }

    var minimumGridWidth: CGFloat {
        let dateWidth = ceil((self.shortDate as NSString).size(withAttributes: [.font: self.dateFont]).width)
        let countWidth = self.countLabel.isHidden ? 0.0 : ceil(self.countLabel.intrinsicContentSize.width)
        return max(44.0, max(dateWidth, countWidth) + 8.0)
    }

    private var markerHeight: CGFloat {
        let countHeight = self.countLabel.isHidden ? 0.0 : ceil(self.countFont.lineHeight)
        return countHeight + (self.todayBar.isHidden ? 0.0 : (countHeight > 0.0 ? 1.0 : 0.0) + 3.0)
    }

    /// Keep date baselines aligned even on unmarked days. This is a font-sized caption slot and
    /// Today bar inside each compact button, not a separate calendar-wide decoration reservation.
    private var gridMarkerHeight: CGFloat {
        return ceil(self.countFont.lineHeight) + 4.0
    }

    func preferredHeight(width: CGFloat, asList: Bool) -> CGFloat {
        let text = asList ? self.fullDate : self.shortDate
        let rect = (text as NSString).boundingRect(with: CGSize(width: max(1.0, width - 8.0), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: self.dateFont], context: nil)
        let markerHeight = asList ? self.markerHeight : self.gridMarkerHeight
        return max(44.0, ceil(rect.height) + (markerHeight > 0.0 ? 2.0 + markerHeight : 0.0) + 6.0)
    }

    func setListPresentation(_ isList: Bool) {
        self.isList = isList
        self.dateLabel.text = isList ? self.fullDate : self.shortDate
        self.dateLabel.numberOfLines = isList ? 0 : 1
        self.dateLabel.textAlignment = isList ? .natural : .center
        self.countLabel.textAlignment = isList ? .natural : .center
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.selectionBackground.frame = self.bounds.insetBy(dx: 2.0, dy: 1.0)
        let width = max(0.0, self.bounds.width - 8.0)
        let dateHeight = ceil(self.dateLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let markerHeight = self.isList ? self.markerHeight : self.gridMarkerHeight
        let total = dateHeight + (markerHeight > 0.0 ? 2.0 + markerHeight : 0.0)
        var y = floor((self.bounds.height - total) / 2.0)
        self.dateLabel.frame = CGRect(x: 4.0, y: y, width: width, height: dateHeight)
        y += dateHeight + 2.0
        if !self.countLabel.isHidden {
            let height = ceil(self.countFont.lineHeight)
            self.countLabel.frame = CGRect(x: 4.0, y: y, width: width, height: height)
            y += height + 1.0
        }
        if !self.isList && self.countLabel.isHidden {
            y += ceil(self.countFont.lineHeight) + 1.0
        }
        let barX = self.isList ? (self.effectiveUserInterfaceLayoutDirection == .rightToLeft ? self.bounds.width - 16.0 : 4.0) : floor((self.bounds.width - 12.0) / 2.0)
        self.todayBar.frame = CGRect(x: barX, y: y, width: 12.0, height: 3.0)
    }
}
