import Foundation
import CryptoKit
import SGChatLock
import SGProtectedStore

/// What the chat-list search may do with the text the user is typing while the secret-code reveal is on.
public enum SecretVaultCodeOutcome: Equatable {
    /// Ordinary search: local AND remote results.
    case search
    /// The text stays on this device: local results only, nothing is sent to Telegram's servers.
    case hold
    /// The text was the vault credential and the vault opened; the query is dropped.
    case revealed
    /// Like `.hold`, but the user asked for a server search and will get none, so the surface owes them a
    /// visible (deliberately neutral) explanation instead of silence — audit batch 4 round 2, defect B.
    case holdExplained
}

/// Zenlygram — the one place where text typed into chat-list search may be checked against the vault
/// credential (audit #27, #73, #89). One instance per search activation; main thread only.
///
/// Three rules shape it, and each of them fixes an audited hole:
///
/// * **#27 — every check is counted, but against the RIGHT budget.** Checks go through
///   `ChatPincodeManager.checkVault(_:countsAsAttempt:)` with `countsAsAttempt: false`, and this gate does the
///   accounting itself against `ChatLockThrottle.vaultSearch` — a scope of its own. Round 1 charged `.vault`,
///   which the PIN screens and the title-gesture reveal are gated by, so for a text-password vault five
///   ordinary queries ("mom", "invoice", …) locked the owner out of their own vault PIN screen and then
///   silently stopped searching altogether. `.vault` is still consulted (a lockout there answers `.throttled`,
///   which is held), it is simply never SPENT from here.
///   A candidate is never checked "for free" and counted later: a full 4-digit code is checked only after it
///   has settled for 0.8 s (so `998901234567` never costs the four attempts its prefixes would), and a text
///   password is checked only when the user submits it. Retyping the same wrong code costs one attempt in
///   total, not one per retype (the per-session memo).
/// * **Checking and billing are separate questions.** Anything that could still BE the credential is compared
///   (so the reveal works for a password of any length), while only credential-SHAPED text is billed: with a
///   learned `vaultCodeLengthHint`, exactly that length; before one exists, `SGVaultCodeLength`'s conservative
///   window. Text with whitespace, or of the wrong length for a `.pin4` vault, is neither compared nor billed —
///   it cannot be the credential, so it is released untouched.
/// * **#89 — nothing the user can see depends on the text.** While the mode is on, EVERY non-empty text is
///   held, digits or not, so the local-only results read the same for `0000` and for `abcd`. Round 2 also took
///   the last visible difference away: the empty-results text no longer branches on the hold at all (see
///   ChatListSearchListPaneNode), so a borrowed phone cannot be asked whether a vault exists.
/// * **#73 — a credential that cannot be checked is never released.** In `.holdOnly` (restored iPhone,
///   pending recovery, unreadable keychain) a candidate-shaped text is held even when the user taps Search:
///   it may be the real PIN, and this is exactly how the PIN used to end up in a server-side search query.
public final class SecretVaultCodeGate {
    /// How long a complete 4-digit candidate must stand still before it is worth an attempt.
    private static let settleDelay: Double = 0.8
    /// Enough to cover any realistic session; past it every candidate counts again (never a free-guess pool).
    private static let memoCapacity = 64

    private let onReveal: () -> Void
    /// Per-instance, never persisted: the memo must not survive the search session, nor be comparable
    /// against anything outside it.
    private let sessionNonce: Data
    private var memo = Set<String>()
    private var settleWorkItem: DispatchWorkItem?
    private var lastText: String?

    public init(onReveal: @escaping () -> Void) {
        self.onReveal = onReveal
        // Swift's default generator is the system CSPRNG on Apple platforms.
        self.sessionNonce = Data((0 ..< 16).map({ _ in UInt8.random(in: UInt8.min ... UInt8.max) }))
        if case .armed = SecretVaultManager.shared.secretCodeMode {
            // Records the restore-surviving shape hint while the metadata is still readable. After a
            // migration the hint is all that tells a 4-digit vault from a text-password one, and without it
            // EVERY query has to be held to stay fail-closed (audit #73).
            _ = ChatPincodeManager.shared.vaultCodeShape()
        }
    }

    deinit {
        self.settleWorkItem?.cancel()
    }

    /// A keystroke. Never releases anything to the server on its own.
    public func textChanged(_ text: String) -> SecretVaultCodeOutcome {
        self.cancelSettle()
        self.lastText = text
        let mode = SecretVaultManager.shared.secretCodeMode
        guard mode != .off, !text.isEmpty else {
            return .search
        }
        // A 4-digit PIN is the only shape that can be recognised while typing. A text password is NOT checked
        // here: doing so would be an uncounted guess on every keystroke (the #27 hole).
        if case .armed = mode,
           SecretVaultCodeGate.isFourDigits(text),
           ChatPincodeManager.shared.vaultCodeShape() == .pin4,
           !self.memo.contains(self.fingerprint(text)) {
            self.scheduleSettle(text)
        }
        // #89: held whatever the text looks like, so the search UI cannot be read as an oracle.
        return .hold
    }

