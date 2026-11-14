import Foundation
import SwiftUI
import UIKit
import SGCustomerSyncCore

// MARK: Zenlygram — Settings → Zenlygram → Data & consent (design 40 §11.2, ui-strings §3): the account's consent
// status, the consent text it agreed to, My data, Give consent, Withdraw consent, the deletion and the privacy policy;
// the operator, where the data is stored, and that the screen is per Telegram account (`zg.data.*`). The status is
// derived here from the stored facts the app reads (`SGDataConsentFacts`), so the preview host shows exactly the
// app's mapping.

/// What the app reads about one account's consent (all local: the consent store, SGEntitlement's session, the
/// coordinator's in-flight state).
struct SGDataConsentFacts: Equatable {
    /// nil = `none`.
    var record: SGConsentRecord?
    /// Why the record is `needs_reconsent`.
    var storedNotice: SGConsentStoredNotice?
    /// The record's `consent_id` (the grant, or the withdrawal) is acked at the current authority.
    var recordAcked = false
    /// The code the server refused the latest grant with.
    var grantRejection: String?
    /// The server ended the binding this grant linked, not normalised yet (design 40 §8.1).
    var linkEnded = false
    /// This device holds a binding for the account.
    var isLinked = false
    /// The user-initiated withdraw send is running (shown for up to 10 s).
    var sending = false
    /// An un-acked withdraw is in the outbox.
    var hasPendingWithdraw = false
    /// This device erased the account and the done text was not shown yet.
    var deletedNotice = false

    var state: SGConsentState {
        return self.record?.state ?? SGConsentState.none
    }

    /// The record's decision time.
    var decidedAt: Date? {
        return self.record?.decidedAt.flatMap(SGCustomerTime.date(fromInstant:))
    }

    /// Withdraw is offered from `granted`, and from `needs_reconsent` while the server still holds the previous grant
    /// this device knows of (acked here; design 40 §5.4 rights rows, `SGConsentStore.withdraw`).
    var canWithdraw: Bool {
        switch self.state {
        case .granted:
            return true
        case .needsReconsent:
            return self.recordAcked
        default:
            return false
        }
    }

    /// Give consent is offered while there is no usable grant (optional builds; a refused or ended grant in either).
    var canGrant: Bool {
        return self.state != .granted || self.grantRejection != nil || self.linkEnded
    }

    /// A withdrawal made on this device: where its delivery stands.
    var withdrawalDelivery: SGWithdrawalDelivery? {
        guard self.state == .withdrawn else {
            return nil
        }
        return SGWithdrawalDelivery.derive(acked: self.recordAcked, isLinked: self.isLinked, sending: self.sending)
    }
}

/// The status line of Data & consent (ui-strings §3; `.sending` and `.withdrawPending` are the 40 additions).
enum SGDataConsentStatus: Equatable {
    case granted(Date?, version: Int)
    /// A grant not acked yet.
    case pending
    case none
    case declined
    /// An acked withdrawal, or one made on another device.
    case withdrawn(Date?)
    case sending
    /// Not acked yet while a binding exists: the app keeps trying (+ Retry).
    case withdrawPending(Date?)
    /// No binding on this device: it cannot be sent from here (+ the web page).
    case withdrawNotLinked
    case reconsent
    case linkEnded
    /// A terminal 422 on the grant.
    case rejected

    static func derive(_ facts: SGDataConsentFacts) -> SGDataConsentStatus {
        switch facts.state {
        case .none:
            return .none
        case .declined:
            return .declined
        case .granted:
            if facts.grantRejection != nil {
                return .rejected
            }
            if facts.linkEnded {
                return .linkEnded
            }
            return facts.recordAcked ? .granted(facts.decidedAt, version: facts.record?.textVersion ?? 1) : .pending
        case .withdrawn:
            switch facts.withdrawalDelivery ?? .delivered {
            case .delivered:
                return .withdrawn(facts.decidedAt)
            case .sending:
                return .sending
            case .pending:
                return .withdrawPending(facts.decidedAt)
            case .notLinked:
                return .withdrawNotLinked
            }
        case .withdrawnRemote:
            return .withdrawn(facts.decidedAt)
        case .needsReconsent:
            return facts.storedNotice == .linkEnded ? .linkEnded : .reconsent
        }
    }

    func text(_ c: SGCustomerCaptions) -> String {
        switch self {
        case let .granted(date, version):
            return SGCustomerSyncFormat.sentence(c("DataConsent.Status.Granted", SGCustomerSyncFormat.decisionDate(date, lang: c.lang), "\(version)"))
        case .pending:
            return c("DataConsent.Status.Pending")
        case .none:
            return c("DataConsent.Status.None")
        case .declined:
            return c("DataConsent.Status.Declined")
        case let .withdrawn(date):
            return SGCustomerSyncFormat.sentence(c("DataConsent.Status.Withdrawn", SGCustomerSyncFormat.decisionDate(date, lang: c.lang)))
        case .sending:
            return c("DataConsent.Withdraw.Sending")
        case let .withdrawPending(date):
            return SGCustomerSyncFormat.sentence(c("DataConsent.Status.WithdrawPending", SGCustomerSyncFormat.decisionDate(date, lang: c.lang)))
        case .withdrawNotLinked:
            return c("DataConsent.Withdraw.PendingUpload")
        case .reconsent:
            return c("DataConsent.Status.Reconsent")
        case .linkEnded:
            return c("DataConsent.Status.LinkEnded")
        case .rejected:
            return c("DataConsent.Status.Rejected")
        }
    }
}

