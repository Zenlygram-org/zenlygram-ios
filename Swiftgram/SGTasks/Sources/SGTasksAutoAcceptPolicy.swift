import Foundation
import SGEntitlement

// MARK: - The contact rule (wf15 §5.3, D2): a pure decision per pending invitation
//
// An invitation from a person in the RECIPIENT's own Telegram contacts is accepted by the
// recipient's phone itself; everyone else's waits in Takliflar. The check is local (the app knows
// its contacts; the server never receives them) and only the existing `invitation.respond
// {decision: accept}` leaves the device. Every condition fails closed:
//
//   accept iff permission == .allowed                       the traffic rule
//          && contacts ∋ owner                              the recipient's own Telegram contacts
//          && owner != own id
//          && !blockedSenders ∋ owner                       Tasks `sender.block` (shadow + queued)
//          && telegramBlockedListLoaded                      revision 3: the account's Telegram
//          && !telegramBlocked ∋ owner                        blocked list (plus the senders' cached
//                                                            flag) — a blocked user can still be in
//                                                            Contacts.List; unknown → wait
//          && telegramBlockChecked ∋ owner                   this sender's cached block flag has been
//                                                            read since the invitation is pending: the
//                                                            list is read once per process, so a block
//                                                            made after that is known only from the
//                                                            flag; not read yet → wait (fail closed)
//          && !expired (estimated server clock)
//          && no unresolved entry on the invitation key      one answer at a time
//          && the invitation was never answered by hand
//          && the task was never declined or left by hand   every later epoch waits in Takliflar
//          && automatic attempts < 3                        the initial accept + 2 reseals
//
// `leaveForUser` records nothing anywhere: before Postbox has loaded the contacts, before the
// blocked list has been read once, or before the sender's own block flag has been read, the
// invitation simply waits, and the run after the change accepts it (adding the sender as a contact
// later, or unblocking them, accepts their still-pending invitations). A sender's first invitation
// is therefore not accepted by the cycle whose pull delivered it but by the coordinator's run about
// a second later, once it has subscribed that sender's flag; a sender who already has another
// invitation pending (flag subscribed) is accepted in the delivering cycle.

public enum SGTasksAutoAcceptDecision: Equatable {
    case accept
    case leaveForUser
}

/// The device-local inputs the sync coordinator gathers from the account's Telegram data and hands
/// to the repository (`runAutoAccept`). Nothing here is persisted or sent.
public struct SGTasksAutoAcceptInputs: Equatable {
    /// Raw Telegram user ids of the account's contacts (`Contacts.List`, `.user` peers).
    public var contactTgIds: Set<Int64>
    /// Raw Telegram user ids blocked in Telegram: the account's blocked list plus the pending
    /// senders' cached `IsBlocked` flag.
    public var telegramBlockedIds: Set<Int64>
    /// The blocked list has been read to its end once in this process.
    public var telegramBlockedListLoaded: Bool
    /// Raw Telegram user ids of the pending senders whose cached `IsBlocked` flag the coordinator
    /// has read (its subscription delivered a value for exactly these ids). The blocked list is a
    /// one-time read, so a block made later — in this app or on another device — reaches the policy
    /// only through that flag: a sender outside this set is never accepted automatically.
    public var telegramBlockCheckedSenderIds: Set<Int64>

    public init(contactTgIds: Set<Int64>, telegramBlockedIds: Set<Int64>, telegramBlockedListLoaded: Bool, telegramBlockCheckedSenderIds: Set<Int64>) {
        self.contactTgIds = contactTgIds
        self.telegramBlockedIds = telegramBlockedIds
        self.telegramBlockedListLoaded = telegramBlockedListLoaded
        self.telegramBlockCheckedSenderIds = telegramBlockCheckedSenderIds
    }
}

public enum SGTasksAutoAcceptPolicy {
    /// The initial automatic accept and two reseals after `revision_changed`.
    public static let maximumAttempts = 3

    public struct Context {
        public var permission: SGTasksSyncPermission
        public var contactTgIds: Set<Int64>
        public var ownTelegramId: SGTasksWire.TelegramId?
        /// Tasks-level shadow blocks (`sender.block`, acknowledged or queued).
        public var blockedSenderIds: Set<SGTasksWire.TelegramId>
        public var telegramBlockedListLoaded: Bool
        public var telegramBlockedIds: Set<Int64>
        /// The senders whose cached Telegram block flag has been read (`SGTasksAutoAcceptInputs`).
        public var telegramBlockCheckedSenderIds: Set<Int64>
        /// `SGTasksCloudState.estimatedServerNow`; nil before any server answer (never expired).
        public var estimatedServerNow: Date?
        /// An unresolved outbox entry carries this key (`SGTasksCloudKey.invitation`).
        public var hasUnresolvedEntry: (String) -> Bool
        public var manualAnswers: SGTasksInviteAnswers
        /// Automatic accepts already made for an invitation id (store meta `auto_accept.<id>`).
        public var automaticAttempts: [SGTasksWire.UUID: Int]

        public init(permission: SGTasksSyncPermission, contactTgIds: Set<Int64>, ownTelegramId: SGTasksWire.TelegramId?, blockedSenderIds: Set<SGTasksWire.TelegramId>, telegramBlockedListLoaded: Bool, telegramBlockedIds: Set<Int64>, telegramBlockCheckedSenderIds: Set<Int64>, estimatedServerNow: Date?, hasUnresolvedEntry: @escaping (String) -> Bool, manualAnswers: SGTasksInviteAnswers, automaticAttempts: [SGTasksWire.UUID: Int]) {
            self.permission = permission
            self.contactTgIds = contactTgIds
            self.ownTelegramId = ownTelegramId
            self.blockedSenderIds = blockedSenderIds
            self.telegramBlockedListLoaded = telegramBlockedListLoaded
            self.telegramBlockedIds = telegramBlockedIds
            self.telegramBlockCheckedSenderIds = telegramBlockCheckedSenderIds
            self.estimatedServerNow = estimatedServerNow
            self.hasUnresolvedEntry = hasUnresolvedEntry
            self.manualAnswers = manualAnswers
            self.automaticAttempts = automaticAttempts
        }
    }

    public static func decide(_ invitation: SGTasksWire.Invitation, context: Context) -> SGTasksAutoAcceptDecision {
        let owner = invitation.ownerTgId
        guard context.permission == .allowed else { return .leaveForUser }
        guard context.contactTgIds.contains(owner.int64Value) else { return .leaveForUser }
        if let own = context.ownTelegramId, own == owner { return .leaveForUser }
        guard !context.blockedSenderIds.contains(owner) else { return .leaveForUser }
        guard context.telegramBlockedListLoaded, !context.telegramBlockedIds.contains(owner.int64Value) else { return .leaveForUser }
        guard context.telegramBlockCheckedSenderIds.contains(owner.int64Value) else { return .leaveForUser }
        if let serverNow = context.estimatedServerNow, serverNow >= invitation.expiresAt.date { return .leaveForUser }
        guard !context.hasUnresolvedEntry(SGTasksCloudKey.invitation(invitation.id)) else { return .leaveForUser }
        guard !context.manualAnswers.answered(invitationId: invitation.id) else { return .leaveForUser }
        guard !context.manualAnswers.refused(taskId: invitation.taskId) else { return .leaveForUser }
        guard context.automaticAttempts[invitation.id, default: 0] < Self.maximumAttempts else { return .leaveForUser }
        return .accept
    }
}
