import Foundation

// MARK: Zenlygram — TEST-ONLY. The consent screens' preview scenarios (design 40 §15.6), Foundation only.
//
// Compiled into BOTH the preview module (`SGCustomerSyncViewsPreviewLib`, where
// `SGCustomerSyncPreviewScenarios.swift` gives each case its fixture state) and the UI test bundle
// (`SGCustomerSyncPreviewUITestsLib`), which launches the host with `-scenario <rawValue> -lang <uz|ru|en>` and checks
// what each case promises below. One list, so a scenario cannot exist in one and be missing from the other.

public enum SGCustomerSyncPreviewScenario: String, CaseIterable {
    // The wall (required builds).
    case wallNone
    case wallReconsent
    case wallOperatorChanged
    case wallLinkEnded
    case wallDeleted
    case wallTextUnavailable
    case wallSaveFailed
    case wallWithdrawnSending
    case wallWithdrawnDelivered
    case wallWithdrawnPending
    case wallWithdrawnUnlinked
    case wallWithdrawnRemote
    // The optional prompt.
    case promptNone
    case promptReconsent
    // The consent text page, the decline page, the rights page, and the screens pushed inside the wall.
    case wallText
    case declinedOneAccount
    case declinedTwoAccounts
    case declinedWithdrawable
    case rightsPage
    case wallMyData
    case wallDelete
    // Settings → Zenlygram → Data & consent, one per status.
    case dataGranted
    case dataPending
    case dataNone
    case dataDeclined
    case dataWithdrawn
    case dataSending
    case dataWithdrawPending
    case dataWithdrawUnlinked
    case dataReconsent
    case dataLinkEnded
    case dataRejected
    // The withdraw confirmation.
    case withdrawUnsentOne
    case withdrawUnsentFew
    case withdrawUnsentMany
    case withdrawUnsentUnknown
    case withdrawOptional
    case withdrawUnlinked
    // The deletion (Settings).
    case deleteLinked
    case deleteBilling
    case deleteUnlinked
    case deleteSending
    case deleteFailed
    case deleteRateLimited
    case deleteDone
    // My data (Settings).
    case myDataLoaded
    case myDataError
    case myDataNotLinked

    public enum Screen: Equatable {
        case wall
        case prompt
        case dataConsent
        case withdrawAlert
        case delete
        case myData
    }

    /// The scenarios' fixed clock and decision time, so every date renders the same on every run.
    public static let referenceNow = Date(timeIntervalSince1970: 1_790_000_000)
    public static let decisionDate = Date(timeIntervalSince1970: 1_790_000_000 - 2 * 86_400)
    /// The zone the consent screens show decision dates in (ui-strings §3).
    public static let decisionTimeZone = "Asia/Tashkent"
    /// The wall's account line value (`Consent.Wall.Account`).
    public static let accountLine = "Preview User"
    /// The Telegram id of the My data fixture.
    public static let telegramUserId: Int64 = 100_000_001

    public var screen: Screen {
        switch self {
        case .wallNone, .wallReconsent, .wallOperatorChanged, .wallLinkEnded, .wallDeleted, .wallTextUnavailable, .wallSaveFailed,
             .wallWithdrawnSending, .wallWithdrawnDelivered, .wallWithdrawnPending, .wallWithdrawnUnlinked, .wallWithdrawnRemote,
             .wallText, .declinedOneAccount, .declinedTwoAccounts, .declinedWithdrawable, .rightsPage, .wallMyData, .wallDelete:
            return .wall
        case .promptNone, .promptReconsent:
            return .prompt
        case .dataGranted, .dataPending, .dataNone, .dataDeclined, .dataWithdrawn, .dataSending, .dataWithdrawPending,
             .dataWithdrawUnlinked, .dataReconsent, .dataLinkEnded, .dataRejected:
            return .dataConsent
        case .withdrawUnsentOne, .withdrawUnsentFew, .withdrawUnsentMany, .withdrawUnsentUnknown, .withdrawOptional, .withdrawUnlinked:
            return .withdrawAlert
        case .deleteLinked, .deleteBilling, .deleteUnlinked, .deleteSending, .deleteFailed, .deleteRateLimited, .deleteDone:
            return .delete
        case .myDataLoaded, .myDataError, .myDataNotLinked:
            return .myData
        }
    }

