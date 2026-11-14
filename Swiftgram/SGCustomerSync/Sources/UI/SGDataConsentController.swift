import Foundation
import UIKit
import SwiftUI
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display
import TelegramPresentationData
import SGSwiftUI
import SGEntitlement
import SGStrings
import SGCustomerSyncCore

extension SGCustomerSync {
    /// Settings → Zenlygram → Data & consent of the account in `context` (design 40 §11.2), pushed by Settings
    /// (`SGSettingsController`, I-6). Its sub-screens — the consent text, My data and the deletion — are pushed on the
    /// same navigation controller.
    public func dataAndConsentController(context: AccountContext) -> ViewController {
        assert(Thread.isMainThread)
        return SGDataConsentScreen.make(context: context)
    }
}

/// Zenlygram — builds Data & consent and its sub-screens as `LegacySwiftUIController`s over the pure views.
enum SGDataConsentScreen {
    static func make(context: AccountContext) -> ViewController {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        let accountPeerId = context.account.peerId.toInt64()
        let tg = context.account.peerId.id._internalGetInt64Value()
        let sync = SGCustomerSync.shared
        let values = sync.operatorValues
        #if DEBUG
        let showsDebugReset = true
        #else
        let showsDebugReset = false
        #endif
        let model = SGDataConsentViewModel(
            lang: lang,
            facts: SGCustomerFlows.facts(accountPeerId: accountPeerId, tg: tg) ?? SGDataConsentFacts(),
            operatorName: values.displayValue(.name) ?? "{{\(SGConsentOperatorValues.Field.name.placeholder)}}",
            operatorEmail: values.displayValue(.contactEmail) ?? "{{\(SGConsentOperatorValues.Field.contactEmail.placeholder)}}",
            hasPrivacyPolicy: sync.privacyPolicyURL != nil,
            showsDebugReset: showsDebugReset
        )
        let controller = SGDataConsentScreen.controller(title: "DataConsent.Title".i18n(lang), presentationData: presentationData) { legacyController in
            SGSwiftUIView<SGDataConsentView>(legacyController: legacyController, manageSafeArea: true, content: {
                SGDataConsentView(model: model)
            })
        }
        model.lifetime.append(SGDataConsentBinder(model: model, accountPeerId: accountPeerId, tg: tg))

        let push: (ViewController) -> Void = { [weak controller] next in
            (controller?.navigationController as? NavigationController)?.pushViewController(next)
        }
        model.actions.readText = {
            push(SGDataConsentScreen.consentText(context: context, tg: tg, presentationData: presentationData))
        }
        model.actions.myData = {
            push(SGDataConsentScreen.myData(model: SGCustomerFlows.myDataModel(accountPeerId: accountPeerId, lang: lang), presentationData: presentationData))
        }
        model.actions.grant = {
            sync.presentConsentPrompt(context: context)
        }
        let openDelete: () -> Void = {
            push(SGDataConsentScreen.delete(context: context, lang: lang, presentationData: presentationData))
        }
        model.actions.delete = openDelete
        model.actions.withdraw = { [weak controller, weak model] in
            SGCustomerFlows.confirmWithdrawal(accountPeerId: accountPeerId, tg: tg, lang: lang, locale: SGConsentLocale.forWall(languageCode: lang), context: context, presenter: controller, deleteInstead: openDelete, withdrew: {
                model?.refresh(accountPeerId: accountPeerId, tg: tg)
            })
        }
        model.actions.privacyPolicy = {
            if let url = sync.privacyPolicyURL {
                SGCustomerFlows.open(url, context: context)
            }
        }
        model.actions.retry = { [weak model] in
            SGCustomerFlows.retryWithdrawal(accountPeerId: accountPeerId)
            model?.refresh(accountPeerId: accountPeerId, tg: tg)
        }
        model.actions.openURL = { url in
            SGCustomerFlows.open(url, context: context)
        }
        model.actions.resetDebug = { [weak model] in
            _ = sync.consentStore?.resetForDebug(tg: tg)
            model?.refresh(accountPeerId: accountPeerId, tg: tg)
        }
        model.actions.appeared = {
            SGAnalytics.screen(.zgDataConsent, accountPeerId: accountPeerId)
        }
        return controller
    }

