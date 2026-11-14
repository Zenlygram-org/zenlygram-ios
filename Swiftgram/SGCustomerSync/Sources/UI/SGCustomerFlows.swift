import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display
import TelegramPresentationData
import SGEntitlement
import SGTasks
import SGStrings
import SGCustomerSyncCore

/// Zenlygram — the consent flows the wall's pages and Settings → Zenlygram → Data & consent share (design 40 §5.4,
/// §11.2–11.4). Main queue. They hold no decision of their own: the consent store decides what may be written, the
/// coordinator's reducer runs everything that follows a decision (`SGCustomerCoordinatorCore`), the views decide what
/// is shown from the facts read here.
///
/// - Agree / decline: `SGConsentStore.grant` with exactly the rendered text, `decline` (optional builds only).
/// - Withdraw: the confirmation (unsent Tasks changes from `SGTasksCloudRepository.unsentChangeCount`, the mode
///   sentence, the not-deliverable sentence), then `SGConsentStore.withdraw` and `SGCustomerSync.userWithdrew`: the
///   reducer publishes clearance `[]`, purges the event queue, clears the profile receipt, calls
///   `SGTasksCloudRepository.retireForConsentWithdrawal` (never the logout purge) and sends the withdraw at once when
///   linked. "Sending…" shows for up to 10 s.
/// - Deletion: the second confirmation, then `SGCustomerSync.confirmDeletion` (the `erasing` fence before the first
///   send); the outcome arrives as `SGCustomerSync.deletionDidChangeNotification`. The local erase — including
///   `SGTasksCloudRepository.purgeAfterAccountErasure` — is the reducer's.
/// - Logout (decline page): Telegram's own confirmation plus `sgTasksLogoutNotice`, the last-account warning and the
///   not-deliverable withdrawal; then `logoutFromAccount`. A linked account's pending withdraw goes out with the
///   pre-revoke final send inside `SGEntitlement.logout` (`SGAccountReconcile.finalUploads`).
/// - My data: `SGCustomerSync.fetchMyData`, in every consent state.
enum SGCustomerFlows {
    /// The longest "Sending your withdrawal…" (design 40 §11.2 step 3).
    static let sendingWindow: TimeInterval = 10

    /// Per account: until when a user-initiated withdraw send shows as sending. Main queue only.
    private static var sendingUntil: [Int64: Date] = [:]

    // MARK: - Facts

    /// What the account's consent screens show, read locally (nil while the pipeline is not active or the store
    /// cannot be read — a launch before the first unlock).
    static func facts(accountPeerId: Int64, tg: Int64) -> SGDataConsentFacts? {
        let sync = SGCustomerSync.shared
        guard sync.isActive, let store = sync.consentStore, let authority = sync.customerDataAuthority, store.isReadable else {
            return nil
        }
        let entitlement = SGEntitlement.shared
        let record = store.record(tg: tg)
        var facts = SGDataConsentFacts()
        facts.record = record
        facts.storedNotice = store.storedNotice(tg: tg)
        if let consentId = record?.consentId {
            facts.recordAcked = store.isAcked(tg: tg, authority: authority, consentId: consentId)
        }
        if record?.state == .granted {
            facts.grantRejection = store.latestGrantRejection(tg: tg, authority: authority)
        }
        let sessionEnd = entitlement.sessionEnd(accountPeerId: accountPeerId).map(SGCustomerSync.sessionEnd)
        let handled = SGCustomerLinkState.Handled(jsonObject: store.jsonObject(.linkEnded(tg: tg, authority: authority)))
        facts.linkEnded = SGCustomerLinkState.linkEnded(record: record, sessionEnd: sessionEnd, handled: handled)
        facts.isLinked = entitlement.isLinked(accountPeerId: accountPeerId)
        facts.sending = SGCustomerFlows.isSending(accountPeerId: accountPeerId)
        facts.hasPendingWithdraw = !store.pendingWithdraws(tg: tg, authority: authority).isEmpty
        facts.deletedNotice = store.deletedNotice(tg: tg) != nil
        return facts
    }