    /// The consent page of the wall or the prompt is on screen (the age checkbox and the two buttons).
    public var showsDecision: Bool {
        switch self {
        case .wallNone, .wallReconsent, .wallOperatorChanged, .wallLinkEnded, .wallDeleted, .wallSaveFailed, .wallWithdrawnSending,
             .wallWithdrawnDelivered, .wallWithdrawnPending, .wallWithdrawnUnlinked, .wallWithdrawnRemote, .promptNone, .promptReconsent:
            return true
        default:
            return false
        }
    }

    /// The element every scenario shows once rendered (the withdraw confirmation is checked as an alert instead).
    public var rootIdentifier: String {
        switch self.screen {
        case .wall, .prompt:
            return "zg.consent.wall"
        case .dataConsent, .withdrawAlert:
            return "zg.data"
        case .delete:
            return "zg.delete"
        case .myData:
            return "zg.mydata"
        }
    }

    /// The consent page with a text: the summary paragraph and the "Consent text" row, never the text itself.
    private static let consentPage = ["zg.consent.page", "zg.consent.title", "zg.consent.account", "zg.consent.summary", "zg.consent.text", "zg.consent.rights"]
    /// What the consent page never shows: the language control and the document live on the text page.
    private static let consentPageAbsent = ["zg.consent.lang", "zg.consent.text.page", "zg.consent.text.back", "zg.consent.text.body"]
    private static let decision = ["zg.consent.age", "zg.consent.agehint", "zg.consent.modenote", "zg.consent.agree", "zg.consent.decline"]
    /// The text page: Back, the language control and the full document; no decision, no summary, no row.
    private static let textPage = ["zg.consent.wall", "zg.consent.text.page", "zg.consent.text.back", "zg.consent.lang", "zg.consent.text.body"]
    private static let dataRows = ["zg.data.status", "zg.data.text", "zg.data.mydata", "zg.data.delete", "zg.data.policy", "zg.data.operator", "zg.data.storage", "zg.data.footer"]

    /// Every `zg.*` identifier the scenario must show.
    public var presentIdentifiers: [String] {
        switch self {
        case .wallNone:
            return ["zg.consent.wall"] + Self.consentPage + Self.decision
        case .wallReconsent, .wallOperatorChanged, .wallLinkEnded, .wallDeleted, .wallWithdrawnDelivered, .wallWithdrawnRemote:
            return ["zg.consent.wall", "zg.consent.notice"] + Self.consentPage + Self.decision
        case .wallSaveFailed:
            return ["zg.consent.wall", "zg.consent.savefailed"] + Self.consentPage + Self.decision
        case .wallTextUnavailable:
            return ["zg.consent.wall", "zg.consent.textunavailable", "zg.consent.page", "zg.consent.title", "zg.consent.account", "zg.consent.rights"]
        case .wallWithdrawnSending:
            return ["zg.consent.wall", "zg.consent.notice", "zg.consent.withdraw.status"] + Self.consentPage + Self.decision
        case .wallWithdrawnPending:
            return ["zg.consent.wall", "zg.consent.notice", "zg.consent.withdraw.status", "zg.consent.withdraw.retry"] + Self.consentPage + Self.decision
        case .wallWithdrawnUnlinked:
            return ["zg.consent.wall", "zg.consent.notice", "zg.consent.withdraw.status", "zg.consent.withdraw.web"] + Self.consentPage + Self.decision
        case .promptNone:
            return ["zg.consent.wall", "zg.consent.close"] + Self.consentPage + Self.decision
        case .promptReconsent:
            return ["zg.consent.wall", "zg.consent.close", "zg.consent.notice"] + Self.consentPage + Self.decision
        case .wallText:
            return Self.textPage
        case .declinedOneAccount:
            return ["zg.consent.wall", "zg.consent.declined", "zg.consent.declined.back", "zg.consent.declined.logout", "zg.consent.rights.delete", "zg.consent.rights.mydata", "zg.consent.rights.policy"]
        case .declinedTwoAccounts:
            return ["zg.consent.wall", "zg.consent.declined", "zg.consent.declined.back", "zg.consent.declined.logout", "zg.consent.declined.switch", "zg.consent.rights.delete", "zg.consent.rights.mydata", "zg.consent.rights.policy"]
        case .declinedWithdrawable:
            return ["zg.consent.wall", "zg.consent.declined", "zg.consent.declined.back", "zg.consent.declined.logout", "zg.consent.rights.delete", "zg.consent.rights.mydata", "zg.consent.rights.withdraw", "zg.consent.rights.policy"]
        case .rightsPage:
            return ["zg.consent.wall", "zg.consent.rights.page", "zg.consent.rights.back", "zg.consent.rights.mydata", "zg.consent.rights.delete", "zg.consent.rights.policy"]
        case .wallMyData:
            return ["zg.consent.wall", "zg.mydata", "zg.mydata.back", "zg.mydata.tgid", "zg.mydata.consent"]
        case .wallDelete:
            return ["zg.consent.wall", "zg.delete", "zg.delete.back", "zg.delete.billing", "zg.delete.manage", "zg.delete.action"]
        case .dataGranted, .dataPending:
            return Self.dataRows + ["zg.data.withdraw"]
        case .dataNone, .dataDeclined, .dataWithdrawn, .dataSending:
            return Self.dataRows + ["zg.data.grant"]
        case .dataWithdrawPending:
            return Self.dataRows + ["zg.data.grant", "zg.data.retry"]
        case .dataWithdrawUnlinked:
            return Self.dataRows + ["zg.data.grant", "zg.data.web"]
        case .dataReconsent, .dataLinkEnded, .dataRejected:
            return Self.dataRows + ["zg.data.grant", "zg.data.withdraw"]
        case .withdrawUnsentOne, .withdrawUnsentFew, .withdrawUnsentMany, .withdrawUnsentUnknown, .withdrawOptional, .withdrawUnlinked:
            // The alert is modal: what is under it is not in the accessibility tree.
            return []
        case .deleteLinked, .deleteBilling:
            return ["zg.delete", "zg.delete.billing", "zg.delete.manage", "zg.delete.action"]
        case .deleteUnlinked:
            return ["zg.delete", "zg.delete.notlinked", "zg.delete.web"]
        case .deleteSending:
            return ["zg.delete", "zg.delete.billing", "zg.delete.action", "zg.delete.sending"]
        case .deleteFailed:
            return ["zg.delete", "zg.delete.billing", "zg.delete.error", "zg.delete.web", "zg.delete.action"]
        case .deleteRateLimited:
            return ["zg.delete", "zg.delete.billing", "zg.delete.error", "zg.delete.action"]
        case .deleteDone:
            return ["zg.delete", "zg.delete.done", "zg.delete.done.ok"]
        case .myDataLoaded:
            return ["zg.mydata", "zg.mydata.tgid", "zg.mydata.consent"]
        case .myDataError:
            return ["zg.mydata", "zg.mydata.error", "zg.mydata.retry"]
        case .myDataNotLinked:
            return ["zg.mydata", "zg.mydata.notlinked"]
        }
    }

