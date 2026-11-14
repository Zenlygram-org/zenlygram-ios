import Foundation

// Zenlygram — P7 (contract 2026-10-12): which App Store receipt a server revocation is about, and who
// owns an Apple original transaction. Without it the StoreKit fallback was one identityless
// aggregate per install: a refund the server had already applied kept unlocking creation from a
// stale StoreKit cache, and account A's receipt unlocked account B's Vault.
//
// Nothing here gates reading, opening, unhiding, unlocking or deleting existing data — only the
// CREATE decisions `SGEntitlementEvaluator` feeds.

/// `apple_source.event_id`: a nonnegative decimal integer of any size, compared exactly — never
/// through a floating-point or fixed-width integer, which could overflow or round.
public struct SGEntitlementAppleEventId: Comparable, Hashable, Codable, CustomStringConvertible {
    /// Digits only, no leading zeros ("0" for zero).
    public let digits: String

    public init?(_ raw: String) {
        guard !raw.isEmpty, raw.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        let trimmed = raw.drop(while: { $0 == "0" })
        self.digits = trimmed.isEmpty ? "0" : String(trimmed)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = SGEntitlementAppleEventId(raw) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "event_id is not a nonnegative decimal string"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.digits)
    }

    public static func < (lhs: SGEntitlementAppleEventId, rhs: SGEntitlementAppleEventId) -> Bool {
        if lhs.digits.count != rhs.digits.count {
            return lhs.digits.count < rhs.digits.count
        }
        return lhs.digits < rhs.digits
    }

    public var description: String {
        return self.digits
    }
}

/// `apple_source.environment`. Exactly the two values the contract allows; anything else makes the
/// token malformed.
public enum SGEntitlementAppleEnvironment: String, Codable, Hashable {
    case production = "Production"
    case sandbox = "Sandbox"
}

/// One `apple_source.revoked_transactions[]` element: an exact receipt the server revoked, and the
/// instant (receipt expiry + 72 h) after which its tombstone no longer matters.
public struct SGEntitlementAppleRevokedTransaction: Equatable, Hashable {
    public let transactionId: String
    public let fallbackUntil: Date
}

/// The `apple_source` object. Every member is required and non-null; anything else is malformed.
public struct SGEntitlementAppleSource: Equatable, Decodable {
    public let originalTransactionId: String
    public let environment: SGEntitlementAppleEnvironment
    public let eventId: SGEntitlementAppleEventId
    public let revokedTransactions: [SGEntitlementAppleRevokedTransaction]

    private enum CodingKeys: String, CodingKey {
        case originalTransactionId = "original_transaction_id"
        case environment
        case eventId = "event_id"
        case revokedTransactions = "revoked_transactions"
    }

    private enum RevokedKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case fallbackUntil = "fallback_until"
    }

    public init(originalTransactionId: String, environment: SGEntitlementAppleEnvironment, eventId: SGEntitlementAppleEventId, revokedTransactions: [SGEntitlementAppleRevokedTransaction]) {
        self.originalTransactionId = originalTransactionId
        self.environment = environment
        self.eventId = eventId
        self.revokedTransactions = revokedTransactions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let original = try container.decode(String.self, forKey: .originalTransactionId)
        guard !original.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .originalTransactionId, in: container, debugDescription: "empty original_transaction_id")
        }
        self.originalTransactionId = original
        self.environment = try container.decode(SGEntitlementAppleEnvironment.self, forKey: .environment)
        self.eventId = try container.decode(SGEntitlementAppleEventId.self, forKey: .eventId)
        var list = try container.nestedUnkeyedContainer(forKey: .revokedTransactions)
        var revoked: [SGEntitlementAppleRevokedTransaction] = []
        while !list.isAtEnd {
            let item = try list.nestedContainer(keyedBy: RevokedKeys.self)
            let transactionId = try item.decode(String.self, forKey: .transactionId)
            let rawUntil = try item.decode(String.self, forKey: .fallbackUntil)
            // RFC 3339 UTC: `Z`, never an offset.
            guard !transactionId.isEmpty, rawUntil.hasSuffix("Z"), let until = SGEntitlementTimestamp.parse(rawUntil) else {
                throw DecodingError.dataCorruptedError(forKey: .fallbackUntil, in: item, debugDescription: "malformed revoked transaction")
            }
            revoked.append(SGEntitlementAppleRevokedTransaction(transactionId: transactionId, fallbackUntil: until))
        }
        self.revokedTransactions = revoked
    }
}

