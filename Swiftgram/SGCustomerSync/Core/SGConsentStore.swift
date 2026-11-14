import Foundation

/// Zenlygram — every UserDefaults key of the customer-data layer (contract §6.2, design 40 §4.4),
/// spelled once. `tg` = the RAW Telegram user id (decimal), `authority` = the backend authority
/// (`SGEntitlement.shared.customerDataAuthority`).
public enum SGCustomerStoreKey: Hashable {
    /// `zg.consent.v1.<tg>` — the record JSON.
    case record(tg: Int64)
    /// `zg.consent.outbox.v1.<tg>` — the exact ConsentEvent JSON texts awaiting upload.
    case outbox(tg: Int64)
    /// `zg.consent.acked.v1.<tg>@<authority>` — JSON array of acked `consent_id`.
    case acked(tg: Int64, authority: String)
    /// `zg.consent.rejected.v1.<tg>@<authority>` — JSON object `{consent_id: error_code}`.
    case rejected(tg: Int64, authority: String)
    /// `zg.cs.notice.v1.<tg>` — why the record is `needs_reconsent` (`SGConsentStoredNotice`).
    case notice(tg: Int64)
    /// `zg.cs.consents_sent.v1.<tg>@<authority>` — the binding `device_id` whose post-link consents
    /// upload finished.
    case consentsSent(tg: Int64, authority: String)
    /// `zg.cs.bind_refused.v1.<tg>@<authority>` — the `consent_id` `/bind/start` refused (422
    /// `invalid_consent`).
    case bindRefused(tg: Int64, authority: String)
    /// `zg.cs.link_ended.v1.<tg>@<authority>` — `{"device_id","code","at"}` of the handled server-ended
    /// binding.
    case linkEnded(tg: Int64, authority: String)
    /// `zg.cs.delete.v1.<tg>@<authority>` — `{"key","sent_unknown","since"}`: the `erasing` fence.
    case deletion(tg: Int64, authority: String)
    /// `zg.cs.deleted_notice.v1.<tg>` — instant of a completed erasure whose done text was not shown.
    case deletedNotice(tg: Int64)
    /// `zg.autolink.v1.<tg>@<authority>` — the account's automatic-link schedule (and `suppressed`).
    case autoLink(tg: Int64, authority: String)
    /// `zg.autolink.install.v1@<authority>` — the install-wide attest-null ladder.
    case autoLinkInstall(authority: String)
    /// `zg.cs.budget.v1.<route>@<authority>` — a device-wide client budget window.
    case budget(route: SGCustomerRoute, authority: String)
    /// `zg.cs.hints.v1@<authority>` — the server's flush/min-interval hints.
    case hints(authority: String)
    /// `zg.cs.not_linked.v1.<tg>@<authority>` — the binding `device_id` that answered
    /// `profile_account_not_linked`.
    case notLinked(tg: Int64, authority: String)

    public var name: String {
        switch self {
        case let .record(tg):
            return "zg.consent.v1.\(tg)"
        case let .outbox(tg):
            return "zg.consent.outbox.v1.\(tg)"
        case let .acked(tg, authority):
            return "zg.consent.acked.v1.\(tg)@\(authority)"
        case let .rejected(tg, authority):
            return "zg.consent.rejected.v1.\(tg)@\(authority)"
        case let .notice(tg):
            return "zg.cs.notice.v1.\(tg)"
        case let .consentsSent(tg, authority):
            return "zg.cs.consents_sent.v1.\(tg)@\(authority)"
        case let .bindRefused(tg, authority):
            return "zg.cs.bind_refused.v1.\(tg)@\(authority)"
        case let .linkEnded(tg, authority):
            return "zg.cs.link_ended.v1.\(tg)@\(authority)"
        case let .deletion(tg, authority):
            return "zg.cs.delete.v1.\(tg)@\(authority)"
        case let .deletedNotice(tg):
            return "zg.cs.deleted_notice.v1.\(tg)"
        case let .autoLink(tg, authority):
            return "zg.autolink.v1.\(tg)@\(authority)"
        case let .autoLinkInstall(authority):
            return "zg.autolink.install.v1@\(authority)"
        case let .budget(route, authority):
            return "zg.cs.budget.v1.\(route.rawValue)@\(authority)"
        case let .hints(authority):
            return "zg.cs.hints.v1@\(authority)"
        case let .notLinked(tg, authority):
            return "zg.cs.not_linked.v1.\(tg)@\(authority)"
        }
    }

