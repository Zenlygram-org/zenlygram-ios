import Foundation

// MARK: Zenlygram — TEST-ONLY. The status preview's scenario names and fixed clock, Foundation only.
//
// Compiled into BOTH the preview host (`SGPayWallStatusPreviewLib`, where
// `SGPayWallStatusPreviewScenarios.swift` gives each case its synthetic inputs) and the UI test
// bundle (`SGPayWallStatusPreviewUITestsLib`), which launches the host with `-scenario <rawValue>`.
// One list, so a scenario cannot exist in one and be missing from the other.

public enum SGPayWallStatusPreviewScenario: String, CaseIterable {
    case notSubscribed
    case localGrace
    case tokenAccess
    case appStoreRenews
    case appStoreEnds
    case appStoreBillingRetry
    case viaAppStoreSnapshot
    case unconfiguredBuild
    case lapsed
    case reconnect
    case otherAccount
    case restoreRunning
    case restoreRestored
    case restoreNothing
    case restoreInProgressElsewhere
    case restoreFailed
    // Free-first: the signed monetization policy is free.
    /// Nothing genuine on the account, and a local grace window that would still be counting down.
    case freeAccess
    /// Free, with a genuine account horizon and an App Store subscription Apple says renews.
    case freeAppStoreRenews
    /// Free, with an App Store subscription Apple says will NOT renew: no renewal claim.
    case freeAppStoreEnds
    /// Free, and the Restore this screen ran found nothing: its result must still be readable.
    case freeRestoreNothing

    /// A fixed clock, so every date renders the same on every run.
    public static let referenceNow = Date(timeIntervalSince1970: 1_790_000_000)
}
