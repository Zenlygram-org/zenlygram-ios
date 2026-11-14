import Foundation
import SwiftUI
import UIKit
import SGStrings
import SGCustomerSyncCore

// MARK: Zenlygram — the small pieces of the consent screens (design 40 §5.3, §11): captions in one language, the date
// formats, a page column, sections and rows, the filled decision button, the checkbox, a spinner and the alert texts.
//
// Everything under `Sources/UI/Views/` is PURE — SwiftUI, UIKit, Core and SGStrings only, no app state — because it is
// compiled twice: into the app module and into the test-only preview host that renders it over fixture states
// (`//Swiftgram/SGCustomerSync:SGCustomerSyncPreviewHost`, design 40 §15.6). Effects reach the app through the
// closures of the view models. iOS 13 is the floor: every newer API sits behind `#available`.

/// The web page for an account that is not linked on this device (ui-strings §5).
let sgCustomerDeletionPageURL = URL(string: "https://zenlygram.org/account/delete")!
/// Apple's own subscription management (as `SGSettingsController` opens it).
let sgCustomerSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

/// The captions of one screen in one language (`i18n(key, lang)`): the wall renders every caption in the selected
/// text locale (design 40 §4.2), the Settings screens in the app language. A key with placeholders is always read
/// with its arguments.
struct SGCustomerCaptions {
    let lang: String

    init(_ lang: String) {
        self.lang = lang
    }

    func callAsFunction(_ key: String) -> String {
        return key.i18n(self.lang)
    }

    /// One `%@`.
    func callAsFunction(_ key: String, _ value: String) -> String {
        return key.i18n(self.lang, args: value)
    }

    /// Two `%@`.
    func callAsFunction(_ key: String, _ first: String, _ second: String) -> String {
        return key.i18n(self.lang, args: first, second)
    }

    /// One `%d`.
    func count(_ key: String, _ value: Int) -> String {
        return key.i18n(self.lang, args: value)
    }
}

/// How the consent screens show dates and amounts.
enum SGCustomerSyncFormat {
    /// The decisions' dates (`DataConsent.Status.*`, the wall's notices) are shown in Asia/Tashkent (ui-strings §3).
    static let decisionTimeZone: TimeZone = TimeZone(identifier: "Asia/Tashkent") ?? TimeZone(secondsFromGMT: 5 * 3600) ?? .current

    static func locale(_ lang: String) -> Locale {
        return Locale(identifier: lang.hasSuffix("-raw") ? String(lang.dropLast(4)) : lang)
    }

