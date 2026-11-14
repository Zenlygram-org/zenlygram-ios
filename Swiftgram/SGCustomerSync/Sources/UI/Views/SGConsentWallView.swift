import Foundation
import SwiftUI
import UIKit
import SGCustomerSyncCore

// MARK: Zenlygram — the data-consent wall and prompt of one Telegram account (design 40 §5.3–5.5, ui-strings §1–2), with
// its own navigation: the consent page → the consent text page (the full document and the language control), the
// decline page (required mode), the rights rows (My data, Withdraw, deletion, privacy policy), so nothing of the app is
// ever presented above it.
//
// - The consent page is MINIMAL (owner decision 2026-11-11): the title, the account line, a notice when there is one,
//   a one-paragraph summary of what is kept (`Consent.Wall.Summary`), a "Consent text" row that opens the full
//   document, the age checkbox, the mode note, a prominent "I agree", a quiet "I don't agree" under it and the small
//   "Data & privacy" link. At the default text size on an iPhone 17 it fits without scrolling when there is no notice.
// - Every caption is in the selected TEXT locale (the language control on the text page; "Oʻzbekcha", "Русский",
//   "English"), so the screen is in one language; the default is the app language when it is uz, ru or en, else uz
//   (U rule 1.8). The language chosen on the text page stays selected on the consent page: it is the locale of the
//   text "I agree" records (`SGConsentRenderedText.locale`).
// - The age checkbox starts unticked and its label is the age statement of the hashed text; "I agree" stays disabled
//   until it is ticked (U rule 1.1). "I don't agree" is always offered, as a plain text button under "I agree".
// - Required mode: "I don't agree" opens the decline page (a view state, never stored). Optional mode (the prompt):
//   "I don't agree" and the close glyph record `declined` (U rule 1.3); there is no "Not now".
// - `.textUnavailable`: no text, no summary, no "Consent text" row and no "I agree"; the rights link stays.
// - Identifiers `zg.consent.*` are stable (the ios-ui scenarios and the preview UI tests use them).

final class SGConsentWallViewModel: ObservableObject {
    enum Kind: Equatable {
        /// Required mode: cannot be dismissed by the user.
        case wall(SGConsentWallNotice)
        /// Optional mode: closing it is a decline.
        case prompt(SGConsentWallNotice)
        /// The bundled text is retired: no text, no "I agree".
        case textUnavailable

        var notice: SGConsentWallNotice {
            switch self {
            case let .wall(notice), let .prompt(notice):
                return notice
            case .textUnavailable:
                return .none
            }
        }

        var isPrompt: Bool {
            if case .prompt = self {
                return true
            }
            return false
        }
    }

    enum Page {
        case consent
        /// The full consent text with the language control.
        case text
        case declined
        case rights
        case myData(SGMyDataViewModel)
        case delete(SGAccountDeleteViewModel)
    }

    /// What the wall asks of the app; every effect leaves through here.
    struct Actions {
        /// "I agree" with exactly the rendered text on screen (`text_sha256`, `locale`).
        var agree: (SGConsentRenderedText) -> Void = { _ in }
        /// The prompt's "I don't agree" or close glyph.
        var declinePrompt: () -> Void = {}
        var logout: () -> Void = {}
        var switchAccount: () -> Void = {}
        /// Shows the withdraw confirmation.
        var withdraw: () -> Void = {}
        var retryWithdrawal: () -> Void = {}
        var openURL: (URL) -> Void = { _ in }
        /// My data in the given caption language.
        var makeMyData: (String) -> SGMyDataViewModel? = { _ in nil }
        /// The deletion screen in the given caption language.
        var makeDelete: (String) -> SGAccountDeleteViewModel? = { _ in nil }
    }

    /// The language control's segment for `locale`; the labels never change with the locale (ui-strings §1).
    static func segmentTitle(_ locale: SGConsentLocale) -> String {
        switch locale {
        case .uz:
            return "Oʻzbekcha"
        case .ru:
            return "Русский"
        case .en:
            return "English"
        }
    }

    let mode: SGConsentMode
    /// The bundled current text in each locale (missing: that locale cannot be shown).
    let texts: [SGConsentLocale: SGConsentRenderedText]
    let privacyPolicyURL: URL?
    var actions = Actions()

