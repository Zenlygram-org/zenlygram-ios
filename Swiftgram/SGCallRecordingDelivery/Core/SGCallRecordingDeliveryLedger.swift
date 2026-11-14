// MARK: Zenlygram — call recording delivery: the delivery's own durable facts.
//
// WHY A SECOND FILE AT ALL. The recording's sidecar is the source of truth for the INTENT to send,
// and it is `.complete`: unreadable while the device is locked. A call very often ends with the
// phone in a pocket, which is exactly when the server acknowledges the upload. A fact that only fits
// into the sidecar is therefore a fact the delivery LOSES while locked (audit #68), and the
// in-memory stash that stood in for it died with the process (#70).
//
// This ledger holds what the delivery itself learned about each leg, in a file that is readable
// from the first unlock after boot onwards (`completeUntilFirstUserAuthentication` — the same class
// Telegram's own Postbox lives in, so whenever Postbox can be queried this can be read too):
//   * the local message id `enqueueMessages` handed back — the cancellation handle;
//   * the message's `globallyUniqueId` — Postbox re-points it to the cloud id on acknowledgement and
//     keeps that mapping across relaunches, which is the only acknowledgement proof that survives a
//     kill (the correlation map is in memory only) or Telegram's own Retry (audit #69);
//   * the cloud message id, once proven;
//   * that the native upload gate denied the leg's upload (a locked relaunch) and its message
//     failed — so it is re-sent once when proof is back, even after a kill (see
//     SGCallRecordingGateDenialRecovery.swift);
//   * correlation ids of earlier attempts, so their media-cache copies can still be removed (#13).
// Each entry is bound to the Telegram account it was written for: the account's peer id AND its
// local account-record id, so an entry can never be applied to another account database (a later
// login of the same user, or the test environment).
//
// WHAT IT CONTAINS. No peer title, no other party's id, no file name, no path, no timestamp.
// Recordings are keyed by a SHA-256 of their id (whose stem is the call's start time). What is left
// is the user's OWN account peer id and record id, message ids and random 64-bit numbers.
//
// UNREADABLE IS NOT ABSENT. A ledger that cannot be opened right now answers `.unavailable`, never
// "no facts": callers defer. Writes made while the file is unreadable are kept in memory and merged
// into the file on the next successful read — removals included, so a removal never resurrects.

import Foundation
import CryptoKit

/// What the delivery knows about one leg of one ATTEMPT. `correlationId` names the attempt: facts
/// are only ever applied to a sidecar leg carrying the same correlation id, so the facts of a failed
/// attempt can never leak into its retry.
public struct SGCallRecordingDeliveryLegFacts: Codable, Equatable {
    public var legIndex: Int
    public var correlationId: Int64
    public var localMessageId: Int32?
    public var globallyUniqueId: Int64?
    public var cloudMessageId: Int32?
    /// The native upload gate denied this attempt's upload and its message was seen failed (see
    /// `SGCallRecordingGateDenialRecovery`). The only durable provenance for re-sending it once proof
    /// is back; an ordinary failure never sets it.
    public var uploadGateDenied: Bool

    public init(legIndex: Int, correlationId: Int64, localMessageId: Int32? = nil, globallyUniqueId: Int64? = nil, cloudMessageId: Int32? = nil, uploadGateDenied: Bool = false) {
        self.legIndex = legIndex
        self.correlationId = correlationId
        self.localMessageId = localMessageId
        self.globallyUniqueId = globallyUniqueId
        self.cloudMessageId = cloudMessageId
        self.uploadGateDenied = uploadGateDenied
    }

    private enum CodingKeys: String, CodingKey {
        case legIndex, correlationId, localMessageId, globallyUniqueId, cloudMessageId, uploadGateDenied
    }

    /// Same rule as the entry: a field added later is optional on decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.legIndex = try container.decode(Int.self, forKey: .legIndex)
        self.correlationId = try container.decode(Int64.self, forKey: .correlationId)
        self.localMessageId = try container.decodeIfPresent(Int32.self, forKey: .localMessageId)
        self.globallyUniqueId = try container.decodeIfPresent(Int64.self, forKey: .globallyUniqueId)
        self.cloudMessageId = try container.decodeIfPresent(Int32.self, forKey: .cloudMessageId)
        self.uploadGateDenied = try container.decodeIfPresent(Bool.self, forKey: .uploadGateDenied) ?? false
    }
}

