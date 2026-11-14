import Foundation
import SGEntitlement

// MARK: - Zenlygram Tasks R4: normalization of the copied device rows (design 30 §7.1)
//
// Pure: every create of the automatic first migration and of the R4 explicit copy is built from
// these values; the originals stay unchanged in the local archive. Instead of refusing a row the
// rules trim, fill a placeholder, truncate (keeping the full title in the description), clamp and
// drop what the server would refuse. The vectors N1–N13 are `Tests/Fixtures/tasks-r4-vectors.json`,
// a verbatim copy of the backend's `tests/Fixtures/tasks-r4/vectors.json` (identical on Android).
//
// The assignee is a Telegram contact the user was promised stays on this device (F16): it is never
// part of a create, so `content(listId:)` always carries `annotation: nil`.

public struct SGTasksMigrationNormalizer: Equatable {
    public typealias Locale = TodoCloudMigrationRecord.Locale

    public static let listTitleScalarLimit = 100
    public static let taskTitleScalarLimit = 200
    public static let titleByteLimit = 8192
    public static let descriptionScalarLimit = 4096
    public static let descriptionByteLimit = 16384
    /// A creation or completion time later than the estimated server time by more than this is unknown.
    public static let futureSkew: TimeInterval = 300
    /// A sort order that does not fit the wire becomes the row's index among its siblings times this.
    public static let sortOrderStep = 1024
    /// The stored titles of the stable inbox that map to the virtual Cloud Inbox: its default title in
    /// each shipped language, compared exactly (a renamed inbox is a real list).
    public static let defaultInboxTitles: [String] = ["Inbox", "Kiruvchi", "Входящие"]

    /// The record's `normalization_locale`: placeholder titles are in this language for good.
    public let locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    // MARK: Normalized rows

    public struct List: Equatable {
        public let title: String
        public let sortOrder: SGTasksWire.SortOrder
        public let createdAt: SGTasksWire.Instant?
    }

    public struct Task: Equatable {
        public let title: String
        public let description: String?
        public let dueAt: SGTasksWire.Deadline?
        public let priority: Int
        public let sortOrder: SGTasksWire.SortOrder
        public let createdAt: SGTasksWire.Instant?
        public let isCompleted: Bool
        /// nil for an open task, and for a completed one whose time is unknown or invalid.
        public let completedAt: SGTasksWire.Instant?

        /// The create's content. The local assignee never leaves the device: no annotation, ever.
        public func content(listId: SGTasksWire.UUID?) -> SGTasksWire.Content {
            return SGTasksWire.Content(listId: listId, title: self.title, description: self.description, dueAt: self.dueAt, priority: self.priority, sortOrder: self.sortOrder, annotation: nil)
        }
    }

    /// The stable inbox under one of its default titles is the virtual Cloud Inbox (no list.create;
    /// its tasks carry `list_id: null`).
    public static func isCloudInbox(folderId: String, title: String) -> Bool {
        guard folderId == TodoStorage.inboxFolderId else { return false }
        let scalars = Array(title.unicodeScalars)
        return Self.defaultInboxTitles.contains { Array($0.unicodeScalars) == scalars }
    }

    /// `index`: the folder's 0-based position among the folders in local order; `now`: the estimated
    /// server time.
    public func list(_ folder: TodoCloudImportFolder, index: Int, now: Date) -> List {
        return List(title: self.listTitle(folder.title), sortOrder: Self.sortOrder(folder.sortOrder, index: index), createdAt: Self.instant(folder.createdDate, now: now))
    }

    /// `index`: the task's 0-based position within its folder in local order.
    public func task(_ task: TodoTask, index: Int, now: Date) -> Task {
        let text = self.taskText(title: task.title, description: task.description)
        return Task(
            title: text.title,
            description: text.description,
            dueAt: Self.deadline(task.dueAt.map(Int64.init)),
            priority: Self.priority(task.priority),
            sortOrder: Self.sortOrder(Int64(task.sortOrder), index: index),
            createdAt: Self.instant(Int64(task.createdDate), now: now),
            isCompleted: task.isCompleted,
            completedAt: Self.completedAt(isCompleted: task.isCompleted, seconds: task.completedAt.map(Int64.init), now: now)
        )
    }

    // MARK: Placeholders (`tasks_migration_untitledTask` / `tasks_migration_importedList`)

    public var untitledTaskPlaceholder: String {
        switch self.locale {
        case .uz: return "Nomsiz vazifa"
        case .ru: return "Задача без названия"
        case .en: return "Untitled task"
        }
    }

    public var importedListPlaceholder: String {
        switch self.locale {
        case .uz: return "Import qilingan ro\u{02BB}yxat"
        case .ru: return "Импортированный список"
        case .en: return "Imported list"
        }
    }

    // MARK: Rules

