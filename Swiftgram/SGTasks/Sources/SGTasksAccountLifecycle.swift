import Foundation

// MARK: - Zenlygram Tasks R4: what the customer layer calls on withdrawal and erasure (design 30 §5.5)
//
// The customer layer (design 40) decides that an account's data consent was withdrawn or that the
// account was erased; Tasks then retires the account's cloud state and its claim on the device rows.
// A Telegram logout keeps using `purgeAccount` (the migration record and the mappings survive it, so a
// re-login resumes). A re-grant needs no call: the sync coordinator observes the gate and resumes.

extension SGTasksCloudRepository {
    /// Posted (main queue) when an account's claim on the device rows changed outside a migration
    /// step; `userInfo["accountPeerId"]`: Int64. The sync coordinator recomputes the cut-overs (the
    /// other accounts' `ownerActive` follows the owner's record).
    public static let migrationDidChangeNotification = Notification.Name("SGTasksCloudMigrationDidChange")

    /// Consent withdrawn. Synchronous, in this order:
    /// 1. the discard — every unsent outbox row goes and `consent_epoch` is bumped, so a migration
    ///    step in flight can no longer enqueue; the cloud cache stays as a read-only archive, no
    ///    Tasks request is made any more. With the account's repository open in this process it
    ///    goes through it (`discardAfterConsentWithdrawal()`, on the repository queue: board,
    ///    driver and realtime follow). With none open (the usual case for the launch re-run of a
    ///    withdrawal, design 40 §6.6) the same transaction runs on the bare store and the WAL is
    ///    folded (`discardWithoutRepository`), so the launch neither builds the repository nor
    ///    decodes its outbox and board on main; if the bare store does not open, the call falls
    ///    back to the repository;
    /// 2. `releaseCloudDevice(.withdrawn)` — the account's import mappings are voided (its cloud
    ///    copies are being erased, so they no longer guard against duplicates), its owner marker is
    ///    freed when nothing was enqueued yet (else released: only this account may claim it
    ///    again), its record becomes `released(withdrawn)`.
    /// The local board is writable again at once (cut-over row 1). Returns the discarded USER
    /// changes; nil when the cloud store is unavailable (the release still happens).
    @discardableResult
    public static func retireForConsentWithdrawal(accountPeerId: Int64) -> Int? {
        let discarded = Self.discardWithoutRepository(accountPeerId: accountPeerId) ?? Self.repository(accountPeerId: accountPeerId).discardAfterConsentWithdrawal()
        do {
            try Self.environment.legacy().releaseCloudDevice(accountPeerId: accountPeerId, reason: .withdrawn, now: Self.environment.now())
        } catch {
            print("[SGTasksCloud] device release after withdrawal not recorded")
        }
        Self.postMigrationChange(accountPeerId: accountPeerId)
        return discarded
    }

    /// Account erased (in-app deletion): the account's cloud store goes (`purgeAccount`: cache,
    /// outbox, cursors), its owner marker is freed or released as on withdrawal, and its migration
    /// record and every import mapping are deleted. A later consent of a new server account starts
    /// over.
    public static func purgeAfterAccountErasure(accountPeerId: Int64) {
        Self.purgeAccount(accountPeerId: accountPeerId)
        do {
            try Self.environment.legacy().releaseCloudDevice(accountPeerId: accountPeerId, reason: .erased, now: Self.environment.now())
        } catch {
            print("[SGTasksCloud] device release after erasure not recorded")
        }
        Self.postMigrationChange(accountPeerId: accountPeerId)
    }

    private static func postMigrationChange(accountPeerId: Int64) {
        let center = Self.environment.notificationCenter
        DispatchQueue.main.async {
            center.post(name: Self.migrationDidChangeNotification, object: nil, userInfo: ["accountPeerId": accountPeerId])
        }
    }
}
