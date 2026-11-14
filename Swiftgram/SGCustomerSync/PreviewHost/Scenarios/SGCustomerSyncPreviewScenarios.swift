import Foundation
import SwiftUI
import UIKit
import SGCustomerSyncCore

// MARK: Zenlygram — TEST-ONLY fixture states for the consent screens' real views (design 40 §15.6).
//
// Compiled ONLY into `SGCustomerSyncViewsPreviewLib` (Swiftgram/SGCustomerSync/BUILD) together with the unchanged
// `Sources/UI/Views/**`, never into the app. Each scenario is a plain view-model value fed to the production views; the
// consent texts are the vendored tree bundled with the host (`SGCustomerSyncResources.bundle`) rendered with clearly
// fake operator values. Nothing here touches SGEntitlement, the consent store, the network or any persistence; taps
// only log (an alert the screen asks for is shown, so the screens can be walked by hand).

// The case list and what each case promises live in `SGCustomerSyncPreviewCatalog.swift` (Foundation only), which the
// UI test bundle compiles too.
extension SGCustomerSyncPreviewScenario {
    /// Clearly fake operator values (the real ones are build configuration and are never in a fixture).
    static let operatorValues = SGConsentOperatorValues(decoded: [
        .name: "Preview Operator (test)",
        .stir: "000000000",
        .responsiblePerson: "Preview Person (test)",
        .contactEmail: "privacy@example.invalid",
    ])

    static let privacyPolicyURL = URL(string: "https://zenlygram.org/privacy-policy.html")

    /// The bundled current text in every locale.
    static let texts: [SGConsentLocale: SGConsentRenderedText] = {
        guard let bundleURL = Bundle.main.url(forResource: "SGCustomerSyncResources", withExtension: "bundle"),
              case let .success(repository) = SGConsentTextRepository.load(rootURL: bundleURL.appendingPathComponent("consent", isDirectory: true)) else {
            NSLog("SGCustomerSyncPreview: the vendored consent tree is missing")
            return [:]
        }
        var texts: [SGConsentLocale: SGConsentRenderedText] = [:]
        for locale in SGConsentLocale.allCases {
            texts[locale] = repository.render(version: repository.currentVersion, locale: locale, operatorValues: SGCustomerSyncPreviewScenario.operatorValues)
        }
        return texts
    }()

    private static func record(_ state: SGConsentState) -> SGConsentRecord {
        return SGConsentRecord(
            tgUserId: SGCustomerSyncPreviewScenario.telegramUserId,
            state: state,
            consentId: "9b0c0000-0000-4000-8000-000000000001",
            textVersion: 1,
            textSha256: nil,
            locale: .uz,
            consentMode: .required,
            decidedAt: SGCustomerTime.instant(SGCustomerSyncPreviewScenario.decisionDate)
        )
    }

    static func log(_ action: String) {
        NSLog("SGCustomerSyncPreview action: %@", action)
    }

    // MARK: The wall

    var wallKind: SGConsentWallViewModel.Kind {
        switch self {
        case .wallReconsent:
            return .wall(.reconsent)
        case .wallOperatorChanged:
            return .wall(.operatorChanged)
        case .wallLinkEnded:
            return .wall(.linkEnded)
        case .wallDeleted:
            return .wall(.deleted)
        case .wallTextUnavailable:
            return .textUnavailable
        case .wallWithdrawnSending, .wallWithdrawnDelivered, .wallWithdrawnPending, .wallWithdrawnUnlinked:
            return .wall(.withdrawn)
        case .wallWithdrawnRemote:
            return .wall(.withdrawnRemote)
        case .promptNone:
            return .prompt(.none)
        case .promptReconsent:
            return .prompt(.reconsent)
        case .declinedWithdrawable:
            return .wall(.reconsent)
        default:
            return .wall(.none)
        }
    }

