import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display
import TelegramPresentationData
import SGEntitlement
import SGCustomerSyncCore

extension SGCustomerSync {
    /// The data-consent wall of the account in `context` (design 40 §5.1), called by `AuthorizedApplicationContext.init`
    /// right after the account's root controllers were added, before `isReady` is set. Synchronous and local only —
    /// the consent store, the session item and the bundled texts, never the network (I1, owner exception O1).
    ///
    /// When the wall policy (§4.6) asks, the wall is presented as a global overlay of `rootController` (it dies with
    /// that root on an account switch and covers both iPad columns) and its `ready` is returned, so the first visible
    /// frame already holds it; otherwise `.single(true)`. From then on the account is re-evaluated on every change of
    /// its consent, its binding, protected data and the app's activity: a required build presents and dismisses on
    /// every change; an optional build prompts at most once per attach (a later change never prompts at once).
    public func attachRoot(context: AccountContext, rootController: NavigationController) -> Signal<Bool, NoError> {
        assert(Thread.isMainThread)
        self.ensureLoaded()
        guard self.isActive, !SGEntitlement.isAppExtension else {
            return .single(true)
        }
        return self.consentWallPresenter.attach(context: context, rootController: rootController)
    }

    /// While a hold exists the account's wall is not presented; it is when the last hold is disposed (design 40
    /// §5.1 step 5). The Settings deletion screen holds it so its done state stays visible.
    public func holdWall(accountPeerId: Int64) -> Disposable {
        assert(Thread.isMainThread)
        guard self.isActive else {
            return EmptyDisposable
        }
        return self.consentWallPresenter.hold(accountPeerId: accountPeerId)
    }

    /// Telegram's call screens stay above the consent wall (design 40 §5.1). `SharedAccountContextImpl` asks before it
    /// shows a call screen on `rootController`, the main window's root: while a wall is up there, the screen goes above
    /// it as a later global overlay of that root, not by Telegram's push or `.calls` overlay (both land under the wall).
    /// `barriers`: other screens the call must stay above as well — the app-update block (update_policy_spec §4f);
    /// the topmost of the wall and the barriers decides.
    public func callScreenPlacement(_ controller: ViewController, in rootController: NavigationController, alsoAbove barriers: [ViewController] = []) -> SGCallScreenPlacement {
        assert(Thread.isMainThread)
        let wall = self.consentWallController(over: rootController)
        return SGCallScreenPlacement(of: controller, barriers: [wall].compactMap { $0 } + barriers, stack: rootController.viewControllers, overlays: rootController.overlayControllers, globalOverlays: rootController.globalOverlayControllers)
    }

    /// The wall (or prompt) up on `rootController`, whichever account it belongs to — for `callScreenPlacement`, and
    /// for the app-update block's z-order (update_policy_spec §4f: the block stays above the wall).
    public func consentWallController(over rootController: NavigationController) -> ViewController? {
        assert(Thread.isMainThread)
        return (self.wallPresenter as? SGConsentWallPresenter)?.wallController(over: rootController)
    }

    /// Data & consent → Give consent (design 40 §11.2): the consent screen as a prompt, whatever the policy says,
    /// until the user decides.
    func presentConsentPrompt(context: AccountContext) {
        assert(Thread.isMainThread)
        guard self.isActive else {
            return
        }
        self.consentWallPresenter.presentPrompt(context: context)
    }

    var consentWallPresenter: SGConsentWallPresenter {
        if let presenter = self.wallPresenter as? SGConsentWallPresenter {
            return presenter
        }
        let presenter = SGConsentWallPresenter()
        self.wallPresenter = presenter
        return presenter
    }
}

/// Zenlygram — presents, updates and takes down every account's consent wall (design 40 §5.1–5.2). Main queue.
///
/// Each attached account root has an entry `{account, root (weak), wall?, token, holds}`. A decision is made from
/// local state only (`SGConsentWallPolicy.decide`) and a normalisation (`granted → needs_reconsent`) is persisted only
/// while the store is readable; `.deferred` (a launch before the first unlock) changes nothing on screen.
final class SGConsentWallPresenter: SGConsentWallPresenting {
    private final class Entry {
        let accountPeerId: Int64
        /// The RAW Telegram user id (the consent store's key).
        let tg: Int64
        weak var context: AccountContext?
        weak var rootController: NavigationController?
        var model: SGConsentWallViewModel?
        var wall: SGConsentWallController?
        var token = UUID()
        /// Optional builds: this attach's one prompt was decided (shown, or not needed).
        var promptDecided = false
        /// Optional builds: Vazifalar was opened in this attach, so the account's FIRST prompt (state `none`) may be
        /// shown (wf15 §6.2, D1); false at attach. The other prompts keep the attach timing (`SGOptionalPromptTiming`).
        var promptArmed = false
        /// Give consent from Settings: the prompt stays until the user decides.
        var isForcedPrompt = false
        /// The wall shows the deleted notice it found (the stored one is removed once shown, §4.4) until it goes.
        var showsDeletedNotice = false
        var deletedNoticeCleared = false
        /// `presentOverlay` is running (it reports overlay changes synchronously).
        var isPresenting = false
        let identity = MetaDisposable()
        let accounts = MetaDisposable()