    /// The wall policy's inputs (design 40 §4.6) from the facts; nil facts = unreadable (`.deferred`).
    static func wallInputs(facts: SGDataConsentFacts?, mode: SGConsentMode, texts: SGConsentTextRepository, operatorValues: SGConsentOperatorValues) -> SGConsentWallInputs {
        guard let facts = facts else {
            return SGConsentWallInputs(mode: mode, readable: false, record: nil, storedNotice: nil, bundledCurrentVersion: texts.currentVersion, bundledMinValidVersion: texts.minValidVersion, renderedSha256ForRecord: nil, latestGrantRejection: nil, linkEnded: false, deletedNotice: false)
        }
        var rendered: String?
        if let record = facts.record, record.state == .granted, let version = record.textVersion, let locale = record.locale {
            rendered = texts.renderedSha256(version: version, locale: locale, operatorValues: operatorValues)
        }
        return SGConsentWallInputs(mode: mode, readable: true, record: facts.record, storedNotice: facts.storedNotice, bundledCurrentVersion: texts.currentVersion, bundledMinValidVersion: texts.minValidVersion, renderedSha256ForRecord: rendered, latestGrantRejection: facts.grantRejection, linkEnded: facts.linkEnded, deletedNotice: facts.deletedNotice)
    }

    // MARK: - Decisions

    /// "I agree": the grant of exactly `text` (what the wall rendered), written and read back before this returns;
    /// `now` is the server-offset clock (design 40 §4.5). False = nothing was written (`Consent.Wall.SaveFailed`).
    static func grant(tg: Int64, text: SGConsentRenderedText) -> Bool {
        let sync = SGCustomerSync.shared
        guard let store = sync.consentStore, let mode = sync.consentMode else {
            return false
        }
        let now = SGEntitlement.shared.entitlementClock.effectiveNow()
        if case .success = store.grant(tg: tg, text: text, mode: mode, appVersion: SGDeviceInfo.appVersion, now: now) {
            return true
        }
        return false
    }

    /// The prompt's "I don't agree" or close glyph (U rule 1.3): `declined` in optional builds; `.notAllowed` where a
    /// decline is not a state (required builds, a withdrawn record).
    static func declinePrompt(tg: Int64) -> Result<Void, SGConsentStoreError> {
        let sync = SGCustomerSync.shared
        guard let store = sync.consentStore, let mode = sync.consentMode else {
            return .failure(.notAllowed)
        }
        return store.decline(tg: tg, mode: mode)
    }

    // MARK: - Withdrawal (design 40 §11.2)

    /// Shows the withdraw confirmation; on Withdraw, withdraws and calls `withdrew`. "Delete instead" (ui-strings §4)
    /// withdraws nothing and calls `deleteInstead`.
    static func confirmWithdrawal(accountPeerId: Int64, tg: Int64, lang: String, locale: SGConsentLocale, context: AccountContext, presenter: ViewController?, deleteInstead: (() -> Void)?, withdrew: (() -> Void)?) {
        guard let mode = SGCustomerSync.shared.consentMode else {
            return
        }
        let alert = SGCustomerAlert.withdrawConfirmation(
            lang: lang,
            unsentChanges: SGTasksCloudRepository.unsentChangeCount(accountPeerId: accountPeerId),
            mode: mode,
            isLinked: SGEntitlement.shared.isLinked(accountPeerId: accountPeerId),
            withdraw: { [weak presenter] in
                if SGCustomerFlows.withdraw(accountPeerId: accountPeerId, tg: tg, locale: locale) {
                    withdrew?()
                } else {
                    let failed = SGCustomerAlert(title: "", message: "Consent.Wall.SaveFailed".i18n(lang), actions: [
                        SGCustomerAlert.Action(title: "Common.Close".i18n(lang), style: .cancel, handler: {}),
                    ])
                    SGCustomerFlows.present(failed, on: presenter, context: context)
                }
            },
            deleteInstead: deleteInstead
        )
        SGCustomerFlows.present(alert, on: presenter, context: context)
    }

    /// The withdraw itself (C§6.7): the store appends the withdraw event and writes `withdrawn` (read back) before this
    /// returns; the coordinator then runs gate → queue → receipt → Tasks retire and sends at once when linked.
    static func withdraw(accountPeerId: Int64, tg: Int64, locale: SGConsentLocale) -> Bool {
        let sync = SGCustomerSync.shared
        guard let store = sync.consentStore, let mode = sync.consentMode, let authority = sync.customerDataAuthority else {
            return false
        }
        let now = SGEntitlement.shared.entitlementClock.effectiveNow()
        guard case .success = store.withdraw(tg: tg, authority: authority, mode: mode, locale: locale, appVersion: SGDeviceInfo.appVersion, now: now) else {
            return false
        }
        SGCustomerFlows.beginSending(accountPeerId: accountPeerId)
        sync.userWithdrew(accountPeerId: accountPeerId)
        return true
    }

