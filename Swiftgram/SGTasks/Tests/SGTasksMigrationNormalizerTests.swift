import Foundation
import SGEntitlement

// Host tests for SGTasksMigrationNormalizer (design 30 §7.1): every iOS vector of
// `Fixtures/tasks-r4-vectors.json` (a verbatim copy of the backend's
// `tests/Fixtures/tasks-r4/vectors.json`; its path is the first argument) plus each rule on its own.
// Pure: no database is opened, nothing reads the network.

private enum NormalizerTestFailure: Error {
    case assertion(String)
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw NormalizerTestFailure.assertion(message)
    }
}

/// Exact comparison (Swift `==` is canonical equivalence; the wire compares scalars).
private func same(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (lhs?, rhs?):
        return Array(lhs.unicodeScalars) == Array(rhs.unicodeScalars)
    default:
        return false
    }
}

private func describe(_ value: String?) -> String {
    guard let value = value else { return "nil" }
    return "\(value.unicodeScalars.count) scalars \(value.prefix(24).debugDescription)"
}

private let now = Date(timeIntervalSince1970: 1_792_512_000)

@main
private struct SGTasksMigrationNormalizerTests {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1 else {
            print("usage: migration-tests <path of Fixtures/tasks-r4-vectors.json>")
            exit(2)
        }
        let vectorsPath = arguments[0]
        let cases: [(String, () throws -> Void)] = [
            ("every iOS normalization vector of the vendored fixture (N1-N13)", { try Self.fixtureVectors(path: vectorsPath) }),
            ("N12: a valid and an unconvertible assignee both give annotation nil", assigneeNeverSent),
            ("edge whitespace is exactly U+0009-U+000D, U+0085, Zs, Zl, Zp", edgeWhitespace),
            ("visible scalars exclude Cc, Cf, Mn, Mc, Me, Zs, Zl, Zp only", visibleScalars),
            ("truncate keeps whole graphemes within L - 1 scalars and adds one ellipsis", truncation),
            ("task title: placeholder, cut, and the full title moved into the description", taskTitles),
            ("list title: trimmed, placeholder, cut at 100 scalars", listTitles),
            ("description: empty is nil, trailing whitespace stays, cut at 4096 scalars", descriptions),
            ("deadline, creation and completion times, priority and sort order bounds", numericRules),
            ("the inbox maps to the Cloud Inbox only under an exact default title", cloudInbox),
            ("placeholder language: uz, ru, else en", locales)
        ]
        var failures: [String] = []
        for (name, test) in cases {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures.append(name)
                print("FAIL: \(name): \(error)")
            }
        }
        guard failures.isEmpty else {
            print("FAIL: \(failures.count) of \(cases.count) migration normalizer tests")
            exit(1)
        }
        print("PASS: \(cases.count) migration normalizer tests")
    }

    // MARK: - The vendored vectors

    private static func fixtureVectors(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vectors = root["normalization"] as? [[String: Any]],
              let rules = root["normalization_rules"] as? [String: Any] else {
            throw NormalizerTestFailure.assertion("the fixture has no normalization vectors")
        }
        try check((root["about"] as? String)?.contains("Swiftgram/SGTasks/Tests/Fixtures/tasks-r4-vectors.json") == true, "the fixture is not the vendored R4 vectors file")
        // The inbox titles and placeholders of the contract are this build's.
        try check(rules["inbox_titles"] as? [String] == SGTasksMigrationNormalizer.defaultInboxTitles, "inbox titles differ from the contract")
        if let placeholders = rules["placeholders"] as? [String: [String: String]] {
            for locale in TodoCloudMigrationRecord.Locale.allCases {
                let normalizer = SGTasksMigrationNormalizer(locale: locale)
                try check(same(placeholders["tasks_migration_untitledTask"]?[locale.rawValue], normalizer.untitledTaskPlaceholder), "untitled placeholder (\(locale)) differs")
                try check(same(placeholders["tasks_migration_importedList"]?[locale.rawValue], normalizer.importedListPlaceholder), "imported-list placeholder (\(locale)) differs")
            }
        } else {
            throw NormalizerTestFailure.assertion("the fixture has no placeholders")
        }
        var ran = 0
        for vector in vectors {
            let id = vector["id"] as? String ?? "?"
            if let platform = vector["platform"] as? String, platform != "ios" {
                continue
            }
            guard let input = vector["input"] as? [String: Any], let expected = vector["expected"] as? [String: Any],
                  let localeRaw = vector["locale"] as? String, let locale = TodoCloudMigrationRecord.Locale(rawValue: localeRaw),
                  let kind = input["kind"] as? String else {
                throw NormalizerTestFailure.assertion("\(id): malformed vector")
            }
            let normalizer = SGTasksMigrationNormalizer(locale: locale)
            let vectorNow = (input["now"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? now
            switch kind {
            case "task":
                try Self.checkTask(id: id, input: input, expected: expected, normalizer: normalizer, now: vectorNow)
            case "list":
                try Self.checkList(id: id, input: input, expected: expected, normalizer: normalizer, now: vectorNow)
            default:
                throw NormalizerTestFailure.assertion("\(id): unknown kind \(kind)")
            }
            ran += 1
        }
        let applicable = vectors.filter { ($0["platform"] as? String ?? "ios") == "ios" }.count
        try check(ran == applicable && ran >= 30, "only \(ran) of \(applicable) iOS vectors ran")
        print("  \(ran) iOS vectors (N1-N13)")
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        return number.int64Value
    }

    private static func checkTask(id: String, input: [String: Any], expected: [String: Any], normalizer: SGTasksMigrationNormalizer, now: Date) throws {
        var assignee: TodoAssignee?
        if let raw = input["assignee"] as? [String: Any], let peerId = Self.int64(raw["peer_id"]), let name = raw["display_name"] as? String {
            assignee = TodoAssignee(peerId: peerId, displayName: name)
        }
        let task = TodoTask(
            id: "t-\(id)", folderId: "f", title: input["title"] as? String ?? "",
            description: input["description"] as? String,
            dueAt: Self.int64(input["due_at"]).map { Int32(truncatingIfNeeded: $0) },
            priority: Int(Self.int64(input["priority"]) ?? 0),
            isCompleted: input["is_completed"] as? Bool ?? false,
            completedAt: Self.int64(input["completed_at"]).map { Int32(truncatingIfNeeded: $0) },
            sortOrder: Int(Self.int64(input["sort_order"]) ?? 0),
            createdDate: Int32(truncatingIfNeeded: Self.int64(input["created_at"]) ?? 0),
            updatedAt: 0,
            assignee: assignee
        )
        let index = Int(Self.int64(input["index"]) ?? 0)
        let result = normalizer.task(task, index: index, now: now)
        let content = result.content(listId: nil)
        for (field, value) in expected {
            switch field {
            case "title":
                try check(same(result.title, value as? String), "\(id): title \(describe(result.title)) != \(describe(value as? String))")
            case "description":
                try check(same(result.description, value as? String), "\(id): description \(describe(result.description)) != \(describe(value as? String))")
            case "due_at":
                try check(result.dueAt.map(Int64.init) == Self.int64(value), "\(id): due_at \(String(describing: result.dueAt))")
            case "created_at":
                try check(result.createdAt?.rawValue == value as? String, "\(id): created_at \(String(describing: result.createdAt))")
            case "completed_at":
                try check(result.completedAt?.rawValue == value as? String, "\(id): completed_at \(String(describing: result.completedAt))")
            case "is_completed":
                try check(result.isCompleted == value as? Bool, "\(id): is_completed")
            case "priority":
                try check(Int64(result.priority) == Self.int64(value), "\(id): priority \(result.priority)")
            case "sort_order":
                try check(Int64(result.sortOrder) == Self.int64(value), "\(id): sort_order \(result.sortOrder)")
            case "annotation":
                try check(value is NSNull && content.annotation == nil, "\(id): an annotation left the device")
            default:
                throw NormalizerTestFailure.assertion("\(id): unchecked expected field \(field)")
            }
        }
        // Every create of a copy carries no annotation, whatever the vector says.
        try check(content.annotation == nil, "\(id): a create carries an annotation")
        try check(content.title == result.title && content.description == result.description && content.priority == result.priority, "\(id): the content differs from the normalized row")
    }

    private static func checkList(id: String, input: [String: Any], expected: [String: Any], normalizer: SGTasksMigrationNormalizer, now: Date) throws {
        let localId = input["local_id"] as? String ?? "f"
        let title = input["title"] as? String ?? ""
        let folder = TodoCloudImportFolder(id: localId, incarnation: "i-\(id)", title: title, sortOrder: Self.int64(input["sort_order"]) ?? 0, createdDate: Self.int64(input["created_at"]) ?? 0)
        let isInbox = SGTasksMigrationNormalizer.isCloudInbox(folderId: localId, title: title)
        let result = normalizer.list(folder, index: Int(Self.int64(input["index"]) ?? 0), now: now)
        for (field, value) in expected {
            switch field {
            case "cloud_inbox":
                try check(isInbox == value as? Bool, "\(id): cloud_inbox \(isInbox)")
            case "title":
                try check(!isInbox && same(result.title, value as? String), "\(id): title \(describe(result.title)) != \(describe(value as? String))")
            case "sort_order":
                try check(Int64(result.sortOrder) == Self.int64(value), "\(id): sort_order \(result.sortOrder)")
            default:
                throw NormalizerTestFailure.assertion("\(id): unchecked expected field \(field)")
            }
        }
    }

    // MARK: - Rules

    private static func assigneeNeverSent() throws {
        let normalizer = SGTasksMigrationNormalizer(locale: .uz)
        for peerId: Int64 in [123_456_789, 8_589_934_593, -5] {
            let task = TodoTask(id: "t", folderId: "f", title: "Ali bilan", description: nil, dueAt: nil, priority: 2, isCompleted: false, completedAt: nil, sortOrder: 0, createdDate: 1_700_000_000, updatedAt: 1_700_000_000, assignee: TodoAssignee(peerId: peerId, displayName: "Ali"))
            let content = normalizer.task(task, index: 0, now: now).content(listId: SGTasksWire.UUID.generate())
            try check(content.annotation == nil, "assignee \(peerId) became an annotation")
            try check(content.title == "Ali bilan" && content.priority == 2, "the task changed besides its assignee")
        }
    }

    private static func edgeWhitespace() throws {
        let edges: [UInt32] = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x20, 0xA0, 0x1680, 0x2000, 0x2005, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
        for value in edges {
            let scalar = Unicode.Scalar(value)!
            try check(SGTasksMigrationNormalizer.isEdgeWhitespace(scalar), "U+\(String(value, radix: 16)) is not edge whitespace")
            let wrapped = "\(Character(scalar))Ish\(Character(scalar))"
            try check(SGTasksMigrationNormalizer.trimmingEdges(wrapped) == "Ish", "U+\(String(value, radix: 16)) was not trimmed")
        }
        // Format characters and marks are not whitespace: they stay at an edge.
        for value: UInt32 in [0x200B, 0xFEFF, 0x0301, 0x00AD] {
            try check(!SGTasksMigrationNormalizer.isEdgeWhitespace(Unicode.Scalar(value)!), "U+\(String(value, radix: 16)) counted as edge whitespace")
        }
        try check(same(SGTasksMigrationNormalizer.trimmingEdges("\u{200B}Ish\u{200B}"), "\u{200B}Ish\u{200B}"), "a zero-width space was trimmed")
        try check(SGTasksMigrationNormalizer.trimmingEdges(" \t\n ") == "", "whitespace-only did not trim to empty")
        try check(SGTasksMigrationNormalizer.trimmingEdges("a  b") == "a  b", "inner whitespace was touched")
    }

    private static func visibleScalars() throws {
        let invisible: [UInt32] = [0x00, 0x1F, 0x7F, 0x200B, 0x200D, 0x2060, 0xFEFF, 0x0301, 0x0903, 0x20DD, 0x20, 0x3000, 0x2028, 0x2029]
        for value in invisible {
            try check(!SGTasksMigrationNormalizer.isVisible(Unicode.Scalar(value)!), "U+\(String(value, radix: 16)) counted as visible")
        }
        let visible: [UInt32] = [0x61, 0x2026, 0x0416, 0x1F600, 0xE000, 0x2E80]
        for value in visible {
            try check(SGTasksMigrationNormalizer.isVisible(Unicode.Scalar(value)!), "U+\(String(value, radix: 16)) counted as invisible")
        }
        try check(!SGTasksMigrationNormalizer.hasVisibleScalar("\u{200B}\u{0301} \t"), "N2b input has a visible scalar")
        try check(SGTasksMigrationNormalizer.hasVisibleScalar("\u{200B}a"), "a visible scalar was missed")
    }

    private static func truncation() throws {
        let exact = String(repeating: "a", count: 200)
        try check(SGTasksMigrationNormalizer.truncate(exact, scalars: 200, bytes: 8192) == exact, "200 scalars were cut")
        let over = String(repeating: "a", count: 201)
        let cut = SGTasksMigrationNormalizer.truncate(over, scalars: 200, bytes: 8192)
        try check(cut.unicodeScalars.count == 200 && cut.hasSuffix("\u{2026}") && cut.unicodeScalars.filter { $0 == "\u{2026}" }.count == 1, "201 scalars did not become 199 + ellipsis")
        // Two-scalar graphemes: never cut inside one.
        let combining = String(repeating: "e\u{0301}", count: 101)
        let cutCombining = SGTasksMigrationNormalizer.truncate(combining, scalars: 200, bytes: 8192)
        try check(cutCombining.unicodeScalars.count == 199 && same(cutCombining, String(repeating: "e\u{0301}", count: 99) + "\u{2026}"), "a grapheme was split: \(cutCombining.unicodeScalars.count)")
        // The byte bound: L - 1 scalars is not enough when bytes run out first.
        let wide = String(repeating: "\u{1F600}", count: 10)
        let cutWide = SGTasksMigrationNormalizer.truncate(wide, scalars: 100, bytes: 20)
        try check(cutWide.utf8.count <= 20 && same(cutWide, String(repeating: "\u{1F600}", count: 4) + "\u{2026}"), "the byte bound was not kept: \(cutWide.utf8.count)")
        try check(SGTasksMigrationNormalizer.truncate("", scalars: 1, bytes: 1) == "", "empty changed")
    }

    private static func taskTitles() throws {
        let en = SGTasksMigrationNormalizer(locale: .en)
        try check(en.taskText(title: "  Ish ", description: nil) == ("Ish", nil), "N1a")
        try check(en.taskText(title: "\u{200B}", description: "x") == ("Untitled task", "x"), "a placeholder title moved something into the description")
        let long = String(repeating: "a", count: 250)
        let text = en.taskText(title: long, description: "Batafsil")
        try check(text.title.unicodeScalars.count == 200 && text.description == long + "\n\nBatafsil", "N3a")
        // A description that would overflow keeps itself, untouched.
        let big = String(repeating: "d", count: 4090)
        let kept = en.taskText(title: long, description: big)
        try check(kept.description == big, "an overflowing prepend replaced the description")
        // The prepend itself may be exactly at the limit.
        let fits = en.taskText(title: long, description: String(repeating: "d", count: 4096 - 252))
        try check(fits.description?.unicodeScalars.count == 4096, "a prepend at exactly 4096 scalars was refused")
        // No truncation: the description stays as normalized (empty → nil).
        try check(en.taskText(title: "Ish", description: "") == ("Ish", nil), "N4a")
        let normalized = en.task(TodoTask(id: "t", folderId: "f", title: "  Ish  ", description: "", dueAt: nil, priority: 0, isCompleted: false, completedAt: nil, sortOrder: 0, createdDate: 0, updatedAt: 0), index: 0, now: now)
        try check(normalized.title == "Ish" && normalized.description == nil, "task() does not apply the title rules")
    }

    private static func listTitles() throws {
        let ru = SGTasksMigrationNormalizer(locale: .ru)
        try check(ru.listTitle("\u{3000}Uy ishlari ") == "Uy ishlari", "N1c")
        try check(ru.listTitle("") == "Импортированный список", "an empty list title got no placeholder")
        let long = String(repeating: "L", count: 150)
        try check(ru.listTitle(long) == String(repeating: "L", count: 99) + "\u{2026}", "N3e")
        try check(ru.listTitle(String(repeating: "L", count: 100)) == String(repeating: "L", count: 100), "100 scalars were cut")
    }

    private static func descriptions() throws {
        try check(SGTasksMigrationNormalizer.description(nil) == nil && SGTasksMigrationNormalizer.description("") == nil, "an empty description is not nil")
        try check(SGTasksMigrationNormalizer.description("Eslatma \n") == "Eslatma \n", "trailing whitespace was trimmed")
        try check(SGTasksMigrationNormalizer.description("   ") == "   ", "a whitespace-only description was changed")
        let exact = String(repeating: "\u{1F600}", count: 4096)
        try check(SGTasksMigrationNormalizer.description(exact) == exact && exact.utf8.count == 16384, "4096 four-byte scalars (16384 bytes) were cut")
        let over = String(repeating: "b", count: 5000)
        try check(SGTasksMigrationNormalizer.description(over) == String(repeating: "b", count: 4095) + "\u{2026}", "N5a")
    }

    private static func numericRules() throws {
        try check(SGTasksMigrationNormalizer.deadline(nil) == nil && SGTasksMigrationNormalizer.deadline(-1) == nil, "a negative deadline stayed")
        try check(SGTasksMigrationNormalizer.deadline(0) == 0 && SGTasksMigrationNormalizer.deadline(Int64(Int32.max)) == Int32.max, "a valid deadline changed")
        try check(SGTasksMigrationNormalizer.deadline(Int64(Int32.max) + 1) == nil, "a deadline beyond Int32 stayed")
        try check(SGTasksMigrationNormalizer.instant(1_792_512_300, now: now)?.rawValue == "2026-10-20T16:05:00Z", "now + 300 s was dropped")
        try check(SGTasksMigrationNormalizer.instant(1_792_512_301, now: now) == nil && SGTasksMigrationNormalizer.instant(-1, now: now) == nil, "an invalid creation time stayed")
        try check(SGTasksMigrationNormalizer.instant(0, now: now)?.rawValue == "1970-01-01T00:00:00Z", "the epoch was dropped")
        try check(SGTasksMigrationNormalizer.completedAt(isCompleted: false, seconds: 1_792_511_940, now: now) == nil, "an open task kept its completion time")
        try check(SGTasksMigrationNormalizer.completedAt(isCompleted: true, seconds: nil, now: now) == nil, "an unknown completion time was invented")
        try check(SGTasksMigrationNormalizer.priority(7) == 4 && SGTasksMigrationNormalizer.priority(-1) == 0 && SGTasksMigrationNormalizer.priority(3) == 3, "priority is not clamped to 0...4")
        try check(SGTasksMigrationNormalizer.sortOrder(-1, index: 3) == -1 && SGTasksMigrationNormalizer.sortOrder(Int64(Int32.min), index: 3) == Int32.min, "a sort order within Int32 changed")
        try check(SGTasksMigrationNormalizer.sortOrder(Int64(Int32.max) + 1, index: 3) == 3072, "N9a")
        try check(SGTasksMigrationNormalizer.sortOrder(Int64(Int32.min) - 1, index: 0) == 0, "N9d")
        try check(SGTasksMigrationNormalizer.sortOrder(Int64.max, index: Int.max / 2) == Int32.max, "an overflowing index did not saturate")
    }

    private static func cloudInbox() throws {
        for title in ["Inbox", "Kiruvchi", "Входящие"] {
            try check(SGTasksMigrationNormalizer.isCloudInbox(folderId: TodoStorage.inboxFolderId, title: title), "default inbox \(title) is not the Cloud Inbox")
        }
        for title in ["inbox", "Inbox ", " Inbox", "INBOX", "Ishlarim", ""] {
            try check(!SGTasksMigrationNormalizer.isCloudInbox(folderId: TodoStorage.inboxFolderId, title: title), "inbox titled \(title.debugDescription) became the Cloud Inbox")
        }
        try check(!SGTasksMigrationNormalizer.isCloudInbox(folderId: "f1", title: "Inbox"), "an ordinary folder titled Inbox became the Cloud Inbox")
    }

    private static func locales() throws {
        let expected: [(String, TodoCloudMigrationRecord.Locale)] = [("uz", .uz), ("uz-Latn", .uz), ("UZ", .uz), ("ru", .ru), ("ru_RU", .ru), ("en", .en), ("de", .en), ("", .en), ("uzb", .en)]
        for (code, locale) in expected {
            try check(TodoCloudMigrationRecord.Locale(languageCode: code) == locale, "\(code.debugDescription) is not \(locale)")
        }
        try check(SGTasksMigrationNormalizer(locale: .uz).untitledTaskPlaceholder == "Nomsiz vazifa", "uz placeholder")
        try check(same(SGTasksMigrationNormalizer(locale: .uz).importedListPlaceholder, "Import qilingan ro\u{02BB}yxat"), "the uz placeholder lost its U+02BB")
    }
}