        init(accountPeerId: Int64, tg: Int64) {
            self.accountPeerId = accountPeerId
            self.tg = tg
        }

        deinit {
            self.identity.dispose()
            self.accounts.dispose()
        }
    }

    /// The raiser of a root's in-call bar while a wall is up (the app-update block is the other one).
    static let inCallBarRaiser = "zg.consent.wall"

    private var entries: [Int64: Entry] = [:]
    private var holds: [Int64: Int] = [:]
    private var observers: [NSObjectProtocol] = []
    private var isEvaluationScheduled = false

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Entry points

    func attach(context: AccountContext, rootController: NavigationController) -> Signal<Bool, NoError> {
        self.startObserving()
        let accountPeerId = context.account.peerId.toInt64()
        let entry: Entry
        if let existing = self.entries[accountPeerId], existing.rootController === rootController {
            entry = existing
        } else {
            if let existing = self.entries[accountPeerId] {
                // The account has a new root (it became primary again): the old root's wall goes with it.
                self.dismiss(existing)
            }
            entry = Entry(accountPeerId: accountPeerId, tg: context.account.peerId.id._internalGetInt64Value())
            self.entries[accountPeerId] = entry
        }
        entry.context = context
        entry.rootController = rootController
        self.evaluate(entry)
        guard let wall = entry.wall else {
            return .single(true)
        }
        return wall.ready.get()
    }

    func hold(accountPeerId: Int64) -> Disposable {
        self.holds[accountPeerId, default: 0] += 1
        return ActionDisposable(action: { [weak self] in
            Queue.mainQueue().async {
                guard let self = self else {
                    return
                }
                let remaining = (self.holds[accountPeerId] ?? 1) - 1
                self.holds[accountPeerId] = remaining > 0 ? remaining : nil
                self.scheduleEvaluation()
            }
        })
    }

    func presentPrompt(context: AccountContext) {
        self.startObserving()
        let accountPeerId = context.account.peerId.toInt64()
        let entry: Entry
        if let existing = self.entries[accountPeerId], existing.rootController != nil {
            entry = existing
        } else {
            // No root attached for the account (yet): its current root is the main window's.
            guard let root = context.sharedContext.mainWindow?.viewController as? NavigationController else {
                return
            }
            entry = Entry(accountPeerId: accountPeerId, tg: context.account.peerId.id._internalGetInt64Value())
            entry.context = context
            entry.rootController = root
            self.entries[accountPeerId] = entry
        }
        guard entry.wall == nil else {
            return
        }
        entry.isForcedPrompt = true
        self.evaluate(entry)
    }

    /// The first open of Vazifalar (wf15 §6.2, D1 "bir marta"): from now on this attach may show the account's first
    /// prompt (state `none`), which no longer goes up at attach in an optional build. Evaluates at once and returns
    /// whether a prompt is now up. Required builds never call this (`SGCustomerSync.tasksPromptIfUndecided`); an account
    /// whose root is not attached has nothing to arm. By account id so the app-side test can drive it.
    func armFirstPrompt(accountPeerId: Int64) -> Bool {
        guard let entry = self.entries[accountPeerId], entry.rootController != nil else {
            return false
        }
        entry.promptArmed = true
        self.evaluate(entry)
        guard entry.wall != nil, let model = entry.model, case .prompt = model.kind else {
            return false
        }
        return true
    }

    // MARK: - SGConsentWallPresenting

    func isWallPresented(accountPeerId: Int64) -> Bool {
        guard let entry = self.entries[accountPeerId], entry.rootController != nil else {
            return false
        }
        return entry.wall != nil
    }

    func wallController(accountPeerId: Int64) -> ViewController? {
        return self.entries[accountPeerId]?.wall
    }