/// The three states of the optional `apple_source` claim.
public enum SGEntitlementAppleSourceClaim: Equatable {
    /// Absent: a legacy server or token. Neither a revocation nor an ownership assertion.
    case omitted
    /// `null`: this account owns no Apple original.
    case none
    case source(SGEntitlementAppleSource)
}

/// Who owns an Apple original transaction, as far as this install has been TOLD by the server.
public enum SGEntitlementAppleOwnership: Codable, Equatable {
    /// Nothing authoritative yet (not attached, failed, refused). Eligible device-wide, like before.
    case unresolved
    /// An anonymous attach said `account.linked_telegram == false`: a genuine pre-link purchase,
    /// usable by every account on the device (invariant I2).
    case unclaimed
    /// Owned by the server account `accountId`; its Telegram peer when known locally.
    case claimed(accountId: String, accountPeerId: Int64?)

    /// The outcome of a SUCCESSFUL `/apple/attach` for this original. A bound attach that succeeded
    /// is the caller's (the server answers 409 otherwise). An anonymous one is claimed only when the
    /// server says the owner is linked to Telegram; a missing field proves nothing.
    public static func fromAttach(boundAccountPeerId: Int64?, accountId: String?, linkedTelegram: Bool?) -> SGEntitlementAppleOwnership {
        guard let accountId, !accountId.isEmpty else {
            return .unresolved
        }
        if let boundAccountPeerId {
            return .claimed(accountId: accountId, accountPeerId: boundAccountPeerId)
        }
        switch linkedTelegram {
        case .some(true):
            return .claimed(accountId: accountId, accountPeerId: nil)
        case .some(false):
            return .unclaimed
        case .none:
            return .unresolved
        }
    }

    /// Claimed ownership is never demoted: not by logout, an anonymous replay, a transient failure
    /// or a 409. Only another positive server statement of an owner replaces it.
    public static func merged(current: SGEntitlementAppleOwnership, observed: SGEntitlementAppleOwnership) -> SGEntitlementAppleOwnership {
        switch (current, observed) {
        case (_, .unresolved):
            return current
        case (.claimed, .unclaimed):
            return current
        case (_, .unclaimed):
            return .unclaimed
        case let (.claimed(currentId, currentPeer), .claimed(observedId, observedPeer)) where currentId == observedId:
            return .claimed(accountId: currentId, accountPeerId: observedPeer ?? currentPeer)
        case (_, .claimed):
            return observed
        }
    }

    /// May this receipt grant the account identified by (`accountId`, `accountPeerId`)?
    func grants(accountId: String?, accountPeerId: Int64?) -> Bool {
        switch self {
        case .unresolved, .unclaimed:
            return true
        case let .claimed(ownerId, ownerPeer):
            if let accountId, !accountId.isEmpty, accountId == ownerId {
                return true
            }
            if let ownerPeer, let accountPeerId, ownerPeer == accountPeerId {
                return true
            }
            return false
        }
    }
}

/// The highest provenance observed per (trust domain, environment, original), plus the local
/// ownership of each original. Per INSTALL: it survives account switches and logouts, because the
/// receipts it describes belong to the Apple ID, not to a Telegram session.
public struct SGEntitlementAppleProvenanceState: Codable, Equatable {
    struct Record: Codable, Equatable {
        var eventId: SGEntitlementAppleEventId?
        /// transaction id → fallback_until.
        var tombstones: [String: Date]
        var ownership: SGEntitlementAppleOwnership
        /// Accounts on this install whose BOUND attach of this original the server refused with
        /// `apple_subscription_conflict`: it belongs to another Telegram account. Never granting for
        /// them, whatever `ownership` says (a conflict never turns a receipt into unclaimed for its
        /// loser). Cleared for an account only by a positive server statement naming it the owner.
        /// Optional so a ledger stored before this field decodes unchanged.
        var conflictedAccountPeerIds: [Int64]?

