import Foundation

// Zenlygram — Tasks board (task-first Tasks screen) strings. Same pick(en:uz:ru:) scheme as
// SGTasksL10n.swift; kept in its own file so that one stays focused.

public extension SGTasksL10n {
    // MARK: - Filters and lists

    var tasks_filter_all: String {
        pick(en: "All", uz: "Hammasi", ru: "Все")
    }

    var tasks_filter_newList: String {
        pick(en: "New List", uz: "Yangi roʻyxat", ru: "Новый список")
    }

    /// Title of the list quick-added tasks go to while "All" is selected. Stored when the list is
    /// first created, so it keeps the language it was created in (the user can rename it).
    var tasks_inbox_title: String {
        pick(en: "Inbox", uz: "Kiruvchi", ru: "Входящие")
    }

    var tasks_lists_title: String {
        pick(en: "Lists", uz: "Roʻyxatlar", ru: "Списки")
    }

    /// VoiceOver value of a filter chip: how many open tasks it holds.
    func tasks_a11y_openCount(_ count: Int) -> String {
        switch count {
        case 0:
            return pick(en: "No open tasks", uz: "Ochiq vazifalar yoʻq", ru: "Нет открытых задач")
        default:
            let ruWord = countRuWord(count, one: "открытая задача", few: "открытые задачи", many: "открытых задач")
            return pick(
                en: count == 1 ? "1 open task" : "\(count) open tasks",
                uz: "\(count) ta ochiq vazifa",
                ru: "\(count) \(ruWord)"
            )
        }
    }

    // MARK: - Quick add

    var tasks_quickAdd_placeholder: String {
        pick(en: "Add a task", uz: "Vazifa qoʻshing", ru: "Добавить задачу")
    }

    func tasks_quickAdd_placeholderInList(_ listTitle: String) -> String {
        pick(
            en: "Add to “\(listTitle)”",
            uz: "“\(listTitle)” roʻyxatiga qoʻshing",
            ru: "Добавить в «\(listTitle)»"
        )
    }

    var tasks_quickAdd_submit: String {
        pick(en: "Add Task", uz: "Vazifani qoʻshish", ru: "Добавить задачу")
    }

    // MARK: - Completed section

    func tasks_completed_header(_ count: Int) -> String {
        pick(en: "Completed (\(count))", uz: "Bajarilgan (\(count))", ru: "Выполненные (\(count))")
    }

    var tasks_a11y_expanded: String {
        pick(en: "Expanded", uz: "Ochiq", ru: "Развёрнуто")
    }

    var tasks_a11y_collapsed: String {
        pick(en: "Collapsed", uz: "Yopiq", ru: "Свёрнуто")
    }

    var tasks_a11y_completedHint_show: String {
        pick(en: "Shows completed tasks", uz: "Bajarilgan vazifalarni koʻrsatadi", ru: "Показывает выполненные задачи")
    }

    var tasks_a11y_completedHint_hide: String {
        pick(en: "Hides completed tasks", uz: "Bajarilgan vazifalarni yashiradi", ru: "Скрывает выполненные задачи")
    }

    // MARK: - Empty states

    var tasks_empty_noTasks_title: String {
        pick(en: "No tasks yet", uz: "Hozircha vazifalar yoʻq", ru: "Задач пока нет")
    }

    var tasks_empty_noTasks_text: String {
        pick(
            en: "Type a task in the field below to add it.",
            uz: "Qoʻshish uchun vazifani pastdagi maydonga yozing.",
            ru: "Чтобы добавить задачу, введите её в поле ниже."
        )
    }

    var tasks_empty_listEmpty_text: String {
        pick(
            en: "This list has no tasks. Add one in the field below.",
            uz: "Bu roʻyxatda vazifalar yoʻq. Pastdagi maydonda qoʻshing.",
            ru: "В этом списке нет задач. Добавьте задачу в поле ниже."
        )
    }

    var tasks_empty_allDone_title: String {
        pick(en: "All done", uz: "Hammasi bajarildi", ru: "Всё сделано")
    }

    var tasks_empty_allDone_text: String {
        pick(
            en: "Nothing left to do here.",
            uz: "Bu yerda bajariladigan ish qolmadi.",
            ru: "Здесь больше нечего делать."
        )
    }

    // MARK: - Task row

    var tasks_a11y_markDone: String {
        pick(en: "Mark as done", uz: "Bajarildi deb belgilash", ru: "Отметить как выполненную")
    }

    var tasks_a11y_markNotDone: String {
        pick(en: "Mark as not done", uz: "Bajarilmadi deb belgilash", ru: "Отметить как невыполненную")
    }

    var tasks_a11y_stateDone: String {
        pick(en: "Completed", uz: "Bajarilgan", ru: "Выполнена")
    }

