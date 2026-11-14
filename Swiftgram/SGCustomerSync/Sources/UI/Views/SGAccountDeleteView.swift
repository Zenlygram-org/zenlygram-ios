import Foundation
import SwiftUI
import UIKit
import SGCustomerSyncCore

// MARK: Zenlygram — "Delete my Zenlygram account and data" (design 40 §11.4, ui-strings §5; Apple "Offering account
// deletion"): what is deleted and what is kept, that the Telegram account stays, the timing, the subscription notice
// (emphasised when a StoreKit subscription is known here) with Apple's management page, and a second confirmation. The
// outcome comes from the core's deletion state machine (`SGCustomerDeletion.Report`), mapped by the app. Not linked on
// this device → `AccountDelete.NotLinked` with the web page, and no call. Reached from Data & consent and from the
// wall's decline and rights rows (`zg.delete.*`).

final class SGAccountDeleteViewModel: ObservableObject {
    enum Failure: Equatable {
        /// `AccountDelete.Failed` (+ the web page): nothing was deleted.
        case failed
        /// `AccountDelete.Error.Offline` (+ the web page): the request is sent again with the same key.
        case offline
        /// `AccountDelete.Error.Unavailable` (+ the web page).
        case unavailable
        /// `AccountDelete.Error.RateLimited`.
        case rateLimited
    }

    enum State: Equatable {
        case form
        case notLinked
        case sending
        case failed(Failure)
        case done
    }

    @Published var state: State
    let lang: String
    /// "App Store" in `AccountDelete.Billing`.
    let storeName: String
    /// A StoreKit subscription is known on this device.
    let billingEmphasised: Bool
    /// True only where an App Store subscription can exist for this account (`SGCustomerFlows.deleteModel`): the
    /// Apple backend is on AND the signed policy is PAID or this account holds Pro by the Settings row's own
    /// predicate (`sgProSettingsRowOpensStatus`: an active or billing-retry StoreKit status, a manageable snapshot,
    /// a genuine grant — the same `holdsPro` that keeps the status screen for a holder while free). False with the
    /// Apple backend held (`apple_backend_enabled: false`: nothing was ever sold through the App Store for this app
    /// — review finding, 2026-11-10) and for a non-holder while the policy is FREE (no Pro-branded chrome then —
    /// D1, 2026-11-11): the subscription paragraph and Apple's "Manage subscription" link would point at a
    /// subscription that cannot exist.
    let showsBilling: Bool
    /// Presents the second confirmation (the app: a `UIAlertController` above the screen).
    var presentAlert: (SGCustomerAlert) -> Void = { _ in }
    /// Both confirmations given: the core fences the account and sends the request.
    var confirm: () -> Void = {}
    var openURL: (URL) -> Void = { _ in }
    /// Done on the done state.
    var finish: () -> Void = {}
    var appeared: () -> Void = {}
    /// What the app keeps alive with this screen (observers, the wall hold).
    var lifetime: [AnyObject] = []

    init(lang: String, state: State, storeName: String = "App Store", billingEmphasised: Bool, showsBilling: Bool = true) {
        self.lang = lang
        self.state = state
        self.storeName = storeName
        self.billingEmphasised = billingEmphasised
        self.showsBilling = showsBilling
    }

    /// "Delete my account and data": the second confirmation, then `confirm`.
    func requestDeletion() {
        guard self.state != .sending else {
            return
        }
        self.presentAlert(SGCustomerAlert.deleteConfirmation(lang: self.lang, delete: { [weak self] in
            self?.confirm()
        }))
    }
}

struct SGAccountDeleteView: View {
    @ObservedObject var model: SGAccountDeleteViewModel
    /// Inside the wall: its own back control and title.
    var back: SGCustomerBack?

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        return SGCustomerPage(identifier: "zg.delete") {
            if let back = self.back, self.model.state != .done {
                SGCustomerBackButton(back: back)
            }
            if self.back != nil {
                SGCustomerTitle(text: c("AccountDelete.Title"))
            }
            SGAccountDeleteContent(model: self.model)
        }
        .onAppear(perform: self.model.appeared)
    }
}