    /// The wall (or prompt) up on `rootController`, whichever account it belongs to (`callScreenPlacement`).
    func wallController(over rootController: NavigationController) -> ViewController? {
        for entry in self.entries.values where entry.rootController === rootController {
            if let wall = entry.wall {
                return wall
            }
        }
        return nil
    }

    /// The account root's global overlays changed: a wall taken down by anything but its presenter is presented again
    /// (the same screen, a new token). A prompt that disappeared is not a decision and is not asked again.
    func rootOverlaysChanged(accountPeerId: Int64) {
        guard let entry = self.entries[accountPeerId], !entry.isPresenting, let wall = entry.wall, let root = entry.rootController, let model = entry.model else {
            return
        }
        if root.globalOverlayControllers.contains(where: { $0 === wall }) {
            return
        }
        entry.wall = nil
        switch model.kind {
        case .wall, .textUnavailable:
            self.present(entry, kind: model.kind, facts: SGCustomerFlows.facts(accountPeerId: entry.accountPeerId, tg: entry.tg))
        case .prompt:
            self.dismiss(entry)
        }
    }

    // MARK: - Deciding

    private func startObserving() {
        guard self.observers.isEmpty else {
            return
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            SGConsentStore.didChangeNotification,
            SGEntitlement.didChangeNotification,
            SGCustomerSync.consentSummaryDidChangeNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        for name in names {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                self?.scheduleEvaluation()
            }))
        }
    }

    /// One pass over every account on the next main-queue turn (changes arrive in bursts, some from inside the
    /// coordinator's effects).
    private func scheduleEvaluation() {
        guard !self.isEvaluationScheduled else {
            return
        }
        self.isEvaluationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                return
            }
            self.isEvaluationScheduled = false
            for accountPeerId in self.entries.keys.sorted() {
                if let entry = self.entries[accountPeerId] {
                    self.evaluate(entry)
                }
            }
        }
    }

    private func evaluate(_ entry: Entry) {
        guard entry.rootController != nil else {
            // The root is gone (logout, account switch): its wall went with it.
            self.dismiss(entry)
            if self.entries[entry.accountPeerId] === entry {
                self.entries[entry.accountPeerId] = nil
            }
            return
        }
        let sync = SGCustomerSync.shared
        let loaded = sync.loaded()
        guard case .active = loaded.activation, let texts = loaded.texts, let mode = loaded.config.mode else {
            self.dismiss(entry)
            return
        }
        let facts = SGCustomerFlows.facts(accountPeerId: entry.accountPeerId, tg: entry.tg)
        let decision = SGConsentWallPolicy.decide(SGCustomerFlows.wallInputs(facts: facts, mode: mode, texts: texts, operatorValues: loaded.config.operatorValues))
        if let notice = decision.normalise, facts != nil, let store = sync.consentStore {
            _ = store.markNeedsReconsent(tg: entry.tg, notice: notice)
        }

        var kind: SGConsentWallViewModel.Kind?
        switch decision.presentation {
        case .deferred:
            // Nothing can be read: nothing is decided, and what is on screen stays.
            return
        case .none:
            kind = nil
        case let .wall(notice):
            kind = .wall(notice)
        case let .prompt(notice):
            kind = .prompt(notice)
        case .textUnavailable:
            kind = .textUnavailable
        }
        if mode == .optional {
            // One prompt per attach (wf15 §6.2): the account's first prompt waits for the first open of Vazifalar
            // (`armFirstPrompt`), every other prompt is shown at attach or at the first decision after `.deferred`,
            // never later. A prompt already on screen is updated, not re-decided.
            let timing = SGConsentWallPresenter.optionalPromptTiming(kind: kind, isWallUp: entry.wall != nil, armed: entry.promptArmed, decided: entry.promptDecided)
            kind = timing.kind
            entry.promptDecided = timing.decided
        }
        if kind == nil, entry.isForcedPrompt, let facts = facts {
            kind = .prompt(SGConsentWallPresenter.forcedNotice(facts))
        }
        if case .wall(.none)? = kind, entry.showsDeletedNotice {
            kind = .wall(.deleted)
        }

        guard let shown = kind else {
            self.dismiss(entry)
            return
        }
        if entry.wall != nil, let model = entry.model {
            SGConsentWallPresenter.apply(shown, facts: facts, to: model)
        } else if (self.holds[entry.accountPeerId] ?? 0) == 0 {
            self.present(entry, kind: shown, facts: facts)
        }
        if shown == .wall(.deleted), entry.wall != nil {
            entry.showsDeletedNotice = true
            if !entry.deletedNoticeCleared {
                // "Removed when shown" (design 40 §4.4); this wall keeps showing it while it is up.
                entry.deletedNoticeCleared = true
                _ = sync.consentStore?.clearDeletedNotice(tg: entry.tg)
            }
        }
    }

    /// An optional build's prompt timing over the policy's answer (`SGOptionalPromptTiming`, wf15 §6.2): the kind to
    /// show now (nil = nothing, or the prompt waits) and the entry's `promptDecided` after this evaluation. A wall or
    /// prompt already up keeps its kind (the model is updated in place) and counts as decided. `.prompt(.none)` is the
    /// account's first prompt (the policy asks it for state `none` only, row 8).
    static func optionalPromptTiming(kind: SGConsentWallViewModel.Kind?, isWallUp: Bool, armed: Bool, decided: Bool) -> (kind: SGConsentWallViewModel.Kind?, decided: Bool) {
        guard !isWallUp else {
            return (kind, true)
        }
        let ask: SGOptionalPromptTiming.Ask
        switch kind {
        case .prompt(.none)?:
            ask = .firstPrompt
        case .prompt?:
            ask = .otherPrompt
        case .wall?, .textUnavailable?, nil:
            // Not asked of an optional build by the policy; nothing to time.
            ask = .nothing
        }
        let outcome = SGOptionalPromptTiming.decide(ask: ask, armed: armed, decided: decided)
        if case .prompt? = kind, !outcome.shows {
            return (nil, outcome.decided)
        }
        return (kind, outcome.decided)
    }

    /// The prompt Give consent asks for, with the notice of the state it is asked from.
    private static func forcedNotice(_ facts: SGDataConsentFacts) -> SGConsentWallNotice {
        switch facts.state {
        case .needsReconsent:
            switch facts.storedNotice {
            case .operatorChanged?:
                return .operatorChanged
            case .linkEnded?:
                return .linkEnded
            default:
                return .reconsent
            }
        case .withdrawn:
            return .withdrawn
        case .withdrawnRemote:
            return .withdrawnRemote
        case .granted:
            return facts.linkEnded ? .linkEnded : .none
        case .none, .declined:
            return .none
        }
    }

    // MARK: - Showing

    private func present(_ entry: Entry, kind: SGConsentWallViewModel.Kind, facts: SGDataConsentFacts?) {
        defer { self.syncInCallBar(on: entry.rootController) }
        guard let context = entry.context, let root = entry.rootController, let model = entry.model ?? self.makeModel(entry, context: context, kind: kind) else {
            SGCustomerLog.log(.wallBuildFailed)
            return
        }
        entry.model = model
        SGConsentWallPresenter.apply(kind, facts: facts, to: model)
        let token = UUID()
        entry.token = token
        let wall = SGConsentWallController(model: model, token: token, presentationData: context.sharedContext.currentPresentationData.with { $0 })
        entry.wall = wall
        entry.isPresenting = true
        root.presentOverlay(controller: wall, inGlobal: true, blockInteraction: false)
        entry.isPresenting = false

        // Telegram's call screens stay above the wall (design 40 §5.1). A call under way when the wall goes up (answered
        // before the first unlock, or a withdrawal or an ended link during the call) is shown again: the screen the wall
        // now covers moves above it, a minimised one comes back above it (`callScreenPlacement`). Minimising a 1:1 or
        // group call later shows the wall with Telegram's in-call bar above it (`syncInCallBar`), and a tap on the bar
        // brings the call screen back above the wall; a live stream's bar does nothing while the wall is up.
        let isWindowRoot = (context.sharedContext.mainWindow?.viewController as? NavigationController) === root
        if SGConsentWallPresenter.raisesCallScreen(isForcedPrompt: entry.isForcedPrompt, hasActiveCall: context.sharedContext.callManager?.hasActiveCall ?? false, isWindowRoot: isWindowRoot) {
            context.sharedContext.navigateToCurrentCall()
        }
    }

    /// A wall that goes up on the main window's root during a call brings the call screen back above it. Not for the
    /// prompt the user opened from Settings (it can be dismissed), and not for a root the window does not show yet
    /// (`attachRoot` runs before AppDelegate installs it; a call is shown on the window's root).
    static func raisesCallScreen(isForcedPrompt: Bool, hasActiveCall: Bool, isWindowRoot: Bool) -> Bool {
        return hasActiveCall && isWindowRoot && !isForcedPrompt
    }

    /// While a wall or prompt is up on `root`, Telegram's in-call bar is drawn above it, so a minimised call stays
    /// one tap away (design 40 §5.1); once the last one on that root is gone, the bar is back at Telegram's place.
    /// Every exit of `present` and `dismiss` calls it.
    private func syncInCallBar(on root: NavigationController?) {
        guard let root = root else {
            return
        }
        // One raiser of two (the app-update block is the other): the bar drops only when neither is up.
        root.sgSetInCallStatusBarAboveGlobalOverlays(self.wallController(over: root) != nil, for: SGConsentWallPresenter.inCallBarRaiser)
    }

    private func dismiss(_ entry: Entry) {
        defer { self.syncInCallBar(on: entry.rootController) }
        entry.isForcedPrompt = false
        entry.showsDeletedNotice = false
        entry.deletedNoticeCleared = false
        entry.model = nil
        entry.identity.set(nil)
        entry.accounts.set(nil)
        guard let wall = entry.wall else {
            return
        }
        entry.wall = nil
        wall.dismissForPresenter(token: entry.token)
    }

    private static func apply(_ kind: SGConsentWallViewModel.Kind, facts: SGDataConsentFacts?, to model: SGConsentWallViewModel) {
        if model.kind != kind {
            model.kind = kind
        }
        let decidedAt = facts?.decidedAt
        if model.decidedAt != decidedAt {
            model.decidedAt = decidedAt
        }
        let delivery = facts?.withdrawalDelivery
        if model.delivery != delivery {
            model.delivery = delivery
        }
        let canWithdraw = facts?.canWithdraw ?? false
        if model.canWithdraw != canWithdraw {
            model.canWithdraw = canWithdraw
        }
    }

    /// The wall's screen state: the bundled CURRENT text in all three locales (the language control switches between
    /// them at once), opened in the app language's text locale.
    private func makeModel(_ entry: Entry, context: AccountContext, kind: SGConsentWallViewModel.Kind) -> SGConsentWallViewModel? {
        let sync = SGCustomerSync.shared
        let loaded = sync.loaded()
        guard let texts = loaded.texts, let mode = loaded.config.mode else {
            return nil
        }
        var rendered: [SGConsentLocale: SGConsentRenderedText] = [:]
        for locale in SGConsentLocale.allCases {
            rendered[locale] = texts.render(version: texts.currentVersion, locale: locale, operatorValues: loaded.config.operatorValues)
        }
        let languageCode = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        let model = SGConsentWallViewModel(kind: kind, mode: mode, texts: rendered, locale: SGConsentLocale.forWall(languageCode: languageCode), privacyPolicyURL: sync.privacyPolicyURL)
        self.wire(model, entry: entry)

        // The account line appears when the local read finishes (nothing is sent).
        entry.identity.set((sync.wallIdentity(context: context)
        |> deliverOnMainQueue).startStrict(next: { [weak model] line in
            model?.accountLine = line
        }))
        let accountId = context.account.id
        entry.accounts.set((context.sharedContext.activeAccountsWithInfo
        |> map { value -> Int in
            return value.accounts.filter { $0.account.id != accountId }.count
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).startStrict(next: { [weak model] count in
            model?.otherAccounts = count
        }))
        return model
    }

    private func wire(_ model: SGConsentWallViewModel, entry: Entry) {
        let accountPeerId = entry.accountPeerId
        let tg = entry.tg
        model.actions.agree = { [weak self, weak entry, weak model] text in
            guard let self = self, let entry = entry, let model = model else {
                return
            }
            if SGCustomerFlows.grant(tg: tg, text: text) {
                model.saveFailed = false
                entry.isForcedPrompt = false
                entry.showsDeletedNotice = false
                self.evaluate(entry)
            } else {
                model.saveFailed = true
            }
        }
        model.actions.declinePrompt = { [weak self, weak entry, weak model] in
            guard let self = self, let entry = entry, let model = model else {
                return
            }
            switch SGCustomerFlows.declinePrompt(tg: tg) {
            case .success, .failure(.notAllowed):
                // Recorded (`declined`), or nothing to record: either way the prompt goes (U rule 1.3).
                model.saveFailed = false
                self.dismiss(entry)
            case .failure:
                model.saveFailed = true
            }
        }
        model.actions.logout = { [weak entry, weak model] in
            guard let entry = entry, let context = entry.context, let model = model else {
                return
            }
            SGCustomerFlows.confirmLogout(context: context, tg: tg, lang: model.lang, isLastAccount: model.otherAccounts == 0, presenter: entry.wall)
        }
        model.actions.switchAccount = { [weak entry, weak model] in
            guard let entry = entry, let context = entry.context, let model = model else {
                return
            }
            SGCustomerFlows.chooseAccount(context: context, lang: model.lang, presenter: entry.wall)
        }
        model.actions.withdraw = { [weak entry, weak model] in
            guard let entry = entry, let context = entry.context, let model = model else {
                return
            }
            SGCustomerFlows.confirmWithdrawal(accountPeerId: accountPeerId, tg: tg, lang: model.lang, locale: model.locale, context: context, presenter: entry.wall, deleteInstead: { [weak model] in
                model?.openDelete()
            }, withdrew: { [weak model] in
                // The consent page shows the withdrawal and its delivery.
                model?.showConsent()
            })
        }
        model.actions.retryWithdrawal = {
            SGCustomerFlows.retryWithdrawal(accountPeerId: accountPeerId)
        }
        model.actions.openURL = { [weak entry] url in
            guard let context = entry?.context else {
                return
            }
            SGCustomerFlows.open(url, context: context)
        }
        model.actions.makeMyData = { lang in
            return SGCustomerFlows.myDataModel(accountPeerId: accountPeerId, lang: lang)
        }
        model.actions.makeDelete = { [weak self, weak entry] lang in
            guard let entry = entry, let context = entry.context else {
                return nil
            }
            return SGCustomerFlows.deleteModel(context: context, lang: lang, presenter: { [weak entry] in
                return entry?.wall
            }, holdsWall: false, finished: { [weak self, weak entry] in
                // Inside the wall, Done returns to the consent page (design 40 §11.4).
                guard let self = self, let entry = entry else {
                    return
                }
                entry.showsDeletedNotice = false
                entry.model?.showConsent()
                self.evaluate(entry)
            })
        }
    }
}

