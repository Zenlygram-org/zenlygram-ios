import Foundation

// Zenlygram — Tasks: pure rules for a task's local assignee/deadline annotations. Foundation only, so
// `Tests/run-board-model-tests.sh` checks them on the host. The UIKit picker and editor never convert
// dates themselves; they go through these functions.

/// The deadline range storage accepts: a non-negative Unix timestamp that fits in `Int32`.
public enum TasksDeadlineBounds {
    public static let minimumTimestamp: Int32 = 0
    public static let maximumTimestamp: Int32 = Int32.max

    public static var minimumDate: Date {
        return Date(timeIntervalSince1970: TimeInterval(minimumTimestamp))
    }

    public static var maximumDate: Date {
        return Date(timeIntervalSince1970: TimeInterval(maximumTimestamp))
    }
}

/// The stored timestamp for a picked date: whole seconds, rounded down (never into the future).
/// nil for a date storage cannot represent — non-finite, negative or past `Int32.max` — instead of
/// wrapping or clamping it into a different deadline.
public func tasksDeadlineTimestamp(for date: Date) -> Int32? {
    let seconds = date.timeIntervalSince1970
    guard seconds.isFinite,
          seconds >= TimeInterval(TasksDeadlineBounds.minimumTimestamp),
          seconds <= TimeInterval(TasksDeadlineBounds.maximumTimestamp) else {
        return nil
    }
    return Int32(exactly: seconds.rounded(.down))
}

/// The date the picker opens on: the stored deadline exactly (even if overdue), otherwise the start of
/// the next hour of `now` in `calendar`, kept inside the storable range. A negative stored value is
/// treated as absent.
public func tasksDeadlineInitialDate(current: Int32?, now: Date, calendar: Calendar) -> Date {
    if let current, current >= TasksDeadlineBounds.minimumTimestamp {
        return Date(timeIntervalSince1970: TimeInterval(current))
    }
    let nowSeconds = now.timeIntervalSince1970
    guard nowSeconds.isFinite else {
        return TasksDeadlineBounds.minimumDate
    }
    let suggestion: TimeInterval
    // The calendar's hour interval ends at the next real hour boundary, also across a DST gap.
    if let hour = calendar.dateInterval(of: .hour, for: now), hour.end > now {
        suggestion = hour.end.timeIntervalSince1970
    } else {
        suggestion = (nowSeconds / 3600.0).rounded(.down) * 3600.0 + 3600.0
    }
    let lower = TimeInterval(TasksDeadlineBounds.minimumTimestamp)
    let upper = TimeInterval(TasksDeadlineBounds.maximumTimestamp)
    return Date(timeIntervalSince1970: min(max(suggestion, lower), upper))
}

/// The quick date choices in the deadline sheet. Each picks a local calendar day counted from today;
/// the time of day stays the one already selected.
public enum TasksDeadlineShortcut: CaseIterable {
    case today
    case tomorrow
    case nextWeek

    /// Calendar days after today (calendar days, not 24-hour periods).
    var dayOffset: Int {
        switch self {
        case .today:
            return 0
        case .tomorrow:
            return 1
        case .nextWeek:
            return 7
        }
    }
}

/// The date a shortcut moves `selectedDate` to: the local day `now` + 0/1/7 calendar days in
/// `calendar`, at the selected hour, minute and whole second.
///
/// - Already on that day: the selected instant itself (so a repeated DST hour keeps its occurrence),
///   floored to the whole second storage keeps.
/// - Another day: a clock time missing there (DST gap) moves forward keeping minutes and seconds; a
///   repeated one takes its first occurrence.
///
/// nil when either input or the result is outside what storage accepts (`tasksDeadlineTimestamp`),
/// never a clamped, different deadline.
public func tasksDeadlineShortcutDate(_ shortcut: TasksDeadlineShortcut, selectedDate: Date, now: Date, calendar: Calendar) -> Date? {
    guard tasksDeadlineTimestamp(for: now) != nil, let selectedSeconds = tasksDeadlineTimestamp(for: selectedDate) else {
        return nil
    }
    // Step from the middle of today so a day whose midnight is skipped or repeated cannot shift the
    // target to a neighbouring day.
    guard let today = calendar.dateInterval(of: .day, for: now),
          let targetMoment = calendar.date(byAdding: .day, value: shortcut.dayOffset, to: today.start.addingTimeInterval(today.duration / 2.0)),
          let targetDay = calendar.dateInterval(of: .day, for: targetMoment) else {
        return nil
    }
    if calendar.isDate(selectedDate, inSameDayAs: targetDay.start) {
        return Date(timeIntervalSince1970: TimeInterval(selectedSeconds))
    }
    let clock = calendar.dateComponents([.hour, .minute, .second], from: selectedDate)
    guard let result = calendar.nextDate(
        after: targetDay.start.addingTimeInterval(-1.0),
        matching: DateComponents(hour: clock.hour, minute: clock.minute, second: clock.second),
        matchingPolicy: .nextTimePreservingSmallerComponents,
        repeatedTimePolicy: .first,
        direction: .forward
    ), let resultSeconds = tasksDeadlineTimestamp(for: result) else {
        return nil
    }
    return Date(timeIntervalSince1970: TimeInterval(resultSeconds))
}

/// Contact text for display beside other metadata. Remove caller-supplied bidi controls before
/// adding our own isolate, so an embedded PDI cannot escape it. Natural RTL letters and joiners stay.
public func tasksIsolatedDisplayText(_ text: String) -> String {
    let newlines = CharacterSet.newlines
    var result = "\u{2068}"
    result.reserveCapacity(text.utf8.count + 6)
    for scalar in text.unicodeScalars where !scalar.properties.isBidiControl {
        if newlines.contains(scalar) {
            result.append(" ")
        } else {
            result.unicodeScalars.append(scalar)
        }
    }
    result.append("\u{2069}")
    return result
}

/// Assignee and deadline chosen in the quick-add composer and not yet stored. Kept by the board
/// controller across pickers, cancels, reloads, list switches and theme changes; reset only after a
/// task is created with it.
public struct TasksTaskMetadataDraft: Equatable {
    public var assignee: TodoAssignee?
    public var dueAt: Int32?

    public init(assignee: TodoAssignee? = nil, dueAt: Int32? = nil) {
        self.assignee = assignee
        self.dueAt = dueAt
    }

    public static let empty = TasksTaskMetadataDraft()

    public var isEmpty: Bool {
        return self.assignee == nil && self.dueAt == nil
    }
}