        /// Lifts the conflict of the peer an ACCEPTED, NEW positive statement names as owner.
        /// Callers pass only the incoming statement — never the retained / merged ownership, which
        /// can be the account's own earlier claim that the 409 has since contradicted.
        mutating func liftConflict(namedBy statement: SGEntitlementAppleOwnership) {
            guard case let .claimed(_, ownerPeer) = statement, let ownerPeer, var conflicted = self.conflictedAccountPeerIds else {
                return
            }
            conflicted.removeAll(where: { $0 == ownerPeer })
            self.conflictedAccountPeerIds = conflicted.isEmpty ? nil : conflicted
        }
    }

    /// Keyed by `key(domain:environment:originalTransactionId:)`.
    var records: [String: Record] = [:]

    public init() {
    }

    static func key(domain: String, environment: String, originalTransactionId: String) -> String {
        // Domain and environment never contain "\n"; the original id is the last component.
        return "\(domain)\n\(environment)\n\(originalTransactionId)"
    }

    /// Applies a VERIFIED token's `apple_source` for its account (`sub`). Event ordering:
    /// - lower than what is held: ignored (a stale token cannot restore a revoked receipt);
    /// - equal: tombstones only accumulate — an equal id never clears a live one;
    /// - higher: the complete snapshot replaces the tombstones (clearing one is the authoritative
    ///   reversal) and names the owner.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func observe(_ source: SGEntitlementAppleSource, ownerAccountId: String, ownerAccountPeerId: Int64?, domain: String, now: Date) -> Bool {
        let key = SGEntitlementAppleProvenanceState.key(domain: domain, environment: source.environment.rawValue, originalTransactionId: source.originalTransactionId)
        var record = self.records[key] ?? Record(eventId: nil, tombstones: [:], ownership: .unresolved)
        let previous = record
        var incoming: [String: Date] = [:]
        for revoked in source.revokedTransactions where revoked.fallbackUntil > now {
            incoming[revoked.transactionId] = max(incoming[revoked.transactionId] ?? revoked.fallbackUntil, revoked.fallbackUntil)
        }
        let owner = SGEntitlementAppleOwnership.claimed(accountId: ownerAccountId, accountPeerId: ownerAccountPeerId)
        // Lifting a 409 conflict needs a statement known to be NEWER than what this install held:
        // only a strictly higher event id over a held one. An equal id is the same server state
        // (a stale or re-delivered token of the old owner must not undo a fresher 409), and with
        // no held id there is nothing to order against. A 409 carries no event id, so a token
        // minted between the last observed event and the 409 is the one ordering gap left.
        let liftsConflict: Bool
        if let held = record.eventId, source.eventId < held {
            return false
        } else if let held = record.eventId, source.eventId == held {
            record.tombstones.merge(incoming, uniquingKeysWith: { max($0, $1) })
            // Same event, so the same server state: refreshes the peer, never moves the owner.
            if case let .claimed(heldId, _) = record.ownership, heldId == ownerAccountId {
                record.ownership = SGEntitlementAppleOwnership.merged(current: record.ownership, observed: owner)
            } else if case .claimed = record.ownership {
                // Two owners at one event id: unordered. Keep the first; reported as a server gap.
            } else {
                record.ownership = SGEntitlementAppleOwnership.merged(current: record.ownership, observed: owner)
            }
            liftsConflict = false
        } else {
            liftsConflict = record.eventId != nil
            record.eventId = source.eventId
            record.tombstones = incoming
            record.ownership = SGEntitlementAppleOwnership.merged(current: record.ownership, observed: owner)
        }
        if liftsConflict {
            record.liftConflict(namedBy: owner)
        }
        self.records[key] = record
        return record != previous
    }

    /// Records a successful attach's ownership (`SGEntitlementAppleOwnership.fromAttach`). Never
    /// demotes a claim; never touches the event ordering or tombstones.
    @discardableResult
    public mutating func recordAttach(originalTransactionId: String, environment: String, ownership: SGEntitlementAppleOwnership, domain: String) -> Bool {
        guard !originalTransactionId.isEmpty else {
            return false
        }
        let key = SGEntitlementAppleProvenanceState.key(domain: domain, environment: environment, originalTransactionId: originalTransactionId)
        var record = self.records[key] ?? Record(eventId: nil, tombstones: [:], ownership: .unresolved)
        let previous = record
        record.ownership = SGEntitlementAppleOwnership.merged(current: record.ownership, observed: ownership)
        // A successful BOUND attach (a 2xx answered to that account's own request, after its 409)
        // names it the owner; an anonymous, unresolved or other account's answer lifts nothing.
        record.liftConflict(namedBy: ownership)
        self.records[key] = record
        return record != previous
    }

    /// Records that `accountPeerId`'s bound attach of this original was refused as owned by another
    /// account (`apple_subscription_conflict`). An environment other than exactly Production or
    /// Sandbox is recorded under both (`ledgerEnvironments`). Never touches event ordering,
    /// tombstones or the recorded owner. Returns whether anything changed.
    @discardableResult
    public mutating func recordConflict(originalTransactionId: String, environment: String, accountPeerId: Int64, domain: String) -> Bool {
        guard !originalTransactionId.isEmpty else {
            return false
        }
        var changed = false
        for candidate in SGEntitlementAppleProvenanceState.ledgerEnvironments(forReceiptEnvironment: environment) {
            let key = SGEntitlementAppleProvenanceState.key(domain: domain, environment: candidate, originalTransactionId: originalTransactionId)
            var record = self.records[key] ?? Record(eventId: nil, tombstones: [:], ownership: .unresolved)
            var conflicted = record.conflictedAccountPeerIds ?? []
            guard !conflicted.contains(accountPeerId) else {
                continue
            }
            conflicted.append(accountPeerId)
            record.conflictedAccountPeerIds = conflicted
            self.records[key] = record
            changed = true
        }
        return changed
    }

    func isConflicted(domain: String, environment: String, originalTransactionId: String, accountPeerId: Int64?) -> Bool {
        guard let accountPeerId else {
            return false
        }
        return self.records[SGEntitlementAppleProvenanceState.key(domain: domain, environment: environment, originalTransactionId: originalTransactionId)]?.conflictedAccountPeerIds?.contains(accountPeerId) ?? false
    }

    public func ownership(domain: String, environment: String, originalTransactionId: String) -> SGEntitlementAppleOwnership {
        return self.records[SGEntitlementAppleProvenanceState.key(domain: domain, environment: environment, originalTransactionId: originalTransactionId)]?.ownership ?? .unresolved
    }

    /// The exact (environment, original, transaction) receipt is revoked and its tombstone is live.
    public func isTombstoned(domain: String, environment: String, originalTransactionId: String, transactionId: String, now: Date) -> Bool {
        guard let until = self.records[SGEntitlementAppleProvenanceState.key(domain: domain, environment: environment, originalTransactionId: originalTransactionId)]?.tombstones[transactionId] else {
            return false
        }
        return now < until
    }

    /// An authenticated, live revocation exists in this trust domain — the contradiction that
    /// quarantines an identityless legacy aggregate.
    public func hasLiveTombstone(domain: String, now: Date) -> Bool {
        let prefix = "\(domain)\n"
        return self.records.contains(where: { key, record in
            key.hasPrefix(prefix) && record.tombstones.values.contains(where: { now < $0 })
        })
    }

    /// Drops tombstones whose `fallback_until` has passed. Event ids and ownership are kept: they
    /// are what stops a stale token from re-planting or reassigning anything.
    public mutating func prune(now: Date) {
        for key in Array(self.records.keys) {
            let tombstones = self.records[key]?.tombstones.filter { now < $0.value } ?? [:]
            self.records[key]?.tombstones = tombstones
        }
    }
}

