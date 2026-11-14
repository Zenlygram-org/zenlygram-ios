import XCTest
import UIKit
import SwiftSignalKit
import Display
import TelegramPresentationData
import TelegramUIPreferences
import SGEntitlement
@testable import SGAppUpdateUI

/// Zenlygram — the presenter of the app-update policy (update_policy_spec §4e–h; the §7 "presenter" checks) over a
/// real `NavigationController` driven without a host, the way `NavigationControllerInCallBarTests` drives one. The
/// decision source is scripted (`Decisions`: what the signed policy would say) and the app is a recorder
/// (`Recorder`: what the presenter asked of it, and which root the window shows), so every case is about the
/// presenter alone:
///
/// - the block is a GLOBAL overlay of the login root and of the chat-list root, decided from the stored token
///   (`restoreDecision`) synchronously at attach, and the authorized root's readiness waits for it;
/// - on a root switch the new root gets its own block while the replaced root keeps its until the new one is on
///   screen (`rootDidAppear`); it comes back after a forced removal, ignores `dismiss`, goes back above a consent
///   wall that comes up later, stays under a call screen presented later, and is lifted by a corrected policy
///   (`SGAppUpdate.decisionDidChange`) or by a decision that moved while the app was inactive (the 30-day valve) on
///   the next activation — while a block is up the presenter only observes; the coordinator's refresh is never touched;
/// - the reminder: an overlay of the authorized root itself, only once that root is the window's and no login root is
///   up; suppressed on an activation that came with a notification tap / deep link / shortcut, while a block, a
///   call, an overlay or a modal is up, and on the login root; never offered by a policy adopted mid-session; offered
///   at most once per launch; the marker written only once the alert actually appeared;
/// - the TestFlight button variant with the App Store as its fallback, the Help link;
/// - the QA override of a non-store build (compiled into non-store builds only), which never writes the marker.
final class SGAppUpdatePresenterTests: XCTestCase {
    /// A Dynamic Island phone in portrait with the keyboard closed.
    private static let layout = ContainerViewLayout(
        size: CGSize(width: 402.0, height: 874.0),
        metrics: LayoutMetrics(widthClass: .compact, heightClass: .regular, orientation: .portrait),
        deviceMetrics: .iPhone16Pro,
        intrinsicInsets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: 34.0, right: 0.0),
        safeInsets: UIEdgeInsets(top: 62.0, left: 0.0, bottom: 34.0, right: 0.0),
        additionalInsets: UIEdgeInsets(),
        statusBarHeight: 54.0,
        inputHeight: nil,
        inputHeightIsInteractivellyChanging: false,
        inVoiceOver: false
    )

    /// What the signed policy would say.
    private final class Decisions: SGAppUpdateDeciding {
        var decision: SGAppUpdateDecision = .none
        var restoreCalls = 0
        var currentCalls = 0
        var remindedLatest: [SGAppUpdateVersion] = []

        func restoreDecision() -> SGAppUpdateDecision {
            self.restoreCalls += 1
            return self.decision
        }

        var currentDecision: SGAppUpdateDecision {
            self.currentCalls += 1
            return self.decision
        }

        func noteReminderShown(latest: SGAppUpdateVersion) {
            self.remindedLatest.append(latest)
        }
    }

    /// What the presenter asked of the app, and which root the main window shows (`isWindowRoot`).
    private final class Recorder {
        var isAppStoreBuild = false
        var isSandboxReceipt = false
        var storeOpens = 0
        var testFlightOpens = 0
        var testFlightAnswer = true
        var urls: [URL] = []
        var hasActiveCall = false
        var navigateCalls = 0
        weak var windowRoot: NavigationController?
        var debugOverride: String?

        func environment() -> SGAppUpdateEnvironment {
            return SGAppUpdateEnvironment(
                isAppStoreBuild: self.isAppStoreBuild,
                isSandboxReceipt: self.isSandboxReceipt,
                presentation: {
                    return SGAppUpdatePresentation(theme: defaultPresentationTheme, fontSize: .regular, lang: "en")
                },
                openAppStorePage: { [unowned self] in
                    self.storeOpens += 1
                },
                openTestFlightPage: { [unowned self] completion in
                    self.testFlightOpens += 1
                    completion(self.testFlightAnswer)
                },
                openURL: { [unowned self] url in
                    self.urls.append(url)
                },
                hasActiveCall: { [unowned self] in
                    return self.hasActiveCall
                },
                navigateToCurrentCall: { [unowned self] in
                    self.navigateCalls += 1
                },
                isWindowRoot: { [unowned self] root in
                    return self.windowRoot === root
                }
            )
        }
    }

    private let latest = SGAppUpdateVersion("12.10.0")!
    private var block: SGAppUpdateDecision {
        return .block(SGAppUpdateVersions(min: SGAppUpdateVersion("12.9.2")!, latest: self.latest)!)
    }

    /// Runs the main-queue work a step scheduled (readiness, deferred layout, the reminder check).
    private static func spin(_ seconds: TimeInterval = 0.03) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// A root with one controller and a layout, as the window gives one.
    private func makeRoot() -> NavigationController {
        let root = NavigationController(mode: .single, theme: NavigationControllerTheme(presentationTheme: defaultPresentationTheme))
        _ = root.view
        root.setViewControllers([ViewController(navigationBarPresentationData: nil)], animated: false)
        root.containerLayoutUpdated(SGAppUpdatePresenterTests.layout, transition: .immediate)
        SGAppUpdatePresenterTests.spin()
        return root
    }

    /// No idle delay: the reminder check runs on the next main-queue turn.
    private func makePresenter(_ decisions: Decisions, _ recorder: Recorder, active: Bool = true) -> SGAppUpdatePresenter {
        return SGAppUpdatePresenter(decisions: decisions, environment: recorder.environment(), debugOverride: { recorder.debugOverride }, reminderIdleDelay: 0.0, isApplicationActive: active)
    }

    /// AppDelegate put `root` on screen: the window shows it (`mainWindow.viewController = root`) and says so.
    private func show(_ root: NavigationController, _ recorder: Recorder, _ presenter: SGAppUpdatePresenter) {
        recorder.windowRoot = root
        presenter.rootDidAppear(root)
    }

    /// The reminder alerts up on `root` — the presenter presents the alert as an overlay of the root itself.
    private func alerts(on root: NavigationController) -> [SGAppUpdateReminderAlertController] {
        return root.overlayControllers.compactMap { $0 as? SGAppUpdateReminderAlertController }
    }

    /// The app's wiring of `globalOverlayControllersUpdated` (ApplicationContext / UnauthorizedApplicationContext).
    private func wire(_ root: NavigationController, to presenter: SGAppUpdatePresenter, consentWall: @escaping () -> ViewController? = { nil }) {
        root.globalOverlayControllersUpdated = { [weak presenter, weak root] in
            guard let presenter = presenter, let root = root else {
                return
            }
            presenter.rootOverlaysChanged(root: root, consentWall: consentWall())
        }
    }

    private func readyValue(_ signal: Signal<Bool, NoError>) -> Bool? {
        var value: Bool?
        let disposable = signal.start(next: { next in
            value = next
        })
        SGAppUpdatePresenterTests.spin()
        disposable.dispose()
        return value
    }

    // MARK: - The block: a global overlay of either root, from the first frame

    func test_aBlockedInstallGetsTheBlockOverTheLoginRoot_fromTheStoredDecision() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder)
        let root = self.makeRoot()

        let ready = presenter.attach(root: root, kind: .unauthorized)

        XCTAssertEqual(decisions.restoreCalls, 1, "the first frame is decided from the stored token, synchronously, at attach")
        let block = try XCTUnwrap(presenter.blockController(over: root) as? SGAppUpdateBlockController)
        XCTAssertTrue(root.globalOverlayControllers.contains(where: { $0 === block }), "a GLOBAL overlay of the root, not a window-level present")
        XCTAssertTrue(root.overlayControllers.isEmpty)
        XCTAssertTrue(presenter.isBlockPresented)
        XCTAssertTrue(block.isOpaqueWhenInOverlay)
        XCTAssertTrue(block.blocksBackgroundWhenInOverlay)
        XCTAssertEqual(block.model.storeButton, .appStore)
        XCTAssertEqual(self.readyValue(ready), true)
    }

    func test_theAuthorizedRootIsReadyOnlyWithTheBlockUp_andAtOnceWithoutOne() throws {
        let blocked = Decisions()
        blocked.decision = self.block
        let recorder = Recorder()
        let presenter = self.makePresenter(blocked, recorder)
        let root = self.makeRoot()
        let ready = presenter.attach(root: root, kind: .authorized)
        let block = try XCTUnwrap(presenter.blockController(over: root))
        XCTAssertTrue(root.globalOverlayControllers.contains(where: { $0 === block }), "presented before the root is shown: the first frame already holds it")
        XCTAssertEqual(self.readyValue(ready), true, "the block's own readiness gates the root's")

        let open = Decisions()
        let openPresenter = self.makePresenter(open, Recorder())
        let openRoot = self.makeRoot()
        XCTAssertEqual(self.readyValue(openPresenter.attach(root: openRoot, kind: .authorized)), true, "nothing to wait for")
        XCTAssertNil(openPresenter.blockController(over: openRoot))
        XCTAssertFalse(openPresenter.isBlockPresented)
        XCTAssertTrue(openRoot.globalOverlayControllers.isEmpty)
        XCTAssertEqual(open.restoreCalls, 1)
    }

    /// An account switch: `AuthorizedApplicationContext.init` attaches the new root while the previous account's root
    /// is still the one on screen (AppDelegate installs the new root only once `isReady` fires). The old root keeps
    /// its block until then — a blocked install never shows the previous account's chat list in between — and drops
    /// it the moment the new root is on screen (`rootDidAppear`).
    func test_aNewRootOfTheSameKindGetsItsOwnBlock_theOldRootKeepsItsUntilTheNewOneIsOnScreen() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder)
        let first = self.makeRoot()
        _ = presenter.attach(root: first, kind: .authorized)
        self.show(first, recorder, presenter)
        let firstBlock = try XCTUnwrap(presenter.blockController(over: first))

        // The new authorized root is created and attached; the window still shows `first`.
        let second = self.makeRoot()
        _ = presenter.attach(root: second, kind: .authorized)
        SGAppUpdatePresenterTests.spin()

        let secondBlock = try XCTUnwrap(presenter.blockController(over: second))
        XCTAssertFalse(secondBlock === firstBlock)
        XCTAssertTrue(second.globalOverlayControllers.contains(where: { $0 === secondBlock }), "the new root is blocked from its first frame")
        XCTAssertTrue(presenter.blockController(over: first) === firstBlock, "the root still on screen keeps its block")
        XCTAssertTrue(first.globalOverlayControllers.contains(where: { $0 === firstBlock }))
        XCTAssertTrue(presenter.isBlockPresented)

        // A policy that lifts the block during the switch lifts it on both.
        decisions.decision = .none
        NotificationCenter.default.post(name: SGAppUpdate.decisionDidChange, object: nil)
        SGAppUpdatePresenterTests.spin()
        XCTAssertNil(presenter.blockController(over: first))
        XCTAssertNil(presenter.blockController(over: second))
        decisions.decision = self.block
        NotificationCenter.default.post(name: SGAppUpdate.decisionDidChange, object: nil)
        SGAppUpdatePresenterTests.spin()
        let firstAgain = try XCTUnwrap(presenter.blockController(over: first))
        XCTAssertNotNil(presenter.blockController(over: second))

        // `isReady` fired: the window shows `second` now, and `first` is off screen.
        self.show(second, recorder, presenter)
        SGAppUpdatePresenterTests.spin()
        XCTAssertNil(presenter.blockController(over: first), "the replaced root's block went with it")
        XCTAssertFalse(first.globalOverlayControllers.contains(where: { $0 === firstAgain }))
        XCTAssertNotNil(presenter.blockController(over: second))
        XCTAssertTrue(presenter.isBlockPresented)
    }

    func test_aBlockRemovedByAnythingButItsPresenterComesBack() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let presenter = self.makePresenter(decisions, Recorder())
        let root = self.makeRoot()
        self.wire(root, to: presenter)
        _ = presenter.attach(root: root, kind: .authorized)
        let first = try XCTUnwrap(presenter.blockController(over: root))

        // Something else takes the overlay container down: the proxy every presented overlay gets.
        first.presentingViewController?.dismiss(animated: false, completion: nil)
        SGAppUpdatePresenterTests.spin()

        let second = try XCTUnwrap(presenter.blockController(over: root))
        XCTAssertFalse(second === first, "the same screen again, a new controller and token")
        XCTAssertTrue(root.globalOverlayControllers.contains(where: { $0 === second }))
        XCTAssertFalse(root.globalOverlayControllers.contains(where: { $0 === first }))
        XCTAssertTrue(presenter.isBlockPresented)
    }

    func test_dismissIsIgnoredUnlessThePresenterTakesItDown() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let presenter = self.makePresenter(decisions, Recorder())
        let root = self.makeRoot()
        self.wire(root, to: presenter)
        _ = presenter.attach(root: root, kind: .authorized)
        let block = try XCTUnwrap(presenter.blockController(over: root))

        // The generic "dismiss every global overlay" paths.
        block.dismiss()
        block.dismiss(animated: false, completion: nil)
        block.dismiss(completion: nil)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(root.globalOverlayControllers.contains(where: { $0 === block }), "ignored")
        XCTAssertTrue(presenter.blockController(over: root) === block)

        // Its presenter: a corrected policy.
        decisions.decision = .none
        NotificationCenter.default.post(name: SGAppUpdate.decisionDidChange, object: nil)
        SGAppUpdatePresenterTests.spin()
        XCTAssertFalse(root.globalOverlayControllers.contains(where: { $0 === block }))
        XCTAssertNil(presenter.blockController(over: root))
    }

    // MARK: - Z-order: above the consent wall, below a call screen

    func test_theBlockGoesBackAboveAConsentWallThatComesUpLater() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let presenter = self.makePresenter(decisions, Recorder())
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        let block = try XCTUnwrap(presenter.blockController(over: root))

        // The wall's presenter puts the wall up after the block (its first unlock, a re-consent).
        let wall = ViewController(navigationBarPresentationData: nil)
        wall.isOpaqueWhenInOverlay = true
        wall.blocksBackgroundWhenInOverlay = true
        root.presentOverlay(controller: wall, inGlobal: true)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(root.globalOverlayControllers.last === wall, "harness: the wall is above the block now")

        presenter.rootOverlaysChanged(root: root, consentWall: wall)
        SGAppUpdatePresenterTests.spin()

        let reblock = try XCTUnwrap(presenter.blockController(over: root))
        let overlays = root.globalOverlayControllers
        XCTAssertEqual(overlays.count, 2)
        XCTAssertTrue(overlays.first === wall)
        XCTAssertTrue(overlays.last === reblock, "the block is above the wall again")
        XCTAssertFalse(overlays.contains(where: { $0 === block }))

        // Already in order: nothing moves.
        presenter.rootOverlaysChanged(root: root, consentWall: wall)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(presenter.blockController(over: root) === reblock)
        XCTAssertTrue(root.globalOverlayControllers.last === reblock)
    }

    func test_aCallScreenPresentedLaterStaysAboveTheBlock() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let presenter = self.makePresenter(decisions, Recorder())
        let root = self.makeRoot()
        self.wire(root, to: presenter)
        _ = presenter.attach(root: root, kind: .authorized)
        let block = try XCTUnwrap(presenter.blockController(over: root))

        // `SharedAccountContextImpl` presents a call screen as a later global overlay (`SGCallScreenPlacement`).
        let call = ViewController(navigationBarPresentationData: nil)
        root.presentOverlay(controller: call, inGlobal: true)
        SGAppUpdatePresenterTests.spin()

        let overlays = root.globalOverlayControllers
        XCTAssertEqual(overlays.count, 2)
        XCTAssertTrue(overlays.first === block)
        XCTAssertTrue(overlays.last === call, "the call screen is above the block")
        XCTAssertTrue(presenter.blockController(over: root) === block, "the block was not re-presented over it")
    }

    func test_aBlockThatGoesUpDuringACallOnTheWindowRootBringsTheCallScreenBack() {
        let decisions = Decisions()
        decisions.decision = self.block
        let recorder = Recorder()
        recorder.hasActiveCall = true
        let presenter = self.makePresenter(decisions, recorder)
        let root = self.makeRoot()
        recorder.windowRoot = root
        _ = presenter.attach(root: root, kind: .authorized)
        XCTAssertEqual(recorder.navigateCalls, 1, "the call screen the block now covers is shown again, above it")

        // A root the window does not show yet raises nothing.
        let other = Recorder()
        other.hasActiveCall = true
        let otherPresenter = self.makePresenter(decisions, other)
        _ = otherPresenter.attach(root: self.makeRoot(), kind: .authorized)
        XCTAssertEqual(other.navigateCalls, 0)
    }

    // MARK: - A corrected policy lifts it; the in-call bar; the valve

    func test_aCorrectedPolicyLiftsTheBlock() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let presenter = self.makePresenter(decisions, Recorder())
        let root = self.makeRoot()
        self.wire(root, to: presenter)
        _ = presenter.attach(root: root, kind: .authorized)
        let block = try XCTUnwrap(presenter.blockController(over: root))
        XCTAssertTrue(root.sgInCallStatusBarAboveGlobalOverlays, "a minimised call stays one tap away while the block is up")

        // The coordinator kept refreshing while the block was up and adopted a policy that lifts it.
        decisions.decision = .none
        NotificationCenter.default.post(name: SGAppUpdate.decisionDidChange, object: nil)
        SGAppUpdatePresenterTests.spin()

        XCTAssertGreaterThanOrEqual(decisions.currentCalls, 1, "re-read on the change")
        XCTAssertFalse(presenter.isBlockPresented)
        XCTAssertNil(presenter.blockController(over: root))
        XCTAssertFalse(root.globalOverlayControllers.contains(where: { $0 === block }))
        XCTAssertFalse(root.sgInCallStatusBarAboveGlobalOverlays)

        // And a policy that blocks again puts it back.
        decisions.decision = self.block
        NotificationCenter.default.post(name: SGAppUpdate.decisionDidChange, object: nil)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(presenter.isBlockPresented)
        XCTAssertNotNil(presenter.blockController(over: root))
    }

    /// The decision depends on the policy clock (the 30-day block valve): a process that stayed suspended past the
    /// valve gets no `decisionDidChange` — every fetch of a gone endpoint fails or is rejected, which posts nothing —
    /// so the next activation re-reads the decision itself and takes the block down (or puts one up).
    func test_aDecisionThatMovedWhileTheAppWasInactiveIsAppliedOnTheNextActivation() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let presenter = self.makePresenter(decisions, Recorder())
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        let block = try XCTUnwrap(presenter.blockController(over: root))

        decisions.decision = .none
        presenter.applicationWillResignActive()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertNil(presenter.blockController(over: root), "the valve lifted the block: gone on the next foreground, with no notification")
        XCTAssertFalse(root.globalOverlayControllers.contains(where: { $0 === block }))
        XCTAssertFalse(presenter.isBlockPresented)

        decisions.decision = self.block
        presenter.applicationWillResignActive()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertNotNil(presenter.blockController(over: root), "and a decision that blocks again is applied the same way")
    }

    // MARK: - The reminder

    func test_noReminderOnAnActivationFromANotificationTap_thenOnTheNextIdleOne() throws {
        let decisions = Decisions()
        decisions.decision = .remind(latest: self.latest)
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder, active: false)
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        self.show(root, recorder, presenter)

        // A notification tap (or a deep link, a shortcut) came with this activation.
        presenter.noteExternalActivation()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: root).isEmpty, "not an idle activation")
        XCTAssertTrue(decisions.remindedLatest.isEmpty)

        // The next activation is idle.
        presenter.applicationWillResignActive()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertEqual(self.alerts(on: root).count, 1)
    }

    func test_theReminderIsOfferedOnceAndTheMarkerIsWrittenOnlyAfterItAppeared() throws {
        let decisions = Decisions()
        decisions.decision = .remind(latest: self.latest)
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder)
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        self.show(root, recorder, presenter)
        SGAppUpdatePresenterTests.spin()

        let alert = try XCTUnwrap(self.alerts(on: root).first, "offered on the idle activation, as an overlay of the root itself")
        XCTAssertEqual(self.alerts(on: root).count, 1)
        XCTAssertTrue(root.globalOverlayControllers.isEmpty, "a plain overlay, as Window1.present(on: .root) makes one — not a global one")
        XCTAssertEqual(decisions.remindedLatest, [self.latest], "written once the alert appeared (viewDidAppear), once")

        // Taken down; later activations of this launch offer nothing more.
        alert.presentingViewController?.dismiss(animated: false, completion: nil)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(root.overlayControllers.isEmpty, "harness: the alert is gone")
        presenter.applicationWillResignActive()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        NotificationCenter.default.post(name: SGAppUpdate.decisionDidChange, object: nil)
        SGAppUpdatePresenterTests.spin()
        presenter.rootDidAppear(root)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: root).isEmpty, "at most once per launch")
        XCTAssertEqual(decisions.remindedLatest, [self.latest])
    }

    /// The authorized root is attached from `AuthorizedApplicationContext.init`, before the window shows it: nothing is
    /// offered on it — and nothing is consumed — until AppDelegate reports it on screen (`rootDidAppear`). On an
    /// account switch the alert would otherwise land on the previous account's root (`Window1.present(on: .root)`
    /// presents on the CURRENT root) and vanish with it, its marker written: the reminder for that `latest` lost.
    func test_noReminderUntilTheAuthorizedRootIsTheWindowsRoot_thenOneOnThatRoot() throws {
        let decisions = Decisions()
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder)
        let first = self.makeRoot()
        _ = presenter.attach(root: first, kind: .authorized)
        self.show(first, recorder, presenter)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: first).isEmpty, "premise: nothing to remind of yet")

        // The policy arrived; an account switch readies a new root behind `first`.
        decisions.decision = .remind(latest: self.latest)
        let second = self.makeRoot()
        _ = presenter.attach(root: second, kind: .authorized)
        presenter.applicationWillResignActive()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: first).isEmpty, "not on the root about to be replaced")
        XCTAssertTrue(self.alerts(on: second).isEmpty, "not on a root the window does not show yet")
        XCTAssertTrue(decisions.remindedLatest.isEmpty, "nothing consumed")

        self.show(second, recorder, presenter)
        SGAppUpdatePresenterTests.spin()
        XCTAssertEqual(self.alerts(on: second).count, 1, "offered once the new root is on screen, on that root")
        XCTAssertTrue(self.alerts(on: first).isEmpty)
        XCTAssertEqual(decisions.remindedLatest, [self.latest])
    }

    /// A policy adopted mid-session (the staggered first fetch, the 30-minute tick) re-evaluates the block and nothing
    /// else: its reminder waits for the next idle activation (§4g) instead of popping over a chat being typed in — a
    /// pushed chat with the keyboard up is not "something presented over the root".
    func test_aPolicyAdoptedMidSessionNeverInterrupts_theNextActivationReminds() throws {
        let decisions = Decisions()
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder)
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        self.show(root, recorder, presenter)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: root).isEmpty)

        decisions.decision = .remind(latest: self.latest)
        NotificationCenter.default.post(name: SGAppUpdate.decisionDidChange, object: nil)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: root).isEmpty, "an adopted policy offers no alert by itself")
        XCTAssertTrue(decisions.remindedLatest.isEmpty)

        presenter.applicationWillResignActive()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertEqual(self.alerts(on: root).count, 1, "the next idle activation")
    }

    /// Adding an account: a login root is presented over the authorized root. `Window1.present(on: .root)` would land
    /// the alert on the login (the topmost presented NavigationController), where §4g never shows it — so nothing is
    /// offered while a login root is up, and the next activation after it is gone offers the reminder.
    func test_noReminderWhileALoginRootIsUpOverTheAuthorizedRoot() throws {
        let decisions = Decisions()
        decisions.decision = .remind(latest: self.latest)
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder, active: false)
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        self.show(root, recorder, presenter)

        // The window's presentation context installs the login root's view over the authorized root.
        let window = UIView(frame: CGRect(origin: CGPoint(), size: SGAppUpdatePresenterTests.layout.size))
        let login = self.makeRoot()
        window.addSubview(login.view)
        _ = presenter.attach(root: login, kind: .unauthorized)
        presenter.rootDidAppear(login)
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: root).isEmpty, "not while the login is up")
        XCTAssertTrue(self.alerts(on: login).isEmpty, "and never on the login root")
        XCTAssertTrue(decisions.remindedLatest.isEmpty)

        // The login is dismissed (its view removed, the root not yet released); the next activation is idle.
        login.view.removeFromSuperview()
        presenter.applicationWillResignActive()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertEqual(self.alerts(on: root).count, 1)
        withExtendedLifetime(login) {}
    }

    func test_noReminderWhileABlockIsUp_onTheLoginRoot_orDuringACall() {
        // A block: the decision is the block's, and nothing is offered over it.
        let blocked = Decisions()
        blocked.decision = self.block
        let blockedRecorder = Recorder()
        let blockedPresenter = self.makePresenter(blocked, blockedRecorder)
        let blockedRoot = self.makeRoot()
        _ = blockedPresenter.attach(root: blockedRoot, kind: .authorized)
        self.show(blockedRoot, blockedRecorder, blockedPresenter)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: blockedRoot).isEmpty)

        // The login root: no reminder there, even as the window's root.
        let login = Decisions()
        login.decision = .remind(latest: self.latest)
        let loginRecorder = Recorder()
        let loginPresenter = self.makePresenter(login, loginRecorder)
        let loginRoot = self.makeRoot()
        _ = loginPresenter.attach(root: loginRoot, kind: .unauthorized)
        self.show(loginRoot, loginRecorder, loginPresenter)
        loginPresenter.applicationWillResignActive()
        loginPresenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: loginRoot).isEmpty)
        XCTAssertTrue(login.remindedLatest.isEmpty)

        // A call: never interrupted; offered once the call is over.
        let call = Decisions()
        call.decision = .remind(latest: self.latest)
        let callRecorder = Recorder()
        callRecorder.hasActiveCall = true
        let callPresenter = self.makePresenter(call, callRecorder)
        let callRoot = self.makeRoot()
        _ = callPresenter.attach(root: callRoot, kind: .authorized)
        self.show(callRoot, callRecorder, callPresenter)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: callRoot).isEmpty)
        callRecorder.hasActiveCall = false
        callPresenter.applicationWillResignActive()
        callPresenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertEqual(self.alerts(on: callRoot).count, 1)
    }

    func test_noReminderWhileAnOverlayOrAModalIsPresented() {
        let decisions = Decisions()
        decisions.decision = .remind(latest: self.latest)
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder, active: false)
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        self.show(root, recorder, presenter)

        // A toast, a tooltip, the consent wall: an overlay of the root.
        let toast = ViewController(navigationBarPresentationData: nil)
        root.presentOverlay(controller: toast, inGlobal: false)
        SGAppUpdatePresenterTests.spin()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: root).isEmpty, "never interrupts what is on screen")

        toast.presentingViewController?.dismiss(animated: false, completion: nil)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(root.overlayControllers.isEmpty, "harness: the toast is gone")

        // A flat modal pushed onto the stack.
        let modal = ViewController(navigationBarPresentationData: nil)
        modal.navigationPresentation = .modal
        root.pushViewController(modal, animated: false, completion: {})
        SGAppUpdatePresenterTests.spin()
        presenter.applicationWillResignActive()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: root).isEmpty)

        root.filterController(modal, animated: false)
        SGAppUpdatePresenterTests.spin()
        presenter.applicationWillResignActive()
        presenter.applicationDidBecomeActive()
        SGAppUpdatePresenterTests.spin()
        XCTAssertEqual(self.alerts(on: root).count, 1, "idle at last")
    }

    /// A cold launch as the app lives it: `configure` in `didFinishLaunching` while the app is still inactive,
    /// UIKit's didBecomeActive (the real notification) BEFORE the account loads and the authorized root attaches,
    /// then `isReady` and the root going on screen. The launch's own activation is the idle one of §4g — it is not
    /// lost because the presenter was not listening yet (regression: no reminder on a cold launch until the app was
    /// backgrounded and foregrounded), and the alert waits for the root to be the window's.
    func test_theReminderIsOfferedOnAColdLaunch_whoseActivationPrecedesTheAttach() {
        let decisions = Decisions()
        decisions.decision = .remind(latest: self.latest)
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder, active: false)
        presenter.configure(environment: recorder.environment())

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(decisions.remindedLatest.isEmpty, "no authorized root yet: nothing to offer on, nothing consumed")

        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: root).isEmpty, "attached, not shown yet")
        self.show(root, recorder, presenter)
        SGAppUpdatePresenterTests.spin()
        XCTAssertEqual(self.alerts(on: root).count, 1, "the activation that preceded the attach counts, once the root is on screen")
    }

    // MARK: - The buttons

    func test_aSandboxReceiptBuildOffersTestFlight_withTheAppStoreAsItsFallback() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let recorder = Recorder()
        recorder.isSandboxReceipt = true
        let presenter = self.makePresenter(decisions, recorder)
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        let block = try XCTUnwrap(presenter.blockController(over: root) as? SGAppUpdateBlockController)

        XCTAssertEqual(block.model.storeButton, .testFlight)
        XCTAssertEqual(block.model.storeButtonTitleKey, "AppUpdate.Required.TestFlightButton")

        block.model.actions.openStore()
        XCTAssertEqual(recorder.testFlightOpens, 1)
        XCTAssertEqual(recorder.storeOpens, 0, "TestFlight opened it")

        recorder.testFlightAnswer = false
        block.model.actions.openStore()
        XCTAssertEqual(recorder.testFlightOpens, 2)
        XCTAssertEqual(recorder.storeOpens, 1, "no TestFlight on the device: the App Store")

        // A store build: the App Store, nothing else.
        let storeRecorder = Recorder()
        let storePresenter = self.makePresenter(decisions, storeRecorder)
        let storeRoot = self.makeRoot()
        _ = storePresenter.attach(root: storeRoot, kind: .authorized)
        let storeBlock = try XCTUnwrap(storePresenter.blockController(over: storeRoot) as? SGAppUpdateBlockController)
        XCTAssertEqual(storeBlock.model.storeButton, .appStore)
        XCTAssertEqual(storeBlock.model.storeButtonTitleKey, "AppUpdate.Required.Button")
        storeBlock.model.actions.openStore()
        XCTAssertEqual(storeRecorder.storeOpens, 1)
        XCTAssertEqual(storeRecorder.testFlightOpens, 0)
    }

    func test_theHelpLinkOpensZenlygramOrg() throws {
        let decisions = Decisions()
        decisions.decision = self.block
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder)
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .unauthorized)
        let block = try XCTUnwrap(presenter.blockController(over: root) as? SGAppUpdateBlockController)

        block.model.actions.openHelp()
        XCTAssertEqual(recorder.urls, [URL(string: "https://zenlygram.org")!])
    }

    // MARK: - The QA override (non-store builds only; a store build compiles none of it)

    #if SG_APP_UPDATE_DEBUG_OVERRIDE
    func test_theOverrideBlocksANonStoreBuildOnly() throws {
        let decisions = Decisions()
        let recorder = Recorder()
        recorder.debugOverride = "block"
        let presenter = self.makePresenter(decisions, recorder)
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        XCTAssertNotNil(presenter.blockController(over: root), "the override replaces the decision of a non-store build")
        XCTAssertEqual(decisions.restoreCalls, 1, "the signed policy is still read; the override only replaces its decision")

        // Back to the policy, from the Debug Settings row.
        recorder.debugOverride = "none"
        presenter.debugOverrideDidChange()
        SGAppUpdatePresenterTests.spin()
        XCTAssertNil(presenter.blockController(over: root))

        // A store build never reads it (the belt under the compile-time exclusion).
        let store = Recorder()
        store.isAppStoreBuild = true
        store.debugOverride = "block"
        let storePresenter = self.makePresenter(decisions, store)
        let storeRoot = self.makeRoot()
        _ = storePresenter.attach(root: storeRoot, kind: .authorized)
        XCTAssertNil(storePresenter.blockController(over: storeRoot))
        XCTAssertFalse(storePresenter.isBlockPresented)
    }

    func test_theRemindOverrideOffersTheAlertAtOnceButNeverWritesTheMarker() throws {
        let decisions = Decisions()
        let recorder = Recorder()
        let presenter = self.makePresenter(decisions, recorder)
        let root = self.makeRoot()
        _ = presenter.attach(root: root, kind: .authorized)
        self.show(root, recorder, presenter)
        SGAppUpdatePresenterTests.spin()
        XCTAssertTrue(self.alerts(on: root).isEmpty, "premise: the signed policy says nothing")

        // QA picks `remind` in Debug Settings: the alert on this activation, unlike a signed policy adopted mid-session.
        recorder.debugOverride = "remind"
        presenter.debugOverrideDidChange()
        SGAppUpdatePresenterTests.spin()
        XCTAssertEqual(self.alerts(on: root).count, 1)
        XCTAssertTrue(decisions.remindedLatest.isEmpty, "the marker belongs to a signed latest, never to the override's 99.0")
    }
    #endif
}