    /// `zg.*` identifiers the scenario must NOT show.
    public var absentIdentifiers: [String] {
        switch self {
        case .wallNone:
            return ["zg.consent.notice", "zg.consent.close", "zg.consent.textunavailable", "zg.consent.savefailed", "zg.consent.withdraw.status"] + Self.consentPageAbsent
        case .wallReconsent, .wallOperatorChanged, .wallLinkEnded, .wallDeleted, .wallWithdrawnRemote:
            return ["zg.consent.close", "zg.consent.textunavailable", "zg.consent.withdraw.status"] + Self.consentPageAbsent
        case .wallWithdrawnDelivered:
            return ["zg.consent.close", "zg.consent.withdraw.status", "zg.consent.withdraw.retry", "zg.consent.withdraw.web"] + Self.consentPageAbsent
        case .wallWithdrawnSending:
            return ["zg.consent.withdraw.retry", "zg.consent.withdraw.web"] + Self.consentPageAbsent
        case .wallWithdrawnPending:
            return ["zg.consent.withdraw.web"] + Self.consentPageAbsent
        case .wallWithdrawnUnlinked:
            return ["zg.consent.withdraw.retry"] + Self.consentPageAbsent
        case .wallSaveFailed:
            return ["zg.consent.close"] + Self.consentPageAbsent
        case .wallTextUnavailable:
            return ["zg.consent.agree", "zg.consent.decline", "zg.consent.age", "zg.consent.modenote", "zg.consent.close", "zg.consent.summary", "zg.consent.text"] + Self.consentPageAbsent
        case .promptNone:
            return ["zg.consent.notice", "zg.consent.textunavailable"] + Self.consentPageAbsent
        case .promptReconsent:
            return ["zg.consent.textunavailable"] + Self.consentPageAbsent
        case .wallText:
            return ["zg.consent.page", "zg.consent.summary", "zg.consent.text", "zg.consent.age", "zg.consent.agree", "zg.consent.decline", "zg.consent.modenote", "zg.consent.rights", "zg.consent.textunavailable"]
        case .declinedOneAccount:
            return ["zg.consent.declined.switch", "zg.consent.rights.withdraw", "zg.consent.agree"]
        case .declinedTwoAccounts:
            return ["zg.consent.rights.withdraw", "zg.consent.agree"]
        case .declinedWithdrawable:
            return ["zg.consent.declined.switch", "zg.consent.agree"]
        case .rightsPage:
            return ["zg.consent.rights.withdraw", "zg.consent.declined", "zg.consent.agree"]
        case .wallMyData:
            return ["zg.mydata.error", "zg.consent.agree"]
        case .wallDelete:
            return ["zg.delete.done", "zg.delete.notlinked", "zg.consent.agree"]
        case .dataGranted, .dataPending:
            return ["zg.data.grant", "zg.data.retry", "zg.data.web", "zg.data.resetdebug"]
        case .dataNone, .dataDeclined, .dataWithdrawn, .dataSending:
            return ["zg.data.withdraw", "zg.data.retry", "zg.data.web", "zg.data.resetdebug"]
        case .dataWithdrawPending:
            return ["zg.data.withdraw", "zg.data.web", "zg.data.resetdebug"]
        case .dataWithdrawUnlinked:
            return ["zg.data.withdraw", "zg.data.retry", "zg.data.resetdebug"]
        case .dataReconsent, .dataLinkEnded, .dataRejected:
            return ["zg.data.retry", "zg.data.web", "zg.data.resetdebug"]
        case .withdrawUnsentOne, .withdrawUnsentFew, .withdrawUnsentMany, .withdrawUnsentUnknown, .withdrawOptional, .withdrawUnlinked:
            return []
        case .deleteLinked, .deleteBilling:
            return ["zg.delete.error", "zg.delete.notlinked", "zg.delete.done", "zg.delete.back", "zg.delete.sending"]
        case .deleteUnlinked:
            return ["zg.delete.action", "zg.delete.done", "zg.delete.back"]
        case .deleteSending:
            return ["zg.delete.error", "zg.delete.done"]
        case .deleteFailed:
            return ["zg.delete.done", "zg.delete.notlinked"]
        case .deleteRateLimited:
            return ["zg.delete.web", "zg.delete.done"]
        case .deleteDone:
            return ["zg.delete.action", "zg.delete.error", "zg.delete.back"]
        case .myDataLoaded:
            return ["zg.mydata.error", "zg.mydata.loading", "zg.mydata.back"]
        case .myDataError:
            return ["zg.mydata.tgid", "zg.mydata.loading"]
        case .myDataNotLinked:
            return ["zg.mydata.tgid", "zg.mydata.error"]
        }
    }

