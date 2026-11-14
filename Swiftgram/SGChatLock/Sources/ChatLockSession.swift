import Foundation
import UIKit
import Display
import LocalAuthentication
import Postbox
import SwiftSignalKit
import TelegramPresentationData
import SGProtectedStore

// Zenlygram — Chat Lock central gate: the per-app-session unlock state.
//
// A locked chat's content is visible only while an unlock GRANT exists for (account, peer). Grants are
// issued by a successful PIN / biometric / master-recovery prompt and kept alive by HOLDERS (the chat
// screens showing that content). Everything that renders a locked chat asks this session instead of
// ChatPincodeManager directly, so there is exactly one answer to "may this be shown right now?".
//
// - L1 (this file): grants, holders, relock on background / device lock, privacy shield, eviction.
// - L2 entry gates (TelegramUI / ChatListUI glue): navigateToChatControllerImpl + chat list preflight.
// - L3 backstop (ChatLockControllerGate): an opaque cover on every chat screen until a grant exists.
// - L4 surfaces: cross-chat lists ask `shouldHideContentGlobally`, per-peer ones observe `contentVisibility`.
//
// SG: Secret Vault (audit batch 3) — a second layer (ChatLockSession+Vault.swift): a vaulted chat's content is
// visible only while its account's vault is open (a vault grant, held by the vault list, a vault content screen
// or a vault chat on screen). `isContentVisible` = lock layer ∧ vault layer, so every gate above is vault-aware too.

public struct ChatLockKey: Hashable {
    public let accountPeerId: PeerId
    public let peerId: PeerId

    public init(accountPeerId: PeerId, peerId: PeerId) {
        self.accountPeerId = accountPeerId
        self.peerId = peerId
    }
}

public enum ChatLockPromptReason {
    /// The user is opening the chat (tap, navigation, Unlock button).
    case openChat
    /// The app came back to the foreground over a relocked chat.
    case resume
}

public enum ChatLockUnlockResult {
    /// A grant exists (or the chat is no longer locked): the content may be shown.
    case unlocked
    /// The user closed the PIN screen.
    case cancelled
    /// The prompt could not be shown or was taken down by the system (another prompt on screen, the app
    /// passcode locking, the host leaving its window). Nothing was decided.
    case interrupted
}

public enum ChatLockRelockReason {
    case background
    case deviceLocked
}

/// Cancellable one-shot main-queue timer (avoids the Foundation / SwiftSignalKit `Timer` name clash).
final class ChatLockMainTimer {
    private var workItem: DispatchWorkItem?

    init(timeout: Double, action: @escaping () -> Void) {
        let workItem = DispatchWorkItem(block: action)
        self.workItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func invalidate() {
        self.workItem?.cancel()
        self.workItem = nil
    }
}

private final class ChatLockWeakGate {
    weak var value: ChatLockControllerGate?

    init(_ value: ChatLockControllerGate) {
        self.value = value
    }
}

public final class ChatLockSession {
    public static let shared = ChatLockSession()

    public struct Configuration {
        /// AppLockContextImpl.isCurrentlyLocked (also true while the app is in the background).
        public var appLockIsLocked: Signal<Bool, NoError>
        public var presentationData: () -> PresentationData
        /// The native UIKit root of the main window (prompts are presented from its topmost presentation).
        public var rootViewController: () -> UIViewController?
        /// App-level teardown after a relock: galleries, context menus, UIKit modals, protected playback.
        public var relockTeardown: (_ revokedKeys: Set<ChatLockKey>) -> Void

        public init(appLockIsLocked: Signal<Bool, NoError>, presentationData: @escaping () -> PresentationData, rootViewController: @escaping () -> UIViewController?, relockTeardown: @escaping (Set<ChatLockKey>) -> Void) {
            self.appLockIsLocked = appLockIsLocked
            self.presentationData = presentationData
            self.rootViewController = rootViewController
            self.relockTeardown = relockTeardown
        }
    }

    enum Grant {
        case pending(deadline: Double)
        case held
    }

    final class Holder {
        let isAttached: () -> Bool
        let registeredAt: Double

        init(isAttached: @escaping () -> Bool, registeredAt: Double) {
            self.isAttached = isAttached
            self.registeredAt = registeredAt
        }
    }

