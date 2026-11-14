import Foundation

/// Zenlygram — the manual Link screen's hooks into the customer-data layer (design 40 §8.2,
/// compliance C-13, contract amendment A3). Feature modules call these; SGCustomerSync installs the
/// one handler (`install(handler:)`), which turns each call into a coordinator event
/// (`SGCustomerCoordinatorCore.Event(_:)`). Until a handler is installed — a build without the
/// pipeline, an extension, before `SGCustomerSync.start` — every call does nothing, and nothing
/// links automatically either.
///
/// Calls reach the handler synchronously on the caller's thread (the main thread): `userWillUnlink`
/// returns only after the suppression is persisted, so the caller can go on to
/// `SGEntitlement.shared.logout(accountPeerId:)` without auto-link re-linking the account behind it.
public enum SGCustomerLinkEvents {
    public enum Event: Equatable {
        /// The user chose Unlink (before the logout): no automatic link for the account until a
        /// manual link or a new grant (`suppressed: "user_unlink"`). Its reduction starts no
        /// consents, sync or events upload for the account, because the logout that follows removes
        /// its session: that logout's final send carries the newest pending withdrawals ahead of
        /// `/bind/revoke`, and queued events stay queued for the next link.
        case userWillUnlink(accountPeerId: Int64)
        /// The Link screen reached `.linked` (a manual link): the Unlink suppression is lifted.
        case userDidLink(accountPeerId: Int64)
        /// A manual `/bind/start` answered 409 `consent_stale` (SGEntitlement then retried without
        /// consent): the grant it carried predates an erasure of this Telegram id, so it is asked
        /// again — `SGConsentStore.normaliseAfterConsentStale(tg:consentId:)`, exactly what the
        /// automatic path's `.consentStale` does. `consentId` = the grant the start carried (nil:
        /// the current grant).
        case bindConsentStale(accountPeerId: Int64, consentId: String?)
    }

    private static let lock = NSLock()
    private static var installedHandler: ((Event) -> Void)?

    /// SGCustomerSync only, once at start; nil removes it.
    public static func install(handler: ((Event) -> Void)?) {
        SGCustomerLinkEvents.lock.lock()
        SGCustomerLinkEvents.installedHandler = handler
        SGCustomerLinkEvents.lock.unlock()
    }

    /// `SGLinkAccountModel.unlink()`, before `SGEntitlement.shared.logout(accountPeerId:)`.
    public static func userWillUnlink(accountPeerId: Int64) {
        SGCustomerLinkEvents.deliver(.userWillUnlink(accountPeerId: accountPeerId))
    }

    /// The Link screen's `.linked` phase.
    public static func userDidLink(accountPeerId: Int64) {
        SGCustomerLinkEvents.deliver(.userDidLink(accountPeerId: accountPeerId))
    }

    /// A manual bind's 409 `consent_stale`, with the `consent_id` of the grant the start carried.
    public static func bindConsentStale(accountPeerId: Int64, consentId: String?) {
        SGCustomerLinkEvents.deliver(.bindConsentStale(accountPeerId: accountPeerId, consentId: consentId))
    }

    private static func deliver(_ event: Event) {
        SGCustomerLinkEvents.lock.lock()
        let handler = SGCustomerLinkEvents.installedHandler
        SGCustomerLinkEvents.lock.unlock()
        handler?(event)
    }
}