    var tasks_a11y_stateOpen: String {
        pick(en: "Not completed", uz: "Bajarilmagan", ru: "Не выполнена")
    }

    var tasks_a11y_editHint: String {
        pick(en: "Edits the task", uz: "Vazifani tahrirlaydi", ru: "Изменяет задачу")
    }

    /// A row of the read-only Eski vazifalar / Sinxronlangan nusxa views (wf15 §3.4).
    var tasks_a11y_openReadOnlyHint: String {
        pick(en: "Opens the task to read", uz: "Vazifani koʻrish uchun ochadi", ru: "Открывает задачу для просмотра")
    }

    var tasks_action_edit: String {
        pick(en: "Edit", uz: "Tahrirlash", ru: "Изменить")
    }

    var tasks_taskDeleted: String {
        pick(en: "Task deleted", uz: "Vazifa oʻchirildi", ru: "Задача удалена")
    }

    // MARK: - Errors (never the raw storage error)

    var tasks_error_generic: String {
        pick(
            en: "Couldn't save the change. Please try again.",
            uz: "Oʻzgarishni saqlab boʻlmadi. Qaytadan urinib koʻring.",
            ru: "Не удалось сохранить изменение. Попробуйте ещё раз."
        )
    }

    var tasks_error_restore: String {
        pick(
            en: "Couldn't restore the task. Its list may have been deleted.",
            uz: "Vazifani tiklab boʻlmadi. Uning roʻyxati oʻchirilgan boʻlishi mumkin.",
            ru: "Не удалось восстановить задачу. Возможно, её список был удалён."
        )
    }

    func tasks_error_titleTooLong(limit: Int) -> String {
        pick(
            en: "The name is too long. Use up to \(limit) characters.",
            uz: "Nom juda uzun. Koʻpi bilan \(limit) ta belgi kiriting.",
            ru: "Слишком длинное название. Используйте не более \(limit) символов."
        )
    }

    // MARK: - Assignee and deadline (local-only annotations)

    var tasks_assignee_title: String {
        pick(en: "Assignee", uz: "Masʼul", ru: "Исполнитель")
    }

    var tasks_deadline_title: String {
        pick(en: "Deadline", uz: "Muddat", ru: "Срок")
    }

    var tasks_metadata_none: String {
        pick(en: "None", uz: "Yoʻq", ru: "Нет")
    }

    var tasks_assignee_remove: String {
        pick(en: "Remove Assignee", uz: "Masʼulni olib tashlash", ru: "Убрать исполнителя")
    }

    var tasks_deadline_remove: String {
        pick(en: "Remove Deadline", uz: "Muddatni olib tashlash", ru: "Убрать срок")
    }

    var tasks_assignee_pickerTitle: String {
        pick(en: "Choose Assignee", uz: "Masʼulni tanlang", ru: "Выберите исполнителя")
    }

    var tasks_editTask_screenTitle: String {
        pick(en: "Edit Task", uz: "Vazifani tahrirlash", ru: "Изменить задачу")
    }

    var tasks_editTask_nameHeader: String {
        pick(en: "Task name", uz: "Vazifa nomi", ru: "Название задачи")
    }

    /// wf15: an old local assignee while sync is off — saved earlier, never sent to anyone; assigning
    /// now needs sync (the device board's Masʼul row opens the needs-sync sheet).
    var tasks_metadata_localFooter: String {
        pick(
            en: "This assignee was saved earlier and hasn't been sent to anyone. Assigning now needs sync.",
            uz: "Bu masʼul avval saqlangan va hech kimga yuborilmagan. Endi masʼul tayinlash uchun sinxronlash kerak.",
            ru: "Этот исполнитель сохранён ранее и никому не отправлен. Теперь для назначения нужна синхронизация."
        )
    }

    func tasks_a11y_assigneeValue(_ name: String) -> String {
        pick(en: "Assignee: \(name)", uz: "Masʼul: \(name)", ru: "Исполнитель: \(name)")
    }

    func tasks_a11y_deadlineValue(_ text: String) -> String {
        pick(en: "Deadline: \(text)", uz: "Muddat: \(text)", ru: "Срок: \(text)")
    }

    var tasks_a11y_pickAssigneeHint: String {
        pick(
            en: "Chooses a Telegram contact. The task is sent to them in Zenlygram Tasks, not as a Telegram message.",
            uz: "Telegram kontaktini tanlaydi. Vazifa unga Telegram xabari sifatida emas, Zenlygram Vazifalari orqali yuboriladi.",
            ru: "Выбирает контакт Telegram. Задача отправляется ему в «Задачи» Zenlygram, а не сообщением Telegram."
        )
    }