    /// A pending grant (prompt succeeded, no screen holds it yet) lives this long.
    static let pendingGrantTimeout: Double = 60.0
    /// A held grant survives this long without an attached holder (push/pop animations, quick re-open).
    static let leaveGrace: Double = 2.0

    static let isAppExtension: Bool = Bundle.main.bundlePath.hasSuffix(".appex")

    private(set) var configuration: Configuration?

    // Main thread only.
    private var grants: [ChatLockKey: Grant] = [:]
    private var pendingTimers: [ChatLockKey: ChatLockMainTimer] = [:]
    private var leaveTimers: [ChatLockKey: ChatLockMainTimer] = [:]
    var holders: [ChatLockKey: Bag<Holder>] = [:]
    var visibilityObservers: [ChatLockKey: Bag<(Bool) -> Void>] = [:]

    // SG: Secret Vault — main thread only (logic in ChatLockSession+Vault.swift). Keyed by account peer id.
    var vaultGrants: [PeerId: Grant] = [:]
    var vaultPendingTimers: [PeerId: ChatLockMainTimer] = [:]
    var vaultLeaveTimers: [PeerId: ChatLockMainTimer] = [:]
    var vaultScreens: [ChatLockVaultScreenEntry] = []
    var vaultOpenObservers: [PeerId: Bag<(Bool) -> Void>] = [:]
    var activityMonitor: ChatLockActivityMonitor?
    /// #119: the hover and scroll-only pan observers installed next to `activityMonitor`, and their target.
    var activityPointerRecognizers: [UIGestureRecognizer] = []
    var activityPointerObserver: ChatLockPointerActivityObserver?
    var activityObservers: [NSObjectProtocol] = []
    var inactivityTimer: ChatLockMainTimer?
    var lastUserActivity: Double = 0.0
    private var gateRefs: [ChatLockWeakGate] = []
    private let relockHandlers = Bag<(Set<ChatLockKey>) -> Void>()
    private var lifecycleObservers: [NSObjectProtocol] = []

    // Any thread.
    private let predicatesLock = NSLock()
    private var predicates: [Int: (PeerId, PeerId) -> Bool] = [:]
    private var nextPredicateId = 0

    let presenter = ChatLockPromptPresenter()
    let privacyShield = ChatLockPrivacyShield()

    /// True while a LocalAuthentication sheet (Face ID / Touch ID / device passcode) is up. The sheet makes
    /// the app resign active, which must not raise the privacy shield.
    public internal(set) var isAuthenticating: Bool = false

    // SG: Secret Vault (audit batch 4, #27) — when the vault credential was last PROVEN in this session,
    // measured on the throttle's monotonic clock (never `ChatLockSession.now()`, whose `systemUptime` stops
    // while the device sleeps and would stretch the window over a night). It only spares the user a second PIN
    // screen within a minute (e.g. turning the secret-code mode off right after entering the PIN); it never
    // grants a vault and never opens anything by itself.
    static let vaultCredentialProofTimeout: Double = 60.0
    private let vaultProofLock = NSLock()
    private var vaultCredentialProofAt: Double?

    /// True while at least one locked chat is unlocked, or a Secret Vault is open, in this session.
    public var hasLiveGrants: Bool {
        return !self.grants.isEmpty || !self.vaultGrants.isEmpty
    }

