import Foundation

/// Session keys use `PeerId.toInt64()`, not Telegram's raw user id. Postbox packs the namespace into
/// bits 32...34 and shifts the user id's high bits left by three (`Peer.swift`). Cloud users have
/// namespace zero; decoding is necessary for modern user ids above UInt32.max. Kept here so the
/// extension-safe entitlement library does not acquire a dependency on the Postbox database.
///
/// Public so the main app's consent providers map the packed id exactly as this module does.
public enum SGEntitlementAccountIdentity {
    public static func telegramUserId(accountPeerId: Int64) -> Int64? {
        guard accountPeerId > 0 else {
            return nil
        }
        let packed = UInt64(accountPeerId)
        guard ((packed >> 32) & 0x7) == 0 else {
            return nil
        }
        let raw = (packed & 0xffffffff) | ((packed >> 35) << 32)
        return Int64(raw)
    }
}

/// Zenlygram — who asked for a bind: the user on the Link screen, or the main app's automatic link
/// (`SGEntitlement.bindWithTelegramAttestation`). Decides whether a start may go out under the
/// account's permission (`SGEntitlement.permitsStart`: the automatic link only while `.allowed`) and
/// the consent fallbacks of `/bind/start` (`SGEntitlement.startWithConsentFallback`: a `409
/// consent_stale` is retried only for a manual start, and an automatic start's `422 invalid_consent`
/// retry only while its permission is still `.allowed`).
public enum SGEntitlementBindPurpose: Equatable {
    case manual
    case auto
}

/// The local owner and lifetime of a bind request. Access to the registry is serialized by the
/// entitlement's binding lock, together with session writes and logout.
struct SGEntitlementBindAttempt: Equatable {
    let accountPeerId: Int64
    let generation: UUID
}

/// Zenlygram — the one live bind attempt per account. A newer attempt replaces the older one, a
/// logout or a stored bind removes it, and the flow that began an attempt ends it when it gives up
/// (`end`), so an abandoned attempt never reads as in progress.
struct SGEntitlementBindAttempts {
    struct Record: Equatable {
        let generation: UUID
        let beganAt: Date
        /// The start's `expires_at` (the server's bind TTL), once `/bind/start` answered.
        var expiresAt: Date?
        let purpose: SGEntitlementBindPurpose
        /// The flow that began it gave up: no longer current, never in progress.
        var ended: Bool
    }

    /// How long an attempt whose start has not (yet) told its expiry counts as live: the server's
    /// default bind TTL (`zenlypay.bind.ttl_seconds`).
    static let defaultLifetime: TimeInterval = 300.0

    private var records: [Int64: Record] = [:]

    mutating func begin(accountPeerId: Int64, purpose: SGEntitlementBindPurpose = .manual, now: Date = Date()) -> SGEntitlementBindAttempt {
        let generation = UUID()
        self.records[accountPeerId] = Record(generation: generation, beganAt: now, expiresAt: nil, purpose: purpose, ended: false)
        return SGEntitlementBindAttempt(accountPeerId: accountPeerId, generation: generation)
    }

    func isCurrent(_ attempt: SGEntitlementBindAttempt?, accountPeerId: Int64) -> Bool {
        guard let attempt, attempt.accountPeerId == accountPeerId, let record = self.records[accountPeerId] else {
            return false
        }
        return record.generation == attempt.generation && !record.ended
    }

    func isCurrent(_ attempt: SGEntitlementBindAttempt?) -> Bool {
        guard let attempt else {
            return false
        }
        return self.isCurrent(attempt, accountPeerId: attempt.accountPeerId)
    }

    /// Records the start's expiry, only while `attempt` is still the account's current one.
    mutating func setExpiresAt(_ expiresAt: Date?, for attempt: SGEntitlementBindAttempt?) {
        guard let attempt, self.isCurrent(attempt) else {
            return
        }
        self.records[attempt.accountPeerId]?.expiresAt = expiresAt
    }

    /// Ends `attempt` — and only it: a newer attempt of the same account is never touched. True when
    /// it was still current.
    @discardableResult
    mutating func end(_ attempt: SGEntitlementBindAttempt?) -> Bool {
        guard let attempt, self.isCurrent(attempt) else {
            return false
        }
        self.records[attempt.accountPeerId]?.ended = true
        return true
    }

    mutating func invalidate(accountPeerId: Int64) {
        self.records.removeValue(forKey: accountPeerId)
    }

    /// A current, not-ended attempt that has not outlived its start: `now < expiresAt`, or
    /// `beganAt + defaultLifetime` while the expiry is unknown.
    func isInProgress(accountPeerId: Int64, now: Date) -> Bool {
        guard let record = self.records[accountPeerId], !record.ended else {
            return false
        }
        let until = record.expiresAt ?? record.beganAt.addingTimeInterval(SGEntitlementBindAttempts.defaultLifetime)
        return now < until
    }

    /// Tests: the account's record, ended or not.
    func record(accountPeerId: Int64) -> Record? {
        return self.records[accountPeerId]
    }
}

extension SGEntitlementBindConfirmation {
    /// A bot opened in another signed-in Telegram account must not attach that account's Pro
    /// subscription to the paywall's account. Check the envelope first and the signed identity
    /// whenever its key is known; an unknown rotated key may still establish a session for refresh.
    func belongs(to accountPeerId: Int64, pinnedKeys: SGEntitlementPinnedKeys) -> Bool {
        guard let telegramUserId = SGEntitlementAccountIdentity.telegramUserId(accountPeerId: accountPeerId),
              !self.refreshToken.isEmpty,
              let account = self.account, !account.id.isEmpty, account.tgUserId == telegramUserId,
              let device = self.device, !device.id.isEmpty else {
            return false
        }
        switch SGEntitlementTokenVerifier.verify(self.entitlement, pinnedKeys: pinnedKeys, boundDeviceId: device.id, boundAccountId: account.id, accountPeerId: accountPeerId) {
        case .success, .failure(.unknownKid):
            return true
        case .failure:
            return false
        }
    }
}
