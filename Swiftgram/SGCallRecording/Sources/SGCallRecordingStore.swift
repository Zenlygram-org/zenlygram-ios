// MARK: Zenlygram — call recording, on-disk store.
//
// WHERE THE FILES LIVE, AND WHY NOT WHERE EVERYTHING ELSE DOES.
//
// The rest of this app keeps its data in the app group container (`group.<bundleId>` /
// `telegram-data`), because five extensions need to reach it: NotificationService, Share,
// SiriIntents, WidgetKit and BroadcastUpload all resolve that same container. That is exactly why
// recordings must NOT go there — anything in the group container is readable by every one of those
// processes. Recordings live in the app's own container instead
// (`Library/Application Support/...`), which no extension can open.
//
// BACKUPS. `Library/Application Support` is inside the iOS backup set: only `Library/Caches` and
// `tmp` are outside it. Without an explicit exclusion the `.ogg` audio AND the sidecar (which
// holds the other party's display name in cleartext) would ride every iCloud and every Finder
// backup onto the user's next device — while the consent screen and the settings footer say in
// three languages that recordings are not backed up. So the directory is marked
// `isExcludedFromBackup`, and the mark is re-asserted on every `ensureDirectory()` and on every
// file this store creates: a directory left by an older build already exists, so an exclusion
// applied only at creation time would never run on an upgrade. The repo does the same thing for the
// account directory at submodules/TelegramCore/Sources/Account/AccountManager.swift:291.
//
// DATA PROTECTION. Nothing else in this repo sets a protection class (zero `FileProtectionType`
// hits across submodules/, Swiftgram/ and Telegram/), so everything inherits the iOS default,
// `completeUntilFirstUserAuthentication`. For recordings that is not good enough:
//
//   * while writing: `.completeUnlessOpen`. It is the only class that lets an already-open
//     descriptor keep working after the screen locks. `.complete` revokes the descriptor roughly
//     ten seconds after lock, which would kill a recording mid-call with no error — a bug that only
//     ever reproduces on a real device with the screen off.
//   * once closed: `.complete`, so a finished recording cannot be read at all while the phone is
//     locked.
//
// The class is set AT CREATION (`createFile(atPath:contents:attributes:)`), never afterwards: a
// file written first and protected later has already existed on disk unprotected.
//
// THE SIDECAR IS CREATED `.completeUnlessOpen` TOO, for the same reason the audio is: it is written
// at `stop()`, and a call very often ends while the device is locked (the user pocketed the phone,
// or Auto-Lock fired on speaker). A class-A create cannot succeed then — the key is gone ten
// seconds after lock — so a `.complete` sidecar would silently fail exactly when it matters, and
// the whole recording would become invisible to `list()` and then be swept as an orphan. Tightening
// to `.complete` happens opportunistically instead, in `tightenProtection()`, on a later pass that
// is unlocked by construction (the user is looking at the recordings list).
//
// NOTHING HERE IS LOGGED. No path, no file name, no duration, no peer reaches SGLogging, NSLog or
// any other sink that can leave the process — the recordings are the single most sensitive artefact
// this app can hold, and the log file is exportable.
//
// A RECORDING CAN NOW LEAVE THE DEVICE. `SGCallRecordingDelivery` sends a finished recording to the
// user's own Telegram Saved Messages — automatically when the setting is on, and on an explicit tap
// either way. That is an ordinary Telegram cloud message: it is stored on Telegram's servers and is
// not end-to-end encrypted, and the consent screen, the setting's description and the privacy
// policy say so in those words. Everything above still holds for what is on THIS device; the one
// thing that changed is that the local copy is deleted once — and only once — the message has been
// acknowledged by the server, which is what `SGCallRecordingSendRecord` below exists to remember
// across a relaunch.

import Foundation
import Darwin
import SwiftSignalKit

/// Who made a recording, as the sidecar this process last wrote for it says.
struct SGCallRecordingWrittenIdentity: Equatable {
    let accountPeerId: Int64?
}

/// One message that carries one audio file of a recording to the user's own Saved Messages.
///
/// A recording made by this build is ONE file and therefore ONE leg. A pre-mix recording is still a
/// PAIR, and mixing it here would mean re-encoding an artefact that cannot be re-made (see
/// `SGCallRecordingMetadata`), so it becomes two legs — two messages — and BOTH have to be
/// acknowledged before either file is removed.
public struct SGCallRecordingSendLeg: Codable, Equatable {
    /// The audio file this leg carries, as a NAME inside the recordings directory rather than a
    /// path. The container's absolute path is not stable across a restore or a device migration,
    /// and a record that survives on disk must not point at a directory that moved.
    public var fileName: String
    /// The correlation id handed to `enqueueMessages`. It is stored in the message's own
    /// `OutgoingMessageInfoAttribute` inside Postbox, so it survives a relaunch with the message
    /// and still identifies the send when the pending-message manager retries it in a later
    /// process. This is what turns an in-memory ack into something this sidecar can wait for.
    public var correlationId: Int64
    /// The LOCAL message id `enqueueMessages` handed back. nil while the message has not been
    /// handed to the pipeline yet (the audio file was unreadable — see `SGCallRecordingDelivery`).
    public var localMessageId: Int32?
    /// The CLOUD message id. Non-nil means the server acknowledged this message: the id moved out
    /// of the local namespace, which is the only event that may delete the audio.
    public var cloudMessageId: Int32?

    public init(fileName: String, correlationId: Int64, localMessageId: Int32? = nil, cloudMessageId: Int32? = nil) {
        self.fileName = fileName
        self.correlationId = correlationId
        self.localMessageId = localMessageId
        self.cloudMessageId = cloudMessageId
    }

    public var isConfirmed: Bool {
        return self.cloudMessageId != nil
    }
}

/// A recording's delivery to Saved Messages, as it is remembered ON DISK.
///
/// It lives in the sidecar rather than in memory because the whole promise of the feature is that
/// the recording is never lost: the app can be killed between the enqueue and the server's
/// acknowledgement, and on the next launch the only thing that knows a send was ever asked for is
/// this record.
public struct SGCallRecordingSendRecord: Codable, Equatable {
    /// The account whose Saved Messages this goes to, as `PeerId.toInt64()`. The messages live in
    /// that account's Postbox, so a record belonging to an account that is no longer signed in is
    /// simply not resumable — and the recording itself is deleted with that account anyway.
    public var accountPeerId: Int64
    public var legs: [SGCallRecordingSendLeg]

    public init(accountPeerId: Int64, legs: [SGCallRecordingSendLeg]) {
        self.accountPeerId = accountPeerId
        self.legs = legs
    }

