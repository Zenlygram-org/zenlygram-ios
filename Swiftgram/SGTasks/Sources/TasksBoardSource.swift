import Foundation

// Zenlygram — Tasks: the one board (wf15 §3). The Tasks screen shows exactly one board — the device
// database while sync is off or not usable yet, the account's synced board otherwise — with at most
// one status line under it, one "Eski vazifalar" / "Sinxronlangan nusxa" entry in Roʻyxatlar whenever
// rows exist that the board does not show, and one answer to "can a Masʼul be assigned here?". A pure
// resolver decides all four from plain facts (`TasksBoardSourceResolver.resolve`: the state table
// S1–S11, evaluated top-down, the first matching row wins, S6b before S6; S11 then overrides the line
// and the Masʼul of whatever row matched). Foundation only — plus the pure cut-over table, the
// permission, the migration record and the cloud read-only reason, all value types — so
// `Tests/run-cloud-model-tests.sh` checks every row on the host; the tab controller gathers the
// inputs and renders the result, nothing here reads a database, a store or the network.
//
// Also here: the device archive's banner model for a cut-over (`TasksBoardArchive(cutOver:...)`,
// moved unchanged from TasksScope.swift — the resolver reads it for S4/S7/S8 and the read-only
// "Eski vazifalar" screen still renders it) and the one-shot cleanup of the retired per-account scope
// keys (`sgtasks.scope.<id>`, `sgtasks.scope.v2.<id>`): nothing reads a remembered scope any more.

/// What the resolver reads: one plain fact per field, every one of them already known to the tab
/// controller. Nothing is derived here from a database or a store.
public struct TasksBoardSourceInputs: Equatable {
    /// `SGTasksSyncPolicy.permission`: `legacy` | `forbidden` | `waiting` | `allowed`.
    public var permission: SGTasksSyncPermission
    /// `SGTasksCutOver.evaluate` (the unchanged table).
    public var cutOver: TasksCutOver
    /// This account's `cloud_migration` record: its state and, for `skipped`, why
    /// (`existing_mappings` | `device_owned_by_other` | `scope_changed`).
    public var recordState: TodoCloudMigrationRecord.State?
    public var recordReason: TodoCloudMigrationRecord.Reason?
    /// `cloud_device_owner` is nil, or held by THIS account in any state (claimed / completed /
    /// released by this account). A marker another account holds OR released is NOT free:
    /// `claimCloudDevice` answers `.ownedByOther` / `.releasedByOther` for it.
    public var deviceOwnedByThisOrFree: Bool
    /// Live device tasks (the device-wide database).
    public var deviceLiveRows: Int
    /// S6b only: the rows the explicit copy would enqueue — the items of
    /// `repository.prepareLegacyImport(locale:)` whose status `isEnqueuedByConsent`, when its
    /// availability is `.canCopy` (the preview reads the mappings of the CURRENT import scope); nil
    /// until the snapshot is complete and the count is known; 0 = nothing left to copy.
    public var importableDeviceRows: Int?
    /// S6b: the preview's items in `needsCorrection` (shown as `keptLocal`).
    public var importNeedsCorrection: Int
    /// `TasksBoardArchive(cutOver:done:total:keptLocal:recordState:copyOnDevice:)` for the cut-over;
    /// nil while the board is writable, or before the controller computed it.
    public var archive: TasksBoardArchive?
    /// The account's cloud store holds a complete snapshot. The table reads `importableDeviceRows`
    /// (nil until then); the flag is carried for the host that renders the loading banner.
    public var snapshotComplete: Bool
    /// `tasksCloudReadOnlyReason(state, isConsentWithdrawn:)`: the consent hold of the cloud store.
    public var cloudReadOnly: TasksCloudReadOnlyReason?
    /// `forbidden` && the account store still holds owner-role tasks (the Sinxronlangan nusxa, F12).
    public var hasOwnCachedSyncedRows: Bool
    /// The consent entry hook is installed and the pipeline active: the sync-off line is tappable.
    public var consentEntryAvailable: Bool
    /// The one-time S9 notice was dismissed for this account.
    public var otherAccountNoticeDismissed: Bool