/// The identifying fields of an App Store signed transaction (JWS), read from its payload without
/// verifying it — only to key a LOCAL, non-granting record; StoreKit verified it already.
public struct SGEntitlementAppleSignedTransactionFields: Equatable {
    public let originalTransactionId: String
    /// As signed ("Production", "Sandbox", "Xcode", …); "" when absent.
    public let environment: String

    public init?(signedTransaction jws: String) {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            return nil
        }
        // App Store transaction payloads carry the id as a decimal string.
        guard let original = object["originalTransactionId"] as? String, !original.isEmpty else {
            return nil
        }
        self.originalTransactionId = original
        self.environment = (object["environment"] as? String) ?? ""
    }
}

/// What the stored ledger bytes load as. Absent is a clean start; bytes this build cannot decode
/// (corrupt, or a newer build's format) start empty in memory but must never be written over —
/// `SGEntitlement.mutateAppleProvenance` then keeps every change in memory only.
public struct SGEntitlementAppleProvenanceStoredLoad: Equatable {
    public let initialState: SGEntitlementAppleProvenanceState
    public let preservesStoredBytes: Bool

    public init(stored: Data?) {
        guard let stored else {
            self.initialState = SGEntitlementAppleProvenanceState()
            self.preservesStoredBytes = false
            return
        }
        if let decoded = try? JSONDecoder().decode(SGEntitlementAppleProvenanceState.self, from: stored) {
            self.initialState = decoded
            self.preservesStoredBytes = false
        } else {
            self.initialState = SGEntitlementAppleProvenanceState()
            self.preservesStoredBytes = true
        }
    }
}

