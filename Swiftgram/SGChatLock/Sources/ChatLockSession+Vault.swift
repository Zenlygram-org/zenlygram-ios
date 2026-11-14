import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import SGProtectedStore

// SG: Secret Vault — the vault layer of the Chat Lock session (audit batch 3: #7, #12, #13, #14, #119).
//
// A vaulted chat (SGProtectedStore membership, per account) is visible only while its account's vault is OPEN:
// a vault grant exists. Grants come from the vault PIN (title gesture, secret code, opening a vault chat from
// outside the vault) and are kept alive by holders: the registered vault list while it is in its navigation
// stack, a registered vault content screen (the story viewer of a vault contact) while it is in its stack, and
// any chat screen of a vaulted peer of that account while it is attached. The vault closes when the last holder
// leaves (after `leaveGrace`), on background / device lock, after `vaultInactivityTimeout` without user activity
// (passive use counts as activity), and when the vault is turned off. Resign alone does not close it: the
// privacy shield covers it (`vaultClosesOnResign`). Closing evicts the vault list, every vault content screen and
// every vault chat (without keeping iPad master-column controllers), tears down window-level galleries / menus
// and stops vault playback.

/// Must match `Notification.Name.fenixSecretVaultChanged` (SGSecretVault depends on this module, not the reverse).
let chatLockSecretVaultChangedNotification = Notification.Name("FenixSecretVaultChanged")

public enum ChatLockVaultPromptPurpose {
    /// The title gesture: pops to an already attached vault list; the prompt offers device-owner "Forgot".
    case reveal
    /// A vault chat opened from outside the vault (Spotlight, widget, notification, link, Forward…).
    case openChat
}

public enum ChatLockVaultCloseReason {
    /// The last vault holder left (or a pending grant expired): playback stop only.
    case left
    case resign
    case background
    case deviceLocked
    case inactivity
    /// The vault was turned off, an account disappeared, or membership changed.
    case vaultChanged
}

/// A registered vault screen: the vault chat list (`isList`) or a vault content screen (the story viewer of a
/// vault contact). Main thread.
final class ChatLockVaultScreenEntry {
    weak var controller: ViewController?
    let accountPeerId: PeerId
    let registeredAt: Double
    let isList: Bool

    init(controller: ViewController, accountPeerId: PeerId, registeredAt: Double, isList: Bool) {
        self.controller = controller
        self.accountPeerId = accountPeerId
        self.registeredAt = registeredAt
        self.isList = isList
    }
}

extension ChatLockSession {
    /// D1: whether an open vault also closes when the app resigns active (full-screen, not authenticating).
    /// Off: resign is not leaving. The first permission alert, Allow Paste, Apple Pay, Siri, Control Center or a
    /// call inside a vault chat resigns the app for seconds (a grace timer does not fit them either); on resign
    /// the privacy shield covers the vault content (`hasLiveGrants` includes vault grants). Background, device
    /// lock, inactivity and turning the vault off close it.
    public static var vaultClosesOnResign: Bool = false
    /// #119: seconds without user activity after which an open vault closes. Activity: touches, hardware-keyboard
    /// presses, pointer movement, trackpad / mouse-wheel scrolls, typing and VoiceOver focus in the main window;
    /// passive use (the idle timer disabled for a recording or a call, `vaultKeepAliveProvider`) counts too.
    public static var vaultInactivityTimeout: Double = 300.0
    /// #119: installed by the app glue (main thread): true while the vault is used passively without input, e.g.
    /// a vault chat's media playing or a media viewer on screen. Asked when the inactivity timer fires.
    public static var vaultKeepAliveProvider: (() -> Bool)?

    // MARK: - Membership (any thread)

    /// Hidden in `accountPeerId`'s vault (fail closed while unreadable; never the account itself). Same answer
    /// as `SecretVaultManager.shouldHide(_:accountPeerId:)`.
    public func isVaultHidden(peerId: PeerId, accountPeerId: PeerId) -> Bool {
        return SGProtectedStore.shared.isVaultHidden(peerId: peerId.toInt64(), accountPeerId: accountPeerId.toInt64())
    }

    func isVaultHidden(_ key: ChatLockKey) -> Bool {
        return self.isVaultHidden(peerId: key.peerId, accountPeerId: key.accountPeerId)
    }

    /// Main thread: vault-hidden and its vault is closed (nothing may prompt for it automatically).
    func isVaultClosedFor(_ key: ChatLockKey) -> Bool {
        return self.isVaultHidden(key) && !self.hasVaultGrant(key.accountPeerId)
    }