    private init() {
        let center = NotificationCenter.default
        // queue: nil — delivered synchronously on the posting (main) thread. didEnterBackground in
        // particular must relock BEFORE the app-switcher snapshot is taken.
        self.lifecycleObservers.append(center.addObserver(forName: ChatPincodeManager.lockedPeersDidChangeNotification, object: nil, queue: nil, using: { [weak self] notification in
            self?.onMain { $0.lockedPeersDidChange(notification) }
        }))
        self.lifecycleObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil, using: { [weak self] _ in
            self?.onMain { $0.applicationWillResignActive() }
        }))
        self.lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: { [weak self] _ in
            self?.onMain { $0.applicationDidEnterBackground() }
        }))
        self.lifecycleObservers.append(center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil, using: { [weak self] _ in
            self?.onMain { $0.protectedDataWillBecomeUnavailable() }
        }))
        self.lifecycleObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil, using: { [weak self] _ in
            self?.onMain { $0.applicationDidBecomeActive() }
        }))
        // SG: Secret Vault — membership / flag changes (posted on the main thread by SGSecretVault).
        self.lifecycleObservers.append(center.addObserver(forName: chatLockSecretVaultChangedNotification, object: nil, queue: nil, using: { [weak self] notification in
            self?.onMain { $0.secretVaultDidChange(notification) }
        }))
    }

    func onMain(_ f: @escaping (ChatLockSession) -> Void) {
        if Thread.isMainThread {
            f(self)
        } else {
            DispatchQueue.main.async {
                f(self)
            }
        }
    }

    // MARK: - Configuration

    /// Main thread; the first call wins. Called once by the main app's SharedAccountContextImpl.
    public func configure(_ configuration: Configuration) {
        guard self.configuration == nil, !ChatLockSession.isAppExtension else {
            return
        }
        self.configuration = configuration
        SGProtectedStore.shared.setProtectedDataAvailable(UIApplication.shared.isProtectedDataAvailable) // SG: Secret Vault
        ChatPincodeManager.shared.prepareLockedPeersCache(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
        self.presenter.start(appLockIsLocked: configuration.appLockIsLocked)
    }

    func currentPresentationData() -> PresentationData {
        return self.configuration?.presentationData() ?? defaultPresentationData()
    }

    // MARK: - Protection (any thread)

    /// Whether `peerId` is Chat-Locked for `accountPeerId`. Saved Messages (`peerId == accountPeerId`) never is.
    public func isProtected(peerId: PeerId, accountPeerId: PeerId) -> Bool {
        return peerId != accountPeerId && ChatPincodeManager.shared.isLocked(peerId)
    }

    /// Whether cross-chat surfaces (search, Storage, attachments, hashtags, PiP) must hide this peer's
    /// content regardless of the session state: `isProtected`, or hidden in the Secret Vault (static: even
    /// while the vault is open, cross-chat surfaces never mix vault content in), or a registered predicate.
    public func shouldHideContentGlobally(peerId: PeerId, accountPeerId: PeerId) -> Bool {
        if self.isProtected(peerId: peerId, accountPeerId: accountPeerId) {
            return true
        }
        if self.isVaultHidden(peerId: peerId, accountPeerId: accountPeerId) {
            return true
        }
        self.predicatesLock.lock()
        let predicates = Array(self.predicates.values)
        self.predicatesLock.unlock()
        for predicate in predicates {
            if predicate(peerId, accountPeerId) {
                return true
            }
        }
        return false
    }

    /// Adds a predicate to `shouldHideContentGlobally` (Batch 3: the Secret Vault). Any thread.
    public func registerGlobalContentPredicate(_ predicate: @escaping (_ peerId: PeerId, _ accountPeerId: PeerId) -> Bool) -> Disposable {
        self.predicatesLock.lock()
        let id = self.nextPredicateId
        self.nextPredicateId += 1
        self.predicates[id] = predicate
        self.predicatesLock.unlock()
        return ActionDisposable { [weak self] in
            guard let self else {
                return
            }
            self.predicatesLock.lock()
            self.predicates.removeValue(forKey: id)
            self.predicatesLock.unlock()
        }
    }

    // MARK: - Visibility (main thread)

    /// Lock layer: the peer is not Chat-Locked, or a grant exists for (account, peer). Vault layer (SG: Secret
    /// Vault): the peer is not hidden in this account's vault, or that vault is open.
    public func isContentVisible(peerId: PeerId, accountPeerId: PeerId) -> Bool {
        if self.isProtected(peerId: peerId, accountPeerId: accountPeerId) && !self.hasGrant(ChatLockKey(accountPeerId: accountPeerId, peerId: peerId)) {
            return false
        }
        if self.isVaultHidden(peerId: peerId, accountPeerId: accountPeerId) {
            return self.hasVaultGrant(accountPeerId)
        }
        return true
    }

    /// Current visibility, then every change for this key (distinct). May be subscribed from any queue;
    /// values are delivered on the main queue (synchronously on subscription when subscribed on main).
    public func contentVisibility(peerId: PeerId, accountPeerId: PeerId) -> Signal<Bool, NoError> {
        let key = ChatLockKey(accountPeerId: accountPeerId, peerId: peerId)
        return Signal<Bool, NoError> { subscriber in
            let disposable = MetaDisposable()
            let start: () -> Void = {
                let session = ChatLockSession.shared
                subscriber.putNext(session.isContentVisible(peerId: peerId, accountPeerId: accountPeerId))
                disposable.set(session.observeVisibility(key, { value in
                    subscriber.putNext(value)
                }))
            }
            if Thread.isMainThread {
                start()
            } else {
                DispatchQueue.main.async(execute: start)
            }
            return disposable
        }
        |> distinctUntilChanged
    }

    /// Internal (main thread): raw visibility change callbacks for one key.
    func observeVisibility(_ key: ChatLockKey, _ f: @escaping (Bool) -> Void) -> Disposable {
        let bag: Bag<(Bool) -> Void>
        if let current = self.visibilityObservers[key] {
            bag = current
        } else {
            bag = Bag()
            self.visibilityObservers[key] = bag
        }
        let index = bag.add(f)
        return ActionDisposable { [weak self, weak bag] in
            let remove: () -> Void = {
                guard let self, let bag else {
                    return
                }
                bag.remove(index)
                if bag.isEmpty, self.visibilityObservers[key] === bag {
                    self.visibilityObservers.removeValue(forKey: key)
                }
            }
            if Thread.isMainThread {
                remove()
            } else {
                DispatchQueue.main.async(execute: remove)
            }
        }
    }

    func broadcast(_ key: ChatLockKey) {
        guard let bag = self.visibilityObservers[key] else {
            return
        }
        let visible = self.isContentVisible(peerId: key.peerId, accountPeerId: key.accountPeerId)
        for f in bag.copyItems() {
            f(visible)
        }
    }

    // MARK: - Prompts (main thread)

    /// Completes synchronously with `.unlocked` when the content is already visible; otherwise shows the
    /// chat's PIN screen (serially: a different chat's request while one is on screen gets `.interrupted`).
    /// SG: Secret Vault — a vaulted chat whose vault is closed first asks for the vault PIN (generic prompt),
    /// then for the chat's own PIN if it is also Chat-Locked (D10: two sequential prompts). The vault never
    /// prompts automatically: a `.resume` request for it ends `.interrupted`.
    public func requireUnlock(peerId: PeerId, accountPeerId: PeerId, reason: ChatLockPromptReason, from host: UIViewController?, completion: @escaping (ChatLockUnlockResult) -> Void) {
        if self.isContentVisible(peerId: peerId, accountPeerId: accountPeerId) {
            completion(.unlocked)
            return
        }
        if self.isVaultHidden(peerId: peerId, accountPeerId: accountPeerId) && !self.hasVaultGrant(accountPeerId) {
            if case .resume = reason {
                completion(.interrupted)
                return
            }
            self.requireVault(accountPeerId: accountPeerId, purpose: .openChat, from: host, completion: { [weak self, weak host] result in
                guard let self, case .unlocked = result else {
                    completion(result)
                    return
                }
                self.requireUnlock(peerId: peerId, accountPeerId: accountPeerId, reason: reason, from: host, completion: completion)
            })
            return
        }
        self.presenter.request(key: ChatLockKey(accountPeerId: accountPeerId, peerId: peerId), reason: reason, host: host, completion: completion)
    }

    // MARK: - Grants and holders (main thread)

    /// Issues a pending grant (prompt succeeded). A holder attaching turns it into a held grant.
    func grant(_ key: ChatLockKey) {
        if case .held = self.grants[key] {
        } else {
            self.grants[key] = .pending(deadline: ChatLockSession.now() + ChatLockSession.pendingGrantTimeout)
            self.pendingTimers.removeValue(forKey: key)?.invalidate()
            self.pendingTimers[key] = ChatLockMainTimer(timeout: ChatLockSession.pendingGrantTimeout + 0.05, action: { [weak self] in
                guard let self else {
                    return
                }
                self.pendingTimers.removeValue(forKey: key)
                if case .pending = self.grants[key] {
                    self.revoke(key)
                }
            })
        }
        self.broadcast(key)
    }

    /// Registers a screen showing this key's content. While any holder is attached the grant (if any)
    /// stays alive; a pending grant becomes held. The holder counts as attached for `leaveGrace` after
    /// registering (push animations).
    public func hold(peerId: PeerId, accountPeerId: PeerId, isAttached: @escaping () -> Bool) -> Disposable {
        let key = ChatLockKey(accountPeerId: accountPeerId, peerId: peerId)
        let bag: Bag<Holder>
        if let current = self.holders[key] {
            bag = current
        } else {
            bag = Bag()
            self.holders[key] = bag
        }
        let index = bag.add(Holder(isAttached: isAttached, registeredAt: ChatLockSession.now()))
        if case .pending = self.grants[key] {
            self.promoteToHeld(key)
        }
        // SG: Secret Vault — a vault chat on screen holds its account's vault open.
        if case .pending? = self.vaultGrants[accountPeerId], self.isVaultHidden(peerId: peerId, accountPeerId: accountPeerId) {
            self.promoteVaultToHeld(accountPeerId)
        }
        // Re-check once the registration grace has run out, so a holder that never attaches (an aborted
        // push) cannot keep a grant alive.
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatLockSession.leaveGrace + 0.1, execute: { [weak self] in
            self?.setNeedsHolderCheck(key)
        })
        return ActionDisposable { [weak self, weak bag] in
            let remove: () -> Void = {
                guard let self, let bag else {
                    return
                }
                bag.remove(index)
                if bag.isEmpty, self.holders[key] === bag {
                    self.holders.removeValue(forKey: key)
                }
                self.setNeedsHolderCheck(key)
            }
            if Thread.isMainThread {
                remove()
            } else {
                DispatchQueue.main.async(execute: remove)
            }
        }
    }

    /// Re-evaluates a held grant's holders; revokes it after `leaveGrace` without an attached holder.
    func setNeedsHolderCheck(_ key: ChatLockKey) {
        if self.vaultGrants[key.accountPeerId] != nil {
            self.setNeedsVaultHolderCheck(key.accountPeerId) // SG: Secret Vault
        }
        guard case .held = self.grants[key] else {
            return
        }
        if self.hasAttachedHolder(key) {
            self.leaveTimers.removeValue(forKey: key)?.invalidate()
            return
        }
        self.scheduleLeaveCheck(key)
    }

    private func hasGrant(_ key: ChatLockKey) -> Bool {
        guard let grant = self.grants[key] else {
            return false
        }
        switch grant {
        case let .pending(deadline):
            return ChatLockSession.now() < deadline
        case .held:
            if self.leaveTimers[key] == nil && !self.hasAttachedHolder(key) {
                self.scheduleLeaveCheck(key)
            }
            return true
        }
    }

    private func promoteToHeld(_ key: ChatLockKey) {
        self.grants[key] = .held
        self.pendingTimers.removeValue(forKey: key)?.invalidate()
    }

    func hasAttachedHolder(_ key: ChatLockKey) -> Bool {
        guard let bag = self.holders[key] else {
            return false
        }
        let now = ChatLockSession.now()
        for holder in bag.copyItems() {
            if now - holder.registeredAt < ChatLockSession.leaveGrace || holder.isAttached() {
                return true
            }
        }
        return false
    }

    private func scheduleLeaveCheck(_ key: ChatLockKey) {
        guard self.leaveTimers[key] == nil else {
            return
        }
        self.leaveTimers[key] = ChatLockMainTimer(timeout: ChatLockSession.leaveGrace, action: { [weak self] in
            guard let self else {
                return
            }
            self.leaveTimers.removeValue(forKey: key)
            guard case .held = self.grants[key] else {
                return
            }
            if !self.hasAttachedHolder(key) {
                self.revoke(key)
            }
        })
    }

    private func revoke(_ key: ChatLockKey) {
        guard self.grants.removeValue(forKey: key) != nil else {
            return
        }
        self.pendingTimers.removeValue(forKey: key)?.invalidate()
        self.leaveTimers.removeValue(forKey: key)?.invalidate()
        self.broadcast(key)
    }

    static func now() -> Double {
        return ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Gate registry (main thread)

    func registerGate(_ gate: ChatLockControllerGate) {
        self.gateRefs = self.gateRefs.filter { $0.value != nil }
        self.gateRefs.append(ChatLockWeakGate(gate))
    }

    func liveGates() -> [ChatLockControllerGate] {
        self.gateRefs = self.gateRefs.filter { $0.value != nil }
        return self.gateRefs.compactMap { $0.value }
    }

    // MARK: - Lock-set changes

    private func lockedPeersDidChange(_ notification: Notification) {
        let added = notification.userInfo?["added"] as? Set<PeerId> ?? Set()
        let removed = notification.userInfo?["removed"] as? Set<PeerId> ?? Set()
        if added.isEmpty && removed.isEmpty {
            return
        }

        if !added.isEmpty {
            // The owner just locked a chat that is on screen: never cover it in their face. Attached
            // non-preview screens get an implicit held grant; previews (and detached screens) cover.
            for gate in self.liveGates() where added.contains(gate.key.peerId) && gate.style != .preview && gate.isHostAttached {
                self.promoteToHeld(gate.key)
                gate.ensureHolding()
            }
        }
        if !removed.isEmpty {
            for key in Array(self.grants.keys) where removed.contains(key.peerId) {
                self.grants.removeValue(forKey: key)
                self.pendingTimers.removeValue(forKey: key)?.invalidate()
                self.leaveTimers.removeValue(forKey: key)?.invalidate()
            }
            // e.g. master "Forgot pincode?" removed the lock: whoever waits for that chat may proceed.
            self.presenter.peersUnlocked(removed)
        }

        let affected = added.union(removed)
        for key in Array(self.visibilityObservers.keys) where affected.contains(key.peerId) {
            self.broadcast(key)
        }
    }

    // MARK: - Relock

    /// Registers a handler run on every relock (after the grants are revoked and screens evicted).
    public func addRelockHandler(_ handler: @escaping (_ revokedKeys: Set<ChatLockKey>) -> Void) -> Disposable {
        let index = self.relockHandlers.add(handler)
        return ActionDisposable { [weak self] in
            let remove: () -> Void = {
                self?.relockHandlers.remove(index)
            }
            if Thread.isMainThread {
                remove()
            } else {
                DispatchQueue.main.async(execute: remove)
            }
        }
    }

    /// Revokes every grant (covers re-appear synchronously), pops everything stacked above the lowest
    /// relocked chat of each navigation stack (that chat stays covered in place and re-prompts on resume),
    /// runs the relock handlers, then the app-level teardown.
    public func relockAll(reason: ChatLockRelockReason) {
        // SG: Secret Vault — vaults first: their eviction also drops the iPad master-column vault list, which
        // the Chat Lock eviction below keeps.
        switch reason {
        case .background:
            self.closeVault(accountPeerId: nil, reason: .background)
        case .deviceLocked:
            self.closeVault(accountPeerId: nil, reason: .deviceLocked)
        }
        let revokedKeys = Set(self.grants.keys)
        self.grants.removeAll()
        for (_, timer) in self.pendingTimers {
            timer.invalidate()
        }
        self.pendingTimers.removeAll()
        for (_, timer) in self.leaveTimers {
            timer.invalidate()
        }
        self.leaveTimers.removeAll()

        for key in Array(self.visibilityObservers.keys) where revokedKeys.contains(key) {
            self.broadcast(key)
        }
        if !revokedKeys.isEmpty {
            self.evictScreens(above: revokedKeys)
        }
        for handler in self.relockHandlers.copyItems() {
            handler(revokedKeys)
        }
        self.configuration?.relockTeardown(revokedKeys)
    }

    private func evictScreens(above revokedKeys: Set<ChatLockKey>) {
        var lowest: [ObjectIdentifier: (NavigationController, Int)] = [:]
        for gate in self.liveGates() where gate.style != .preview && gate.isCovered && revokedKeys.contains(gate.key) {
            guard let host = gate.host, let navigationController = host.navigationController as? NavigationController else {
                continue
            }
            guard let index = navigationController.viewControllers.firstIndex(where: { $0 === host }) else {
                continue
            }
            let id = ObjectIdentifier(navigationController)
            if let current = lowest[id], current.1 <= index {
                continue
            }
            lowest[id] = (navigationController, index)
        }
        for (_, entry) in lowest {
            let (navigationController, index) = entry
            let controllers = navigationController.viewControllers
            guard index + 1 < controllers.count else {
                continue
            }
            // Keep the relocked chat and everything below it, plus iPad master-column controllers.
            let kept = Array(controllers[0 ... index]) + controllers[(index + 1)...].filter { controller in
                if let controller = controller as? ViewController, case .master = controller.navigationPresentation {
                    return true
                }
                return false
            }
            if kept.count != controllers.count {
                navigationController.setViewControllers(kept, animated: false)
            }
        }
    }

    // MARK: - App lifecycle

    private func applicationWillResignActive() {
        guard self.configuration != nil else {
            return
        }
        // Resign also fires for Control Center, the Face ID sheet, permission alerts and calls: shield
        // the screen but keep the grants. iPad Split View / Stage Manager windows are left alone.
        let isMainWindowFullScreen = self.isMainWindowFullScreen()
        if self.hasLiveGrants && !self.isAuthenticating && isMainWindowFullScreen {
            self.privacyShield.show(presentationData: self.currentPresentationData(), referenceWindow: self.mainWindow())
        }
        // SG: Secret Vault — D1: an open vault stays open on resign, covered by the shield above (hasLiveGrants
        // includes vault grants): a permission alert, Allow Paste, Apple Pay or Siri inside a vault chat must not
        // close it. Background and device lock close it (relockAll). Closing on resign too stays behind the flag
        // (off by default).
        if ChatLockSession.vaultClosesOnResign && !self.vaultGrants.isEmpty && !self.isAuthenticating && isMainWindowFullScreen {
            UIView.performWithoutAnimation {
                self.closeVault(accountPeerId: nil, reason: .resign)
            }
        }
    }

    private func applicationDidEnterBackground() {
        // SG: Secret Vault (audit batch 4) — leaving the app ends the credential proof, whatever else happens.
        self.clearVaultCredentialProof()
        guard self.configuration != nil else {
            return
        }
        if self.hasLiveGrants {
            self.privacyShield.show(presentationData: self.currentPresentationData(), referenceWindow: self.mainWindow())
        }
        // Synchronous and without animations: the app-switcher snapshot is taken right after this.
        UIView.performWithoutAnimation {
            self.relockAll(reason: .background)
        }
        self.isAuthenticating = false
    }

    private func protectedDataWillBecomeUnavailable() {
        self.clearVaultCredentialProof()
        guard self.configuration != nil else {
            return
        }
        UIView.performWithoutAnimation {
            self.relockAll(reason: .deviceLocked)
        }
    }

    private func applicationDidBecomeActive() {
        guard self.configuration != nil else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.privacyShield.hide()
            // Re-prompt for the relocked chat the user is looking at (the presenter waits for AppLock).
            // SG: Secret Vault — never for a vaulted chat: the vault does not prompt automatically.
            for gate in self.liveGates() where gate.canResumePrompt && !self.isVaultClosedFor(gate.key) {
                gate.promptIfNeeded(reason: .resume)
                break
            }
            self.presenter.setNeedsPresentation()
        }
    }

    func mainWindow() -> UIWindow? {
        guard let root = self.configuration?.rootViewController(), root.isViewLoaded else {
            return nil
        }
        return root.view.window
    }

    func isMainWindowFullScreen() -> Bool {
        guard let window = self.mainWindow() else {
            return true
        }
        let windowSize = window.bounds.size
        let screenSize = window.screen.bounds.size
        return abs(windowSize.width - screenSize.width) < 1.0 && abs(windowSize.height - screenSize.height) < 1.0
    }

    // MARK: - Vault credential proof (SG: Secret Vault — audit batch 4, #27)

    /// The vault credential was just entered correctly (any surface). Any thread.
    public func noteVaultCredentialProof() {
        self.vaultProofLock.lock()
        self.vaultCredentialProofAt = ChatLockThrottle.monotonicNow()
        self.vaultProofLock.unlock()
    }

    /// Whether the vault credential was proven less than a minute ago, so a Settings switch that requires it
    /// does not ask a second time. Never a substitute for the credential itself.
    public var hasRecentVaultCredentialProof: Bool {
        self.vaultProofLock.lock()
        let at = self.vaultCredentialProofAt
        self.vaultProofLock.unlock()
        guard let at else {
            return false
        }
        let elapsed = ChatLockThrottle.monotonicNow() - at
        // A reboot restarts the clock: a negative elapsed time means the proof is from another boot.
        return elapsed >= 0.0 && elapsed < ChatLockSession.vaultCredentialProofTimeout
    }

    func clearVaultCredentialProof() {
        self.vaultProofLock.lock()
        self.vaultCredentialProofAt = nil
        self.vaultProofLock.unlock()
    }
}

