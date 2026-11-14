// MARK: Zenlygram — call recording: which recordings belong to a protected chat.
//
// A recording carries the other party's voice and, in its sidecar, their display name. A call with a
// Secret Vault contact or a Chat-Locked chat therefore produces exactly the content the rest of the
// app hides behind a PIN — and before version 5 the sidecar did not even say WHO the call was with,
// so nothing could check. This file is the one rule every surface applies (the recordings list, the
// Saved Messages delivery), deliberately free of any dependency on the protection store itself: the
// caller passes the verdict of `SGProtectedStore.protection(peerId:accountPeerId:)` in, so this
// module stays small and the rule is testable on its own.
//
// THE RULE IS FAIL-CLOSED.
//
//   * Protection is evaluated for the ACTUAL recorded pair — the account that made the recording
//     and the peer it was made with — never for the account whose screen happens to be open, and
//     never guessed from the display name.
//   * A recording whose identity is unknown (no account id, no peer id: sidecars older than v5)
//     is `.open` only when no protection is configured at all — then nothing could be hidden. As
//     soon as any is, it is `.unverifiable`: no proof can be established for it, so it is never
//     played, exported or auto-sent; it is shown redacted and can still be deleted.
//   * A verdict of "protection state unreadable" is `.unverifiable` too.

import Foundation

/// The protection verdict for one (peer, account) pair, as the caller's protection store reports it.
/// Map `SGPeerProtection` as: `.none` → `.none`, `.locked`/`.vaulted` → `.protected`,
/// `.unknown` → `.unknown`.
public enum SGCallRecordingPeerProtection: Equatable {
    case none
    case protected
    case unknown
}

public enum SGCallRecordingPrivacy: Equatable {
    /// Identity known (or nothing is protected on this device) and the peer is not protected:
    /// listed with its name, playable, shareable, eligible for automatic delivery.
    case open
    /// Recorded with a Vault / Chat-Locked peer. Listed REDACTED; playing, sharing or sending it
    /// requires the app's existing local authorization for exactly this pair first
    /// (`ChatLockSession.requireUnlock(peerId:accountPeerId:…)`). Never sent automatically.
    case protected(accountPeerId: Int64, peerId: Int64)
    /// Who the call was with cannot be established, or the protection state cannot be read. Listed
    /// redacted and deletable; never played, shared or sent.
    case unverifiable

    /// Whether the recording may leave the device or be played without asking for anything.
    public var isOpen: Bool {
        return self == .open
    }
}

public extension SGCallRecordingItem {
    /// - Parameters:
    ///   - isProtectionConfigured: `SGProtectedStore.shared.isAnyProtectionConfigured`.
    ///   - protection: the verdict for `(peerId, accountPeerId)`.
    func privacy(isProtectionConfigured: Bool, protection: (_ peerId: Int64, _ accountPeerId: Int64) -> SGCallRecordingPeerProtection) -> SGCallRecordingPrivacy {
        guard let accountPeerId = self.accountPeerId, let peerId = self.peerId else {
            return isProtectionConfigured ? .unverifiable : .open
        }
        switch protection(peerId, accountPeerId) {
        case .none:
            return .open
        case .protected:
            return .protected(accountPeerId: accountPeerId, peerId: peerId)
        case .unknown:
            return .unverifiable
        }
    }
}
