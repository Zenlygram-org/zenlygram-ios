import Foundation

// MARK: - Zenlygram Tasks R4: what the cut-over reads (design 30 §7.5)
//
// One account's cut-over inputs as the sync coordinator reads them: its migration record and the
// live rows not mapped in the record's scope (U) from the device database, and I1 from its cloud
// store; and the Device archive's progress with that same I1 (`SGTasksMigration.archiveProgress`,
// which the Tasks board reads). Apart from SGTasksCutOver.swift, which stays pure for the host
// scripts that build it without the repository. The coordinator (SGTasksSyncCoordinator.swift) and
// the board (TasksTabController.swift), never compiled on the host, call these, and so do the
// logout-resume cases of run-cloud-tests.sh (SGTasksMigrationTests.swift), against the real store
// and purge.

extension TasksCutOver.Inputs {
    /// One signed-in account's inputs. P, S and `ownerActive` are the coordinator's (the gate, the
    /// binding, the owner marker across the signed-in accounts); the rest is read here. U is counted
    /// only for a completed copy, in the record's scope (else the binding's). `repository` opens the
    /// account's repository and runs only for I1 of an account with consent and a copy. A value the
    /// device database cannot read counts as none (no record, no new rows).
    static func read(accountPeerId: Int64, permission: SGTasksSyncPermission, currentScope: String?, ownerActive: Bool, database: TodoDatabase, repository: () -> SGTasksCloudRepository) -> TasksCutOver.Inputs {
        let record = try? database.cloudMigrationRecord(accountPeerId: accountPeerId)
        var unmapped = 0
        if record?.state == .completed, let scope = record?.principalScope ?? currentScope {
            unmapped = (try? database.unmappedLiveRowCount(accountPeerId: accountPeerId, principalScope: scope)) ?? 0
        }
        let ownCopyOnDevice = TasksCutOver.isOwnCopyOnDevice(permission: permission, record: record, readStore: {
            return repository().cutOverStoreFacts()
        })
        return TasksCutOver.Inputs(
            permission: permission,
            record: record,
            currentScope: currentScope,
            unmappedLiveRows: unmapped,
            ownerActive: ownerActive,
            ownCopyOnDevice: ownCopyOnDevice
        )
    }
}

extension SGTasksCloudRepository {
    /// What this account's cloud store on this device holds for I1, read on the repository's queue
    /// in one turn; nil when the store does not open (storage unavailable, e.g. after a purge that
    /// could not finish). A Telegram logout purges the store and keeps the record, so after a
    /// re-login the new store is unbound until its first cycle, and holds the copy again only once
    /// the snapshot of the record's server account lands (or the step re-enqueues the creates) and,
    /// for a confirmed copy, the step has checked it there (`migration_checked` and
    /// `resync_generation`, read as `migrationPreconditions` reads them). A value the store cannot
    /// read counts as none; when either of those two cannot be read, the store counts as unchecked
    /// (fail closed: a confirmed copy stays the archive).
    func cutOverStoreFacts() -> TasksCutOver.StoreFacts? {
        let originScope = self.environment.originScope
        return self.onQueue {
            guard let store = self.store else { return nil }
            let check: (migrationChecked: Bool, resyncGeneration: Int64)
            do {
                let resyncGeneration = try store.integerMeta("resync_generation") ?? 0
                check = (try store.meta(Self.migrationCheckedMeta) == "1", resyncGeneration)
            } catch {
                check = (false, 0)
            }
            return TasksCutOver.StoreFacts(
                boundScope: (try? store.meta("principal")).map { SGTasksCloudRepository.importScope(origin: originScope, principal: $0) },
                hasCompleteSnapshot: (try? store.meta("snapshot_complete")) == "1",
                pendingMigrationCreates: (try? store.unsentCounts())?.migration ?? 0,
                migrationChecked: check.migrationChecked,
                resyncGeneration: check.resyncGeneration
            )
        }
    }
}

/// What the Device archive's banner shows for the account's record under `archive(migrating)`
/// (`TasksBoardArchive(cutOver:...)`, TasksBoardSource.swift): the copy's progress, and whether the copy is
/// in the account's cloud store on this device.
struct SGTasksArchiveProgress: Equatable {
    let progress: SGTasksMigrationProgress
    /// I1 of the record's copy: the cut-over's own predicate over the facts `Inputs.read` reads.
    let copyOnDevice: Bool
}

extension SGTasksMigration {
    /// The banner's progress for `record`, with I1 read by the cut-over's own predicate
    /// (`TasksCutOver.isOwnCopyOnDevice(record:store:)` over `cutOverStoreFacts()`, never a copy of
    /// it), so the banner follows any change to that predicate. The store's facts are read first and
    /// the counts after them, so the counts are never older than the I1 they are shown with: a
    /// re-enqueue between the two reads shows its new counts. Before the step re-enqueues, a complete
    /// snapshot alone counts as a queued copy, so its line can read "N of N" for that moment.
    static func archiveProgress(_ record: TodoCloudMigrationRecord, repository: SGTasksCloudRepository) -> SGTasksArchiveProgress {
        let copyOnDevice = TasksCutOver.isOwnCopyOnDevice(record: record, store: repository.cutOverStoreFacts())
        return SGTasksArchiveProgress(progress: Self.progress(record, repository: repository), copyOnDevice: copyOnDevice)
    }
}