    /// Captions (string table keys without placeholders) that must be on screen; compared case-insensitively
    /// (section headers are shown in upper case).
    public var presentKeys: [String] {
        switch self {
        case .wallNone, .wallReconsent, .wallOperatorChanged, .wallLinkEnded, .wallDeleted, .wallSaveFailed, .wallWithdrawnSending,
             .wallWithdrawnDelivered, .wallWithdrawnPending, .wallWithdrawnUnlinked, .wallWithdrawnRemote:
            return ["Consent.Wall.Title", "Consent.Wall.Summary", "DataConsent.ReadText", "Consent.Wall.AgeHint", "Consent.Wall.ModeNote.Required", "Consent.Wall.Agree", "Consent.Wall.Decline", "Settings.Data.Header"]
        case .wallTextUnavailable:
            return ["Consent.Wall.Title", "Consent.Wall.TextUnavailable", "Settings.Data.Header"]
        case .promptNone, .promptReconsent:
            return ["Consent.Wall.Title", "Consent.Wall.Summary", "DataConsent.ReadText", "Consent.Wall.ModeNote.Optional", "Consent.Wall.Agree", "Consent.Wall.Decline"]
        case .wallText:
            return ["DataConsent.ReadText", "Consent.Wall.Language", "Consent.Declined.Back"]
        case .declinedOneAccount, .declinedWithdrawable:
            return ["Consent.Declined.Title", "Consent.Declined.Text", "Consent.Declined.Back", "Consent.Declined.Delete", "Consent.Declined.Logout", "DataConsent.MyData", "Consent.Declined.PrivacyPolicy"]
        case .declinedTwoAccounts:
            return ["Consent.Declined.Title", "Consent.Declined.Back", "Consent.Declined.Delete", "Consent.Declined.Logout", "Consent.Declined.SwitchAccount"]
        case .rightsPage:
            return ["Settings.Data.Header", "DataConsent.MyData", "DataConsent.Delete", "Settings.Data.PrivacyPolicy", "Consent.Declined.Back"]
        case .wallMyData, .myDataLoaded:
            return ["MyData.Section.Account", "MyData.Field.TelegramId", "MyData.Section.Consent", "MyData.Section.Profile", "MyData.Field.Phone", "MyData.Section.Devices", "MyData.Section.Events", "MyData.Section.Retention"]
        case .wallDelete, .deleteLinked, .deleteBilling:
            return ["AccountDelete.Deleted", "AccountDelete.Kept", "AccountDelete.Telegram", "AccountDelete.Timing", "AccountDelete.ManageSubscription", "AccountDelete.Confirm"]
        case .dataGranted, .dataPending, .dataNone, .dataDeclined, .dataWithdrawn, .dataSending, .dataWithdrawPending, .dataWithdrawUnlinked,
             .dataReconsent, .dataLinkEnded, .dataRejected:
            return ["DataConsent.ReadText", "DataConsent.MyData", "DataConsent.Delete", "DataConsent.Storage", "DataConsent.Footer"]
        case .withdrawUnsentOne, .withdrawUnsentFew, .withdrawUnsentMany, .withdrawUnsentUnknown, .withdrawOptional, .withdrawUnlinked:
            // Checked on the alert itself (`withdrawal`).
            return []
        case .deleteUnlinked:
            return ["AccountDelete.NotLinked", "AccountDelete.OpenWeb"]
        case .deleteSending:
            return ["AccountDelete.Deleted", "AccountDelete.Confirm"]
        case .deleteFailed:
            return ["AccountDelete.Failed", "AccountDelete.OpenWeb", "AccountDelete.Confirm"]
        case .deleteRateLimited:
            return ["AccountDelete.Error.RateLimited", "AccountDelete.Confirm"]
        case .deleteDone:
            return ["AccountDelete.Done.Title", "AccountDelete.Done.Text", "Common.Close"]
        case .myDataError:
            return ["MyData.Error.Offline", "MyData.Retry"]
        case .myDataNotLinked:
            return ["MyData.NotLinked"]
        }
    }