    var tasks_a11y_pickDeadlineHint: String {
        pick(en: "Chooses a date and time", uz: "Sana va vaqtni tanlaydi", ru: "Выбирает дату и время")
    }

    // MARK: - Deadline sheet shortcuts (Today / Tomorrow reuse tasks_relative_today / _tomorrow)

    var tasks_deadline_nextWeek: String {
        pick(en: "In a Week", uz: "Bir haftadan soʻng", ru: "Через неделю")
    }

    var tasks_a11y_deadlineShortcutHint: String {
        pick(
            en: "Changes the date and keeps the time. Applied when you save.",
            uz: "Sanani oʻzgartiradi, vaqt oʻzgarmaydi. Saqlaganingizda qoʻllanadi.",
            ru: "Меняет дату, время остаётся прежним. Применится после сохранения."
        )
    }

    // MARK: - Unsaved task edits

    var tasks_discardChanges_title: String {
        pick(en: "Discard changes?", uz: "Saqlamasdan chiqilsinmi?", ru: "Выйти без сохранения?")
    }

    var tasks_discardChanges_text: String {
        pick(en: "Your changes haven't been saved.", uz: "Oʻzgarishlaringiz saqlanmagan.", ru: "Изменения не сохранены.")
    }

    var tasks_discardChanges_keepEditing: String {
        pick(en: "Keep Editing", uz: "Tahrirlashni davom ettirish", ru: "Продолжить редактирование")
    }

    var tasks_discardChanges_discard: String {
        pick(en: "Discard", uz: "Saqlamaslik", ru: "Не сохранять")
    }

    /// The date picker's locale: the app language with Telegram's 12/24-hour choice as the ICU
    /// hour-cycle keyword (`h23` / `h12`), so the wheel/inline time matches the saved text. The time
    /// zone is set separately (device time zone).
    func tasks_deadlinePickerLocale(use24HourClock: Bool) -> Locale {
        return Locale(identifier: self.dateLocale.identifier + (use24HourClock ? "@hours=h23" : "@hours=h12"))
    }

    /// The calendar of every deadline surface (picker, shortcuts, saved text): Gregorian in the app
    /// language and the device time zone, read fresh so a time zone change is picked up.
    var tasks_deadlineCalendar: Calendar {
        return tasksDeadlineCalendar(locale: self.dateLocale, timeZone: TimeZone.current)
    }

    /// A stored deadline in the app language and the device time zone, with the user's 12/24-hour
    /// choice, kept short: "Today, 14:30", "Tomorrow, 14:30", "Mar 14, 14:30" this year, and
    /// "Mar 14, 2027, 14:30" in any other year. The time is always exact. Formatters are cached: rows
    /// format on every table reload.
    func tasks_deadline_text(_ dueAt: Int32, use24HourClock: Bool, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(dueAt))
        let formatters = TasksDeadlineFormatterCache.formatters(locale: self.dateLocale, use24HourClock: use24HourClock)
        let calendar = formatters.calendar
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let isTomorrow = !isToday && calendar.date(byAdding: .day, value: 1, to: now).map { calendar.isDate(date, inSameDayAs: $0) } == true
        if isToday || isTomorrow {
            return self.tasks_relative_format(today: isToday, tomorrow: isTomorrow, yesterday: false, time: formatters.time.string(from: date))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return formatters.dateThisYear.string(from: date)
        }
        return formatters.dateWithYear.string(from: date)
    }
}

private func tasksDeadlineCalendar(locale: Locale, timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    calendar.timeZone = timeZone
    return calendar
}

/// Main-thread only (board, editor and picker all format on the main thread).
private enum TasksDeadlineFormatterCache {
    struct Formatters {
        /// Gregorian in the formatters' time zone: decides Today / Tomorrow / same year.
        let calendar: Calendar
        let time: DateFormatter
        let dateThisYear: DateFormatter
        let dateWithYear: DateFormatter
    }

    private static var cache: [String: Formatters] = [:]

    static func formatters(locale: Locale, use24HourClock: Bool) -> Formatters {
        let timeZone = TimeZone.current
        let key = "\(locale.identifier)|\(use24HourClock)|\(timeZone.identifier)"
        if let formatters = self.cache[key] {
            return formatters
        }
        let calendar = tasksDeadlineCalendar(locale: locale, timeZone: timeZone)
        func make(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        let formatters = Formatters(
            calendar: calendar,
            time: make(use24HourClock ? "HHmm" : "hmma"),
            dateThisYear: make(use24HourClock ? "MMMdHHmm" : "MMMdhmma"),
            dateWithYear: make(use24HourClock ? "yMMMdHHmm" : "yMMMdhmma")
        )
        self.cache[key] = formatters
        return formatters
    }
}