    func wallModel(lang: String, present: @escaping (SGCustomerAlert) -> Void) -> SGConsentWallViewModel {
        let kind = self.wallKind
        let model = SGConsentWallViewModel(kind: kind, mode: kind.isPrompt ? .optional : .required, texts: SGCustomerSyncPreviewScenario.texts, locale: SGConsentLocale.forWall(languageCode: lang), privacyPolicyURL: SGCustomerSyncPreviewScenario.privacyPolicyURL)
        model.accountLine = SGCustomerSyncPreviewScenario.accountLine
        model.decidedAt = SGCustomerSyncPreviewScenario.decisionDate
        switch self {
        case .wallWithdrawnSending:
            model.delivery = .sending
        case .wallWithdrawnDelivered:
            model.delivery = .delivered
        case .wallWithdrawnPending:
            model.delivery = .pending
        case .wallWithdrawnUnlinked:
            model.delivery = .notLinked
        default:
            model.delivery = nil
        }
        model.saveFailed = self == .wallSaveFailed
        model.otherAccounts = self == .declinedTwoAccounts ? 1 : 0
        model.canWithdraw = self == .declinedWithdrawable
        model.actions.agree = { _ in
            SGCustomerSyncPreviewScenario.log("agree")
        }
        model.actions.declinePrompt = {
            SGCustomerSyncPreviewScenario.log("decline")
        }
        model.actions.logout = {
            SGCustomerSyncPreviewScenario.log("logout")
        }
        model.actions.switchAccount = {
            SGCustomerSyncPreviewScenario.log("switch")
        }
        model.actions.withdraw = {
            present(SGCustomerAlert.withdrawConfirmation(lang: lang, unsentChanges: 2, mode: .required, isLinked: true, withdraw: {
                SGCustomerSyncPreviewScenario.log("withdraw")
            }, deleteInstead: nil))
        }
        model.actions.retryWithdrawal = {
            SGCustomerSyncPreviewScenario.log("retry")
        }
        model.actions.openURL = { url in
            SGCustomerSyncPreviewScenario.log("open \(url.absoluteString)")
        }
        model.actions.makeMyData = { lang in
            return SGCustomerSyncPreviewScenario.myDataModel(lang: lang, state: SGCustomerSyncPreviewScenario.loadedMyData)
        }
        model.actions.makeDelete = { lang in
            return SGCustomerSyncPreviewScenario.deleteModel(lang: lang, state: .form, billingEmphasised: false, present: present)
        }
        switch self {
        case .wallText:
            model.show([.text])
        case .declinedOneAccount, .declinedTwoAccounts, .declinedWithdrawable:
            model.show([.declined])
        case .rightsPage:
            model.show([.rights])
        case .wallMyData:
            model.show([.rights, .myData(SGCustomerSyncPreviewScenario.myDataModel(lang: model.lang, state: SGCustomerSyncPreviewScenario.loadedMyData))])
        case .wallDelete:
            model.show([.declined, .delete(SGCustomerSyncPreviewScenario.deleteModel(lang: model.lang, state: .form, billingEmphasised: false, present: present))])
        default:
            break
        }
        return model
    }

    // MARK: Data & consent

    var dataFacts: SGDataConsentFacts {
        var facts = SGDataConsentFacts()
        facts.isLinked = true
        switch self {
        case .dataGranted, .withdrawUnsentOne, .withdrawUnsentFew, .withdrawUnsentMany, .withdrawUnsentUnknown, .withdrawOptional, .withdrawUnlinked:
            facts.record = SGCustomerSyncPreviewScenario.record(.granted)
            facts.recordAcked = true
        case .dataPending:
            facts.record = SGCustomerSyncPreviewScenario.record(.granted)
        case .dataNone:
            facts.record = nil
        case .dataDeclined:
            facts.record = SGCustomerSyncPreviewScenario.record(.declined)
        case .dataWithdrawn:
            facts.record = SGCustomerSyncPreviewScenario.record(.withdrawn)
            facts.recordAcked = true
        case .dataSending:
            facts.record = SGCustomerSyncPreviewScenario.record(.withdrawn)
            facts.sending = true
            facts.hasPendingWithdraw = true
        case .dataWithdrawPending:
            facts.record = SGCustomerSyncPreviewScenario.record(.withdrawn)
            facts.hasPendingWithdraw = true
        case .dataWithdrawUnlinked:
            facts.record = SGCustomerSyncPreviewScenario.record(.withdrawn)
            facts.hasPendingWithdraw = true
            facts.isLinked = false
        case .dataReconsent:
            facts.record = SGCustomerSyncPreviewScenario.record(.needsReconsent)
            facts.storedNotice = .reconsent
            facts.recordAcked = true
        case .dataLinkEnded:
            facts.record = SGCustomerSyncPreviewScenario.record(.needsReconsent)
            facts.storedNotice = .linkEnded
            facts.recordAcked = true
        case .dataRejected:
            facts.record = SGCustomerSyncPreviewScenario.record(.granted)
            facts.grantRejection = "consent_text_mismatch"
        default:
            break
        }
        return facts
    }