public struct SGCallRecordingDeliveryEntry: Codable, Equatable {
    /// The account whose Saved Messages the attempt targets (`PeerId.toInt64()`).
    public var accountPeerId: Int64
    /// `Account.id.int64` of that account's local database when the entry was written. nil only for
    /// an entry reconstructed without a live account. A context whose record id differs is a
    /// different database, and nothing in this entry may be applied to it.
    public var accountRecordId: Int64?
    /// The UI established local authorization for exporting a PROTECTED recording, for this
    /// recording's own account and peer, before the record was written.
    public var exportAuthorized: Bool
    /// Written by the automatic path ("Send to Saved Messages" setting), not a tap.
    public var isAutomatic: Bool
    /// The recording names no account (a version-1 sidecar). The store deletes such recordings on
    /// ANY logout, so their deliveries are retired on any account removal.
    public var isOwnerlessRecording: Bool
    /// The number of legs in the attempt, so a ledger-only view can tell whether every leg is known.
    public var legCount: Int
    public var legs: [SGCallRecordingDeliveryLegFacts]
    /// Correlation ids of earlier attempts. Only used to remove their media-cache copies.
    public var retiredCorrelationIds: [Int64]
    /// The recording is finished, deleted or withdrawn and this entry only waits for its
    /// unacknowledged local messages to be discarded and its media-cache copies removed. Written
    /// BEFORE the caller is told it may unlink the audio, so a kill in between still finishes it.
    public var isRetiring: Bool

    public init(accountPeerId: Int64, accountRecordId: Int64? = nil, exportAuthorized: Bool, isAutomatic: Bool = false, isOwnerlessRecording: Bool = false, legCount: Int, legs: [SGCallRecordingDeliveryLegFacts], retiredCorrelationIds: [Int64] = [], isRetiring: Bool = false) {
        self.accountPeerId = accountPeerId
        self.accountRecordId = accountRecordId
        self.exportAuthorized = exportAuthorized
        self.isAutomatic = isAutomatic
        self.isOwnerlessRecording = isOwnerlessRecording
        self.legCount = legCount
        self.legs = legs
        self.retiredCorrelationIds = retiredCorrelationIds
        self.isRetiring = isRetiring
    }

    private enum CodingKeys: String, CodingKey {
        case accountPeerId, accountRecordId, exportAuthorized, isAutomatic, isOwnerlessRecording, legCount, legs, retiredCorrelationIds, isRetiring
    }