    /// Every message reached the server. THE ONLY CONDITION UNDER WHICH THE AUDIO MAY BE DELETED.
    public var isConfirmed: Bool {
        return !self.legs.isEmpty && self.legs.allSatisfy { $0.isConfirmed }
    }

    /// Every leg has been handed to the message pipeline. False means at least one is still waiting
    /// to be enqueued (the audio could not be read, i.e. the device was locked).
    public var isEnqueued: Bool {
        return self.legs.allSatisfy { $0.localMessageId != nil || $0.cloudMessageId != nil }
    }
}

/// One recording: the audio of one call plus what the list needs to show.
public struct SGCallRecordingItem: Equatable {
    /// Opaque identifier; also the file-name stem on disk.
    public let id: String
    /// When the recording started (Unix time).
    public let startTimestamp: Double
    /// Seconds of audio actually written.
    public let duration: Double
    /// Display title of the other party, captured when the recording was made. Kept for the list —
    /// and, when the user sends a recording to their own Saved Messages, used in that message's
    /// file name and caption, because a recording nobody can identify later is not worth keeping.
    /// It goes nowhere else.
    public let peerTitle: String
    /// The files this recording is made of, in the order they are summed on playback.
    ///
    /// ONE entry for a recording made by this build: the two directions were mixed at record time,
    /// which is what a person who records a call is asking for. TWO for a recording made before
    /// that — the separate microphone and playout streams — which are still listed, still played
    /// (summed on the fly) and still shared. Never empty: an item with no audio is not returned.
    public let audioPaths: [String]
    /// Sum of every file above.
    public let totalSize: Int64
    /// False when the recording never reached a clean end: the process was killed mid-call, or a
    /// write failed part-way through. What is on disk plays, but it stops early.
    public let isComplete: Bool
    /// The delivery to Saved Messages, if one was ever asked for. Read straight off the sidecar so
    /// the list can say "waiting to send" without a second pass over the directory.
    public let send: SGCallRecordingSendRecord?
    /// The account that made this recording, as `PeerId.toInt64()`, or nil for a version-1 sidecar
    /// that predates the field.
    ///
    /// THIS IS ON THE ITEM BECAUSE THE DESTINATION OF AN UPLOAD IS DECIDED BY IT. `list()` returns
    /// every recording on the device regardless of account, and the recordings screen is reached
    /// from ONE account's settings — so without this the only account a "Send to Saved Messages"
    /// action could name was whichever one the user happened to be looking at, which is how a call
    /// recorded on the work account ended up in the personal account's cloud. The sidecar has
    /// carried the answer since version 2; it simply was not published.
    public let accountPeerId: Int64?
    /// The other party of the call, as `PeerId.toInt64()`, or nil for a sidecar written before
    /// version 5. Never guessed from `peerTitle`: a recording without it has NO known identity, and
    /// `SGCallRecordingPrivacy` treats that as unverifiable whenever any protection is configured.
    ///
    /// Protection (Secret Vault / Chat Lock) is always evaluated against THIS pair — the account
    /// that made the recording and this peer — never the account whose screen happens to be open.
    public let peerId: Int64?

    public init(id: String, startTimestamp: Double, duration: Double, peerTitle: String, audioPaths: [String], totalSize: Int64, isComplete: Bool, send: SGCallRecordingSendRecord?, accountPeerId: Int64?, peerId: Int64? = nil) {
        self.id = id
        self.startTimestamp = startTimestamp
        self.duration = duration
        self.peerTitle = peerTitle
        self.audioPaths = audioPaths
        self.totalSize = totalSize
        self.isComplete = isComplete
        self.send = send
        self.accountPeerId = accountPeerId
        self.peerId = peerId
    }
}

/// What reading one recording off disk found. "Cannot read it right now" is deliberately NOT
/// "it is gone": the sidecar is unreadable while the device is locked, and a caller that treated
/// that as missing would drop a delivery or skip an account removal exactly when it matters.
public enum SGCallRecordingReadState {
    case available(SGCallRecordingItem)
    /// No sidecar, or a readable sidecar with no audio left next to it.
    case missing
    /// The user deleted it; a durable tombstone hides it until its files are gone.
    case deleted
    /// The sidecar (or the account-removal ledger) exists but cannot be OPENED right now — the
    /// device is locked. Temporary: retry after unlock. Never treat as gone.
    case unreadable
    /// The sidecar was read but cannot be decoded: damaged, or written in a format this build does
    /// not know. Not temporary, and its owner and peer are unknown. Never play, export or send it;
    /// the list offers a neutral Delete-only row for it (`managementOnlyRecordingIds()`).
    case corrupt
    /// It belongs to an account whose removal is still pending. Treat as gone: never list, play,
    /// share or send it — it is removed as soon as the removal can be completed.
    case pendingAccountRemoval
}

/// The sidecar written next to the audio. Deliberately tiny and deliberately local.
///
/// Version 2 added `accountPeerId` (so a recording can be removed with the account that made it)
/// and `isComplete` (so a recording interrupted by a crash is still listable and still deletable
/// instead of becoming an invisible orphan). A version-1 sidecar decodes with both nil/absent and
/// is treated as belonging to no account and as complete.
///
/// Version 3 is the one-file recording: `hasMixed` replaces the `hasLocal`/`hasRemote` pair, which
/// only ever described a two-file world. Both of those became OPTIONAL rather than being removed,
/// because **version 2 must keep decoding**. Recordings already on the phone are the one thing here
/// that cannot be re-made, and a migration that stops listing them is data loss dressed up as a
/// version bump — so a v2 sidecar still reads, still resolves to its two files, and still plays,
/// shares and deletes.
///
/// The old pairs are deliberately NOT mixed into single files on read. Doing so would mean
/// decoding and re-encoding through a lossy codec — a second generation of Opus loss on an artefact
/// that cannot be recorded again — as a side effect of opening a settings screen, in a pass that
/// can be interrupted half-way and leave the user with neither the pair nor the mix. And it would
/// buy almost nothing: the player already sums the two, so an old recording already SOUNDS like one
/// conversation. The only thing it does not do is leave the device as a single file, and that is
/// not worth risking the recording itself for.
///
/// Version 4 adds `send`, the Saved Messages delivery record. It describes nothing about the audio
/// layout — a version-4 sidecar is a version-3 recording with a delivery attached — so `isMixed`
/// keeps working unchanged, and a sidecar written by an older build simply decodes with `send` nil,
/// i.e. as a recording nobody ever asked to upload. That is exactly the right default: the
/// recording stays on the device until the user says otherwise.
///
/// Version 5 adds `peerId`, the other party, so Secret Vault / Chat Lock protection can be checked
/// against the actual recorded account and peer. It is additive and optional: every older sidecar
/// decodes with `peerId` nil — an UNKNOWN identity, never one inferred from `peerTitle`.
struct SGCallRecordingMetadata: Codable {
    var version: Int
    var startTimestamp: Double
    var duration: Double
    var peerTitle: String
    /// VERSION 1 AND 2 ONLY: the microphone stream was written. nil in version-3 sidecars.
    var hasLocal: Bool?
    /// VERSION 1 AND 2 ONLY: the playout stream was written. nil in version-3 sidecars.
    var hasRemote: Bool?
    /// The account that made the recording, as `PeerId.toInt64()`. nil in version-1 sidecars.
    var accountPeerId: Int64?
    /// nil in version-1 sidecars, which were only ever written at a clean stop.
    var isComplete: Bool?
    /// VERSION 3: the single mixed stream was written. nil in version-1 and -2 sidecars.
    var hasMixed: Bool?
    /// VERSION 4: the delivery to Saved Messages. nil — and absent from every older sidecar —
    /// whenever nothing was ever queued.
    var send: SGCallRecordingSendRecord?
    /// VERSION 5: the other party, as `PeerId.toInt64()`. nil in every older sidecar.
    var peerId: Int64?

