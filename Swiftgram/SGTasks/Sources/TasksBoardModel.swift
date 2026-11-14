import Foundation

// Zenlygram — Tasks board: the pure UI state behind the task-first Tasks screen.
//
// Foundation only (no UIKit, no database access — only the storage facade's pure title rule), so
// `Tests/run-board-model-tests.sh` runs it on the host against the real `TodoTask` / `TodoFolder`
// types. The controller owns I/O; this file owns
// every decision about WHAT the screen shows: which list is selected, which tasks are open or done,
// in what order, where a quick-added task goes, and when the empty state appears.

/// Which tasks the board shows. A list is selected by id, so renaming it keeps the selection.
public enum TasksBoardFilter: Equatable {
    case all
    case folder(id: String)
}

/// Length limits, owned by the storage facade (one policy for UI and database). The UI checks a
/// title before the entitlement gate, so a title storage would refuse never opens the paywall and
/// never reaches the database.
public enum TasksTitleLimit {
    public static let task = TodoStorage.taskTitleLimit
    public static let folder = TodoStorage.folderTitleLimit
}

public enum TasksTitleValidation: Equatable {
    case valid(String)
    /// Nothing visible: empty, whitespace, or only control / format / combining characters.
    case empty
    /// More than `limit` characters or more than the storage byte limit after trimming.
    case tooLong
}