    /// Every field added after the first is optional on decode, so a field added later never turns
    /// an older ledger into "damaged" (which would cost its facts).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountPeerId = try container.decode(Int64.self, forKey: .accountPeerId)
        self.accountRecordId = try container.decodeIfPresent(Int64.self, forKey: .accountRecordId)
        self.exportAuthorized = try container.decodeIfPresent(Bool.self, forKey: .exportAuthorized) ?? false
        self.isAutomatic = try container.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? false
        self.isOwnerlessRecording = try container.decodeIfPresent(Bool.self, forKey: .isOwnerlessRecording) ?? false
        self.legCount = try container.decodeIfPresent(Int.self, forKey: .legCount) ?? 0
        self.legs = try container.decodeIfPresent([SGCallRecordingDeliveryLegFacts].self, forKey: .legs) ?? []
        self.retiredCorrelationIds = try container.decodeIfPresent([Int64].self, forKey: .retiredCorrelationIds) ?? []
        self.isRetiring = try container.decodeIfPresent(Bool.self, forKey: .isRetiring) ?? false
    }

    public func facts(legIndex: Int, correlationId: Int64) -> SGCallRecordingDeliveryLegFacts? {
        return self.legs.first(where: { $0.legIndex == legIndex && $0.correlationId == correlationId })
    }

    /// Local message ids that were enqueued and never acknowledged: the cancellation handles.
    public var unacknowledgedLocalMessageIds: [Int32] {
        return self.legs.compactMap { $0.cloudMessageId == nil ? $0.localMessageId : nil }
    }

    /// Every correlation id whose upload resource may have left a media-cache copy.
    public var allCorrelationIds: [Int64] {
        var result = self.legs.map { $0.correlationId }
        for id in self.retiredCorrelationIds where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    /// Every known `globallyUniqueId`: proof that a cloud message is this delivery's own.
    public var knownGloballyUniqueIds: [Int64] {
        return self.legs.compactMap { $0.globallyUniqueId }
    }

    /// Returns a copy with the facts for (`legIndex`, `correlationId`) replaced by `transform`'s
    /// result. Facts of the same leg index under a DIFFERENT correlation id are dropped: that attempt
    /// is over, and only its correlation id is worth keeping (in `retiredCorrelationIds`).
    public func updatingLeg(legIndex: Int, correlationId: Int64, _ transform: (SGCallRecordingDeliveryLegFacts) -> SGCallRecordingDeliveryLegFacts) -> SGCallRecordingDeliveryEntry {
        var result = self
        var retired = result.retiredCorrelationIds
        var current = SGCallRecordingDeliveryLegFacts(legIndex: legIndex, correlationId: correlationId)
        var legs: [SGCallRecordingDeliveryLegFacts] = []
        for leg in result.legs {
            if leg.legIndex != legIndex {
                legs.append(leg)
            } else if leg.correlationId == correlationId {
                current = leg
            } else if !retired.contains(leg.correlationId) {
                retired.append(leg.correlationId)
            }
        }
        legs.append(transform(current))
        legs.sort(by: { $0.legIndex < $1.legIndex })
        result.legs = legs
        result.retiredCorrelationIds = retired
        return result
    }
}

/// The raw bytes behind the ledger. A protocol so tests can model "exists but unreadable".
public protocol SGCallRecordingDeliveryLedgerStorage: AnyObject {
    func read() -> SGCallRecordingDeliveryLedgerReadResult
    func write(_ data: Data) -> Bool
    /// A content-free flag that must be writable and readable even before the first unlock
    /// (the ledger itself is not). Used for "retire every ownerless delivery once readable".
    func readMarker() -> Bool
    func writeMarker(_ present: Bool) -> Bool
}

public enum SGCallRecordingDeliveryLedgerReadResult {
    /// No ledger has ever been written (or it was removed): there are genuinely no facts.
    case absent
    /// The file exists and cannot be opened right now (data protection before first unlock, I/O).
    case unreadable
    case data(Data)
}

/// Answer to "what does the ledger say about this recording".
public enum SGCallRecordingDeliveryLedgerLookup: Equatable {
    case known(SGCallRecordingDeliveryEntry?)
    /// The file cannot be read and nothing was learned in this process: do not treat as absent.
    case unavailable
}

public final class SGCallRecordingDeliveryLedger {
    private struct FileContents: Codable {
        var version: Int
        var entries: [String: SGCallRecordingDeliveryEntry]
    }

    private static let currentVersion = 1

    private let storage: SGCallRecordingDeliveryLedgerStorage
    /// The entries as last read from disk merged with every change made since. Authoritative only
    /// once `isSynced`.
    private var entries: [String: SGCallRecordingDeliveryEntry] = [:]
    private var isSynced = false
    /// Changes made while the file could not be read, replayed over its contents once it can.
    private var overlay: [String: SGCallRecordingDeliveryEntry] = [:]
    private var removedKeys = Set<String>()
    private var removedAccounts = Set<Int64>()
    /// Last write did not reach disk; retried on the next mutation or `flush()`.
    private var isDirty = false
    /// The ownerless-retirement request when even the marker could not be written.
    private var ownerlessRetirementRequestedInMemory = false

    public init(storage: SGCallRecordingDeliveryLedgerStorage) {
        self.storage = storage
    }