    // MARK: - Vault state (main thread)

    public func isVaultOpen(accountPeerId: PeerId) -> Bool {
        return self.hasVaultGrant(accountPeerId)
    }

    /// Current open state, then every change (distinct). May be subscribed from any queue; values are delivered
    /// on the main queue (synchronously on subscription when subscribed on main).
    public func vaultOpenState(accountPeerId: PeerId) -> Signal<Bool, NoError> {
        return Signal<Bool, NoError> { subscriber in
            let disposable = MetaDisposable()
            let start: () -> Void = {
                let session = ChatLockSession.shared
                subscriber.putNext(session.isVaultOpen(accountPeerId: accountPeerId))
                disposable.set(session.observeVaultOpen(accountPeerId, { value in
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

    func observeVaultOpen(_ accountPeerId: PeerId, _ f: @escaping (Bool) -> Void) -> Disposable {
        let bag: Bag<(Bool) -> Void>
        if let current = self.vaultOpenObservers[accountPeerId] {
            bag = current
        } else {
            bag = Bag()
            self.vaultOpenObservers[accountPeerId] = bag
        }
        let index = bag.add(f)
        return ActionDisposable { [weak self, weak bag] in
            let remove: () -> Void = {
                guard let self, let bag else {
                    return
                }
                bag.remove(index)
                if bag.isEmpty, self.vaultOpenObservers[accountPeerId] === bag {
                    self.vaultOpenObservers.removeValue(forKey: accountPeerId)
                }
            }
            if Thread.isMainThread {
                remove()
            } else {
                DispatchQueue.main.async(execute: remove)
            }
        }
    }

    /// Asks for the vault PIN (generic prompt: no chat is named).
    /// - `.reveal`: completes `.unlocked` at once when this account's vault list is already attached (the caller
    ///   pops to it); otherwise it prompts even while the vault is open (the presenter does not skip a reveal
    ///   without an attached list). A lingering grant is not closed before prompting: on iPad an attached vault
    ///   chat (held grant) stays in the detail column, and after the PIN the caller pushes the vault list into
    ///   the master column. A pending grant that nothing holds is closed when the prompt does not end unlocked.
    /// - `.openChat`: completes `.unlocked` at once while the vault is open.
    public func requireVault(accountPeerId: PeerId, purpose: ChatLockVaultPromptPurpose, from host: UIViewController?, completion: @escaping (ChatLockUnlockResult) -> Void) {
        guard self.configuration != nil else {
            completion(.interrupted)
            return
        }
        guard SGProtectedStore.shared.isVaultActive else {
            switch purpose {
            case .reveal:
                completion(.cancelled)
            case .openChat:
                // Nothing is vault-hidden while the vault is off.
                completion(.unlocked)
            }
            return
        }
        // Zenlygram — audit #70: while the vault credential has to be set up again on this iPhone, nothing may
        // silently answer a vault request. A grant that is still lying around (or an attached list) would
        // stand in for a credential that no longer exists; the prompt shows the recovery screen instead.
        let needsRecovery = ChatPincodeManager.shared.protectionRecoveryStatus().vaultNeedsRecovery
        switch purpose {
        case .reveal:
            if !needsRecovery, self.hasVaultGrant(accountPeerId) && self.hasAttachedVaultList(accountPeerId) {
                completion(.unlocked)
                return
            }
            self.presenter.requestVault(accountPeerId: accountPeerId, purpose: purpose, host: host, completion: { [weak self] result in
                if result != .unlocked, let self, case .pending? = self.vaultGrants[accountPeerId], !self.hasAttachedVaultHolder(accountPeerId) {
                    self.closeVault(accountPeerId: accountPeerId, reason: .left)
                }
                completion(result)
            })
            return
        case .openChat:
            if !needsRecovery, self.hasVaultGrant(accountPeerId) {
                completion(.unlocked)
                return
            }
        }
        self.presenter.requestVault(accountPeerId: accountPeerId, purpose: purpose, host: host, completion: completion)
    }

    /// Opens `accountPeerId`'s vault (a pending grant, held once a vault screen / vault chat attaches). Only after
    /// a verified vault proof: the vault PIN (the presenter) or the secret code (the chat list glue).
    public func grantVault(accountPeerId: PeerId) {
        guard self.configuration != nil else {
            return
        }
        if case .held? = self.vaultGrants[accountPeerId] {
        } else {
            self.vaultGrants[accountPeerId] = .pending(deadline: ChatLockSession.now() + ChatLockSession.pendingGrantTimeout)
            self.vaultPendingTimers.removeValue(forKey: accountPeerId)?.invalidate()
            self.vaultPendingTimers[accountPeerId] = ChatLockMainTimer(timeout: ChatLockSession.pendingGrantTimeout + 0.05, action: { [weak self] in
                guard let self else {
                    return
                }
                self.vaultPendingTimers.removeValue(forKey: accountPeerId)
                if case .pending? = self.vaultGrants[accountPeerId] {
                    self.closeVault(accountPeerId: accountPeerId, reason: .left)
                }
            })
            if self.hasAttachedVaultHolder(accountPeerId) {
                self.promoteVaultToHeld(accountPeerId)
            }
        }
        self.vaultStateChanged(accountPeerId)
        self.startActivityMonitoringIfNeeded()
    }

    /// Registers a vault screen (the vault list) of `accountPeerId`. While it is in its navigation stack (or
    /// within `leaveGrace` of registering) it keeps that vault open; a pending grant becomes held.
    public func registerVaultScreen(_ controller: ViewController, accountPeerId: PeerId) -> Disposable {
        return self.registerVaultEntry(controller, accountPeerId: accountPeerId, isList: true)
    }

    /// Registers a vault content screen of `accountPeerId`: a screen outside the chat gates that shows vault
    /// content (the story viewer opened on a vault contact, #20 / #7). Same holder semantics as the vault list:
    /// while it is in its navigation stack (or within `leaveGrace` of registering) it keeps that vault open and a
    /// pending grant becomes held. Closing the vault evicts it (pops it with everything above it, or dismisses it
    /// when it is in no stack). Registered while that vault is closed, it is evicted on the next runloop (fail
    /// closed). Main thread.
    public func registerVaultContentScreen(_ controller: ViewController, accountPeerId: PeerId) -> Disposable {
        let disposable = self.registerVaultEntry(controller, accountPeerId: accountPeerId, isList: false)
        if !self.isVaultOpen(accountPeerId: accountPeerId) {
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller, !self.isVaultOpen(accountPeerId: accountPeerId) else {
                    return
                }
                self.evictVaultContentScreen(controller)
            }
        }
        return disposable
    }

    private func registerVaultEntry(_ controller: ViewController, accountPeerId: PeerId, isList: Bool) -> Disposable {
        let entry = ChatLockVaultScreenEntry(controller: controller, accountPeerId: accountPeerId, registeredAt: ChatLockSession.now(), isList: isList)
        self.vaultScreens = self.vaultScreens.filter { $0.controller != nil }
        self.vaultScreens.append(entry)
        if case .pending? = self.vaultGrants[accountPeerId] {
            self.promoteVaultToHeld(accountPeerId)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatLockSession.leaveGrace + 0.1, execute: { [weak self] in
            self?.setNeedsVaultHolderCheck(accountPeerId)
        })
        return ActionDisposable { [weak self, weak entry] in
            let remove: () -> Void = {
                guard let self, let entry else {
                    return
                }
                self.vaultScreens.removeAll(where: { $0 === entry })
                self.setNeedsVaultHolderCheck(accountPeerId)
            }
            if Thread.isMainThread {
                remove()
            } else {
                DispatchQueue.main.async(execute: remove)
            }
        }
    }

    /// Closes the vault of `accountPeerId` (nil = every account), in this order (design §7.5):
    /// 1. revoke and broadcast (covers go up synchronously); 2. evict the vault list, every vault content screen
    /// and every attached vault chat (lowest index per navigation stack, iPad master-column controllers included;
    /// overlay chats and stackless content screens are dismissed); 3. teardown (`.left`: playback only; otherwise galleries, menus, peeks, modals, playback);
    /// 4. activity monitor removal + VoiceOver screen change.
    public func closeVault(accountPeerId: PeerId?, reason: ChatLockVaultCloseReason) {
        var accounts = Set<PeerId>()
        if let accountPeerId {
            accounts.insert(accountPeerId)
        } else {
            accounts.formUnion(self.vaultGrants.keys)
            for entry in self.vaultScreens where entry.controller != nil {
                accounts.insert(entry.accountPeerId)
            }
        }

        // 1. Revoke and broadcast.
        var didRevoke = false
        for account in accounts {
            if self.vaultGrants.removeValue(forKey: account) != nil {
                didRevoke = true
            }
            self.vaultPendingTimers.removeValue(forKey: account)?.invalidate()
            self.vaultLeaveTimers.removeValue(forKey: account)?.invalidate()
        }
        for account in accounts {
            self.vaultStateChanged(account)
        }

        // 2. Evict.
        let animated: Bool
        switch reason {
        case .resign, .background, .deviceLocked:
            animated = false
        case .left, .inactivity, .vaultChanged:
            animated = true
        }
        let (didEvict, gateKeys) = self.evictVaultContent(accounts: accounts, animated: animated)

        // 3. Teardown.
        if case .left = reason {
            self.configuration?.relockTeardown([])
        } else if didRevoke || didEvict {
            var revokedKeys = gateKeys
            for account in accounts {
                guard let members = SGProtectedStore.shared.vaultMemberIds(accountPeerId: account.toInt64()) else {
                    continue
                }
                for member in members {
                    revokedKeys.insert(ChatLockKey(accountPeerId: account, peerId: PeerId(member)))
                }
            }
            self.configuration?.relockTeardown(revokedKeys)
        } else {
            self.configuration?.relockTeardown([])
        }

        // 4. Activity monitor + VoiceOver.
        self.stopActivityMonitoringIfNeeded()
        if didRevoke || didEvict {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    // MARK: - Grants and holders (main thread)

    func hasVaultGrant(_ accountPeerId: PeerId) -> Bool {
        guard let grant = self.vaultGrants[accountPeerId] else {
            return false
        }
        switch grant {
        case let .pending(deadline):
            return ChatLockSession.now() < deadline
        case .held:
            if self.vaultLeaveTimers[accountPeerId] == nil && !self.hasAttachedVaultHolder(accountPeerId) {
                self.scheduleVaultLeaveCheck(accountPeerId)
            }
            return true
        }
    }

    func promoteVaultToHeld(_ accountPeerId: PeerId) {
        self.vaultGrants[accountPeerId] = .held
        self.vaultPendingTimers.removeValue(forKey: accountPeerId)?.invalidate()
    }

    /// A registered vault screen of the account (the vault list or a vault content screen) that is in its
    /// navigation stack (or still within the registration grace), or an attached holder of one of the account's
    /// vault-hidden chats.
    func hasAttachedVaultHolder(_ accountPeerId: PeerId) -> Bool {
        if self.hasAttachedVaultScreen(accountPeerId, listsOnly: false) {
            return true
        }
        for key in Array(self.holders.keys) where key.accountPeerId == accountPeerId && self.isVaultHidden(key) {
            if self.hasAttachedHolder(key) {
                return true
            }
        }
        return false
    }

    /// The account's vault list is in its navigation stack (or still within the registration grace): the
    /// title-gesture reveal pops to it instead of prompting.
    func hasAttachedVaultList(_ accountPeerId: PeerId) -> Bool {
        return self.hasAttachedVaultScreen(accountPeerId, listsOnly: true)
    }

    private func hasAttachedVaultScreen(_ accountPeerId: PeerId, listsOnly: Bool) -> Bool {
        let now = ChatLockSession.now()
        for entry in self.vaultScreens where entry.accountPeerId == accountPeerId && (entry.isList || !listsOnly) {
            guard let controller = entry.controller else {
                continue
            }
            if now - entry.registeredAt < ChatLockSession.leaveGrace {
                return true
            }
            if let navigationController = controller.navigationController as? NavigationController, navigationController.viewControllers.contains(where: { $0 === controller }) {
                return true
            }
        }
        return false
    }

    /// Re-evaluates a held vault grant's holders; closes the vault after `leaveGrace` without one.
    func setNeedsVaultHolderCheck(_ accountPeerId: PeerId) {
        guard case .held? = self.vaultGrants[accountPeerId] else {
            return
        }
        if self.hasAttachedVaultHolder(accountPeerId) {
            self.vaultLeaveTimers.removeValue(forKey: accountPeerId)?.invalidate()
            return
        }
        self.scheduleVaultLeaveCheck(accountPeerId)
    }

    private func scheduleVaultLeaveCheck(_ accountPeerId: PeerId) {
        guard self.vaultLeaveTimers[accountPeerId] == nil else {
            return
        }
        self.vaultLeaveTimers[accountPeerId] = ChatLockMainTimer(timeout: ChatLockSession.leaveGrace, action: { [weak self] in
            guard let self else {
                return
            }
            self.vaultLeaveTimers.removeValue(forKey: accountPeerId)
            guard case .held? = self.vaultGrants[accountPeerId] else {
                return
            }
            if !self.hasAttachedVaultHolder(accountPeerId) {
                self.closeVault(accountPeerId: accountPeerId, reason: .left)
            }
        })
    }

    /// Broadcasts every observed vault-hidden key of the account and the vault open state.
    private func vaultStateChanged(_ accountPeerId: PeerId) {
        for key in Array(self.visibilityObservers.keys) where key.accountPeerId == accountPeerId && self.isVaultHidden(key) {
            self.broadcast(key)
        }
        if let bag = self.vaultOpenObservers[accountPeerId] {
            let isOpen = self.isVaultOpen(accountPeerId: accountPeerId)
            for f in bag.copyItems() {
                f(isOpen)
            }
        }
    }

    // MARK: - Eviction (main thread)

    /// Pops, per navigation stack, from the lowest registered vault screen (list or content) / attached
    /// interactive vault chat of `accounts` (nothing above it is kept, iPad master-column controllers included);
    /// dismisses such chats and content screens that are in no stack. Returns whether anything was evicted and
    /// the vault-hidden gate keys of those accounts.
    private func evictVaultContent(accounts: Set<PeerId>, animated: Bool) -> (Bool, Set<ChatLockKey>) {
        guard !accounts.isEmpty else {
            return (false, Set())
        }
        var lowest: [ObjectIdentifier: (NavigationController, Int)] = [:]
        let consider: (ViewController) -> Bool = { controller in
            guard let navigationController = controller.navigationController as? NavigationController, let index = navigationController.viewControllers.firstIndex(where: { $0 === controller }) else {
                return false
            }
            let id = ObjectIdentifier(navigationController)
            if let current = lowest[id], current.1 <= index {
                return true
            }
            lowest[id] = (navigationController, index)
            return true
        }
        var stacklessScreens: [ViewController] = []
        for entry in self.vaultScreens where accounts.contains(entry.accountPeerId) {
            if let controller = entry.controller, !consider(controller), !entry.isList {
                stacklessScreens.append(controller)
            }
        }
        var gateKeys = Set<ChatLockKey>()
        var stacklessGates: [ChatLockControllerGate] = []
        for gate in self.liveGates() where accounts.contains(gate.key.accountPeerId) && self.isVaultHidden(gate.key) {
            gateKeys.insert(gate.key)
            guard gate.isInteractiveAttachedHost, let host = gate.host else {
                continue
            }
            if !consider(host) {
                stacklessGates.append(gate)
            }
        }
        var didEvict = false
        for (_, entry) in lowest {
            let (navigationController, index) = entry
            let controllers = navigationController.viewControllers
            guard index < controllers.count else {
                continue
            }
            navigationController.setViewControllers(Array(controllers.prefix(index)), animated: animated)
            didEvict = true
        }
        for gate in stacklessGates {
            gate.evict(animated: animated)
            didEvict = true
        }
        for controller in stacklessScreens {
            controller.dismiss()
            didEvict = true
        }
        return (didEvict, gateKeys)
    }

    /// Fail closed for one vault content screen shown without an open vault: pops it (with everything above
    /// it), or dismisses it when it is in no navigation stack.
    private func evictVaultContentScreen(_ controller: ViewController) {
        if let navigationController = controller.navigationController as? NavigationController, let index = navigationController.viewControllers.firstIndex(where: { $0 === controller }) {
            navigationController.setViewControllers(Array(navigationController.viewControllers.prefix(index)), animated: false)
        } else {
            controller.dismiss()
        }
    }

    // MARK: - Membership changes (§7.8)

    func secretVaultDidChange(_ notification: Notification) {
        guard self.configuration != nil else {
            return
        }
        if let accountPeerId = notification.userInfo?["accountPeerId"] as? PeerId {
            let added = notification.userInfo?["added"] as? Set<PeerId> ?? Set()
            let removed = notification.userInfo?["removed"] as? Set<PeerId> ?? Set()
            let affected = added.union(removed)
            for key in Array(self.visibilityObservers.keys) where key.accountPeerId == accountPeerId && affected.contains(key.peerId) {
                self.broadcast(key)
            }
            if !added.isEmpty && !self.hasVaultGrant(accountPeerId) {
                // Just vaulted while its vault is closed (e.g. an iPad detail chat vaulted from the master list):
                // take it off screen, no prompt.
                self.evictChats(accountPeerId: accountPeerId, peerIds: added)
            }
        } else {
            for key in Array(self.visibilityObservers.keys) {
                self.broadcast(key)
            }
            if !SGProtectedStore.shared.isVaultActive {
                self.closeVault(accountPeerId: nil, reason: .vaultChanged)
            }
        }
    }

    private func evictChats(accountPeerId: PeerId, peerIds: Set<PeerId>) {
        var lowest: [ObjectIdentifier: (NavigationController, Int)] = [:]
        var stacklessGates: [ChatLockControllerGate] = []
        for gate in self.liveGates() where gate.key.accountPeerId == accountPeerId && peerIds.contains(gate.key.peerId) && gate.isInteractiveAttachedHost {
            guard let host = gate.host else {
                continue
            }
            guard let navigationController = host.navigationController as? NavigationController, let index = navigationController.viewControllers.firstIndex(where: { $0 === host }) else {
                stacklessGates.append(gate)
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
            navigationController.setViewControllers(Array(navigationController.viewControllers.prefix(index)), animated: true)
        }
        for gate in stacklessGates {
            gate.evict(animated: true)
        }
    }

    // MARK: - Inactivity (#119)

    /// Activity in the main window: touches and hardware-keyboard presses (ChatLockActivityMonitor), pointer
    /// movement and trackpad / mouse-wheel scrolls (ChatLockPointerActivityObserver), typing and VoiceOver focus.
    /// The inactivity timer also counts passive use when it fires (see `armInactivityTimer`).
    func noteUserActivity() {
        self.lastUserActivity = ChatLockSession.now()
    }

    private func startActivityMonitoringIfNeeded() {
        guard !self.vaultGrants.isEmpty else {
            return
        }
        self.noteUserActivity()
        if self.activityMonitor == nil, let window = self.mainWindow() {
            let monitor = ChatLockActivityMonitor()
            monitor.onActivity = { [weak self] in
                self?.noteUserActivity()
            }
            window.addGestureRecognizer(monitor)
            self.activityMonitor = monitor

            // Pointer movement and trackpad / mouse-wheel scrolls are not touches: pure observers of their own.
            let pointerObserver = ChatLockPointerActivityObserver(onActivity: { [weak self] in
                self?.noteUserActivity()
            })
            for recognizer in pointerObserver.makeRecognizers() {
                window.addGestureRecognizer(recognizer)
                self.activityPointerRecognizers.append(recognizer)
            }
            self.activityPointerObserver = pointerObserver

            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                UITextField.textDidChangeNotification,
                UITextView.textDidChangeNotification,
                UIAccessibility.elementFocusedNotification
            ]
            for name in names {
                self.activityObservers.append(center.addObserver(forName: name, object: nil, queue: nil, using: { [weak self] _ in
                    self?.onMain { $0.noteUserActivity() }
                }))
            }
        }
        self.armInactivityTimer()
    }

    private func stopActivityMonitoringIfNeeded() {
        guard self.vaultGrants.isEmpty else {
            return
        }
        if let monitor = self.activityMonitor {
            monitor.view?.removeGestureRecognizer(monitor)
            self.activityMonitor = nil
        }
        for recognizer in self.activityPointerRecognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        self.activityPointerRecognizers.removeAll()
        self.activityPointerObserver = nil
        for observer in self.activityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.activityObservers.removeAll()
        self.inactivityTimer?.invalidate()
        self.inactivityTimer = nil
    }

    /// One monotonic timer at `lastUserActivity + timeout`, re-armed when there was activity meanwhile. Passive
    /// use counts as activity when it fires: the idle timer disabled (Telegram's pushIdleTimerExtension while
    /// recording a voice / video message and during calls) or `vaultKeepAliveProvider` (vault playback, a media
    /// viewer on screen).
    private func armInactivityTimer() {
        guard self.inactivityTimer == nil else {
            return
        }
        let timeout = ChatLockSession.vaultInactivityTimeout
        let delay = max(1.0, self.lastUserActivity + timeout - ChatLockSession.now())
        self.inactivityTimer = ChatLockMainTimer(timeout: delay, action: { [weak self] in
            guard let self else {
                return
            }
            self.inactivityTimer = nil
            guard !self.vaultGrants.isEmpty else {
                return
            }
            if ChatLockSession.now() - self.lastUserActivity >= timeout - 0.5 {
                if UIApplication.shared.isIdleTimerDisabled || ChatLockSession.vaultKeepAliveProvider?() == true {
                    self.noteUserActivity()
                    self.armInactivityTimer()
                    return
                }
                // No toast: the vault simply closes.
                self.closeVault(accountPeerId: nil, reason: .inactivity)
            } else {
                self.armInactivityTimer()
            }
        })
    }
}