/// Applies the storage facade's title rule (`TodoStorage.validatedTitle`) and only classifies a
/// refusal for the message the UI shows; it never accepts a title storage would reject.
public func tasksValidateTitle(_ raw: String, limit: Int) -> TasksTitleValidation {
    if let title = try? TodoStorage.validatedTitle(raw, limit: limit) {
        return .valid(title)
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count > limit || trimmed.utf8.count > TodoStorage.maximumTitleUTF8Bytes {
        return .tooLong
    }
    return .empty
}

/// Bounds interactive entry; submission separately validates the complete title.
func tasksAcceptsDraftEdit(current: String, updated: String) -> Bool {
    let updatedCount = updated.count
    return updatedCount <= TasksTitleLimit.task || updatedCount < current.count
}

/// R4 (design 30 §5.6, §7.5): what became of the device rows once the account's copy exists. The
/// controller maps the sync coordinator's cut-over, the account's migration progress and whether its
/// copy is in this account's cloud store on this device onto it
/// (`TasksBoardArchive(cutOver:done:total:keptLocal:recordState:copyOnDevice:)`, TasksBoardSource.swift,
/// where the one-board resolver reads it for its status line and "Eski vazifalar" entry, wf15 §3);
/// nil = nothing copied. Since wf15 the board draws no banner from it (the status line and the
/// read-only "Eski vazifalar" screen say it); the struct stays here so
/// `Tests/run-board-model-tests.sh` keeps compiling the board model without the cut-over sources.
public struct TasksBoardArchive: Equatable {
    public enum Reason: Equatable {
        /// The copies wait in this account's outbox (editable in Cloud, offline too): `done` of
        /// `total` lists and tasks are confirmed; `total` is 0 (no progress line) before the copy was
        /// counted, for a completed copy, and while `awaitsCloudCopy` is set.
        case migrating(done: Int, total: Int)
        /// The copy is confirmed, but this many newer device rows are not in Cloud yet ("Copy to
        /// Cloud" offers the explicit copy).
        case newRows(Int)
        /// The rows were copied to the cloud of another account signed in on this device.
        case otherAccount
        /// Every row is in Cloud: the board is hidden behind Cloud, read-only if it is ever reached.
        case retired
    }

    public let reason: Reason
    /// Rows the copy could not take; they stay on this device.
    public let keptLocal: Int
    /// `migrating` only: the archive's copy is not in this account's cloud store on this device — a
    /// logout purged it, the store does not open, or the step has not yet checked it there. It returns
    /// once the account is confirmed and its snapshot lands and the step re-checks or re-enqueues it.
    /// False for every other reason.
    public let awaitsCloudCopy: Bool

    public init(reason: Reason, keptLocal: Int = 0, awaitsCloudCopy: Bool = false) {
        self.reason = reason
        self.keptLocal = max(0, keptLocal)
        if case .migrating = reason {
            self.awaitsCloudCopy = awaitsCloudCopy
        } else {
            self.awaitsCloudCopy = false
        }
    }

    /// The explicit copy (the status line's "Sinxronlash") is offered for rows that are not synced yet.
    public var offersCopy: Bool {
        if case .newRows = self.reason {
            return true
        }
        return false
    }
}

/// One row of the board's table.
public enum TasksBoardRow: Equatable {
    /// The open-tasks section has nothing to show.
    case emptyMessage(TasksBoardEmptyKind)
    case task(id: String)
    /// The completed disclosure; always present while the current filter has completed tasks.
    case completedHeader(count: Int, isExpanded: Bool)
}

public enum TasksBoardEmptyKind: Equatable {
    /// The current filter has no tasks at all.
    case noTasks
    /// Every task in the current filter is done.
    case allDone
}

/// A filter chip above the list.
public struct TasksBoardChip: Equatable {
    public let filter: TasksBoardFilter
    /// nil for "All" (its title is localized by the UI); the list's own title otherwise.
    public let folderTitle: String?
    public let activeCount: Int
    public let isSelected: Bool
}

public struct TasksBoardState: Equatable {
    public private(set) var folders: [TodoFolder]
    public private(set) var tasks: [TodoTask]
    public private(set) var filter: TasksBoardFilter
    public var isCompletedExpanded: Bool
    /// Read-only mode (wf15 §3.4, the "Eski vazifalar" screen): no quick add, completion, removal or
    /// list change; rows open read-only. Reading, filtering and the calendar stay. The main board is
    /// always writable (the storage fence still refuses a write the cut-over forbids,
    /// `TodoDatabaseError.archived`).
    public private(set) var isReadOnly: Bool

    public init(folders: [TodoFolder], tasks: [TodoTask], filter: TasksBoardFilter = .all, isCompletedExpanded: Bool = false, isReadOnly: Bool = false) {
        self.folders = folders
        self.tasks = tasks
        self.filter = filter
        self.isCompletedExpanded = isCompletedExpanded
        self.isReadOnly = isReadOnly
        self.filter = self.resolved(filter)
    }

    public mutating func setReadOnly(_ isReadOnly: Bool) {
        self.isReadOnly = isReadOnly
    }

    /// Replaces the data with a fresh read. A selected list that no longer exists (deleted on the
    /// Lists screen, or by a logout cleanup) falls back to "All" instead of showing an empty list.
    public mutating func update(folders: [TodoFolder], tasks: [TodoTask]) {
        self.folders = folders
        self.tasks = tasks
        self.filter = self.resolved(self.filter)
    }

    /// Selects a filter; an unknown list id selects "All".
    public mutating func select(_ filter: TasksBoardFilter) {
        self.filter = self.resolved(filter)
    }

    private func resolved(_ filter: TasksBoardFilter) -> TasksBoardFilter {
        switch filter {
        case .all:
            return .all
        case let .folder(id):
            return self.folders.contains(where: { $0.id == id }) ? filter : .all
        }
    }

    /// The list a quick-added task goes to: the selected list, or nil under "All" — the storage
    /// facade then files it in the inbox list, creating that list on first use.
    public var quickAddFolderId: String? {
        switch self.filter {
        case .all:
            return nil
        case let .folder(id):
            return id
        }
    }

    public var selectedFolder: TodoFolder? {
        guard case let .folder(id) = self.filter else {
            return nil
        }
        return self.folders.first(where: { $0.id == id })
    }

    public func task(id: String) -> TodoTask? {
        return self.tasks.first(where: { $0.id == id })
    }

    public func folderTitle(for task: TodoTask) -> String? {
        return self.folders.first(where: { $0.id == task.folderId })?.title
    }

    private func matchesFilter(_ task: TodoTask) -> Bool {
        switch self.filter {
        case .all:
            return true
        case let .folder(id):
            return task.folderId == id
        }
    }

    /// Open tasks of the current filter: lists in their order, tasks in their stored order within
    /// each list (storage already sorts by sort_order, created_at).
    public var activeTasks: [TodoTask] {
        let folderRank = self.folderRanks()
        let indexed = self.tasks.enumerated().filter { !$0.element.isCompleted && self.matchesFilter($0.element) }
        return indexed.sorted { lhs, rhs in
            let lhsRank = folderRank[lhs.element.folderId] ?? Int.max
            let rhsRank = folderRank[rhs.element.folderId] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// Done tasks of the current filter, most recently completed first.
    public var completedTasks: [TodoTask] {
        let indexed = self.tasks.enumerated().filter { $0.element.isCompleted && self.matchesFilter($0.element) }
        return indexed.sorted { lhs, rhs in
            let lhsDate = lhs.element.completedAt ?? Int32.min
            let rhsDate = rhs.element.completedAt ?? Int32.min
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    private func folderRanks() -> [String: Int] {
        var ranks: [String: Int] = [:]
        for (index, folder) in self.folders.enumerated() {
            ranks[folder.id] = index
        }
        return ranks
    }

    /// "All" first, then every list in order, each with its open-task count.
    public var chips: [TasksBoardChip] {
        var activeByFolder: [String: Int] = [:]
        var activeTotal = 0
        for task in self.tasks where !task.isCompleted {
            activeByFolder[task.folderId, default: 0] += 1
            activeTotal += 1
        }
        var chips = [TasksBoardChip(filter: .all, folderTitle: nil, activeCount: activeTotal, isSelected: self.filter == .all)]
        for folder in self.folders {
            let filter = TasksBoardFilter.folder(id: folder.id)
            chips.append(TasksBoardChip(filter: filter, folderTitle: folder.title, activeCount: activeByFolder[folder.id] ?? 0, isSelected: self.filter == filter))
        }
        return chips
    }

    /// Section 0: open tasks (or the empty message). Section 1: the completed disclosure and,
    /// when expanded, the completed tasks. Section 1 is empty when nothing is completed. Read-only
    /// mode has the same two sections (no banner: the screen's footer says why it is read-only).
    public var sections: [[TasksBoardRow]] {
        return self.projectedSections(including: { _ in true })
    }

    /// The board's sections narrowed to one calendar day or to undated tasks, in the board's own order
    /// and with the completed count of that projection. `.all` is exactly `sections`.
    public func calendarSections(filter: TasksCalendarFilter, calendar: Calendar) -> [[TasksBoardRow]] {
        let matcher = TasksCalendarMatcher(filter: filter, calendar: calendar)
        return self.projectedSections(including: { matcher.matches(dueAt: $0.dueAt) })
    }

    /// The deadline of every task the current list filter shows, open and completed; nil for each
    /// undated task. Feeds the agenda's day markers and undated count.
    public var calendarDueDates: [Int32?] {
        return (self.activeTasks + self.completedTasks).map { $0.dueAt }
    }

    private func projectedSections(including isIncluded: (TodoTask) -> Bool) -> [[TasksBoardRow]] {
        let active = self.activeTasks.filter(isIncluded)
        let completed = self.completedTasks.filter(isIncluded)

        let openRows: [TasksBoardRow]
        if active.isEmpty {
            openRows = [.emptyMessage(completed.isEmpty ? .noTasks : .allDone)]
        } else {
            openRows = active.map { .task(id: $0.id) }
        }

        var completedRows: [TasksBoardRow] = []
        if !completed.isEmpty {
            completedRows.append(.completedHeader(count: completed.count, isExpanded: self.isCompletedExpanded))
            if self.isCompletedExpanded {
                completedRows.append(contentsOf: completed.map { .task(id: $0.id) })
            }
        }
        return [openRows, completedRows]
    }
}
