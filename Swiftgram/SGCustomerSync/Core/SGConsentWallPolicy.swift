import Foundation

/// Zenlygram — the notice line of the wall or prompt (design 40 §5.3, U§1).
public enum SGConsentWallNotice: Equatable {
    /// First ask (state `none`, or a legacy `declined` in a required build): no notice.
    case none
    /// This device erased the account (`AccountDelete.Done.*`).
    case deleted
    /// The server ended this account's binding (`Consent.Wall.Notice.LinkEnded`).
    case linkEnded
    /// The granted version was retired (`Consent.Wall.Notice.Reconsent`).
    case reconsent
    /// This build renders the granted text with other operator values (`Consent.Wall.Notice.Reconsent`).
    case operatorChanged
    /// Withdrawn on this device (`Consent.Wall.Notice.Withdrawn`).
    case withdrawn
    /// Withdrawn on another device (`Consent.Wall.Notice.WithdrawnRemote`).
    case withdrawnRemote

    init(_ stored: SGConsentStoredNotice?) {
        switch stored {
        case .operatorChanged:
            self = .operatorChanged
        case .linkEnded:
            self = .linkEnded
        case .reconsent, .none:
            self = .reconsent
        }
    }
}

/// Zenlygram — what the account's root shows (design 40 §4.6).
public enum SGConsentWallPresentation: Equatable {
    /// Unreadable store (a launch before the first unlock): decide again on
    /// `protectedDataDidBecomeAvailable` / foreground. Nothing is shown or written.
    case deferred
    /// Nothing.
    case none
    /// The blocking wall (required mode).
    case wall(SGConsentWallNotice)
    /// The dismissable prompt (optional mode).
    case prompt(SGConsentWallNotice)
    /// The bundled text itself is retired: no text and no Agree, the rights rows stay (required mode).
    case textUnavailable
}

/// Zenlygram — the inputs of the wall decision, all local (UserDefaults, the session item and the
/// bundled manifest; never the network).
public struct SGConsentWallInputs: Equatable {
    public var mode: SGConsentMode
    /// `UIApplication.isProtectedDataAvailable` and the store's canary read.
    public var readable: Bool
    /// nil = `none`.
    public var record: SGConsentRecord?
    /// `zg.cs.notice.v1.<tg>`: why the record is `needs_reconsent`.
    public var storedNotice: SGConsentStoredNotice?
    public var bundledCurrentVersion: Int
    public var bundledMinValidVersion: Int
    /// This build's `text_sha256` for (record `text_version`, record `locale`); nil when that version
    /// is not bundled (or there is no record).
    public var renderedSha256ForRecord: String?
    /// The code the server rejected the latest grant with (`SGConsentStore.latestGrantRejection`).
    public var latestGrantRejection: String?
    /// The server ended the binding this grant linked and it was not handled yet (design 40 §8.1).
    public var linkEnded: Bool
    /// This device erased the account and the done text was not shown yet.
    public var deletedNotice: Bool

    public init(mode: SGConsentMode, readable: Bool, record: SGConsentRecord?, storedNotice: SGConsentStoredNotice?, bundledCurrentVersion: Int, bundledMinValidVersion: Int, renderedSha256ForRecord: String?, latestGrantRejection: String?, linkEnded: Bool, deletedNotice: Bool) {
        self.mode = mode
        self.readable = readable
        self.record = record
        self.storedNotice = storedNotice
        self.bundledCurrentVersion = bundledCurrentVersion
        self.bundledMinValidVersion = bundledMinValidVersion
        self.renderedSha256ForRecord = renderedSha256ForRecord
        self.latestGrantRejection = latestGrantRejection
        self.linkEnded = linkEnded
        self.deletedNotice = deletedNotice
    }
}

/// Zenlygram — the decision and, when a `granted` record must be asked again, the normalisation the
/// presenter persists (`SGConsentStore.markNeedsReconsent`, only while readable).
public struct SGConsentWallDecision: Equatable {
    public let presentation: SGConsentWallPresentation
    /// `granted → needs_reconsent` with this notice.
    public let normalise: SGConsentStoredNotice?

    public init(presentation: SGConsentWallPresentation, normalise: SGConsentStoredNotice? = nil) {
        self.presentation = presentation
        self.normalise = normalise
    }
}

/// Zenlygram — the wall decision table (design 40 §4.6), evaluated top-down.
///
/// | # | Condition | Required | Optional | Normalise |
/// |---|---|---|---|---|
/// | 1 | unreadable | deferred | deferred | — |
/// | 2 | deleted notice | wall(deleted) | none | — |
/// | 3 | granted, link ended | wall(linkEnded) | prompt(linkEnded) | link_ended |
/// | 4 | granted, rejected `consent_version_retired`, version ≥ bundled current | textUnavailable | none | — |
/// | 5 | granted, version < bundled min, or rejected `consent_version_retired` | wall(reconsent) | prompt(reconsent) | reconsent |
/// | 6 | granted, this build renders the record's text with another hash | wall(operatorChanged) | prompt(operatorChanged) | operator_changed |
/// | 7 | granted (other rejections stay usable; Settings shows them) | none | none | — |
/// | 8 | none / declined | wall(none) | none → prompt(none), declined → none | — |
/// | 9 | withdrawn / withdrawn_remote | wall(withdrawn / withdrawnRemote) | none | — |
/// | 10 | needs_reconsent | wall(stored notice) | prompt(stored notice) | — |
public enum SGConsentWallPolicy {
    public static let versionRetiredCode = "consent_version_retired"

    public static func decide(_ inputs: SGConsentWallInputs) -> SGConsentWallDecision {
        let required = inputs.mode == .required
        func ask(_ notice: SGConsentWallNotice, normalise: SGConsentStoredNotice? = nil) -> SGConsentWallDecision {
            return SGConsentWallDecision(presentation: required ? .wall(notice) : .prompt(notice), normalise: normalise)
        }
        guard inputs.readable else {
            return SGConsentWallDecision(presentation: .deferred)
        }
        if inputs.deletedNotice {
            return SGConsentWallDecision(presentation: required ? .wall(.deleted) : .none)
        }
        let state = inputs.record?.state ?? SGConsentState.none
        switch state {
        case .granted:
            let version = inputs.record?.textVersion ?? 0
            let retired = inputs.latestGrantRejection == SGConsentWallPolicy.versionRetiredCode
            if inputs.linkEnded {
                return ask(.linkEnded, normalise: .linkEnded)
            }
            if retired && version >= inputs.bundledCurrentVersion {
                return SGConsentWallDecision(presentation: required ? .textUnavailable : .none)
            }
            if version < inputs.bundledMinValidVersion || retired {
                return ask(.reconsent, normalise: .reconsent)
            }
            if let rendered = inputs.renderedSha256ForRecord, rendered != inputs.record?.textSha256 {
                return ask(.operatorChanged, normalise: .operatorChanged)
            }
            return SGConsentWallDecision(presentation: .none)
        case .none:
            return ask(.none)
        case .declined:
            return SGConsentWallDecision(presentation: required ? .wall(.none) : .none)
        case .withdrawn:
            return SGConsentWallDecision(presentation: required ? .wall(.withdrawn) : .none)
        case .withdrawnRemote:
            return SGConsentWallDecision(presentation: required ? .wall(.withdrawnRemote) : .none)
        case .needsReconsent:
            return ask(SGConsentWallNotice(inputs.storedNotice))
        }
    }
}
