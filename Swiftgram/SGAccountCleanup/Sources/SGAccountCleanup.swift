import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGSimpleSettings
import SGUnreadReminder
import SGAutoAccept
import SGTasks
import SGChatLock
import SGSecretVault
import SGKeychainBackupManager
import SGCallRecording
import SGCallRecordingDelivery
import SGEntitlement

/// Zenlygram — cleans up fork state that outlives an account's logout (audit #96, Batch 6).
///
/// Kept-deleted messages and edit history live in the account's Postbox and are deleted with it by
/// upstream's account cleanup. This handles the rest that is keyed outside Postbox: unread reminders,
/// the auto-accept monitor, the Tasks database, the legacy (pre-Batch 6) retention registry, the
/// account's Secret Vault state (Batch 3's shared snapshot and records) and, on the last logout, the
/// device-wide Secret Vault and Chat Lock configuration. (The Batch 3 coordinator only closes a removed
/// account's vault on screen.)
///
/// Driven by `SharedAccountContext.activeAccountContexts`, so no upstream lifecycle hook is needed:
///  - first emission (launch): reconcile reminders, legacy registry entries, vault state, cloud
///    Tasks and recordings for removed accounts. Device-only Tasks keep their existing lifecycle.
///  - later emissions: for every account that disappeared, stop its reminder and auto-accept work,
///    drop its legacy retention state, forget its vault (device-wide vault checks read every
///    account's set and would keep hiding those chats in the remaining accounts) and log it out of
///    the Zenlygram Pro entitlement (its binding, refresh token and cached JWS; nothing else).
///  - the last account logging out in this process (non-empty -> empty, never on the first
///    emission): wipe Tasks, turn auto-accept off, turn the local-retention features off, and reset
///    the Secret Vault and Chat Lock (switch, PINs, locks), so the next account signed in on this
///    device inherits neither a vault PIN it doesn't know nor locks on peers it shares with the old one.
///    Session Backups are NOT touched here — surviving a logout is the whole point of that feature.
public enum SGAccountCleanup {
    private static var started = false
    private static let disposable = MetaDisposable()
    private static var previousAccountPeerIds: Set<Int64>?
    private static var accessibilitySweepRetryObserver: NSObjectProtocol?
    private static var recordingCleanupPending = false
    private static var recordingCleanupRetryObservers: [NSObjectProtocol] = []

    /// Optional feature hook, awaited for an account before its stored session (Keychain items) of the
    /// optional feature is deleted: per removed account, for each signed-out account found by the launch
    /// reconciliation and for every stored account on the last sign-out. A build that includes the
    /// feature sets it (main queue, before `start`) to end the account's server session with the
    /// credentials it still needs; nil otherwise, and then the storage is deleted directly.
    public static var beforeAccountRemoval: ((Int64) async -> Void)?

