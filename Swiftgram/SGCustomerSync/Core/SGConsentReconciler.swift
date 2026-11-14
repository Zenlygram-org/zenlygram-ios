import Foundation

/// Zenlygram — how the local consent follows what the server says (contract §6.3, design 40 §4.7),
/// as pure functions: the caller applies the action (`SGConsentStore`) and runs the effects (stop
/// traffic, drop the event queue, re-show the wall).
public enum SGConsentReconciler {
    public enum Action: Equatable {
        /// Nothing to change.
        case none
        /// Upload the outbox / the latest grant (`POST /v1/profile/consents`), then retry the failed
        /// call once. Allowed once per process per account.
        case reuploadThenRetryOnce
        /// Stop: the re-upload was already spent this process (or the reason is unknown).
        case stop
        /// Another device withdrew: `SGConsentStore.markWithdrawnRemote`; stop profile/events/tasks
        /// traffic and drop the event queue; required mode shows the wall.
        case markWithdrawnRemote(effectiveAt: String, consentId: String?)
        /// `SGConsentStore.markNeedsReconsent(notice:)`.
        case markNeedsReconsent(SGConsentStoredNotice)
    }

    /// What a `POST /v1/profile/consents` 200 means for the account.
    public struct ConsentsResult: Equatable {
        /// `recorded` | `duplicate` | `superseded`: `SGConsentStore.markAcked`.
        public let acked: [String]
        public let action: Action
    }

    /// What a terminal answer (422 any code, 409 `profile_account_mismatch`, another 4xx) to a
    /// consents request means for its entries.
    public enum TerminalAction: Equatable {
        /// `SGConsentStore.markRejected(id:code:)`: the grant is never sent again.
        case markRejected(consentId: String, code: String)
        /// A withdraw is never rejected: it stays in the outbox; log the code (a client bug).
        case keep(SGCustomerLogCode)
        /// The entry the error names cannot be told (several sent, no `field`): nothing is marked.
        case unattributed
    }

    /// 403 `consent_required` on `/v1/profile/sync` or `/v1/profile/events` (C§6.3), for an account
    /// whose local state is `granted` (any other state changes nothing). `didReuploadThisProcess` is
    /// the caller's per-process, per-account memory of a re-upload already spent.
    public static func onConsentRequired(_ extras: SGConsentRequiredExtras, record: SGConsentRecord?, didReuploadThisProcess: Bool) -> Action {
        guard let record, record.state == .granted else {
            return .none
        }
        let reupload: Action = didReuploadThisProcess ? .stop : .reuploadThenRetryOnce
        switch extras.reason {
        case .noConsent:
            return reupload
        case .withdrawn:
            if let consent = extras.consent, let effectiveAt = consent.effectiveAt, SGConsentReconciler.isNewer(effectiveAt, than: record.decidedAt) {
                return .markWithdrawnRemote(effectiveAt: effectiveAt, consentId: consent.consentId)
            }
            return reupload
        case .reconsentRequired:
            return .markNeedsReconsent(.reconsent)
        case .unknown:
            return .stop
        }
    }

    /// A `POST /v1/profile/consents` 200 for the entries `sent` (C§6.3, design 40 §4.7): every
    /// `recorded` / `duplicate` / `superseded` result is acked. Then, for an account whose local
    /// state is `granted`:
    /// - a newer remote withdraw (`consent.state == withdrawn`, `effective_at` after the local
    ///   decision) → `markWithdrawnRemote`;
    /// - the current grant answered `duplicate` or `recorded` while the effective state is `none`, or
    ///   marked `foreign` (amendment A4): the `consent_id` belongs to another (erased) account and is
    ///   never effective here → `markNeedsReconsent(.linkEnded)`.
    public static func onConsentsResponse(_ response: SGConsentsResponse, sent: [SGConsentEvent], record: SGConsentRecord?) -> ConsentsResult {
        let sentIds = Set(sent.map(\.consentId))
        let acked = response.results.filter { sentIds.contains($0.consentId) }.map(\.consentId)
        guard let record, record.state == .granted, let grantId = record.consentId else {
            return ConsentsResult(acked: acked, action: .none)
        }
        if let consent = response.consent, consent.state == .withdrawn, consent.consentId.map(sentIds.contains) != true,
           let effectiveAt = consent.effectiveAt, SGConsentReconciler.isNewer(effectiveAt, than: record.decidedAt) {
            return ConsentsResult(acked: acked, action: .markWithdrawnRemote(effectiveAt: effectiveAt, consentId: consent.consentId))
        }
        let grantSent = sent.contains { $0.consentId == grantId && $0.action == .grant }
        if grantSent, let result = response.results.first(where: { $0.consentId == grantId }) {
            let effectiveNone = response.consent?.state == SGEffectiveConsent.State.none
            if result.foreign || ((result.outcome == .duplicate || result.outcome == .recorded) && effectiveNone) {
                return ConsentsResult(acked: acked, action: .markNeedsReconsent(.linkEnded))
            }
        }
        return ConsentsResult(acked: acked, action: .none)
    }

    /// A terminal answer to a consents request (design 40 §4.7): the request held one entry (the
    /// planner sends one per request), so that entry is meant; with several, the error's `field`
    /// (`consents[N]…`) names it. A grant is marked rejected with `code` (`http_<status>` when the
    /// body had none); a withdraw is kept and its code logged.
    public static func onConsentsTerminal(status: Int, code: String?, field: String?, sent: [SGConsentEvent]) -> TerminalAction {
        let entry: SGConsentEvent
        if sent.count == 1 {
            entry = sent[0]
        } else if let index = SGConsentReconciler.consentIndex(field), sent.indices.contains(index) {
            entry = sent[index]
        } else {
            return .unattributed
        }
        let stableCode = code.flatMap { SGCustomerLogCode.isStableCode($0) ? $0 : nil } ?? "http_\(status)"
        switch entry.action {
        case .grant:
            return .markRejected(consentId: entry.consentId, code: stableCode)
        case .withdraw:
            return .keep(SGCustomerLogCode.server(stableCode))
        }
    }

    /// 409 `consent_stale` on `/bind/start` (contract amendment A3; the automatic and the manual
    /// path alike): a `granted` record — the grant `/bind/start` carried, when `consentId` names it —
    /// becomes `needs_reconsent` / `link_ended`. Applied by `SGConsentStore.normaliseAfterConsentStale`.
    public static func onBindConsentStale(record: SGConsentRecord?, consentId: String?) -> Action {
        guard let record, record.state == .granted else {
            return .none
        }
        if let consentId, consentId != record.consentId {
            return .none
        }
        return .markNeedsReconsent(.linkEnded)
    }

    /// `remote` is strictly later than the local decision (a missing local time is older).
    static func isNewer(_ remote: String, than local: String?) -> Bool {
        guard let remoteDate = SGCustomerTime.date(fromInstant: remote) else {
            return false
        }
        guard let local, let localDate = SGCustomerTime.date(fromInstant: local) else {
            return true
        }
        return remoteDate > localDate
    }

    /// `N` of an error `field` such as `consents[1].text_sha256`.
    static func consentIndex(_ field: String?) -> Int? {
        guard let field, field.hasPrefix("consents["), let close = field.firstIndex(of: "]") else {
            return nil
        }
        let start = field.index(field.startIndex, offsetBy: "consents[".count)
        guard start < close else {
            return nil
        }
        return Int(field[start ..< close])
    }
}