    @Published var kind: Kind
    /// The text locale: the language of every caption, of the text page and of the text "I agree" records.
    @Published var locale: SGConsentLocale
    /// `Consent.Wall.Account`'s value; appears when the local read finishes.
    @Published var accountLine: String?
    @Published var ageConfirmed = false
    @Published var saveFailed = false
    /// The record's decision time (the withdrawal date of the notices).
    @Published var decidedAt: Date?
    /// A withdrawal made on this device: its delivery.
    @Published var delivery: SGWithdrawalDelivery?
    @Published var otherAccounts = 0
    /// The server still holds the grant this device knows of (design 40 §5.4).
    @Published var canWithdraw = false
    /// The account root's safe insets (the app hosts the wall with the safe area ignored).
    @Published var insets = EdgeInsets()
    @Published private(set) var pages: [Page] = [.consent]

    init(kind: Kind, mode: SGConsentMode, texts: [SGConsentLocale: SGConsentRenderedText], locale: SGConsentLocale, privacyPolicyURL: URL?) {
        self.kind = kind
        self.mode = mode
        self.texts = texts
        self.locale = locale
        self.privacyPolicyURL = privacyPolicyURL
    }

    var lang: String {
        return self.locale.rawValue
    }

    var page: Page {
        return self.pages.last ?? .consent
    }

    /// The text on screen; nil while unavailable (`.textUnavailable`, no age statement, not bundled).
    var text: SGConsentRenderedText? {
        guard self.kind != .textUnavailable, let text = self.texts[self.locale], text.document.ageStatement != nil else {
            return nil
        }
        return text
    }

    func agree() {
        guard self.ageConfirmed, let text = self.text else {
            return
        }
        self.actions.agree(text)
    }

    func decline() {
        if self.kind.isPrompt {
            self.actions.declinePrompt()
        } else {
            self.push(.declined)
        }
    }

    /// The "Consent text" row: the full document on its own page.
    func openText() {
        self.push(.text)
    }

    /// Back from the text page; the language chosen there stays selected.
    func backFromText() {
        if case .text = self.page {
            self.pages.removeLast()
        }
    }

    func openRights() {
        self.push(.rights)
    }

    func openMyData() {
        if let model = self.actions.makeMyData(self.lang) {
            self.push(.myData(model))
        }
    }

    func openDelete() {
        if let model = self.actions.makeDelete(self.lang) {
            self.push(.delete(model))
        }
    }

    func back() {
        if self.pages.count > 1 {
            self.pages.removeLast()
        }
    }

    /// Back to the consent page (a withdrawal or a finished deletion).
    func showConsent() {
        self.pages = [.consent]
    }

    /// Opens on `pages` (the preview host's scenarios).
    func show(_ pages: [Page]) {
        self.pages = [.consent] + pages
    }

    private func push(_ page: Page) {
        self.pages.append(page)
    }
}

/// The whole wall: opaque, full screen, one page at a time.
struct SGConsentWallRoot: View {
    @ObservedObject var model: SGConsentWallViewModel

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground)
                .edgesIgnoringSafeArea(.all)
            self.page
                .padding(self.model.insets)
        }
        .accessibilityElement(children: .contain)
        .accessibility(identifier: "zg.consent.wall")
    }

    private var page: AnyView {
        let back = SGCustomerCaptions(self.model.lang)("Consent.Declined.Back")
        switch self.model.page {
        case .consent:
            return AnyView(SGConsentPage(model: self.model))
        case .text:
            return AnyView(SGConsentWallTextPage(model: self.model))
        case .declined:
            return AnyView(SGConsentDeclinedPage(model: self.model))
        case .rights:
            return AnyView(SGConsentRightsPage(model: self.model))
        case let .myData(myData):
            return AnyView(SGMyDataView(model: myData, back: SGCustomerBack(title: back, identifier: "zg.mydata.back", action: self.model.back)))
        case let .delete(delete):
            return AnyView(SGAccountDeleteView(model: delete, back: SGCustomerBack(title: back, identifier: "zg.delete.back", action: self.model.back)))
        }
    }
}

// MARK: - The consent page