    /// The wall's notice line: its key, and whether it carries the decision date.
    public var noticeKey: (key: String, dated: Bool)? {
        switch self {
        case .wallReconsent, .wallOperatorChanged, .promptReconsent:
            return ("Consent.Wall.Notice.Reconsent", false)
        case .wallLinkEnded:
            return ("Consent.Wall.Notice.LinkEnded", false)
        case .wallDeleted:
            return ("AccountDelete.Done.Title", false)
        case .wallWithdrawnSending, .wallWithdrawnDelivered, .wallWithdrawnPending, .wallWithdrawnUnlinked:
            return ("Consent.Wall.Notice.Withdrawn", true)
        case .wallWithdrawnRemote:
            return ("Consent.Wall.Notice.WithdrawnRemote", true)
        default:
            return nil
        }
    }

    /// Data & consent's status line: its key, whether it carries the decision date, and the text version.
    public var dataStatus: (key: String, dated: Bool, version: String?)? {
        switch self {
        case .dataGranted:
            return ("DataConsent.Status.Granted", true, "1")
        case .dataPending:
            return ("DataConsent.Status.Pending", false, nil)
        case .dataNone:
            return ("DataConsent.Status.None", false, nil)
        case .dataDeclined:
            return ("DataConsent.Status.Declined", false, nil)
        case .dataWithdrawn:
            return ("DataConsent.Status.Withdrawn", true, nil)
        case .dataSending:
            return ("DataConsent.Withdraw.Sending", false, nil)
        case .dataWithdrawPending:
            return ("DataConsent.Status.WithdrawPending", true, nil)
        case .dataWithdrawUnlinked:
            return ("DataConsent.Withdraw.PendingUpload", false, nil)
        case .dataReconsent:
            return ("DataConsent.Status.Reconsent", false, nil)
        case .dataLinkEnded:
            return ("DataConsent.Status.LinkEnded", false, nil)
        case .dataRejected:
            return ("DataConsent.Status.Rejected", false, nil)
        default:
            return nil
        }
    }

    /// The withdraw confirmation's inputs: unsent Tasks changes (nil = unknown), the build's mode, a binding here.
    public var withdrawal: (unsent: Int?, optional: Bool, linked: Bool)? {
        switch self {
        case .withdrawUnsentOne:
            return (1, false, true)
        case .withdrawUnsentFew:
            return (3, false, true)
        case .withdrawUnsentMany:
            return (5, false, true)
        case .withdrawUnsentUnknown:
            return (nil, false, true)
        case .withdrawOptional:
            return (0, true, true)
        case .withdrawUnlinked:
            return (0, false, false)
        default:
            return nil
        }
    }
}