    /// Data & consent → Consent text: the version and locale the account agreed to, else the current text in the
    /// app language's text locale; read only.
    static func consentText(context: AccountContext, tg: Int64, presentationData: PresentationData) -> ViewController {
        let sync = SGCustomerSync.shared
        let lang = presentationData.strings.baseLanguageCode
        let record = sync.consentStore?.record(tg: tg)
        var rendered: SGConsentRenderedText?
        if let texts = sync.consentTexts {
            if let version = record?.textVersion, let locale = record?.locale, texts.isBundled(version: version) {
                rendered = texts.render(version: version, locale: locale, operatorValues: sync.operatorValues)
            }
            if rendered == nil {
                rendered = texts.render(version: texts.currentVersion, locale: SGConsentLocale.forWall(languageCode: lang), operatorValues: sync.operatorValues)
            }
        }
        let document = rendered?.document ?? SGConsentDocument(blocks: [.paragraph(runs: [SGConsentRun(text: "Consent.Wall.TextUnavailable".i18n(lang))])], ageStatementIndex: nil)
        return SGDataConsentScreen.controller(title: "DataConsent.ReadText".i18n(lang), presentationData: presentationData) { legacyController in
            SGSwiftUIView<SGConsentTextPage>(legacyController: legacyController, manageSafeArea: true, content: {
                SGConsentTextPage(document: document, openURL: { url in
                    SGCustomerFlows.open(url, context: context)
                })
            })
        }
    }

    static func myData(model: SGMyDataViewModel, presentationData: PresentationData) -> ViewController {
        return SGDataConsentScreen.controller(title: "MyData.Title".i18n(model.lang), presentationData: presentationData) { legacyController in
            SGSwiftUIView<SGMyDataView>(legacyController: legacyController, manageSafeArea: true, content: {
                SGMyDataView(model: model)
            })
        }
    }

    /// The deletion screen of Settings: the wall is held from the confirmation until Done (design 40 §11.4), and
    /// Done closes the screen (a required build then shows the wall, state `none`).
    static func delete(context: AccountContext, lang: String, presentationData: PresentationData) -> ViewController {
        var close: (() -> Void)?
        let model = SGCustomerFlows.deleteModel(context: context, lang: lang, presenter: {
            return nil
        }, holdsWall: true, finished: {
            close?()
        })
        let controller = SGDataConsentScreen.controller(title: "AccountDelete.Title".i18n(lang), presentationData: presentationData) { legacyController in
            SGSwiftUIView<SGAccountDeleteView>(legacyController: legacyController, manageSafeArea: true, content: {
                SGAccountDeleteView(model: model)
            })
        }
        model.presentAlert = { [weak controller] alert in
            SGCustomerFlows.present(alert, on: controller, context: context)
        }
        close = { [weak controller] in
            controller?.dismiss()
        }
        return controller
    }

    /// A pushed `LegacySwiftUIController` hosting `content`, styled like the app's other SwiftUI screens.
    static func controller<Content: View>(title: String, presentationData: PresentationData, content: (LegacySwiftUIController) -> Content) -> LegacySwiftUIController {
        let controller = LegacySwiftUIController(presentation: .navigation, theme: presentationData.theme, strings: presentationData.strings)
        controller.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
        controller.title = title
        let hosting = UIHostingController(rootView: content(controller), ignoreSafeArea: true)
        hosting.overrideUserInterfaceStyle = presentationData.theme.overallDarkAppearance ? .dark : .light
        hosting.view.backgroundColor = UIColor.systemGroupedBackground
        controller.bind(controller: hosting)
        return controller
    }
}

extension SGDataConsentViewModel {
    /// Reads the account's facts again.
    func refresh(accountPeerId: Int64, tg: Int64) {
        if let facts = SGCustomerFlows.facts(accountPeerId: accountPeerId, tg: tg), facts != self.facts {
            self.facts = facts
        }
    }
}

/// Zenlygram — keeps Data & consent current while it is open: the consent store, the coordinator's summary (uploads,
/// the withdraw's delivery), SGEntitlement (link, session end) and the deletion. Removed with the screen.
final class SGDataConsentBinder {
    private var observers: [NSObjectProtocol] = []

    init(model: SGDataConsentViewModel, accountPeerId: Int64, tg: Int64) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            SGConsentStore.didChangeNotification,
            SGCustomerSync.consentSummaryDidChangeNotification,
            SGCustomerSync.deletionDidChangeNotification,
            SGEntitlement.didChangeNotification,
        ]
        for name in names {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: { [weak model] _ in
                model?.refresh(accountPeerId: accountPeerId, tg: tg)
            }))
        }
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