    /// A consent decision's date: medium style, no time, Asia/Tashkent.
    static func decisionDate(_ date: Date?, lang: String) -> String {
        guard let date = date else {
            return "—"
        }
        let formatter = DateFormatter()
        formatter.locale = SGCustomerSyncFormat.locale(lang)
        formatter.timeZone = SGCustomerSyncFormat.decisionTimeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// A caption that ends with a date: a date that itself ends with an abbreviation's period (ru "19 сент. 2026 г.")
    /// also ends the sentence, so the period is not doubled.
    static func sentence(_ text: String) -> String {
        return text.replacingOccurrences(of: "..", with: ".")
    }

    /// A time on My data: medium date and short time in the device's time zone (design 40 §11.3).
    static func time(_ date: Date, lang: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = SGCustomerSyncFormat.locale(lang)
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// A server instant (`2026-11-01T10:00:00Z`; a fraction is tolerated).
    static func serverDate(_ text: String?) -> Date? {
        guard let text = text else {
            return nil
        }
        if let date = SGCustomerTime.date(fromInstant: text) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// A server instant as `time(...)`, or the raw text when it does not parse.
    static func serverTime(_ text: String?, lang: String, timeZone: TimeZone) -> String? {
        guard let text = text else {
            return nil
        }
        return SGCustomerSyncFormat.serverDate(text).map { SGCustomerSyncFormat.time($0, lang: lang, timeZone: timeZone) } ?? text
    }

    /// `value` of one calendar unit, spelled out in `lang` ("180 days", "25 месяцев").
    static func span(_ value: Int, _ unit: NSCalendar.Unit, lang: String) -> String {
        var components = DateComponents()
        switch unit {
        case .year:
            components.year = value
        case .month:
            components.month = value
        case .day:
            components.day = value
        default:
            components.second = value
        }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = SGCustomerSyncFormat.locale(lang)
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [unit]
        return formatter.string(from: components) ?? "\(value)"
    }

    /// A duration in hours and minutes.
    static func duration(seconds: Int, lang: String) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = SGCustomerSyncFormat.locale(lang)
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        return formatter.string(from: TimeInterval(max(0, seconds))) ?? "\(seconds)"
    }
}

/// An alert the screens ask for, presented by the app (or the preview host) as a `UIAlertController`. The texts are
/// decided here so the preview UI tests read exactly what the app shows (design 40 §15.6 "the withdraw confirmation
/// texts").
struct SGCustomerAlert {
    enum Style {
        case cancel
        case normal
        case destructive
    }

    struct Action {
        let title: String
        let style: Style
        let handler: () -> Void
    }

    let title: String
    let message: String
    let actions: [Action]

    /// An empty title or message is left out.
    func makeController() -> UIAlertController {
        let controller = UIAlertController(title: self.title.isEmpty ? nil : self.title, message: self.message.isEmpty ? nil : self.message, preferredStyle: .alert)
        for action in self.actions {
            let style: UIAlertAction.Style
            switch action.style {
            case .cancel:
                style = .cancel
            case .normal:
                style = .default
            case .destructive:
                style = .destructive
            }
            let handler = action.handler
            controller.addAction(UIAlertAction(title: action.title, style: style, handler: { _ in
                handler()
            }))
        }
        return controller
    }

    /// The withdraw confirmation (design 40 §11.2 step 1, ui-strings §4): the text, the unsent Tasks changes (a count
    /// by `SGCustomerPlural`; "unknown" when they cannot be read; nothing for none), what happens in this build's mode,
    /// and — with no binding on this device — that the withdrawal cannot be sent from here. "Delete instead" opens the
    /// deletion and withdraws nothing.
    static func withdrawConfirmation(lang: String, unsentChanges: Int?, mode: SGConsentMode, isLinked: Bool, withdraw: @escaping () -> Void, deleteInstead: (() -> Void)?) -> SGCustomerAlert {
        let c = SGCustomerCaptions(lang)
        var parts = [c("DataConsent.Withdraw.Confirm.Text")]
        if let unsent = unsentChanges {
            if unsent > 0 {
                let form: String
                switch SGCustomerPlural.category(unsent, languageCode: lang) {
                case .one:
                    form = "One"
                case .few:
                    form = "Few"
                case .many:
                    form = "Many"
                }
                parts.append(c.count("DataConsent.Withdraw.Confirm.Unsent.\(form)", unsent))
            }
        } else {
            parts.append(c("DataConsent.Withdraw.Confirm.UnsentUnknown"))
        }
        parts.append(c(mode == .required ? "DataConsent.Withdraw.Required" : "DataConsent.Withdraw.Optional"))
        if !isLinked {
            parts.append(c("DataConsent.Withdraw.PendingUpload"))
        }
        var actions = [Action(title: c("Common.Cancel"), style: .cancel, handler: {})]
        if let deleteInstead = deleteInstead {
            actions.append(Action(title: c("DataConsent.Withdraw.DeleteInstead"), style: .normal, handler: deleteInstead))
        }
        actions.append(Action(title: c("DataConsent.Withdraw.Confirm.Action"), style: .destructive, handler: withdraw))
        return SGCustomerAlert(title: c("DataConsent.Withdraw.Confirm.Title"), message: parts.joined(separator: "\n\n"), actions: actions)
    }

    /// The second confirmation of the deletion (ui-strings §5).
    static func deleteConfirmation(lang: String, delete: @escaping () -> Void) -> SGCustomerAlert {
        let c = SGCustomerCaptions(lang)
        return SGCustomerAlert(title: c("AccountDelete.Confirm2.Title"), message: c("AccountDelete.Confirm2.Text"), actions: [
            Action(title: c("Common.Cancel"), style: .cancel, handler: {}),
            Action(title: c("AccountDelete.Confirm2.Action"), style: .destructive, handler: delete),
        ])
    }

    /// "Log out of this account" on the decline page (design 40 §5.4): Telegram's own logout confirmation (`title`,
    /// `text`, `cancel`, `confirm` from the app's strings), then the Tasks notice when something is unsent, the
    /// last-account warning when this is the only signed-in account, and the not-delivered withdrawal when there is no
    /// binding to send it with.
    static func logoutConfirmation(lang: String, title: String, text: String, cancel: String, confirm: String, tasksNotice: String?, isLastAccount: Bool, withdrawalNotDeliverable: Bool, logout: @escaping () -> Void) -> SGCustomerAlert {
        let c = SGCustomerCaptions(lang)
        var parts = [text]
        if let tasksNotice = tasksNotice, !tasksNotice.isEmpty {
            parts.append(tasksNotice)
        }
        if isLastAccount {
            parts.append(c("Consent.Declined.Logout.LastAccount"))
        }
        if withdrawalNotDeliverable {
            parts.append(c("DataConsent.Withdraw.PendingUpload"))
        }
        return SGCustomerAlert(title: title, message: parts.joined(separator: "\n\n"), actions: [
            Action(title: cancel, style: .cancel, handler: {}),
            Action(title: confirm, style: .destructive, handler: logout),
        ])
    }
}

/// Where a withdrawal made on this device stands (design 40 §5.3, §11.2): delivered (acked), being sent (the
/// user-initiated send, shown for up to 10 s), not delivered yet while a binding exists (Retry), or not deliverable
/// from here (no binding: the web page).
enum SGWithdrawalDelivery: Equatable {
    case delivered
    case sending
    case pending
    case notLinked

    static func derive(acked: Bool, isLinked: Bool, sending: Bool) -> SGWithdrawalDelivery {
        if acked {
            return .delivered
        }
        if !isLinked {
            return .notLinked
        }
        return sending ? .sending : .pending
    }
}

// MARK: - Layout

/// A scrolling page whose content column is at most 640 pt wide and centred (iPad, wide windows; design 40 §5.3).
struct SGCustomerPage<Content: View>: View {
    static var maxWidth: CGFloat {
        return 640
    }

    let identifier: String
    let content: Content

    init(identifier: String, @ViewBuilder content: () -> Content) {
        self.identifier = identifier
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                self.content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: SGCustomerPage.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibility(identifier: self.identifier)
        }
    }
}

/// A page title.
struct SGCustomerTitle: View {
    let text: String
    var identifier: String?

