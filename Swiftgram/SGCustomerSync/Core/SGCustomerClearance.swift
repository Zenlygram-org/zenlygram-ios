import Foundation

/// Zenlygram — an account's clearance from PERSISTED state only (design 40 §6.4, Contract issue 19):
/// published at start and at every attach — at t = 0, offline or not — so a consented, linked,
/// synced account keeps Cloud Tasks after a relaunch without the network, and cleared at once on
/// withdrawal, deletion, a server-ended link and logout.
///
/// - `recordEvents` = readable ∧ `granted` ∧ the latest grant not rejected ∧ ¬erasing ∧ ¬link ended
///   ∧ the grant is not stale in this build;
/// - `uploadProfile` = `recordEvents` ∧ linked ∧ the latest grant acked at this authority ∧ the
///   current binding is not the one that answered `profile_account_not_linked`;
/// - `uploadEvents` = `uploadProfile` ∧ a profile receipt of the current binding;
/// - `tasksSync` = `uploadEvents` (events delivery is NOT a prerequisite: an events outage or a
///   24 h ingest pause never stalls Tasks, Contract issue 4).
/// The post-link consents re-upload marker (`consents_sent`) does not gate anything here.
///
/// "Stale in this build" is rows 5–6 of the wall policy (design 40 §4.6, contract §5.2): the
/// record's `text_version` is below the bundled `min_valid_version`, or this build renders the
/// record's text with another `text_sha256` (operator values changed). The wall persists that as
/// `needs_reconsent` only for an account whose root attached — the primary one — so every other
/// signed-in account is stopped here, from the same facts, until it becomes primary and is asked.
public enum SGCustomerClearance {
    public struct Inputs: Equatable {
        /// The consent store is readable (protected data, canary).
        public var readable: Bool
        /// The record's state (`none` when absent).
        public var state: SGConsentState
        /// The server refused the latest grant for good at this authority.
        public var latestGrantRejected: Bool
        /// A confirmed in-app deletion is not resolved (`zg.cs.delete…` present).
        public var erasing: Bool
        /// `SGCustomerLinkState.linkEnded(...)`: the server ended the binding this grant linked.
        public var linkEnded: Bool
        /// The current binding's `device_id` (`SGEntitlement.session(...).deviceId` while linked);
        /// nil = not linked.
        public var bindingDeviceId: String?
        /// The record's grant is acked at this authority.
        public var latestGrantAcked: Bool
        /// `zg.cs.not_linked…`: the binding that answered `profile_account_not_linked`.
        public var notLinkedDeviceId: String?
        /// `SGEntitlement.profileSyncReceipt(...)` exists (a bind clears it).
        public var hasProfileReceipt: Bool
        // The record against this build's consent texts (`staleGrantNotice`).
        /// The record's `text_version` (nil when absent).
        public var textVersion: Int?
        /// The record's `text_sha256` (nil when absent).
        public var textSha256: String?
        /// This build's bundled `min_valid_version`; nil = this build's texts were not given, so the
        /// version is not compared.
        public var bundledMinValidVersion: Int?
        /// This build's `text_sha256` for the record's (`text_version`, `locale`)
        /// (`renderedSha256(record:texts:operatorValues:)`); nil when that version is not bundled or
        /// the texts were not given, so the hashes are not compared.
        public var renderedSha256ForRecord: String?

        public init(readable: Bool, state: SGConsentState, latestGrantRejected: Bool, erasing: Bool, linkEnded: Bool, bindingDeviceId: String?, latestGrantAcked: Bool, notLinkedDeviceId: String?, hasProfileReceipt: Bool, textVersion: Int? = nil, textSha256: String? = nil, bundledMinValidVersion: Int? = nil, renderedSha256ForRecord: String? = nil) {
            self.readable = readable
            self.state = state
            self.latestGrantRejected = latestGrantRejected
            self.erasing = erasing
            self.linkEnded = linkEnded
            self.bindingDeviceId = bindingDeviceId
            self.latestGrantAcked = latestGrantAcked
            self.notLinkedDeviceId = notLinkedDeviceId
            self.hasProfileReceipt = hasProfileReceipt
            self.textVersion = textVersion
            self.textSha256 = textSha256
            self.bundledMinValidVersion = bundledMinValidVersion
            self.renderedSha256ForRecord = renderedSha256ForRecord
        }