    public init(
        permission: SGTasksSyncPermission,
        cutOver: TasksCutOver,
        recordState: TodoCloudMigrationRecord.State? = nil,
        recordReason: TodoCloudMigrationRecord.Reason? = nil,
        deviceOwnedByThisOrFree: Bool,
        deviceLiveRows: Int,
        importableDeviceRows: Int? = nil,
        importNeedsCorrection: Int = 0,
        archive: TasksBoardArchive? = nil,
        snapshotComplete: Bool,
        cloudReadOnly: TasksCloudReadOnlyReason? = nil,
        hasOwnCachedSyncedRows: Bool = false,
        consentEntryAvailable: Bool = false,
        otherAccountNoticeDismissed: Bool = false
    ) {
        self.permission = permission
        self.cutOver = cutOver
        self.recordState = recordState
        self.recordReason = recordReason
        self.deviceOwnedByThisOrFree = deviceOwnedByThisOrFree
        self.deviceLiveRows = deviceLiveRows
        self.importableDeviceRows = importableDeviceRows
        self.importNeedsCorrection = importNeedsCorrection
        self.archive = archive
        self.snapshotComplete = snapshotComplete
        self.cloudReadOnly = cloudReadOnly
        self.hasOwnCachedSyncedRows = hasOwnCachedSyncedRows
        self.consentEntryAvailable = consentEntryAvailable
        self.otherAccountNoticeDismissed = otherAccountNoticeDismissed
    }
}

/// Which store the one board shows.
public enum TasksBoardSource: Equatable {
    /// The device database. `writable` is false only for the read-only "Eski vazifalar" view the host
    /// pushes; every device row of the table (S1, S2, S3, S5) is writable (the write fence of a
    /// running migration step still answers its toast).
    case device(writable: Bool)
    /// The account's synced board. `readOnly` while the cloud store holds a consent hold (S11).
    case synced(readOnly: Bool)
}

/// The at-most-one status line under the board (§3.2). The tab controller renders it; the host
/// node shows the repository's banners separately.
public enum TasksSyncLine: Equatable {
    case none
    /// S2: the ONE footer line "Sinxronlash oʻchiq"; tappable → Data & consent when the hook is there.
    case syncOff(tappable: Bool)
    /// S3/S4: "Akkaunt bogʻlangach sinxronlash boshlanadi" + action Bogʻlash.
    case waitingLink
    /// S5, and S7 with nothing counted yet: "Sinxronlash yoqilmoqda…".
    case turningOn
    /// S7 with a queued copy on this device: "Eski vazifalar sinxronlanmoqda: done / total";
    /// tappable → Eski vazifalar. `keptLocal` > 0 adds the second line.
    case progress(done: Int, total: Int, keptLocal: Int)
    /// S7 after a logout/re-login (`awaitsCloudCopy`): the loading text; tappable → Eski vazifalar.
    case loading(keptLocal: Int)
    /// S8 and S6b: "{n} ta eski vazifa hali sinxronlanmagan" + action Sinxronlash (the explicit,
    /// CREATE-gated import); the line itself is tappable → Eski vazifalar.
    case newRows(Int, keptLocal: Int)
    /// S9: the one-time dismissible notice + Koʻrish.
    case otherAccountNotice
    /// S11: the synced board is read-only while the server's consent fence holds.
    case fenced

    /// The lines that are tappable → "Eski vazifalar" (§3.3: the device rows are one tap away).
    public var opensOlderTasks: Bool {
        switch self {
        case .progress, .loading, .newRows:
            return true
        case .none, .syncOff, .waitingLink, .turningOn, .otherAccountNotice, .fenced:
            return false
        }
    }
}

/// Why the "Eski vazifalar" screen is offered (its footer, `tasks_older_footer_*`).
public enum TasksOlderReason: Equatable {
    /// The copy is being synced (S4/S7 with the copy on this device).
    case migrating
    /// The copy is synced and returns with the snapshot (after a logout/re-login, `awaitsCloudCopy`).
    case awaiting
    /// This many device rows are not synced yet (S8, S6b).
    case newRows(Int)
    /// S6b before the explicit copy's count is known (revision 2); also the transient synced board of
    /// a copy made under another server account, until the step records `skipped(scope_changed)`.
    case checking
    /// The device rows belong to another account signed in (or once signed in) on this device.
    case otherAccount
}

/// The Roʻyxatlar entry that keeps every row reachable (§3.3 "no row is ever stranded").
public enum TasksOlderEntry: Equatable {
    /// "Eski vazifalar": the device rows, read-only.
    case older(TasksOlderReason)
    /// "Sinxronlangan nusxa": the account's own cached synced rows after sync went off (F12).
    case syncedCopy
}