    /// The user explicitly asked to search Telegram (keyboard Search, or the paid-search button). This is the
    /// only path that may release held text — and only once the text is PROVEN not to be the credential.
    public func textSubmitted(_ text: String) -> SecretVaultCodeOutcome {
        self.cancelSettle()
        self.lastText = text
        let mode = SecretVaultManager.shared.secretCodeMode
        guard !text.isEmpty else {
            return .search
        }
        switch mode {
        case .off:
            return .search
        case .armed, .holdOnly:
            break
        }
        // Text that cannot be the credential at all is released without any check. This is also what keeps
        // global search alive in `.holdOnly` (audit batch 4 round 2, defect B): after a migration an ordinary
        // multi-word query is still sent, only a credential-shaped one is withheld.
        let candidacy = self.candidacy(text)
        guard candidacy.checkable else {
            return .search
        }
        guard case .armed = mode else {
            // #73: nothing here can tell the real PIN from an ordinary query, so it stays on this device —
            // and, unlike round 1, the user is told that the search did not happen.
            return .holdExplained
        }
        // The search path's own brute-force budget. It never blocks (nor is blocked by) the vault PIN screen.
        guard ChatLockThrottle.remaining(.vaultSearch) == 0 else {
            return .holdExplained
        }
        let fingerprint = self.fingerprint(text)
        let alreadyCounted = self.memo.contains(fingerprint)
        switch ChatPincodeManager.shared.checkVault(text, countsAsAttempt: false) {
        case .match:
            self.noteCredentialMatched(text)
            self.onReveal()
            return .revealed
        case .mismatch:
            // Proven not to be the credential: searching for it leaks nothing.
            if !alreadyCounted {
                self.memoize(fingerprint)
                if candidacy.chargeable {
                    ChatLockThrottle.registerFailure(.vaultSearch)
                }
            }
            return .search
        case .throttled, .unavailable:
            // Unchecked text is held: releasing it would send a possible credential to the server. `.throttled`
            // means the PIN screens locked `.vault` out; `.unavailable` means the credential cannot be read.
            return .holdExplained
        }
    }

    // MARK: - Settling

    private func cancelSettle() {
        self.settleWorkItem?.cancel()
        self.settleWorkItem = nil
    }

    private func scheduleSettle(_ text: String) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.settleDidFire(text)
        }
        self.settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + SecretVaultCodeGate.settleDelay, execute: workItem)
    }

    private func settleDidFire(_ text: String) {
        self.settleWorkItem = nil
        guard self.lastText == text else {
            return
        }
        let fingerprint = self.fingerprint(text)
        guard !self.memo.contains(fingerprint) else {
            return
        }
        // Audit batch 4 (round 2): the search path spends only `.vaultSearch`. A lockout there refuses the
        // check outright, so this timer can never be the free-guess channel either.
        guard ChatLockThrottle.remaining(.vaultSearch) == 0 else {
            return
        }
        switch ChatPincodeManager.shared.checkVault(text, countsAsAttempt: false) {
        case .match:
            self.noteCredentialMatched(text)
            self.onReveal()
        case .mismatch:
            self.memoize(fingerprint)
            // Only a `.pin4` vault ever schedules a settle, and only for a complete 4-digit code: exactly the
            // shape that is worth one attempt.
            ChatLockThrottle.registerFailure(.vaultSearch)
        case .throttled, .unavailable:
            break
        }
    }

    // MARK: - Candidacy (audit batch 4 round 2)

    /// Two independent questions about one piece of typed text.
    private struct Candidacy {
        /// It could still BE the credential, so it must be compared — never released unchecked (#73).
        let checkable: Bool
        /// …and it looks enough like a credential that a mismatch is worth one `.vaultSearch` attempt.
        /// Ordinary searches fall outside this, which is what stops the owner from throttling themselves.
        let chargeable: Bool
    }

    private func candidacy(_ text: String) -> Candidacy {
        switch ChatPincodeManager.shared.vaultCodeShape() {
        case .pin4:
            // A 4-digit vault: anything else is provably not the credential, and a complete code is always
            // worth an attempt.
            let isCode = SecretVaultCodeGate.isFourDigits(text)
            return Candidacy(checkable: isCode, chargeable: isCode)
        case .text, .unknown:
            // `.unknown` is the post-migration case (metadata unreadable, hint never written), so it must be
            // treated as permissively as `.text`: the credential's length is not known here.
            guard !SecretVaultCodeGate.containsWhitespace(text) else {
                // A credential is never typed with spaces or newlines, so "flight to dubai" is released and
                // costs nothing — the single biggest source of the round-1 false failures.
                return Candidacy(checkable: false, chargeable: false)
            }
            let hint = SGProtectedStore.shared.vaultCodeLengthHint
            let chargeable: Bool
            if hint > SGVaultCodeLength.unknown {
                // Learned from a real match: only that exact length can be the credential, so only it is billed.
                chargeable = text.count == hint
            } else {
                chargeable = text.count >= SGVaultCodeLength.minimumWhenUnknown && text.count <= SGVaultCodeLength.maximumWhenUnknown
            }
            // Checkable regardless of length: a longer password must still be able to open the vault. Those
            // checks are unbilled, but they are also guaranteed mismatches once the length is known, so they
            // are not a guessing channel.
            return Candidacy(checkable: true, chargeable: chargeable)
        }
    }

    /// The credential really matched: remember its (non-secret) length so ordinary queries of any other length
    /// stop being billed, and clear the search-side budget the owner may have spent getting here.
    private func noteCredentialMatched(_ text: String) {
        SGProtectedStore.shared.setVaultCodeLengthHint(text.count)
        ChatLockThrottle.reset(.vaultSearch)
    }

    // MARK: - Per-session memo

    private func fingerprint(_ text: String) -> String {
        var input = self.sessionNonce
        input.append(contentsOf: Array(text.utf8))
        return SHA256.hash(data: input).map({ String(format: "%02x", $0) }).joined()
    }

    private func memoize(_ fingerprint: String) {
        guard self.memo.count < SecretVaultCodeGate.memoCapacity else {
            return
        }
        self.memo.insert(fingerprint)
    }

    private static func isFourDigits(_ text: String) -> Bool {
        guard text.count == 4 else {
            return false
        }
        return text.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 })
    }

    private static func containsWhitespace(_ text: String) -> Bool {
        return text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}
