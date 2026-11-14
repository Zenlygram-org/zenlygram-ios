import Foundation
import UIKit
import SwiftSignalKit
import Display
import SGEntitlement
import SGSimpleSettings
import SGLogging

// MARK: - The app's entry points (`SGAppUpdate.shared`)

/// Zenlygram — the presenter half of the app-update policy (update_policy_spec §4e–h), as extensions
/// of the Foundation-only holder `SGAppUpdate` (SGEntitlement), for its `shared` instance: the holder
/// reads the decision, this module shows it — the block, the reminder, the QA override. Main queue.
extension SGAppUpdate {
    /// AppDelegate, once the build configuration is known and before any root exists
    /// (`didFinishLaunching`): the first frame already knows the QA override and the TestFlight variant.
    public func configure(environment: SGAppUpdateEnvironment) {
        SGAppUpdatePresenter.shared.configure(environment: environment)
    }

    /// FIRST FRAME (§4e). Called synchronously when a root is created: by `AuthorizedApplicationContext
    /// .init` right after the account's root controllers were added (before `isReady` is set), and by
    /// AppDelegate right before the login root is presented. The decision is `restoreDecision()`: the
    /// stored, re-verified token, no network. A known-blocked install gets the block presented on `root`
    /// as a global overlay before the root is ever shown, and the block's `ready` is returned so the
    /// authorized root's readiness waits for it, like the consent wall's; otherwise `.single(true)`.
    /// The +8 s fetch only refines or lifts. A later root of the same kind (an account switch, a login)
    /// gets a block of its own; the root it replaces KEEPS its block until the new root is on screen
    /// (`rootDidAppear`) — the previous account's chat list stays covered while the new root loads.
    public func attachRoot(_ root: NavigationController, kind: SGAppUpdateRootKind) -> Signal<Bool, NoError> {
        return SGAppUpdatePresenter.shared.attach(root: root, kind: kind)
    }

    /// AppDelegate put `root` on screen: the authorized root became the main window's root (`isReady`
    /// fired, `mainWindow.viewController = root`), or the login root was presented over it. The roots
    /// of the same kind it replaced are off screen now, so their blocks go with them; and this is the
    /// moment the reminder's idle activation is measured from (§4g) — never before the root is shown.
    public func rootDidAppear(_ root: NavigationController) {
        SGAppUpdatePresenter.shared.rootDidAppear(root)
    }

    /// The root's global overlays changed (`NavigationController.globalOverlayControllersUpdated`): a
    /// block removed by anything but its presenter is presented again, and a block the consent wall
    /// came up above is presented again above the wall (§4f: block above the wall, call screens
    /// above the block). `consentWall`: the wall up on that root, if any.
    public func rootOverlaysChanged(root: NavigationController, consentWall: ViewController?) {
        SGAppUpdatePresenter.shared.rootOverlaysChanged(root: root, consentWall: consentWall)
    }

    /// A block is up on a live root: deep links, notification taps and root shortcuts are dropped,
    /// as behind the consent wall (`AuthorizedApplicationContext`).
    public var isBlockPresented: Bool {
        return SGAppUpdatePresenter.shared.isBlockPresented
    }

    /// The block up on `root`, for `SGCallScreenPlacement`: a call screen is placed above it.
    public func blockController(over root: NavigationController) -> ViewController? {
        return SGAppUpdatePresenter.shared.blockController(over: root)
    }

    /// A notification tap, a deep link, a user activity or a home-screen shortcut reached AppDelegate:
    /// this activation is not idle, and the reminder waits for the next one (§4g).
    public func noteExternalActivation() {
        SGAppUpdatePresenter.shared.noteExternalActivation()
    }

    #if SG_APP_UPDATE_DEBUG_OVERRIDE
    /// Debug Settings changed the QA override (`SGSimpleSettings.appUpdateDebugOverride`, §4h): the
    /// decision is re-read at once, and a `remind` override offers its alert on this activation — a
    /// signed policy adopted mid-session never does (`decisionDidChange` only re-evaluates the block).
    /// Non-store builds only: the override is compiled out of a store build with its Debug row.
    public func debugOverrideDidChange() {
        SGAppUpdatePresenter.shared.debugOverrideDidChange()
    }
    #endif
}

