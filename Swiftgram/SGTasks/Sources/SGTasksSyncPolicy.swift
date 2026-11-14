import Foundation

// MARK: - Zenlygram Tasks R4: the sync coordinator's decisions (design 30 §5.1, §5.8)
//
// Pure and host-tested (`Tests/run-sync-policy-tests.sh`): no SGCustomerSyncCore, UIKit or Network.
// `SGTasksSyncCoordinator` only gathers the inputs (the customer layer's gate as plain Bools, the
// repository's flags, the migration record) and performs what these functions decide.

public enum SGTasksSyncPolicy {
    /// The customer layer's gate for one account, as plain values.
    public struct GateInputs: Equatable {
        /// `SGEntitlement.shared.isTasksConfigured`: this build has a Tasks backend at all.
        public var isTasksConfigured: Bool
        /// `SGCustomerDataGate.shared.isPipelineActive`.
        public var isPipelineActive: Bool
        /// The account's clearance contains `.tasksSync`.
        public var tasksSync: Bool
        /// The account's clearance contains `.recordEvents`.
        public var recordEvents: Bool

        public init(isTasksConfigured: Bool, isPipelineActive: Bool, tasksSync: Bool, recordEvents: Bool) {
            self.isTasksConfigured = isTasksConfigured
            self.isPipelineActive = isPipelineActive
            self.tasksSync = tasksSync
            self.recordEvents = recordEvents
        }
    }

    /// Fail closed: `legacy` only for a build without a Tasks backend (every Tasks call answers
    /// `notConfigured` without a request, so R3 behaviour is inert); a configured build without the
    /// customer pipeline (not produced today, mapped defensively) is `forbidden`; then `tasksSync`
    /// → `allowed`, `recordEvents` → `waiting`, anything else (a failed activation publishes `[]`)
    /// → `forbidden`.
    public static func permission(_ inputs: GateInputs) -> SGTasksSyncPermission {
        guard inputs.isTasksConfigured else { return .legacy }
        guard inputs.isPipelineActive else { return .forbidden }
        if inputs.tasksSync {
            return .allowed
        }
        if inputs.recordEvents {
            return .waiting
        }
        return .forbidden
    }

    public enum DriveAction: Equatable {
        /// `startDriving()` + `requestDrive(reason)`.
        case drive
        /// `stopDriving()`.
        case stop
        case none
    }

    /// Per account, per input change: only `allowed` is driven; a driven repository whose
    /// permission dropped stops (`legacy` is exactly R3: never driven).
    public static func driveAction(_ permission: SGTasksSyncPermission, isDriven: Bool) -> DriveAction {
        if permission == .allowed {
            return .drive
        }
        return isDriven ? .stop : .none
    }

    /// The gate is back (`allowed`) for a repository whose consent was withdrawn locally:
    /// `resumeAfterConsentRegrant()` (the next migration step re-claims a released record).
    public static func needsRegrantResume(_ permission: SGTasksSyncPermission, consentWithdrawnFlag: Bool) -> Bool {
        return permission == .allowed && consentWithdrawnFlag
    }

    /// The consent-time claim of the device rows (local, no network): with consent (`waiting` or
    /// `allowed`) and no record yet, or the account's own `released` one (after a withdrawal).
    public static func shouldClaimDevice(_ permission: SGTasksSyncPermission, record: TodoCloudMigrationRecord?) -> Bool {
        guard permission == .waiting || permission == .allowed else { return false }
        guard let record = record else { return true }
        return record.state == .released
    }

    /// wf15 §5.3 (review E-12): the one-time read of the account's Telegram blocked list has reached
    /// its end, asked after every settled page (never while a load is in flight). `canLoadMore ==
    /// false` is the plain end. A list the server answers in slices (more than one page) never
    /// reports that — every slice says "more" — so the read also ends when the total count is
    /// reached, or when the page asked for last added no peer (`peerCountAtLastRequest` is the peer
    /// count when that page was requested; nil before the first request). Without this the read
    /// would ask for the next page for as long as the account is `allowed` and never count as loaded.
    public static func blockedListReadEnded(canLoadMore: Bool, peerCount: Int, totalCount: Int?, peerCountAtLastRequest: Int?) -> Bool {
        guard canLoadMore else { return true }
        if let totalCount = totalCount, peerCount >= totalCount { return true }
        if let asked = peerCountAtLastRequest, peerCount <= asked { return true }
        return false
    }

    /// The fence of an account's checked local writes: `migrating` for EVERY account while a step's
    /// local part runs (the device database is shared), else `archived` while the account's cut-over
    /// makes the board read-only, else `open`.
    public static func writeFence(migrationStepRunning: Bool, cutOver: TasksCutOver) -> TodoWriteFence {
        if migrationStepRunning {
            return .migrating
        }
        return cutOver.isReadOnly ? .archived : .open
    }
}
