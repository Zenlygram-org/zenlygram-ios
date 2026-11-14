import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramPresentationData
import SGCustomerSyncCore

/// Zenlygram — the UIKit container every Chat Lock prompt is presented in (`.overFullScreen`, so the
/// Display hierarchy underneath stays alive). Public so app-level teardown can recognise and spare it.
public final class ChatLockPromptNavigationController: UINavigationController {
    var onDidDisappear: (() -> Void)?

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.onDidDisappear?()
    }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return self.topViewController?.supportedInterfaceOrientations ?? .all
    }

    public override var childForStatusBarStyle: UIViewController? {
        return self.topViewController
    }
}

/// Zenlygram — serial presenter of Chat Lock PIN prompts.
///
/// - Presents only when the app is active, the app passcode (AppLock) has been unlocked for 0.35 s and the
///   presenting controller is not mid-transition; otherwise it retries (on didBecomeActive, on AppLock
///   changes, every 0.1 s).
/// - Presents from the topmost non-dismissing UIKit presentation of the native window root, never through
///   Display's `ViewController.present` (which reroutes to the root and silently fails).
/// - One prompt at a time: a request for the prompt's own chat joins it, a request for another chat while
///   a prompt is on screen is `.interrupted` at once; a newer request replaces one that is still waiting.
/// - Except (SG: Chat Lock): an automatic `.resume` prompt is the weakest intent. An `.openChat` request for
///   another chat (notification, link, Spotlight…) takes it down and is queued behind it, and a `.resume`
///   request never replaces a waiting `.openChat`, so an explicit navigation is never dropped for it. A PIN
///   screen left up when the app went to the background counts as such a prompt too, and a waiting `.resume`
///   prompt is dropped once its chat is no longer the top of its navigation stack.
/// - The chat's title (`ChatLockSession.promptChatTitleProvider`) names the chat on its PIN screen.
/// - SG: Secret Vault — a prompt's subject is a chat or an account's vault. Vault prompts are generic (no chat
///   title), never `.resume`, are taken down (not demoted) when the app enters the background, and two vault
///   requests for the same account join. A request that arrives while the active prompt is already decided (on
///   its way out) is queued behind it instead of `.interrupted`: the vault → chat PIN chain relies on it. A vault
///   prompt ends `.unlocked` only while that vault is open, and an open vault skips the `.reveal` prompt only
///   while its vault list is attached.
final class ChatLockPromptPresenter {
    enum Subject {
        case chat(ChatLockKey)
        case vault(accountPeerId: PeerId, purpose: ChatLockVaultPromptPurpose)

        /// Two requests for the same chat, or for the same account's vault, share one prompt.
        func joins(_ other: Subject) -> Bool {
            switch self {
            case let .chat(key):
                if case let .chat(otherKey) = other {
                    return key == otherKey
                }
                return false
            case let .vault(accountPeerId, _):
                if case let .vault(otherAccountPeerId, _) = other {
                    return accountPeerId == otherAccountPeerId
                }
                return false
            }
        }

        var chatKey: ChatLockKey? {
            if case let .chat(key) = self {
                return key
            }
            return nil
        }

        var isVault: Bool {
            if case .vault = self {
                return true
            }
            return false
        }
    }

    private final class Prompt {
        let subject: Subject
        var reason: ChatLockPromptReason
        weak var host: UIViewController?
        var completions: [(ChatLockUnlockResult) -> Void]
        let createdAt: Double
        /// Set once the prompt's outcome has been delivered to the completions.
        var result: ChatLockUnlockResult?
        /// Set the moment the outcome is known, before the dismissal that delivers it completes.
        var decided: ChatLockUnlockResult?
        weak var navigationController: ChatLockPromptNavigationController?
        /// SG: Chat Lock — superseded by an explicit open of another chat; being dismissed as `.interrupted`.
        var isTakenDown = false
        /// SG: Chat Lock — the chat's display title for the PIN screen (resolved asynchronously; may stay nil).
        var chatTitle: String?
        weak var chatController: ChatPincodeViewController?
        var chatTitleDisposable: Disposable?
        /// SG: Chat Lock — the pending re-check of a take-down (one at a time).
        var takeDownRetryTimer: ChatLockMainTimer?

        init(subject: Subject, reason: ChatLockPromptReason, host: UIViewController?, completion: @escaping (ChatLockUnlockResult) -> Void) {
            self.subject = subject
            self.reason = reason
            self.host = host
            self.completions = [completion]
            self.createdAt = ProcessInfo.processInfo.systemUptime
        }
    }

