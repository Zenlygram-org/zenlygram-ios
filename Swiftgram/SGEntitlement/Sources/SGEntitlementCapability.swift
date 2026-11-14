import Foundation

/// Zenlygram — the capability strings the entitlement server emits (`config/zenlypay.php:56-61`).
///
/// The server sends a LIST of strings, not a bitmask, so the set of features a subscription grants
/// can change without a new binary — within what this build accepts: `refusedByThisBuild` filters
/// out, centrally, every capability the shipped privacy disclosure does not cover. Unknown strings
/// are ignored.
public enum SGEntitlementCapability: String, CaseIterable, Hashable {
    case vault = "vault"
    case chatLock = "chatlock"
    case tasks = "tasks"
    /// Edit History: CAPTURING new records — keeping a copy of a message someone else deleted and
    /// the previous version of one they edited (`SGEntitlementGatedAction.createRetainedHistoryRecord`).
    /// What was already retained is read and removed with no gate, in every mode. The server's
    /// capability list does not change for this.
    case editHistory = "edithistory"
    /// AI Assistant. Refused by this build (`refusedByThisBuild`): it ships only in a release that
    /// removes `.ai` from that set, never by the server alone.
    case ai = "ai"

    /// The operator escape hatch: `ent: ["*"]` grants everything, including strings this build has
    /// never heard of. A client that does not implement it makes the hatch inert for exactly the
    /// population it exists to rescue.
    public static let wildcard = "*"

    /// What `storeKitFallback()` and the local grace grant: the four shipped features, never `"*"`,
    /// never `.ai`. They grant what the product sells, not what the server might later add.
    public static let base: Set<SGEntitlementCapability> = [.vault, .chatLock, .tasks, .editHistory]

    /// Capabilities this BUILD refuses no matter what the server says.
    ///
    /// `ai` is here because enabling the AI Assistant changes what LEAVES the device — message
    /// text goes to a third-party model — while the App Privacy answers, the privacy policy and
    /// the store metadata all describe an app that does not do that. If a capability string
    /// arriving from the server could switch that on, those documents would become false on
    /// already-installed binaries, with no release and no review. Apple requires the shipped app's
    /// disclosure to be accurate, and a remotely flippable data-collection switch cannot satisfy
    /// that.
    ///
    /// Removing `ai` from this set is therefore the release in which the privacy documents are
    /// updated — not a server-side toggle. Until then the server may carry `ai` harmlessly: it is
    /// filtered out here, centrally, so no call site can forget the rule. See appstore/CHECKLIST.md.
    public static let refusedByThisBuild: Set<SGEntitlementCapability> = [.ai]


    /// Does this capability's DATA live per install rather than per Telegram account?
    ///
    /// The entitlement is per account — one binding, one refresh token, one JWS each — but three of
    /// the four features are not: `TodoDatabase` is one SQLite file per install, `ChatPincodeManager`
    /// keys pincodes by peer id alone, and Edit History's capture gate is ONE app-group flag that
    /// every account's Postbox replay reads (`SGSimpleSettings.editHistoryCaptureBlocked`). Gating
    /// those on whichever account happens to be in front would paywall the task list that ANOTHER
    /// account paid for, and would stop capturing in the paying account's own chats the moment the
    /// account switcher lands on an unlinked account — so their gate is evaluated over every linked
    /// account on the install (`SGEntitlement.deviceWideHas`).
    ///
    /// Only the Secret Vault is genuinely account-scoped (`SecretVaultManager.shouldHide(_:
    /// accountPeerId:)`), and the AI Assistant follows the account whose subscription describes it.
    public var isDeviceGlobal: Bool {
        switch self {
        case .chatLock, .tasks, .editHistory:
            return true
        case .vault, .ai:
            return false
        }
    }
}

/// Zenlygram — the ONLY actions a subscription gates.
///
/// **Every case here CREATES new material.** There is no read case, no open case, no unhide case,
/// no unlock case and no delete case, and there must never be one: the owner's lapse policy is that
/// existing data stays fully accessible forever, and invariant I1 says the server is never on the
/// path to the user's own data. A gate placed on a read locks a paying — or lapsed — user out of
/// their own chats, which is the single worst failure this module can have.
///
/// The counterpart is `SGEntitlementUnrestrictedAction` — reads, un-hides, unlocks and deletes of
/// existing material. Always `true`. Getting the two backwards therefore fails in the permissive
/// direction (invariant I2), and asking the wrong question at all requires misspelling a case name
/// from a different enum.
public enum SGEntitlementGatedAction: String, CaseIterable, Hashable {
    /// Adding a NEW chat to the Secret Vault (`SGSecretVault`).
    case createVaultEntry
    /// Setting a pincode on a chat that does not have one yet (`SGChatLock`).
    case createChatLockPincode
    /// Creating a NEW task (`SGTasks`).
    case createTask
    /// Recording a NEW retained-history record: keeping a message someone else deleted, or the
    /// previous version of one they edited (`SGMessageRetention`, monetization policy
    /// `saved_history`). Records already retained stay readable and removable in every mode,
    /// including paid mode without a grant — no gate exists for them. A lapse only stops new capture;
    /// it never erases or hides what was kept. The user's own toggles and the privacy exclusions
    /// still decide first. The Postbox replay reads this decision through the app-group flag
    /// (`SGEntitlementRetainedHistoryCapture`), since TelegramCore cannot link this module.
    case createRetainedHistoryRecord
    /// Anything in `SGAIAssistant`. The feature holds no pre-existing user data, so the whole
    /// feature is gated rather than only its create path.
    case useAIAssistant

    public var capability: SGEntitlementCapability {
        switch self {
        case .createVaultEntry:
            return .vault
        case .createChatLockPincode:
            return .chatLock
        case .createTask:
            return .tasks
        case .createRetainedHistoryRecord:
            return .editHistory
        case .useAIAssistant:
            return .ai
        }
    }
}

/// Zenlygram — actions that must NEVER consult the entitlement.
///
/// `SGEntitlement.can(_:)` answers `true` for every case, unconditionally, offline, forever, with no
/// token at all and with the server unreachable. The enum exists so that a caller reaching for a
/// gate on a read path finds a name that compiles *and* documents why there is nothing to check —
/// rather than reaching for `SGEntitlementGatedAction` and inventing one.
///
/// Chat Lock's preview hiding is in this list on purpose: it is a PRIVACY setting, not a billing
/// one, and a lapse must never re-expose a preview the user chose to hide (design §4.7).
///
/// Reading and removing retained message history (kept-deleted messages, previous versions of an
/// edited message) needs no case here either: nothing consults the entitlement on that path at all.
public enum SGEntitlementUnrestrictedAction: String, CaseIterable, Hashable {
    case openVault
    case listVaultEntries
    case readVaultedChat
    /// Un-hiding a chat. A lapse never un-hides anything, and the user may always undo it themselves.
    case removeVaultEntry
    case unlockChatWithPincode
    /// Removing a pincode. A lapse never un-locks anything, and the user may always undo it themselves.
    case removeChatLockPincode
    /// Hiding message previews in the chat list and in the Notification Service Extension.
    case hideLockedChatPreview
    case readTask
    case editTask
    case completeTask
    case deleteTask
}