    /// Whether the key `name` belongs to the account `tg` (any authority): what `purge(tg:)` removes.
    static func belongs(_ name: String, to tg: Int64) -> Bool {
        let exact = [
            SGCustomerStoreKey.record(tg: tg).name,
            SGCustomerStoreKey.outbox(tg: tg).name,
            SGCustomerStoreKey.notice(tg: tg).name,
            SGCustomerStoreKey.deletedNotice(tg: tg).name,
        ]
        if exact.contains(name) {
            return true
        }
        let families = [
            "zg.consent.acked.v1.", "zg.consent.rejected.v1.", "zg.cs.consents_sent.v1.", "zg.cs.bind_refused.v1.",
            "zg.cs.link_ended.v1.", "zg.cs.delete.v1.", "zg.autolink.v1.", "zg.cs.not_linked.v1.",
        ]
        return families.contains { name.hasPrefix("\($0)\(tg)@") }
    }
}

/// Zenlygram — why a consent store write changed nothing.
public enum SGConsentStoreError: Error, Equatable {
    /// Protected data is unavailable or the store failed its canary read (a launch before the first
    /// unlock sees empty defaults): nothing was written.
    case unreadable
    /// The record's state does not allow the operation (or a required-mode decline): nothing written.
    case notAllowed
    /// The Telegram id, text, version or value is outside the contract: nothing written.
    case invalidInput
    /// The write did not read back (the wall shows `Consent.SaveFailed`).
    case saveFailed
}

/// Zenlygram — the local consent state of every Telegram account on this device (contract §6.2,
/// design 40 §4.4–4.5): the record, the outbox of exact ConsentEvents, the acked / rejected marks and
/// the per-account markers, in `UserDefaults.standard` of the MAIN APP only (never the App Group,
/// never an extension). Lock-guarded and synchronous: a grant returns only after the record and the
/// outbox are written and read back, so the wall never waits on the network.
///
/// Every write first requires `isReadable` (the injected protected-data check AND the canary read):
/// otherwise it is refused and nothing changes — never "absent, so write or purge". Reads are not
/// guarded; a caller that decides from them checks `isReadable` first.
///
/// The outbox keeps at most `outboxLimit` entries when it can: un-acked entries stay until acked,
/// the latest decision is always kept, an un-acked withdraw is never dropped; over the cap it drops,
/// in order, acked entries (oldest first), rejected grants, then un-acked grants older than the
/// latest decision. "Acked"/"rejected" there means at any authority.
public final class SGConsentStore {
    /// Posted on the main queue after a successful decision, normalisation, new upload mark, notice
    /// change or a purge that removed something; `userInfo["tg_user_id"]` is the raw Telegram id
    /// (`Int64`). Marker writes for I-2b/I-2c (`setString`/`setJSONObject` of the other keys) post
    /// nothing.
    public static let didChangeNotification = Notification.Name("SGConsentStoreDidChange")
    public static let tgUserIdKey = "tg_user_id"
    public static let outboxLimit = 10
    /// Device-wide, never purged: written once while readable, so a later launch that cannot read it
    /// does not trust its (empty) defaults.
    static let canaryKey = "zg.cs.canary.v1"

    private let defaults: UserDefaults
    private let readableProvider: () -> Bool
    private let clock: () -> Date
    private let makeConsentId: () -> String
    private let notify: (Int64) -> Void
    private let lock = NSLock()

    /// - Parameters:
    ///   - defaults: `UserDefaults.standard` in the app.
    ///   - isReadable: `UIApplication.shared.isProtectedDataAvailable` in the app.
    ///   - now: the clock for decisions that take no `now` (a decline).
    ///   - makeConsentId: mints `consent_id` (uuid4).
    ///   - notify: replaces the `didChangeNotification` post (tests).
    public init(defaults: UserDefaults, isReadable: @escaping () -> Bool, now: @escaping () -> Date = { Date() }, makeConsentId: @escaping () -> String = { SGCustomerTime.uuid4() }, notify: ((Int64) -> Void)? = nil) {
        self.defaults = defaults
        self.readableProvider = isReadable
        self.clock = now
        self.makeConsentId = makeConsentId
        self.notify = notify ?? { tg in
            NotificationCenter.default.post(name: SGConsentStore.didChangeNotification, object: nil, userInfo: [SGConsentStore.tgUserIdKey: tg])
        }
    }

    /// Protected data is available and the defaults answer the canary.
    public var isReadable: Bool {
        return self.locked { self.readableLocked() }
    }