    /// Retry of a withdrawal that did not reach the server (`DataConsent.Status.WithdrawPending`).
    static func retryWithdrawal(accountPeerId: Int64) {
        SGCustomerFlows.beginSending(accountPeerId: accountPeerId)
        SGCustomerSync.shared.userWithdrew(accountPeerId: accountPeerId)
        SGCustomerFlows.postSummaryChange(accountPeerId: accountPeerId)
    }

    /// The user-initiated withdraw send is running and its 10 s are not over.
    static func isSending(accountPeerId: Int64) -> Bool {
        guard let until = SGCustomerFlows.sendingUntil[accountPeerId], until > Date() else {
            return false
        }
        return SGCustomerSync.shared.isInFlight(.consents, accountPeerId: accountPeerId)
    }

    private static func beginSending(accountPeerId: Int64) {
        SGCustomerFlows.sendingUntil[accountPeerId] = Date().addingTimeInterval(SGCustomerFlows.sendingWindow)
        DispatchQueue.main.asyncAfter(deadline: .now() + SGCustomerFlows.sendingWindow + 0.1) {
            if let until = SGCustomerFlows.sendingUntil[accountPeerId], until <= Date() {
                SGCustomerFlows.sendingUntil[accountPeerId] = nil
            }
            // The progress gives way to the delivery status.
            SGCustomerFlows.postSummaryChange(accountPeerId: accountPeerId)
        }
    }

    private static func postSummaryChange(accountPeerId: Int64) {
        NotificationCenter.default.post(name: SGCustomerSync.consentSummaryDidChangeNotification, object: nil, userInfo: [SGCustomerSync.accountPeerIdKey: accountPeerId])
    }

    // MARK: - Logout and other accounts (design 40 §5.4)