    var body: some View {
        let title = Text(verbatim: self.text)
            .font(.title)
            .bold()
            .fixedSize(horizontal: false, vertical: true)
            .accessibility(addTraits: .isHeader)
        if let identifier = self.identifier {
            return AnyView(title.accessibility(identifier: identifier))
        }
        return AnyView(title)
    }
}

/// A paragraph of body text.
struct SGCustomerParagraph: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    var identifier: String?

    var body: some View {
        let paragraph = Text(verbatim: self.text)
            .font(self.font)
            .foregroundColor(self.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let identifier = self.identifier {
            return AnyView(paragraph.accessibility(identifier: identifier))
        }
        return AnyView(paragraph)
    }
}

/// A grouped section: an optional header (upper case, as iOS shows them), rounded content, an optional footer.
struct SGCustomerSection<Content: View>: View {
    let header: String?
    let footer: String?
    let content: Content

    init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = self.header {
                Text(verbatim: header.uppercased())
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .accessibility(addTraits: .isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                self.content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(10)
            if let footer = self.footer {
                Text(verbatim: footer)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// The hairline between two rows of a section.
struct SGCustomerRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

/// A tappable row of a section.
struct SGCustomerRowButton: View {
    enum Role {
        case normal
        case destructive
        case link
    }

    let title: String
    let identifier: String
    var role: Role = .normal
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                Text(verbatim: self.title)
                    .foregroundColor(self.color)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if self.role != .link {
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                        .accessibility(hidden: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibility(identifier: self.identifier)
    }

    private var color: Color {
        switch self.role {
        case .normal:
            return .primary
        case .destructive:
            return .red
        case .link:
            return .accentColor
        }
    }
}

/// A label and its value (My data).
struct SGCustomerValueRow: View {
    let title: String
    let value: String
    var detail: String?
    var titleIdentifier: String?
    var valueIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                self.titleText
                Spacer(minLength: 8)
                self.valueText
            }
            if let detail = self.detail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: AnyView {
        let text = Text(verbatim: self.title)
            .foregroundColor(self.titleIdentifier == nil ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
        if let identifier = self.titleIdentifier {
            return AnyView(text.accessibility(identifier: identifier))
        }
        return AnyView(text)
    }

    private var valueText: AnyView {
        let text = Text(verbatim: self.value)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        if let identifier = self.valueIdentifier {
            return AnyView(text.accessibility(identifier: identifier))
        }
        return AnyView(text)
    }
}

/// The back control of a page pushed inside the wall's own navigation (the wall shows nothing of the app's).
struct SGCustomerBack {
    let title: String
    let identifier: String
    let action: () -> Void
}

struct SGCustomerBackButton: View {
    let back: SGCustomerBack

    var body: some View {
        Button(action: self.back.action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(Font.body.weight(.semibold))
                    .accessibility(hidden: true)
                Text(verbatim: self.back.title)
            }
            .foregroundColor(.accentColor)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibility(identifier: self.back.identifier)
    }
}

/// The wall's prominent, full-width "I agree" (owner decision 2026-11-11: the quiet "I don't agree" under it is a plain
/// text button, styled in SGConsentWallView). One line, scaled down before it wraps, so the frame holds at every text
/// size; disabled is dimmed.
struct SGCustomerDecisionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SGCustomerFilledButtonLabel(label: configuration.label, isPressed: configuration.isPressed, color: .accentColor)
    }
}

/// A full-width filled button (the deletion's "Delete my account and data").
struct SGCustomerFilledButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        SGCustomerFilledButtonLabel(label: configuration.label, isPressed: configuration.isPressed, color: self.color)
    }
}

private struct SGCustomerFilledButtonLabel<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled: Bool
    let label: Label
    let isPressed: Bool
    let color: Color