    func dataModel(lang: String) -> SGDataConsentViewModel {
        let model = SGDataConsentViewModel(lang: lang, facts: self.dataFacts, operatorName: "Preview Operator (test)", operatorEmail: "privacy@example.invalid", hasPrivacyPolicy: true, showsDebugReset: false)
        model.actions.readText = { SGCustomerSyncPreviewScenario.log("text") }
        model.actions.myData = { SGCustomerSyncPreviewScenario.log("mydata") }
        model.actions.grant = { SGCustomerSyncPreviewScenario.log("grant") }
        model.actions.withdraw = { SGCustomerSyncPreviewScenario.log("withdraw") }
        model.actions.delete = { SGCustomerSyncPreviewScenario.log("delete") }
        model.actions.privacyPolicy = { SGCustomerSyncPreviewScenario.log("policy") }
        model.actions.retry = { SGCustomerSyncPreviewScenario.log("retry") }
        model.actions.openURL = { url in SGCustomerSyncPreviewScenario.log("open \(url.absoluteString)") }
        return model
    }

    /// The withdraw confirmation exactly as the app builds it.
    func withdrawAlert(lang: String) -> SGCustomerAlert? {
        guard let withdrawal = self.withdrawal else {
            return nil
        }
        return SGCustomerAlert.withdrawConfirmation(lang: lang, unsentChanges: withdrawal.unsent, mode: withdrawal.optional ? .optional : .required, isLinked: withdrawal.linked, withdraw: {
            SGCustomerSyncPreviewScenario.log("withdraw")
        }, deleteInstead: {
            SGCustomerSyncPreviewScenario.log("delete instead")
        })
    }

    // MARK: Deletion and My data

    static func deleteModel(lang: String, state: SGAccountDeleteViewModel.State, billingEmphasised: Bool, present: @escaping (SGCustomerAlert) -> Void) -> SGAccountDeleteViewModel {
        let model = SGAccountDeleteViewModel(lang: lang, state: state, billingEmphasised: billingEmphasised)
        model.presentAlert = present
        model.confirm = { SGCustomerSyncPreviewScenario.log("delete") }
        model.openURL = { url in SGCustomerSyncPreviewScenario.log("open \(url.absoluteString)") }
        model.finish = { SGCustomerSyncPreviewScenario.log("done") }
        return model
    }

    var deleteState: SGAccountDeleteViewModel.State {
        switch self {
        case .deleteUnlinked:
            return .notLinked
        case .deleteSending:
            return .sending
        case .deleteFailed:
            return .failed(.failed)
        case .deleteRateLimited:
            return .failed(.rateLimited)
        case .deleteDone:
            return .done
        default:
            return .form
        }
    }

    static func myDataModel(lang: String, state: SGMyDataViewModel.State) -> SGMyDataViewModel {
        let model = SGMyDataViewModel(lang: lang, state: state, timeZone: TimeZone(identifier: "Asia/Tashkent") ?? .current)
        model.reload = { SGCustomerSyncPreviewScenario.log("retry") }
        return model
    }

    var myDataState: SGMyDataViewModel.State {
        switch self {
        case .myDataError:
            return .failed(.offline)
        case .myDataNotLinked:
            return .notLinked
        default:
            return SGCustomerSyncPreviewScenario.loadedMyData
        }
    }