    /// U+0009–U+000D, U+0085 and the categories Zs, Zl, Zp.
    public static func isEdgeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09 ... 0x0D, 0x85:
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// A scalar outside Cc, Cf, Mn, Mc, Me, Zs, Zl, Zp (the server's visible text rule).
    public static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .nonspacingMark, .spacingMark, .enclosingMark, .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
    }

    public static func trimmingEdges(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { !Self.isEdgeWhitespace($0) }),
              let last = scalars.lastIndex(where: { !Self.isEdgeWhitespace($0) }) else { return "" }
        return String(String.UnicodeScalarView(scalars[first ... last]))
    }

    public static func hasVisibleScalar(_ value: String) -> Bool {
        return value.unicodeScalars.contains(where: Self.isVisible)
    }

    /// `truncate(s, L, B)`: `s` when it has at most `L` scalars and `B` UTF-8 bytes; otherwise the
    /// longest prefix ending on a grapheme boundary with at most `L - 1` scalars and `B - 3` bytes,
    /// followed by U+2026. Counting scalars keeps the server's grapheme count within `L`.
    public static func truncate(_ value: String, scalars limit: Int, bytes byteLimit: Int) -> String {
        return Self.truncated(value, scalars: limit, bytes: byteLimit).value
    }

    static func truncated(_ value: String, scalars limit: Int, bytes byteLimit: Int) -> (value: String, didTruncate: Bool) {
        if value.unicodeScalars.count <= limit && value.utf8.count <= byteLimit {
            return (value, false)
        }
        var scalars = 0
        var bytes = 0
        var end = value.startIndex
        for character in value {
            let characterScalars = character.unicodeScalars.count
            let characterBytes = character.utf8.count
            if scalars + characterScalars > limit - 1 || bytes + characterBytes > byteLimit - 3 {
                break
            }
            scalars += characterScalars
            bytes += characterBytes
            end = value.index(after: end)
        }
        return (String(value[..<end]) + "\u{2026}", true)
    }

    /// Trimmed; no visible scalar left → the imported-list placeholder; at most 100 scalars.
    public func listTitle(_ raw: String) -> String {
        let trimmed = Self.trimmingEdges(raw)
        let full = Self.hasVisibleScalar(trimmed) ? trimmed : self.importedListPlaceholder
        return Self.truncate(full, scalars: Self.listTitleScalarLimit, bytes: Self.titleByteLimit)
    }

    /// The title is trimmed (no visible scalar → the untitled placeholder) and cut to 200 scalars.
    /// When it was cut, the description becomes the full title — followed by a blank line and the
    /// normalized description, if any — as long as that fits the description limits; else the
    /// normalized description stays.
    public func taskText(title raw: String, description rawDescription: String?) -> (title: String, description: String?) {
        let trimmed = Self.trimmingEdges(raw)
        let full = Self.hasVisibleScalar(trimmed) ? trimmed : self.untitledTaskPlaceholder
        let title = Self.truncated(full, scalars: Self.taskTitleScalarLimit, bytes: Self.titleByteLimit)
        var description = Self.description(rawDescription)
        if title.didTruncate {
            let candidate = description.map { full + "\n\n" + $0 } ?? full
            if candidate.unicodeScalars.count <= Self.descriptionScalarLimit && candidate.utf8.count <= Self.descriptionByteLimit {
                description = candidate
            }
        }
        return (title.value, description)
    }

    /// `""` → nil; at most 4096 scalars and 16384 bytes. No edge rule: trailing whitespace stays.
    public static func description(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        return Self.truncate(raw, scalars: Self.descriptionScalarLimit, bytes: Self.descriptionByteLimit)
    }

    /// iOS deadlines are seconds: negative or beyond Int32 → nil (0 stays).
    public static func deadline(_ seconds: Int64?) -> SGTasksWire.Deadline? {
        guard let seconds = seconds, seconds >= 0 else { return nil }
        return SGTasksWire.Deadline(exactly: seconds)
    }

    /// A creation time: negative or later than `now` + 300 s → nil (the server stamps its own).
    public static func instant(_ seconds: Int64?, now: Date) -> SGTasksWire.Instant? {
        guard let seconds = seconds, seconds >= 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        guard date <= now.addingTimeInterval(Self.futureSkew) else { return nil }
        return SGTasksWire.Instant(date: date)
    }

    /// nil for an open task; for a completed task an invalid time (as `instant`) is unknown (nil).
    public static func completedAt(isCompleted: Bool, seconds: Int64?, now: Date) -> SGTasksWire.Instant? {
        guard isCompleted else { return nil }
        return Self.instant(seconds, now: now)
    }

    public static func priority(_ value: Int) -> Int {
        return min(max(value, 0), 4)
    }

    /// A value that fits Int32 stays; any other becomes `index * 1024`.
    public static func sortOrder(_ value: Int64, index: Int) -> SGTasksWire.SortOrder {
        if let exact = SGTasksWire.SortOrder(exactly: value) {
            return exact
        }
        let (product, overflow) = max(index, 0).multipliedReportingOverflow(by: Self.sortOrderStep)
        return overflow ? SGTasksWire.SortOrder.max : SGTasksWire.SortOrder(clamping: product)
    }
}
