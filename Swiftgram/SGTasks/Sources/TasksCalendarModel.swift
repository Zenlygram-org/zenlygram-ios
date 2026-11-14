import Foundation

// Zenlygram — Tasks calendar: the pure day/undated projection behind the month/day agenda of both the
// device and the Cloud Tasks boards, the time-zone-independent selected day, and the per-day marker
// counts.
//
// Foundation only, so the host board-model tests run it with an injected Calendar / TimeZone. It only
// narrows what a board already shows by the task's existing `dueAt`; it never loads, authorizes or
// stores anything.

/// Which deadline the agenda shows on top of the board's list filter.
public enum TasksCalendarFilter: Equatable {
    /// Every task: the board exactly as it is.
    case all
    /// Tasks due on the local calendar day containing this instant.
    case day(Date)
    /// Tasks without a deadline (`dueAt == nil`; timestamp 0 is a real deadline).
    case noDeadline
}

/// Whether a deadline belongs to the filter. See `TasksCalendarMatcher` for the day rule.
public func tasksCalendarMatches(dueAt: Int32?, filter: TasksCalendarFilter, calendar: Calendar) -> Bool {
    return TasksCalendarMatcher(filter: filter, calendar: calendar).matches(dueAt: dueAt)
}

/// A filter resolved once against a calendar, so projecting a board does one calendar computation per
/// call rather than one per task. A day is the calendar's half-open local day [start of day, start of
/// the next local day), so 23- and 25-hour DST days, days whose midnight is skipped and the injected
/// time zone are honoured; it is never a fixed 86,400-second window.
struct TasksCalendarMatcher {
    private enum Rule {
        case all
        case noDeadline
        /// Unix seconds: `start` inclusive, `end` exclusive.
        case day(start: TimeInterval, end: TimeInterval)
        /// The calendar has no day for the selected instant: nothing is due on it.
        case none
    }

    private let rule: Rule

    init(filter: TasksCalendarFilter, calendar: Calendar) {
        switch filter {
        case .all:
            self.rule = .all
        case .noDeadline:
            self.rule = .noDeadline
        case let .day(date):
            if let day = calendar.dateInterval(of: .day, for: date) {
                self.rule = .day(start: day.start.timeIntervalSince1970, end: day.end.timeIntervalSince1970)
            } else {
                self.rule = .none
            }
        }
    }

    func matches(dueAt: Int32?) -> Bool {
        switch self.rule {
        case .all:
            return true
        case .noDeadline:
            return dueAt == nil
        case let .day(start, end):
            guard let dueAt else {
                return false
            }
            let seconds = TimeInterval(dueAt)
            return start <= seconds && seconds < end
        case .none:
            return false
        }
    }
}

/// A calendar day as year / month / day of a given calendar: independent of the time zone, so a
/// selection survives a time zone change as the same named day.
struct TasksCalendarDay: Hashable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local day (in `calendar`'s time zone) that contains `date`.
    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 0, month: components.month ?? 0, day: components.day ?? 0)
    }

    init?(components: DateComponents) {
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    func components(calendar: Calendar) -> DateComponents {
        return DateComponents(calendar: calendar, year: self.year, month: self.month, day: self.day)
    }

    /// Noon of the day: always inside it, also when a DST change skips or repeats midnight. The
    /// projection maps it back to the whole local day [start, next start).
    func date(calendar: Calendar) -> Date? {
        return calendar.date(from: DateComponents(year: self.year, month: self.month, day: self.day, hour: 12))
    }
}

/// Per-day task counts for the calendar markers, from the projection's due dates. A nil deadline is
/// counted separately (never as 1970-01-01); a timestamp of 0 is a real day.
func tasksCalendarDueDateCounts(_ dueDates: [Int32?], calendar: Calendar) -> (days: [TasksCalendarDay: Int], undated: Int) {
    var days: [TasksCalendarDay: Int] = [:]
    var undated = 0
    for dueAt in dueDates {
        guard let dueAt else {
            undated += 1
            continue
        }
        days[TasksCalendarDay(date: Date(timeIntervalSince1970: TimeInterval(dueAt)), calendar: calendar), default: 0] += 1
    }
    return (days, undated)
}