/// The decision source the presenter reads: `SGAppUpdate` in the app, a stub in its tests.
protocol SGAppUpdateDeciding: AnyObject {
    /// The stored, re-verified policy's decision — synchronous, offline, for the first frame.
    func restoreDecision() -> SGAppUpdateDecision
    var currentDecision: SGAppUpdateDecision { get }
    /// The reminder for `latest` was actually on screen.
    func noteReminderShown(latest: SGAppUpdateVersion)
}

extension SGAppUpdate: SGAppUpdateDeciding {}

/// Zenlygram — presents, re-presents and takes down the block on every attached root, and offers the
/// one reminder of a launch (update_policy_spec §4e–h). Main queue.
///
/// Each attached root has an entry `{root (weak), kind, block?, token}`, in attach order — during a
/// root switch two roots of one kind are tracked, the one on screen and the one being readied, until
/// `rootDidAppear` drops the replaced one. The decision is read from the holder
/// (`SGAppUpdateDeciding`) under the QA override of a non-store build, synchronously; a block is
/// presented with `presentOverlay(inGlobal: true)` on the root itself — never through
/// `presentGlobalController`, whose `Window1.present(on: .root)` lands in the root's NON-global
/// overlays, under the consent wall and the call screens, and dies with the root — and is dismissed
/// only by this presenter, with its token. The in-call bar is lifted above the global overlays while
/// a block is up (`sgSetInCallStatusBarAboveGlobalOverlays`), so a minimised call stays one tap away.
final class SGAppUpdatePresenter {
    /// The app's instance, over `SGAppUpdate.shared`; configured by AppDelegate.
    static let shared = SGAppUpdatePresenter(
        decisions: SGAppUpdate.shared,
        environment: .unconfigured,
        debugOverride: {
            return SGSimpleSettings.shared.appUpdateDebugOverride
        }
    )

    private final class Entry {
        weak var root: NavigationController?
        let kind: SGAppUpdateRootKind
        var block: SGAppUpdateBlockController?
        var token = UUID()
        /// `presentOverlay` is running (it reports overlay changes synchronously).
        var isPresenting = false

        init(root: NavigationController, kind: SGAppUpdateRootKind) {
            self.root = root
            self.kind = kind
        }
    }

    /// The raiser of the root's in-call bar while a block is up (the consent wall is another).
    static let inCallBarRaiser = "zg.app-update.block"
    /// The reminder is offered this long after an activation, so a notification tap, a deep link or a
    /// shortcut that arrives with it has reported itself first (`noteExternalActivation`).
    static let defaultReminderIdleDelay: TimeInterval = 2.0

    private let decisions: SGAppUpdateDeciding
    private(set) var environment: SGAppUpdateEnvironment
    /// `SGSimpleSettings.shared.appUpdateDebugOverride`, read on every decision of a non-store build
    /// (`SG_APP_UPDATE_DEBUG_OVERRIDE`); a store build never reads it.
    private let debugOverride: () -> String?
    private let reminderIdleDelay: TimeInterval
    private var entries: [Entry] = []
    private var observers: [NSObjectProtocol] = []
    private var isApplicationActive: Bool
    /// An activation that came with a notification tap, a deep link, a user activity or a shortcut;
    /// cleared when the app resigns active.
    private var externalActivationPending = false
    /// At most one reminder per launch, whatever becomes of it.
    private var didOfferReminderThisLaunch = false
    private var scheduledReminderCheck: DispatchWorkItem?

    /// Tests construct their own over a stub and a recording environment, with no idle delay and an
    /// explicit activity; the app uses `shared`.
    init(decisions: SGAppUpdateDeciding, environment: SGAppUpdateEnvironment, debugOverride: @escaping () -> String?, reminderIdleDelay: TimeInterval = SGAppUpdatePresenter.defaultReminderIdleDelay, isApplicationActive: Bool? = nil) {
        self.decisions = decisions
        self.environment = environment
        self.debugOverride = debugOverride
        self.reminderIdleDelay = reminderIdleDelay
        self.isApplicationActive = isApplicationActive ?? (UIApplication.shared.applicationState == .active)
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.scheduledReminderCheck?.cancel()
    }

    // MARK: - Entry points

