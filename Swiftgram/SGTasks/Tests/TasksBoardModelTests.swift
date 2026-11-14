import Foundation

// Host tests for TasksBoardModel.swift (the Tasks board's pure UI state), run against the real
// TodoTask / TodoFolder types. No database is opened: every value is built in memory.
@main
struct TasksBoardModelTests {
    private static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        precondition(condition, "line \(line): \(message)")
    }

    private static func folder(_ id: String, _ title: String, order: Int) -> TodoFolder {
        return TodoFolder(id: id, title: title, sortOrder: order, createdDate: 1_000)
    }

    private static func task(_ id: String, in folderId: String, order: Int, completedAt: Int32? = nil, dueAt: Int32? = 5_000) -> TodoTask {
        return TodoTask(
            id: id, folderId: folderId, title: "Task \(id)",
            description: "details \(id)", dueAt: dueAt, priority: 3,
            isCompleted: completedAt != nil, completedAt: completedAt,
            sortOrder: order, createdDate: 1_000, updatedAt: 1_000
        )
    }

    private static func gregorian(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private static func localDate(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private static func stamp(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Int32 {
        return Int32(localDate(calendar, year, month, day, hour, minute, second).timeIntervalSince1970)
    }

    private static func instant(_ timestamp: Int32) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    /// Order-independent view of due dates; nil (no deadline) is kept distinct from timestamp 0.
    private static func dueKeys(_ values: [Int32?]) -> [String] {
        return values.map { $0.map { String($0) } ?? "nil" }.sorted()
    }

    private static func completing(_ task: TodoTask, at time: Int32) -> TodoTask {
        return TodoTask(
            id: task.id, folderId: task.folderId, title: task.title,
            description: task.description, dueAt: task.dueAt, priority: task.priority,
            isCompleted: true, completedAt: time,
            sortOrder: task.sortOrder, createdDate: task.createdDate, updatedAt: time
        )
    }

    private static func taskIds(_ rows: [TasksBoardRow]) -> [String] {
        return rows.compactMap { row in
            if case let .task(id) = row { return id }
            return nil
        }
    }

    static func main() {
        validatesTitles()
        permitsRepairingOversizedDraft()
        recoversDeletedSelection()
        quickAddTargetsSelectedListOrInbox()
        filtersAndOrdersOpenTasks()
        completionMovesTheSameIdIntoCollapsedSection()
        ordersCompletedNewestFirst()
        choosesEmptyStates()
        countsOpenTasksPerChip()
        preventsContactNamesFromEscapingBidiIsolation()
        convertsDeadlineWithoutRoundingUp()
        rejectsUnrepresentableDeadlines()
        preservesStoredDeadlineWhenOpeningPicker()
        boundsSuggestedDeadlineAcrossClockAndCalendarLimits()
        shortcutsUseLocalCalendarDaysAndKeepTheSelectedClock()
        shortcutsResolveMissingLocalHoursWithoutLosingMinutes()
        shortcutsHandleRepeatedHoursWithoutChangingExistingInstants()
        shortcutsRejectUnrepresentableDates()
        calendarMatchesKeepNoDeadlineDistinctFromEpochZero()
        calendarDayIsTheHalfOpenLocalDayAcrossDST()
        calendarDayFollowsTheInjectedTimeZoneAcrossMonthAndYearBoundaries()
        calendarAllReproducesTheExistingBoard()
        calendarFiltersPartitionTheBoardInBoardOrder()
        calendarRecountsCompletedForTheFilterEvenWhenCollapsed()
        calendarDueDatesFollowTheSelectedListAndIncludeCompleted()
        calendarDayKeepsItsCivilDateAcrossTimeZones()
        calendarDueDateCountsMatchTheDayRows()
        // wf15 (§3.4): the read-only mode of the "Eski vazifalar" screen, and the archive model the
        // one-board resolver reads (design 30 §5.6 cut-over facts, no banner any more).
        writableBoardHasTheTwoTaskSections()
        readOnlyModeKeepsTheRowsWithoutABanner()
        readOnlyModeKeepsReadingFilteringAndTheCalendar()
        archiveReasonsOfferCopyOnlyForNewRows()
        print("PASS: Tasks board model (filters, recovery, quick-add, completion, ordering, title limits, deadline bounds, calendar shortcuts and preservation, calendar day/undated projection, calendar day selection and markers; wf15: read-only mode without a banner, filters and calendar kept, archive copy offer)")
    }

    // MARK: - Read-only mode (Eski vazifalar) and the archive model

    private static func writableBoardHasTheTwoTaskSections() {
        let work = folder("work", "Work", order: 0)
        let state = TasksBoardState(folders: [work], tasks: [task("w", in: "work", order: 0)])
        check(!state.isReadOnly, "the main board is writable")
        check(state.sections == [[.task(id: "w")], []], "and has exactly the two task sections")
    }

    private static func readOnlyModeKeepsTheRowsWithoutABanner() {
        let work = folder("work", "Work", order: 0)
        let tasks = [task("w1", in: "work", order: 0), task("w2", in: "work", order: 1, completedAt: 10)]
        var state = TasksBoardState(folders: [work], tasks: tasks, isReadOnly: true)
        check(state.isReadOnly, "the Eski vazifalar screen is read-only")
        check(state.sections == [[.task(id: "w1")], [.completedHeader(count: 1, isExpanded: false)]], "no banner row: the same two sections as the writable board (the footer says why)")
        state.isCompletedExpanded = true
        check(state.sections[1] == [.completedHeader(count: 1, isExpanded: true), .task(id: "w2")], "completed tasks stay readable")
        var writable = TasksBoardState(folders: [work], tasks: tasks)
        writable.setReadOnly(true)
        check(writable.isReadOnly && writable.sections.count == 2, "read-only can be set after the fact")
        writable.setReadOnly(false)
        check(!writable.isReadOnly && writable.sections == [[.task(id: "w1")], [.completedHeader(count: 1, isExpanded: false)]], "and cleared again")
        let empty = TasksBoardState(folders: [], tasks: [], isReadOnly: true)
        check(empty.sections == [[.emptyMessage(.noTasks)], []], "an empty read-only board shows the empty message")
    }

    private static func readOnlyModeKeepsReadingFilteringAndTheCalendar() {
        let utc = gregorian("UTC")
        let work = folder("work", "Work", order: 0)
        let home = folder("home", "Home", order: 1)
        let day = stamp(utc, 2026, 11, 2)
        let tasks = [task("w1", in: "work", order: 0, dueAt: day), task("h1", in: "home", order: 0, dueAt: nil)]
        var state = TasksBoardState(folders: [work, home], tasks: tasks, isReadOnly: true)
        state.select(.folder(id: "home"))
        check(state.filter == .folder(id: "home") && state.sections == [[.task(id: "h1")], []], "list filters keep working read-only")
        check(state.chips.map { $0.activeCount } == [2, 1, 1], "chips keep counting")
        state.select(.all)
        check(state.calendarSections(filter: .all, calendar: utc) == state.sections, "the All calendar filter is exactly the read-only board")
        check(state.calendarSections(filter: .day(instant(day)), calendar: utc) == [[.task(id: "w1")], []], "a day filters the tasks")
        check(state.calendarSections(filter: .noDeadline, calendar: utc) == [[.task(id: "h1")], []], "No Deadline too")
        check(dueKeys(state.calendarDueDates) == dueKeys([day, nil]), "the calendar markers come from the read-only board's tasks")
    }

    private static func archiveReasonsOfferCopyOnlyForNewRows() {
        check(TasksBoardArchive(reason: .newRows(3)).offersCopy, "new rows: the explicit copy")
        check(!TasksBoardArchive(reason: .migrating(done: 0, total: 0)).offersCopy, "migrating: the copy is already on its way")
        check(!TasksBoardArchive(reason: .otherAccount).offersCopy, "another account's copy is not this account's to extend")
        check(!TasksBoardArchive(reason: .retired).offersCopy, "retired: nothing left to copy")
        check(TasksBoardArchive(reason: .retired, keptLocal: -3).keptLocal == 0, "kept-local rows are never negative")
        check(TasksBoardArchive(reason: .newRows(1), awaitsCloudCopy: true).awaitsCloudCopy == false, "only a migrating copy can be awaited")
        check(TasksBoardArchive(reason: .migrating(done: 2, total: 2), awaitsCloudCopy: true).awaitsCloudCopy, "a migrating copy can be awaited")
    }

    private static func validatesTitles() {
        check(tasksValidateTitle("   \n\t ", limit: 200) == .empty, "blank title must be rejected")
        check(tasksValidateTitle("", limit: 200) == .empty, "empty title must be rejected")
        check(tasksValidateTitle("  Buy milk \n", limit: 200) == .valid("Buy milk"), "title must be trimmed")
        let exact = String(repeating: "a", count: TasksTitleLimit.task)
        check(tasksValidateTitle(exact, limit: TasksTitleLimit.task) == .valid(exact), "200 characters are allowed")
        check(tasksValidateTitle(exact + "b", limit: TasksTitleLimit.task) == .tooLong, "201 characters are rejected")
        // Surrounding whitespace does not count against the limit.
        check(tasksValidateTitle("   " + exact + "   ", limit: TasksTitleLimit.task) == .valid(exact), "padding is trimmed before the limit check")
        // Limits are user-perceived characters: one skin-toned emoji is one character.
        let emoji = String(repeating: "👍🏽", count: TasksTitleLimit.folder)
        check(tasksValidateTitle(emoji, limit: TasksTitleLimit.folder) == .valid(emoji), "emoji count as single characters")
        check(tasksValidateTitle(emoji + "👍🏽", limit: TasksTitleLimit.folder) == .tooLong, "folder limit is 100 characters")
        // Invisible-only titles are refused before the gate, as storage would refuse them.
        check(tasksValidateTitle("\u{200B}\u{200B}", limit: 200) == .empty, "zero-width spaces only are not a title")
        check(tasksValidateTitle(" \u{0301}\u{0308} ", limit: 200) == .empty, "combining marks only are not a title")
        check(tasksValidateTitle("o\u{0308}", limit: 200) == .valid("o\u{0308}"), "a visible letter with a mark is a title")
        // 100 characters within the 200-character limit, but each carries 50 combining marks
        // (101 UTF-8 bytes): 10,100 bytes exceed the 8,192-byte storage limit.
        let heavy = String(repeating: "a" + String(repeating: "\u{0301}", count: 50), count: 100)
        check(heavy.count == 100 && heavy.utf8.count > TodoStorage.maximumTitleUTF8Bytes, "fixture is over the byte limit only")
        check(tasksValidateTitle(heavy, limit: TasksTitleLimit.task) == .tooLong, "the UTF-8 byte limit applies before the gate")
    }

    private static func permitsRepairingOversizedDraft() {
        let oversized = String(repeating: "👍🏽", count: 250)
        check(tasksAcceptsDraftEdit(current: oversized, updated: String(oversized.dropLast())), "dictation overflow must remain deletable")
        check(!tasksAcceptsDraftEdit(current: oversized, updated: oversized + "a"), "overflow cannot grow")
        let full = String(repeating: "a", count: 200)
        check(!tasksAcceptsDraftEdit(current: full, updated: full + "b"), "typing past the limit is refused")
        check(tasksAcceptsDraftEdit(current: "", updated: full), "pasting exactly the limit works")
        check(tasksAcceptsDraftEdit(current: oversized, updated: ""), "overflow can be cleared")
    }

    private static func recoversDeletedSelection() {
        let work = folder("work", "Work", order: 0)
        let home = folder("home", "Home", order: 1)
        var state = TasksBoardState(folders: [work, home], tasks: [], filter: .folder(id: "home"))
        check(state.filter == .folder(id: "home"), "an existing list stays selected")

        // Renamed list: the selection is by id, so it survives.
        let renamedHome = TodoFolder(id: "home", title: "House", sortOrder: 1, createdDate: 1_000)
        state.update(folders: [work, renamedHome], tasks: [])
        check(state.filter == .folder(id: "home"), "a renamed list stays selected")
        check(state.selectedFolder?.title == "House", "the selected list reflects the new title")

        // Deleted elsewhere (Lists screen / logout cleanup): fall back to All.
        state.update(folders: [work], tasks: [])
        check(state.filter == .all, "a deleted selected list falls back to All")
        check(state.selectedFolder == nil, "no list is selected after the fallback")

        state.select(.folder(id: "missing"))
        check(state.filter == .all, "selecting an unknown list selects All")

        let stale = TasksBoardState(folders: [work], tasks: [], filter: .folder(id: "gone"))
        check(stale.filter == .all, "a stale initial selection is resolved on init")
    }

    private static func quickAddTargetsSelectedListOrInbox() {
        let work = folder("work", "Work", order: 0)
        var state = TasksBoardState(folders: [work], tasks: [])
        check(state.quickAddFolderId == nil, "under All the quick-added task goes to the inbox (nil)")
        state.select(.folder(id: "work"))
        check(state.quickAddFolderId == "work", "a selected list receives the quick-added task")
        state.update(folders: [], tasks: [])
        check(state.quickAddFolderId == nil, "after the list is deleted, quick add targets the inbox again")
    }

    private static func filtersAndOrdersOpenTasks() {
        // Folders in display order: B first. Tasks arrive in storage order (sort_order across lists).
        let folderA = folder("a", "A", order: 1)
        let folderB = folder("b", "B", order: 0)
        let tasks = [
            task("a1", in: "a", order: 0),
            task("b1", in: "b", order: 0),
            task("a2", in: "a", order: 1),
            task("b2", in: "b", order: 1)
        ]
        var state = TasksBoardState(folders: [folderB, folderA], tasks: tasks)
        check(state.activeTasks.map { $0.id } == ["b1", "b2", "a1", "a2"], "All groups open tasks by list order, then stored order")
        check(taskIds(state.sections[0]) == ["b1", "b2", "a1", "a2"], "section 0 lists the open tasks")

        state.select(.folder(id: "a"))
        check(state.activeTasks.map { $0.id } == ["a1", "a2"], "a list filter shows only its own tasks")
        check(state.sections[1].isEmpty, "no completed section without completed tasks")
    }

    private static func completionMovesTheSameIdIntoCollapsedSection() {
        let work = folder("work", "Work", order: 0)
        let first = task("t1", in: "work", order: 0)
        let second = task("t2", in: "work", order: 1)
        var state = TasksBoardState(folders: [work], tasks: [first, second])
        check(taskIds(state.sections[0]) == ["t1", "t2"], "both tasks start open")

        state.update(folders: [work], tasks: [second, completing(first, at: 9_000)])
        check(taskIds(state.sections[0]) == ["t2"], "the completed id leaves the open section")
        check(state.sections[1] == [.completedHeader(count: 1, isExpanded: false)], "completed starts collapsed and shows its count")
        check(!state.sections[1].contains(.task(id: "t1")), "a collapsed section hides its rows")

        state.isCompletedExpanded = true
        check(state.sections[1] == [.completedHeader(count: 1, isExpanded: true), .task(id: "t1")], "expanding reveals exactly the completed id")
        check(state.task(id: "t1")?.description == "details t1", "the row resolves to the full stored task")

        // Un-completing moves it back, and the filter stays on the same list.
        state.select(.folder(id: "work"))
        state.update(folders: [work], tasks: [first, second])
        check(taskIds(state.sections[0]) == ["t1", "t2"], "un-completing moves the id back to the open section")
        check(state.sections[1].isEmpty, "the completed section disappears when nothing is done")
        check(state.filter == .folder(id: "work"), "completion does not change the selected list")
    }

    private static func ordersCompletedNewestFirst() {
        let work = folder("work", "Work", order: 0)
        let tasks = [
            task("old", in: "work", order: 0, completedAt: 100),
            task("new", in: "work", order: 1, completedAt: 300),
            task("mid", in: "work", order: 2, completedAt: 200)
        ]
        let state = TasksBoardState(folders: [work], tasks: tasks, isCompletedExpanded: true)
        check(state.completedTasks.map { $0.id } == ["new", "mid", "old"], "completed tasks are newest first")
    }

    private static func choosesEmptyStates() {
        let work = folder("work", "Work", order: 0)
        let home = folder("home", "Home", order: 1)
        let empty = TasksBoardState(folders: [], tasks: [])
        check(empty.sections == [[.emptyMessage(.noTasks)], []], "no data shows the no-tasks message only")

        let allDone = TasksBoardState(folders: [work], tasks: [task("d", in: "work", order: 0, completedAt: 10)])
        check(allDone.sections == [[.emptyMessage(.allDone)], [.completedHeader(count: 1, isExpanded: false)]], "all completed shows All done above the disclosure")

        var listEmpty = TasksBoardState(folders: [work, home], tasks: [task("w", in: "work", order: 0)])
        listEmpty.select(.folder(id: "home"))
        check(listEmpty.sections == [[.emptyMessage(.noTasks)], []], "an empty list shows the no-tasks message")
    }

    private static func countsOpenTasksPerChip() {
        let work = folder("work", "Work", order: 0)
        let home = folder("home", "Home", order: 1)
        let tasks = [
            task("w1", in: "work", order: 0),
            task("w2", in: "work", order: 1, completedAt: 10),
            task("h1", in: "home", order: 0)
        ]
        var state = TasksBoardState(folders: [work, home], tasks: tasks)
        let chips = state.chips
        check(chips.map { $0.filter } == [.all, .folder(id: "work"), .folder(id: "home")], "All first, then lists in order")
        check(chips.map { $0.activeCount } == [2, 1, 1], "chips count open tasks only")
        check(chips.map { $0.folderTitle } == [nil, "Work", "Home"], "All has no stored title")
        check(chips.filter { $0.isSelected }.map { $0.filter } == [.all], "exactly All is selected by default")

        state.select(.folder(id: "home"))
        check(state.chips.filter { $0.isSelected }.map { $0.filter } == [.folder(id: "home")], "exactly the chosen list is selected")
    }

    private static func preventsContactNamesFromEscapingBidiIsolation() {
        let controls = "\u{061c}\u{200e}\u{200f}\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}\u{2066}\u{2067}\u{2068}\u{2069}"
        let name = "علي 👩‍💻\nAlice" + controls + " Smith"
        check(tasksIsolatedDisplayText(name) == "\u{2068}علي 👩‍💻 Alice Smith\u{2069}",
              "contact-supplied bidi controls must not escape isolation or reorder the neighbouring deadline; natural RTL and joined emoji must remain")
    }

    private static func convertsDeadlineWithoutRoundingUp() {
        let cases: [(TimeInterval, Int32)] = [
            (0.0, 0),
            (1_800_000_017.875, 1_800_000_017),
            (Double(Int32.max), Int32.max)
        ]
        for (seconds, expected) in cases {
            check(tasksDeadlineTimestamp(for: Date(timeIntervalSince1970: seconds)) == expected,
                  "deadline conversion must preserve seconds without rounding into the future")
        }
    }

    private static func rejectsUnrepresentableDeadlines() {
        let invalid: [TimeInterval] = [-0.25, Double(Int32.max) + 0.25, .nan, .infinity, -.infinity]
        for seconds in invalid {
            check(tasksDeadlineTimestamp(for: Date(timeIntervalSince1970: seconds)) == nil,
                  "unsupported dates must be refused rather than overflowing or wrapping")
        }
    }

    private static func preservesStoredDeadlineWhenOpeningPicker() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 5 * 3600)!
        let stored: Int32 = 1_800_000_017
        let initial = tasksDeadlineInitialDate(current: stored, now: Date(timeIntervalSince1970: 1_900_000_000), calendar: calendar)
        check(initial.timeIntervalSince1970 == Double(stored),
              "opening an overdue deadline must not replace it with now or truncate its seconds")
        check(tasksDeadlineTimestamp(for: initial) == stored,
              "opening and accepting an unchanged deadline must preserve its exact timestamp")
    }

    private static func boundsSuggestedDeadlineAcrossClockAndCalendarLimits() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let springForward = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30))!
        let suggested = tasksDeadlineInitialDate(current: nil, now: springForward, calendar: calendar)
        check(suggested > springForward && tasksDeadlineTimestamp(for: suggested) != nil,
              "the spring-forward gap must not produce a past or unrepresentable suggestion")
        for seconds in [Double(Int32.max) - 10.0, Double(Int32.max) + 3600.0, -3600.0] {
            let date = tasksDeadlineInitialDate(current: nil, now: Date(timeIntervalSince1970: seconds), calendar: calendar)
            check(tasksDeadlineTimestamp(for: date) != nil,
                  "suggestions at clock bounds must remain within the database timestamp range")
        }
    }

    private static func shortcutsUseLocalCalendarDaysAndKeepTheSelectedClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30))!
        let selected = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 9, minute: 45, second: 17))!
        let cases: [(TasksDeadlineShortcut, Int)] = [(.today, 7), (.tomorrow, 8), (.nextWeek, 14)]
        for (shortcut, day) in cases {
            let expected = calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 9, minute: 45, second: 17))!
            check(tasksDeadlineShortcutDate(shortcut, selectedDate: selected, now: now, calendar: calendar) == expected,
                  "shortcuts must choose the local calendar day across DST, not add 24-hour durations or replace the selected clock")
        }
    }

    private static func shortcutsResolveMissingLocalHoursWithoutLosingMinutes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let selected = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 2, minute: 30, second: 17))!
        let expected = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 30, second: 17))!
        check(tasksDeadlineShortcutDate(.tomorrow, selectedDate: selected, now: now, calendar: calendar) == expected,
              "a nonexistent spring-forward time must move forward while preserving the selected minutes and seconds")
    }

    private static func shortcutsHandleRepeatedHoursWithoutChangingExistingInstants() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var local = utc
        local.timeZone = TimeZone(identifier: "America/New_York")!
        let secondOccurrence = utc.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 6, minute: 30, second: 17))!
        let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 15))!
        check(tasksDeadlineShortcutDate(.today, selectedDate: secondOccurrence, now: now, calendar: local) == secondOccurrence,
              "choosing the same local day must not silently move an existing deadline into the first repeated hour")
        let previousDay = utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 5, minute: 30, second: 17))!
        let firstOccurrence = utc.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 5, minute: 30, second: 17))!
        check(tasksDeadlineShortcutDate(.tomorrow, selectedDate: previousDay, now: previousDay, calendar: local) == firstOccurrence,
              "choosing a different day with a repeated hour must consistently choose its first occurrence")
    }

    private static func shortcutsRejectUnrepresentableDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nearLimit = Date(timeIntervalSince1970: Double(Int32.max) - 10.0)
        for shortcut in [TasksDeadlineShortcut.tomorrow, .nextWeek] {
            check(tasksDeadlineShortcutDate(shortcut, selectedDate: nearLimit, now: nearLimit, calendar: calendar) == nil,
                  "a shortcut beyond storage bounds must be unavailable, not clamped to an unrelated deadline")
        }
        let valid = Date(timeIntervalSince1970: 1_800_000_000)
        for seconds in [-1.0, Double(Int32.max) + 1.0, .nan, .infinity] {
            let invalid = Date(timeIntervalSince1970: seconds)
            check(tasksDeadlineShortcutDate(.today, selectedDate: invalid, now: valid, calendar: calendar) == nil,
                  "invalid selected dates must not enter calendar calculations")
            check(tasksDeadlineShortcutDate(.today, selectedDate: valid, now: invalid, calendar: calendar) == nil,
                  "invalid clock dates must not enter calendar calculations")
        }
    }

    private static func calendarMatchesKeepNoDeadlineDistinctFromEpochZero() {
        let utc = gregorian("UTC")
        let newYork = gregorian("America/New_York")
        let epochDay = TasksCalendarFilter.day(instant(0))
        check(tasksCalendarMatches(dueAt: nil, filter: .noDeadline, calendar: utc), "a task without a deadline is undated")
        check(!tasksCalendarMatches(dueAt: 0, filter: .noDeadline, calendar: utc), "timestamp 0 is a real deadline, never 'no deadline'")
        check(tasksCalendarMatches(dueAt: 0, filter: epochDay, calendar: utc), "timestamp 0 lands on 1 January 1970 in UTC")
        check(!tasksCalendarMatches(dueAt: nil, filter: epochDay, calendar: utc), "an undated task belongs to no day")
        check(tasksCalendarMatches(dueAt: nil, filter: .all, calendar: utc) && tasksCalendarMatches(dueAt: 0, filter: .all, calendar: utc), "All matches every task")
        check(tasksCalendarMatches(dueAt: 0, filter: .day(localDate(newYork, 1969, 12, 31)), calendar: newYork), "the same instant is 31 December 1969 in New York")
        check(!tasksCalendarMatches(dueAt: 0, filter: .day(localDate(newYork, 1970, 1, 1)), calendar: newYork), "the day is read in the injected calendar's time zone")
        check(tasksCalendarMatches(dueAt: Int32.max, filter: .day(localDate(utc, 2038, 1, 19)), calendar: utc), "the largest stored deadline still has a day")
    }

    private static func calendarDayIsTheHalfOpenLocalDayAcrossDST() {
        let newYork = gregorian("America/New_York")
        let cases: [(month: Int, day: Int, hours: Int32)] = [(3, 8, 23), (11, 1, 25)]
        for (month, day, hours) in cases {
            let start = stamp(newYork, 2026, month, day, 0, 0, 0)
            let next = stamp(newYork, 2026, month, day + 1, 0, 0, 0)
            check(next - start == hours * 3600, "fixture: 2026-\(month)-\(day) has \(hours) hours in New York")
            for selector in [start, start + 3600, next - 1] {
                let filter = TasksCalendarFilter.day(instant(selector))
                check(tasksCalendarMatches(dueAt: start, filter: filter, calendar: newYork), "local midnight opens the day")
                check(tasksCalendarMatches(dueAt: next - 1, filter: filter, calendar: newYork), "the last second before the next local midnight is still the day")
                check(tasksCalendarMatches(dueAt: next - 1800, filter: filter, calendar: newYork), "23:30 local is the same day")
                check(!tasksCalendarMatches(dueAt: next, filter: filter, calendar: newYork), "the next local midnight belongs to the next day")
                check(!tasksCalendarMatches(dueAt: start - 1, filter: filter, calendar: newYork), "the second before local midnight belongs to the previous day")
            }
        }
        // A fixed 86,400-second day would wrongly take 00:15 of the day after the 23-hour day, and
        // wrongly drop 23:30 of the 25-hour day.
        let short = TasksCalendarFilter.day(localDate(newYork, 2026, 3, 8))
        check(!tasksCalendarMatches(dueAt: stamp(newYork, 2026, 3, 9, 0, 15), filter: short, calendar: newYork), "the 23-hour day ends at the next local midnight")
        let long = TasksCalendarFilter.day(localDate(newYork, 2026, 11, 1))
        check(tasksCalendarMatches(dueAt: stamp(newYork, 2026, 11, 1, 23, 30), filter: long, calendar: newYork), "the 25-hour day keeps its last hour")
    }

    private static func calendarDayFollowsTheInjectedTimeZoneAcrossMonthAndYearBoundaries() {
        let utc = gregorian("UTC")
        let tashkent = gregorian("Asia/Tashkent")
        let newYork = gregorian("America/New_York")

        let lateJune = stamp(utc, 2026, 6, 30, 23, 30)
        check(tasksCalendarMatches(dueAt: lateJune, filter: .day(localDate(utc, 2026, 6, 30)), calendar: utc), "23:30 UTC on 30 June is 30 June in UTC")
        check(!tasksCalendarMatches(dueAt: lateJune, filter: .day(localDate(utc, 2026, 7, 1)), calendar: utc), "and not 1 July in UTC")
        check(tasksCalendarMatches(dueAt: lateJune, filter: .day(localDate(tashkent, 2026, 7, 1)), calendar: tashkent), "the same instant is 1 July in Tashkent")
        check(!tasksCalendarMatches(dueAt: lateJune, filter: .day(localDate(tashkent, 2026, 6, 30)), calendar: tashkent), "and not 30 June in Tashkent")

        // One selector instant (21:00 UTC 30 June = 02:00 1 July in Tashkent) names a different day per calendar.
        let selector = TasksCalendarFilter.day(localDate(utc, 2026, 6, 30, 21))
        let juneNoon = stamp(utc, 2026, 6, 30, 12)
        check(tasksCalendarMatches(dueAt: juneNoon, filter: selector, calendar: utc), "the selector is 30 June in UTC")
        check(!tasksCalendarMatches(dueAt: juneNoon, filter: selector, calendar: tashkent), "the selector is 1 July in Tashkent")

        let lastOfYear = stamp(newYork, 2026, 12, 31, 23, 59, 59)
        let firstOfYear = stamp(newYork, 2027, 1, 1, 0, 0, 0)
        let newYearsEve = TasksCalendarFilter.day(localDate(newYork, 2026, 12, 31))
        let newYearsDay = TasksCalendarFilter.day(localDate(newYork, 2027, 1, 1))
        check(tasksCalendarMatches(dueAt: lastOfYear, filter: newYearsEve, calendar: newYork) && !tasksCalendarMatches(dueAt: firstOfYear, filter: newYearsEve, calendar: newYork), "31 December ends at local midnight")
        check(tasksCalendarMatches(dueAt: firstOfYear, filter: newYearsDay, calendar: newYork) && !tasksCalendarMatches(dueAt: lastOfYear, filter: newYearsDay, calendar: newYork), "1 January starts at local midnight")

        let leapDay = TasksCalendarFilter.day(localDate(newYork, 2028, 2, 29))
        check(tasksCalendarMatches(dueAt: stamp(newYork, 2028, 2, 29, 23, 59, 59), filter: leapDay, calendar: newYork), "29 February exists in a leap year")
        check(!tasksCalendarMatches(dueAt: stamp(newYork, 2028, 3, 1, 0, 0, 0), filter: leapDay, calendar: newYork), "1 March is the next month")
    }

    private static func calendarAllReproducesTheExistingBoard() {
        let newYork = gregorian("America/New_York")
        let utc = gregorian("UTC")
        let work = folder("work", "Work", order: 0)
        let home = folder("home", "Home", order: 1)
        let tasks = [
            task("w1", in: "work", order: 0, dueAt: nil),
            task("h1", in: "home", order: 0, dueAt: 0),
            task("w2", in: "work", order: 1, completedAt: 50, dueAt: stamp(newYork, 2026, 3, 8)),
            task("h2", in: "home", order: 1, completedAt: 70, dueAt: nil)
        ]
        var states = [
            TasksBoardState(folders: [], tasks: []),
            TasksBoardState(folders: [work, home], tasks: tasks),
            TasksBoardState(folders: [work, home], tasks: tasks, isCompletedExpanded: true),
            TasksBoardState(folders: [work], tasks: [task("d", in: "work", order: 0, completedAt: 10)])
        ]
        var selected = TasksBoardState(folders: [work, home], tasks: tasks, isCompletedExpanded: true)
        selected.select(.folder(id: "home"))
        states.append(selected)
        for state in states {
            check(state.calendarSections(filter: .all, calendar: newYork) == state.sections, "the All calendar filter is exactly the existing board")
            check(state.calendarSections(filter: .all, calendar: utc) == state.sections, "the All calendar filter ignores the calendar")
        }
    }

    private static func calendarFiltersPartitionTheBoardInBoardOrder() {
        let newYork = gregorian("America/New_York")
        let folderA = folder("a", "A", order: 1)
        let folderB = folder("b", "B", order: 0)
        // Storage order across lists; due times deliberately disagree with the board order.
        let tasks = [
            task("a1", in: "a", order: 0, dueAt: stamp(newYork, 2026, 3, 8, 9)),
            task("b1", in: "b", order: 0, dueAt: stamp(newYork, 2026, 3, 9, 0, 0, 0)),
            task("a2", in: "a", order: 1, dueAt: nil),
            task("b2", in: "b", order: 1, dueAt: stamp(newYork, 2026, 3, 8, 23, 30)),
            task("b3", in: "b", order: 2, dueAt: 0),
            task("a3", in: "a", order: 2, dueAt: stamp(newYork, 2026, 3, 8, 0, 0, 0))
        ]
        let state = TasksBoardState(folders: [folderB, folderA], tasks: tasks)
        check(taskIds(state.sections[0]) == ["b1", "b2", "b3", "a1", "a2", "a3"], "fixture: the default board order")

        let filters: [(TasksCalendarFilter, [String])] = [
            (.day(localDate(newYork, 2026, 3, 8)), ["b2", "a1", "a3"]),
            (.day(localDate(newYork, 2026, 3, 9)), ["b1"]),
            (.day(localDate(newYork, 1969, 12, 31)), ["b3"]),
            (.noDeadline, ["a2"])
        ]
        var seen: [String] = []
        for (filter, expected) in filters {
            let sections = state.calendarSections(filter: filter, calendar: newYork)
            check(taskIds(sections[0]) == expected, "\(filter) keeps the board's list-then-stored order")
            check(sections[1].isEmpty, "\(filter) has no completed section without completed tasks")
            seen.append(contentsOf: taskIds(sections[0]))
        }
        check(seen.sorted() == taskIds(state.sections[0]).sorted(), "the day buckets and the undated bucket partition the board exactly once")

        let quietDay = state.calendarSections(filter: .day(localDate(newYork, 2026, 3, 10)), calendar: newYork)
        check(quietDay == [[.emptyMessage(.noTasks)], []], "a day without tasks shows the no-tasks message")
        check(state.sections[0].count == 6, "projecting a day never changes the default board")
    }

    private static func calendarRecountsCompletedForTheFilterEvenWhenCollapsed() {
        let newYork = gregorian("America/New_York")
        let work = folder("work", "Work", order: 0)
        let day = stamp(newYork, 2026, 11, 1, 9)
        let otherDay = stamp(newYork, 2026, 11, 2, 9)
        let tasks = [
            task("o1", in: "work", order: 0, dueAt: day),
            task("c1", in: "work", order: 1, completedAt: 100, dueAt: day),
            task("c2", in: "work", order: 2, completedAt: 300, dueAt: stamp(newYork, 2026, 11, 1, 23, 30)),
            task("c3", in: "work", order: 3, completedAt: 200, dueAt: otherDay),
            task("c4", in: "work", order: 4, completedAt: 400, dueAt: nil)
        ]
        var state = TasksBoardState(folders: [work], tasks: tasks)
        let dayFilter = TasksCalendarFilter.day(localDate(newYork, 2026, 11, 1))
        check(state.sections[1] == [.completedHeader(count: 4, isExpanded: false)], "fixture: the default board counts every completed task")
        check(state.calendarSections(filter: dayFilter, calendar: newYork) == [[.task(id: "o1")], [.completedHeader(count: 2, isExpanded: false)]],
              "a collapsed completed header counts only the day's completed tasks")
        check(state.calendarSections(filter: .day(instant(otherDay)), calendar: newYork) == [[.emptyMessage(.allDone)], [.completedHeader(count: 1, isExpanded: false)]],
              "a day whose tasks are all done shows All done above its own count")
        check(state.calendarSections(filter: .noDeadline, calendar: newYork) == [[.emptyMessage(.allDone)], [.completedHeader(count: 1, isExpanded: false)]],
              "the undated bucket counts its own completed task")

        state.isCompletedExpanded = true
        check(state.calendarSections(filter: dayFilter, calendar: newYork) == [[.task(id: "o1")], [.completedHeader(count: 2, isExpanded: true), .task(id: "c2"), .task(id: "c1")]],
              "expanding reveals exactly the day's completed tasks, newest first")
    }

    private static func calendarDueDatesFollowTheSelectedListAndIncludeCompleted() {
        let newYork = gregorian("America/New_York")
        let work = folder("work", "Work", order: 0)
        let home = folder("home", "Home", order: 1)
        let workDay = stamp(newYork, 2026, 3, 8, 10)
        let workDone = stamp(newYork, 2026, 3, 9, 10)
        let homeDay = stamp(newYork, 2026, 3, 10, 10)
        let tasks = [
            task("w1", in: "work", order: 0, dueAt: workDay),
            task("w2", in: "work", order: 1, completedAt: 10, dueAt: workDone),
            task("w3", in: "work", order: 2, dueAt: nil),
            task("h1", in: "home", order: 0, dueAt: homeDay),
            task("h2", in: "home", order: 1, dueAt: 0)
        ]
        var state = TasksBoardState(folders: [work, home], tasks: tasks)
        check(dueKeys(state.calendarDueDates) == dueKeys([workDay, workDone, nil, homeDay, 0]), "All marks every task, completed and undated included, 0 distinct from nil")

        state.select(.folder(id: "work"))
        check(dueKeys(state.calendarDueDates) == dueKeys([workDay, workDone, nil]), "a selected list marks only its own tasks")
        check(state.calendarSections(filter: .day(instant(homeDay)), calendar: newYork) == [[.emptyMessage(.noTasks)], []], "another list's task never leaks into a day")
        check(state.calendarSections(filter: .day(instant(workDone)), calendar: newYork) == [[.emptyMessage(.allDone)], [.completedHeader(count: 1, isExpanded: false)]], "the list's completed task stays on its day")
        check(state.quickAddFolderId == "work", "projecting a day never changes where quick add files a task")
    }

    private static func calendarDayKeepsItsCivilDateAcrossTimeZones() {
        let utc = gregorian("UTC")
        let tashkent = gregorian("Asia/Tashkent")
        let lateJune = localDate(utc, 2026, 6, 30, 23, 30)
        let selected = TasksCalendarDay(date: lateJune, calendar: utc)
        check(selected == TasksCalendarDay(year: 2026, month: 6, day: 30), "the selected instant names 30 June in UTC")
        check(TasksCalendarDay(date: lateJune, calendar: tashkent) == TasksCalendarDay(year: 2026, month: 7, day: 1), "the same instant names 1 July in Tashkent")
        check(TasksCalendarDay(components: selected.components(calendar: tashkent)) == selected, "components round-trip the civil date in any zone")
        check(TasksCalendarDay(components: DateComponents(year: 2026, month: 6)) == nil, "a date without a day is not a calendar day")

        let work = folder("work", "Work", order: 0)
        let tasks = [
            task("t1", in: "work", order: 0, dueAt: stamp(tashkent, 2026, 6, 30, 10)),
            task("t2", in: "work", order: 1, dueAt: stamp(tashkent, 2026, 7, 1, 1)),
            task("t3", in: "work", order: 2, dueAt: stamp(utc, 2026, 6, 30, 23, 30))
        ]
        let state = TasksBoardState(folders: [work], tasks: tasks)
        check(taskIds(state.calendarSections(filter: .day(selected.date(calendar: utc)!), calendar: utc)[0]) == ["t1", "t2", "t3"],
              "30 June in UTC holds every task due on that UTC day")
        check(taskIds(state.calendarSections(filter: .day(selected.date(calendar: tashkent)!), calendar: tashkent)[0]) == ["t1"],
              "after a time zone change the same named day is re-resolved in the new zone")

        // Noon stays inside the named day when DST skips or repeats an hour (New York) or midnight (Santiago).
        let newYork = gregorian("America/New_York")
        let santiago = gregorian("America/Santiago")
        let dstDays: [(Calendar, TasksCalendarDay)] = [
            (newYork, TasksCalendarDay(year: 2026, month: 3, day: 8)),
            (newYork, TasksCalendarDay(year: 2026, month: 11, day: 1)),
            (santiago, TasksCalendarDay(year: 2026, month: 4, day: 5)),
            (santiago, TasksCalendarDay(year: 2026, month: 9, day: 6))
        ]
        for (calendar, day) in dstDays {
            let noon = day.date(calendar: calendar)!
            check(TasksCalendarDay(date: noon, calendar: calendar) == day, "noon of \(day) is inside \(day)")
            let bounds = calendar.dateInterval(of: .day, for: noon)!
            check(tasksCalendarMatches(dueAt: Int32(bounds.start.timeIntervalSince1970), filter: .day(noon), calendar: calendar), "noon selects \(day) from its first instant")
            check(!tasksCalendarMatches(dueAt: Int32(bounds.end.timeIntervalSince1970), filter: .day(noon), calendar: calendar), "and stops at the next day's first instant")
        }
    }

    /// Every marker counts exactly the rows its day shows (completed rows expanded), the undated badge
    /// counts the No Deadline rows, and every visible task is counted once.
    private static func checkCountsMatchRows(_ state: TasksBoardState, calendar: Calendar, line: Int = #line) {
        func rowCount(_ filter: TasksCalendarFilter) -> Int {
            let sections = state.calendarSections(filter: filter, calendar: calendar)
            return taskIds(sections[0]).count + taskIds(sections[1]).count
        }
        let counts = tasksCalendarDueDateCounts(state.calendarDueDates, calendar: calendar)
        for (day, count) in counts.days {
            check(rowCount(.day(day.date(calendar: calendar)!)) == count, "the \(day) marker counts exactly that day's rows", line: line)
        }
        check(rowCount(.noDeadline) == counts.undated, "the undated badge counts exactly the No Deadline rows", line: line)
        check(counts.days.values.reduce(0, +) + counts.undated == rowCount(.all), "every visible task is counted exactly once", line: line)
    }

    private static func calendarDueDateCountsMatchTheDayRows() {
        let utc = gregorian("UTC")
        let newYork = gregorian("America/New_York")
        let epoch = tasksCalendarDueDateCounts([nil, 0, nil], calendar: utc)
        check(epoch.undated == 2 && epoch.days == [TasksCalendarDay(year: 1970, month: 1, day: 1): 1], "nil is undated; timestamp 0 is 1 January 1970 in UTC")
        check(tasksCalendarDueDateCounts([0], calendar: newYork).days == [TasksCalendarDay(year: 1969, month: 12, day: 31): 1], "timestamp 0 is 31 December 1969 in New York")
        let limit = tasksCalendarDueDateCounts([Int32.max], calendar: utc)
        check(limit.days == [TasksCalendarDay(year: 2038, month: 1, day: 19): 1] && limit.undated == 0, "the largest stored deadline counts on its day")

        let work = folder("work", "Work", order: 0)
        let home = folder("home", "Home", order: 1)
        let tasks = [
            task("w1", in: "work", order: 0, dueAt: stamp(newYork, 2026, 3, 8, 9)),
            task("w2", in: "work", order: 1, completedAt: 10, dueAt: stamp(newYork, 2026, 3, 8, 23, 30)),
            task("w3", in: "work", order: 2, dueAt: nil),
            task("w4", in: "work", order: 3, dueAt: stamp(newYork, 2026, 3, 9, 0, 0, 0)),
            task("h1", in: "home", order: 0, dueAt: stamp(newYork, 2026, 3, 8, 12)),
            task("h2", in: "home", order: 1, completedAt: 20, dueAt: nil),
            task("h3", in: "home", order: 2, dueAt: 0)
        ]
        var state = TasksBoardState(folders: [work, home], tasks: tasks, isCompletedExpanded: true)
        checkCountsMatchRows(state, calendar: newYork)
        checkCountsMatchRows(state, calendar: utc)
        let marchEighth = TasksCalendarDay(year: 2026, month: 3, day: 8)
        let marchNinth = TasksCalendarDay(year: 2026, month: 3, day: 9)
        let all = tasksCalendarDueDateCounts(state.calendarDueDates, calendar: newYork)
        check(all.days[marchEighth] == 3 && all.days[marchNinth] == 1 && all.undated == 2, "fixture: open and completed tasks are counted on their New York days")

        state.select(.folder(id: "work"))
        checkCountsMatchRows(state, calendar: newYork)
        check(tasksCalendarDueDateCounts(state.calendarDueDates, calendar: newYork).days[marchEighth] == 2, "a selected list counts only its own tasks")

        state.select(.all)
        state.update(folders: [work, home], tasks: tasks.filter { $0.id != "w4" })
        checkCountsMatchRows(state, calendar: newYork)
        let afterRemoval = tasksCalendarDueDateCounts(state.calendarDueDates, calendar: newYork)
        check(afterRemoval.days[marchNinth] == nil, "removing a day's last task removes its marker")
        check(afterRemoval.days[marchEighth] == 3, "other days keep their counts")
    }
}
