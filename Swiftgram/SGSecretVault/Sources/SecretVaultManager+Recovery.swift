import Foundation
import Postbox
import SGChatLock
import SGSimpleSettings
import SGProtectedStore

/// How the chat-list search may treat what the user types while the secret-code reveal is on (audit #27 /
/// #73 / #89).
public enum SecretVaultSecretCodeMode: Equatable {
    /// The secret code is off: the search behaves exactly like Telegram's.
    case off
    /// A vault credential can be checked: candidates are verified (throttled) and a match reveals the vault.
    case armed
    /// The credential cannot be checked right now (restored device, recovery pending, unreadable state):
    /// candidate text is HELD locally and never verified — and above all never sent to the server as a search
    /// query, which is exactly how the vault PIN leaked after a migration (audit #73).
    case holdOnly
}

public extension SecretVaultManager {
    /// Recomputed on every call (the underlying state is uncached and may change between keystrokes).
    /// Both inputs it starts from — the user's intent (`secretVaultUseSecretCode`, `secretVaultEnabled`) —
    /// live in the app-group defaults and therefore SURVIVE a restore, so a migrated device lands in
    /// `.holdOnly`, never in `.off`.
    var secretCodeMode: SecretVaultSecretCodeMode {
        let store = SGProtectedStore.shared
        guard SGSimpleSettings.shared.secretVaultUseSecretCode, store.isVaultFeatureEnabled else {
            return .off
        }
        if !store.recovery.intersection(.vaultAny).isEmpty {
            return .holdOnly
        }
        if !store.isMembershipKnown {
            // The shared state cannot be read: revealing (or releasing the text) would be a guess either way.
            return .holdOnly
        }
        switch ChatPincodeManager.shared.vaultCredentialHealth() {
        case .ready:
            return .armed
        case .absent, .unreadable, .unverifiable:
            return .holdOnly
        }
    }

    /// The vault may be opened and changed: it is active AND no vault-side recovery is pending. Every
    /// mutating or revealing entry point (context menu "Add to Vault", the vault list, the reveal gesture)
    /// asks this instead of `isActive`.
    var isOperable: Bool {
        return self.isActive && SGProtectedStore.shared.recovery.intersection(.vaultAny).isEmpty
    }

    /// Audit #74: vault members with no mute record left, but ONLY once the bookkeeping itself is provably
    /// gone — after a restore the records (an app-private, device-only keychain blob) are lost while the chats
    /// stay muted forever on the server. Empty otherwise, because a member with no record is the normal case
    /// for a chat the user had already muted themselves when they vaulted it: nothing was recorded then and
    /// nothing may be unmuted now. The Settings teardown unmutes exactly what this returns, and only while the
    /// chats are still muted forever, so a mute the user set in the meantime is never clobbered either.
    func vaultMembersMissingMuteRecords(accountPeerId: PeerId) -> Set<PeerId> {
        guard self.vaultMuteBookkeepingIsLost(accountPeerId: accountPeerId) else {
            return Set()
        }
        let members = SGProtectedStore.shared.vaultMemberIds(accountPeerId: accountPeerId.toInt64()) ?? []
        guard !members.isEmpty else {
            return Set()
        }
        let recorded = Set((self.vaultMuteRecords()[accountPeerId] ?? [:]).keys.map { $0.toInt64() })
        return Set(members.subtracting(recorded).map { PeerId($0) })
    }
}