    /// A `GET /v1/profile/me` answer with fake values in every section.
    static var loadedMyData: SGMyDataViewModel.State {
        let body = """
        {"schema_version":1,
         "account":{"id":"acc_preview_0001","tg_user_id":\(SGCustomerSyncPreviewScenario.telegramUserId),"created_at":"2026-10-01T09:00:00Z"},
         "consent":{"state":"granted","consent_id":"9b0c0000-0000-4000-8000-000000000001","text_version":1,"locale":"uz","consent_mode":"required","effective_at":"2026-10-30T09:00:00Z"},
         "consent_history":[
          {"consent_id":"9b0c0000-0000-4000-8000-000000000001","action":"grant","scopes":["link","profile","statistics","tasks_sync"],"text_version":1,"locale":"uz","consent_mode":"required","source":"client","platform":"ios","app_version":"12.0","recorded_at":"2026-10-30T09:00:00Z","received_at":"2026-10-30T09:00:02Z","outcome":"recorded"}
         ],
         "profile":{
          "phone":{"value":"+998900000000","source":"telegram_session","observed_at":"2026-10-30T09:05:00Z"},
          "country":"UZ",
          "usernames":{"value":["preview_user"],"source":"telegram_attest","observed_at":"2026-10-30T09:05:00Z"},
          "first_name":{"value":"Preview","source":"telegram_attest","observed_at":"2026-10-30T09:05:00Z"},
          "last_name":{"value":"User","source":"client","observed_at":"2026-10-30T09:05:00Z"},
          "language_code":{"value":"uz","source":"telegram_bot","observed_at":"2026-10-30T09:05:00Z"},
          "is_premium":{"value":false,"source":"client","observed_at":"2026-10-30T09:05:00Z"}
         },
         "devices":[
          {"device_id":"dev_preview_0001","platform":"ios","device_class":"phone","device_model":"iPhone18,1","os_version":"27.0","app_version":"12.0","app_build":"1","ui_language":"uz","locale":"uz-UZ","timezone":"Asia/Tashkent","distribution":"debug","first_seen_at":"2026-10-01T09:00:00Z","last_seen_at":"2026-10-30T09:05:00Z"}
         ],
         "activity":{"first_active_at":"2026-10-01T09:00:00Z","last_active_at":"2026-10-30T09:05:00Z","active_days":12,"sessions_30d":40,"session_seconds_30d":5400},
         "events":{"retention_days":180,"total":3,"by_name":[{"name":"app.session_start","count":2},{"name":"screen.view","count":1}],"recent":[{"name":"screen.view","ts":"2026-10-30T09:05:00Z"}]},
         "subscription":{"reason":"free_access","status":"active","source":"policy","until":null},
         "retention":{"profile":"until_withdrawal","events_days":180,"activity_months":25,"consent_log_years_after_erasure":3}
        }
        """
        guard let me = SGProfileMe.decode(Data(body.utf8)) else {
            NSLog("SGCustomerSyncPreview: the My data fixture does not decode")
            return .failed(.failed)
        }
        return .loaded(me)
    }
}

/// The real screen of `scenario`, in `lang`. Taps only log; an alert a screen asks for is shown above it.
public func sgCustomerSyncPreviewController(scenario: SGCustomerSyncPreviewScenario, lang: String) -> UIViewController {
    let presenter = SGCustomerSyncPreviewPresenter()
    let present: (SGCustomerAlert) -> Void = { [weak presenter] alert in
        presenter?.present(alert)
    }
    let content: AnyView
    switch scenario.screen {
    case .wall, .prompt:
        content = AnyView(SGConsentWallRoot(model: scenario.wallModel(lang: lang, present: present)))
    case .dataConsent:
        content = AnyView(SGDataConsentView(model: scenario.dataModel(lang: lang)))
    case .withdrawAlert:
        content = AnyView(SGDataConsentView(model: scenario.dataModel(lang: lang)))
        presenter.pendingAlert = scenario.withdrawAlert(lang: lang)
    case .delete:
        content = AnyView(SGAccountDeleteView(model: SGCustomerSyncPreviewScenario.deleteModel(lang: lang, state: scenario.deleteState, billingEmphasised: scenario == .deleteBilling, present: present)))
    case .myData:
        content = AnyView(SGMyDataView(model: SGCustomerSyncPreviewScenario.myDataModel(lang: lang, state: scenario.myDataState)))
    }
    presenter.content = content
    presenter.title = "\(scenario.rawValue) · \(lang)"
    return presenter
}

/// Hosts a scenario's view; shows an alert the screen asks for (and the withdraw confirmation of its scenario once it
/// appeared).
final class SGCustomerSyncPreviewPresenter: UIViewController {
    var content: AnyView?
    var pendingAlert: SGCustomerAlert?

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemGroupedBackground
        let hosting = UIHostingController(rootView: self.content ?? AnyView(EmptyView()))
        self.addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .systemGroupedBackground
        self.view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let alert = self.pendingAlert {
            self.pendingAlert = nil
            self.present(alert)
        }
    }

    func present(_ alert: SGCustomerAlert) {
        self.present(alert.makeController(), animated: false, completion: nil)
    }
}