    /// The sidecar this build writes.
    ///
    /// `send` is deliberately NOT a parameter: this is called at start, at every ten-second refresh
    /// and at stop, i.e. only for a recording that is being written, and a recording being written
    /// is never being uploaded. The delivery record is attached later, by `setSendRecord`, which
    /// rewrites the sidecar in place. `peerId` has no default on purpose: a call site that forgot
    /// it would silently write a recording whose protection can never be checked.
    static func mixed(startTimestamp: Double, duration: Double, peerTitle: String, accountPeerId: Int64?, peerId: Int64?, isComplete: Bool) -> SGCallRecordingMetadata {
        return SGCallRecordingMetadata(
            version: 5,
            startTimestamp: startTimestamp,
            duration: duration,
            peerTitle: peerTitle,
            hasLocal: nil,
            hasRemote: nil,
            accountPeerId: accountPeerId,
            isComplete: isComplete,
            hasMixed: true,
            send: nil,
            peerId: peerId
        )
    }

    /// Whether this recording is the single mixed file rather than a pre-mix pair. Falls back to
    /// the version number so a sidecar written by something that bumped the version and forgot the
    /// flag is still read as what it is.
    var isMixed: Bool {
        return self.hasMixed ?? (self.version >= 3)
    }
}

public final class SGCallRecordingStore {
    public static let shared = SGCallRecordingStore()

    private static let directoryName = "zenlygram-call-recordings"

    /// The id of the recording being written right now, if any. Set by `SGCallRecordingSession`
    /// around the life of a session.
    ///
    /// Two things need it. NO DELETE — `delete(id:)` or `deleteAll()` — may unlink the files a live
    /// session still holds open: the descriptors survive the unlink, so the encoder would keep
    /// writing happily into an inode nobody can reach and the user would be told the recording
    /// finished normally. And `tightenProtection()` must not re-class an open file to `.complete`,
    /// which would revoke that descriptor the moment the screen locks.
    private let activeLock = NSLock()
    private var activeRecordingIdValue: String?
    private var deleteActiveWhenFinishedValue: Bool = false
    /// The owner and start time of every sidecar this process wrote, keyed by recording id.
    ///
    /// Only the LIVE recording needs it: its sidecar is `.completeUnlessOpen` and closed between
    /// refreshes, so with the screen locked an account removal cannot read who made it — and
    /// skipping it is how a live recording used to outlive the account that made it. The session
    /// writes the sidecar before it marks the recording active, so this is always populated first.
    private var writtenIdentities: [String: SGCallRecordingWrittenIdentity] = [:]
    /// Accounts removed in this process. No new recording may be started for them until a
    /// reconciliation reports them signed in again — see `canRecord(accountPeerId:)`.
    private var fencedAccountPeerIds = Set<Int64>()
    /// Recordings this process deleted. See `wasPurged(id:)`.
    private var purgedIds = Set<String>()
    private let activeRecordingIdPromise = ValuePromise<String?>(nil, ignoreRepeated: true)

    /// The durable account-removal ledger. See SGCallRecordingAccountLedger.swift.
    let accountLedger = SGCallRecordingAccountLedger()

    private init() {
    }

    var activeRecordingId: String? {
        get {
            self.activeLock.lock()
            let value = self.activeRecordingIdValue
            self.activeLock.unlock()
            return value
        }
        set {
            self.activeLock.lock()
            self.activeRecordingIdValue = newValue
            self.deleteActiveWhenFinishedValue = false
            self.activeLock.unlock()
            self.activeRecordingIdPromise.set(newValue)
        }
    }

    /// The recording being written right now, then every change. The recordings list combines it
    /// so a live row turns into a finished one the moment the call ends, instead of staying
    /// "recording now" (or, before, "0:00 · stops early") until the user happens to reopen it.
    public var activeRecordingIdSignal: Signal<String?, NoError> {
        return self.activeRecordingIdPromise.get()
    }

    func writtenIdentity(id: String) -> SGCallRecordingWrittenIdentity? {
        self.activeLock.lock()
        let value = self.writtenIdentities[id]
        self.activeLock.unlock()
        return value
    }

    func fenceRecording(accountPeerId: Int64) {
        self.activeLock.lock()
        self.fencedAccountPeerIds.insert(accountPeerId)
        self.activeLock.unlock()
    }

    func unfenceRecording(signedInAccountPeerIds: Set<Int64>) {
        self.activeLock.lock()
        self.fencedAccountPeerIds.subtract(signedInAccountPeerIds)
        self.activeLock.unlock()
    }

    func isRecordingFenced(accountPeerId: Int64) -> Bool {
        self.activeLock.lock()
        let value = self.fencedAccountPeerIds.contains(accountPeerId)
        self.activeLock.unlock()
        return value
    }

    /// Whether a delete ran while this recording was being written, and clears the in-memory flag.
    ///
    /// Neither "Delete All Recordings" nor the per-row Delete can unlink a live recording's files —
    /// the encoder holds them open — so both spare them and leave a durable tombstone behind
    /// instead. The session honours it when it finishes: the user asked for the recording to go,
    /// and one that reappeared in the list right after they deleted it would be a worse answer than
    /// deleting it. The tombstone is what makes that survive a kill: it is on disk before the
    /// delete is acknowledged, so a later process finds it even though this flag is gone.
    func consumeDeleteWhenFinished(id: String) -> Bool {
        self.activeLock.lock()
        let flagged = self.deleteActiveWhenFinishedValue && self.activeRecordingIdValue == id
        if flagged {
            self.deleteActiveWhenFinishedValue = false
        }
        self.activeLock.unlock()
        return flagged || self.isDeleted(id: id)
    }

    // MARK: - Tombstones