    /// "Log out of this account": Telegram's logout confirmation of THIS account, with the Tasks notice, the
    /// last-account warning and, when an un-acked withdraw exists and there is no binding to send it with, that it
    /// cannot be delivered from here.
    static func confirmLogout(context: AccountContext, tg: Int64, lang: String, isLastAccount: Bool, presenter: ViewController?) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let accountPeerId = context.account.peerId.toInt64()
        let sync = SGCustomerSync.shared
        var notDeliverable = false
        if let store = sync.consentStore, let authority = sync.customerDataAuthority, store.isReadable {
            notDeliverable = !store.pendingWithdraws(tg: tg, authority: authority).isEmpty && !SGEntitlement.shared.isLinked(accountPeerId: accountPeerId)
        }
        let alert = SGCustomerAlert.logoutConfirmation(
            lang: lang,
            title: presentationData.strings.Settings_LogoutConfirmationTitle,
            text: presentationData.strings.Settings_LogoutConfirmationText,
            cancel: presentationData.strings.Common_Cancel,
            confirm: presentationData.strings.Common_OK,
            tasksNotice: sgTasksLogoutNotice(accountPeerId: accountPeerId, languageCode: lang, genericNotice: "Tasks.Cloud.LogoutNotice".i18n(lang)),
            isLastAccount: isLastAccount,
            withdrawalNotDeliverable: notDeliverable,
            logout: {
                let _ = logoutFromAccount(id: context.account.id, accountManager: context.sharedContext.accountManager, alreadyLoggedOutRemotely: false).startStandalone()
            }
        )
        SGCustomerFlows.present(alert, on: presenter, context: context)
    }

    /// "Use another account": the other signed-in accounts; choosing one makes it primary (its own wall decides then).
    static func chooseAccount(context: AccountContext, lang: String, presenter: ViewController?) {
        let accountId = context.account.id
        let _ = (context.sharedContext.activeAccountsWithInfo
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { [weak presenter] value in
            let others = value.accounts.filter { $0.account.id != accountId }
            guard !others.isEmpty else {
                return
            }
            var actions = others.map { info -> SGCustomerAlert.Action in
                let id = info.account.id
                return SGCustomerAlert.Action(title: SGCustomerFlows.accountTitle(info.peer), style: .normal, handler: {
                    context.sharedContext.switchToAccount(id: id, fromSettingsController: nil, withChatListController: nil)
                })
            }
            actions.append(SGCustomerAlert.Action(title: "Common.Cancel".i18n(lang), style: .cancel, handler: {}))
            SGCustomerFlows.present(SGCustomerAlert(title: "Consent.Declined.SwitchAccount".i18n(lang), message: "", actions: actions), on: presenter, context: context)
        })
    }

    /// An account as the wall names it (name, else @username, else the masked phone).
    static func accountTitle(_ peer: EnginePeer) -> String {
        guard case let .user(user) = peer else {
            return "—"
        }
        let username = user.usernames.first(where: { $0.flags.contains(.isActive) })?.username ?? user.username
        return SGProfileReader.accountLine(firstName: user.firstName, lastName: user.lastName, username: username, phone: user.phone) ?? "—"
    }

    // MARK: - My data (design 40 §11.3)

    static func myDataModel(accountPeerId: Int64, lang: String) -> SGMyDataViewModel {
        let model = SGMyDataViewModel(lang: lang)
        let loader = SGMyDataLoader(accountPeerId: accountPeerId)
        model.lifetime.append(loader)
        model.reload = { [weak model, weak loader] in
            guard let model = model, let loader = loader else {
                return
            }
            loader.load(into: model)
        }
        model.appeared = {
            SGAnalytics.screen(.zgMyData, accountPeerId: accountPeerId)
        }
        model.reload()
        return model
    }

    static func myDataState(_ result: SGCustomerSync.MyData) -> SGMyDataViewModel.State {
        switch result {
        case let .loaded(me):
            return .loaded(me)
        case .notLinked:
            return .notLinked
        case .offline:
            return .failed(.offline)
        case .unavailable:
            return .failed(.unavailable)
        case .rateLimited:
            return .failed(.rateLimited)
        case .failed, .inProgress:
            return .failed(.failed)
        }
    }

    // MARK: - Deletion (design 40 §11.4)

    /// The deletion screen of the account in `context`. `holdsWall` (Settings): the wall is held from the
    /// confirmation until Done, so the done state stays visible; inside the wall nothing is held.
    static func deleteModel(context: AccountContext, lang: String, presenter: @escaping () -> ViewController?, holdsWall: Bool, finished: @escaping () -> Void) -> SGAccountDeleteViewModel {
        let accountPeerId = context.account.peerId.toInt64()
        let sync = SGCustomerSync.shared
        var state: SGAccountDeleteViewModel.State = SGEntitlement.shared.isLinked(accountPeerId: accountPeerId) ? .form : .notLinked
        if sync.isInFlight(.delete, accountPeerId: accountPeerId) {
            state = .sending
        } else if case let .pending(notice)? = sync.deletionReport(accountPeerId: accountPeerId) {
            state = SGCustomerFlows.deleteState(.pending(notice))
        }
        // The billing paragraph and Apple's "Manage subscription" link describe an App Store subscription, so they
        // appear only where one can exist (D1, 2026-11-11): the Apple backend is on AND either the signed policy is
        // PAID (a subscription may be bought) or this account HOLDS Pro — the one holder notion every Pro surface
        // shares (`sgProEntryIsVisible` is `sgProSurfacesVisible` with the Settings row's `holdsPro`: an active or
        // billing-retry StoreKit status, a manageable snapshot, or a genuine grant). A subscriber who paid under
        // another Apple ID and linked keeps the warning after a flip back to free: that subscription does keep
        // renewing. `isAppleBackendEnabled` stays in front because `sgProSurfacesVisible` is true with the Apple
        // backend HELD (`apple_backend_enabled: false`): nothing was ever sold through the App Store for this app,
        // and while the policy is FREE a non-holder has no subscription to be warned about — no Pro-branded chrome
        // either way. The emphasis alone follows StoreKit's own evidence on this device.
        let entitlement = SGEntitlement.shared
        let hasManageableStoreKitSubscription = entitlement.manageableStoreKitSnapshot != nil
        let showsBilling = entitlement.isAppleBackendEnabled && context.sharedContext.sgProEntryIsVisible(context: context)
        let model = SGAccountDeleteViewModel(lang: lang, state: state, billingEmphasised: hasManageableStoreKitSubscription, showsBilling: showsBilling)
        let session = SGAccountDeleteSession(accountPeerId: accountPeerId, tg: context.account.peerId.id._internalGetInt64Value(), holdsWall: holdsWall)
        session.model = model
        model.lifetime.append(session)
        model.presentAlert = { alert in
            SGCustomerFlows.present(alert, on: presenter(), context: context)
        }
        model.confirm = { [weak session] in
            session?.confirm()
        }
        model.openURL = { url in
            SGCustomerFlows.open(url, context: context)
        }
        model.finish = { [weak session] in
            session?.finish()
            finished()
        }
        model.appeared = {
            SGAnalytics.screen(.zgAccountDelete, accountPeerId: accountPeerId)
        }
        return model
    }

    static func deleteState(_ report: SGCustomerDeletion.Report) -> SGAccountDeleteViewModel.State {
        let notice: SGCustomerDeletion.Notice
        switch report {
        case .deleted:
            return .done
        case let .notDeleted(value), let .pending(value):
            notice = value
        }
        switch notice {
        case .failed:
            return .failed(.failed)
        case .notLinked:
            return .notLinked
        case .offline:
            return .failed(.offline)
        case .unavailable:
            return .failed(.unavailable)
        case .rateLimited:
            return .failed(.rateLimited)
        case .inProgress:
            return .sending
        }
    }

    // MARK: - Presentation

    /// Safari, through the application bindings (design 40 §4.3): not an in-app browser, and unaffected by the wall's
    /// deep-link guard.
    static func open(_ url: URL, context: AccountContext) {
        context.sharedContext.applicationBindings.openUrl(url.absoluteString)
    }

    /// An alert above `presenter` (the wall or the Settings screen), else above the main window.
    static func present(_ alert: SGCustomerAlert, on presenter: ViewController?, context: AccountContext?) {
        let controller = alert.makeController()
        if let presenter = presenter, presenter.isViewLoaded, presenter.view.window != nil {
            presenter.present(controller, animated: true, completion: nil)
        } else {
            context?.sharedContext.mainWindow?.presentNative(controller)
        }
    }
}

