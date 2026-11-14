import Foundation
import UIKit
import UserNotifications
import WidgetKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramIntents
import SGChatLock
import SGSecretVault
import SGProtectedStore

// Zenlygram — Secret Vault app glue (audit batch 3, design §8; compiled into TelegramUI). Configured from
// sgChatLockConfigure (main app only):
// - migrations M1 / M3 (SGProtectedStore) and M2 (ChatPincodeManager) while protected data is available,
//   retried on protectedDataDidBecomeAvailable / didBecomeActive until done;
// - per account (activeAccountContexts): M4 (legacy vault ids → every logged-in account) + its unarchive
//   repair, then M5 (one-time cleanup, D4); pending unmutes; closing the vault of an account that disappears;
//   a watcher that carries the vault / Chat Lock over to the supergroup a protected basic group was upgraded to
//   and keeps vault chats out of the Archive;
// - the effects of a vault change, serially per account: mute / unmute, unarchive / re-archive, unpin / re-pin,
//   donation and delivered notification cleanup, widget reload.

func sgSecretVaultConfigure(_ sharedContext: SharedAccountContextImpl) {
    guard sharedContext.applicationBindings.isMainApp else {
        return
    }
    SGSecretVaultCoordinator.shared.start(sharedContext)
}

// MARK: - Glue API (main thread unless stated)

/// An in-app banner / sound for this peer must be suppressed: vault-hidden in this account and its vault closed.
func sgSecretVaultSuppressesInAppNotification(context: AccountContext, peerId: EnginePeer.Id) -> Bool {
    let session = ChatLockSession.shared
    let accountPeerId = context.account.peerId
    return session.isVaultHidden(peerId: peerId, accountPeerId: accountPeerId) && !session.isVaultOpen(accountPeerId: accountPeerId)
}

/// For open paths that do not go through navigateToChatController: when the peer is vault-hidden and its vault
/// is closed, asks for the vault PIN and calls `retry` once it is open. Returns true when it intercepted.
func sgSecretVaultInterceptOpen(context: AccountContext, peerId: EnginePeer.Id, from host: UIViewController?, retry: @escaping () -> Void) -> Bool {
    let session = ChatLockSession.shared
    let accountPeerId = context.account.peerId
    guard session.isVaultHidden(peerId: peerId, accountPeerId: accountPeerId), !session.isVaultOpen(accountPeerId: accountPeerId) else {
        return false
    }
    session.requireVault(accountPeerId: accountPeerId, purpose: .openChat, from: host, completion: { result in
        if case .unlocked = result {
            retry()
        }
    })
    return true
}

/// Emits once on subscription, then after every vault / Chat Lock / readability change. Main queue.
func sgProtectionChangesSignal() -> Signal<Void, NoError> {
    return Signal { subscriber in
        if Thread.isMainThread {
            subscriber.putNext(Void())
        } else {
            DispatchQueue.main.async {
                subscriber.putNext(Void())
            }
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .fenixSecretVaultChanged,
            ChatPincodeManager.lockedPeersDidChangeNotification,
            SGProtectedStore.didChangeNotification
        ]
        let observers = names.map { name in
            return center.addObserver(forName: name, object: nil, queue: .main, using: { _ in
                subscriber.putNext(Void())
            })
        }
        return ActionDisposable {
            for observer in observers {
                center.removeObserver(observer)
            }
        }
    }
}

/// "Next unread channel" (#21): nil = do not offer one (the current chat is vault-hidden); otherwise the peers the
/// engine must skip (this account's vault). Any thread.
func sgSecretVaultNextChannelExclusion(context: AccountContext, currentPeerId: EnginePeer.Id) -> Set<EnginePeer.Id>? {
    let accountPeerId = context.account.peerId
    if SecretVaultManager.shared.shouldHide(currentPeerId, accountPeerId: accountPeerId) {
        return nil
    }
    return SecretVaultManager.shared.vaultedPeerIds(accountPeerId: accountPeerId)
}