    // MARK: - Reads

    /// The account's record; nil = `none` (absent, unreadable or corrupt).
    public func record(tg: Int64) -> SGConsentRecord? {
        return self.locked { self.recordLocked(tg) }
    }

    public func storedNotice(tg: Int64) -> SGConsentStoredNotice? {
        return self.locked { self.defaults.string(forKey: SGCustomerStoreKey.notice(tg: tg).name).flatMap(SGConsentStoredNotice.init(rawValue:)) }
    }

    /// The instant of a completed erasure whose done text was not shown yet.
    public func deletedNotice(tg: Int64) -> String? {
        return self.locked { self.defaults.string(forKey: SGCustomerStoreKey.deletedNotice(tg: tg).name).flatMap { SGCustomerTime.isInstant($0) ? $0 : nil } }
    }

    /// A confirmed in-app deletion of the account is not resolved yet (`zg.cs.delete…` present).
    public func isErasing(tg: Int64, authority: String) -> Bool {
        return self.locked { self.defaults.object(forKey: SGCustomerStoreKey.deletion(tg: tg, authority: authority).name) != nil }
    }

    public func isAcked(tg: Int64, authority: String, consentId: String) -> Bool {
        return self.locked { self.ackedLocked(tg, authority).contains(consentId) }
    }

    /// The newest grant in the outbox.
    public func latestGrant(tg: Int64) -> SGConsentEvent? {
        return self.locked { SGConsentStore.chronological(self.outboxLocked(tg)).last(where: { $0.event.action == .grant })?.event }
    }

    /// The error code the server rejected the account's newest grant with at `authority`, if it did.
    public func latestGrantRejection(tg: Int64, authority: String) -> String? {
        return self.locked {
            guard let grant = SGConsentStore.chronological(self.outboxLocked(tg)).last(where: { $0.event.action == .grant }) else {
                return nil
            }
            return self.rejectedLocked(tg, authority)[grant.event.consentId]
        }
    }

    /// Outbox entries neither acked nor rejected at `authority`, ascending `recorded_at` — the planner
    /// sends one per request.
    public func pendingUploads(tg: Int64, authority: String) -> [Data] {
        return self.locked { self.pendingLocked(tg, authority).map { Data($0.text.utf8) } }
    }

    /// The pending withdraws (the logout final send, design 40 §11.5): wrap each with
    /// `SGConsentsRequest.body(events:)`.
    public func pendingWithdraws(tg: Int64, authority: String) -> [Data] {
        return self.locked { self.pendingLocked(tg, authority).filter { $0.event.action == .withdraw }.map { Data($0.text.utf8) } }
    }

    /// The exact bytes of the newest decision (always kept): "always after a link" re-sends it.
    public func latestDecision(tg: Int64) -> Data? {
        return self.locked { SGConsentStore.chronological(self.outboxLocked(tg)).last.map { Data($0.text.utf8) } }
    }

