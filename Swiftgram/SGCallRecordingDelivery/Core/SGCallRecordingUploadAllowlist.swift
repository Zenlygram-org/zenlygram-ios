// MARK: Zenlygram — call recording delivery: what the native upload gate may let through.
//
// TelegramCore's `OutgoingLocalFileUploadGate` asks, on the pending-message queue and before any
// byte is read, whether one governed upload may run. The answer comes from this snapshot: a plain
// value built ONLY on main by `SGCallRecordingDelivery` after it has re-validated the leg (owner
// account signed in and not removed, same account database, ledger entry not retiring, privacy
// `.open` or `.protected` with a scoped grant). The pending-message queue only reads it — no store,
// file system or main-queue access. Anything not in it is denied.

import Foundation

/// One allowed upload: one leg of one attempt, keyed by its derived resource random id.
public struct SGCallRecordingUploadAllowEntry: Equatable {
    /// `ObjectIdentifier` of the uploading account's Postbox (one database, one incarnation).
    public let postboxIdentity: ObjectIdentifier
    public let accountPeerId: Int64
    /// The leg's own audio file name inside the recordings directory.
    public let fileName: String
    /// The leg's known local message id; nil only while Delivery itself is enqueuing the leg (the id
    /// is not returned yet), when any local id in the account's Saved Messages is accepted for this
    /// fresh, unguessable resource.
    public let localMessageId: Int32?

    public init(postboxIdentity: ObjectIdentifier, accountPeerId: Int64, fileName: String, localMessageId: Int32?) {
        self.postboxIdentity = postboxIdentity
        self.accountPeerId = accountPeerId
        self.fileName = fileName
        self.localMessageId = localMessageId
    }
}

/// The gate's request, as plain values.
public struct SGCallRecordingUploadRequestFacts: Equatable {
    public let postboxIdentity: ObjectIdentifier
    public let accountPeerId: Int64
    public let peerId: Int64
    public let messagePeerId: Int64
    public let messageNamespaceIsLocal: Bool
    public let messageId: Int32
    /// Standardized path of the governed file.
    public let localFilePath: String
    public let resourceRandomId: Int64

    public init(postboxIdentity: ObjectIdentifier, accountPeerId: Int64, peerId: Int64, messagePeerId: Int64, messageNamespaceIsLocal: Bool, messageId: Int32, localFilePath: String, resourceRandomId: Int64) {
        self.postboxIdentity = postboxIdentity
        self.accountPeerId = accountPeerId
        self.peerId = peerId
        self.messagePeerId = messagePeerId
        self.messageNamespaceIsLocal = messageNamespaceIsLocal
        self.messageId = messageId
        self.localFilePath = localFilePath
        self.resourceRandomId = resourceRandomId
    }
}

/// The directory component a governed file must sit directly inside.
public let sgCallRecordingGovernedDirectoryName = "zenlygram-call-recordings"

public struct SGCallRecordingUploadSnapshot: Equatable {
    public var entries: [Int64: SGCallRecordingUploadAllowEntry]

    public init(entries: [Int64: SGCallRecordingUploadAllowEntry] = [:]) {
        self.entries = entries
    }

    /// True only for an upload of exactly an allowed leg: same database and account, into the
    /// account's own Saved Messages, a local message, the leg's own file directly inside the
    /// recordings directory, and the leg's known local id or a newer one within Telegram's Retry
    /// window (Delivery re-binds the leg to it).
    public func allows(_ request: SGCallRecordingUploadRequestFacts) -> Bool {
        guard let entry = self.entries[request.resourceRandomId] else {
            return false
        }
        guard entry.postboxIdentity == request.postboxIdentity, entry.accountPeerId == request.accountPeerId else {
            return false
        }
        guard request.peerId == request.accountPeerId, request.messagePeerId == request.peerId, request.messageNamespaceIsLocal else {
            return false
        }
        let components = (request.localFilePath as NSString).pathComponents
        guard components.count >= 2, components[components.count - 1] == entry.fileName, components[components.count - 2] == sgCallRecordingGovernedDirectoryName else {
            return false
        }
        guard let known = entry.localMessageId else {
            return true
        }
        if request.messageId == known {
            return true
        }
        let distance = Int64(request.messageId) - Int64(known)
        return distance > 0 && distance <= Int64(sgCallRecordingRetryScanWindow)
    }
}