    /// A recording id is a file-name stem in this directory and nothing else.
    static func isValidRecordingId(_ id: String) -> Bool {
        return !id.isEmpty && !id.contains("/") && id != "." && id != ".." && !id.hasPrefix(".")
    }

    private func tombstoneFilePath(id: String) -> String? {
        guard SGCallRecordingStore.isValidRecordingId(id), let directory = self.directoryPath else {
            return nil
        }
        return (directory as NSString).appendingPathComponent("\(id)\(SGCallRecordingStore.tombstoneSuffix)")
    }

    static let tombstoneSuffix = ".deleted"

    /// Whether the user deleted this recording and its files are not all gone yet. A stat, so it
    /// answers while the device is locked.
    public func isDeleted(id: String) -> Bool {
        guard let path = self.tombstoneFilePath(id: id) else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Persists the tombstone. Empty and carrying no name, so it is created
    /// `completeUntilFirstUserAuthentication`: it must be creatable and visible while the device is
    /// locked, which is exactly when a live recording's call often ends.
    private func writeTombstone(id: String) -> Bool {
        guard self.ensureDirectory() != nil, let path = self.tombstoneFilePath(id: id) else {
            return false
        }
        if FileManager.default.fileExists(atPath: path) {
            return true
        }
        guard FileManager.default.createFile(atPath: path, contents: Data(), attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]) else {
            return false
        }
        self.excludeFromBackup(atPath: path)
        return true
    }

