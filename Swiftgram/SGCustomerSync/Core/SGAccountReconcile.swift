import Foundation

/// Zenlygram — what goes when Telegram accounts leave this device (design 40 §11.5), as pure
/// functions: the logout purge and the launch reconciliation share one rule, and the logout's final
/// withdraw send takes its bodies from here.
public enum SGAccountReconcile {
    /// At most this many withdrawals ride a logout's final send (`SGEntitlement.logout`).
    public static let finalUploadLimit = 3

    /// The Telegram ids (raw, ascending) whose customer data must go: every id that holds a consent
    /// record (`SGConsentStore.knownTelegramUserIds()`, plus the ids of accounts that just signed out)
    /// or an event queue (`SGAnalyticsQueueStore.queueOwners()`) and is not signed in. For each:
    /// `SGConsentStore.purge(tg:)` (record, outbox, acked, rejected, every `zg.cs.*` / `zg.autolink.*`
    /// key of the id) and `SGAnalyticsQueueStore.purge(tg:)`.
    ///
    /// Nothing while the consent store is unreadable or the queue directory cannot be listed
    /// (`queueOwners == nil`): a launch before the first unlock sees empty defaults and no files,
    /// which must never read as "absent, so purge". The caller retries once both are readable.
    public static func purgeSet(known: [Int64], queueOwners: [Int64]?, signedIn: Set<Int64>, readable: Bool) -> [Int64] {
        guard readable, let queueOwners else {
            return []
        }
        return Set(known).union(queueOwners).subtracting(signedIn).filter { $0 > 0 }.sorted()
    }

    /// The bodies `SGEntitlement.preRevokeUploadsProvider` hands over at logout (§11.5): the
    /// account's pending withdrawals at the current authority (`SGConsentStore.pendingWithdraws`,
    /// oldest first), one entry per `POST /v1/profile/consents` body, the newest
    /// `finalUploadLimit` of them in their order. An entry that is not a valid event is skipped.
    public static func finalUploads(pendingWithdraws: [Data]) -> [Data] {
        let bodies = pendingWithdraws.compactMap { entry -> Data? in
            guard SGConsentEvent.decode(entry)?.action == .withdraw else {
                return nil
            }
            return SGConsentsRequest.body(events: [entry])
        }
        return Array(bodies.suffix(SGAccountReconcile.finalUploadLimit))
    }
}
