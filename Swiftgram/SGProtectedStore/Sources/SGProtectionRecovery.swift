import Foundation

/// Zenlygram — protection states that need the user's help (audit batch 4: #70, #71, #73, #41).
///
/// A bit is set when a credential (or the membership it protects) that the user's INTENT says must exist is
/// definitively gone or cannot be verified any more — the classic case being a restore onto a new iPhone, where
/// every `ThisDeviceOnly` keychain item stays behind. Protection is then never silently downgraded: the feature
/// keeps its "on" state, hidden / locked chats keep being treated as protected where that is still possible, and
/// the surfaces offer a recovery instead of a PIN screen nothing can satisfy.
///
/// Stored as one non-secret Int bitmask in the app-group defaults (`zg.protect.recovery`), so the extensions can
/// read it; only the main app writes.
public struct SGProtectionRecovery: OptionSet, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The vault credential is definitively absent although the vault feature is on.
    public static let vaultCredentialLost = SGProtectionRecovery(rawValue: 1 << 0)
    /// The shared snapshot item is gone too, so the set of hidden chats cannot be restored.
    public static let vaultMembershipLost = SGProtectionRecovery(rawValue: 1 << 1)
    /// A vault record exists but nothing can verify it any more (its salt is gone — audit #41).
    public static let vaultCredentialUnverifiable = SGProtectionRecovery(rawValue: 1 << 2)
    /// Chat Lock credentials are gone while the non-secret mirror still names locked chats.
    public static let chatLockCredentialLost = SGProtectionRecovery(rawValue: 1 << 3)

    /// Any vault-side recovery: the vault must not be operated (opened, mutated, used as a secret code).
    public static let vaultAny: SGProtectionRecovery = [.vaultCredentialLost, .vaultMembershipLost, .vaultCredentialUnverifiable]
    public static let all: SGProtectionRecovery = [.vaultAny, .chatLockCredentialLost]
}

/// Shape of the vault credential, mirrored as a non-secret hint in the app-group defaults so the secret-code
/// search gate can tell "this text cannot be the vault PIN" without reading the keychain (audit #27 / #89).
public enum SGVaultCodeShape: Int {
    case unknown = 0
    /// 4-digit numeric PIN (`ChatLockPasswordType.pin`).
    case pin4 = 1
    /// Alphanumeric password of any length (`ChatLockPasswordType.text`).
    case text = 2
}

/// Audit batch 4 (round 2) — the window the secret-code search gate uses to decide whether a failed check is
/// worth one `.vaultSearch` attempt while `SGProtectedStore.vaultCodeLengthHint` is still unknown.
///
/// It is a BILLING window only: a text outside it is still compared against the credential (so the reveal keeps
/// working for a password of any length), it simply costs nothing when it does not match. That is what stops an
/// owner's ordinary one-word searches from adding up to a lockout, without ever creating an unchecked text.
public enum SGVaultCodeLength {
    /// No length has been observed yet.
    public static let unknown = 0
    /// Shorter than this, a text password is not plausible (and the PIN shape is handled separately).
    public static let minimumWhenUnknown = 4
    /// Longer than this it is far more likely to be a sentence than a credential.
    public static let maximumWhenUnknown = 16
}