private struct SGAccountDeleteContent: View {
    @ObservedObject var model: SGAccountDeleteViewModel

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        switch self.model.state {
        case .done:
            return AnyView(
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: c("AccountDelete.Done.Title"))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibility(addTraits: .isHeader)
                        SGCustomerParagraph(text: c("AccountDelete.Done.Text"))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibility(identifier: "zg.delete.done")
                    Button(action: self.model.finish) {
                        Text(verbatim: c("Common.Close"))
                    }
                    .buttonStyle(SGCustomerFilledButtonStyle(color: .accentColor))
                    .accessibility(identifier: "zg.delete.done.ok")
                }
            )
        case .notLinked:
            return AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    SGCustomerParagraph(text: c("AccountDelete.NotLinked"), identifier: "zg.delete.notlinked")
                    SGCustomerSection {
                        SGCustomerRowButton(title: c("AccountDelete.OpenWeb"), identifier: "zg.delete.web", role: .link, action: {
                            self.model.openURL(sgCustomerDeletionPageURL)
                        })
                    }
                }
            )
        case .form, .sending, .failed:
            return AnyView(SGAccountDeleteForm(model: self.model))
        }
    }
}

private struct SGAccountDeleteForm: View {
    @ObservedObject var model: SGAccountDeleteViewModel

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        let isSending = self.model.state == .sending
        return VStack(alignment: .leading, spacing: 18) {
            SGCustomerSection {
                VStack(alignment: .leading, spacing: 12) {
                    SGCustomerParagraph(text: c("AccountDelete.Deleted"))
                    SGCustomerParagraph(text: c("AccountDelete.Kept"))
                    SGCustomerParagraph(text: c("AccountDelete.Telegram"))
                    SGCustomerParagraph(text: c("AccountDelete.Timing"))
                }
                .padding(16)
            }
            if self.model.showsBilling {
                VStack(alignment: .leading, spacing: 10) {
                    SGCustomerParagraph(text: c("AccountDelete.Billing", self.model.storeName), font: self.model.billingEmphasised ? .headline : .body, identifier: "zg.delete.billing")
                    Button(action: {
                        self.model.openURL(sgCustomerSubscriptionsURL)
                    }) {
                        Text(verbatim: c("AccountDelete.ManageSubscription"))
                            .foregroundColor(.accentColor)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibility(identifier: "zg.delete.manage")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(self.model.billingEmphasised ? Color.orange.opacity(0.18) : Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(10)
            }
            if case let .failed(failure) = self.model.state {
                VStack(alignment: .leading, spacing: 6) {
                    SGCustomerParagraph(text: c(SGAccountDeleteForm.key(failure)), color: .red, identifier: "zg.delete.error")
                    if failure != .rateLimited {
                        Button(action: {
                            self.model.openURL(sgCustomerDeletionPageURL)
                        }) {
                            Text(verbatim: c("AccountDelete.OpenWeb"))
                                .foregroundColor(.accentColor)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibility(identifier: "zg.delete.web")
                    }
                }
            }
            if isSending {
                HStack {
                    Spacer()
                    SGCustomerSpinner(identifier: "zg.delete.sending")
                    Spacer()
                }
            }
            Button(action: self.model.requestDeletion) {
                Text(verbatim: c("AccountDelete.Confirm"))
            }
            .buttonStyle(SGCustomerFilledButtonStyle(color: .red))
            .disabled(isSending)
            .accessibility(identifier: "zg.delete.action")
        }
    }

    static func key(_ failure: SGAccountDeleteViewModel.Failure) -> String {
        switch failure {
        case .failed:
            return "AccountDelete.Failed"
        case .offline:
            return "AccountDelete.Error.Offline"
        case .unavailable:
            return "AccountDelete.Error.Unavailable"
        case .rateLimited:
            return "AccountDelete.Error.RateLimited"
        }
    }
}