/// Top to bottom: the close glyph (prompt only), the title and the account line, the notice, the summary, the
/// "Consent text" row, the decision block, the "Data & privacy" link. Short enough to fit an iPhone without scrolling.
private struct SGConsentPage: View {
    @ObservedObject var model: SGConsentWallViewModel

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        return SGCustomerPage(identifier: "zg.consent.page") {
            if self.model.kind.isPrompt {
                HStack {
                    Spacer()
                    Button(action: self.model.decline) {
                        Image(systemName: "xmark")
                            .font(Font.body.weight(.semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibility(label: Text(verbatim: c("Consent.Wall.Decline")))
                    .accessibility(identifier: "zg.consent.close")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SGCustomerTitle(text: c("Consent.Wall.Title"), identifier: "zg.consent.title")
                if let line = self.model.accountLine {
                    SGCustomerParagraph(text: c("Consent.Wall.Account", line), font: .subheadline, color: .secondary, identifier: "zg.consent.account")
                }
            }
            SGConsentNoticeView(model: self.model)
            if let text = self.model.text, let age = text.document.ageStatement {
                SGCustomerParagraph(text: c("Consent.Wall.Summary"), identifier: "zg.consent.summary")
                SGConsentTextRow(title: c("DataConsent.ReadText"), identifier: "zg.consent.text", action: self.model.openText)
                SGConsentDecisionView(model: self.model, ageStatement: age)
            } else {
                SGCustomerParagraph(text: c("Consent.Wall.TextUnavailable"), identifier: "zg.consent.textunavailable")
            }
            SGConsentRightsLink(title: c("Settings.Data.Header"), action: self.model.openRights)
        }
    }
}

/// "Consent text ›": a row in the accent colour that opens the full document on the wall's own text page.
private struct SGConsentTextRow: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                Text(verbatim: self.title)
                    .foregroundColor(.accentColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(Font.footnote.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .accessibility(hidden: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibility(identifier: self.identifier)
    }
}

/// The small "Data & privacy" link at the foot of the consent page (the rights page: My data, Withdraw, deletion, the
/// privacy policy), usable without consenting.
private struct SGConsentRightsLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Text(verbatim: self.title)
                .font(.footnote)
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibility(identifier: "zg.consent.rights")
    }
}

private struct SGConsentLanguageControl: View {
    @ObservedObject var model: SGConsentWallViewModel

    var body: some View {
        let caption = SGCustomerCaptions(self.model.lang)("Consent.Wall.Language")
        // The identifier sits on the control's container (its caption and the segments): it reaches the
        // accessibility tree whatever the platform control underneath does with it.
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: caption)
                .font(.footnote)
                .foregroundColor(.secondary)
            Picker(selection: self.$model.locale, label: Text(verbatim: caption)) {
                ForEach(SGConsentLocale.allCases, id: \.self) { locale in
                    Text(verbatim: SGConsentWallViewModel.segmentTitle(locale)).tag(locale)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
        }
        .accessibilityElement(children: .contain)
        .accessibility(identifier: "zg.consent.lang")
    }
}

/// Why the wall is asking again (the notice line) and, after a withdrawal on this device, where its delivery stands.
private struct SGConsentNoticeView: View {
    @ObservedObject var model: SGConsentWallViewModel

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        let notice = self.model.kind.notice
        let date = SGCustomerSyncFormat.decisionDate(self.model.decidedAt, lang: c.lang)
        let text: Text?
        switch notice {
        case .none:
            text = nil
        case .deleted:
            text = Text(verbatim: c("AccountDelete.Done.Title")).bold() + Text(verbatim: "\n" + c("AccountDelete.Done.Text"))
        case .linkEnded:
            text = Text(verbatim: c("Consent.Wall.Notice.LinkEnded"))
        case .reconsent, .operatorChanged:
            text = Text(verbatim: c("Consent.Wall.Notice.Reconsent"))
        case .withdrawn:
            text = Text(verbatim: SGCustomerSyncFormat.sentence(c("Consent.Wall.Notice.Withdrawn", date)))
        case .withdrawnRemote:
            text = Text(verbatim: SGCustomerSyncFormat.sentence(c("Consent.Wall.Notice.WithdrawnRemote", date)))
        }
        let delivery = notice == .withdrawn ? self.model.delivery : nil
        guard let line = text else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                line
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibility(identifier: "zg.consent.notice")
                if let delivery = delivery, delivery != .delivered {
                    SGConsentDeliveryView(delivery: delivery, date: date, c: c, actions: self.model.actions)
                }
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(10)
        )
    }
}