/// Zenlygram — one My data screen's requests: one at a time; a result arrives on the main queue.
final class SGMyDataLoader {
    private let accountPeerId: Int64
    private var isLoading = false

    init(accountPeerId: Int64) {
        self.accountPeerId = accountPeerId
    }

    func load(into model: SGMyDataViewModel) {
        guard !self.isLoading else {
            return
        }
        guard SGEntitlement.shared.isLinked(accountPeerId: self.accountPeerId) else {
            // Not linked here: nothing to ask (`MyData.NotLinked`).
            model.state = .notLinked
            return
        }
        self.isLoading = true
        model.state = .loading
        let accountPeerId = self.accountPeerId
        let deliver: (SGCustomerSync.MyData) -> Void = { [weak self, weak model] result in
            self?.isLoading = false
            model?.state = SGCustomerFlows.myDataState(result)
        }
        Task {
            let result = await SGCustomerSync.shared.fetchMyData(accountPeerId: accountPeerId)
            SGMainQueue.deliver(result, to: deliver)
        }
    }
}

/// Zenlygram — one deletion screen's link to the coordinator: the confirmed request, its outcome
/// (`deletionDidChangeNotification`), the wall hold of the Settings screen, and Done (the deleted notice was shown).
final class SGAccountDeleteSession {
    private let accountPeerId: Int64
    private let tg: Int64
    private let holdsWall: Bool
    weak var model: SGAccountDeleteViewModel?
    private var hold: Disposable?
    private var observer: NSObjectProtocol?

    init(accountPeerId: Int64, tg: Int64, holdsWall: Bool) {
        self.accountPeerId = accountPeerId
        self.tg = tg
        self.holdsWall = holdsWall
        self.observer = NotificationCenter.default.addObserver(forName: SGCustomerSync.deletionDidChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self = self, notification.userInfo?[SGCustomerSync.accountPeerIdKey] as? Int64 == self.accountPeerId else {
                return
            }
            if let report = SGCustomerSync.shared.deletionReport(accountPeerId: self.accountPeerId) {
                self.model?.state = SGCustomerFlows.deleteState(report)
            }
        })
    }

    deinit {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        self.hold?.dispose()
    }

    /// Both confirmations given: the core writes the fence, then sends.
    func confirm() {
        if self.holdsWall, self.hold == nil {
            // Settings in a required build: the wall would cover the done state the moment the erase lands.
            self.hold = SGCustomerSync.shared.holdWall(accountPeerId: self.accountPeerId)
        }
        self.model?.state = .sending
        if let report = SGCustomerSync.shared.confirmDeletion(accountPeerId: self.accountPeerId) {
            self.model?.state = SGCustomerFlows.deleteState(report)
        }
    }

    /// Done: the done text was shown, so the deleted notice goes; then the wall may come back.
    func finish() {
        _ = SGCustomerSync.shared.consentStore?.clearDeletedNotice(tg: self.tg)
        self.hold?.dispose()
        self.hold = nil
    }
}