/// Whether a Masʼul can be assigned from this board (§4.4: the pill and the editor row stay visible).
public enum TasksAssignAvailability: Equatable {
    /// The synced board: picking a contact sends the task (`assignTask`).
    case available
    /// S2: the needs-sync sheet with "Sinxronlashni yoqish" (D1: assigning needs consent and a link).
    case needsConsent
    /// S3/S4: the needs-sync sheet with the link action; nothing new is queued before the link.
    case needsLink
    /// S5 and S11: the toast "wait for sync"; nothing is queued.
    case wait
    /// S1: today's local assignee of the R3 build, unchanged.
    case legacyLocal
}

/// One row of the table: what the tab controller shows.
public struct TasksBoardPresentation: Equatable {
    public var source: TasksBoardSource
    public var line: TasksSyncLine
    public var olderEntry: TasksOlderEntry?
    public var assign: TasksAssignAvailability

    public init(source: TasksBoardSource, line: TasksSyncLine, olderEntry: TasksOlderEntry?, assign: TasksAssignAvailability) {
        self.source = source
        self.line = line
        self.olderEntry = olderEntry
        self.assign = assign
    }
}

/// The §3.2 table. Pure: the same inputs always give the same row.
public enum TasksBoardSourceResolver {
    public static func resolve(_ inputs: TasksBoardSourceInputs) -> TasksBoardPresentation {
        var presentation = Self.firstMatchingRow(inputs)
        // S11: the server's consent fence (403 `tasks_consent_required`) makes ANY synced row
        // read-only — nothing is queued, so no assignment either — and the line says why. The two
        // other read-only reasons (consent off / withdrawn) belong to `forbidden`, i.e. S2 and the
        // device board, and never meet a synced row; should a stale refinement still carry one, the
        // board stays read-only and the Masʼul waits (fail closed) under the row's own line — the
        // cloud board's banner names that reason itself.
        if case .synced = presentation.source, let reason = inputs.cloudReadOnly {
            presentation.source = .synced(readOnly: true)
            if reason == .consentFenced {
                presentation.line = .fenced
            }
            presentation.assign = .wait
        }
        return presentation
    }

    private static func firstMatchingRow(_ inputs: TasksBoardSourceInputs) -> TasksBoardPresentation {
        switch inputs.permission {
        case .legacy:
            // S1: a build without a Tasks backend — today's device board, today's local assignee.
            return TasksBoardPresentation(source: .device(writable: true), line: .none, olderEntry: nil, assign: .legacyLocal)
        case .forbidden:
            // S2: no consent (declined in optional mode, withdrawn, a failed activation, a stale
            // grant, the link ended, the pipeline inactive): the device board, writable (cut-over
            // row 1 forces `none`), the one footer line; the account's own cached synced rows stay
            // reachable read-only (F12).
            return TasksBoardPresentation(
                source: .device(writable: true),
                line: .syncOff(tappable: inputs.consentEntryAvailable),
                olderEntry: inputs.hasOwnCachedSyncedRows ? .syncedCopy : nil,
                assign: .needsConsent
            )
        case .waiting:
            if case .none = inputs.cutOver {
                // S3: consent given, the link pending, nothing copied: the device board.
                return TasksBoardPresentation(source: .device(writable: true), line: .waitingLink, olderEntry: nil, assign: .needsLink)
            }
            // S4: the copy exists (archive / retired) while the link is pending: the synced board,
            // writable — changes queue until the link (`tasksCloudReadOnlyReason` is nil for
            // `.consentRequired(waiting: true)`); the device rows one tap away unless every one of
            // them is in the synced board (`retired`); no new assignment before the link (D1).
            let entry = inputs.deviceLiveRows > 0 ? Self.olderReason(inputs).map(TasksOlderEntry.older) : nil
            return TasksBoardPresentation(source: .synced(readOnly: false), line: .waitingLink, olderEntry: entry, assign: .needsLink)
        case .allowed:
            switch inputs.cutOver {
            case .none:
                return Self.allowedBeforeTheCopy(inputs)
            case .archive(.migrating):
                // S7: the copy is queued (progress, tappable), or it is confirmed but not in this
                // account's store on this device yet (after a logout/re-login: loading until the
                // snapshot is back), or nothing is counted yet (turning on).
                let keptLocal = inputs.archive?.keptLocal ?? 0
                let line: TasksSyncLine
                if inputs.archive?.awaitsCloudCopy == true {
                    line = .loading(keptLocal: keptLocal)
                } else if let archive = inputs.archive, case let .migrating(done, total) = archive.reason, total > 0 {
                    line = .progress(done: done, total: total, keptLocal: keptLocal)
                } else {
                    line = .turningOn
                }
                return TasksBoardPresentation(source: .synced(readOnly: false), line: line, olderEntry: Self.olderReason(inputs).map(TasksOlderEntry.older), assign: .available)
            case let .archive(.newRows(count)):
                // S8: newer device rows (incl. the kept-local ones) are not synced; the line offers
                // the explicit, CREATE-gated import and is tappable to the rows.
                return TasksBoardPresentation(
                    source: .synced(readOnly: false),
                    line: .newRows(count, keptLocal: inputs.archive?.keptLocal ?? 0),
                    olderEntry: Self.olderReason(inputs).map(TasksOlderEntry.older),
                    assign: .available
                )
            case .archive(.otherAccount):
                // S9: another account's copy of the device rows: this account's own synced board,
                // the one-time notice until dismissed, the rows reachable from Roʻyxatlar.
                return TasksBoardPresentation(
                    source: .synced(readOnly: false),
                    line: inputs.otherAccountNoticeDismissed ? .none : .otherAccountNotice,
                    olderEntry: Self.olderReason(inputs).map(TasksOlderEntry.older),
                    assign: .available
                )
            case .retired:
                // S10: every device row is in the synced board.
                return TasksBoardPresentation(source: .synced(readOnly: false), line: .none, olderEntry: nil, assign: .available)
            }
        }
    }