private struct SGConsentDeliveryView: View {
    let delivery: SGWithdrawalDelivery
    let date: String
    let c: SGCustomerCaptions
    let actions: SGConsentWallViewModel.Actions

    var body: some View {
        switch self.delivery {
        case .delivered:
            return AnyView(EmptyView())
        case .sending:
            return AnyView(
                HStack(spacing: 10) {
                    SGCustomerSpinner()
                    SGCustomerParagraph(text: self.c("DataConsent.Withdraw.Sending"), font: .subheadline, color: .secondary, identifier: "zg.consent.withdraw.status")
                }
            )
        case .pending:
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    SGCustomerParagraph(text: SGCustomerSyncFormat.sentence(self.c("DataConsent.Status.WithdrawPending", self.date)), font: .subheadline, color: .secondary, identifier: "zg.consent.withdraw.status")
                    SGConsentInlineButton(title: self.c("MyData.Retry"), identifier: "zg.consent.withdraw.retry", action: self.actions.retryWithdrawal)
                }
            )
        case .notLinked:
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    SGCustomerParagraph(text: self.c("DataConsent.Withdraw.PendingUpload"), font: .subheadline, color: .secondary, identifier: "zg.consent.withdraw.status")
                    SGConsentInlineButton(title: self.c("AccountDelete.OpenWeb"), identifier: "zg.consent.withdraw.web", action: {
                        self.actions.openURL(sgCustomerDeletionPageURL)
                    })
                }
            )
        }
    }
}

private struct SGConsentInlineButton: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Text(verbatim: self.title)
                .foregroundColor(.accentColor)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibility(identifier: self.identifier)
    }
}

/// The age checkbox and its hint, the mode note, the prominent "I agree" with the quiet "I don't agree" under it, and
/// a failed save.
private struct SGConsentDecisionView: View {
    @ObservedObject var model: SGConsentWallViewModel
    let ageStatement: [SGConsentRun]

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SGCustomerCheckbox(isOn: self.model.ageConfirmed, identifier: "zg.consent.age", toggle: {
                    self.model.ageConfirmed.toggle()
                }) {
                    SGConsentRunsText.concatenated(self.ageStatement)
                }
                if !self.model.ageConfirmed {
                    SGCustomerParagraph(text: c("Consent.Wall.AgeHint"), font: .footnote, color: .secondary, identifier: "zg.consent.agehint")
                        .padding(.leading, 36)
                }
            }
            SGCustomerParagraph(text: c(self.model.mode == .required ? "Consent.Wall.ModeNote.Required" : "Consent.Wall.ModeNote.Optional"), font: .footnote, color: .secondary, identifier: "zg.consent.modenote")
            VStack(spacing: 4) {
                Button(action: self.model.agree) {
                    Text(verbatim: c("Consent.Wall.Agree"))
                }
                .buttonStyle(SGCustomerDecisionButtonStyle())
                .disabled(!self.model.ageConfirmed)
                .accessibility(identifier: "zg.consent.agree")
                Button(action: self.model.decline) {
                    Text(verbatim: c("Consent.Wall.Decline"))
                }
                .buttonStyle(SGConsentQuietButtonStyle())
                .accessibility(identifier: "zg.consent.decline")
            }
            .frame(maxWidth: .infinity)
            if self.model.saveFailed {
                SGCustomerParagraph(text: c("Consent.Wall.SaveFailed"), font: .subheadline, color: .red, identifier: "zg.consent.savefailed")
            }
        }
    }
}

/// "I don't agree" under the filled "I agree": a plain text button, smaller and quieter (owner decision 2026-11-11),
/// centred, still 44 pt tall to tap.
private struct SGConsentQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundColor(.accentColor)
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

// MARK: - The consent text page