extension SGEntitlementAppleProvenanceState {
    /// The ledger environments a receipt's environment string is checked under. Exactly
    /// "Production" or "Sandbox" is itself. Anything else (unreadable payload → "", "Xcode", a
    /// future value) cannot be placed, so it is checked under BOTH, and either one denying denies:
    /// an unidentifiable environment must not slip past a revocation or an owner recorded under
    /// the real one.
    static func ledgerEnvironments(forReceiptEnvironment environment: String) -> [String] {
        if SGEntitlementAppleEnvironment(rawValue: environment) != nil {
            return [environment]
        }
        return [SGEntitlementAppleEnvironment.production.rawValue, SGEntitlementAppleEnvironment.sandbox.rawValue]
    }

    /// May the receipt (environment, original, transaction) grant (`accountId`, `accountPeerId`)?
    /// Not if, under any environment it can belong to (`ledgerEnvironments`), it is an exact live
    /// tombstone, another account's claimed original, or an original this account's bound attach
    /// was refused for as another account's (`recordConflict`).
    public func receiptGrants(domain: String, environment: String, originalTransactionId: String, transactionId: String, accountId: String?, accountPeerId: Int64?, now: Date) -> Bool {
        for candidate in SGEntitlementAppleProvenanceState.ledgerEnvironments(forReceiptEnvironment: environment) {
            if self.isTombstoned(domain: domain, environment: candidate, originalTransactionId: originalTransactionId, transactionId: transactionId, now: now) {
                return false
            }
            if !self.ownership(domain: domain, environment: candidate, originalTransactionId: originalTransactionId).grants(accountId: accountId, accountPeerId: accountPeerId) {
                return false
            }
            if self.isConflicted(domain: domain, environment: candidate, originalTransactionId: originalTransactionId, accountPeerId: accountPeerId) {
                return false
            }
        }
        return true
    }
}

/// What the evaluator needs to decide which StoreKit receipts may grant ONE account.
public struct SGEntitlementStoreKitEligibility: Equatable {
    public let provenance: SGEntitlementAppleProvenanceState
    /// The configured backend trust domain the ledger is scoped to.
    public let domain: String
    /// The account's server id (`material.accountId` / `sub`), when it has a binding.
    public let accountId: String?
    public let accountPeerId: Int64?
    /// False while the stored ledger exists but cannot be decoded
    /// (`SGEntitlementAppleProvenanceStoredLoad.preservesStoredBytes`). Its tombstones, owners and
    /// conflicts are then unknown, so NO StoreKit receipt or aggregate may grant creation — in the
    /// app and in every extension, which read the same bytes. A verified token still grants, and
    /// existing data is never evaluated here.
    public let isLedgerReadable: Bool

    public init(provenance: SGEntitlementAppleProvenanceState, domain: String, accountId: String?, accountPeerId: Int64?, isLedgerReadable: Bool = true) {
        self.provenance = provenance
        self.domain = domain
        self.accountId = accountId
        self.accountPeerId = accountPeerId
        self.isLedgerReadable = isLedgerReadable
    }
}