    /// Unlinks every file a recording could have. A tombstone is written FIRST (best effort) and
    /// removed LAST, so a kill part-way leaves the tombstone hiding whatever is left — never a
    /// sidecar carrying the other party's name next to no audio — and the next pass finishes the
    /// job. Returns whether nothing of it is left on disk. Never call for the live recording.
    private func purgeFiles(id: String) -> Bool {
        guard SGCallRecordingStore.isValidRecordingId(id) else {
            return false
        }
        if self.hasRecordingsDirectory {
            let _ = self.writeTombstone(id: id)
        }
        self.activeLock.lock()
        self.purgedIds.insert(id)
        self.activeLock.unlock()
        // The `.meta.json.tmp` of an interrupted atomic rewrite goes too. It holds the same
        // peerTitle and accountPeerId as the real sidecar, so leaving it behind would mean an
        // explicit delete (or a per-account logout) left the other party's name on disk.
        var paths = [self.mixedFilePath(id: id), self.localFilePath(id: id), self.remoteFilePath(id: id), self.metadataFilePath(id: id)]
        if let metadataPath = self.metadataFilePath(id: id) {
            paths.append(metadataPath + ".tmp")
        }
        var allGone = true
        for case let path? in paths where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
            if FileManager.default.fileExists(atPath: path) {
                allGone = false
            }
        }
        guard allGone else {
            return false
        }
        self.activeLock.lock()
        self.writtenIdentities.removeValue(forKey: id)
        self.activeLock.unlock()
        if let tombstone = self.tombstoneFilePath(id: id), FileManager.default.fileExists(atPath: tombstone) {
            try? FileManager.default.removeItem(atPath: tombstone)
            return !FileManager.default.fileExists(atPath: tombstone)
        }
        return true
    }

    /// Whether this process already deleted this recording. A sidecar write for such an id — a
    /// session finalising after a delete landed in the gap between "no longer live" and its final
    /// write — must never bring the sidecar back after the delete was reported done.
    private func wasPurged(id: String) -> Bool {
        self.activeLock.lock()
        let value = self.purgedIds.contains(id)
        self.activeLock.unlock()
        return value
    }

    /// Finishes every delete a previous process (or a session that has since ended) acknowledged
    /// but could not complete. Runs from `list()` and is safe at launch.
    public func completePendingDeletes() {
        guard let directory = self.directoryPath, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }
        let activeId = self.activeRecordingId
        for name in names where name.hasSuffix(SGCallRecordingStore.tombstoneSuffix) {
            let id = String(name.dropLast(SGCallRecordingStore.tombstoneSuffix.count))
            if id == activeId {
                continue
            }
            let _ = self.purgeFiles(id: id)
        }
    }

    /// `<app container>/Library/Application Support/zenlygram-call-recordings`.
    ///
    /// Note the *app's own* container: `NSSearchPathForDirectoriesInDomains` resolves inside the
    /// sandbox of the running process and never touches the shared app group.
    public var directoryPath: String? {
        guard let applicationSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first else {
            return nil
        }
        return (applicationSupport as NSString).appendingPathComponent(SGCallRecordingStore.directoryName)
    }

    /// Marks a path as "do not back this up". Best effort by necessity — there is nothing sensible
    /// to do when it fails — but it is applied at every site that can create something here, so a
    /// single failure is repaired on the next use rather than becoming permanent.
    private func excludeFromBackup(atPath path: String) {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Whether the recordings directory exists at all. A stat; never creates it.
    var hasRecordingsDirectory: Bool {
        guard let path = self.directoryPath else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Creates the directory if needed and returns it. `.completeUnlessOpen` on the directory so a
    /// recording in progress survives the screen locking; the finished files are tightened to
    /// `.complete` individually.
    ///
    /// The backup exclusion is re-asserted on EVERY call, not only on creation: the early return
    /// below means a directory left by a build that predates the exclusion would otherwise never be
    /// fixed.
    @discardableResult
    public func ensureDirectory() -> String? {
        guard let path = self.directoryPath else {
            return nil
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                return nil
            }
            self.excludeFromBackup(atPath: path)
            return path
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUnlessOpen
            ])
        } catch {
            return nil
        }
        self.excludeFromBackup(atPath: path)
        return path
    }

    /// Bytes the volume will hand out for something the user asked for. Used as a pre-flight so a
    /// recording is not started onto a disk that cannot hold it.
    func availableCapacity() -> Int64? {
        guard let path = self.directoryPath ?? NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// Removes audio files that have no sidecar, and sidecars that have no audio, once neither has
    /// been written to for an hour.
    ///
    /// Since version 2 the sidecar is written at START, so an interrupted recording is listable and
    /// deletable rather than orphaned; the audio half of this only reaches files left by a build
    /// that predates that. The mtime of a recording in progress is refreshed on every flush, so an
    /// hour of slack cannot catch a live one — even on a very long call.
    ///
    /// THE SIDECAR HALF EXISTS BECAUSE A LONE SIDECAR IS UNREACHABLE AND NOT EMPTY. `item(id:)`
    /// returns nil when no audio file is left, so such a sidecar never appears in `list()` and has
    /// no row to delete — while it still holds the other party's display name in cleartext, and
    /// `hasAnyFiles()` still counts it, leaving the screen showing an empty list over a file only
    /// "Delete All" could remove. Builds before the live-recording guard in `delete(id:)` could
    /// strand one (delete the recording of a call still in progress, and `stop()` re-created the
    /// sidecar next to audio that was already gone), so this also cleans up after them.
    func sweepOrphans() {
        guard let directory = self.directoryPath else {
            return
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }
        let activeId = self.activeRecordingId
        let metadataIds = Set(names.filter { $0.hasSuffix(".meta.json") }.map { String($0.dropLast(".meta.json".count)) })
        let cutoff = Date().addingTimeInterval(-3600.0)
        var audioIds = Set<String>()
        for name in names {
            if let id = self.audioRecordingId(forFileName: name) {
                audioIds.insert(id)
            }
        }
        for id in metadataIds where !audioIds.contains(id) && id != activeId {
            guard let path = self.metadataFilePath(id: id) else {
                continue
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                continue
            }
            // The same hour of slack the audio gets, and for the same reason: `start()` writes the
            // audio file before the sidecar, and `drain()` refreshes the sidecar every ten seconds,
            // so nothing a live or half-started recording owns can be this old.
            guard let modified = attributes[.modificationDate] as? Date, modified < cutoff else {
                continue
            }
            // A SIDECAR CARRYING AN UNFINISHED DELIVERY IS NEVER WRECKAGE. It is the only thing
            // that knows a message is on its way to Saved Messages and which one it is, so sweeping
            // it would strand that message with nothing left to confirm it. A recording still
            // waiting to send always has its audio too, so this never fires for one.
            //
            // A CONFIRMED record is the opposite case and must NOT be exempt: `delete(id:)` unlinks
            // the audio before the sidecar, so a kill in between — reachable right after
            // `SGCallRecordingDelivery.finish` — leaves a confirmed record with no audio. That is
            // never listed (`item(id:)` returns nil), never advanced, and an exemption on `send !=
            // nil` alone would keep it, and the other party's display name inside it, on disk
            // forever, over a list that cannot show it. Which is precisely what this sweep is for.
            if let send = self.metadata(id: id)?.send, !send.isConfirmed {
                continue
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        for name in names where name.hasSuffix(".meta.json.tmp") {
            // A half-written sidecar from an interrupted atomic rewrite. It is not `.meta.json` and
            // not audio, so no other pass here would ever collect it, and it is never load-bearing:
            // the real sidecar is only replaced once this one is complete.
            let path = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                continue
            }
            guard let modified = attributes[.modificationDate] as? Date, modified < cutoff else {
                continue
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        for name in names {
            // Every audio name, including the single `<id>.ogg` this build writes — a sweep that
            // still only knew the two-file names would leave the new files behind forever.
            guard let id = self.audioRecordingId(forFileName: name) else {
                continue
            }
            if metadataIds.contains(id) || id == activeId {
                continue
            }
            let path = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                continue
            }
            guard let modified = attributes[.modificationDate] as? Date, modified < cutoff else {
                continue
            }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Re-classes every closed file in the directory to `.complete`.
    ///
    /// The sidecar and the audio are created `.completeUnlessOpen` so that writing them works
    /// while the device is locked. This is the pass that tightens them afterwards; it runs from
    /// `list()` and from the start of a new recording, i.e. always with the device unlocked and the
    /// app in the foreground, which is precisely when a class-A write can succeed. Files belonging
    /// to a live recording are skipped: re-classing an OPEN descriptor to `.complete` is what kills
    /// a recording ten seconds after the screen locks.
    func tightenProtection() {
        guard let directory = self.directoryPath else {
            return
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }
        let activeId = self.activeRecordingId
        for name in names {
            if let activeId = activeId, name.hasPrefix(activeId) {
                continue
            }
            guard name.hasSuffix(".ogg") || name.hasSuffix(".meta.json") else {
                continue
            }
            let path = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                continue
            }
            if let current = attributes[.protectionKey] as? FileProtectionType, current == .complete {
                continue
            }
            try? FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.complete
            ], ofItemAtPath: path)
        }
    }

    /// Every suffix this store has ever given an audio file, LONGEST-QUALIFIED FIRST.
    ///
    /// The order is load-bearing: `<id>.local.ogg` also ends in `.ogg`, so matching the bare suffix
    /// first would hand back an "id" of `<id>.local` and orphan a perfectly good pre-mix recording.
    private static let audioSuffixes = [".local.ogg", ".remote.ogg", ".ogg"]

    /// The recording id an audio file in the directory belongs to, or nil if it is not one of ours.
    private func audioRecordingId(forFileName name: String) -> String? {
        for suffix in SGCallRecordingStore.audioSuffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }

    /// The single mixed stream — what a recording made by this build consists of.
    func mixedFilePath(id: String) -> String? {
        guard let directory = self.directoryPath else {
            return nil
        }
        return (directory as NSString).appendingPathComponent("\(id).ogg")
    }

    /// The microphone stream of a recording made before the mix landed. Still read, never written.
    func localFilePath(id: String) -> String? {
        guard let directory = self.directoryPath else {
            return nil
        }
        return (directory as NSString).appendingPathComponent("\(id).local.ogg")
    }

    /// The playout stream of a recording made before the mix landed. Still read, never written.
    func remoteFilePath(id: String) -> String? {
        guard let directory = self.directoryPath else {
            return nil
        }
        return (directory as NSString).appendingPathComponent("\(id).remote.ogg")
    }

    func metadataFilePath(id: String) -> String? {
        guard let directory = self.directoryPath else {
            return nil
        }
        return (directory as NSString).appendingPathComponent("\(id).meta.json")
    }

    /// Creates an empty file with its protection class already applied, and returns its path.
    /// Creating it empty first is what lets `SGOggFileDataItem` simply open it for writing.
    func createProtectedFile(atPath path: String) -> Bool {
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [
            .protectionKey: FileProtectionType.completeUnlessOpen
        ]) else {
            return false
        }
        self.excludeFromBackup(atPath: path)
        return true
    }

    /// Tightens a finished file to `.complete` — unreadable whenever the device is locked. Returns
    /// false when the device is locked, which is why `tightenProtection()` exists.
    @discardableResult
    func sealFile(atPath path: String) -> Bool {
        do {
            try FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.complete
            ], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }

    /// Writes (or rewrites) the sidecar. Returns whether the bytes actually landed — the caller
    /// decides what to tell the user, and every caller here does.
    ///
    /// A DELETED RECORDING IS NEVER WRITTEN AGAIN. The user deleted it while it was live (or a
    /// removed account owned it, or a wipe ran), and the finalize / ten-second refresh of the session
    /// must not rewrite a sidecar that brings it back. While still live this is a no-op; once the
    /// session has let go it completes the delete instead. Either way it reports success, because
    /// the outcome the caller cares about — the recording is in the state the user asked for — holds.
    ///
    /// `protection` is the class the new sidecar is CREATED with, and it is never weakened on a
    /// failure. The session writes `.completeUnlessOpen` (a call often ends with the device locked,
    /// when a class-A create cannot succeed; `tightenProtection()` raises it later). Every rewrite of
    /// a FINISHED recording (`setSendRecord`) writes `.complete`: renaming a weaker file over a
    /// sealed sidecar would silently unseal the other party's name, so while locked it fails and the
    /// caller retries after unlock instead.
    @discardableResult
    func writeMetadata(id: String, metadata: SGCallRecordingMetadata, protection: FileProtectionType = .completeUnlessOpen) -> Bool {
        guard let path = self.metadataFilePath(id: id), SGCallRecordingStore.isValidRecordingId(id) else {
            return false
        }
        if self.isDeleted(id: id) || self.wasPurged(id: id) {
            if !self.isActive(id: id) {
                let _ = self.purgeFiles(id: id)
            }
            return true
        }
        // The FIRST sidecar of a recording is its reservation: refused while a cleanup covers its
        // owner — an account being (or, in this process, already) removed, a pending global wipe, or
        // a ledger that cannot be read — so no capture can start that a cleanup will never see or
        // that a still-pending deferred cleanup would later delete. An ownerless reservation is
        // covered by every removal and every wipe. See `canRecord(accountPeerId:)`.
        if self.writtenIdentity(id: id) == nil, !FileManager.default.fileExists(atPath: path), !self.canReserve(owner: metadata.accountPeerId) {
            return false
        }
        self.activeLock.lock()
        self.writtenIdentities[id] = SGCallRecordingWrittenIdentity(accountPeerId: metadata.accountPeerId)
        self.activeLock.unlock()
        guard let data = try? JSONEncoder().encode(metadata) else {
            return false
        }
        // WRITTEN BESIDE THE REAL SIDECAR AND RENAMED OVER IT — never destroyed first.
        //
        // This used to `removeItem` the old sidecar and then `createFile` the new one, and a failed
        // create left the recording with NO SIDECAR AT ALL: invisible to `list()` (`item(id:)`
        // returns nil without one) and to `pendingSends()`, with its audio unlinked by
        // `sweepOrphans` an hour later. A full disk is exactly the failure a feature that fills the
        // device with call audio invites, and a recording destroyed by a failed bookkeeping write is
        // the one outcome this whole feature exists to prevent.
        //
        // `rename(2)` is atomic within a directory and carries the temp file's data-protection class
        // with it, so what is on disk is always one whole version or the other, and a false return
        // genuinely means "nothing changed".
        let tempPath = path + ".tmp"
        if FileManager.default.fileExists(atPath: tempPath) {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        guard FileManager.default.createFile(atPath: tempPath, contents: data, attributes: [
            .protectionKey: protection
        ]) else {
            try? FileManager.default.removeItem(atPath: tempPath)
            return false
        }
        self.excludeFromBackup(atPath: tempPath)
        guard Darwin.rename(tempPath, path) == 0 else {
            try? FileManager.default.removeItem(atPath: tempPath)
            return false
        }
        self.excludeFromBackup(atPath: path)
        return true
    }

    /// Every recording on this device, newest first. Reads only the sidecars, so it is cheap.
    ///
    /// Also the housekeeping pass, because reaching this code means the app is in the foreground
    /// with the device unlocked — the only state in which a `.complete` re-class can succeed, and
    /// the only moment the user is actually looking at what is stored. Sweeping here as well as at
    /// the start of a recording is what stops a stray file from sitting in the container
    /// indefinitely just because the user never recorded a second call.
    public func list() -> [SGCallRecordingItem] {
        // Finishes deletes the USER already confirmed (tombstones), nothing else. It deliberately does
        // NOT run pending account cleanup: a reconciliation on disk may be older than the accounts
        // signed in now, and this is called from UI and delivery paths that can run before the
        // current account set is known. Account cleanup runs only from the explicit lifecycle hooks
        // (`reconcileAccounts` with the current set, then `retryPendingAccountRemovals`); until then
        // a pending entry only HIDES what it covers and fences new recordings — it deletes nothing.
        self.completePendingDeletes()
        self.sweepOrphans()
        self.tightenProtection()
        guard let directory = self.directoryPath else {
            return []
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var result: [SGCallRecordingItem] = []
        for name in names {
            guard name.hasSuffix(".meta.json") else {
                continue
            }
            let id = String(name.dropLast(".meta.json".count))
            guard case let .available(item) = self.readState(id: id) else {
                continue
            }
            result.append(item)
        }
        result.sort { lhs, rhs in
            if lhs.startTimestamp != rhs.startTimestamp {
                return lhs.startTimestamp > rhs.startTimestamp
            }
            return lhs.id > rhs.id
        }
        return result
    }

    /// Whether anything at all may be on disk, listable or not. The recordings screen uses it to
    /// keep "Delete All" reachable even when `list()` is empty — leftovers from an older build, a
    /// sidecar that cannot be read or decoded, recordings hidden by a pending cleanup, a tombstone
    /// or a half-written temp file, a cleanup ledger that blocks recording — so nothing is ever
    /// stranded with no way to remove it. Settings uses it to keep the recordings screen reachable
    /// while recording itself is unavailable.
    ///
    /// Content-free: a directory listing, never a sidecar read, and it never creates the directory.
    /// ANY entry counts, and a directory that exists but cannot be listed counts as "may have
    /// files" — not knowing is not evidence that it is empty.
    public func hasAnyFiles() -> Bool {
        guard let directory = self.directoryPath else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return true
        }
        return !names.isEmpty
    }

    /// Whether this recording may still exist, WITHOUT requiring its sidecar to be readable.
    ///
    /// `item(id:)` has to READ the sidecar, and the sidecar is `.completeUnlessOpen` — so while the
    /// screen is locked it cannot be opened at all and `item(id:)` returns nil for a recording that is
    /// perfectly intact. A call very often ends with the phone already in a pocket, which is exactly
    /// when the automatic delivery runs, so "cannot read it" must never be mistaken for "it is gone".
    /// False only for what is definitely gone: no sidecar, a tombstone, or a pending cleanup.
    public func exists(id: String) -> Bool {
        switch self.sidecarState(id: id) {
        case .deleted, .missing, .pendingAccountRemoval:
            return false
        case .unreadable, .corrupt, .visible:
            return true
        }
    }

    /// Recordings that exist on disk but cannot be shown as a normal row: a sidecar that is locked,
    /// damaged or in an unknown format, or a recording hidden by a cleanup that has not finished.
    /// Ids only — nothing is read beyond what `readState` reads, and nothing about the call is
    /// published. The list shows each as a NEUTRAL, Delete-only row, so a stuck cleanup can be
    /// resolved one recording at a time, not only by Delete All. The live recording is excluded.
    public func managementOnlyRecordingIds() -> [String] {
        guard let directory = self.directoryPath, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        let activeId = self.activeRecordingId
        var result: [String] = []
        for name in names where name.hasSuffix(".meta.json") {
            let id = String(name.dropLast(".meta.json".count))
            if id == activeId || !SGCallRecordingStore.isValidRecordingId(id) {
                continue
            }
            switch self.readState(id: id) {
            case .unreadable, .corrupt, .pendingAccountRemoval:
                result.append(id)
            case .deleted:
                // A delete whose files could not all be removed yet: Delete retries it.
                result.append(id)
            case .available, .missing:
                break
            }
        }
        return result.sorted(by: >)
    }

    /// Whether this recording is the one being written right now.
    ///
    /// The sidecar is written at START, so a live recording HAS a row on the list — that is
    /// deliberate (see `delete(id:)`, which defers instead of unlinking files the encoder holds
    /// open). Anything that offers an action a live recording cannot perform has to ask this first:
    /// a live file is half-written, so Play and Share must not be offered, and `setSendRecord`
    /// refuses outright while a recording is active.
    public func isActive(id: String) -> Bool {
        return self.activeRecordingId == id
    }

    public func item(id: String) -> SGCallRecordingItem? {
        guard case let .available(item) = self.readState(id: id) else {
            return nil
        }
        return item
    }

    /// What is on disk for this recording, telling "gone" apart from "cannot be read right now".
    public func readState(id: String) -> SGCallRecordingReadState {
        let metadata: SGCallRecordingMetadata
        switch self.sidecarState(id: id) {
        case .deleted:
            return .deleted
        case .missing:
            return .missing
        case .unreadable:
            return .unreadable
        case .corrupt:
            return .corrupt
        case .pendingAccountRemoval:
            return .pendingAccountRemoval
        case let .visible(value):
            metadata = value
        }

        var totalSize: Int64 = 0
        var audioPaths: [String] = []
        func include(_ path: String?) {
            guard let path = path, FileManager.default.fileExists(atPath: path) else {
                return
            }
            audioPaths.append(path)
            totalSize += self.fileSize(atPath: path)
        }
        if metadata.isMixed {
            include(self.mixedFilePath(id: id))
        } else {
            // VERSION 1 AND 2: the pair, in the order the player has always summed them.
            if metadata.hasLocal == true {
                include(self.localFilePath(id: id))
            }
            if metadata.hasRemote == true {
                include(self.remoteFilePath(id: id))
            }
        }
        if audioPaths.isEmpty {
            return .missing
        }
        return .available(SGCallRecordingItem(
            id: id,
            startTimestamp: metadata.startTimestamp,
            duration: metadata.duration,
            peerTitle: metadata.peerTitle,
            audioPaths: audioPaths,
            totalSize: totalSize,
            isComplete: metadata.isComplete ?? true,
            send: metadata.send,
            accountPeerId: metadata.accountPeerId,
            peerId: metadata.peerId
        ))
    }

    private enum SidecarRead {
        case missing
        /// Exists, cannot be opened right now (locked).
        case unreadable
        /// Read, but does not decode.
        case corrupt
        case readable(SGCallRecordingMetadata)
    }

    private enum SidecarState {
        case deleted
        case missing
        case unreadable
        case corrupt
        case pendingAccountRemoval
        case visible(SGCallRecordingMetadata)
    }

    /// The raw sidecar. One that exists but cannot be opened (locked) is `.unreadable`; one whose
    /// bytes were read but do not decode is `.corrupt`. Neither is ever `.missing`.
    private func readSidecar(id: String) -> SidecarRead {
        guard SGCallRecordingStore.isValidRecordingId(id), let path = self.metadataFilePath(id: id) else {
            return .missing
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .missing
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .unreadable
        }
        guard let metadata = try? JSONDecoder().decode(SGCallRecordingMetadata.self, from: data) else {
            return .corrupt
        }
        return .readable(metadata)
    }

    /// The sidecar as every public reader must see it: tombstones and pending cleanups applied.
    /// The single gate in front of `item`, `sendRecord`, `setSendRecord` and `pendingSends`.
    private func sidecarState(id: String) -> SidecarState {
        if self.isDeleted(id: id) {
            return .deleted
        }
        switch self.readSidecar(id: id) {
        case .missing:
            return .missing
        case .unreadable:
            return .unreadable
        case .corrupt:
            // A pending wipe or explicit removal covers an unattributable recording; reconciliation
            // never does (see SGCallRecordingAccountLedgerContents).
            if self.accountLedger.covers(owner: .unknown, directory: self.directoryPath) == true {
                return .pendingAccountRemoval
            }
            return .corrupt
        case let .readable(metadata):
            switch self.accountLedger.covers(owner: .owner(metadata.accountPeerId), directory: self.directoryPath) {
            case .none:
                return .unreadable
            case .some(true):
                return .pendingAccountRemoval
            case .some(false):
                return .visible(metadata)
            }
        }
    }

    /// Calls `body` with the owner evidence of every recording that is not already tombstoned.
    ///
    /// A sidecar that cannot be OPENED is attributed from what this process wrote for it (always
    /// available for the live recording); otherwise the pass is incomplete (returns false) and the
    /// caller retries after unlock. A sidecar that cannot be DECODED, and audio or a temp file left
    /// with no sidecar at all, are `.unknown` — permanent, so they never hold a pass open; the
    /// caller's rule decides whether "unknown" is covered. Also false when the directory exists
    /// but cannot be listed. The live recording is always attributed, never `.unknown`.
    func forEachRecordingOwner(_ body: (_ id: String, _ owner: SGCallRecordingOwnerEvidence) -> Void) -> Bool {
        guard let directory = self.directoryPath, FileManager.default.fileExists(atPath: directory) else {
            return true
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        let activeId = self.activeRecordingId
        var complete = true
        var seen = Set<String>()
        for name in names where name.hasSuffix(".meta.json") {
            let id = String(name.dropLast(".meta.json".count))
            seen.insert(id)
            if self.isDeleted(id: id) || !SGCallRecordingStore.isValidRecordingId(id) {
                continue
            }
            if let written = self.writtenIdentity(id: id), id == activeId {
                body(id, .owner(written.accountPeerId))
                continue
            }
            switch self.readSidecar(id: id) {
            case .missing:
                continue
            case let .readable(metadata):
                body(id, .owner(metadata.accountPeerId))
            case .corrupt:
                if let written = self.writtenIdentity(id: id) {
                    body(id, .owner(written.accountPeerId))
                } else {
                    body(id, .unknown)
                }
            case .unreadable:
                guard let written = self.writtenIdentity(id: id) else {
                    complete = false
                    continue
                }
                body(id, .owner(written.accountPeerId))
            }
        }
        // Files with no sidecar: audio from an older build or a killed start, a temp left by an
        // interrupted rewrite. Not the live recording (its audio exists before its first sidecar),
        // and not one this process is still writing.
        for name in names {
            guard let id = SGCallRecordingStore.recordingId(forAnyFileName: name), !seen.contains(id), SGCallRecordingStore.isValidRecordingId(id) else {
                continue
            }
            seen.insert(id)
            if id == activeId || self.writtenIdentity(id: id) != nil || self.isDeleted(id: id) {
                continue
            }
            body(id, .unknown)
        }
        return complete
    }

    /// The recording id a file in the directory belongs to, for every name this store writes.
    static func recordingId(forAnyFileName name: String) -> String? {
        let suffixes = [".meta.json.tmp", ".meta.json", SGCallRecordingStore.tombstoneSuffix, ".local.ogg", ".remote.ogg", ".ogg"]
        for suffix in suffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }

    // MARK: - Delivery to Saved Messages
    //
    // The record lives in the sidecar, next to the audio it describes, for one reason: the audio
    // may only be deleted once the server has acknowledged the message, and the process can die at
    // any point in between. Anything held only in memory would forget, on the next launch, that a
    // recording was ever queued — and then either the file would sit there forever or, worse, a
    // second copy would be sent.

    /// The delivery record, or nil when this recording was never queued — or is deleted, pending an
    /// account removal, or cannot be read right now (`readState(id:)` tells those apart).
    public func sendRecord(id: String) -> SGCallRecordingSendRecord? {
        guard case let .visible(metadata) = self.sidecarState(id: id) else {
            return nil
        }
        return metadata.send
    }

    /// Attaches, replaces or (with nil) removes the delivery record, rewriting the sidecar.
    ///
    /// Refuses while the recording is still being written: the session rewrites that sidecar every
    /// ten seconds from its own queue, so a write from here would simply be overwritten — and a
    /// recording in progress cannot be uploaded anyway. Returns whether the bytes landed; a caller
    /// that is about to enqueue a message MUST NOT proceed on false, or the send would become
    /// unrecoverable the moment the app is killed.
    @discardableResult
    public func setSendRecord(id: String, _ record: SGCallRecordingSendRecord?) -> Bool {
        if self.activeRecordingId == id {
            return false
        }
        guard case var .visible(metadata) = self.sidecarState(id: id) else {
            return false
        }
        if metadata.send == record {
            return true
        }
        metadata.send = record
        // A finished recording's sidecar is sealed: the rewrite is created `.complete` too, and
        // fails (to be retried after unlock) rather than unseal it.
        return self.writeMetadata(id: id, metadata: metadata, protection: .complete)
    }

    /// Every recording that has a delivery record, without the sweeping and protection-tightening
    /// `list()` does. Used at launch to pick the waiting recordings back up.
    public func pendingSends() -> [(id: String, record: SGCallRecordingSendRecord)] {
        guard let directory = self.directoryPath else {
            return []
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var result: [(id: String, record: SGCallRecordingSendRecord)] = []
        for name in names where name.hasSuffix(".meta.json") {
            let id = String(name.dropLast(".meta.json".count))
            guard case let .visible(metadata) = self.sidecarState(id: id), let record = metadata.send else {
                continue
            }
            result.append((id, record))
        }
        return result
    }

    /// The absolute path of one of a recording's audio files, named the way a delivery leg names
    /// it. Rejects anything that is not a plain name in this directory, so a record carried over
    /// from somewhere else can never make this resolve outside the container.
    public func path(forAudioFileName fileName: String) -> String? {
        guard !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
            return nil
        }
        // The stem must itself be a valid recording id: rejects `.ogg`, `.x.ogg` and the like.
        guard let recordingId = self.audioRecordingId(forFileName: fileName), SGCallRecordingStore.isValidRecordingId(recordingId) else {
            return nil
        }
        guard let directory = self.directoryPath else {
            return nil
        }
        return (directory as NSString).appendingPathComponent(fileName)
    }

    private func metadata(id: String) -> SGCallRecordingMetadata? {
        guard let path = self.metadataFilePath(id: id) else {
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode(SGCallRecordingMetadata.self, from: data)
    }

    private func fileSize(atPath path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return 0
        }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Removes the audio and the sidecar. "Deleting must actually delete." Returns true only when
    /// the delete is guaranteed: nothing of the recording is left, or — for the live recording — a
    /// durable tombstone is on disk. False means the recording is still there and the user must be
    /// told; nothing may report a delete that a relaunch could undo.
    ///
    /// Every name a recording could have is tried, not just the one its sidecar claims: an
    /// unreadable or half-written sidecar must not be the reason a file survives a delete.
    ///
    /// A LIVE RECORDING IS DEFERRED, NOT UNLINKED — the same rule `deleteAll()` follows below, and
    /// for the same reason. The encoder holds the file open, and POSIX keeps that descriptor
    /// working after the unlink, so unlinking here would leave the session writing happily into an
    /// inode nobody can reach: nothing would report an error, the REC indicator and the CallKit
    /// marker would keep promising a recording for the rest of the call, and `stop()` — seeing
    /// bytes written — would re-create the sidecar carrying the other party's name.
    ///
    /// The deferral is a TOMBSTONE ON DISK, written before this returns. It used to be an
    /// in-memory flag only, so a force-quit or jetsam before the call ended brought the deleted
    /// recording back on the next launch, playable and shareable. Now every reader hides a
    /// tombstoned recording at once, `writeMetadata` refuses to rewrite it, the session honours it at
    /// `finalizeStream()` via `consumeDeleteWhenFinished(id:)`, and `completePendingDeletes()` (run by
    /// `list()` and every account pass) finishes it in whichever process gets there first.
    @discardableResult
    public func delete(id: String) -> Bool {
        guard SGCallRecordingStore.isValidRecordingId(id) else {
            return false
        }
        guard self.isActive(id: id) else {
            return self.purgeFiles(id: id)
        }
        guard self.writeTombstone(id: id) else {
            return false
        }
        self.activeLock.lock()
        let stillActive = self.activeRecordingIdValue == id
        if stillActive {
            self.deleteActiveWhenFinishedValue = true
        }
        self.activeLock.unlock()
        if !stillActive {
            // The session let go between the check and the tombstone: nothing holds the files now.
            return self.purgeFiles(id: id)
        }
        return true
    }

    /// Total bytes held by all recordings; used by the settings footer.
    public func totalSize() -> Int64 {
        return self.list().reduce(Int64(0)) { $0 + $1.totalSize }
    }
}