    /// Idempotent; call once on the main queue after the shared context exists.
    public static func start(sharedContext: SharedAccountContext) {
        assert(Thread.isMainThread)
        if self.started {
            return
        }
        self.started = true
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            self.recordingCleanupRetryObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: { _ in
                SGAccountCleanup.retryRecordingCleanup()
            }))
        }

        self.disposable.set((sharedContext.activeAccountContexts
        |> map { activeAccounts -> Set<Int64> in
            return Set(activeAccounts.accounts.map { $0.1.account.peerId.toInt64() })
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).startStrict(next: { current in
            SGAccountCleanup.update(current: current)
        }))
    }

    private static func update(current: Set<Int64>) {
        guard let previous = self.previousAccountPeerIds else {
            // Launch reconciliation with the real account set (the promise only emits once the
            // accounts are loaded).
            self.previousAccountPeerIds = current
            #if SG_LENTA
            SGFeatureStorageCleanup.shared.removeAccounts(notIn: current, beforeRemoval: self.beforeAccountRemoval)
            #else
            // This build does not include the optional feature: none of its state may remain.
            SGFeatureStorageCleanup.shared.removeEverything()
            #endif
            SGTasksCloudRepository.reconcileAccounts(activeAccountPeerIds: current)
            self.reconcileRecordingCleanup(current: current)
            SGUnreadReminderManager.removeOrphanedReminders(activeAccountPeerIds: current)
            SGSimpleSettings.shared.removeLegacyRetentionState(exceptAccountIds: current)
            SecretVaultManager.shared.forgetAccounts(notIn: Set(current.map { EnginePeer.Id($0) }))
            // Audit #72: sessions written by an older build may still be `WhenUnlocked`, which DOES
            // ride an encrypted iTunes/Finder backup and Quick Start — contradicting the device-only
            // promise the Session Backup notice and the paywall make to everyone. Heal them once per
            // launch instead of only when the user opens and unlocks the Accounts Backup screen.
            // Cheap and idempotent; if the Keychain is not readable yet it leaves its done-flag unset
            // and simply retries on the next launch. A launch while the device is locked (background
            // refresh / silent push) hides every stored item, so the sweep is skipped entirely instead
            // of falsely marking itself done over a read that saw nothing.
            let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
            KeychainBackupManager.shared.upgradeAccessibilityIfNeeded(protectedDataAvailable: protectedDataAvailable)
            if !protectedDataAvailable {
                self.scheduleAccessibilitySweepRetry()
            }
            return
        }
        self.previousAccountPeerIds = current

        for accountPeerId in previous.subtracting(current) {
            // Fence cloud responses before removing the binding; no late response may recreate
            // this account's shared tasks, drafts or cursor after logout.
            SGTasksCloudRepository.purgeAccount(accountPeerId: accountPeerId)
            // Cancel readable legacy sends before retiring delivery state or changing protection.
            // Their destination may be another signed-in account because old sidecars had no owner.
            for (recordingId, _) in SGCallRecordingStore.shared.pendingSends() {
                let owner = SGCallRecordingStore.shared.item(id: recordingId)?.accountPeerId
                if (owner == nil || owner == accountPeerId) && !SGCallRecordingDelivery.shared.cancelSend(id: recordingId) {
                    self.recordingCleanupPending = true
                }
            }
            if !SGCallRecordingDelivery.shared.accountRemoved(accountPeerId: accountPeerId) {
                self.recordingCleanupPending = true
            }
            SGUnreadReminderManager.stop(accountPeerId: accountPeerId)
            SGAutoAcceptManager.accountRemoved(EnginePeer.Id(accountPeerId))
            SGSimpleSettings.shared.removeLegacyRetentionState(accountId: accountPeerId)
            SecretVaultManager.shared.forgetAccount(EnginePeer.Id(accountPeerId))
            // Zenlygram Pro — the account's binding, refresh token and cached JWS go with it. Until
            // now they stayed in the Keychain until an explicit unlink on the paywall, so a signed-out
            // account kept a live server session and its old token governed again on the next sign-in.
            // `logout` empties the local material SYNCHRONOUSLY, here on the main queue, before
            // anything waits on the network; `/bind/revoke` follows in the background with the token
            // it captured, so a slow revoke can neither keep the session alive nor wipe a re-bind
            // that lands after it. Only THIS account's material: other accounts, the device id, the
            // local grace and the StoreKit outbox (an unfinished paid transaction is still owed its
            // attach) are untouched.
            SGEntitlement.shared.logout(accountPeerId: accountPeerId)
            // Zenlygram — recordings are per-account too. This is a multi-account client: logging
            // out of the work account while the personal one stays signed in used to leave that
            // account's calls listed, playable and shareable, labelled with the work contact's
            // name. The sidecar carries the account that made the recording (version 2); version-1
            // sidecars carry nothing, so they cannot be attributed and go with any logout rather
            // than outliving every account that might have made them.
            // The durable removal also covers locked metadata and a live capture.
            if SGCallRecordingStore.shared.deleteAll(accountPeerId: accountPeerId) != .completed {
                self.recordingCleanupPending = true
            }
            // Zenlygram — the optional feature's session, drafts, upload queue and cache of this account.
            SGFeatureStorageCleanup.shared.removeAccount(accountPeerId, beforeRemoval: self.beforeAccountRemoval)
        }

        if !previous.isEmpty && current.isEmpty {
            // Last account logged out: nothing account-independent should survive either.
            TodoStorage.removeAllData()
            SGTasksCloudRepository.removeAllCloudData()
            // wf15 §7.4: the per-account `sgtasks.*` markers (the D4 sheet's marker, `remaining`, the
            // durable sent set, the explainer, the consent prompt, the other-account notice, the
            // scope-key sweep) go with the device rows they describe — except the durable manual
            // invitation answers (`sgtasks.inviteAnswers.*`), which survive every logout (§5.3).
            SGTasksLocalMarkers.removeAll()
            SGAutoAcceptManager.resetForNoAccounts()
            // The stored data went away with the accounts' Postbox folders; the next login starts
            // with both local-retention features off (opt-in again).
            SGSimpleSettings.shared.showDeletedMessages = false
            SGSimpleSettings.shared.editHistoryEnabled = false
            // Secret Vault and Chat Lock are device-wide (one vault PIN, one master PIN, locks keyed by
            // peer only): reset them the same way. The vault first, so disableChatLock has no vault
            // credential left to carry over.
            SecretVaultManager.shared.resetForNoAccounts()
            ChatPincodeManager.shared.disableChatLock()
            // Zenlygram — call recordings live in the app's own container, outside every Postbox, so
            // nothing else deletes them. They must not greet whoever signs in next: wipe the whole
            // directory, and drop the one-time recording consent with it so the next user is asked
            // again rather than inheriting somebody else's acceptance. Same order and same reason as
            // the per-account branch above: the queued uploads go before their files do.
            if !SGCallRecordingDelivery.shared.cancelAllSends() {
                self.recordingCleanupPending = true
            }
            if SGCallRecordingStore.shared.deleteAll() != .completed {
                self.recordingCleanupPending = true
            }
            SGCallRecordingGate.consentAccepted = false
            SGCallRecordingGate.notifyOtherParty = false
            // "Send to Saved Messages" goes with them. It is the one switch that uploads a
            // recording without being asked, and inheriting it from the previous user would mean
            // the next person's first recorded call leaves the device before they have ever seen
            // the screen that explains what that means.
            SGCallRecordingGate.sendToSavedMessages = false
            // Zenlygram — every account's state of the optional feature (device-level items stay).
            SGFeatureStorageCleanup.shared.removeAllAccounts(beforeRemoval: self.beforeAccountRemoval)
            // Audit #43: the Session Backup is deliberately NOT cleared here. Reaching zero accounts
            // is exactly the flow the feature exists for — an ordinary logout of the only account,
            // "Remove account from App" (which deletes the account record and so lands in this very
            // branch while promising the session stays restorable), and the advertised "log out of
            // everything, sign back into one account with a code, restore the rest". The sessions
            // stay active on Telegram, and restoring always needs one account signed in first, so
            // wiping them here would only force an SMS/e-mail code for every account. The keys are
            // protected by the Session Backup screen's device-owner gate instead, and clearing them
            // stays an explicit, confirmed action on that screen ("Delete All").
            // Nothing is left to recover, so a pending restore/recovery state from a previous
            // device migration must not greet the next account (Batch 4 recovery bits).
            ChatPincodeManager.shared.clearProtectionRecovery()
        }
        self.reconcileRecordingCleanup(current: current)
    }

    private static func reconcileRecordingCleanup(current: Set<Int64>) {
        // Delivery's content-free ledger can cancel work even while sidecars are locked.
        // Preserve that evidence until cancellation is attempted, then reconcile local files.
        let deliveryCleared = SGCallRecordingDelivery.shared.reconcileAccounts(signedInAccountPeerIds: current)
        let removal = SGCallRecordingStore.shared.reconcileAccounts(signedInAccountPeerIds: current)
        // A previous process may have left a separate account removal or global wipe pending.
        let pendingRemoval = SGCallRecordingStore.shared.retryPendingAccountRemovals()
        self.recordingCleanupPending = !deliveryCleared || removal != .completed || pendingRemoval != .completed
    }

    private static func retryRecordingCleanup() {
        guard self.recordingCleanupPending, let current = self.previousAccountPeerIds else {
            return
        }
        let deliveryCleared = SGCallRecordingDelivery.shared.reconcileAccounts(signedInAccountPeerIds: current)
        let removal = SGCallRecordingStore.shared.retryPendingAccountRemovals()
        self.recordingCleanupPending = !deliveryCleared || removal != .completed
    }

    /// The launch reconciliation above runs once per process, so an app launched into the background
    /// on a locked device would leave the audit-#72 sweep to the next launch (or to the user opening
    /// the Accounts Backup screen). Give it one more chance on the first unlock of this process.
    private static func scheduleAccessibilitySweepRetry() {
        guard self.accessibilitySweepRetryObserver == nil else {
            return
        }
        self.accessibilitySweepRetryObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main, using: { _ in
            KeychainBackupManager.shared.upgradeAccessibilityIfNeeded(protectedDataAvailable: true)
            if let observer = SGAccountCleanup.accessibilitySweepRetryObserver {
                NotificationCenter.default.removeObserver(observer)
                SGAccountCleanup.accessibilitySweepRetryObserver = nil
            }
        })
    }
}