    func configure(environment: SGAppUpdateEnvironment) {
        assert(Thread.isMainThread)
        self.environment = environment
        // The app is INACTIVE while `didFinishLaunching` runs, and UIKit's didBecomeActive follows right after
        // it — before the account loads and a root attaches. Listening only from `attach` lost the launch's own
        // activation: `isApplicationActive` stayed false, so a cold launch offered no reminder until the app was
        // backgrounded and foregrounded once (seen on the simulator; §4g asks for the next idle activation).
        self.startObserving()
        self.evaluateAll()
        self.scheduleReminderCheck()
    }

    func attach(root: NavigationController, kind: SGAppUpdateRootKind) -> Signal<Bool, NoError> {
        assert(Thread.isMainThread)
        self.startObserving()
        self.prune()
        let entry: Entry
        if let existing = self.entries.first(where: { $0.root === root }) {
            entry = existing
        } else {
            // A new root of this kind (an account switch, a login) gets a block of its own. The root it
            // replaces keeps its block and its entry: it is still the one on screen — the authorized root
            // is attached from `AuthorizedApplicationContext.init`, and the window shows it only once
            // `isReady` fires — and `rootDidAppear` drops it when this root takes its place.
            entry = Entry(root: root, kind: kind)
            self.entries.append(entry)
        }
        self.evaluate(entry, restoring: true)
        guard let block = entry.block else {
            return .single(true)
        }
        return block.ready.get()
    }

    func rootDidAppear(_ root: NavigationController) {
        assert(Thread.isMainThread)
        self.prune()
        guard let entry = self.entries.first(where: { $0.root === root }) else {
            return
        }
        // The roots of this kind it replaced are off screen now (`WindowContent.viewController` removed
        // the authorized one's view; the previous login root was dismissed): their blocks go with them.
        for old in self.entries where old !== entry && old.kind == entry.kind {
            self.dismiss(old)
        }
        self.entries.removeAll(where: { $0 !== entry && $0.kind == entry.kind })
        if entry.kind == .authorized {
            self.scheduleReminderCheck()
        }
    }

    func rootOverlaysChanged(root: NavigationController, consentWall: ViewController?) {
        assert(Thread.isMainThread)
        guard let entry = self.entries.first(where: { $0.root === root }), !entry.isPresenting, let block = entry.block else {
            return
        }
        let overlays = root.globalOverlayControllers
        guard let blockIndex = overlays.firstIndex(where: { $0 === block }) else {
            // Taken down by anything but this presenter: the same screen again, with a new token.
            entry.block = nil
            SGLogger.shared.log("SGAppUpdate", "block removed by something else; presenting again")
            self.present(entry)
            return
        }
        if let wall = consentWall, let wallIndex = overlays.firstIndex(where: { $0 === wall }), wallIndex > blockIndex {
            // The consent wall came up (or back) above the block: the block goes above it again. A
            // call screen above both stays above both (`SGCallScreenPlacement` moves one the block
            // would cover).
            SGLogger.shared.log("SGAppUpdate", "consent wall above the block; presenting the block above it")
            self.dismiss(entry)
            self.present(entry)
        }
    }

    var isBlockPresented: Bool {
        assert(Thread.isMainThread)
        self.prune()
        return self.entries.contains(where: { $0.root != nil && $0.block != nil })
    }

    func blockController(over root: NavigationController) -> ViewController? {
        assert(Thread.isMainThread)
        return self.entries.first(where: { $0.root === root })?.block
    }

    func noteExternalActivation() {
        assert(Thread.isMainThread)
        self.externalActivationPending = true
    }

    #if SG_APP_UPDATE_DEBUG_OVERRIDE
    func debugOverrideDidChange() {
        assert(Thread.isMainThread)
        self.evaluateAll()
        self.scheduleReminderCheck()
    }
    #endif

    // MARK: - Observing