/// The full consent text in the selected language — every block, the age statement included (it is also the
/// checkbox's label on the consent page) — under the language control. Back returns to the consent page; the language
/// chosen here stays selected there and is the locale "I agree" records.
private struct SGConsentWallTextPage: View {
    @ObservedObject var model: SGConsentWallViewModel

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        return SGCustomerPage(identifier: "zg.consent.text.page") {
            SGCustomerBackButton(back: SGCustomerBack(title: c("Consent.Declined.Back"), identifier: "zg.consent.text.back", action: self.model.backFromText))
            SGCustomerTitle(text: c("DataConsent.ReadText"))
            SGConsentLanguageControl(model: self.model)
            if let text = self.model.text {
                SGConsentTextView(blocks: text.document.blocks, openURL: self.model.actions.openURL)
                    .accessibilityElement(children: .contain)
                    .accessibility(identifier: "zg.consent.text.body")
            } else {
                SGCustomerParagraph(text: c("Consent.Wall.TextUnavailable"), identifier: "zg.consent.textunavailable")
            }
        }
    }
}

// MARK: - The decline page and the rights rows (design 40 §5.4)

private struct SGConsentDeclinedPage: View {
    @ObservedObject var model: SGConsentWallViewModel

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        return SGCustomerPage(identifier: "zg.consent.declined") {
            SGCustomerTitle(text: c("Consent.Declined.Title"))
            SGCustomerParagraph(text: c("Consent.Declined.Text"))
            // ui-strings §2: Back, Delete, Log out and (Use another account) as rows of the same size and style.
            SGCustomerSection {
                SGCustomerRowButton(title: c("Consent.Declined.Back"), identifier: "zg.consent.declined.back", action: self.model.back)
                SGCustomerRowDivider()
                SGCustomerRowButton(title: c("Consent.Declined.Delete"), identifier: "zg.consent.rights.delete", action: self.model.openDelete)
                SGCustomerRowDivider()
                SGCustomerRowButton(title: c("Consent.Declined.Logout"), identifier: "zg.consent.declined.logout", action: self.model.actions.logout)
                if self.model.otherAccounts > 0 {
                    SGCustomerRowDivider()
                    SGCustomerRowButton(title: c("Consent.Declined.SwitchAccount"), identifier: "zg.consent.declined.switch", action: self.model.actions.switchAccount)
                }
            }
            // The rest of the rights, usable without consenting; the privacy policy as a link row.
            SGCustomerSection(header: c("Settings.Data.Header")) {
                SGCustomerRowButton(title: c("DataConsent.MyData"), identifier: "zg.consent.rights.mydata", action: self.model.openMyData)
                if self.model.canWithdraw {
                    SGCustomerRowDivider()
                    SGCustomerRowButton(title: c("DataConsent.Withdraw"), identifier: "zg.consent.rights.withdraw", action: self.model.actions.withdraw)
                }
                if let url = self.model.privacyPolicyURL {
                    SGCustomerRowDivider()
                    SGCustomerRowButton(title: c("Consent.Declined.PrivacyPolicy"), identifier: "zg.consent.rights.policy", role: .link, action: {
                        self.model.actions.openURL(url)
                    })
                }
            }
        }
    }
}

private struct SGConsentRightsPage: View {
    @ObservedObject var model: SGConsentWallViewModel

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        return SGCustomerPage(identifier: "zg.consent.rights.page") {
            SGCustomerBackButton(back: SGCustomerBack(title: c("Consent.Declined.Back"), identifier: "zg.consent.rights.back", action: self.model.back))
            SGCustomerTitle(text: c("Settings.Data.Header"))
            SGCustomerSection {
                SGCustomerRowButton(title: c("DataConsent.MyData"), identifier: "zg.consent.rights.mydata", action: self.model.openMyData)
                if self.model.canWithdraw {
                    SGCustomerRowDivider()
                    SGCustomerRowButton(title: c("DataConsent.Withdraw"), identifier: "zg.consent.rights.withdraw", action: self.model.actions.withdraw)
                }
                SGCustomerRowDivider()
                SGCustomerRowButton(title: c("DataConsent.Delete"), identifier: "zg.consent.rights.delete", action: self.model.openDelete)
                if let url = self.model.privacyPolicyURL {
                    SGCustomerRowDivider()
                    SGCustomerRowButton(title: c("Settings.Data.PrivacyPolicy"), identifier: "zg.consent.rights.policy", role: .link, action: {
                        self.model.actions.openURL(url)
                    })
                }
            }
        }
    }
}