        public var isLinked: Bool {
            return self.bindingDeviceId.map { !$0.isEmpty } ?? false
        }

        /// What the wall normalises a `granted` record to in this build (`SGConsentWallPolicy` rows
        /// 5–6): `.reconsent` when its `text_version` is below the bundled `min_valid_version` (no
        /// version reads as 0, as the wall reads it), `.operatorChanged` when this build renders its
        /// text with another hash; nil when it is current, or this build's texts were not given.
        public var staleGrantNotice: SGConsentStoredNotice? {
            if let minimum = self.bundledMinValidVersion, (self.textVersion ?? 0) < minimum {
                return .reconsent
            }
            if let rendered = self.renderedSha256ForRecord, rendered != self.textSha256 {
                return .operatorChanged
            }
            return nil
        }
    }

    public static func derive(_ inputs: Inputs) -> SGCustomerDataGate.Clearance {
        guard inputs.readable, inputs.state == .granted, !inputs.latestGrantRejected, !inputs.erasing, !inputs.linkEnded, inputs.staleGrantNotice == nil else {
            return []
        }
        var clearance: SGCustomerDataGate.Clearance = [.recordEvents]
        guard inputs.isLinked, inputs.latestGrantAcked, inputs.notLinkedDeviceId != inputs.bindingDeviceId else {
            return clearance
        }
        clearance.insert(.uploadProfile)
        if inputs.hasProfileReceipt {
            clearance.insert(.uploadEvents)
            clearance.insert(.tasksSync)
        }
        return clearance
    }

    /// The inputs of account `tg` as `store` holds them for `authority` (nil: no authenticated
    /// backend — nothing is acked, nothing erasing); the link facts come from SGEntitlement and
    /// `SGCustomerLinkState`. `texts` (this build's bundled tree) adds the version rule of
    /// `staleGrantNotice`, and `operatorValues` with it (`sg_config.consent_operator`) the hash rule.
    public static func inputs(store: SGConsentStore, tg: Int64, authority: String?, bindingDeviceId: String?, linkEnded: Bool, hasProfileReceipt: Bool, texts: SGConsentTextRepository? = nil, operatorValues: SGConsentOperatorValues? = nil) -> Inputs {
        let readable = store.isReadable
        let record = readable ? store.record(tg: tg) : nil
        let grantId = record?.state == .granted ? record?.consentId : nil
        var rendered: String?
        if let texts, let operatorValues {
            rendered = SGCustomerClearance.renderedSha256(record: record, texts: texts, operatorValues: operatorValues)
        }
        return Inputs(
            readable: readable,
            state: record?.state ?? .none,
            latestGrantRejected: authority.map { store.latestGrantRejection(tg: tg, authority: $0) != nil } ?? false,
            erasing: authority.map { store.isErasing(tg: tg, authority: $0) } ?? false,
            linkEnded: linkEnded,
            bindingDeviceId: bindingDeviceId.flatMap { $0.isEmpty ? nil : $0 },
            latestGrantAcked: authority.flatMap { authority in grantId.map { store.isAcked(tg: tg, authority: authority, consentId: $0) } } ?? false,
            notLinkedDeviceId: authority.flatMap { store.string(.notLinked(tg: tg, authority: $0)) },
            hasProfileReceipt: hasProfileReceipt,
            textVersion: record?.textVersion,
            textSha256: record?.textSha256,
            bundledMinValidVersion: texts?.minValidVersion,
            renderedSha256ForRecord: rendered
        )
    }

    /// `Inputs.renderedSha256ForRecord`: this build's `text_sha256` for a `granted` record's
    /// (`text_version`, `locale`), exactly as the wall computes it for row 6 — nil for any other
    /// state, a record without a version or locale, or a version this build does not bundle.
    public static func renderedSha256(record: SGConsentRecord?, texts: SGConsentTextRepository, operatorValues: SGConsentOperatorValues) -> String? {
        guard let record, record.state == .granted, let version = record.textVersion, let locale = record.locale else {
            return nil
        }
        return texts.renderedSha256(version: version, locale: locale, operatorValues: operatorValues)
    }
}