    /// The `consent` of `/bind/start` (design 40 §7.1.4): the account's current grant as a JSON object
    /// of its stored bytes — only while the state is `granted`, that grant is not rejected at
    /// `authority`, `/bind/start` never refused its `consent_id`, and the account is not erasing.
    public func bindConsentObject(tg: Int64, authority: String) -> [String: Any]? {
        return self.locked {
            guard let record = self.recordLocked(tg), record.state == .granted, let consentId = record.consentId,
                  let entry = self.outboxLocked(tg).first(where: { $0.event.consentId == consentId && $0.event.action == .grant }),
                  self.rejectedLocked(tg, authority)[consentId] == nil,
                  self.defaults.string(forKey: SGCustomerStoreKey.bindRefused(tg: tg, authority: authority).name) != consentId,
                  self.defaults.object(forKey: SGCustomerStoreKey.deletion(tg: tg, authority: authority).name) == nil else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: Data(entry.text.utf8), options: [])) as? [String: Any]
        }
    }

    /// Telegram ids with a consent record on this device (launch reconciliation, design 40 §11.5).
    public func knownTelegramUserIds() -> [Int64] {
        return self.locked {
            let prefix = "zg.consent.v1."
            let ids = self.defaults.dictionaryRepresentation().keys.compactMap { key -> Int64? in
                guard key.hasPrefix(prefix), let tg = Int64(key.dropFirst(prefix.count)), tg > 0 else {
                    return nil
                }
                return tg
            }
            return Array(Set(ids)).sorted()
        }
    }

    /// A string marker (`consentsSent`, `bindRefused`, `notLinked`, `notice`, `deletedNotice`, …).
    public func string(_ key: SGCustomerStoreKey) -> String? {
        return self.locked { self.defaults.string(forKey: key.name) }
    }

    /// A JSON-object marker (`linkEnded`, `deletion`, `autoLink`, `autoLinkInstall`, `budget`, `hints`).
    public func jsonObject(_ key: SGCustomerStoreKey) -> [String: Any]? {
        return self.locked { self.jsonValueLocked(key.name) as? [String: Any] }
    }

    // MARK: - Decisions

    /// The user agreed to `text` (exactly what the wall rendered): mints the `consent_id`, appends
    /// the grant to the outbox and writes the `granted` record, both read back, BEFORE returning;
    /// then clears the re-consent notice, the deleted notice and the Unlink suppression. `now` is the
    /// server-offset clock (`SGEntitlement.shared.entitlementClock.effectiveNow()`).
    public func grant(tg: Int64, text: SGConsentRenderedText, mode: SGConsentMode, appVersion: String, now: Date) -> Result<SGConsentEvent, SGConsentStoreError> {
        let event = SGConsentEvent(consentId: self.makeConsentId(), tgUserId: tg, action: .grant, scopes: text.scopes, textVersion: text.version, textSha256: text.sha256, locale: text.locale, consentMode: mode, ageConfirmed: true, recordedAt: SGCustomerTime.instant(now), appVersion: SGConsentEvent.clippedVersion(appVersion))
        guard event.isValid else {
            return .failure(.invalidInput)
        }
        let record = SGConsentRecord(tgUserId: tg, state: .granted, consentId: event.consentId, textVersion: text.version, textSha256: text.sha256, locale: text.locale, consentMode: mode, decidedAt: event.recordedAt)
        let result: Result<SGConsentEvent, SGConsentStoreError> = self.locked {
            guard self.readableLocked() else {
                return .failure(.unreadable)
            }
            guard self.commitLocked(tg: tg, record: record, appending: event) else {
                return .failure(.saveFailed)
            }
            self.defaults.removeObject(forKey: SGCustomerStoreKey.notice(tg: tg).name)
            self.defaults.removeObject(forKey: SGCustomerStoreKey.deletedNotice(tg: tg).name)
            self.clearUnlinkSuppressionLocked(tg)
            return .success(event)
        }
        self.didChange(tg, result)
        return result
    }

    /// Optional mode only (I don't agree, the close glyph, Back or swipe-down; U rule 1.3), from
    /// `none`, `declined` or `needs_reconsent`: the record becomes `declined` (nothing is appended —
    /// a decline is never uploaded). A required-mode decline is a view state: `.notAllowed`, nothing
    /// written.
    public func decline(tg: Int64, mode: SGConsentMode) -> Result<Void, SGConsentStoreError> {
        guard mode == .optional else {
            return .failure(.notAllowed)
        }
        let decidedAt = SGCustomerTime.instant(self.clock())
        let result: Result<Void, SGConsentStoreError> = self.locked {
            guard self.readableLocked() else {
                return .failure(.unreadable)
            }
            let current = self.recordLocked(tg)
            let state = current?.state ?? SGConsentState.none
            guard state == SGConsentState.none || state == .declined || state == .needsReconsent else {
                return .failure(.notAllowed)
            }
            let record = SGConsentRecord(tgUserId: tg, state: .declined, consentId: current?.consentId, textVersion: current?.textVersion, textSha256: current?.textSha256, locale: current?.locale, consentMode: .optional, decidedAt: decidedAt)
            guard self.commitLocked(tg: tg, record: record, appending: nil) else {
                return .failure(.saveFailed)
            }
            self.defaults.removeObject(forKey: SGCustomerStoreKey.notice(tg: tg).name)
            return .success(())
        }
        self.didChange(tg, result)
        return result
    }

    /// Withdraws the account's grant (C§6.7): appends the withdraw (all four scopes, the withdrawn
    /// `text_version`, no `text_sha256`/`age_confirmed`) and writes the `withdrawn` record, both read
    /// back, before returning. Allowed from `granted`, and from `needs_reconsent` while the previous
    /// grant is acked at `authority` (the server still holds it effective).
    public func withdraw(tg: Int64, authority: String?, mode: SGConsentMode, locale: SGConsentLocale, appVersion: String, now: Date) -> Result<SGConsentEvent, SGConsentStoreError> {
        let consentId = self.makeConsentId()
        let result: Result<SGConsentEvent, SGConsentStoreError> = self.locked {
            guard self.readableLocked() else {
                return .failure(.unreadable)
            }
            guard let current = self.recordLocked(tg) else {
                return .failure(.notAllowed)
            }
            let heldByServer: Bool
            if current.state == .needsReconsent, let authority, let grantId = current.consentId {
                heldByServer = self.ackedLocked(tg, authority).contains(grantId)
            } else {
                heldByServer = false
            }
            guard current.state == .granted || heldByServer else {
                return .failure(.notAllowed)
            }
            let event = SGConsentEvent(consentId: consentId, tgUserId: tg, action: .withdraw, scopes: SGConsentScope.allCases.map(\.rawValue), textVersion: current.textVersion, textSha256: nil, locale: locale, consentMode: mode, ageConfirmed: nil, recordedAt: SGCustomerTime.instant(now), appVersion: SGConsentEvent.clippedVersion(appVersion))
            guard event.isValid else {
                return .failure(.invalidInput)
            }
            let record = SGConsentRecord(tgUserId: tg, state: .withdrawn, consentId: event.consentId, textVersion: current.textVersion, textSha256: nil, locale: locale, consentMode: mode, decidedAt: event.recordedAt)
            guard self.commitLocked(tg: tg, record: record, appending: event) else {
                return .failure(.saveFailed)
            }
            self.defaults.removeObject(forKey: SGCustomerStoreKey.notice(tg: tg).name)
            return .success(event)
        }
        self.didChange(tg, result)
        return result
    }

    /// Another device withdrew (C§6.3): a `granted` / `needs_reconsent` record becomes
    /// `withdrawn_remote` as of the server's `effective_at`.
    public func markWithdrawnRemote(tg: Int64, effectiveAt: String, consentId: String? = nil) -> Result<Void, SGConsentStoreError> {
        guard SGCustomerTime.isInstant(effectiveAt) else {
            return .failure(.invalidInput)
        }
        let result: Result<Void, SGConsentStoreError> = self.locked {
            guard self.readableLocked() else {
                return .failure(.unreadable)
            }
            guard var record = self.recordLocked(tg), record.state == .granted || record.state == .needsReconsent else {
                return .failure(.notAllowed)
            }
            record.state = .withdrawnRemote
            record.consentId = consentId ?? record.consentId
            record.decidedAt = effectiveAt
            guard self.commitLocked(tg: tg, record: record, appending: nil) else {
                return .failure(.saveFailed)
            }
            self.defaults.removeObject(forKey: SGCustomerStoreKey.notice(tg: tg).name)
            return .success(())
        }
        self.didChange(tg, result)
        return result
    }

    /// Normalises a `granted` record (or updates a `needs_reconsent` one) to `needs_reconsent` with
    /// `notice` — the wall policy's normalisations, the reconciler's `reconsent_required` and foreign
    /// duplicate, and a server-ended binding.
    public func markNeedsReconsent(tg: Int64, notice: SGConsentStoredNotice) -> Result<Void, SGConsentStoreError> {
        let result: Result<Void, SGConsentStoreError> = self.locked {
            self.markNeedsReconsentLocked(tg, notice: notice, onlyIf: { $0.state == .granted || $0.state == .needsReconsent })
        }
        self.didChange(tg, result)
        return result
    }

    /// 409 `consent_stale` on `/bind/start` (contract amendment A3), on the automatic AND the manual
    /// path: the grant predates an erasure of this Telegram id, so a `granted` record becomes
    /// `needs_reconsent` / `link_ended` — exactly what the auto-link's `.consentStale` does
    /// (`SGConsentReconciler.onBindConsentStale`). With `consentId` (the grant `/bind/start`
    /// carried) only that grant is normalised, never a newer one. `.notAllowed` = nothing to do.
    public func normaliseAfterConsentStale(tg: Int64, consentId: String?) -> Result<Void, SGConsentStoreError> {
        let result: Result<Void, SGConsentStoreError> = self.locked {
            self.markNeedsReconsentLocked(tg, notice: .linkEnded, onlyIf: { record in
                SGConsentReconciler.onBindConsentStale(record: record, consentId: consentId) == .markNeedsReconsent(.linkEnded)
            })
        }
        self.didChange(tg, result)
        return result
    }

    private func markNeedsReconsentLocked(_ tg: Int64, notice: SGConsentStoredNotice, onlyIf isAllowed: (SGConsentRecord) -> Bool) -> Result<Void, SGConsentStoreError> {
        guard self.readableLocked() else {
            return .failure(.unreadable)
        }
        guard var record = self.recordLocked(tg), isAllowed(record) else {
            return .failure(.notAllowed)
        }
        record.state = .needsReconsent
        let noticeKey = SGCustomerStoreKey.notice(tg: tg).name
        let previousNotice = self.defaults.object(forKey: noticeKey)
        self.defaults.set(notice.rawValue, forKey: noticeKey)
        guard self.defaults.string(forKey: noticeKey) == notice.rawValue, self.commitLocked(tg: tg, record: record, appending: nil) else {
            self.defaults.set(previousNotice, forKey: noticeKey)
            return .failure(.saveFailed)
        }
        return .success(())
    }

    // MARK: - Upload marks

    /// The server answered `recorded` / `duplicate` / `superseded` for these entries at `authority`.
    public func markAcked(tg: Int64, authority: String, ids: [String]) -> Result<Void, SGConsentStoreError> {
        var changed = false
        let result: Result<Void, SGConsentStoreError> = self.locked {
            guard self.readableLocked() else {
                return .failure(.unreadable)
            }
            let present = Set(self.outboxLocked(tg).map(\.event.consentId))
            let previous = self.ackedLocked(tg, authority)
            let acked = previous.union(ids).intersection(present)
            guard acked != previous else {
                return .success(())
            }
            self.setJSONLocked(acked.sorted(), SGCustomerStoreKey.acked(tg: tg, authority: authority).name)
            guard self.ackedLocked(tg, authority) == acked else {
                return .failure(.saveFailed)
            }
            changed = true
            return .success(())
        }
        if changed {
            self.didChange(tg, result)
        }
        return result
    }

    /// The server refused this GRANT for good at `authority` (a terminal 4xx, design 40 §4.7): it is
    /// never sent again. A withdraw is never marked rejected (`.notAllowed`); `code` that is not a
    /// stable error code is stored as `unknown`.
    public func markRejected(tg: Int64, authority: String, id: String, code: String) -> Result<Void, SGConsentStoreError> {
        let result: Result<Void, SGConsentStoreError> = self.locked {
            guard self.readableLocked() else {
                return .failure(.unreadable)
            }
            let entries = self.outboxLocked(tg)
            guard entries.contains(where: { $0.event.consentId == id && $0.event.action == .grant }) else {
                return .failure(.notAllowed)
            }
            let present = Set(entries.map(\.event.consentId))
            var rejected = self.rejectedLocked(tg, authority).filter { present.contains($0.key) }
            rejected[id] = SGCustomerLogCode.isStableCode(code) ? code : "unknown"
            self.setJSONLocked(rejected, SGCustomerStoreKey.rejected(tg: tg, authority: authority).name)
            guard self.rejectedLocked(tg, authority) == rejected else {
                return .failure(.saveFailed)
            }
            return .success(())
        }
        self.didChange(tg, result)
        return result
    }

    // MARK: - Markers

    /// Writes (nil removes) a string marker. The record, outbox and upload marks are written only by
    /// the operations above (`.notAllowed`).
    public func setString(_ value: String?, for key: SGCustomerStoreKey) -> Result<Void, SGConsentStoreError> {
        guard !SGConsentStore.isManaged(key) else {
            return .failure(.notAllowed)
        }
        return self.writeMarker(key) {
            self.defaults.set(value, forKey: key.name)
            return self.defaults.string(forKey: key.name) == value
        }
    }

    /// Writes (nil removes) a JSON-object marker as sorted-key JSON text.
    public func setJSONObject(_ object: [String: Any]?, for key: SGCustomerStoreKey) -> Result<Void, SGConsentStoreError> {
        guard !SGConsentStore.isManaged(key) else {
            return .failure(.notAllowed)
        }
        if let object, !JSONSerialization.isValidJSONObject(object) {
            return .failure(.invalidInput)
        }
        return self.writeMarker(key) {
            guard let object else {
                self.defaults.removeObject(forKey: key.name)
                return self.defaults.object(forKey: key.name) == nil
            }
            self.setJSONLocked(object, key.name)
            return self.defaults.string(forKey: key.name) != nil
        }
    }

    /// `/bind/start` refused this grant as malformed (422 `invalid_consent`): never attached again.
    public func setBindRefused(tg: Int64, authority: String, consentId: String) -> Result<Void, SGConsentStoreError> {
        return self.setString(consentId, for: .bindRefused(tg: tg, authority: authority))
    }

    /// Written AFTER the deletion purge (design 40 §11.4), so it survives it.
    public func setDeletedNotice(tg: Int64, at: Date) -> Result<Void, SGConsentStoreError> {
        return self.setString(SGCustomerTime.instant(at), for: .deletedNotice(tg: tg))
    }

    /// The done text was shown.
    public func clearDeletedNotice(tg: Int64) -> Result<Void, SGConsentStoreError> {
        return self.setString(nil, for: .deletedNotice(tg: tg))
    }

    // MARK: - Purge

    /// Removes every key of the account (`SGCustomerStoreKey.belongs`): the record, outbox, notices
    /// and every `…<tg>@<authority>` key of every authority. Device-wide keys stay. Refused while
    /// unreadable.
    public func purge(tg: Int64) -> Result<Void, SGConsentStoreError> {
        var removed = false
        let result: Result<Void, SGConsentStoreError> = self.locked {
            guard self.readableLocked() else {
                return .failure(.unreadable)
            }
            for key in self.defaults.dictionaryRepresentation().keys where SGCustomerStoreKey.belongs(key, to: tg) {
                self.defaults.removeObject(forKey: key)
                removed = true
            }
            return .success(())
        }
        if removed {
            self.didChange(tg, result)
        }
        return result
    }

    /// Data & consent's DEBUG row (`DataConsent.ResetDebug`).
    public func resetForDebug(tg: Int64) -> Result<Void, SGConsentStoreError> {
        return self.purge(tg: tg)
    }

    // MARK: - Internals

    private struct Entry {
        let text: String
        let event: SGConsentEvent
        let position: Int
    }

    private static func isManaged(_ key: SGCustomerStoreKey) -> Bool {
        switch key {
        case .record, .outbox, .acked, .rejected:
            return true
        default:
            return false
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return body()
    }

    private func readableLocked() -> Bool {
        guard self.readableProvider() else {
            return false
        }
        if self.defaults.string(forKey: SGConsentStore.canaryKey) == "1" {
            return true
        }
        self.defaults.set("1", forKey: SGConsentStore.canaryKey)
        return self.defaults.string(forKey: SGConsentStore.canaryKey) == "1"
    }

    private func writeMarker(_ key: SGCustomerStoreKey, _ write: () -> Bool) -> Result<Void, SGConsentStoreError> {
        let result: Result<Void, SGConsentStoreError> = self.locked {
            guard self.readableLocked() else {
                return .failure(.unreadable)
            }
            return write() ? .success(()) : .failure(.saveFailed)
        }
        switch key {
        case let .notice(tg), let .deletedNotice(tg):
            self.didChange(tg, result)
        default:
            break
        }
        return result
    }

    private func didChange<T>(_ tg: Int64, _ result: Result<T, SGConsentStoreError>) {
        guard case .success = result else {
            return
        }
        let notify = self.notify
        if Thread.isMainThread {
            notify(tg)
        } else {
            DispatchQueue.main.async {
                notify(tg)
            }
        }
    }

    private func recordLocked(_ tg: Int64) -> SGConsentRecord? {
        guard let text = self.defaults.string(forKey: SGCustomerStoreKey.record(tg: tg).name),
              let record = SGConsentRecord.decode(Data(text.utf8)), record.tgUserId == tg else {
            return nil
        }
        return record
    }

    /// The outbox in stored order; an entry that is not a valid event of this account is skipped
    /// (and dropped by the next append).
    private func outboxLocked(_ tg: Int64) -> [Entry] {
        let texts = self.defaults.stringArray(forKey: SGCustomerStoreKey.outbox(tg: tg).name) ?? []
        return texts.enumerated().compactMap { position, text in
            guard let event = SGConsentEvent.decode(Data(text.utf8)), event.tgUserId == tg else {
                return nil
            }
            return Entry(text: text, event: event, position: position)
        }
    }

    /// Ascending `recorded_at`; equal instants keep the stored order.
    private static func chronological(_ entries: [Entry]) -> [Entry] {
        return entries.sorted { ($0.event.recordedAt, $0.position) < ($1.event.recordedAt, $1.position) }
    }

    private func pendingLocked(_ tg: Int64, _ authority: String) -> [Entry] {
        let acked = self.ackedLocked(tg, authority)
        let rejected = self.rejectedLocked(tg, authority)
        return SGConsentStore.chronological(self.outboxLocked(tg)).filter { !acked.contains($0.event.consentId) && rejected[$0.event.consentId] == nil }
    }

    private func ackedLocked(_ tg: Int64, _ authority: String) -> Set<String> {
        return Set((self.jsonValueLocked(SGCustomerStoreKey.acked(tg: tg, authority: authority).name) as? [String]) ?? [])
    }

    private func rejectedLocked(_ tg: Int64, _ authority: String) -> [String: String] {
        return (self.jsonValueLocked(SGCustomerStoreKey.rejected(tg: tg, authority: authority).name) as? [String: String]) ?? [:]
    }

    /// Union over every authority (outbox retention).
    private func marksAtAnyAuthorityLocked(_ tg: Int64) -> (acked: Set<String>, rejected: Set<String>) {
        var acked = Set<String>()
        var rejected = Set<String>()
        let ackedPrefix = "zg.consent.acked.v1.\(tg)@"
        let rejectedPrefix = "zg.consent.rejected.v1.\(tg)@"
        for key in self.defaults.dictionaryRepresentation().keys {
            if key.hasPrefix(ackedPrefix) {
                acked.formUnion((self.jsonValueLocked(key) as? [String]) ?? [])
            } else if key.hasPrefix(rejectedPrefix) {
                rejected.formUnion(((self.jsonValueLocked(key) as? [String: String]) ?? [:]).keys)
            }
        }
        return (acked, rejected)
    }

    /// Appends `event` (with retention) to the outbox, then writes `record`; each read back. On a
    /// failed read-back both are restored as they were and false is returned.
    private func commitLocked(tg: Int64, record: SGConsentRecord, appending event: SGConsentEvent?) -> Bool {
        let recordKey = SGCustomerStoreKey.record(tg: tg).name
        let outboxKey = SGCustomerStoreKey.outbox(tg: tg).name
        let previousRecord = self.defaults.object(forKey: recordKey)
        let previousOutbox = self.defaults.object(forKey: outboxKey)
        func restore() {
            self.defaults.set(previousOutbox, forKey: outboxKey)
            self.defaults.set(previousRecord, forKey: recordKey)
        }
        if let event {
            let text = String(decoding: event.encoded(), as: UTF8.self)
            let entries = self.outboxLocked(tg)
            let appended = entries + [Entry(text: text, event: event, position: (entries.map(\.position).max() ?? -1) + 1)]
            let texts = self.retainedLocked(appended, tg: tg).map(\.text)
            self.defaults.set(texts, forKey: outboxKey)
            guard self.defaults.stringArray(forKey: outboxKey) == texts else {
                restore()
                return false
            }
        }
        self.defaults.set(String(decoding: record.encoded(), as: UTF8.self), forKey: recordKey)
        guard self.recordLocked(tg) == record else {
            restore()
            return false
        }
        return true
    }

    private func retainedLocked(_ entries: [Entry], tg: Int64) -> [Entry] {
        guard entries.count > SGConsentStore.outboxLimit else {
            return entries
        }
        let ordered = SGConsentStore.chronological(entries)
        guard let latest = ordered.last else {
            return entries
        }
        let marks = self.marksAtAnyAuthorityLocked(tg)
        var dropped = Set<Int>()
        var excess = entries.count - SGConsentStore.outboxLimit
        func drop(where isDroppable: (Entry) -> Bool) {
            for entry in ordered where excess > 0 && entry.position != latest.position && !dropped.contains(entry.position) && isDroppable(entry) {
                dropped.insert(entry.position)
                excess -= 1
            }
        }
        drop { marks.acked.contains($0.event.consentId) }
        drop { $0.event.action == .grant && marks.rejected.contains($0.event.consentId) }
        drop { $0.event.action == .grant }
        return entries.filter { !dropped.contains($0.position) }
    }

    private func clearUnlinkSuppressionLocked(_ tg: Int64) {
        let prefix = "zg.autolink.v1.\(tg)@"
        for key in self.defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            guard var object = self.jsonValueLocked(key) as? [String: Any], object["suppressed"] != nil else {
                continue
            }
            object.removeValue(forKey: "suppressed")
            self.setJSONLocked(object, key)
        }
    }

    private func jsonValueLocked(_ name: String) -> Any? {
        guard let text = self.defaults.string(forKey: name) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [])
    }

    private func setJSONLocked(_ value: Any, _ name: String) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return
        }
        self.defaults.set(String(decoding: data, as: UTF8.self), forKey: name)
    }
}