final class SGDataConsentViewModel: ObservableObject {
    struct Actions {
        var readText: () -> Void = {}
        var myData: () -> Void = {}
        var grant: () -> Void = {}
        var withdraw: () -> Void = {}
        var delete: () -> Void = {}
        var privacyPolicy: () -> Void = {}
        /// Retry of a withdrawal that did not reach the server.
        var retry: () -> Void = {}
        var openURL: (URL) -> Void = { _ in }
        var resetDebug: () -> Void = {}
        var appeared: () -> Void = {}
    }

    @Published var facts: SGDataConsentFacts
    let lang: String
    /// `DataConsent.Operator`: the decoded name and e-mail (the literal placeholders on a local build).
    let operatorName: String
    let operatorEmail: String
    let hasPrivacyPolicy: Bool
    /// DEBUG builds only (`DataConsent.ResetDebug`).
    let showsDebugReset: Bool
    var actions = Actions()
    /// What the app keeps alive with this screen (observers).
    var lifetime: [AnyObject] = []

    init(lang: String, facts: SGDataConsentFacts, operatorName: String, operatorEmail: String, hasPrivacyPolicy: Bool, showsDebugReset: Bool) {
        self.lang = lang
        self.facts = facts
        self.operatorName = operatorName
        self.operatorEmail = operatorEmail
        self.hasPrivacyPolicy = hasPrivacyPolicy
        self.showsDebugReset = showsDebugReset
    }

    var status: SGDataConsentStatus {
        return SGDataConsentStatus.derive(self.facts)
    }
}

struct SGDataConsentView: View {
    @ObservedObject var model: SGDataConsentViewModel

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        let facts = self.model.facts
        let status = self.model.status
        return SGCustomerPage(identifier: "zg.data") {
            SGCustomerSection {
                SGDataConsentStatusCard(status: status, c: c, actions: self.model.actions)
            }
            SGCustomerSection {
                SGCustomerRowButton(title: c("DataConsent.ReadText"), identifier: "zg.data.text", action: self.model.actions.readText)
                SGCustomerRowDivider()
                SGCustomerRowButton(title: c("DataConsent.MyData"), identifier: "zg.data.mydata", action: self.model.actions.myData)
                if facts.canGrant {
                    SGCustomerRowDivider()
                    SGCustomerRowButton(title: c("DataConsent.Grant"), identifier: "zg.data.grant", role: .link, action: self.model.actions.grant)
                }
                if facts.canWithdraw {
                    SGCustomerRowDivider()
                    SGCustomerRowButton(title: c("DataConsent.Withdraw"), identifier: "zg.data.withdraw", action: self.model.actions.withdraw)
                }
                SGCustomerRowDivider()
                SGCustomerRowButton(title: c("DataConsent.Delete"), identifier: "zg.data.delete", role: .destructive, action: self.model.actions.delete)
                if self.model.hasPrivacyPolicy {
                    SGCustomerRowDivider()
                    SGCustomerRowButton(title: c("Settings.Data.PrivacyPolicy"), identifier: "zg.data.policy", role: .link, action: self.model.actions.privacyPolicy)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SGCustomerParagraph(text: c("DataConsent.Operator", self.model.operatorName, self.model.operatorEmail), font: .footnote, color: .secondary, identifier: "zg.data.operator")
                SGCustomerParagraph(text: c("DataConsent.Storage"), font: .footnote, color: .secondary, identifier: "zg.data.storage")
                SGCustomerParagraph(text: c("DataConsent.Footer"), font: .footnote, color: .secondary, identifier: "zg.data.footer")
            }
            .padding(.horizontal, 16)
            if self.model.showsDebugReset {
                SGCustomerSection {
                    SGCustomerRowButton(title: c("DataConsent.ResetDebug"), identifier: "zg.data.resetdebug", role: .destructive, action: self.model.actions.resetDebug)
                }
            }
        }
        .onAppear(perform: self.model.actions.appeared)
    }
}

private struct SGDataConsentStatusCard: View {
    let status: SGDataConsentStatus
    let c: SGCustomerCaptions
    let actions: SGDataConsentViewModel.Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if self.status == .sending {
                    SGCustomerSpinner()
                }
                SGCustomerParagraph(text: self.status.text(self.c), identifier: "zg.data.status")
            }
            if case .withdrawPending = self.status {
                Button(action: self.actions.retry) {
                    Text(verbatim: self.c("MyData.Retry"))
                        .foregroundColor(.accentColor)
                        .frame(minHeight: 44)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibility(identifier: "zg.data.retry")
            }
            if self.status == .withdrawNotLinked {
                Button(action: {
                    self.actions.openURL(sgCustomerDeletionPageURL)
                }) {
                    Text(verbatim: self.c("AccountDelete.OpenWeb"))
                        .foregroundColor(.accentColor)
                        .frame(minHeight: 44)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibility(identifier: "zg.data.web")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The consent text as recorded (Data & consent → Consent text): read only, no checkbox, no decision.
struct SGConsentTextPage: View {
    let document: SGConsentDocument
    let openURL: (URL) -> Void

    var body: some View {
        SGCustomerPage(identifier: "zg.data.textpage") {
            SGConsentTextView(blocks: self.document.blocks, openURL: self.openURL)
        }
    }
}