    /// `allowed` with cut-over `none`: S5, then S6b, then S6.
    private static func allowedBeforeTheCopy(_ inputs: TasksBoardSourceInputs) -> TasksBoardPresentation {
        let ownDeviceRows = inputs.deviceLiveRows > 0 && inputs.deviceOwnedByThisOrFree
        if ownDeviceRows && Self.recordStillMovesByItself(inputs.recordState) {
            // S5: the automatic step still moves this record (nil and released are claimed at once
            // by `shouldClaimDevice`; claimed waits for the link and the complete snapshot, then
            // `runStep` copies): the device board, writable, "turning on"; a Masʼul waits.
            return TasksBoardPresentation(source: .device(writable: true), line: .turningOn, olderEntry: nil, assign: .wait)
        }
        if ownDeviceRows && Self.isSkippedButCopyable(inputs) {
            // S6b (revision 2): a record the engine never steps again — the account used the R3
            // explicit copy (existing_mappings) or its server account changed after the claim
            // (scope_changed). Its synced board, with the explicit CREATE-gated copy offered for
            // the rows it would still enqueue.
            let keptLocal = max(0, inputs.importNeedsCorrection)
            guard let importable = inputs.importableDeviceRows else {
                // The count is not known until the snapshot is complete: no line, the entry says so.
                return TasksBoardPresentation(source: .synced(readOnly: false), line: .none, olderEntry: .older(.checking), assign: .available)
            }
            // The rows the copy would enqueue; when none is left but rows still need a correction
            // first, those stand in — else they would be stranded (shown nowhere, the import screen
            // that lists them as "Tuzatish kerak" unreachable).
            let shown = importable > 0 ? importable : keptLocal
            guard shown > 0 else {
                // Every device row is in the synced board (as S10).
                return TasksBoardPresentation(source: .synced(readOnly: false), line: .none, olderEntry: nil, assign: .available)
            }
            return TasksBoardPresentation(source: .synced(readOnly: false), line: .newRows(shown, keptLocal: keptLocal), olderEntry: .older(.newRows(shown)), assign: .available)
        }
        // S6: the synced board — no device rows; or the device rows belong to another account that
        // is logged out here (record skipped(device_owned_by_other), or any record while the marker
        // is another account's, held or released); or, transiently (cut-over row 2), this account's
        // copy made under another server account until the step records skipped(scope_changed)
        // after the first complete snapshot (then S6b). The rows stay one tap away in every case.
        var entry: TasksOlderEntry?
        if inputs.deviceLiveRows > 0 {
            let anotherAccounts = !inputs.deviceOwnedByThisOrFree || (inputs.recordState == .skipped && inputs.recordReason == .deviceOwnedByOther)
            entry = .older(anotherAccounts ? .otherAccount : .checking)
        }
        return TasksBoardPresentation(source: .synced(readOnly: false), line: .none, olderEntry: entry, assign: .available)
    }

