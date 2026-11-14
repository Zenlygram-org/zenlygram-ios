import XCTest

@testable import SGCallRecording

/// Zenlygram — the on-disk store's privacy and lifecycle rules: version-compatible sidecars,
/// "locked is not damaged is not missing", durable delete tombstones, durable account removal and
/// global wipe (including a ledger that cannot be written, and what a later process reads back),
/// the recording fence, and the list's privacy / row policy. Driven against the test process's own
/// Application Support directory; sidecars are written by hand in the exact JSON shapes older and
/// current builds write. A "locked" sidecar is simulated with POSIX permissions (the simulator does
/// not enforce data protection), which produces the same "exists but cannot be opened" read.
final class SGCallRecordingStoreTests: XCTestCase {
    private static let accountA: Int64 = 7_100_000_001
    private static let accountB: Int64 = 7_100_000_002

    private var createdIds: [String] = []
    private var lockedPaths: [String] = []

    private var store: SGCallRecordingStore {
        return SGCallRecordingStore.shared
    }

    override func tearDown() {
        for path in self.lockedPaths {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
        self.lockedPaths = []
        if let directory = self.store.directoryPath {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        }
        self.store.activeRecordingId = nil
        for id in self.createdIds {
            self.removeRaw(id: id)
        }
        self.createdIds = []
        let _ = self.store.retryPendingAccountRemovals()
        let _ = self.store.reconcileAccounts(signedInAccountPeerIds: [SGCallRecordingStoreTests.accountA, SGCallRecordingStoreTests.accountB])
        super.tearDown()
    }

    // MARK: - Fixtures

    private func directory() throws -> String {
        return try XCTUnwrap(self.store.ensureDirectory())
    }

    private func newId() -> String {
        let id = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        self.createdIds.append(id)
        return id
    }

    /// Writes `<id>.ogg` plus a sidecar. Keys that are nil are omitted from the JSON entirely, exactly
    /// like a sidecar from a build that predates them.
    @discardableResult
    private func makeRecording(owner: Int64?, peerId: Int64?, version: Int = 5) throws -> String {
        let directory = try self.directory()
        let id = self.newId()
        var json: [String: Any] = [
            "version": version,
            "startTimestamp": Date().timeIntervalSince1970 - 60.0,
            "duration": 12.0,
            "peerTitle": "Fixture",
            "isComplete": true,
            "hasMixed": true
        ]
        if let owner = owner {
            json["accountPeerId"] = owner
        }
        if let peerId = peerId {
            json["peerId"] = peerId
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertTrue(FileManager.default.createFile(atPath: (directory as NSString).appendingPathComponent("\(id).meta.json"), contents: data))
        XCTAssertTrue(FileManager.default.createFile(atPath: (directory as NSString).appendingPathComponent("\(id).ogg"), contents: Data(repeating: 0x4f, count: 64)))
        return id
    }

    private func makeCorruptRecording() throws -> String {
        let directory = try self.directory()
        let id = self.newId()
        XCTAssertTrue(FileManager.default.createFile(atPath: (directory as NSString).appendingPathComponent("\(id).meta.json"), contents: Data("{".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: (directory as NSString).appendingPathComponent("\(id).ogg"), contents: Data(repeating: 0x4f, count: 64)))
        return id
    }

    /// A recording whose sidecar exists but cannot be opened — what a locked device looks like.
    private func makeLockedRecording(owner: Int64?) throws -> String {
        let id = try self.makeRecording(owner: owner, peerId: 9)
        let path = try self.path(id, ".meta.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        self.lockedPaths.append(path)
        return id
    }

    private func unlock(_ id: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: try self.path(id, ".meta.json"))
    }

    private func path(_ id: String, _ suffix: String) throws -> String {
        return (try self.directory() as NSString).appendingPathComponent("\(id)\(suffix)")
    }

    private func removeRaw(id: String) {
        guard let directory = self.store.directoryPath else {
            return
        }
        for suffix in [".ogg", ".meta.json", ".meta.json.tmp", ".deleted"] {
            try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent("\(id)\(suffix)"))
        }
    }

    private func isAvailable(_ id: String) -> Bool {
        if case .available = self.store.readState(id: id) {
            return true
        }
        return false
    }

    private func liveMetadata(owner: Int64?) -> SGCallRecordingMetadata {
        return SGCallRecordingMetadata.mixed(startTimestamp: Date().timeIntervalSince1970, duration: 1.0, peerTitle: "Live", accountPeerId: owner, peerId: 77, isComplete: false)
    }

    // MARK: - Sidecar compatibility

    func testVersion4SidecarDecodesWithUnknownPeer() throws {
        let id = try self.makeRecording(owner: SGCallRecordingStoreTests.accountA, peerId: nil, version: 4)
        let item = try XCTUnwrap(self.store.item(id: id))
        XCTAssertEqual(item.accountPeerId, SGCallRecordingStoreTests.accountA)
        XCTAssertNil(item.peerId, "an old sidecar has no identity, and none may be invented")
    }

    func testVersion5SidecarCarriesPeer() throws {
        let id = try self.makeRecording(owner: SGCallRecordingStoreTests.accountA, peerId: 42)
        XCTAssertEqual(self.store.item(id: id)?.peerId, 42)
    }

    // MARK: - Locked, damaged and missing are three different things

    func testLockedSidecarIsUnreadableNotMissing() throws {
        let id = try self.makeLockedRecording(owner: SGCallRecordingStoreTests.accountA)
        guard case .unreadable = self.store.readState(id: id) else {
            return XCTFail("a sidecar that exists but cannot be opened must read as unreadable")
        }
        XCTAssertTrue(self.store.exists(id: id), "delivery must not treat a locked recording as gone")
        XCTAssertNil(self.store.item(id: id))
        XCTAssertTrue(self.store.managementOnlyRecordingIds().contains(id))
    }

    func testDamagedSidecarIsCorruptGetsANeutralRowAndIsDeletable() throws {
        let id = try self.makeCorruptRecording()
        guard case .corrupt = self.store.readState(id: id) else {
            return XCTFail("a sidecar that was read but does not decode must read as corrupt")
        }
        XCTAssertTrue(self.store.exists(id: id))
        XCTAssertNil(self.store.item(id: id))
        XCTAssertNil(self.store.sendRecord(id: id))
        XCTAssertFalse(self.store.list().contains { $0.id == id })
        XCTAssertTrue(self.store.managementOnlyRecordingIds().contains(id), "it must be removable one by one, not only by Delete All")
        XCTAssertTrue(self.store.hasAnyFiles())

        XCTAssertTrue(self.store.delete(id: id))
        guard case .missing = self.store.readState(id: id) else {
            return XCTFail("deleted recording must be gone")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try self.path(id, ".ogg")))
        XCTAssertFalse(self.store.managementOnlyRecordingIds().contains(id))
    }

    // MARK: - Durable delete

    func testTombstoneLeftByKilledLiveDeleteHidesAndIsCompletedOnNextList() throws {
        // A process deleted this recording while its call was live and was killed before the call
        // ended: the tombstone is on disk, the sidecar and audio are still there.
        let id = try self.makeRecording(owner: SGCallRecordingStoreTests.accountA, peerId: 42)
        XCTAssertTrue(FileManager.default.createFile(atPath: try self.path(id, ".deleted"), contents: Data()))

        XCTAssertTrue(self.store.isDeleted(id: id))
        guard case .deleted = self.store.readState(id: id) else {
            return XCTFail("a tombstoned recording must read as deleted")
        }
        XCTAssertFalse(self.store.exists(id: id), "delivery must treat a tombstoned recording as gone")
        XCTAssertNil(self.store.item(id: id))
        XCTAssertFalse(self.store.setSendRecord(id: id, SGCallRecordingSendRecord(accountPeerId: SGCallRecordingStoreTests.accountA, legs: [])))
        XCTAssertFalse(self.store.pendingSends().contains { $0.id == id })

        XCTAssertFalse(self.store.list().contains { $0.id == id }, "a relaunch must not resurrect it")
        for suffix in [".ogg", ".meta.json", ".deleted"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: try self.path(id, suffix)), "\(suffix) must be purged once nothing holds it")
        }
    }

    func testLiveDeleteIsTombstonedAndNoLaterWriteResurrectsIt() throws {
        let live = try self.makeRecording(owner: SGCallRecordingStoreTests.accountA, peerId: 1)
        self.store.activeRecordingId = live

        XCTAssertTrue(self.store.delete(id: live), "a live delete is acknowledged once the tombstone is on disk")
        XCTAssertTrue(self.store.isDeleted(id: live))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try self.path(live, ".ogg")), "the open file is not unlinked under the encoder")
        XCTAssertTrue(self.store.writeMetadata(id: live, metadata: self.liveMetadata(owner: SGCallRecordingStoreTests.accountA)), "the ten-second refresh is a harmless no-op")
        XCTAssertTrue(self.store.consumeDeleteWhenFinished(id: live))

        self.store.activeRecordingId = nil
        XCTAssertTrue(self.store.delete(id: live))
        // A final write that lands after the delete was reported done must not bring the sidecar back.
        XCTAssertTrue(self.store.writeMetadata(id: live, metadata: self.liveMetadata(owner: SGCallRecordingStoreTests.accountA)))
        for suffix in [".ogg", ".meta.json", ".deleted"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: try self.path(live, suffix)))
        }
    }

    // MARK: - Account removal

    func testAccountRemovalDeletesOwnedOwnerlessAndDamagedKeepsOtherAccounts() throws {
        let ownedByA = try self.makeRecording(owner: SGCallRecordingStoreTests.accountA, peerId: 1)
        let ownedByB = try self.makeRecording(owner: SGCallRecordingStoreTests.accountB, peerId: 2)
        let ownerless = try self.makeRecording(owner: nil, peerId: nil, version: 1)
        let damaged = try self.makeCorruptRecording()

        let ids = try XCTUnwrap(self.store.recordingIds(ownedBy: SGCallRecordingStoreTests.accountA))
        XCTAssertEqual(Set(ids), Set([ownedByA, ownerless, damaged]))
        XCTAssertEqual(self.store.deleteAll(accountPeerId: SGCallRecordingStoreTests.accountA), .completed)

        XCTAssertFalse(self.store.exists(id: ownedByA))
        XCTAssertFalse(self.store.exists(id: ownerless))
        XCTAssertFalse(self.store.exists(id: damaged))
        XCTAssertTrue(self.isAvailable(ownedByB))
    }

    func testRemovedAccountIsFencedUntilReconciledAsSignedIn() throws {
        try self.makeRecording(owner: SGCallRecordingStoreTests.accountB, peerId: 2)
        XCTAssertTrue(self.store.canRecord(accountPeerId: SGCallRecordingStoreTests.accountA))
        XCTAssertEqual(self.store.deleteAll(accountPeerId: SGCallRecordingStoreTests.accountA), .completed)
        XCTAssertFalse(self.store.canRecord(accountPeerId: SGCallRecordingStoreTests.accountA), "an outliving call object of a removed account must not start a capture")
        XCTAssertTrue(self.store.canRecord(accountPeerId: SGCallRecordingStoreTests.accountB))

        let refused = self.newId()
        XCTAssertFalse(self.store.writeMetadata(id: refused, metadata: self.liveMetadata(owner: SGCallRecordingStoreTests.accountA)), "the first sidecar is the reservation, and it is refused too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try self.path(refused, ".meta.json")))

        XCTAssertEqual(self.store.reconcileAccounts(signedInAccountPeerIds: [SGCallRecordingStoreTests.accountA, SGCallRecordingStoreTests.accountB]), .completed)
        XCTAssertTrue(self.store.canRecord(accountPeerId: SGCallRecordingStoreTests.accountA), "re-login lifts the fence")
    }

    func testLockedSidecarDefersRemovalDurablyAndBlocksNewRecordingsUntilRetryCompletes() throws {
        let readableOfA = try self.makeRecording(owner: SGCallRecordingStoreTests.accountA, peerId: 1)
        let locked = try self.makeLockedRecording(owner: SGCallRecordingStoreTests.accountA)
        let directory = try self.directory()

        XCTAssertNil(self.store.recordingIds(ownedBy: SGCallRecordingStoreTests.accountA), "an incomplete scan is not 'nothing to cancel'")
        XCTAssertEqual(self.store.deleteAll(accountPeerId: SGCallRecordingStoreTests.accountA), .deferred)
        XCTAssertFalse(self.store.exists(id: readableOfA))

        // What a relaunched process reads back from disk: the removal is still pending.
        XCTAssertEqual(SGCallRecordingAccountLedger().blocksRecording(owner: SGCallRecordingStoreTests.accountA, directory: directory), true)

        // While it is pending, anything it covers is unreachable — an ownerless recording too — and
        // no recording it would cover can be reserved, so the deferred cleanup can never catch a
        // fresh one. Another account is untouched and can still record.
        let ownerless = try self.makeRecording(owner: nil, peerId: nil, version: 1)
        guard case .pendingAccountRemoval = self.store.readState(id: ownerless) else {
            return XCTFail("a recording covered by a pending removal must not be reachable")
        }
        XCTAssertFalse(self.store.list().contains { $0.id == ownerless })
        XCTAssertFalse(self.store.pendingSends().contains { $0.id == ownerless })
        XCTAssertFalse(self.store.writeMetadata(id: self.newId(), metadata: self.liveMetadata(owner: nil)), "an ownerless reservation is covered by every removal")
        let otherAccount = try self.makeRecording(owner: SGCallRecordingStoreTests.accountB, peerId: 3)
        XCTAssertTrue(self.isAvailable(otherAccount))
        XCTAssertTrue(self.store.canRecord(accountPeerId: SGCallRecordingStoreTests.accountB))

        XCTAssertEqual(self.store.retryPendingAccountRemovals(), .deferred, "still locked")
        try self.unlock(locked)
        XCTAssertEqual(self.store.retryPendingAccountRemovals(), .completed)
        XCTAssertFalse(self.store.exists(id: locked))
        XCTAssertFalse(self.store.exists(id: ownerless))
        XCTAssertTrue(self.isAvailable(otherAccount))
        XCTAssertEqual(SGCallRecordingAccountLedger().blocksRecording(owner: nil, directory: directory), false, "a confirmed cleanup leaves nothing pending on disk")
    }

    func testUnwritableLedgerFailsClosedInMemoryAndIsMadeDurableOnRetry() throws {
        let directory = try self.directory()
        let ofA = try self.makeRecording(owner: SGCallRecordingStoreTests.accountA, peerId: 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        XCTAssertEqual(self.store.deleteAll(accountPeerId: SGCallRecordingStoreTests.accountA), .failedToPersist)
        guard case .pendingAccountRemoval = self.store.readState(id: ofA) else {
            return XCTFail("an unpersisted removal still hides what it covers in this process")
        }
        XCTAssertFalse(self.store.canReserve(owner: nil), "and still blocks reservations it covers")
        XCTAssertEqual(SGCallRecordingAccountLedger().blocksRecording(owner: nil, directory: directory), false, "nothing durable was claimed")

        // Writable again, but the cleanup itself still cannot finish (a locked sidecar): the retry
        // must FIRST make the pending removal durable, so a kill now no longer forgets it.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        let locked = try self.makeLockedRecording(owner: SGCallRecordingStoreTests.accountA)
        XCTAssertEqual(self.store.retryPendingAccountRemovals(), .deferred)
        XCTAssertEqual(SGCallRecordingAccountLedger().blocksRecording(owner: SGCallRecordingStoreTests.accountA, directory: directory), true)

        try self.unlock(locked)
        XCTAssertEqual(self.store.retryPendingAccountRemovals(), .completed)
        XCTAssertFalse(self.store.exists(id: ofA))
        XCTAssertFalse(self.store.exists(id: locked))
    }

    func testReconciliationRemovesOnlyKnownSignedOutOwners() throws {
        let ownedByA = try self.makeRecording(owner: SGCallRecordingStoreTests.accountA, peerId: 1)
        let ownedByB = try self.makeRecording(owner: SGCallRecordingStoreTests.accountB, peerId: 2)
        let ownerless = try self.makeRecording(owner: nil, peerId: nil, version: 1)
        let damaged = try self.makeCorruptRecording()

        XCTAssertEqual(self.store.reconcileAccounts(signedInAccountPeerIds: []), .completed)
        XCTAssertTrue(self.isAvailable(ownedByA), "an empty set is 'not loaded yet', never 'every account is gone'")

        XCTAssertEqual(self.store.reconcileAccounts(signedInAccountPeerIds: [SGCallRecordingStoreTests.accountB]), .completed, "a damaged sidecar does not hold reconciliation open")
        XCTAssertFalse(self.store.exists(id: ownedByA))
        XCTAssertTrue(self.isAvailable(ownedByB))
        XCTAssertTrue(self.isAvailable(ownerless))
        guard case .corrupt = self.store.readState(id: damaged) else {
            return XCTFail("another account's audio is never removed just because its sidecar is damaged")
        }
    }

    // MARK: - Global wipe

    func testWipeRemovesEverythingAndTombstonesTheLiveRecording() throws {
        let live = try self.makeRecording(owner: SGCallRecordingStoreTests.accountA, peerId: 1)
        let finished = try self.makeRecording(owner: SGCallRecordingStoreTests.accountB, peerId: 2)
        let ownerless = try self.makeRecording(owner: nil, peerId: nil, version: 1)
        let damaged = try self.makeCorruptRecording()
        self.store.activeRecordingId = live

        XCTAssertEqual(self.store.deleteAll(), .completed)
        for id in [finished, ownerless, damaged] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: try self.path(id, ".ogg")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try self.path(id, ".meta.json")))
        }
        XCTAssertTrue(self.store.isDeleted(id: live))
        XCTAssertFalse(self.store.exists(id: live))
        XCTAssertTrue(self.store.consumeDeleteWhenFinished(id: live), "the session deletes it when it finishes")

        self.store.activeRecordingId = nil
        XCTAssertTrue(self.store.delete(id: live))
        XCTAssertTrue(self.store.list().isEmpty)
        XCTAssertTrue(self.store.canRecord(accountPeerId: SGCallRecordingStoreTests.accountB), "a confirmed wipe no longer blocks recording")
    }

    func testPendingWipeOnDiskIsHonouredByALaterProcessAndBlocksEveryReservation() throws {
        let directory = try self.directory()
        let ledgerPath = (directory as NSString).appendingPathComponent(SGCallRecordingAccountLedger.fileName)
        defer {
            try? FileManager.default.removeItem(atPath: ledgerPath)
        }
        XCTAssertTrue(FileManager.default.createFile(atPath: ledgerPath, contents: Data(#"{"version":2,"isWipePending":true}"#.utf8)))
        let relaunched = SGCallRecordingAccountLedger()
        XCTAssertEqual(relaunched.blocksRecording(owner: SGCallRecordingStoreTests.accountB, directory: directory), true)
        XCTAssertEqual(relaunched.blocksRecording(owner: nil, directory: directory), true)
        XCTAssertEqual(relaunched.covers(owner: .owner(SGCallRecordingStoreTests.accountB), directory: directory), true)
    }

    /// A failed (memory-only) reconciliation [A] followed by a SUCCESSFUL durable [A, X] must not
    /// leave [A] behind to cover — and later delete — the newly signed-in account X, while an
    /// unrelated memory-only removal intent survives untouched. The write failure is a nil directory
    /// (no permissions involved, so it holds even for a root test process); the ledger lives in its
    /// own temporary directory, so nothing here touches real recordings.
    func testNewerDurableReconciliationSupersedesStaleMemoryOnlyOne() throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("sg-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        let accountA = SGCallRecordingStoreTests.accountA
        let accountX = SGCallRecordingStoreTests.accountB
        let removedAccount: Int64 = 7_100_000_099
        let ledger = SGCallRecordingAccountLedger()

        XCTAssertFalse(ledger.recordRemoval(accountPeerId: removedAccount, directory: nil), "unrelated intent, memory-only")
        XCTAssertFalse(ledger.recordReconciliation(signedInAccountPeerIds: [accountA], directory: nil), "write fault: memory-only")
        XCTAssertEqual(ledger.covers(owner: .owner(accountX), directory: directory), true, "precondition: the stale set covers X")

        XCTAssertTrue(ledger.recordReconciliation(signedInAccountPeerIds: [accountA, accountX], directory: directory))
        XCTAssertEqual(ledger.covers(owner: .owner(accountX), directory: directory), false, "the newer durable set supersedes at once")
        XCTAssertEqual(ledger.blocksRecording(owner: accountX, directory: directory), false)

        XCTAssertTrue(ledger.persistPending(directory: directory))
        ledger.clearReconciliation(signedInAccountPeerIds: [accountA, accountX], directory: directory)
        XCTAssertEqual(ledger.covers(owner: .owner(accountX), directory: directory), false, "completing the newer set leaves no stale one behind")
        XCTAssertEqual(ledger.blocksRecording(owner: accountX, directory: directory), false)
        XCTAssertEqual(ledger.covers(owner: .owner(removedAccount), directory: directory), true, "an unrelated removal intent is not erased")

        let reloaded = SGCallRecordingAccountLedger()
        XCTAssertEqual(reloaded.covers(owner: .owner(accountX), directory: directory), false, "nor does a stale set reach disk")
        XCTAssertEqual(reloaded.blocksRecording(owner: accountX, directory: directory), false)
        XCTAssertEqual(reloaded.covers(owner: .owner(removedAccount), directory: directory), true, "the removal intent was made durable")
        XCTAssertNil(reloaded.pending(directory: directory).contents.signedInAccountPeerIds)
    }

    /// Older DURABLE [A] on disk, newer MEMORY-ONLY [A, X] (its write failed), then [A, X] completes
    /// and is cleared WITHOUT any `persistPending` in between. The completed newest set supersedes
    /// the stale disk one: X must not be covered, in this ledger or in a fresh one reading the disk.
    /// An unrelated memory-only removal of R survives.
    func testCompletingNewestMemoryOnlyReconciliationClearsOlderDiskSet() throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("sg-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        let accountA = SGCallRecordingStoreTests.accountA
        let accountX = SGCallRecordingStoreTests.accountB
        let removedAccount: Int64 = 7_100_000_099
        let ledger = SGCallRecordingAccountLedger()

        XCTAssertTrue(ledger.recordReconciliation(signedInAccountPeerIds: [accountA], directory: directory))
        XCTAssertFalse(ledger.recordRemoval(accountPeerId: removedAccount, directory: nil))
        XCTAssertFalse(ledger.recordReconciliation(signedInAccountPeerIds: [accountA, accountX], directory: nil), "write fault: memory-only")
        XCTAssertEqual(SGCallRecordingAccountLedger().covers(owner: .owner(accountX), directory: directory), true, "precondition: the stale [A] is what is on disk")
        XCTAssertEqual(ledger.covers(owner: .owner(accountX), directory: directory), false, "the newer memory set overrides it")

        XCTAssertTrue(ledger.clearReconciliation(signedInAccountPeerIds: [accountA, accountX], directory: directory))
        XCTAssertEqual(ledger.covers(owner: .owner(accountX), directory: directory), false)
        XCTAssertEqual(ledger.blocksRecording(owner: accountX, directory: directory), false)
        XCTAssertEqual(ledger.covers(owner: .owner(removedAccount), directory: directory), true, "an unrelated removal intent is not erased")

        let reloaded = SGCallRecordingAccountLedger()
        XCTAssertEqual(reloaded.covers(owner: .owner(accountX), directory: directory), false, "the stale disk set is gone, not just hidden")
        XCTAssertEqual(reloaded.blocksRecording(owner: accountX, directory: directory), false)
        XCTAssertNil(reloaded.pending(directory: directory).contents.signedInAccountPeerIds)
    }

    /// Same start, but the clear itself cannot be written: the newest set must keep overriding the
    /// stale disk one for this process instead of being dropped.
    func testFailedClearKeepsNewestReconciliationOverridingOlderDiskSet() throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("sg-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        let accountA = SGCallRecordingStoreTests.accountA
        let accountX = SGCallRecordingStoreTests.accountB
        let signedOut: Int64 = 7_100_000_077
        let ledger = SGCallRecordingAccountLedger()

        XCTAssertTrue(ledger.recordReconciliation(signedInAccountPeerIds: [accountA], directory: directory))
        XCTAssertFalse(ledger.recordReconciliation(signedInAccountPeerIds: [accountA, accountX], directory: nil))

        XCTAssertFalse(ledger.clearReconciliation(signedInAccountPeerIds: [accountA, accountX], directory: nil), "write fault: not durable")
        XCTAssertEqual(ledger.covers(owner: .owner(accountX), directory: directory), false, "the newest set still overrides the stale [A]")
        XCTAssertEqual(ledger.blocksRecording(owner: accountX, directory: directory), false)
        XCTAssertEqual(ledger.covers(owner: .owner(signedOut), directory: directory), true, "and still covers what really is signed out")

        XCTAssertTrue(ledger.clearReconciliation(signedInAccountPeerIds: [accountA, accountX], directory: directory), "a later clear that can be written finishes it")
        XCTAssertEqual(SGCallRecordingAccountLedger().covers(owner: .owner(accountX), directory: directory), false)
    }

    /// An OLDER durable reconciliation ([A], left by a previous process) is on disk when the list —
    /// or delivery's foreground resume — reads recordings before the current account set is known.
    /// That read must only hide what the stale set covers, never delete the recording of X, who is
    /// signed in now. The authoritative reconcile with the current set, then the explicit retry,
    /// removes only the account that really is signed out.
    func testReadBeforeCurrentReconciliationNeverPurgesWithAStaleSignedInSet() throws {
        let accountA = SGCallRecordingStoreTests.accountA
        let accountX = SGCallRecordingStoreTests.accountB
        let signedOut: Int64 = 7_100_000_055
        let ofX = try self.makeRecording(owner: accountX, peerId: 1)
        let ofSignedOut = try self.makeRecording(owner: signedOut, peerId: 2)

        XCTAssertTrue(self.store.accountLedger.recordReconciliation(signedInAccountPeerIds: [accountA], directory: self.store.directoryPath), "the stale set a previous process left on disk")

        XCTAssertFalse(self.store.list().contains { $0.id == ofX }, "hidden while the stale set is pending")
        guard case .pendingAccountRemoval = self.store.readState(id: ofX) else {
            return XCTFail("the stale set hides X until the current one is recorded")
        }
        XCTAssertTrue(self.store.managementOnlyRecordingIds().contains(ofX))
        XCTAssertFalse(self.store.pendingSends().contains { $0.id == ofX })
        XCTAssertFalse(self.store.exists(id: ofX))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try self.path(ofX, ".ogg")), "a read never deletes on a stale reconciliation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try self.path(ofX, ".meta.json")))

        XCTAssertEqual(self.store.reconcileAccounts(signedInAccountPeerIds: [accountA, accountX]), .completed)
        XCTAssertEqual(self.store.retryPendingAccountRemovals(), .completed)
        XCTAssertTrue(self.isAvailable(ofX), "the current set supersedes the stale one, and X keeps its recording")
        XCTAssertTrue(self.store.list().contains { $0.id == ofX })
        XCTAssertFalse(self.store.exists(id: ofSignedOut), "the account that really is signed out is removed")
    }

    func testLedgerFromANewerBuildFailsClosed() throws {
        let directory = try self.directory()
        let ledgerPath = (directory as NSString).appendingPathComponent(SGCallRecordingAccountLedger.fileName)
        defer {
            try? FileManager.default.removeItem(atPath: ledgerPath)
        }
        XCTAssertTrue(FileManager.default.createFile(atPath: ledgerPath, contents: Data(#"{"version":3}"#.utf8)))
        let relaunched = SGCallRecordingAccountLedger()
        XCTAssertNil(relaunched.blocksRecording(owner: SGCallRecordingStoreTests.accountB, directory: directory), "an unknown format is unreadable, and unreadable blocks recording")
    }

    // MARK: - Privacy

    func testPrivacyIsFailClosedForTheRecordedPair() {
        func item(account: Int64?, peer: Int64?) -> SGCallRecordingItem {
            return SGCallRecordingItem(id: "p", startTimestamp: 0, duration: 1, peerTitle: "Alice", audioPaths: ["/a"], totalSize: 1, isComplete: true, send: nil, accountPeerId: account, peerId: peer)
        }
        var asked: [(Int64, Int64)] = []
        let verdict: (SGCallRecordingPeerProtection) -> (Int64, Int64) -> SGCallRecordingPeerProtection = { value in
            return { peerId, accountPeerId in
                asked.append((peerId, accountPeerId))
                return value
            }
        }

        XCTAssertEqual(item(account: 10, peer: 20).privacy(isProtectionConfigured: true, protection: verdict(.protected)), .protected(accountPeerId: 10, peerId: 20))
        XCTAssertEqual(asked.last?.0, 20)
        XCTAssertEqual(asked.last?.1, 10, "protection is checked for the account that MADE the recording")
        XCTAssertEqual(item(account: 10, peer: 20).privacy(isProtectionConfigured: true, protection: verdict(.none)), .open)
        XCTAssertEqual(item(account: 10, peer: 20).privacy(isProtectionConfigured: true, protection: verdict(.unknown)), .unverifiable)

        asked.removeAll()
        XCTAssertEqual(item(account: 10, peer: nil).privacy(isProtectionConfigured: true, protection: verdict(.none)), .unverifiable)
        XCTAssertEqual(item(account: nil, peer: 20).privacy(isProtectionConfigured: true, protection: verdict(.none)), .unverifiable)
        XCTAssertTrue(asked.isEmpty, "no identity is guessed for a recording that does not carry one")
        XCTAssertEqual(item(account: nil, peer: nil).privacy(isProtectionConfigured: false, protection: verdict(.protected)), .open, "nothing can be hidden when no protection is configured")
    }

    // MARK: - Row policy

    func testLiveRowOffersNoPlaybackOrExportAndSaysRecordingNow() {
        let row = SGCallRecordingRowPresentation(privacy: .open, isLive: true, isPlaying: false, isSendWaiting: false, isSendFailed: false, isComplete: false, isExportAvailable: true)
        XCTAssertEqual(row.badges, [.live], "a live recording is not 'stops early'")
        XCTAssertFalse(row.canPlay)
        XCTAssertFalse(row.canShare)
        XCTAssertFalse(row.canSend)
        XCTAssertFalse(row.showsDuration)
    }

    func testProtectedRowIsRedactedAndNeedsAuthorization() {
        let row = SGCallRecordingRowPresentation(privacy: .protected(accountPeerId: 1, peerId: 2), isLive: false, isPlaying: false, isSendWaiting: false, isSendFailed: false, isComplete: true, isExportAvailable: true)
        XCTAssertTrue(row.isRedacted)
        XCTAssertFalse(row.showsDate)
        XCTAssertFalse(row.showsDuration)
        XCTAssertTrue(row.requiresAuthorization)
        XCTAssertTrue(row.canPlay)
    }

    func testUnverifiableRowOffersOnlyDelete() {
        let row = SGCallRecordingRowPresentation(privacy: .unverifiable, isLive: false, isPlaying: false, isSendWaiting: false, isSendFailed: false, isComplete: true, isExportAvailable: true)
        XCTAssertTrue(row.isRedacted)
        XCTAssertFalse(row.canPlay)
        XCTAssertFalse(row.canShare)
        XCTAssertFalse(row.canSend)
    }

    func testUnavailableBuildPlaysButNeverExports() {
        let row = SGCallRecordingRowPresentation(privacy: .open, isLive: false, isPlaying: false, isSendWaiting: false, isSendFailed: false, isComplete: true, isExportAvailable: false)
        XCTAssertTrue(row.canPlay)
        XCTAssertFalse(row.canShare)
        XCTAssertFalse(row.canSend)
    }

    func testWarningStatusComesFirst() {
        let row = SGCallRecordingRowPresentation(privacy: .open, isLive: false, isPlaying: false, isSendWaiting: false, isSendFailed: true, isComplete: false, isExportAvailable: true)
        XCTAssertEqual(row.badges, [.sendFailed, .incomplete])
        XCTAssertEqual(row.primaryBadge?.isWarning, true)
    }
}