    /// Content-free key for a recording id.
    public static func key(recordingId: String) -> String {
        let digest = SHA256.hash(data: Data(recordingId.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reads

    public func lookup(recordingId: String) -> SGCallRecordingDeliveryLedgerLookup {
        return self.lookup(key: SGCallRecordingDeliveryLedger.key(recordingId: recordingId))
    }

    /// The entry for a key, or `.unavailable` while the file cannot be read.
    public func lookup(key: String) -> SGCallRecordingDeliveryLedgerLookup {
        if self.sync() {
            return .known(self.entries[key])
        }
        if let entry = self.overlay[key] {
            return .known(entry)
        }
        if self.removedKeys.contains(key) {
            return .known(nil)
        }
        return .unavailable
    }

    /// Whether every durable fact about `accountPeerId` is gone from disk. False while the file
    /// cannot be read, or a change has not reached it.
    public func holdsNothing(accountPeerId: Int64) -> Bool {
        guard self.sync(), !self.isDirty else {
            return false
        }
        return !self.entries.values.contains(where: { $0.accountPeerId == accountPeerId })
    }

    /// Every entry, or nil while unreadable.
    public func allEntries() -> [String: SGCallRecordingDeliveryEntry]? {
        guard self.sync() else {
            return nil
        }
        return self.entries
    }

    // MARK: Writes — each returns whether the change is DURABLE (on disk).

    @discardableResult
    public func set(recordingId: String, _ entry: SGCallRecordingDeliveryEntry?) -> Bool {
        return self.setEntry(key: SGCallRecordingDeliveryLedger.key(recordingId: recordingId), entry)
    }

    /// Same as `set(recordingId:)` for an entry known only by its key (from `allEntries()`).
    @discardableResult
    public func set(key: String, _ entry: SGCallRecordingDeliveryEntry?) -> Bool {
        return self.setEntry(key: key, entry)
    }

    /// Applies `transform` to the entry as it truly stands. While the file is unreadable that is only
    /// knowable for an entry written (or removed) in this process; otherwise NOTHING is changed and
    /// false is returned — transforming "nil" there would overwrite facts that are merely unreadable.
    @discardableResult
    public func update(recordingId: String, _ transform: (SGCallRecordingDeliveryEntry?) -> SGCallRecordingDeliveryEntry?) -> Bool {
        let key = SGCallRecordingDeliveryLedger.key(recordingId: recordingId)
        let current: SGCallRecordingDeliveryEntry?
        if self.sync() {
            current = self.entries[key]
        } else if let entry = self.overlay[key] {
            current = entry
        } else if self.removedKeys.contains(key) {
            current = nil
        } else {
            return false
        }
        return self.setEntry(key: key, transform(current))
    }

    /// Drops every entry belonging to `accountPeerId`, including ones only on disk while the file is
    /// unreadable (replayed on the next read). Entries written for the account AFTER this call (a
    /// re-login) survive the replay.
    @discardableResult
    public func removeAll(accountPeerId: Int64) -> Bool {
        self.overlay = self.overlay.filter { $0.value.accountPeerId != accountPeerId }
        if self.sync() {
            self.entries = self.entries.filter { $0.value.accountPeerId != accountPeerId }
            return self.persist()
        }
        self.removedAccounts.insert(accountPeerId)
        return false
    }

    /// Retries a write that did not reach disk.
    @discardableResult
    public func flush() -> Bool {
        guard self.sync() else {
            return false
        }
        if !self.isDirty {
            return true
        }
        return self.persist()
    }

    // MARK: Ownerless-retirement request

    public var isOwnerlessRetirementRequested: Bool {
        return self.ownerlessRetirementRequestedInMemory || self.storage.readMarker()
    }

    /// Records that every ownerless delivery must be retired as soon as the ledger can be read.
    /// Returns whether the request is durable.
    @discardableResult
    public func requestOwnerlessRetirement() -> Bool {
        self.ownerlessRetirementRequestedInMemory = true
        return self.storage.writeMarker(true)
    }

    @discardableResult
    public func clearOwnerlessRetirementRequest() -> Bool {
        guard self.storage.writeMarker(false) else {
            return false
        }
        self.ownerlessRetirementRequestedInMemory = false
        return true
    }

    // MARK: Internals

    private func setEntry(key: String, _ entry: SGCallRecordingDeliveryEntry?) -> Bool {
        if let entry {
            self.overlay[key] = entry
            self.removedKeys.remove(key)
        } else {
            self.overlay.removeValue(forKey: key)
            self.removedKeys.insert(key)
        }
        guard self.sync() else {
            return false
        }
        if let entry {
            self.entries[key] = entry
        } else {
            self.entries.removeValue(forKey: key)
        }
        return self.persist()
    }

    /// Loads the file once and replays every change made while it was unreadable.
    private func sync() -> Bool {
        if self.isSynced {
            return true
        }
        var loaded: [String: SGCallRecordingDeliveryEntry]
        switch self.storage.read() {
        case .unreadable:
            return false
        case .absent:
            loaded = [:]
        case let .data(data):
            if let contents = try? JSONDecoder().decode(FileContents.self, from: data) {
                loaded = contents.entries
            } else {
                // Opened but not decodable: an interrupted write cannot produce this (writes are
                // atomic), so it is damage, and waiting would wait for ever. Its facts are lost —
                // which costs at worst a duplicate send, never a recording (see the delivery).
                loaded = [:]
                self.isDirty = true
            }
        }
        loaded = loaded.filter { !self.removedAccounts.contains($0.value.accountPeerId) && !self.removedKeys.contains($0.key) }
        for (key, entry) in self.overlay {
            loaded[key] = entry
        }
        let replayed = !self.overlay.isEmpty || !self.removedKeys.isEmpty || !self.removedAccounts.isEmpty
        self.entries = loaded
        self.isSynced = true
        self.overlay.removeAll()
        self.removedKeys.removeAll()
        self.removedAccounts.removeAll()
        if replayed || self.isDirty {
            _ = self.persist()
        }
        return true
    }

    private func persist() -> Bool {
        let contents = FileContents(version: SGCallRecordingDeliveryLedger.currentVersion, entries: self.entries)
        guard let data = try? JSONEncoder().encode(contents), self.storage.write(data) else {
            self.isDirty = true
            return false
        }
        self.isDirty = false
        return true
    }
}

/// The file behind the ledger: `<Application Support>/zenlygram-call-recording-delivery/ledger.json`,
/// excluded from backup, `completeUntilFirstUserAuthentication`. A directory of its own so the
/// recordings store's orphan sweep never sees it.
public final class SGCallRecordingDeliveryLedgerFile: SGCallRecordingDeliveryLedgerStorage {
    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func defaultDirectoryURL() -> URL? {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return applicationSupport.appendingPathComponent("zenlygram-call-recording-delivery", isDirectory: true)
    }

    private var fileURL: URL {
        return self.directoryURL.appendingPathComponent("ledger.json", isDirectory: false)
    }

    /// Empty file, no protection class: it must be creatable and visible before the first unlock.
    /// Its existence is the whole content.
    private var markerURL: URL {
        return self.directoryURL.appendingPathComponent("ownerless-retirement.pending", isDirectory: false)
    }

    public func read() -> SGCallRecordingDeliveryLedgerReadResult {
        let path = self.fileURL.path
        // A stat answers whatever the protection class; an open does not.
        if !FileManager.default.fileExists(atPath: path) {
            return .absent
        }
        guard let data = try? Data(contentsOf: self.fileURL) else {
            return .unreadable
        }
        return .data(data)
    }

    public func write(_ data: Data) -> Bool {
        do {
            try self.ensureDirectory()
            try data.write(to: self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    public func readMarker() -> Bool {
        return FileManager.default.fileExists(atPath: self.markerURL.path)
    }

    public func writeMarker(_ present: Bool) -> Bool {
        if present {
            do {
                try self.ensureDirectory()
                try Data().write(to: self.markerURL, options: [.atomic, .noFileProtection])
                return true
            } catch {
                return false
            }
        }
        if !FileManager.default.fileExists(atPath: self.markerURL.path) {
            return true
        }
        return (try? FileManager.default.removeItem(at: self.markerURL)) != nil
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ])
        var directory = self.directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }
}