    private func startObserving() {
        guard self.observers.isEmpty else {
            return
        }
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: SGAppUpdate.decisionDidChange, object: nil, queue: .main, using: { [weak self] _ in
            self?.decisionDidChange()
        }))
        self.observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.applicationDidBecomeActive()
        }))
        self.observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.applicationWillResignActive()
        }))
    }

    /// An adopted policy (`SGAppUpdate.decisionDidChange`). The coordinator keeps refreshing while a
    /// block is up; a corrected policy lifts it here, and a policy that blocks raises it. The reminder
    /// is NOT offered from here: a policy adopted mid-session (the staggered first fetch, the 30-minute
    /// tick) would pop its alert over whatever the user is doing — a chat being typed in is not
    /// "something presented over the root" — and §4g names one trigger, the next idle activation.
    func decisionDidChange() {
        self.evaluateAll()
    }

    /// A foreground. The decision is re-read first: it depends on the policy clock (the 30-day block
    /// valve, `SGAppUpdateDecision.blockValve`), and a long-lived process that keeps being foregrounded
    /// sees no `decisionDidChange` for a valve that lifted — every fetch of a gone endpoint or a rotated
    /// ring fails or is rejected, which posts nothing. `SGAppUpdate.currentDecision` is a lock and a
    /// defaults read after the first verification.
    func applicationDidBecomeActive() {
        self.isApplicationActive = true
        self.evaluateAll()
        self.scheduleReminderCheck()
    }

    func applicationWillResignActive() {
        self.isApplicationActive = false
        self.externalActivationPending = false
        self.scheduledReminderCheck?.cancel()
        self.scheduledReminderCheck = nil
    }

    // MARK: - Deciding

    /// The decision as this build shows it: the signed policy's — `restoring`: the stored one, read
    /// synchronously for the first frame — under the QA override of a non-store build (§4h). The
    /// override exists in non-store builds only (`SG_APP_UPDATE_DEBUG_OVERRIDE`, set from the build
    /// configuration's `is_appstore_build`); a store build compiles the signed decision and nothing else.
    private func decision(restoring: Bool) -> (decision: SGAppUpdateDecision, isOverridden: Bool) {
        let base = restoring ? self.decisions.restoreDecision() : self.decisions.currentDecision
        #if SG_APP_UPDATE_DEBUG_OVERRIDE
        let override = SGAppUpdateDebugOverride.resolve(raw: self.debugOverride(), isAppStoreBuild: self.environment.isAppStoreBuild)
        return (override.apply(to: base), override != .none)
        #else
        return (base, false)
        #endif
    }

    private func prune() {
        self.entries.removeAll(where: { $0.root == nil })
    }

    private func evaluateAll() {
        self.prune()
        for entry in self.entries {
            self.evaluate(entry, restoring: false)
        }
    }

    private func evaluate(_ entry: Entry, restoring: Bool) {
        guard entry.root != nil else {
            return
        }
        switch self.decision(restoring: restoring).decision {
        case .block:
            if entry.block == nil {
                self.present(entry)
            }
        case .none, .remind:
            if entry.block != nil {
                self.dismiss(entry)
            }
        }
    }

    // MARK: - The block

    private func present(_ entry: Entry) {
        guard let root = entry.root else {
            return
        }
        let presentation = self.environment.presentation()
        let storeButton: SGAppUpdateBlockViewModel.StoreButton = self.environment.isSandboxReceipt ? .testFlight : .appStore
        let model = SGAppUpdateBlockViewModel(lang: presentation.lang, storeButton: storeButton)
        model.actions.openStore = { [weak self] in
            self?.openStore(testFlight: storeButton == .testFlight)
        }
        model.actions.openHelp = { [weak self] in
            self?.environment.openURL(SGAppUpdateBlockViewModel.helpURL)
        }
        let token = UUID()
        entry.token = token
        let block = SGAppUpdateBlockController(model: model, token: token, theme: presentation.theme)
        entry.block = block
        entry.isPresenting = true
        root.presentOverlay(controller: block, inGlobal: true, blockInteraction: false)
        entry.isPresenting = false
        root.sgSetInCallStatusBarAboveGlobalOverlays(true, for: SGAppUpdatePresenter.inCallBarRaiser)
        SGLogger.shared.log("SGAppUpdate", "block presented on the \(entry.kind) root")

        // A call under way when the block goes up (a policy adopted during the call): the screen the
        // block now covers is shown again, above it (`SGCallScreenPlacement`). Only on the window's
        // root — a root the window does not show yet (an authorized root being attached) shows no call.
        if self.environment.hasActiveCall(), self.environment.isWindowRoot(root) {
            self.environment.navigateToCurrentCall()
        }
    }

    private func dismiss(_ entry: Entry) {
        guard let block = entry.block else {
            return
        }
        entry.block = nil
        block.dismissForPresenter(token: entry.token)
        entry.root?.sgSetInCallStatusBarAboveGlobalOverlays(false, for: SGAppUpdatePresenter.inCallBarRaiser)
        SGLogger.shared.log("SGAppUpdate", "block taken down on the \(entry.kind) root")
    }

    /// The store button: the App Store page, or TestFlight's page on a sandbox-receipt build — and the
    /// App Store when nothing on the device handles `itms-beta://`.
    private func openStore(testFlight: Bool) {
        guard testFlight else {
            self.environment.openAppStorePage()
            return
        }
        self.environment.openTestFlightPage({ [weak self] opened in
            guard !opened, let self = self else {
                return
            }
            if Thread.isMainThread {
                self.environment.openAppStorePage()
            } else {
                DispatchQueue.main.async {
                    self.environment.openAppStorePage()
                }
            }
        })
    }

    // MARK: - The reminder

    /// After an activation, after the authorized root went on screen (`rootDidAppear`) or after the
    /// Debug Settings override changed: the one check of whether a reminder is due, once the
    /// activation has settled (`reminderIdleDelay`).
    private func scheduleReminderCheck() {
        guard !self.didOfferReminderThisLaunch, self.isApplicationActive else {
            return
        }
        self.scheduledReminderCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.offerReminderIfIdle()
        }
        self.scheduledReminderCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + self.reminderIdleDelay, execute: item)
    }

    /// The one reminder of this launch (§4g): a dismissable "Update available" alert on an idle
    /// activation of the authorized root — never when the activation came from a notification tap, a
    /// deep link or a shortcut, while a call screen is up, while anything is presented over the root
    /// (a modal, an overlay, the consent wall), on the login root, or while a block is up. The alert is
    /// an overlay of the authorized root ITSELF, and only once that root is the window's — not of a
    /// root still being readied behind the previous account's (an account switch), and not while a
    /// login root is up over it (adding an account), where the window would land it on the login. The
    /// marker (`noteReminderShown`) is written when the alert actually appeared, and not under an
    /// override; an alert that never appears consumes nothing but this launch's one offer.
    private func offerReminderIfIdle() {
        self.scheduledReminderCheck = nil
        guard !self.didOfferReminderThisLaunch, self.isApplicationActive, !self.externalActivationPending else {
            return
        }
        self.prune()
        guard let entry = self.entries.last(where: { $0.kind == .authorized }), let root = entry.root, self.environment.isWindowRoot(root) else {
            return
        }
        guard !self.entries.contains(where: { $0.kind == .unauthorized && SGAppUpdatePresenter.isInstalled($0.root) }) else {
            return
        }
        guard !self.isBlockPresented, !self.environment.hasActiveCall(), !SGAppUpdatePresenter.hasSomethingPresented(on: root) else {
            return
        }
        let (decision, isOverridden) = self.decision(restoring: false)
        guard case let .remind(latest) = decision else {
            return
        }
        self.didOfferReminderThisLaunch = true
        let presentation = self.environment.presentation()
        let testFlight = self.environment.isSandboxReceipt
        let alert = SGAppUpdateReminderAlertController.make(presentation: presentation, latest: latest, update: { [weak self] in
            self?.openStore(testFlight: testFlight)
        })
        alert.onShown = { [weak self] in
            guard let self = self, !isOverridden else {
                return
            }
            self.decisions.noteReminderShown(latest: latest)
        }
        SGLogger.shared.log("SGAppUpdate", "reminder for \(latest.text) offered")
        // What `Window1.present(on: .root)` does for the window's root — on this root, by name.
        root.presentOverlay(controller: alert, inGlobal: false)
    }

    /// A login root presented over the authorized one is on screen while its view is installed; the
    /// window's presentation context removes the view when the login is dismissed (`PresentationContext
    /// .dismiss`), before the root itself is released.
    private static func isInstalled(_ root: NavigationController?) -> Bool {
        guard let root, root.isViewLoaded else {
            return false
        }
        return root.view.superview != nil
    }

    /// Something is on top of the root: a UIKit modal, an overlay, a global overlay (the consent wall,
    /// a context menu, a call's bar) or a modal pushed onto the stack. The reminder never interrupts it.
    static func hasSomethingPresented(on root: NavigationController) -> Bool {
        if root.presentedViewController != nil {
            return true
        }
        if !root.overlayControllers.isEmpty || !root.globalOverlayControllers.isEmpty {
            return true
        }
        if let top = root.viewControllers.last as? ViewController {
            switch top.navigationPresentation {
            case .default, .master:
                break
            default:
                return true
            }
        }
        return false
    }
}