// MARK: - Delivered notifications

/// Removes already-delivered notifications whose peer matches (a vaulted chat must not linger on the lock screen
/// / in Notification Center). Delivered notifications carry the peer as a `peerId` Int64 in userInfo, with a
/// legacy from_id / chat_id / channel_id fallback for older push payloads. (Moved from ChatContextMenus.)
func sgSecretVaultRemoveDeliveredNotifications(matching predicate: @escaping (EnginePeer.Id) -> Bool) {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { notifications in
        var identifiers: [String] = []
        for notification in notifications {
            let userInfo = notification.request.content.userInfo
            var peerId: EnginePeer.Id?
            if let value = userInfo["peerId"] as? Int64 {
                peerId = EnginePeer.Id(value)
            } else if let value = userInfo["peerId"] as? String, let intValue = Int64(value) {
                peerId = EnginePeer.Id(intValue)
            } else if let fromId = userInfo["from_id"] as? String, let intValue = Int64(fromId) {
                peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(intValue))
            } else if let chatId = userInfo["chat_id"] as? String, let intValue = Int64(chatId) {
                peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(intValue))
            } else if let channelId = userInfo["channel_id"] as? String, let intValue = Int64(channelId) {
                peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(intValue))
            }
            if let peerId, predicate(peerId) {
                identifiers.append(notification.request.identifier)
            }
        }
        if !identifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}

// MARK: - Coordinator

/// Runs one account's effects strictly in order (an "add" and its Undo never race).
private final class SGSecretVaultEffectQueue {
    private var pending: [() -> Signal<Never, NoError>] = []
    private var isRunning = false

    func enqueue(_ effect: @escaping () -> Signal<Never, NoError>) {
        self.pending.append(effect)
        self.runNext()
    }

    private func runNext() {
        guard !self.isRunning, !self.pending.isEmpty else {
            return
        }
        self.isRunning = true
        let effect = self.pending.removeFirst()
        let _ = (effect()
        |> deliverOnMainQueue).startStandalone(completed: { [weak self] in
            // Next runloop: an effect that completes synchronously must not re-enter.
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.isRunning = false
                self.runNext()
            }
        })
    }
}

/// One account's protection watcher (audit batch 3): see `SGSecretVaultCoordinator.makeWatcher`.
private final class SGSecretVaultAccountWatcher {
    weak var context: AccountContext?
    let disposable = MetaDisposable()
    /// Vault chats moved out of the Archive whose move has not shown up in the chat list data yet.
    var unarchiving = Set<EnginePeer.Id>()

    init(context: AccountContext) {
        self.context = context
    }

    deinit {
        self.disposable.dispose()
    }
}

/// What a watcher observes; a change re-subscribes the peer data.
private struct SGSecretVaultWatchInput: Equatable {
    let vault: Set<Int64>
    let locked: Set<EnginePeer.Id>
    let isVaultActive: Bool
}

private final class SGSecretVaultCoordinator {
    static let shared = SGSecretVaultCoordinator()

    private weak var sharedContext: SharedAccountContextImpl?
    private var observers: [NSObjectProtocol] = []
    private var migrationObservers: [NSObjectProtocol] = []
    private var accountsDisposable: Disposable?
    private var accounts: [EnginePeer.Id: AccountContext] = [:]
    /// The account legacy (pre-batch-3) vaulting muted chats in: M4 adopts the legacy mute records there.
    private var primaryAccountPeerId: EnginePeer.Id?
    private var effectQueues: [EnginePeer.Id: SGSecretVaultEffectQueue] = [:]
    private var watchers: [EnginePeer.Id: SGSecretVaultAccountWatcher] = [:]
    private var isRunningAccountMigrations = false
    private var widgetReloadWorkItem: DispatchWorkItem?