/// Zenlygram — where a Telegram call screen goes on an account root that may show a consent wall (design 40 §5.1:
/// calls stay above the wall). The wall is a global overlay of the root, and global overlays stack in the order they
/// are presented, above the root's overlays and its whole stack. So a pushed call screen (Telegram's flat modal) or a
/// `.calls` overlay is under the wall, and one presented as a later global overlay is above it.
/// `SharedAccountContextImpl` carries the placement out.
public enum SGCallScreenPlacement: Equatable {
    /// No wall on the root: Telegram shows the screen its own way.
    case telegram
    /// Already a global overlay above the wall: nothing to do.
    case aboveWall
    /// Taken out of where it is, then presented as a global overlay of the root, above the wall.
    case moveAboveWall(from: Origin)

    public enum Origin: Equatable {
        /// Not on the root (not on screen).
        case nowhere
        /// In the root's stack (Telegram's flat-modal push).
        case stack
        /// An overlay under the wall: a `.calls` overlay, or a global overlay presented before the wall.
        case overlay
    }

    /// `stack`, `overlays` and `globalOverlays` are the root's, bottom to top. A wall that is not among the global
    /// overlays (taken down by something else, about to be presented again) covers nothing yet.
    init(of controller: AnyObject, wall: AnyObject?, stack: [AnyObject], overlays: [AnyObject], globalOverlays: [AnyObject]) {
        self.init(of: controller, barriers: wall.map { [$0] } ?? [], stack: stack, overlays: overlays, globalOverlays: globalOverlays)
    }

    /// `barriers`: every screen the call must stay above — the consent wall, the app-update block (update_policy_spec
    /// §4f) — in any order; the TOPMOST of them among the global overlays decides, and one that is not among the
    /// global overlays (taken down by something else, about to be presented again) covers nothing yet.
    public init(of controller: AnyObject, barriers: [AnyObject], stack: [AnyObject], overlays: [AnyObject], globalOverlays: [AnyObject]) {
        let barrierIndices = barriers.compactMap { barrier in
            return globalOverlays.firstIndex(where: { $0 === barrier })
        }
        guard let wallIndex = barrierIndices.max() else {
            self = .telegram
            return
        }
        if let index = globalOverlays.firstIndex(where: { $0 === controller }) {
            self = index > wallIndex ? .aboveWall : .moveAboveWall(from: .overlay)
        } else if stack.contains(where: { $0 === controller }) {
            self = .moveAboveWall(from: .stack)
        } else if overlays.contains(where: { $0 === controller }) {
            self = .moveAboveWall(from: .overlay)
        } else {
            self = .moveAboveWall(from: .nowhere)
        }
    }
}