// MARK: - Protection recovery (Zenlygram — audit batch 4: #70, #71)

/// Which protection a recovery flow is for.
public enum SGProtectionRecoveryTarget {
    case vault
    case chatLock
}

/// The outcome of a device-owner authentication — and of the recovery flows built on it, where `.success`
/// means the whole flow finished.
///
/// Zenlygram — audit batch 4: this used to be a plain `Bool`, which made "the user dismissed the sheet" and
/// "this iPhone has neither a passcode nor biometrics, so nothing could ever be proven" look identical. Every
/// caller treated both as a cancel, so on a passcode-less iPhone every recovery action was a silent no-op and
/// the vault stayed stuck in recovery forever. The reason now travels with the result, so each surface can
/// say "set a device passcode" instead of closing without a word.
public enum SGDeviceOwnerAuthResult {
    /// Authenticated (or, for the recovery helpers, the recovery ran to the end).
    case success
    /// The user dismissed the system sheet, or cancelled a recovery screen.
    case cancelled
    /// `LAPolicy.deviceOwnerAuthentication` cannot be evaluated at all: no passcode and no biometrics.
    case unavailable
}

public extension ChatLockSession {
    /// Whether device-owner authentication could succeed at all on this iPhone right now (a device passcode
    /// or an enrolled biometric exists). Surfaces use it to render a recovery action that cannot work as an
    /// explained, disabled row instead of a live button — see `authenticateDeviceOwner`.
    var canAuthenticateDeviceOwner: Bool {
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Device-owner authentication WITH the iPhone passcode allowed. Used only where the credential itself no
    /// longer exists (the recovery flows) — device ownership is then the only proof left. `.unavailable` when
    /// the device has neither biometrics nor a passcode: there is nothing to prove, so recovery is refused and
    /// the caller tells the user to set a device passcode.
    func authenticateDeviceOwner(reason: String, completion: @escaping (SGDeviceOwnerAuthResult) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // NOT a cancel: nothing on this iPhone could ever satisfy the check, so the caller must explain
            // rather than close silently.
            DispatchQueue.main.async { completion(.unavailable) }
            return
        }
        self.onMain { session in
            session.isAuthenticating = true
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                DispatchQueue.main.async {
                    ChatLockSession.shared.isAuthenticating = false
                    completion(success ? .success : .cancelled)
                }
            }
        }
    }

    /// Recovery: device-owner authentication, then the normal "set a credential" screen, then the new
    /// credential replaces what the restore left behind. `present` shows the returned UIKit container (the
    /// caller decides from where). `.cancelled` on a dismissed sheet or screen; `.unavailable` travels on
    /// unchanged from `authenticateDeviceOwner`, and the caller MUST surface it (nothing was presented).
    func runSetNewPinRecovery(_ target: SGProtectionRecoveryTarget, presentationData: PresentationData, present: @escaping (UIViewController) -> Void, completion: @escaping (SGDeviceOwnerAuthResult) -> Void) {
        self.authenticateDeviceOwner(reason: SGProtectionStrings.authReason, completion: { result in
            guard case .success = result else {
                completion(result)
                return
            }
            var didFinish = false
            let controller = ChatPincodeViewController(mode: .set(onSuccess: { code, type, biometricEnabled in
                didFinish = true
                switch target {
                case .vault:
                    ChatPincodeManager.shared.resolveVaultRecovery(newCode: code, type: type, biometricEnabled: biometricEnabled)
                case .chatLock:
                    ChatPincodeManager.shared.resolveChatLockRecovery(newCode: code, type: type, biometricEnabled: biometricEnabled)
                }
                completion(.success)
            }), presentationData: presentationData)
            controller.onCancel = {
                guard !didFinish else {
                    return
                }
                completion(.cancelled)
            }
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.setNavigationBarHidden(true, animated: false)
            navigationController.modalPresentationStyle = .fullScreen
            present(navigationController)
        })
    }

    /// Recovery: the user gives up on the Chat Lock credentials the restore left behind and turns the feature
    /// off (device-owner authentication first — the covered chats are otherwise a stranger's to reveal).
    /// `.unavailable` travels on unchanged, and the caller MUST surface it: nothing happened.
    func runTurnOffChatLockRecovery(completion: @escaping (SGDeviceOwnerAuthResult) -> Void) {
        self.authenticateDeviceOwner(reason: SGProtectionStrings.authReason, completion: { result in
            guard case .success = result else {
                completion(result)
                return
            }
            ChatPincodeManager.shared.resolveChatLockRecoveryByTurningOff()
            completion(.success)
        })
    }
}
