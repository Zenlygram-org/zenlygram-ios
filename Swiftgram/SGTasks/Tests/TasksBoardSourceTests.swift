import Foundation

// Host tests for the one-board resolver (Sources/TasksBoardSource.swift, wf15 §3.1–§3.3): the state
// table S1–S11 row by row, the precedence of the rows, the "no row is ever stranded" rule over a grid
// of inputs, and the one-shot cleanup of the retired scope keys. No `@main`:
// TasksCloudBoardModelTests.main runs `run()` after its own cases (the same executable, the same
// real value types — permission, cut-over, migration record, cloud read-only reason).
enum TasksBoardSourceTests {
    private static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        precondition(condition, "line \(line): \(message)")
    }

    private typealias RecordState = TodoCloudMigrationRecord.State
    private typealias RecordReason = TodoCloudMigrationRecord.Reason

    private static func inputs(
        _ permission: SGTasksSyncPermission,
        cutOver: TasksCutOver = .none,
        record: RecordState? = nil,
        reason: RecordReason? = nil,
        owned: Bool = true,
        rows: Int = 0,
        importable: Int? = nil,
        needsCorrection: Int = 0,
        archive: TasksBoardArchive? = nil,
        complete: Bool = true,
        readOnly: TasksCloudReadOnlyReason? = nil,
        cachedRows: Bool = false,
        consentEntry: Bool = true,
        dismissed: Bool = false
    ) -> TasksBoardSourceInputs {
        return TasksBoardSourceInputs(
            permission: permission,
            cutOver: cutOver,
            recordState: record,
            recordReason: reason,
            deviceOwnedByThisOrFree: owned,
            deviceLiveRows: rows,
            importableDeviceRows: importable,
            importNeedsCorrection: needsCorrection,
            archive: archive,
            snapshotComplete: complete,
            cloudReadOnly: readOnly,
            hasOwnCachedSyncedRows: cachedRows,
            consentEntryAvailable: consentEntry,
            otherAccountNoticeDismissed: dismissed
        )
    }

    private static func resolve(_ inputs: TasksBoardSourceInputs) -> TasksBoardPresentation {
        return TasksBoardSourceResolver.resolve(inputs)
    }

    private static func present(_ source: TasksBoardSource, _ line: TasksSyncLine, _ entry: TasksOlderEntry?, _ assign: TasksAssignAvailability) -> TasksBoardPresentation {
        return TasksBoardPresentation(source: source, line: line, olderEntry: entry, assign: assign)
    }

    /// The plain synced board: no line, no entry, a Masʼul can be picked.
    private static let plainSynced = present(.synced(readOnly: false), .none, nil, .available)

    private static let everyRecord: [(RecordState?, RecordReason?)] = [
        (nil, nil), (.claimed, nil), (.enqueued, nil), (.completed, nil), (.released, .withdrawn),
        (.skipped, .existingMappings), (.skipped, .deviceOwnedByOther), (.skipped, .scopeChanged)
    ]

    /// A queued copy with 3 of 9 rows confirmed and one row kept local.
    private static let queuedArchive = TasksBoardArchive(cutOver: .archive(.migrating), done: 3, total: 9, keptLocal: 1, recordState: .enqueued)!
    /// A confirmed copy whose store was purged by a logout (`awaitsCloudCopy`).
    private static let purgedArchive = TasksBoardArchive(cutOver: .archive(.migrating), done: 9, total: 9, keptLocal: 2, recordState: .completed, copyOnDevice: false)!

    static func run() {
        s1LegacyIsTodaysDeviceBoard()
        s2SyncOffIsTheDeviceBoardWithTheOneFooterLine()
        s3WaitingWithoutACopyIsTheDeviceBoard()
        s4WaitingWithACopyIsTheSyncedBoardAndMasulNeedsTheLink()
        s5TurningOnOnlyWhileTheRecordStillMoves()
        s6bSkippedRecordsOfferTheExplicitCopy()
        s6SyncedBoardKeepsAnotherAccountsRowsReachable()
        s7MigratingArchiveLines()
        s8NewRowsArchive()
        s9OtherAccountNoticeOnce()
        s10RetiredIsTheSyncedBoardAlone()
        s11ConsentFenceOverridesEverySyncedRow()
        firstMatchingRowWins()
        noDeviceRowIsEverStranded()
        scopeKeysAreRemovedOnce()
        print("PASS: Tasks board source (S1–S11 row by row; S5 only for a nil / claimed / released record; S6b for skipped existing_mappings / scope_changed with the explicit copy's count nil / n / 0; a marker released by another account is not free; S4 Masʼul needsLink; S11 over every synced row; first match wins; no device row stranded over the input grid; scope keys removed once)")
    }

    // MARK: - Rows

    static func s1LegacyIsTodaysDeviceBoard() {
        for rows in [0, 3] {
            for (record, reason) in everyRecord {
                let presentation = resolve(inputs(.legacy, record: record, reason: reason, rows: rows, importable: 2, readOnly: .consentFenced, cachedRows: true))
                check(presentation == present(.device(writable: true), .none, nil, .legacyLocal), "S1: a build without a Tasks backend is today's device board with the local assignee (rows \(rows), record \(String(describing: record)))")
            }
        }
    }

    static func s2SyncOffIsTheDeviceBoardWithTheOneFooterLine() {
        check(resolve(inputs(.forbidden, rows: 5)) == present(.device(writable: true), .syncOff(tappable: true), nil, .needsConsent), "S2: the device board, writable, the one footer line, Masʼul needs consent")
        check(resolve(inputs(.forbidden, consentEntry: false)).line == .syncOff(tappable: false), "S2: plain text when the consent hook is not installed")
        check(resolve(inputs(.forbidden, cachedRows: true)) == present(.device(writable: true), .syncOff(tappable: true), .syncedCopy, .needsConsent), "S2: the account's own cached synced rows stay reachable as Sinxronlangan nusxa (F12)")
        for (record, reason) in everyRecord {
            for owned in [true, false] {
                let presentation = resolve(inputs(.forbidden, record: record, reason: reason, owned: owned, rows: 4, importable: 4, readOnly: .withdrawn))
                check(presentation == present(.device(writable: true), .syncOff(tappable: true), nil, .needsConsent), "S2 whatever the record (\(String(describing: record))), the marker (\(owned)) and the cloud hold: the device board")
            }
        }
    }

    static func s3WaitingWithoutACopyIsTheDeviceBoard() {
        for rows in [0, 6] {
            for (record, reason) in everyRecord {
                let presentation = resolve(inputs(.waiting, record: record, reason: reason, rows: rows, importable: 1, cachedRows: true))
                check(presentation == present(.device(writable: true), .waitingLink, nil, .needsLink), "S3: consent given, link pending, nothing copied: the device board with the link line (rows \(rows), record \(String(describing: record)))")
            }
        }
    }

    static func s4WaitingWithACopyIsTheSyncedBoardAndMasulNeedsTheLink() {
        let migrating = resolve(inputs(.waiting, cutOver: .archive(.migrating), record: .enqueued, rows: 9, archive: queuedArchive))
        check(migrating == present(.synced(readOnly: false), .waitingLink, .older(.migrating), .needsLink), "S4 migrating: the synced board (changes queue until the link), the link line, the device rows in Roʻyxatlar, no new assignment before the link")
        let purged = resolve(inputs(.waiting, cutOver: .archive(.migrating), record: .completed, rows: 9, archive: purgedArchive))
        check(purged == present(.synced(readOnly: false), .waitingLink, .older(.awaiting), .needsLink), "S4 after a logout/re-login: the entry says the copy returns")
        check(resolve(inputs(.waiting, cutOver: .archive(.migrating), record: .enqueued, rows: 9)).olderEntry == .older(.migrating), "S4 before the archive was computed: the reason comes from the cut-over")
        let newRows = TasksBoardArchive(cutOver: .archive(.newRows(2)), done: 7, total: 7, keptLocal: 0, recordState: .completed)
        check(resolve(inputs(.waiting, cutOver: .archive(.newRows(2)), record: .completed, rows: 9, archive: newRows)) == present(.synced(readOnly: false), .waitingLink, .older(.newRows(2)), .needsLink), "S4 with newer device rows: still the link line (the copy waits for the link too), the rows in Roʻyxatlar")
        check(resolve(inputs(.waiting, cutOver: .archive(.otherAccount), owned: false, rows: 9)) == present(.synced(readOnly: false), .waitingLink, .older(.otherAccount), .needsLink), "S4 over another account's copy")
        check(resolve(inputs(.waiting, cutOver: .retired, record: .completed, rows: 9)) == present(.synced(readOnly: false), .waitingLink, nil, .needsLink), "S4 retired: every device row is in the synced board, no entry")
        check(resolve(inputs(.waiting, cutOver: .archive(.migrating), record: .enqueued, rows: 0, archive: queuedArchive)) == present(.synced(readOnly: false), .waitingLink, nil, .needsLink), "S4 without device rows: nothing to reach")
        check(resolve(inputs(.waiting, cutOver: .archive(.migrating), record: .enqueued, rows: 9, archive: queuedArchive)).source == .synced(readOnly: false), "S4 is writable: tasksCloudReadOnlyReason is nil for consentRequired(waiting: true)")
    }

    static func s5TurningOnOnlyWhileTheRecordStillMoves() {
        let turningOn = present(.device(writable: true), .turningOn, nil, .wait)
        check(resolve(inputs(.allowed, record: nil, rows: 4)) == turningOn, "S5 no record yet: the device board while the step claims and copies; a Masʼul waits")
        check(resolve(inputs(.allowed, record: .claimed, rows: 4, importable: 4)) == turningOn, "S5 claimed: waits for the link and the complete snapshot, then the step copies")
        check(resolve(inputs(.allowed, record: .released, reason: .withdrawn, rows: 1)) == turningOn, "S5 released (a re-grant): claimed again at once")
        check(resolve(inputs(.allowed, record: nil, rows: 0)) == plainSynced, "no device rows: the synced board at once (S6), never a turning-on line for nothing")
        check(resolve(inputs(.allowed, record: nil, owned: false, rows: 4)) == present(.synced(readOnly: false), .none, .older(.otherAccount), .available), "the rows are another account's (its marker held): S6 with the entry, never S5")
        check(resolve(inputs(.allowed, record: .claimed, owned: false, rows: 4)) == present(.synced(readOnly: false), .none, .older(.otherAccount), .available), "a marker released by ANOTHER account is not free (claimCloudDevice answers releasedByOther): S6, never S5")
        check(resolve(inputs(.allowed, record: .released, reason: .withdrawn, owned: false, rows: 4)).source == .synced(readOnly: false), "this account's released record over another account's marker: S6, never S5")
        for reason in [RecordReason.existingMappings, .scopeChanged, .deviceOwnedByOther] {
            check(resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 4)).source == .synced(readOnly: false), "a skipped record (\(reason)) never moves again: never S5")
        }
        for record in [RecordState.enqueued, .completed] {
            check(resolve(inputs(.allowed, record: record, rows: 4)).source == .synced(readOnly: false), "a copy under another server account (\(record), cut-over row 2) is never S5")
        }
    }

    static func s6bSkippedRecordsOfferTheExplicitCopy() {
        for reason in [RecordReason.existingMappings, .scopeChanged] {
            let checking = resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 4, importable: nil, complete: false))
            check(checking == present(.synced(readOnly: false), .none, .older(.checking), .available), "S6b \(reason): the synced board; while the copy's count is unknown there is no line and the entry says it is being checked")
            check(resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 4, importable: nil, complete: true)).olderEntry == .older(.checking), "S6b \(reason): still checking until the count is published, even with the snapshot complete")
            let three = resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 4, importable: 3))
            check(three == present(.synced(readOnly: false), .newRows(3, keptLocal: 0), .older(.newRows(3)), .available), "S6b \(reason): rows the explicit copy would enqueue: the line to the CREATE-gated import (tappable to the rows) and the entry")
            let withKept = resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 5, importable: 3, needsCorrection: 1))
            check(withKept == present(.synced(readOnly: false), .newRows(3, keptLocal: 1), .older(.newRows(3)), .available), "S6b \(reason): the rows that need a correction first are the second line")
            check(resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 4, importable: 0)) == plainSynced, "S6b \(reason): nothing left to copy: every device row is in the synced board (as S10)")
            let onlyKept = resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 4, importable: 0, needsCorrection: 2))
            check(onlyKept == present(.synced(readOnly: false), .newRows(2, keptLocal: 2), .older(.newRows(2)), .available), "S6b \(reason): rows that need a correction first are never stranded: the line reaches the import screen that lists them")
            check(resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 4, importable: -1, needsCorrection: -3)) == plainSynced, "S6b \(reason): negative counts read as nothing")
            check(resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 0, importable: 3)) == plainSynced, "S6b needs device rows: without them S6")
            check(resolve(inputs(.allowed, record: .skipped, reason: reason, owned: false, rows: 4, importable: 3)) == present(.synced(readOnly: false), .none, .older(.otherAccount), .available), "S6b needs this account's (or a free) marker: another account's, held or released, is S6 with the entry, never S6b")
            check(resolve(inputs(.allowed, record: .skipped, reason: reason, rows: 4, importable: 3)).source == .synced(readOnly: false), "S6b is never the device board (never S5)")
        }
        check(resolve(inputs(.allowed, record: .skipped, reason: .deviceOwnedByOther, owned: false, rows: 4, importable: 3)) == present(.synced(readOnly: false), .none, .older(.otherAccount), .available), "skipped(device_owned_by_other) is S6 (the rows are another account's), never S6b")
    }

    static func s6SyncedBoardKeepsAnotherAccountsRowsReachable() {
        for (record, reason) in everyRecord {
            for owned in [true, false] {
                check(resolve(inputs(.allowed, record: record, reason: reason, owned: owned, rows: 0, importable: 2)) == plainSynced, "S6 without device rows: nothing to reach, whatever the record (\(String(describing: record))) and the marker (\(owned))")
            }
            check(resolve(inputs(.allowed, record: record, reason: reason, owned: false, rows: 2)) == present(.synced(readOnly: false), .none, .older(.otherAccount), .available), "S6: another account's rows (its marker held or released) are in Roʻyxatlar, whatever this account's record (\(String(describing: record)))")
        }
        check(resolve(inputs(.allowed, record: .skipped, reason: .deviceOwnedByOther, owned: true, rows: 2)) == present(.synced(readOnly: false), .none, .older(.otherAccount), .available), "S6: skipped(device_owned_by_other) with the marker freed since (the owner withdrew before copying): still the other account's rows, reachable")
        for record in [RecordState.enqueued, .completed] {
            check(resolve(inputs(.allowed, record: record, owned: true, rows: 2)) == present(.synced(readOnly: false), .none, .older(.checking), .available), "S6 transient (cut-over row 2, \(record) under another server account): the rows stay reachable until the step records skipped(scope_changed) → S6b")
        }
    }

    static func s7MigratingArchiveLines() {
        check(resolve(inputs(.allowed, cutOver: .archive(.migrating), record: .enqueued, rows: 9, archive: queuedArchive)) == present(.synced(readOnly: false), .progress(done: 3, total: 9, keptLocal: 1), .older(.migrating), .available), "S7: a queued copy on this device shows its progress, tappable to Eski vazifalar")
        check(resolve(inputs(.allowed, cutOver: .archive(.migrating), record: .completed, rows: 9, archive: purgedArchive)) == present(.synced(readOnly: false), .loading(keptLocal: 2), .older(.awaiting), .available), "S7 after a logout/re-login: loading until the snapshot is back; the entry says the copy returns")
        let completedUnchecked = TasksBoardArchive(cutOver: .archive(.migrating), done: 9, total: 9, keptLocal: 0, recordState: .completed)
        check(resolve(inputs(.allowed, cutOver: .archive(.migrating), record: .completed, rows: 9, archive: completedUnchecked)) == present(.synced(readOnly: false), .turningOn, .older(.migrating), .available), "S7: a completed copy the step has not checked here yet claims no copying: turning on")
        let uncounted = TasksBoardArchive(cutOver: .archive(.migrating), done: 0, total: 0, keptLocal: 0)
        check(resolve(inputs(.allowed, cutOver: .archive(.migrating), record: .enqueued, rows: 9, archive: uncounted)).line == .turningOn, "S7: nothing counted yet: turning on")
        check(resolve(inputs(.allowed, cutOver: .archive(.migrating), record: .enqueued, rows: 9)) == present(.synced(readOnly: false), .turningOn, .older(.migrating), .available), "S7 before the archive was computed: turning on, the entry from the cut-over")
        check(resolve(inputs(.allowed, cutOver: .archive(.migrating), record: .enqueued, owned: false, rows: 0, archive: queuedArchive)) == present(.synced(readOnly: false), .progress(done: 3, total: 9, keptLocal: 1), .older(.migrating), .available), "S7 reads the archive, not the row count or the marker")
        check(resolve(inputs(.allowed, cutOver: .archive(.migrating), record: .enqueued, rows: 9, archive: queuedArchive)).line.opensOlderTasks, "the progress line is tappable")
        check(resolve(inputs(.allowed, cutOver: .archive(.migrating), record: .completed, rows: 9, archive: purgedArchive)).line.opensOlderTasks, "the loading line is tappable")
    }

    static func s8NewRowsArchive() {
        let archive = TasksBoardArchive(cutOver: .archive(.newRows(4)), done: 9, total: 9, keptLocal: 2, recordState: .completed)
        check(resolve(inputs(.allowed, cutOver: .archive(.newRows(4)), record: .completed, rows: 13, archive: archive)) == present(.synced(readOnly: false), .newRows(4, keptLocal: 2), .older(.newRows(4)), .available), "S8: the newer rows' line with the import action and the kept-local second line; the rows in Roʻyxatlar")
        check(resolve(inputs(.allowed, cutOver: .archive(.newRows(4)), record: .completed, rows: 13)) == present(.synced(readOnly: false), .newRows(4, keptLocal: 0), .older(.newRows(4)), .available), "S8 before the archive was computed: the count from the cut-over, no kept-local count")
        check(resolve(inputs(.allowed, cutOver: .archive(.newRows(4)), record: .completed, rows: 13, archive: archive)).line.opensOlderTasks, "the new-rows line is tappable")
    }

    static func s9OtherAccountNoticeOnce() {
        check(resolve(inputs(.allowed, cutOver: .archive(.otherAccount), owned: false, rows: 6)) == present(.synced(readOnly: false), .otherAccountNotice, .older(.otherAccount), .available), "S9: this account's own synced board with the one-time notice; the rows in Roʻyxatlar")
        check(resolve(inputs(.allowed, cutOver: .archive(.otherAccount), owned: false, rows: 6, dismissed: true)) == present(.synced(readOnly: false), .none, .older(.otherAccount), .available), "S9 dismissed: no line, the entry stays")
        check(resolve(inputs(.allowed, cutOver: .archive(.otherAccount), record: .skipped, reason: .deviceOwnedByOther, owned: false, rows: 6, archive: TasksBoardArchive(cutOver: .archive(.otherAccount), done: 5, total: 9, keptLocal: 3))).line == .otherAccountNotice, "S9 with the usual skipped record and archive")
    }

    static func s10RetiredIsTheSyncedBoardAlone() {
        check(resolve(inputs(.allowed, cutOver: .retired, record: .completed, rows: 9, importable: 0, archive: TasksBoardArchive(cutOver: .retired, done: 9, total: 9, keptLocal: 0, recordState: .completed))) == plainSynced, "S10: every device row is in the synced board: no line, no entry")
        check(resolve(inputs(.allowed, cutOver: .retired, record: .completed, rows: 0)) == plainSynced, "S10 without device rows")
    }

    static func s11ConsentFenceOverridesEverySyncedRow() {
        let syncedRows: [(String, TasksBoardSourceInputs)] = [
            ("S4", inputs(.waiting, cutOver: .archive(.migrating), record: .enqueued, rows: 9, archive: queuedArchive)),
            ("S6", inputs(.allowed, owned: false, rows: 2)),
            ("S6 empty", inputs(.allowed, rows: 0)),
            ("S6b", inputs(.allowed, record: .skipped, reason: .existingMappings, rows: 4, importable: 3)),
            ("S6b checking", inputs(.allowed, record: .skipped, reason: .scopeChanged, rows: 4, importable: nil, complete: false)),
            ("S7", inputs(.allowed, cutOver: .archive(.migrating), record: .enqueued, rows: 9, archive: queuedArchive)),
            ("S7 awaiting", inputs(.allowed, cutOver: .archive(.migrating), record: .completed, rows: 9, archive: purgedArchive)),
            ("S8", inputs(.allowed, cutOver: .archive(.newRows(4)), record: .completed, rows: 13, archive: TasksBoardArchive(cutOver: .archive(.newRows(4)), done: 9, total: 9, keptLocal: 2, recordState: .completed))),
            ("S9", inputs(.allowed, cutOver: .archive(.otherAccount), owned: false, rows: 6)),
            ("S10", inputs(.allowed, cutOver: .retired, record: .completed, rows: 9))
        ]
        for (name, open) in syncedRows {
            let before = resolve(open)
            check(before.source == .synced(readOnly: false), "\(name) is a writable synced row before the fence")
            var fenced = open
            fenced.cloudReadOnly = .consentFenced
            let after = resolve(fenced)
            check(after == present(.synced(readOnly: true), .fenced, before.olderEntry, .wait), "S11 over \(name): read-only, the fence line, the Masʼul waits, the entry as the row's (\(after))")
        }
        for open in [inputs(.legacy, rows: 3), inputs(.forbidden, rows: 3, cachedRows: true), inputs(.waiting, rows: 3), inputs(.allowed, rows: 3)] {
            var fenced = open
            fenced.cloudReadOnly = .consentFenced
            check(resolve(fenced) == resolve(open), "the fence changes nothing on a device board (\(open.permission)): it is not the cloud store")
        }
        for reason in [TasksCloudReadOnlyReason.consentOff, .withdrawn] {
            var stale = inputs(.allowed, cutOver: .retired, record: .completed, rows: 9)
            stale.cloudReadOnly = reason
            check(resolve(stale) == present(.synced(readOnly: true), .none, nil, .wait), "a stale \(reason) hold on a synced row fails closed: read-only, the Masʼul waits, the row's own line")
        }
    }

    // MARK: - Rules

    static func firstMatchingRowWins() {
        check(resolve(inputs(.forbidden, record: .skipped, reason: .existingMappings, rows: 4, importable: 4, readOnly: .consentFenced)) == present(.device(writable: true), .syncOff(tappable: true), nil, .needsConsent), "S2 beats every synced fact")
        check(resolve(inputs(.waiting, record: .skipped, reason: .existingMappings, rows: 4, importable: 4)) == present(.device(writable: true), .waitingLink, nil, .needsLink), "S3 (waiting, no copy) beats S6b")
        check(resolve(inputs(.allowed, record: nil, rows: 4, importable: 3)) == present(.device(writable: true), .turningOn, nil, .wait), "S5 (a record that still moves) beats S6b's count")
        check(resolve(inputs(.allowed, record: .skipped, reason: .scopeChanged, rows: 4, importable: nil, complete: false)) == present(.synced(readOnly: false), .none, .older(.checking), .available), "S6b is checked before S6 (the snapshot incomplete)")
        check(resolve(inputs(.allowed, record: .skipped, reason: .scopeChanged, owned: false, rows: 4, importable: 3)).olderEntry == .older(.otherAccount), "S6b's marker rule hands the row to S6")
        var fenced = inputs(.allowed, record: .skipped, reason: .existingMappings, rows: 4, importable: 3)
        fenced.cloudReadOnly = .consentFenced
        check(resolve(fenced) == present(.synced(readOnly: true), .fenced, .older(.newRows(3)), .wait), "S11 is applied last, over S6b")
        let presentation = resolve(inputs(.allowed, cutOver: .archive(.newRows(2)), record: .completed, rows: 5, archive: TasksBoardArchive(cutOver: .archive(.newRows(2)), done: 3, total: 3, keptLocal: 1, recordState: .completed)))
        check(presentation.line == .newRows(2, keptLocal: 1), "exactly one line, the kept-local count inside it")
    }

    /// §3.3: whenever the device DB holds rows the current board does not show, they are reachable
    /// read-only in one tap (a tappable line) or from Roʻyxatlar. Over a grid of inputs (consistent
    /// ones and inconsistent ones alike): every synced presentation with device rows has an entry or
    /// a tappable line, except where every device row is in the synced board (`retired`, S6b with
    /// nothing left); a device board never offers "Eski vazifalar" (it shows the rows itself) and
    /// never lets a Masʼul be assigned (D1); the fence always reads the same.
    static func noDeviceRowIsEverStranded() {
        let permissions: [SGTasksSyncPermission] = [.legacy, .forbidden, .waiting, .allowed]
        let cutOvers: [TasksCutOver] = [.none, .archive(.migrating), .archive(.newRows(2)), .archive(.otherAccount), .retired]
        var visited = 0
        for permission in permissions {
            for cutOver in cutOvers {
                for (record, reason) in everyRecord {
                    for owned in [true, false] {
                        for rows in [0, 1, 4] {
                            for importable in [nil, 0, 2] as [Int?] {
                                for kept in [0, 1] {
                                    for readOnly in [nil, .consentFenced] as [TasksCloudReadOnlyReason?] {
                                        for copyOnDevice in [true, false] {
                                            let archive = TasksBoardArchive(cutOver: cutOver, done: 1, total: 3, keptLocal: kept, recordState: record, copyOnDevice: copyOnDevice)
                                            let input = inputs(permission, cutOver: cutOver, record: record, reason: reason, owned: owned, rows: rows, importable: importable, needsCorrection: kept, archive: archive, complete: importable != nil, readOnly: readOnly, cachedRows: rows > 0, consentEntry: owned, dismissed: kept == 1)
                                            let presentation = resolve(input)
                                            visited += 1
                                            let label = "\(permission) \(cutOver) \(String(describing: record)) owned=\(owned) rows=\(rows) importable=\(String(describing: importable)) kept=\(kept) fence=\(readOnly != nil) copyOnDevice=\(copyOnDevice) → \(presentation)"
                                            switch presentation.source {
                                            case .device:
                                                if case .older? = presentation.olderEntry {
                                                    check(false, "a device board shows its rows itself: \(label)")
                                                }
                                                check(presentation.assign != .available, "D1: no assignment without sync: \(label)")
                                                check(presentation.line != .fenced && presentation.line != .otherAccountNotice && !presentation.line.opensOlderTasks, "a device board has none of the synced lines: \(label)")
                                            case let .synced(isReadOnly):
                                                check(isReadOnly == (readOnly != nil), "read-only exactly under the hold: \(label)")
                                                if readOnly != nil {
                                                    check(presentation.line == .fenced && presentation.assign == .wait, "S11 reads the same on every row: \(label)")
                                                } else {
                                                    check(presentation.line != .fenced && presentation.line != .syncOff(tappable: true) && presentation.line != .syncOff(tappable: false), "no fence line without the hold, no sync-off line on a synced board: \(label)")
                                                }
                                                check(presentation.olderEntry != .syncedCopy, "Sinxronlangan nusxa is for sync off only: \(label)")
                                                if rows > 0 {
                                                    let nothingLeft = cutOver == .none && record == .skipped && (reason == .existingMappings || reason == .scopeChanged) && owned && importable == 0 && kept == 0
                                                    let everyRowSynced = cutOver == .retired || nothingLeft
                                                    let reachable = presentation.olderEntry != nil || presentation.line.opensOlderTasks
                                                    check(reachable || everyRowSynced, "stranded device rows: \(label)")
                                                    if everyRowSynced {
                                                        check(presentation.olderEntry == nil, "no entry when every device row is in the synced board: \(label)")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        check(visited == 4 * 5 * 8 * 2 * 3 * 3 * 2 * 2 * 2, "the whole grid was visited (\(visited))")
    }

    static func scopeKeysAreRemovedOnce() {
        let suite = "sgtasks.boardsource.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("cloud", forKey: "sgtasks.scope.1")
        defaults.set("device", forKey: "sgtasks.scope.v2.1")
        defaults.set("device", forKey: "sgtasks.scope.77")
        defaults.set(true, forKey: "sgtasks.assignExplainer.1")
        defaults.set("kept", forKey: "sgtasks.scopeless")
        defaults.set(1, forKey: "other.key")
        check(!defaults.bool(forKey: TasksBoardSource.scopeKeysRemovedKey), "no marker before the first launch")
        check(TasksBoardSource.removeLegacyScopeKeys(defaults: defaults) == 3, "the three scope keys go")
        check(defaults.object(forKey: "sgtasks.scope.1") == nil && defaults.object(forKey: "sgtasks.scope.v2.1") == nil && defaults.object(forKey: "sgtasks.scope.77") == nil, "both key shapes, every account")
        check(defaults.bool(forKey: "sgtasks.assignExplainer.1") && defaults.string(forKey: "sgtasks.scopeless") == "kept" && defaults.integer(forKey: "other.key") == 1, "nothing else is touched (the prefix ends with the dot)")
        check(defaults.bool(forKey: TasksBoardSource.scopeKeysRemovedKey), "the marker is set")
        check(!TasksBoardSource.scopeKeysRemovedKey.hasPrefix(TasksBoardSource.legacyScopeKeyPrefix), "the marker is never one of the keys it guards")
        defaults.set("cloud", forKey: "sgtasks.scope.9")
        check(TasksBoardSource.removeLegacyScopeKeys(defaults: defaults) == 0 && defaults.string(forKey: "sgtasks.scope.9") == "cloud", "one-shot: a later call removes nothing")
        check(defaults.bool(forKey: TasksBoardSource.scopeKeysRemovedKey), "the marker stays")
        // The last logout's marker sweep (WP-I6) removes the marker: the next launch cleans once more.
        defaults.removeObject(forKey: TasksBoardSource.scopeKeysRemovedKey)
        check(TasksBoardSource.removeLegacyScopeKeys(defaults: defaults) == 1 && defaults.object(forKey: "sgtasks.scope.9") == nil && defaults.bool(forKey: TasksBoardSource.scopeKeysRemovedKey), "after the sweep the cleanup runs again")
        let freshSuite = "sgtasks.boardsource.tests.\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: freshSuite)!
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        check(TasksBoardSource.removeLegacyScopeKeys(defaults: fresh) == 0 && fresh.bool(forKey: TasksBoardSource.scopeKeysRemovedKey), "a fresh install has nothing to remove and still records the run")
    }
}