    private static let appLockSettleDelay: Double = 0.35
    private static let retryInterval: Double = 0.1
    /// A prompt that could not be presented for this long (no window, stuck presentation) is dropped.
    private static let giveUpInterval: Double = 30.0
    /// SG: Chat Lock — how long an automatic resume prompt is held back after it is requested, so an explicit
    /// open arriving with the same activation (notification tap, link) replaces it before anything is shown.
    private static let resumeGrace: Double = 0.4

    private var waiting: Prompt?
    private var active: Prompt?

    private var appLockIsLocked = false
    private var appLockUnlockedAt: Double = 0.0
    private var appLockDisposable: Disposable?
    private var retryTimer: ChatLockMainTimer?
    private var backgroundObserver: NSObjectProtocol?

    func start(appLockIsLocked: Signal<Bool, NoError>) {
        if self.backgroundObserver == nil {
            // SG: Chat Lock — posted on the main thread (queue: nil runs the block synchronously there).
            self.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.applicationDidEnterBackground()
            })
        }
        self.appLockDisposable?.dispose()
        self.appLockDisposable = (appLockIsLocked
        |> deliverOnMainQueue).start(next: { [weak self] isLocked in
            guard let self else {
                return
            }
            if self.appLockIsLocked && !isLocked {
                // The passcode screen is animating away: give it a moment before a PIN screen goes up.
                self.appLockUnlockedAt = ProcessInfo.processInfo.systemUptime
            }
            self.appLockIsLocked = isLocked
            if !isLocked {
                self.scheduleRetry(after: ChatLockPromptPresenter.appLockSettleDelay + 0.01)
            }
        })
    }

    /// SG: Chat Lock — a PIN screen left up when the app went to the background (the relock teardown spares
    /// it) is no longer what the user is doing: whatever brings the app back (a notification, a link,
    /// Spotlight) is the newer intent. Demoted to `.resume`, it is taken down by an explicit open of another
    /// locked chat instead of that open being dropped as `.interrupted`; a request for its own chat upgrades
    /// it again (see `request`).
    private func applicationDidEnterBackground() {
        // SG: Secret Vault — nothing may stay "about to open the vault" across a trip to the background: a
        // waiting vault prompt is dropped and an active one taken down (`.interrupted`), never demoted.
        if let waiting = self.waiting, waiting.subject.isVault {
            self.waiting = nil
            self.finish(waiting, .interrupted)
        }
        guard let active = self.active, active.result == nil, active.decided == nil, !active.isTakenDown else {
            return
        }
        if active.subject.isVault {
            self.takeDown(active)
            return
        }
        active.reason = .resume
    }

    // MARK: - Requests

    func request(key: ChatLockKey, reason: ChatLockPromptReason, host: UIViewController?, completion: @escaping (ChatLockUnlockResult) -> Void) {
        self.request(subject: .chat(key), reason: reason, host: host, completion: completion)
    }

    /// SG: Secret Vault — the account's vault PIN (always an explicit `.openChat`-strength request).
    func requestVault(accountPeerId: PeerId, purpose: ChatLockVaultPromptPurpose, host: UIViewController?, completion: @escaping (ChatLockUnlockResult) -> Void) {
        self.request(subject: .vault(accountPeerId: accountPeerId, purpose: purpose), reason: .openChat, host: host, completion: completion)
    }

    private func request(subject: Subject, reason: ChatLockPromptReason, host: UIViewController?, completion: @escaping (ChatLockUnlockResult) -> Void) {
        if let active = self.active {
            if active.subject.joins(subject) && active.result == nil && !active.isTakenDown {
                active.completions.append(completion)
                if case .openChat = reason {
                    // SG: Chat Lock — now explicitly asked for: no longer an automatic prompt that may be superseded.
                    active.reason = .openChat
                }
                return
            }
            let isOnItsWayOut = active.result != nil || active.decided != nil
            if !isOnItsWayOut {
                guard case .openChat = reason, case .resume = active.reason else {
                    // A PIN screen is on screen: never stack another one.
                    completion(.interrupted)
                    return
                }
                // SG: Chat Lock — an explicit open of another locked chat outranks the automatic resume prompt nobody
                // asked for. Interrupting it here dropped the navigation (a notification / link / Spotlight tap for
                // chat B while chat A was relocked on screen) and left A's unnamed PIN screen up instead. Take the
                // resume prompt down (A stays covered in place; `.interrupted`) and queue this request: it is
                // presented as soon as the resume prompt has disappeared.
                self.takeDown(active)
            }
            // SG: Secret Vault — a decided prompt still animating out (e.g. the vault PIN that just succeeded, whose
            // completion now asks for the chat's own PIN) is not in the way: queue behind it.
        }
        if let waiting = self.waiting {
            if waiting.subject.joins(subject) {
                waiting.completions.append(completion)
                if case .openChat = reason {
                    waiting.reason = .openChat
                }
                if let host {
                    waiting.host = host
                }
                return
            }
            if case .resume = reason, case .openChat = waiting.reason {
                // SG: Chat Lock — never let an automatic resume prompt replace a pending explicit open (which
                // would be dropped). The relocked chat stays covered, its cover keeps the Unlock button.
                completion(.interrupted)
                return
            }
            // The latest intent wins over a prompt that has not been shown yet.
            self.waiting = nil
            self.finish(waiting, .interrupted)
        }
        let prompt = Prompt(subject: subject, reason: reason, host: host, completion: completion)
        self.waiting = prompt
        self.resolveChatTitle(prompt)
        self.tryPresent()
    }

    /// Chat Lock was removed for these peers (master recovery / reset): whoever waits for them may proceed.
    func peersUnlocked(_ peerIds: Set<PeerId>) {
        if let waiting = self.waiting, let key = waiting.subject.chatKey, peerIds.contains(key.peerId) {
            self.waiting = nil
            self.finish(waiting, .unlocked)
        }
        if let active = self.active, let key = active.subject.chatKey, peerIds.contains(key.peerId), active.result == nil {
            // The screen dismisses itself; its onSuccess / disappearance delivers the outcome.
            active.decided = .unlocked
            if active.navigationController?.presentingViewController == nil {
                self.promptDidDisappear(active)
            }
        }
    }

    func setNeedsPresentation() {
        self.tryPresent()
    }

    // MARK: - Presentation

    private func scheduleRetry(after delay: Double = ChatLockPromptPresenter.retryInterval) {
        self.retryTimer?.invalidate()
        self.retryTimer = ChatLockMainTimer(timeout: delay, action: { [weak self] in
            guard let self else {
                return
            }
            self.retryTimer = nil
            self.tryPresent()
        })
    }

    private func tryPresent() {
        guard self.active == nil, let prompt = self.waiting else {
            return
        }
        if ChatLockSession.isAppExtension {
            self.waiting = nil
            self.finish(prompt, .interrupted)
            return
        }
        if case let .vault(accountPeerId, purpose) = prompt.subject, ChatLockPromptPresenter.vaultOpenAnswers(purpose: purpose, accountPeerId: accountPeerId) {
            // SG: Secret Vault — opened meanwhile (e.g. by the secret code): nothing to ask.
            self.waiting = nil
            self.finish(prompt, .unlocked)
            return
        }
        if case .resume = prompt.reason {
            // Resume prompts only make sense over the relocked chat that is still on screen (and may wait
            // for as long as the app passcode takes). SG: Chat Lock — and still the top of its stack: a chat
            // pushed over it meanwhile (e.g. from a notification for an unlocked chat) must not get the
            // relocked chat's PIN screen, whose cancel would close the new chat along with the relocked one.
            guard let host = prompt.host, host.isViewLoaded, host.view.window != nil, ChatLockPromptPresenter.isTopOfNavigationStack(host) else {
                self.waiting = nil
                self.finish(prompt, .interrupted)
                return
            }
            // SG: Chat Lock — hold it back briefly, so an explicit open that arrives with the same activation
            // replaces it while it is still waiting instead of flashing one chat's PIN screen before another's.
            // The chat stays covered meanwhile.
            let age = ProcessInfo.processInfo.systemUptime - prompt.createdAt
            if age < ChatLockPromptPresenter.resumeGrace {
                self.scheduleRetry(after: ChatLockPromptPresenter.resumeGrace - age + 0.01)
                return
            }
        } else if ProcessInfo.processInfo.systemUptime - prompt.createdAt > ChatLockPromptPresenter.giveUpInterval {
            // Never surface a PIN screen for a request the user made long ago.
            self.waiting = nil
            self.finish(prompt, .interrupted)
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            // Retried from ChatLockSession on didBecomeActive.
            return
        }
        if self.appLockIsLocked {
            // Retried when AppLock reports unlocked.
            return
        }
        let sinceAppLockUnlock = ProcessInfo.processInfo.systemUptime - self.appLockUnlockedAt
        if sinceAppLockUnlock < ChatLockPromptPresenter.appLockSettleDelay {
            self.scheduleRetry(after: ChatLockPromptPresenter.appLockSettleDelay - sinceAppLockUnlock + 0.01)
            return
        }
        guard let presentingController = self.readyPresentingController(for: prompt) else {
            self.scheduleRetry()
            return
        }
        self.waiting = nil
        self.active = prompt
        self.present(prompt, from: presentingController)
    }

    /// SG: Chat Lock — `host` is the last controller of its navigation stack, ignoring iPad master-column
    /// controllers (which the relock eviction also keeps above a chat), or it is in no stack.
    private static func isTopOfNavigationStack(_ host: UIViewController) -> Bool {
        guard let host = host as? ViewController, let navigationController = host.navigationController as? NavigationController, navigationController.viewControllers.contains(where: { $0 === host }) else {
            return true
        }
        let top = navigationController.viewControllers.last(where: { controller in
            if let controller = controller as? ViewController, case .master = controller.navigationPresentation {
                return false
            }
            return true
        })
        return top === host
    }

    private func readyPresentingController(for prompt: Prompt) -> UIViewController? {
        var root: UIViewController?
        if let host = prompt.host, host.isViewLoaded, let window = host.view.window {
            root = window.rootViewController
        }
        if root == nil {
            root = ChatLockSession.shared.configuration?.rootViewController()
        }
        guard var top = root else {
            return nil
        }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        if top.transitionCoordinator != nil || top.isBeingPresented || top.isBeingDismissed {
            return nil
        }
        if let presented = top.presentedViewController, presented.isBeingDismissed {
            // Wait for the dismissal to finish, or the new prompt would be torn down with it.
            return nil
        }
        if top is ViewController {
            // Display's present(_:animated:) reroutes to the window root, which is already presenting.
            return nil
        }
        return top
    }

    private func present(_ prompt: Prompt, from presentingController: UIViewController) {
        let presentationData = ChatLockSession.shared.currentPresentationData()
        let controller: ChatPincodeViewController
        switch prompt.subject {
        case let .chat(key):
            controller = self.makeChatController(prompt: prompt, key: key, presentationData: presentationData)
        case let .vault(accountPeerId, purpose):
            controller = self.makeVaultController(prompt: prompt, accountPeerId: accountPeerId, purpose: purpose, presentationData: presentationData)
        }
        let navigationController = ChatLockPromptNavigationController(rootViewController: controller)
        navigationController.setNavigationBarHidden(true, animated: false)
        navigationController.modalPresentationStyle = .overFullScreen
        navigationController.modalPresentationCapturesStatusBarAppearance = true
        navigationController.view.accessibilityViewIsModal = true
        navigationController.onDidDisappear = { [weak self, weak prompt, weak navigationController] in
            DispatchQueue.main.async {
                guard let self, let prompt else {
                    return
                }
                if let navigationController, navigationController.presentingViewController != nil, !navigationController.isBeingDismissed {
                    // Still presented (only covered by something else).
                    return
                }
                self.promptDidDisappear(prompt)
            }
        }
        prompt.navigationController = navigationController
        presentingController.present(navigationController, animated: true, completion: nil)

        // UIKit refuses a presentation silently when the presenter is busy; never stay "active" forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: { [weak self, weak prompt, weak navigationController] in
            guard let self, let prompt, self.active === prompt else {
                return
            }
            if navigationController?.presentingViewController == nil {
                self.promptDidDisappear(prompt)
            }
        })
    }

    private func promptDidDisappear(_ prompt: Prompt) {
        if prompt.result == nil {
            var result = prompt.decided ?? .interrupted
            if result == .unlocked, case let .vault(accountPeerId, _) = prompt.subject {
                // SG: Secret Vault — decided, but the vault may have closed before the disappearance delivered it.
                result = ChatLockPromptPresenter.vaultResult(accountPeerId: accountPeerId)
            }
            self.finish(prompt, result)
        }
        if self.active === prompt {
            self.active = nil
        }
        self.tryPresent()
    }

    /// SG: Chat Lock — dismisses the active, still undecided prompt because a request that outranks it is
    /// queued. Its outcome is `.interrupted` (delivered by the disappearance, like any external dismissal), so
    /// its chat simply stays covered; the queued request is presented from `promptDidDisappear`.
    private func takeDown(_ prompt: Prompt) {
        guard self.active === prompt, prompt.result == nil, prompt.decided == nil else {
            // Already decided: it is on its way out anyway.
            return
        }
        prompt.isTakenDown = true
        guard let navigationController = prompt.navigationController, let presentingController = navigationController.presentingViewController else {
            // Never made it on screen (UIKit refused the presentation) or already gone. Next runloop: the
            // caller (`request`) queues the superseding prompt first, so that one is what gets presented.
            DispatchQueue.main.async { [weak self, weak prompt] in
                guard let self, let prompt else {
                    return
                }
                self.promptDidDisappear(prompt)
            }
            return
        }
        if navigationController.isBeingDismissed {
            // Its disappearance delivers the outcome.
            return
        }
        if let transitionCoordinator = navigationController.transitionCoordinator {
            // UIKit ignores a dismissal requested while the prompt is still animating in (or pushing the
            // master screen): retry once that transition is over.
            transitionCoordinator.animate(alongsideTransition: nil, completion: { [weak self, weak prompt] _ in
                DispatchQueue.main.async {
                    guard let self, let prompt else {
                        return
                    }
                    self.takeDown(prompt)
                }
            })
            // SG: Chat Lock — and on a timer, like a refused dismissal: never rely on that completion alone.
            self.scheduleTakeDownRetry(prompt)
            return
        }
        // Dismisses everything the prompt presented too (e.g. the "Reset Chat Lock?" alert).
        presentingController.dismiss(animated: true, completion: nil)
        // Never keep the queued request waiting on a dismissal UIKit refused.
        self.scheduleTakeDownRetry(prompt)
    }

    /// SG: Chat Lock — re-runs `takeDown` in 1 s (a no-op once the prompt is gone or decided); one pending
    /// retry per prompt, so the transition and dismissal paths never stack up timers.
    private func scheduleTakeDownRetry(_ prompt: Prompt) {
        prompt.takeDownRetryTimer?.invalidate()
        prompt.takeDownRetryTimer = ChatLockMainTimer(timeout: 1.0, action: { [weak self, weak prompt] in
            guard let self, let prompt else {
                return
            }
            prompt.takeDownRetryTimer = nil
            self.takeDown(prompt)
        })
    }

    /// Zenlygram — audit #70 / #71: a recovery screen finished its own flow, so the prompt's container has to
    /// come down before the outcome is delivered (nothing dismissed it: no credential was ever entered).
    /// `finish` is idempotent, so the disappearance that follows changes nothing.
    private func dismissAndFinish(_ prompt: Prompt, _ result: ChatLockUnlockResult) {
        if let navigationController = prompt.navigationController, let presentingController = navigationController.presentingViewController, !navigationController.isBeingDismissed {
            presentingController.dismiss(animated: true, completion: nil)
        }
        self.finish(prompt, result)
    }

    private func finish(_ prompt: Prompt, _ result: ChatLockUnlockResult) {
        guard prompt.result == nil else {
            return
        }
        prompt.result = result
        prompt.chatTitleDisposable?.dispose()
        prompt.chatTitleDisposable = nil
        let completions = prompt.completions
        prompt.completions = []
        for completion in completions {
            completion(result)
        }
    }

    // MARK: - Chat title (SG: Chat Lock)

    /// Resolves the chat's display title for its PIN screen while the prompt waits (or once it is shown).
    private func resolveChatTitle(_ prompt: Prompt) {
        // SG: Secret Vault — only a chat's own PIN screen is named; the vault prompt stays generic.
        guard let provider = ChatLockSession.promptChatTitleProvider, let key = prompt.subject.chatKey else {
            return
        }
        prompt.chatTitleDisposable = (provider(key)
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak prompt] title in
            guard let prompt, prompt.result == nil else {
                return
            }
            prompt.chatTitle = title
            prompt.chatController?.chatTitle = title
        })
    }

    // MARK: - PIN screens

    /// The chat's own PIN screen. "Forgot pincode?" pushes the master screen on the same UIKit stack.
    private func makeChatController(prompt: Prompt, key: ChatLockKey, presentationData: PresentationData) -> ChatPincodeViewController {
        let peerId = key.peerId
        let manager = ChatPincodeManager.shared
        // Zenlygram — audit #71: the Chat Lock credentials did not come along with a device migration. The
        // chats stay covered (the non-secret mirror still names them), but no entry could open this one, so
        // the screen offers the way out instead of a pincode pad nobody can answer.
        let recoveryStatus = manager.protectionRecoveryStatus()
        if recoveryStatus.chatLockNeedsRecovery, manager.getPincode(for: peerId) == nil {
            return self.makeChatLockRecoveryController(prompt: prompt, key: key, status: recoveryStatus, presentationData: presentationData)
        }
        let metadata = manager.getMetadata(for: peerId)

        var recovery: ChatPincodeRecovery = .legacy
        if manager.isMasterEnabled() {
            recovery = .masterPin(makeMasterController: { [weak self, weak prompt] in
                return ChatLockPromptPresenter.makeMasterController(presenter: self, prompt: prompt, key: key, presentationData: presentationData)
            })
        }

        let controller = ChatPincodeViewController(mode: .verify(passwordType: metadata.passwordType, biometricEnabled: metadata.biometricEnabled, onVerify: { code in
            return manager.verify(code, for: peerId)
        }, onSuccess: { [weak self, weak prompt] in
            guard let self, let prompt else {
                return
            }
            self.finish(prompt, .unlocked)
        }, onForgot: nil), presentationData: presentationData, recovery: recovery, throttleScope: .chat(peerId))
        // SG: Chat Lock — name the chat (set again by resolveChatTitle if the title arrives later).
        controller.chatTitle = prompt.chatTitle
        prompt.chatController = controller
        controller.onWillSucceed = { [weak prompt, weak controller] in
            prompt?.decided = .unlocked
            // Issue the grant before the completions run (and before the covered screen underneath is
            // revealed by the dismissal).
            ChatLockSession.shared.grant(key)
            // Zenlygram — `chat_lock.unlocked{method}` for the chat's account (design 40 §10.2).
            if let method = controller?.lastSuccessMethod?.unlockMethod {
                SGAnalytics.record(.chatLockUnlocked(method: method), accountPeerId: key.accountPeerId.toInt64())
            }
        }
        controller.onCancel = { [weak self, weak prompt] in
            guard let self, let prompt else {
                return
            }
            self.finish(prompt, .cancelled)
        }
        return controller
    }

    /// SG: Secret Vault — whether an open vault answers a vault request without a prompt: always for `.openChat`;
    /// for the title-gesture `.reveal` only while the vault list is attached (the caller pops to it). An open vault
    /// without its list (an iPad vault chat in the detail column, a grant that nothing holds) still asks, so the
    /// list is never shown without the PIN.
    private static func vaultOpenAnswers(purpose: ChatLockVaultPromptPurpose, accountPeerId: PeerId) -> Bool {
        let session = ChatLockSession.shared
        guard session.isVaultOpen(accountPeerId: accountPeerId) else {
            return false
        }
        // Zenlygram — audit #70: while the vault credential has to be set up again on this iPhone, a
        // lingering grant must not stand in for it — the recovery screen is shown instead.
        guard !ChatPincodeManager.shared.protectionRecoveryStatus().vaultNeedsRecovery else {
            return false
        }
        switch purpose {
        case .openChat:
            return true
        case .reveal:
            return session.hasAttachedVaultList(accountPeerId)
        }
    }

    /// SG: Secret Vault — a successful vault prompt ends `.unlocked` only while that vault is still open. Home
    /// pressed between onWillSucceed and onSuccess closes it (background relock): then `.interrupted`, so neither
    /// the reveal, nor `sgSecretVaultInterceptOpen`'s retry, nor `requireUnlock`'s chat PIN goes on with a closed
    /// vault.
    private static func vaultResult(accountPeerId: PeerId) -> ChatLockUnlockResult {
        return ChatLockSession.shared.isVaultOpen(accountPeerId: accountPeerId) ? .unlocked : .interrupted
    }

    /// SG: Secret Vault — the vault PIN screen: generic copy (no chat title), the vault credential, and the one
    /// `.vault` throttle budget every vault check shares (the PIN screens and the secret-code search gate).
    /// Success opens the account's vault before the covered content underneath is revealed. "Forgot pincode?"
    /// (the recovery ladder: Face ID / Touch ID, then the Chat Lock master pincode — never the iPhone passcode)
    /// only for the title-gesture reveal. Both end `.unlocked` only while the vault is still open (`vaultResult`).
    private func makeVaultController(prompt: Prompt, accountPeerId: PeerId, purpose: ChatLockVaultPromptPurpose, presentationData: PresentationData) -> ChatPincodeViewController {
        let manager = ChatPincodeManager.shared
        // Zenlygram — audit #70: the vault credential did not come along with a device migration (or can no
        // longer be checked), so nothing typed here could ever match. Offer the way out instead.
        let recoveryStatus = manager.protectionRecoveryStatus()
        if recoveryStatus.vaultNeedsRecovery {
            return self.makeVaultRecoveryController(prompt: prompt, status: recoveryStatus, presentationData: presentationData)
        }
        let metadata = manager.getVaultMetadata()
        var onForgot: (() -> Void)?
        if case .reveal = purpose {
            onForgot = { [weak self, weak prompt] in
                // Runs after ChatPincodeViewController's device-owner authentication succeeded and it dismissed.
                ChatLockSession.shared.grantVault(accountPeerId: accountPeerId)
                guard let self, let prompt else {
                    return
                }
                prompt.decided = .unlocked
                self.finish(prompt, ChatLockPromptPresenter.vaultResult(accountPeerId: accountPeerId))
            }
        }
        let controller = ChatPincodeViewController(mode: .verify(passwordType: metadata.passwordType, biometricEnabled: metadata.biometricEnabled, onVerify: { code in
            // Zenlygram — audit #27: the SCREEN counts its own failures (`processCredential` is the
            // throttler), so it uses the check that does no throttle bookkeeping of its own.
            return manager.verifyVaultCredential(code)
        }, onSuccess: { [weak self, weak prompt] in
            guard let self, let prompt else {
                return
            }
            self.finish(prompt, ChatLockPromptPresenter.vaultResult(accountPeerId: accountPeerId))
        }, onForgot: onForgot), presentationData: presentationData, recovery: .legacy, throttleScope: .vault)
        controller.onWillSucceed = { [weak prompt, weak controller] in
            prompt?.decided = .unlocked
            ChatLockSession.shared.grantVault(accountPeerId: accountPeerId)
            // Zenlygram — `vault.unlocked{method}`, the rung that succeeded (design 40 §10.2).
            if let method = controller?.lastSuccessMethod?.unlockMethod {
                SGAnalytics.record(.vaultUnlocked(method: method), accountPeerId: accountPeerId.toInt64())
            }
        }
        // The reveal's "Forgot pincode?" ladder opens the vault too: Face ID / Touch ID or the master.
        controller.onRecoveryWillSucceed = { method in
            if let method = method.unlockMethod {
                SGAnalytics.record(.vaultUnlocked(method: method), accountPeerId: accountPeerId.toInt64())
            }
        }
        controller.onCancel = { [weak self, weak prompt] in
            guard let self, let prompt else {
                return
            }
            self.finish(prompt, .cancelled)
        }
        return controller
    }

    // MARK: - Recovery screens (Zenlygram — audit #70 / #71)

    /// Zenlygram — audit batch 4: a recovery action that cannot run because this iPhone has neither a
    /// passcode nor biometrics used to close the sheet with nothing happening. Say what to do instead; the
    /// recovery screen stays up behind the alert, so the user is not stranded.
    private func presentDeviceAuthUnavailable(_ prompt: Prompt) {
        let alert = UIAlertController(title: SGProtectionStrings.deviceAuthUnavailableTitle, message: SGProtectionStrings.deviceAuthUnavailableText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SGProtectionStrings.ok, style: .default, handler: nil))
        // Presented from the prompt's own UIKit container: Display's `present` reroutes to the window root,
        // which is already showing that container, where the alert would silently never appear.
        prompt.navigationController?.present(alert, animated: true)
    }

    /// The vault credential must be set up again on this iPhone. The only action is "set a new vault PIN"
    /// (device-owner authentication, then the normal set-a-PIN screen); turning the vault off lives in
    /// Settings, so the copy says so. The new PIN does not open the vault by itself — the prompt ends
    /// `.cancelled` and the user asks again when they mean to.
    private func makeVaultRecoveryController(prompt: Prompt, status: SGProtectionRecoveryStatus, presentationData: PresentationData) -> ChatPincodeViewController {
        let title = status.vaultUnverifiable ? SGProtectionStrings.vaultUnverifiableTitle : SGProtectionStrings.vaultLostTitle
        var text = status.vaultUnverifiable
            ? SGProtectionStrings.vaultUnverifiableText
            : SGProtectionStrings.vaultLostText(count: status.vaultMembershipLost ? status.lastKnownVaultMemberCount : 0)
        text += "\n\n" + FenixuzChatLockStrings.vaultRecoveryTurnOffHint
        let onPrimary: () -> Void = { [weak prompt] in
            guard let prompt else {
                return
            }
            ChatLockSession.shared.runSetNewPinRecovery(.vault, presentationData: presentationData, present: { [weak prompt] viewController in
                // Presented from the prompt's own container, like every other screen this prompt shows.
                prompt?.navigationController?.present(viewController, animated: true, completion: nil)
            }, completion: { [weak self = self, weak prompt] result in
                guard let self, let prompt else {
                    return
                }
                switch result {
                case .success:
                    self.dismissAndFinish(prompt, .cancelled)
                case .cancelled:
                    break
                case .unavailable:
                    self.presentDeviceAuthUnavailable(prompt)
                }
            })
        }
        let controller = ChatPincodeViewController(
            mode: .verify(passwordType: .pin, biometricEnabled: false, onVerify: { _ in
                // Nothing is ever entered on a `.credentialLost` screen (it has no keypad and no field).
                return false
            }, onSuccess: {}, onForgot: nil),
            presentationData: presentationData,
            recovery: .credentialLost(
                title: title,
                text: text,
                primaryTitle: SGProtectionStrings.setNewVaultPin,
                onPrimary: onPrimary,
                secondaryTitle: nil,
                onSecondary: nil
            ),
            throttleScope: .vault
        )
        controller.onCancel = { [weak self, weak prompt] in
            guard let self, let prompt else {
                return
            }
            self.finish(prompt, .cancelled)
        }
        return controller
    }

    /// The Chat Lock credentials must be set up again on this iPhone. One new pincode replaces the master and
    /// every chat that is still covered (they cannot be told apart any more — the copy says so), or the user
    /// turns Chat Lock off. Cancelling leaves the chat covered.
    private func makeChatLockRecoveryController(prompt: Prompt, key: ChatLockKey, status: SGProtectionRecoveryStatus, presentationData: PresentationData) -> ChatPincodeViewController {
        let onPrimary: () -> Void = { [weak prompt] in
            guard let prompt else {
                return
            }
            ChatLockSession.shared.runSetNewPinRecovery(.chatLock, presentationData: presentationData, present: { [weak prompt] viewController in
                prompt?.navigationController?.present(viewController, animated: true, completion: nil)
            }, completion: { [weak self = self, weak prompt] result in
                guard let self, let prompt else {
                    return
                }
                switch result {
                case .success:
                    // The user proved device ownership and chose the new pincode just now: open this chat
                    // without asking for it again, exactly like the master-pincode recovery path does.
                    prompt.decided = .unlocked
                    ChatLockSession.shared.grant(key)
                    self.dismissAndFinish(prompt, .unlocked)
                case .cancelled:
                    break
                case .unavailable:
                    self.presentDeviceAuthUnavailable(prompt)
                }
            })
        }
        let onSecondary: () -> Void = { [weak prompt] in
            guard let prompt else {
                return
            }
            ChatLockSession.shared.runTurnOffChatLockRecovery(completion: { [weak self = self, weak prompt] result in
                guard let self, let prompt else {
                    return
                }
                switch result {
                case .success:
                    prompt.decided = .unlocked
                    self.dismissAndFinish(prompt, .unlocked)
                case .cancelled:
                    break
                case .unavailable:
                    self.presentDeviceAuthUnavailable(prompt)
                }
            })
        }
        let controller = ChatPincodeViewController(
            mode: .verify(passwordType: .pin, biometricEnabled: false, onVerify: { _ in
                return false
            }, onSuccess: {}, onForgot: nil),
            presentationData: presentationData,
            recovery: .credentialLost(
                title: SGProtectionStrings.chatLockLostTitle,
                text: SGProtectionStrings.chatLockLostText(count: status.pendingLockedChatCount),
                primaryTitle: SGProtectionStrings.setNewChatLockPin,
                onPrimary: onPrimary,
                secondaryTitle: SGProtectionStrings.turnOffChatLock,
                onSecondary: onSecondary
            ),
            throttleScope: .chat(key.peerId)
        )
        controller.onCancel = { [weak self, weak prompt] in
            guard let self, let prompt else {
                return
            }
            self.finish(prompt, .cancelled)
        }
        return controller
    }

    /// Master-pincode recovery for one chat: success removes that chat's lock (so it opens without a second
    /// prompt); the Reset flow turns Chat Lock off altogether.
    private static func makeMasterController(presenter: ChatLockPromptPresenter?, prompt: Prompt?, key: ChatLockKey, presentationData: PresentationData) -> ChatPincodeViewController {
        let peerId = key.peerId
        let manager = ChatPincodeManager.shared
        let metadata = manager.getMasterMetadata()

        let controller = ChatPincodeViewController(mode: .verify(passwordType: metadata.passwordType, biometricEnabled: metadata.biometricEnabled, onVerify: { code in
            return manager.verifyMaster(code)
        }, onSuccess: { [weak presenter, weak prompt] in
            guard let presenter, let prompt else {
                return
            }
            presenter.finish(prompt, .unlocked)
        }, onForgot: nil), presentationData: presentationData, isMasterRecovery: true, recovery: .resetChatLock(onReset: { [weak presenter, weak prompt] in
            guard let presenter, let prompt else {
                return
            }
            presenter.finish(prompt, .unlocked)
        }), throttleScope: .master)
        controller.onWillSucceed = { [weak prompt] in
            prompt?.decided = .unlocked
            // Removing the lock right away (not after the dismissal) keeps the re-entered navigation from
            // prompting again, whichever of onSuccess / the disappearance delivers the outcome first.
            if manager.isLocked(peerId) {
                manager.removePincode(for: peerId)
                // Zenlygram — the user removed this chat's lock through the master pincode (design 40 §10.2).
                SGAnalytics.record(.chatLockLockRemoved, accountPeerId: key.accountPeerId.toInt64())
            }
            ChatLockThrottle.reset(.chat(peerId))
            ChatLockThrottle.reset(.master)
        }
        return controller
    }
}

// SG: Chat Lock — names the chat on its PIN screen.
public extension ChatLockSession {
    /// Resolves a locked chat's display title (title only, never content) for its PIN screen, so prompts the
    /// user did not start by tapping that chat's row (resume after relock, notifications, links, comments keyed
    /// on the discussion group) say whose PIN they want. Installed once by the app glue (main thread); without
    /// it the prompt keeps the generic "Chat is locked" copy. The first value is used; nil keeps the copy.
    static var promptChatTitleProvider: ((ChatLockKey) -> Signal<String?, NoError>)?
}