    /// The record states the automatic step still moves on (S5): none yet, claimed, released.
    private static func recordStillMovesByItself(_ state: TodoCloudMigrationRecord.State?) -> Bool {
        switch state {
        case nil, .claimed?, .released?:
            return true
        case .enqueued?, .completed?, .skipped?:
            return false
        }
    }

    /// S6b's records: skipped for `existing_mappings` or `scope_changed` (never `device_owned_by_other`:
    /// those rows are another account's).
    private static func isSkippedButCopyable(_ inputs: TasksBoardSourceInputs) -> Bool {
        guard inputs.recordState == .skipped else { return false }
        switch inputs.recordReason {
        case .existingMappings?, .scopeChanged?:
            return true
        case .deviceOwnedByOther?, .withdrawn?, .erased?, nil:
            return false
        }
    }

    /// The "Eski vazifalar" reason of a copy's cut-over; nil for `none` (the device board shows its
    /// rows itself) and `retired` (every row is in the synced board).
    private static func olderReason(_ inputs: TasksBoardSourceInputs) -> TasksOlderReason? {
        switch inputs.cutOver {
        case .none, .retired:
            return nil
        case .archive(.migrating):
            return inputs.archive?.awaitsCloudCopy == true ? .awaiting : .migrating
        case let .archive(.newRows(count)):
            return .newRows(count)
        case .archive(.otherAccount):
            return .otherAccount
        }
    }
}

// MARK: - The retired scope keys

public extension TasksBoardSource {
    /// The per-account keys of the retired Cloud / device switch (`sgtasks.scope.<id>` and
    /// `sgtasks.scope.v2.<id>`); nothing reads them any more (§3.3).
    static let legacyScopeKeyPrefix = "sgtasks.scope."
    /// Set once the cleanup ran. The last logout's marker sweep removes it with the other
    /// `sgtasks.*` markers, so the next launch runs the (then empty) cleanup once more.
    static let scopeKeysRemovedKey = "sgtasks.scopeKeysRemoved"

    /// One-shot launch cleanup: removes every key with the prefix and sets the marker; a later call
    /// does nothing. Returns the number of keys removed.
    @discardableResult
    static func removeLegacyScopeKeys(defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: Self.scopeKeysRemovedKey) else {
            return 0
        }
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.legacyScopeKeyPrefix) }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: Self.scopeKeysRemovedKey)
        return keys.count
    }
}

// MARK: - The device archive's banner for a cut-over

public extension TasksBoardArchive {
    /// The device board's archive for an account's cut-over; nil while the board is writable
    /// (`none`). `done` / `total` / `keptLocal` are the account's migration progress (0 when unknown);
    /// another account's copy reports none of this account's counts. Under `archive(migrating)` the
    /// progress line needs both rules:
    /// - `recordState`, the state of the account's migration record: only a queued copy (`enqueued`,
    ///   or unknown) is being copied. A `completed` one there is already in Cloud, only not confirmed
    ///   in this account's store on this device: a logout purged the store or it does not open, the
    ///   step has not yet checked the copy against it (a new or rebound store), or a 409 resync since
    ///   calls for that check again. Nothing is being copied, so no progress.
    /// - `copyOnDevice`, the cut-over's I1 for the record's copy: false while the copy is not in this
    ///   account's store on this device, where a purged outbox would read "N of N". The archive then
    ///   says that the Cloud copy returns instead (`awaitsCloudCopy`).
    /// The other reasons ignore both.
    init?(cutOver: TasksCutOver, done: Int, total: Int, keptLocal: Int, recordState: TodoCloudMigrationRecord.State? = nil, copyOnDevice: Bool = true) {
        switch cutOver {
        case .none:
            return nil
        case let .archive(reason):
            switch reason {
            case .migrating:
                let showsProgress = recordState != .completed && copyOnDevice
                let total = showsProgress ? max(0, total) : 0
                self.init(reason: .migrating(done: min(max(0, done), total), total: total), keptLocal: keptLocal, awaitsCloudCopy: !copyOnDevice)
            case let .newRows(count):
                self.init(reason: .newRows(count), keptLocal: keptLocal)
            case .otherAccount:
                self.init(reason: .otherAccount)
            }
        case .retired:
            self.init(reason: .retired, keptLocal: keptLocal)
        }
    }
}