    func start(_ sharedContext: SharedAccountContextImpl) {
        guard self.sharedContext == nil else {
            return
        }
        self.sharedContext = sharedContext
        // Installs the store → `.fenixSecretVaultChanged` re-post and the pre-v1 plaintext migration.
        let _ = SecretVaultManager.shared

        self.runMigrationsIfPossible()

        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: .fenixSecretVaultChanged, object: nil, queue: .main, using: { [weak self] notification in
            self?.vaultDidChange(notification)
        }))
        self.observers.append(center.addObserver(forName: ChatPincodeManager.lockedPeersDidChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            self?.lockedPeersDidChange(notification)
        }))

        self.accountsDisposable = (sharedContext.activeAccountContexts
        |> deliverOnMainQueue).startStrict(next: { [weak self] contexts in
            self?.accountsUpdated(contexts.accounts.map { $0.1 }, primaryAccountPeerId: contexts.primary?.account.peerId)
        })
    }

    // MARK: Migrations M1 / M2 / M3

    /// Zenlygram — audit batch 4 (#70 / #71): the restore detectors do NOT live here. The Chat Lock one is
    /// inside `rebuildLockedCache` and the vault one inside `reconcileProtectionFlags`, so no ordering between
    /// the cache warm-up, the store migrations and this reconciliation can destroy the evidence they look at
    /// (the locked-ids mirror, and `secretVaultEnabled` versus the credential). Do not add new ordering
    /// dependencies here.
    private func runMigrationsIfPossible() {
        guard UIApplication.shared.isProtectedDataAvailable else {
            self.installMigrationRetry()
            return
        }
        SGProtectedStore.shared.setProtectedDataAvailable(true)
        ChatPincodeManager.shared.prepareLockedPeersCache(protectedDataAvailable: true)
        let storeDone = SGProtectedStore.shared.runMainAppMigrations()
        let flagsDone = ChatPincodeManager.shared.reconcileProtectionFlags()
        if flagsDone {
            // Audit #40: trust-on-first-use baseline of the biometric enrolment for credentials that were set
            // before this build (the flags are decided, so the keychain is readable right now).
            ChatPincodeManager.shared.prepareBiometricBaselinesIfNeeded()
        }
        if storeDone && flagsDone {
            for observer in self.migrationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            self.migrationObservers.removeAll()
            if !self.accounts.isEmpty {
                self.runAccountMigrationsIfNeeded()
            }
        } else {
            self.installMigrationRetry()
        }
    }

    private func installMigrationRetry() {
        guard self.migrationObservers.isEmpty else {
            return
        }
        let center = NotificationCenter.default
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            self.migrationObservers.append(center.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                self?.runMigrationsIfPossible()
            }))
        }
    }

    // MARK: Accounts

    private func accountsUpdated(_ contexts: [AccountContext], primaryAccountPeerId: EnginePeer.Id?) {
        var current: [EnginePeer.Id: AccountContext] = [:]
        for context in contexts {
            current[context.account.peerId] = context
        }
        for (accountPeerId, _) in self.accounts where current[accountPeerId] == nil {
            // Logged out / removed: nothing of its vault may stay on screen.
            ChatLockSession.shared.closeVault(accountPeerId: accountPeerId, reason: .vaultChanged)
            self.effectQueues.removeValue(forKey: accountPeerId)
        }
        for (accountPeerId, watcher) in self.watchers where current[accountPeerId] == nil || current[accountPeerId] !== watcher.context {
            watcher.disposable.dispose()
            self.watchers.removeValue(forKey: accountPeerId)
        }
        self.accounts = current
        self.primaryAccountPeerId = primaryAccountPeerId
        guard !current.isEmpty else {
            return
        }
        // M4 first (synchronously, before any vault mutation can happen), then M5.
        self.runAccountMigrationsIfNeeded()

        for (accountPeerId, context) in current {
            let pending = SecretVaultManager.shared.takePendingUnmutes(accountPeerId: accountPeerId)
            for peerId in pending {
                let _ = SGSecretVaultCoordinator.unmuteIfMutedForever(context: context, peerId: peerId).startStandalone()
            }
            if self.watchers[accountPeerId] == nil {
                self.watchers[accountPeerId] = self.makeWatcher(context: context)
            }
        }
    }

    // MARK: Protection watcher (audit batch 3)

    /// Per account, over its vault members and every Chat Lock peer (main queue):
    /// - a basic group upgraded to a supergroup gets a new peer id; a vaulted / locked group's supergroup joins
    ///   the vault / gets the same lock, so it never shows (or opens) unprotected. The keyed vault add runs the add
    ///   effects on it, and ChatLockSession evicts it if it is open outside the vault. (Residual: until the main
    ///   app has seen the upgrade, the Notification Service extension cannot know the new id.)
    /// - #8: while the vault is active, a vault chat archived elsewhere (e.g. from another device) goes back to
    ///   the main list — the Archive row would reveal it; recorded, so leaving the vault archives it again.
    private func makeWatcher(context: AccountContext) -> SGSecretVaultAccountWatcher {
        let watcher = SGSecretVaultAccountWatcher(context: context)
        let accountPeerId = context.account.peerId
        let engine = context.engine
        watcher.disposable.set((sgProtectionChangesSignal()
        |> map { _ -> SGSecretVaultWatchInput in
            return SGSecretVaultWatchInput(
                vault: SGProtectedStore.shared.vaultMemberIds(accountPeerId: accountPeerId.toInt64()) ?? [],
                locked: ChatPincodeManager.shared.lockedPeerIds(),
                isVaultActive: SGProtectedStore.shared.isVaultActive
            )
        }
        |> distinctUntilChanged
        |> mapToSignal { input -> Signal<(peers: [EnginePeer.Id: EnginePeer?], groups: [EnginePeer.Id: EngineChatList.Group?]), NoError> in
            let vaultIds = input.vault.map { EnginePeer.Id($0) }
            let peerIds = input.locked.union(vaultIds)
            if peerIds.isEmpty {
                return .complete()
            }
            return engine.data.subscribe(
                EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init(id:))),
                EngineDataMap(vaultIds.map(TelegramEngine.EngineData.Item.Messages.ChatListGroup.init(id:)))
            )
            |> map { peers, groups in
                return (peers: peers, groups: groups)
            }
        }
        |> deliverOnMainQueue).startStrict(next: { [weak self, weak watcher] data in
            guard let self, let watcher, let context = watcher.context else {
                return
            }
            self.watcherUpdated(watcher, context: context, peers: data.peers, groups: data.groups)
        }))
        return watcher
    }

    private func watcherUpdated(_ watcher: SGSecretVaultAccountWatcher, context: AccountContext, peers: [EnginePeer.Id: EnginePeer?], groups: [EnginePeer.Id: EngineChatList.Group?]) {
        let accountPeerId = context.account.peerId
        let vault = SecretVaultManager.shared
        let chatLock = ChatPincodeManager.shared

        // #1: basic group → supergroup.
        //
        // MARK: Zenlygram — deliberately NOT entitlement-gated, although it calls `addToVault` and
        // `copyLock`. Nothing new is being protected here: Telegram replaced the peer id of a chat
        // the user ALREADY hid or locked, and this carries the existing protection across. Gating it
        // would silently un-hide a lapsed user's hidden chat and un-lock their locked one the moment
        // a group upgraded — the exact outcome design §4.7 forbids.
        for (_, peer) in peers {
            guard case let .legacyGroup(group)? = peer, let upgradedPeerId = group.migrationReference?.peerId else {
                continue
            }
            if vault.isVaulted(group.id, accountPeerId: accountPeerId) && !vault.isVaulted(upgradedPeerId, accountPeerId: accountPeerId) {
                vault.addToVault([upgradedPeerId], accountPeerId: accountPeerId)
            }
            if chatLock.isLocked(group.id) && !chatLock.isLocked(upgradedPeerId) {
                chatLock.copyLock(from: group.id, to: upgradedPeerId)
            }
        }

        // #8 / #9: vault chats archived elsewhere.
        var archived = Set<EnginePeer.Id>()
        for (peerId, group) in groups where group == .archive {
            archived.insert(peerId)
        }
        // A chat no longer archived has completed its move.
        watcher.unarchiving.formIntersection(archived)
        guard SGProtectedStore.shared.isVaultActive else {
            return
        }
        let toUnarchive = archived.subtracting(watcher.unarchiving).filter { vault.isVaulted($0, accountPeerId: accountPeerId) }
        if toUnarchive.isEmpty {
            return
        }
        watcher.unarchiving.formUnion(toUnarchive)
        for peerId in toUnarchive {
            vault.recordVaultArchived(peerId, accountPeerId: accountPeerId)
        }
        let _ = context.engine.peers.updatePeersGroupIdInteractively(peerIds: Array(toUnarchive), groupId: .root).startStandalone()
    }

    /// M4 (+ its one-time unarchive repair, D2) and M5 (D4). Re-entrancy safe: M4 posts a global vault change.
    private func runAccountMigrationsIfNeeded() {
        guard !self.isRunningAccountMigrations, !self.accounts.isEmpty else {
            return
        }
        self.isRunningAccountMigrations = true
        defer {
            self.isRunningAccountMigrations = false
        }
        let store = SGProtectedStore.shared
        let manager = SecretVaultManager.shared
        let isFirstAssignment = !store.hasMigration(.m4AccountAssignment)
        if isFirstAssignment || manager.hasLegacyUnassignedEntries {
            if manager.assignLegacyEntries(accountPeerIds: Array(self.accounts.keys), primaryAccountPeerId: self.primaryAccountPeerId), isFirstAssignment {
                self.repairArchivedVaultChats()
                self.repairPinnedVaultChats()
            }
        }
        if store.hasMigration(.m4AccountAssignment) && store.hasMigration(.m2Flags) && !store.hasMigration(.m5Cleanup) {
            if store.isAnyProtectionConfigured {
                // D4: donations and delivered notifications from before this build may name protected chats.
                deleteAllSendMessageIntents()
                sgSecretVaultRemoveDeliveredNotifications(matching: { peerId in
                    return SecretVaultManager.shared.shouldHideOnDevice(peerId) || ChatPincodeManager.shared.isLocked(peerId)
                })
                self.scheduleWidgetReload()
            }
            store.markMigration(.m5Cleanup)
        }
    }

    /// D2 / #8: a vaulted chat must not sit in the Archive (whose row would reveal it): unarchive every vaulted
    /// chat once, per account.
    private func repairArchivedVaultChats() {
        for (accountPeerId, context) in self.accounts {
            guard let members = SGProtectedStore.shared.vaultMemberIds(accountPeerId: accountPeerId.toInt64()), !members.isEmpty else {
                continue
            }
            let peerIds = members.map { EnginePeer.Id($0) }
            let engine = context.engine
            let _ = (engine.data.get(EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Messages.ChatListGroup.init(id:))))
            |> mapToSignal { groups -> Signal<Never, NoError> in
                let archived = groups.compactMap { item -> EnginePeer.Id? in
                    return item.value == .archive ? item.key : nil
                }
                if archived.isEmpty {
                    return .complete()
                }
                return engine.peers.updatePeersGroupIdInteractively(peerIds: archived, groupId: .root)
            }).startStandalone()
        }
    }

    /// With the D2 repair, once: vault chats pinned in the main list before the vault unpinned them (see
    /// `unpinFromMainList`). Through each account's effect queue, so it never races an add effect's own unpin
    /// (a toggle is not idempotent); recorded, so leaving the vault pins them again.
    private func repairPinnedVaultChats() {
        for (accountPeerId, context) in self.accounts {
            guard let members = SGProtectedStore.shared.vaultMemberIds(accountPeerId: accountPeerId.toInt64()), !members.isEmpty else {
                continue
            }
            let queue = self.effectQueue(accountPeerId)
            for member in members.sorted() {
                let peerId = EnginePeer.Id(member)
                queue.enqueue({
                    return SGSecretVaultCoordinator.unpinFromMainList(context: context, peerId: peerId)
                })
            }
        }
    }

    // MARK: Vault changes (§8.1)

    private func effectQueue(_ accountPeerId: EnginePeer.Id) -> SGSecretVaultEffectQueue {
        if let queue = self.effectQueues[accountPeerId] {
            return queue
        }
        let queue = SGSecretVaultEffectQueue()
        self.effectQueues[accountPeerId] = queue
        return queue
    }

    private func vaultDidChange(_ notification: Notification) {
        guard let accountPeerId = notification.userInfo?[SecretVaultManager.accountPeerIdKey] as? EnginePeer.Id else {
            // Global (flag, PIN, readability, migration): M4 may be possible now; the widget may show different chats.
            self.runAccountMigrationsIfNeeded()
            self.scheduleWidgetReload()
            return
        }
        let added = notification.userInfo?[SecretVaultManager.addedKey] as? Set<EnginePeer.Id> ?? Set()
        let removed = notification.userInfo?[SecretVaultManager.removedKey] as? Set<EnginePeer.Id> ?? Set()
        guard let context = self.accounts[accountPeerId] else {
            // Not an active account: restore the notifications it gets back when it is active again.
            var pending = Set<EnginePeer.Id>()
            for peerId in removed {
                if let record = SecretVaultManager.shared.takeVaultMuteRecord(peerId, accountPeerId: accountPeerId), record.didMute {
                    pending.insert(peerId)
                }
            }
            SecretVaultManager.shared.addPendingUnmutes(pending, accountPeerId: accountPeerId)
            self.scheduleWidgetReload()
            return
        }
        let queue = self.effectQueue(accountPeerId)
        for peerId in added.sorted(by: { $0.toInt64() < $1.toInt64() }) {
            queue.enqueue({
                return SGSecretVaultCoordinator.addEffect(context: context, peerId: peerId)
            })
        }
        for peerId in removed.sorted(by: { $0.toInt64() < $1.toInt64() }) {
            queue.enqueue({
                return SGSecretVaultCoordinator.removeEffect(context: context, peerId: peerId)
            })
        }
        self.scheduleWidgetReload()
    }

    /// Chat Lock "added": its donations and delivered notifications go (Siri suggestions / share sheet / the
    /// lock screen name the chat and show its messages); widgets re-render.
    private func lockedPeersDidChange(_ notification: Notification) {
        let added = notification.userInfo?["added"] as? Set<EnginePeer.Id> ?? Set()
        for peerId in added {
            deleteSendMessageIntents(peerId: peerId)
        }
        if !added.isEmpty {
            sgSecretVaultRemoveDeliveredNotifications(matching: { added.contains($0) })
        }
        self.scheduleWidgetReload()
    }

    /// Add P in account A: mute (recorded) unless already muted, unarchive or unpin (recorded), drop donations and
    /// delivered notifications.
    private static func addEffect(context: AccountContext, peerId: EnginePeer.Id) -> Signal<Never, NoError> {
        let engine = context.engine
        let accountPeerId = context.account.peerId
        return engine.data.get(
            TelegramEngine.EngineData.Item.Peer.Peer(id: peerId),
            TelegramEngine.EngineData.Item.Peer.NotificationSettings(id: peerId),
            TelegramEngine.EngineData.Item.NotificationSettings.Global(),
            TelegramEngine.EngineData.Item.Messages.ChatListGroup(id: peerId)
        )
        |> mapToSignal { peer, notificationSettings, globalSettings, group -> Signal<Never, NoError> in
            var effects: [Signal<Never, NoError>] = []
            // No peer in this account (e.g. M4 assigning a legacy id to an account that has never seen the chat):
            // nothing can be muted there, so nothing is recorded as muted.
            if peer != nil && !SGSecretVaultCoordinator.isMuted(peer: peer, settings: notificationSettings, global: globalSettings) {
                // Mute so a hidden chat cannot reveal itself through push / banner notifications; recorded so
                // leaving the vault restores it (a mute the user had set is left alone).
                SecretVaultManager.shared.recordVaultMuted(peerId, accountPeerId: accountPeerId)
                effects.append(engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: Int32.max) |> ignoreValues)
            }
            if group == .archive {
                // D2 / #8: the Archive row must not reveal it. Recorded, so removing it (or the add's Undo) archives
                // it again.
                SecretVaultManager.shared.recordVaultArchived(peerId, accountPeerId: accountPeerId)
                effects.append(engine.peers.updatePeersGroupIdInteractively(peerIds: [peerId], groupId: .root))
            } else {
                // An archived chat has no pin in the main list (the move above leaves it unpinned there).
                effects.append(SGSecretVaultCoordinator.unpinFromMainList(context: context, peerId: peerId))
            }
            deleteSendMessageIntents(peerId: peerId)
            sgSecretVaultRemoveDeliveredNotifications(matching: { $0 == peerId })
            return effects.reduce(Signal<Never, NoError>.complete(), { result, effect in
                return result |> then(effect)
            })
        }
    }

    /// Remove P: restore the notifications the vault muted (a legacy record only while still muted forever),
    /// archive it again when the vault moved it out of the Archive and it is still in the main list, and pin it
    /// again when the vault unpinned it.
    private static func removeEffect(context: AccountContext, peerId: EnginePeer.Id) -> Signal<Never, NoError> {
        // Zenlygram — audit #74: no record USUALLY means the vault changed nothing on this chat (the user had
        // already muted it themselves when they vaulted it, so `addEffect` recorded no mute) — unmuting it
        // would clobber their own "Mute forever". But no record can ALSO mean the records are GONE (they live
        // in an app-private, device-only keychain blob, so a restore onto a new iPhone loses them) while the
        // chat is still muted forever because the vault muted it. Only the second case, which needs positive
        // evidence that the bookkeeping itself is lost, falls back to a legacy record — which then unmutes it
        // only while it is still muted forever, so a mute the user changed since is never clobbered.
        let accountPeerId = context.account.peerId
        let record: SecretVaultMuteRecord
        if let storedRecord = SecretVaultManager.shared.takeVaultMuteRecord(peerId, accountPeerId: accountPeerId) {
            record = storedRecord
        } else if SecretVaultManager.shared.vaultMuteBookkeepingIsLost(accountPeerId: accountPeerId) {
            record = SecretVaultMuteRecord(isLegacy: true)
        } else {
            return .complete()
        }
        let engine = context.engine
        var effects: [Signal<Never, NoError>] = []
        if record.didMute {
            if record.isLegacy {
                effects.append(SGSecretVaultCoordinator.unmuteIfMutedForever(context: context, peerId: peerId))
            } else {
                effects.append(engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: 0) |> ignoreValues)
            }
        }
        if record.wasArchived {
            effects.append(engine.data.get(TelegramEngine.EngineData.Item.Messages.ChatListGroup(id: peerId))
            |> mapToSignal { group -> Signal<Never, NoError> in
                if group == .root {
                    return engine.peers.updatePeersGroupIdInteractively(peerIds: [peerId], groupId: .archive)
                }
                return .complete()
            })
        }
        if record.wasPinned {
            // Only while it is in the main list and not pinned already (a toggle would unpin it). Over Telegram's
            // limit this becomes a device-local extra pin (Unlimited Pinned Chats) or is refused; either is fine.
            effects.append(combineLatest(
                engine.peers.getPinnedItemIds(location: .group(.root)),
                engine.data.get(TelegramEngine.EngineData.Item.Messages.ChatListGroup(id: peerId))
            )
            |> mapToSignal { itemIds, group -> Signal<Never, NoError> in
                if group == .root && !itemIds.contains(.peer(peerId)) {
                    return engine.peers.toggleItemPinned(location: .group(.root), itemId: .peer(peerId)) |> ignoreValues
                }
                return .complete()
            })
        }
        return effects.reduce(Signal<Never, NoError>.complete(), { result, effect in
            return result |> then(effect)
        })
    }

    /// A vault chat's pin in the main list is hidden but still counts against Telegram's pin limit (TelegramCore
    /// cannot see the vault): "limit reached" with fewer pins on screen, or (Unlimited Pinned Chats) a new pin
    /// silently kept as a device-local extra, would reveal that hidden chats exist. Unpins it, recorded so leaving
    /// the vault pins it again. Run through the account's effect queue (check, then toggle).
    private static func unpinFromMainList(context: AccountContext, peerId: EnginePeer.Id) -> Signal<Never, NoError> {
        let engine = context.engine
        let accountPeerId = context.account.peerId
        return engine.peers.getPinnedItemIds(location: .group(.root))
        |> mapToSignal { itemIds -> Signal<Never, NoError> in
            guard itemIds.contains(.peer(peerId)) else {
                return .complete()
            }
            SecretVaultManager.shared.recordVaultPinned(peerId, accountPeerId: accountPeerId)
            return engine.peers.toggleItemPinned(location: .group(.root), itemId: .peer(peerId)) |> ignoreValues
        }
    }

    /// Unmutes only a chat still muted forever (the vault's own mute), never a mute the user changed since.
    static func unmuteIfMutedForever(context: AccountContext, peerId: EnginePeer.Id) -> Signal<Never, NoError> {
        let engine = context.engine
        return engine.data.get(TelegramEngine.EngineData.Item.Peer.NotificationSettings(id: peerId))
        |> mapToSignal { settings -> Signal<Never, NoError> in
            if case let .muted(until) = settings.muteState, until == Int32.max {
                return engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: 0) |> ignoreValues
            }
            return .complete()
        }
    }

    private static func isMuted(peer: EnginePeer?, settings: EnginePeer.NotificationSettings, global: EngineGlobalNotificationSettings) -> Bool {
        switch settings.muteState {
        case let .muted(until):
            return until >= Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
        case .unmuted:
            return false
        case .default:
            guard let peer else {
                return false
            }
            switch peer {
            case .user, .secretChat:
                return !global.privateChats.enabled
            case .legacyGroup:
                return !global.groupChats.enabled
            case let .channel(channel):
                switch channel.info {
                case .group:
                    return !global.groupChats.enabled
                case .broadcast:
                    return !global.channels.enabled
                }
            // SG: Secret Vault — upstream 12.9.2 added EnginePeer.community, which has no global notification
            // category of its own. Upstream resolves a community's .default mute state to "not muted" too
            // (CommunityViewScreen, and GlobalNotificationSettings.defaultIncludePeer falls through to its
            // conservative else). Reporting "not muted" is also the fail-safe answer for the vault: addEffect
            // then mutes the community itself and records that it did, so a vaulted community cannot reveal
            // itself through a push or banner, and leaving the vault restores the original setting.
            case .community:
                return false
            }
        }
    }

    // MARK: Widgets

    /// Debounced: widget timelines and the widget picker re-read the (filtered) chats.
    private func scheduleWidgetReload() {
        self.widgetReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            DispatchQueue.global(qos: .background).async {
                if #available(iOSApplicationExtension 14.0, iOS 14.0, *) {
                    #if arch(arm64) || arch(i386) || arch(x86_64)
                    WidgetCenter.shared.reloadAllTimelines()
                    #endif
                }
            }
        }
        self.widgetReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }
}
