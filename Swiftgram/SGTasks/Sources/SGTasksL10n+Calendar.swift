import Foundation

// Zenlygram — Tasks calendar (List / Calendar view of the Tasks board) strings. Same
// pick(en:uz:ru:) scheme as SGTasksL10n.swift. Dates use the deadline calendar
// (`tasks_deadlineCalendar`: Gregorian, app language, current device time zone).

public extension SGTasksL10n {
    // MARK: - View switch

    var tasks_calendar_viewList: String {
        pick(en: "List", uz: "Roʻyxat", ru: "Список")
    }

    var tasks_calendar_viewCalendar: String {
        pick(en: "Calendar", uz: "Kalendar", ru: "Календарь")
    }

    /// VoiceOver label of the month calendar itself.
    var tasks_calendar_label: String {
        pick(en: "Deadline calendar", uz: "Muddatlar kalendari", ru: "Календарь сроков")
    }

    // MARK: - Day choices (Today reuses tasks_relative_today)

    var tasks_calendar_noDeadline: String {
        pick(en: "No Deadline", uz: "Muddatsiz", ru: "Без срока")
    }

    var tasks_calendar_todayHint: String {
        pick(en: "Shows tasks due today", uz: "Bugun muddati tugaydigan vazifalarni koʻrsatadi", ru: "Показывает задачи со сроком на сегодня")
    }

    var tasks_calendar_noDeadlineHint: String {
        pick(en: "Shows tasks without a deadline", uz: "Muddati belgilanmagan vazifalarni koʻrsatadi", ru: "Показывает задачи без срока")
    }

    /// How many tasks a day (or "No deadline") holds, open and completed together.
    func tasks_calendar_taskCount(_ count: Int) -> String {
        if count == 0 {
            return pick(en: "No tasks", uz: "Vazifalar yoʻq", ru: "Нет задач")
        }
        let ruWord = countRuWord(count, one: "задача", few: "задачи", many: "задач")
        return pick(
            en: count == 1 ? "1 task" : "\(count) tasks",
            uz: "\(count) ta vazifa",
            ru: "\(count) \(ruWord)"
        )
    }

    /// The selected day in full ("Today, Wednesday, October 29, 2026") in the app language, in the
    /// given calendar's time zone, so VoiceOver and the screen name the same day the rows belong to.
    func tasks_calendar_dayTitle(_ date: Date, isToday: Bool, calendar: Calendar) -> String {
        let text = TasksCalendarDayFormatterCache.formatter(locale: self.dateLocale, calendar: calendar).string(from: date)
        return isToday ? "\(tasks_relative_today), \(text)" : text
    }

    /// The selected day kept short for the screen ("Today", "Wed, Oct 29", "Wed, Oct 29, 2027"); the
    /// full form stays the VoiceOver label. The year is shown only outside `now`'s year, both read in
    /// the given calendar (the same calendar and `now` as the rows).
    func tasks_calendar_shortDayTitle(_ date: Date, isToday: Bool, now: Date, calendar: Calendar) -> String {
        if isToday {
            return tasks_relative_today
        }
        let template = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "EEEMMMd" : "yEEEMMMd"
        return TasksCalendarShortDayFormatterCache.formatter(template: template, locale: self.dateLocale, calendar: calendar).string(from: date)
    }

    /// The summary disclosure's title: what is selected and how many tasks it holds.
    func tasks_calendar_summary(_ selection: String, count: Int) -> String {
        return "\(selection) · \(tasks_calendar_taskCount(count))"
    }

    /// Cloud before its first complete sync: no count is claimed (some tasks may not be here yet).
    var tasks_calendar_countsIncomplete: String {
        pick(en: "Not all tasks have synced yet", uz: "Hali barcha vazifalar sinxronlanmagan", ru: "Ещё не все задачи синхронизированы")
    }

    func tasks_calendar_summaryIncomplete(_ selection: String) -> String {
        return "\(selection) · \(tasks_calendar_countsIncomplete)"
    }

    // MARK: - Month disclosure

    var tasks_calendar_monthToggleHint: String {
        pick(en: "Shows or hides the month", uz: "Oyni koʻrsatadi yoki yashiradi", ru: "Показывает или скрывает месяц")
    }

    var tasks_calendar_monthShown: String {
        pick(en: "Month shown", uz: "Oy koʻrsatilgan", ru: "Месяц показан")
    }

    var tasks_calendar_monthHidden: String {
        pick(en: "Month hidden", uz: "Oy yashirilgan", ru: "Месяц скрыт")
    }

    var tasks_calendar_previousMonth: String {
        pick(en: "Previous month", uz: "Oldingi oy", ru: "Предыдущий месяц")
    }

    var tasks_calendar_nextMonth: String {
        pick(en: "Next month", uz: "Keyingi oy", ru: "Следующий месяц")
    }

    var tasks_calendar_chooseMonth: String {
        pick(en: "Choose month and year", uz: "Oy va yilni tanlash", ru: "Выбрать месяц и год")
    }

    // MARK: - Empty agenda

    var tasks_calendar_emptyDay_title: String {
        pick(en: "No tasks on this day", uz: "Bu kunga vazifalar yoʻq", ru: "На этот день задач нет")
    }

    var tasks_calendar_emptyDay_text: String {
        pick(
            en: "Tasks with a deadline on this day appear here. Pick another day or switch to List.",
            uz: "Muddati shu kunga belgilangan vazifalar shu yerda chiqadi. Boshqa kunni tanlang yoki Roʻyxatga oʻting.",
            ru: "Здесь появятся задачи со сроком на этот день. Выберите другой день или перейдите в Список."
        )
    }

    var tasks_calendar_emptyUndated_title: String {
        pick(en: "No tasks without a deadline", uz: "Muddatsiz vazifalar yoʻq", ru: "Задач без срока нет")
    }

    var tasks_calendar_emptyUndated_text: String {
        pick(
            en: "Tasks without a deadline appear here. Pick a day to see tasks due then.",
            uz: "Muddatsiz vazifalar shu yerda chiqadi. Muddatli vazifalarni koʻrish uchun kunni tanlang.",
            ru: "Здесь появятся задачи без срока. Выберите день, чтобы увидеть задачи со сроком."
        )
    }
}

/// Main-thread only (the board formats on the main thread). Keyed by language, calendar and time
/// zone, so a time zone change gets a fresh formatter.
private enum TasksCalendarDayFormatterCache {
    private static var cache: [String: DateFormatter] = [:]

    static func formatter(locale: Locale, calendar: Calendar) -> DateFormatter {
        let key = "\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        if let formatter = self.cache[key] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        self.cache[key] = formatter
        return formatter
    }
}

/// Main-thread only. Keyed by template (with / without year), language, calendar and time zone.
private enum TasksCalendarShortDayFormatterCache {
    private static var cache: [String: DateFormatter] = [:]

    static func formatter(template: String, locale: Locale, calendar: Calendar) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        if let formatter = self.cache[key] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        self.cache[key] = formatter
        return formatter
    }
}