    var body: some View {
        self.label
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(self.color.opacity(self.isPressed ? 0.75 : 1))
            .cornerRadius(12)
            .opacity(self.isEnabled ? 1 : 0.4)
    }
}

/// The age checkbox (design 40 §5.3): unticked at first; its label is the age statement of the hashed text.
struct SGCustomerCheckbox<Label: View>: View {
    let isOn: Bool
    let identifier: String
    let toggle: () -> Void
    let label: Label

    init(isOn: Bool, identifier: String, toggle: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.identifier = identifier
        self.toggle = toggle
        self.label = label()
    }

    var body: some View {
        Button(action: self.toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: self.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 24))
                    .foregroundColor(self.isOn ? .accentColor : .secondary)
                    .accessibility(hidden: true)
                self.label
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibility(addTraits: self.isOn ? .isSelected : [])
        .accessibility(value: Text(verbatim: self.isOn ? "1" : "0"))
        .accessibility(identifier: self.identifier)
    }
}

/// An activity indicator that works from iOS 13 on. The identifier is set on the UIKit view itself (SwiftUI's
/// accessibility modifiers do not reliably reach a representable).
struct SGCustomerSpinner: UIViewRepresentable {
    var identifier: String?

    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let view = UIActivityIndicatorView(style: .medium)
        if let identifier = self.identifier {
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = identifier
        }
        view.startAnimating()
        return view
    }

    func updateUIView(_ view: UIActivityIndicatorView, context: Context) {
        if !view.isAnimating {
            view.startAnimating()
        }
    }
}
