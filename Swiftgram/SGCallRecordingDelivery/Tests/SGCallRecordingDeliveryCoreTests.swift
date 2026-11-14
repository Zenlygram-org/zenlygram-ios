import Foundation
import XCTest

import SGCallRecordingDeliveryCore

/// In-memory storage that can model "the file exists but cannot be opened" (data protection before
/// first unlock) and a failing write (full disk).
private final class FakeLedgerStorage: SGCallRecordingDeliveryLedgerStorage {
    var data: Data?
    var isReadable = true
    var isWritable = true
    private(set) var writeCount = 0

    func read() -> SGCallRecordingDeliveryLedgerReadResult {
        guard let data else {
            return .absent
        }
        return self.isReadable ? .data(data) : .unreadable
    }

    func write(_ data: Data) -> Bool {
        guard self.isWritable else {
            return false
        }
        self.writeCount += 1
        self.data = data
        return true
    }

    /// The marker is writable whatever the ledger's own protection state, like the real one.
    var marker = false
    var isMarkerWritable = true

    func readMarker() -> Bool {
        return self.marker
    }

    func writeMarker(_ present: Bool) -> Bool {
        guard self.isMarkerWritable else {
            return false
        }
        self.marker = present
        return true
    }
}

private func makeEntry(account: Int64, correlation: Int64, local: Int32? = nil, gid: Int64? = nil, cloud: Int32? = nil, retiring: Bool = false) -> SGCallRecordingDeliveryEntry {
    return SGCallRecordingDeliveryEntry(
        accountPeerId: account,
        exportAuthorized: false,
        legCount: 1,
        legs: [SGCallRecordingDeliveryLegFacts(legIndex: 0, correlationId: correlation, localMessageId: local, globallyUniqueId: gid, cloudMessageId: cloud)],
        isRetiring: retiring
    )
}

/// Seeds `storage` with `entries` as a previous process would have left them.
private func seed(_ storage: FakeLedgerStorage, _ entries: [String: SGCallRecordingDeliveryEntry]) {
    let writer = SGCallRecordingDeliveryLedger(storage: storage)
    for (recordingId, entry) in entries {
        XCTAssertTrue(writer.set(recordingId: recordingId, entry))
    }
}

final class SGCallRecordingDeliveryLedgerTests: XCTestCase {
    func testUnreadableLedgerIsNotAbsence() {
        let storage = FakeLedgerStorage()
        seed(storage, ["rec-a": makeEntry(account: 1, correlation: 10, local: 5)])
        storage.isReadable = false

        let ledger = SGCallRecordingDeliveryLedger(storage: storage)

        XCTAssertEqual(ledger.lookup(recordingId: "rec-a"), .unavailable)
        XCTAssertEqual(ledger.lookup(recordingId: "never-written"), .unavailable)
        XCTAssertNil(ledger.allEntries())
        XCTAssertFalse(ledger.holdsNothing(accountPeerId: 1))
    }

    func testAbsentLedgerIsKnownEmpty() {
        let ledger = SGCallRecordingDeliveryLedger(storage: FakeLedgerStorage())

        XCTAssertEqual(ledger.lookup(recordingId: "rec-a"), .known(nil))
        XCTAssertTrue(ledger.holdsNothing(accountPeerId: 1))
    }

    func testWritesWhileUnreadableMergeOverDiskOnUnlock() {
        let storage = FakeLedgerStorage()
        seed(storage, [
            "rec-a": makeEntry(account: 1, correlation: 10, local: 5),
            "rec-b": makeEntry(account: 1, correlation: 20, local: 6)
        ])
        storage.isReadable = false
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)

        // Learned while locked: an acknowledgement for rec-a.
        XCTAssertFalse(ledger.set(recordingId: "rec-a", makeEntry(account: 1, correlation: 10, local: 5, cloud: 900)))
        XCTAssertEqual(ledger.lookup(recordingId: "rec-a"), .known(makeEntry(account: 1, correlation: 10, local: 5, cloud: 900)))

        storage.isReadable = true

        XCTAssertEqual(ledger.lookup(recordingId: "rec-a"), .known(makeEntry(account: 1, correlation: 10, local: 5, cloud: 900)))
        XCTAssertEqual(ledger.lookup(recordingId: "rec-b"), .known(makeEntry(account: 1, correlation: 20, local: 6)))
        // And it reached disk: a fresh process sees both.
        let reread = SGCallRecordingDeliveryLedger(storage: storage)
        XCTAssertEqual(reread.lookup(recordingId: "rec-a"), .known(makeEntry(account: 1, correlation: 10, local: 5, cloud: 900)))
        XCTAssertEqual(reread.lookup(recordingId: "rec-b"), .known(makeEntry(account: 1, correlation: 20, local: 6)))
    }

    func testRemovalWhileUnreadableDoesNotResurrect() {
        let storage = FakeLedgerStorage()
        seed(storage, ["rec-a": makeEntry(account: 1, correlation: 10, local: 5)])
        storage.isReadable = false
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)

        XCTAssertFalse(ledger.set(recordingId: "rec-a", nil))
        XCTAssertEqual(ledger.lookup(recordingId: "rec-a"), .known(nil))

        storage.isReadable = true
        XCTAssertEqual(ledger.lookup(recordingId: "rec-a"), .known(nil))
        XCTAssertEqual(SGCallRecordingDeliveryLedger(storage: storage).lookup(recordingId: "rec-a"), .known(nil))
    }

    func testAccountRemovalWhileUnreadableIsReplayedAndReportedOnlyWhenDurable() {
        let storage = FakeLedgerStorage()
        seed(storage, [
            "rec-a": makeEntry(account: 1, correlation: 10, local: 5),
            "rec-b": makeEntry(account: 2, correlation: 20, local: 6)
        ])
        storage.isReadable = false
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)

        XCTAssertFalse(ledger.removeAll(accountPeerId: 1))
        XCTAssertFalse(ledger.holdsNothing(accountPeerId: 1))

        storage.isReadable = true
        XCTAssertTrue(ledger.holdsNothing(accountPeerId: 1))
        XCTAssertEqual(ledger.lookup(recordingId: "rec-b"), .known(makeEntry(account: 2, correlation: 20, local: 6)))
        XCTAssertTrue(SGCallRecordingDeliveryLedger(storage: storage).holdsNothing(accountPeerId: 1))
    }

    func testBlindUpdateWhileUnreadableChangesNothing() {
        let storage = FakeLedgerStorage()
        seed(storage, ["rec-a": makeEntry(account: 1, correlation: 10, local: 5, gid: 77)])
        storage.isReadable = false
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)

        var transformed = false
        let durable = ledger.update(recordingId: "rec-a") { _ in
            transformed = true
            return makeEntry(account: 1, correlation: 10)
        }

        XCTAssertFalse(durable)
        XCTAssertFalse(transformed)
        storage.isReadable = true
        // The gid and local id that were merely unreadable are intact.
        XCTAssertEqual(ledger.lookup(recordingId: "rec-a"), .known(makeEntry(account: 1, correlation: 10, local: 5, gid: 77)))
    }

    func testFailedWriteIsNotReportedDurableAndFlushRetries() {
        let storage = FakeLedgerStorage()
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)
        storage.isWritable = false

        XCTAssertFalse(ledger.set(recordingId: "rec-a", makeEntry(account: 1, correlation: 10, local: 5)))
        // Still known in memory — the cancellation handle is not lost in this process.
        XCTAssertEqual(ledger.lookup(recordingId: "rec-a"), .known(makeEntry(account: 1, correlation: 10, local: 5)))
        XCTAssertFalse(ledger.flush())

        storage.isWritable = true
        XCTAssertTrue(ledger.flush())
        XCTAssertEqual(SGCallRecordingDeliveryLedger(storage: storage).lookup(recordingId: "rec-a"), .known(makeEntry(account: 1, correlation: 10, local: 5)))
    }

    func testCorruptFileIsReplacedNotWaitedOn() {
        let storage = FakeLedgerStorage()
        storage.data = Data("not json".utf8)
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)

        XCTAssertEqual(ledger.lookup(recordingId: "rec-a"), .known(nil))
        XCTAssertTrue(ledger.set(recordingId: "rec-a", makeEntry(account: 1, correlation: 10)))
        XCTAssertEqual(SGCallRecordingDeliveryLedger(storage: storage).lookup(recordingId: "rec-a"), .known(makeEntry(account: 1, correlation: 10)))
    }

    func testReloginEntryWrittenAfterRemovalSurvivesReplay() {
        let storage = FakeLedgerStorage()
        seed(storage, ["old": makeEntry(account: 1, correlation: 10, local: 5)])
        storage.isReadable = false
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)

        XCTAssertFalse(ledger.removeAll(accountPeerId: 1))
        XCTAssertFalse(ledger.set(recordingId: "new", makeEntry(account: 1, correlation: 20)))

        storage.isReadable = true
        XCTAssertEqual(ledger.lookup(recordingId: "old"), .known(nil))
        XCTAssertEqual(ledger.lookup(recordingId: "new"), .known(makeEntry(account: 1, correlation: 20)))
    }

    func testHoldsNothingIsFalseWhileAChangeHasNotReachedDisk() {
        let storage = FakeLedgerStorage()
        seed(storage, ["rec-a": makeEntry(account: 1, correlation: 10)])
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)
        storage.isWritable = false

        XCTAssertFalse(ledger.removeAll(accountPeerId: 1))
        XCTAssertFalse(ledger.holdsNothing(accountPeerId: 1))

        storage.isWritable = true
        XCTAssertTrue(ledger.flush())
        XCTAssertTrue(ledger.holdsNothing(accountPeerId: 1))
    }

    func testOwnerlessRetirementRequestIsDurableWhileTheLedgerIsUnreadable() {
        let storage = FakeLedgerStorage()
        seed(storage, ["rec-a": makeEntry(account: 1, correlation: 10)])
        storage.isReadable = false
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)

        XCTAssertTrue(ledger.requestOwnerlessRetirement())
        // A new process (kill) still sees the request.
        XCTAssertTrue(SGCallRecordingDeliveryLedger(storage: storage).isOwnerlessRetirementRequested)
        XCTAssertTrue(ledger.clearOwnerlessRetirementRequest())
        XCTAssertFalse(SGCallRecordingDeliveryLedger(storage: storage).isOwnerlessRetirementRequested)
    }

    func testOwnerlessRetirementRequestIsKeptInMemoryWhenTheMarkerCannotBeWritten() {
        let storage = FakeLedgerStorage()
        storage.isMarkerWritable = false
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)

        XCTAssertFalse(ledger.requestOwnerlessRetirement())
        XCTAssertTrue(ledger.isOwnerlessRetirementRequested)
        XCTAssertFalse(ledger.clearOwnerlessRetirementRequest())
        XCTAssertTrue(ledger.isOwnerlessRetirementRequested)
    }

    func testEntryDecodesWithoutLaterFields() throws {
        let json = Data(#"{"accountPeerId":1,"legs":[{"legIndex":0,"correlationId":10}]}"#.utf8)
        let entry = try JSONDecoder().decode(SGCallRecordingDeliveryEntry.self, from: json)

        XCTAssertEqual(entry.accountPeerId, 1)
        XCTAssertNil(entry.accountRecordId)
        XCTAssertFalse(entry.exportAuthorized)
        XCTAssertFalse(entry.isAutomatic)
        XCTAssertFalse(entry.isOwnerlessRecording)
        XCTAssertFalse(entry.isRetiring)
        XCTAssertEqual(entry.legs, [SGCallRecordingDeliveryLegFacts(legIndex: 0, correlationId: 10)])
    }

    func testFileIsContentFree() throws {
        let storage = FakeLedgerStorage()
        let recordingId = "1790000000-ABCDEF12"
        seed(storage, [recordingId: makeEntry(account: 1, correlation: 10, local: 5)])

        let text = String(decoding: try XCTUnwrap(storage.data), as: UTF8.self)
        XCTAssertFalse(text.contains(recordingId))
        XCTAssertFalse(text.contains("1790000000"))
        let key = SGCallRecordingDeliveryLedger.key(recordingId: recordingId)
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(key, SGCallRecordingDeliveryLedger.key(recordingId: recordingId))
        XCTAssertNotEqual(key, SGCallRecordingDeliveryLedger.key(recordingId: "1790000000-ABCDEF13"))
    }

    func testFileStorageRoundTripAndAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sg-delivery-ledger-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let file = SGCallRecordingDeliveryLedgerFile(directoryURL: directory)
        guard case .absent = file.read() else {
            return XCTFail("a never-written ledger must read as absent")
        }

        let ledger = SGCallRecordingDeliveryLedger(storage: file)
        XCTAssertTrue(ledger.set(recordingId: "rec-a", makeEntry(account: 1, correlation: 10, local: 5)))

        let reread = SGCallRecordingDeliveryLedger(storage: SGCallRecordingDeliveryLedgerFile(directoryURL: directory))
        XCTAssertEqual(reread.lookup(recordingId: "rec-a"), .known(makeEntry(account: 1, correlation: 10, local: 5)))
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}

final class SGCallRecordingDeliveryEntryTests: XCTestCase {
    func testUpdatingLegRetiresTheReplacedAttempt() {
        let entry = makeEntry(account: 1, correlation: 10, local: 5, gid: 77)

        let updated = entry.updatingLeg(legIndex: 0, correlationId: 11) { facts in
            var facts = facts
            facts.localMessageId = 9
            return facts
        }

        XCTAssertNil(updated.facts(legIndex: 0, correlationId: 10))
        XCTAssertEqual(updated.facts(legIndex: 0, correlationId: 11), SGCallRecordingDeliveryLegFacts(legIndex: 0, correlationId: 11, localMessageId: 9))
        XCTAssertEqual(updated.retiredCorrelationIds, [10])
        XCTAssertEqual(updated.allCorrelationIds, [11, 10])
    }

    func testUnacknowledgedLocalIdsAreTheCancellationHandles() {
        let entry = SGCallRecordingDeliveryEntry(accountPeerId: 1, exportAuthorized: false, legCount: 2, legs: [
            SGCallRecordingDeliveryLegFacts(legIndex: 0, correlationId: 10, localMessageId: 5, cloudMessageId: 900),
            SGCallRecordingDeliveryLegFacts(legIndex: 1, correlationId: 11, localMessageId: 6)
        ])

        XCTAssertEqual(entry.unacknowledgedLocalMessageIds, [6])
    }
}

final class SGCallRecordingDeliveryPolicyTests: XCTestCase {
    func testAutomaticSendFailsClosed() {
        XCTAssertEqual(sgCallRecordingAutoSendDecision(accountPeerId: 1, peerId: 2, privacy: .open), .send)
        XCTAssertEqual(sgCallRecordingAutoSendDecision(accountPeerId: 1, peerId: 2, privacy: .protected), .never)
        XCTAssertEqual(sgCallRecordingAutoSendDecision(accountPeerId: 1, peerId: 2, privacy: .unverifiable), .wait)
        // Unknown identity is never "unprotected", even when nothing is configured (`.open`).
        XCTAssertEqual(sgCallRecordingAutoSendDecision(accountPeerId: 1, peerId: nil, privacy: .open), .never)
        XCTAssertEqual(sgCallRecordingAutoSendDecision(accountPeerId: nil, peerId: 2, privacy: .open), .never)
    }

    func testManualSendNeedsAMatchingGrantOnlyForProtectedAndNeverForUnverifiable() {
        XCTAssertEqual(sgCallRecordingManualSendDecision(privacy: .open, grantMatches: false), .send(exportAuthorized: false))
        XCTAssertEqual(sgCallRecordingManualSendDecision(privacy: .open, grantMatches: true), .send(exportAuthorized: false))
        XCTAssertEqual(sgCallRecordingManualSendDecision(privacy: .protected, grantMatches: false), .requiresAuthorization)
        XCTAssertEqual(sgCallRecordingManualSendDecision(privacy: .protected, grantMatches: true), .send(exportAuthorized: true))
        XCTAssertEqual(sgCallRecordingManualSendDecision(privacy: .unverifiable, grantMatches: true), .refused)
        XCTAssertEqual(sgCallRecordingManualSendDecision(privacy: .unverifiable, grantMatches: false), .refused)
    }

    func testGrantIsScopedToTheRecordingsOwnAccountAndPeer() {
        let grant = SGCallRecordingExportGrant(accountPeerId: 1, peerId: 2)

        XCTAssertTrue(sgCallRecordingExportGrantMatches(grant, accountPeerId: 1, peerId: 2))
        XCTAssertFalse(sgCallRecordingExportGrantMatches(grant, accountPeerId: 1, peerId: 3))
        XCTAssertFalse(sgCallRecordingExportGrantMatches(grant, accountPeerId: 4, peerId: 2))
        XCTAssertFalse(sgCallRecordingExportGrantMatches(grant, accountPeerId: nil, peerId: 2))
        XCTAssertFalse(sgCallRecordingExportGrantMatches(grant, accountPeerId: 1, peerId: nil))
        XCTAssertFalse(sgCallRecordingExportGrantMatches(nil, accountPeerId: 1, peerId: 2))
    }

    func testEnqueueRevalidation() {
        XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .open, exportAuthorized: false, isAutomatic: false, autoSendEnabled: true), .enqueue(neutral: false))
        XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .protected, exportAuthorized: true, isAutomatic: false, autoSendEnabled: true), .enqueue(neutral: true))
        XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .protected, exportAuthorized: false, isAutomatic: false, autoSendEnabled: true), .withdraw)
        XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .unverifiable, exportAuthorized: true, isAutomatic: false, autoSendEnabled: true), .wait)
    }

    func testNewAutomaticMessageWaitsWhileTheSettingIsOff() {
        // A legacy automatic pair with one leg already acknowledged, or a re-send record saved just
        // before a kill: the setting never withdraws it, so enqueue is the last admission.
        XCTAssertFalse(sgCallRecordingAutoOffWithdraws(isAutomatic: true, autoSendEnabled: false, anyLegEnqueued: true))
        XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .open, exportAuthorized: false, isAutomatic: true, autoSendEnabled: false), .wait)
        XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .protected, exportAuthorized: true, isAutomatic: true, autoSendEnabled: false), .wait)
        // The setting back on admits it again.
        XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .open, exportAuthorized: false, isAutomatic: true, autoSendEnabled: true), .enqueue(neutral: false))
    }

    func testManualDeliveryIgnoresTheSettingAndPrivacyStillDecidesFirst() {
        // The user's own tap / "Try sending again" is not automatic.
        XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .open, exportAuthorized: false, isAutomatic: false, autoSendEnabled: false), .enqueue(neutral: false))
        XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .protected, exportAuthorized: true, isAutomatic: false, autoSendEnabled: false), .enqueue(neutral: true))
        // Protected without a grant is still withdrawn, and unverifiable still waits, whatever the
        // provenance and the setting.
        for isAutomatic in [false, true] {
            for autoSendEnabled in [false, true] {
                XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .protected, exportAuthorized: false, isAutomatic: isAutomatic, autoSendEnabled: autoSendEnabled), .withdraw)
                XCTAssertEqual(sgCallRecordingEnqueueDecision(privacy: .unverifiable, exportAuthorized: true, isAutomatic: isAutomatic, autoSendEnabled: autoSendEnabled), .wait)
            }
        }
    }

    func testInFlightExportIsWithdrawnWhenThePeerBecomesProtected() {
        XCTAssertEqual(sgCallRecordingInFlightDecision(privacy: .open, exportAuthorized: false), .keep)
        XCTAssertEqual(sgCallRecordingInFlightDecision(privacy: .protected, exportAuthorized: false), .withdraw)
        XCTAssertEqual(sgCallRecordingInFlightDecision(privacy: .unverifiable, exportAuthorized: false), .withdraw)
        // An authorized export is already neutral.
        XCTAssertEqual(sgCallRecordingInFlightDecision(privacy: .protected, exportAuthorized: true), .keep)
        XCTAssertEqual(sgCallRecordingInFlightDecision(privacy: .unverifiable, exportAuthorized: true), .keep)
    }

    func testTurningAutomaticSendOffWithdrawsOnlyUnenqueuedAutomaticRecords() {
        XCTAssertTrue(sgCallRecordingAutoOffWithdraws(isAutomatic: true, autoSendEnabled: false, anyLegEnqueued: false))
        XCTAssertFalse(sgCallRecordingAutoOffWithdraws(isAutomatic: true, autoSendEnabled: false, anyLegEnqueued: true))
        XCTAssertFalse(sgCallRecordingAutoOffWithdraws(isAutomatic: true, autoSendEnabled: true, anyLegEnqueued: false))
        XCTAssertFalse(sgCallRecordingAutoOffWithdraws(isAutomatic: false, autoSendEnabled: false, anyLegEnqueued: false))
    }

    func testCancelDecision() {
        // Anything in flight, or a ledger that cannot be read: do not delete.
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .readable(hasSendRecord: true), ledgerReadable: true, hasLedgerEntry: true, inFlight: true), .refuse)
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .lockedUnreadable, ledgerReadable: false, hasLedgerEntry: false, inFlight: false), .refuse)
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .corrupt, ledgerReadable: false, hasLedgerEntry: false, inFlight: false), .refuse)
        // A readable ledger carries the cancellation for rows only shown as neutral delete-only.
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .corrupt, ledgerReadable: true, hasLedgerEntry: true, inFlight: false), .retireLedgerEntry)
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .corrupt, ledgerReadable: true, hasLedgerEntry: false, inFlight: false), .nothingToCancel)
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .lockedUnreadable, ledgerReadable: true, hasLedgerEntry: true, inFlight: false), .retireLedgerEntry)
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .gone, ledgerReadable: true, hasLedgerEntry: true, inFlight: false), .retireLedgerEntry)
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .readable(hasSendRecord: true), ledgerReadable: true, hasLedgerEntry: false, inFlight: false), .cancelRecord)
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .readable(hasSendRecord: false), ledgerReadable: true, hasLedgerEntry: false, inFlight: false), .nothingToCancel)
        XCTAssertEqual(sgCallRecordingCancelDecision(sidecar: .readable(hasSendRecord: false), ledgerReadable: true, hasLedgerEntry: true, inFlight: false), .retireLedgerEntry)
    }

    func testOrphanLedgerKeysAreThoseWithoutARecording() {
        let entries = [
            SGCallRecordingDeliveryLedger.key(recordingId: "kept"): makeEntry(account: 1, correlation: 10),
            SGCallRecordingDeliveryLedger.key(recordingId: "gone"): makeEntry(account: 1, correlation: 20),
            SGCallRecordingDeliveryLedger.key(recordingId: "retiring"): makeEntry(account: 1, correlation: 30, retiring: true)
        ]

        XCTAssertEqual(sgCallRecordingOrphanLedgerKeys(entries: entries, knownRecordingIds: ["kept"]), [SGCallRecordingDeliveryLedger.key(recordingId: "gone")])
        XCTAssertEqual(Set(sgCallRecordingOrphanLedgerKeys(entries: entries, knownRecordingIds: [])), [SGCallRecordingDeliveryLedger.key(recordingId: "kept"), SGCallRecordingDeliveryLedger.key(recordingId: "gone")])
    }

    func testOnlyMessagesCarryingOurOwnUploadAreOurs() {
        let directory = "/var/mobile/Containers/Data/Application/X/Library/Application Support/zenlygram-call-recordings"
        let ours = SGCallRecordingLocalResource(randomId: sgCallRecordingResourceRandomId(correlationId: 10), path: directory + "/rec.ogg")
        let foreign = SGCallRecordingLocalResource(randomId: 999, path: "/tmp/photo.jpg")

        XCTAssertTrue(sgCallRecordingIsOwnedMessage(isIncoming: false, resources: [ours], correlationIds: [10], ownedDirectory: nil, ownedFileNames: []))
        // A message at a reused local id with someone else's file: not ours, never deleted or trusted.
        XCTAssertFalse(sgCallRecordingIsOwnedMessage(isIncoming: false, resources: [foreign], correlationIds: [10], ownedDirectory: directory, ownedFileNames: ["rec.ogg"]))
        XCTAssertFalse(sgCallRecordingIsOwnedMessage(isIncoming: false, resources: [], correlationIds: [10], ownedDirectory: directory, ownedFileNames: ["rec.ogg"]))
        // Another attempt's resource is not this attempt's.
        XCTAssertFalse(sgCallRecordingIsOwnedMessage(isIncoming: false, resources: [ours], correlationIds: [11], ownedDirectory: nil, ownedFileNames: []))
        // Incoming is never ours.
        XCTAssertFalse(sgCallRecordingIsOwnedMessage(isIncoming: true, resources: [ours], correlationIds: [10], ownedDirectory: nil, ownedFileNames: []))
        // A record written before the derivation: the recording's own exact audio path.
        let legacy = SGCallRecordingLocalResource(randomId: 12345, path: directory + "/rec.ogg")
        XCTAssertTrue(sgCallRecordingIsOwnedMessage(isIncoming: false, resources: [legacy], correlationIds: [10], ownedDirectory: directory, ownedFileNames: ["rec.ogg"]))
        XCTAssertFalse(sgCallRecordingIsOwnedMessage(isIncoming: false, resources: [legacy], correlationIds: [10], ownedDirectory: directory, ownedFileNames: ["other.ogg"]))
    }

    func testMergeAppliesOnlyMatchingAttemptsAndAcknowledgementWins() {
        let sidecar = [
            SGCallRecordingDeliveryLegState(correlationId: 10, localMessageId: nil, cloudMessageId: nil),
            SGCallRecordingDeliveryLegState(correlationId: 11, localMessageId: 3, cloudMessageId: nil),
            SGCallRecordingDeliveryLegState(correlationId: 12, localMessageId: nil, cloudMessageId: nil)
        ]
        let ledger = SGCallRecordingDeliveryEntry(accountPeerId: 1, exportAuthorized: false, legCount: 3, legs: [
            // Unsaved local id (#70): filled in.
            SGCallRecordingDeliveryLegFacts(legIndex: 0, correlationId: 10, localMessageId: 5),
            // Retry re-binding (#69) and a locked-time acknowledgement (#68).
            SGCallRecordingDeliveryLegFacts(legIndex: 1, correlationId: 11, localMessageId: 8, cloudMessageId: 901),
            // Another attempt's facts: ignored.
            SGCallRecordingDeliveryLegFacts(legIndex: 2, correlationId: 99, localMessageId: 7, cloudMessageId: 902)
        ])

        let merged = sgCallRecordingMergedLegs(sidecar: sidecar, ledger: ledger)

        XCTAssertEqual(merged[0], SGCallRecordingDeliveryLegState(correlationId: 10, localMessageId: 5, cloudMessageId: nil))
        XCTAssertEqual(merged[1], SGCallRecordingDeliveryLegState(correlationId: 11, localMessageId: 3, cloudMessageId: 901))
        XCTAssertEqual(merged[2], sidecar[2])
        XCTAssertEqual(sgCallRecordingMergedLegs(sidecar: sidecar, ledger: nil), sidecar)
    }

    func testMergeTakesTheReboundLocalId() {
        let sidecar = [SGCallRecordingDeliveryLegState(correlationId: 10, localMessageId: 3, cloudMessageId: nil)]
        let ledger = SGCallRecordingDeliveryEntry(accountPeerId: 1, exportAuthorized: false, legCount: 1, legs: [
            SGCallRecordingDeliveryLegFacts(legIndex: 0, correlationId: 10, localMessageId: 8)
        ])

        XCTAssertEqual(sgCallRecordingMergedLegs(sidecar: sidecar, ledger: ledger)[0].localMessageId, 8)
    }

    func testLegResolutionOrderOfEvidence() {
        XCTAssertEqual(sgCallRecordingResolveLeg(correlationCloudId: 900, globallyUniqueIdResolution: .cloud(id: 901), retryReplacement: (8, 1), vanishedLocalMessageId: 3), .confirmed(cloudMessageId: 900))
        XCTAssertEqual(sgCallRecordingResolveLeg(correlationCloudId: nil, globallyUniqueIdResolution: .cloud(id: 901), retryReplacement: (8, 1), vanishedLocalMessageId: 3), .confirmed(cloudMessageId: 901))
        XCTAssertEqual(sgCallRecordingResolveLeg(correlationCloudId: nil, globallyUniqueIdResolution: .local(id: 6), retryReplacement: nil, vanishedLocalMessageId: 3), .rebound(localMessageId: 6, globallyUniqueId: nil))
        XCTAssertEqual(sgCallRecordingResolveLeg(correlationCloudId: nil, globallyUniqueIdResolution: nil, retryReplacement: (8, 42), vanishedLocalMessageId: 3), .rebound(localMessageId: 8, globallyUniqueId: 42))
        // Deleted by the user: the gid no longer resolves and nothing carries the resource.
        XCTAssertEqual(sgCallRecordingResolveLeg(correlationCloudId: nil, globallyUniqueIdResolution: nil, retryReplacement: nil, vanishedLocalMessageId: 3), .abandoned)
        // Scheduled / another chat is not "in Saved Messages".
        XCTAssertEqual(sgCallRecordingResolveLeg(correlationCloudId: nil, globallyUniqueIdResolution: .other, retryReplacement: nil, vanishedLocalMessageId: 3), .abandoned)
        // The vanished message itself is never its own replacement.
        XCTAssertEqual(sgCallRecordingResolveLeg(correlationCloudId: nil, globallyUniqueIdResolution: .local(id: 3), retryReplacement: (3, nil), vanishedLocalMessageId: 3), .abandoned)
    }

    func testRetryScanWindowDoesNotOverflow() {
        XCTAssertEqual(sgCallRecordingRetryScanIds(after: 10, window: 3), [11, 12, 13])
        XCTAssertEqual(sgCallRecordingRetryScanIds(after: Int32.max - 1, window: 5), [Int32.max])
        XCTAssertEqual(sgCallRecordingRetryScanIds(after: Int32.max, window: 5), [])
        XCTAssertEqual(sgCallRecordingRetryScanIds(after: 10, window: 0), [])
        XCTAssertEqual(sgCallRecordingRetryScanIds(after: 0).count, Int(sgCallRecordingRetryScanWindow))
    }

    func testUploadResourceIsDerivedFromTheAttempt() {
        XCTAssertEqual(sgCallRecordingResourceRandomId(correlationId: 123456789), 123456789)
        XCTAssertNotEqual(sgCallRecordingResourceRandomId(correlationId: 1), sgCallRecordingResourceRandomId(correlationId: 2))
    }

    func testOwnedAudioPathIsExact() {
        let directory = "/var/mobile/Containers/Data/Application/X/Library/Application Support/zenlygram-call-recordings"
        XCTAssertTrue(sgCallRecordingIsOwnedAudioPath(directory + "/rec.ogg", directory: directory, fileName: "rec.ogg"))
        XCTAssertTrue(sgCallRecordingIsOwnedAudioPath(directory + "/./rec.ogg", directory: directory, fileName: "rec.ogg"))
        XCTAssertFalse(sgCallRecordingIsOwnedAudioPath(directory + "-evil/rec.ogg", directory: directory, fileName: "rec.ogg"))
        XCTAssertFalse(sgCallRecordingIsOwnedAudioPath(directory + "/sub/../../rec.ogg", directory: directory, fileName: "rec.ogg"))
        XCTAssertFalse(sgCallRecordingIsOwnedAudioPath(directory + "/other.ogg", directory: directory, fileName: "rec.ogg"))
        XCTAssertFalse(sgCallRecordingIsOwnedAudioPath(directory + "/rec.ogg", directory: directory, fileName: ""))
        XCTAssertFalse(sgCallRecordingIsOwnedAudioPath(directory + "/rec.ogg", directory: directory, fileName: "../rec.ogg"))
    }
}

final class SGCallRecordingUploadSnapshotTests: XCTestCase {
    private final class Token {}

    private let postbox = Token()
    private let otherPostbox = Token()
    private let directory = "/var/mobile/Containers/Data/Application/X/Library/Application Support/zenlygram-call-recordings"

    private func snapshot(localMessageId: Int32?) -> SGCallRecordingUploadSnapshot {
        return SGCallRecordingUploadSnapshot(entries: [
            sgCallRecordingResourceRandomId(correlationId: 10): SGCallRecordingUploadAllowEntry(postboxIdentity: ObjectIdentifier(self.postbox), accountPeerId: 1, fileName: "rec.ogg", localMessageId: localMessageId)
        ])
    }

    private func request(postbox: AnyObject? = nil, account: Int64 = 1, peer: Int64 = 1, messagePeer: Int64 = 1, local: Bool = true, messageId: Int32 = 5, path: String? = nil, randomId: Int64 = 10) -> SGCallRecordingUploadRequestFacts {
        return SGCallRecordingUploadRequestFacts(postboxIdentity: ObjectIdentifier(postbox ?? self.postbox), accountPeerId: account, peerId: peer, messagePeerId: messagePeer, messageNamespaceIsLocal: local, messageId: messageId, localFilePath: path ?? (self.directory + "/rec.ogg"), resourceRandomId: randomId)
    }

    func testAllowsExactlyTheAllowedLeg() {
        XCTAssertTrue(self.snapshot(localMessageId: 5).allows(self.request()))
    }

    func testUnknownResourceIsDenied() {
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(randomId: 11)))
        XCTAssertFalse(SGCallRecordingUploadSnapshot().allows(self.request()))
    }

    func testOtherDatabaseOrAccountIsDenied() {
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(postbox: self.otherPostbox)))
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(account: 2, peer: 2, messagePeer: 2)))
    }

    func testOnlyTheAccountsOwnSavedMessagesInTheLocalNamespace() {
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(peer: 3, messagePeer: 3)))
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(messagePeer: 3)))
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(local: false)))
    }

    func testFileMustBeTheLegsOwnFileDirectlyInsideTheRecordingsDirectory() {
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(path: self.directory + "/other.ogg")))
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(path: self.directory + "/sub/rec.ogg")))
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(path: self.directory + "-x/rec.ogg")))
        XCTAssertFalse(self.snapshot(localMessageId: 5).allows(self.request(path: "rec.ogg")))
    }

    func testMessageIdMustBeTheKnownOneOrARetryCopyWithinTheWindow() {
        let snapshot = self.snapshot(localMessageId: 5)
        XCTAssertTrue(snapshot.allows(self.request(messageId: 6)))
        XCTAssertTrue(snapshot.allows(self.request(messageId: 5 + sgCallRecordingRetryScanWindow)))
        XCTAssertFalse(snapshot.allows(self.request(messageId: 6 + sgCallRecordingRetryScanWindow)))
        XCTAssertFalse(snapshot.allows(self.request(messageId: 4)))
    }

    func testUnboundAllowanceAcceptsAnyLocalIdWhileEnqueuing() {
        let snapshot = self.snapshot(localMessageId: nil)
        XCTAssertTrue(snapshot.allows(self.request(messageId: 1)))
        XCTAssertTrue(snapshot.allows(self.request(messageId: 99999)))
        // Everything else is still checked.
        XCTAssertFalse(snapshot.allows(self.request(postbox: self.otherPostbox, messageId: 1)))
        XCTAssertFalse(snapshot.allows(self.request(path: self.directory + "/other.ogg")))
    }

    func testUploadMayRunOnlyWithCurrentProof() {
        XCTAssertTrue(sgCallRecordingUploadMayRun(privacy: .open, exportAuthorized: false))
        XCTAssertTrue(sgCallRecordingUploadMayRun(privacy: .protected, exportAuthorized: true))
        XCTAssertFalse(sgCallRecordingUploadMayRun(privacy: .protected, exportAuthorized: false))
        // A locked relaunch: no verdict, no upload.
        XCTAssertFalse(sgCallRecordingUploadMayRun(privacy: .unverifiable, exportAuthorized: true))
    }
}

/// The gate-denial recovery driven through the same seams Delivery uses: the decider's verdicts
/// (`recordVerdict`), the ledger's durable mark (a real `SGCallRecordingDeliveryLedger`, re-opened
/// over the same bytes for a relaunch), the allowance snapshot the decider reads (a real
/// `SGCallRecordingUploadSnapshot`), `advance`'s observer decision and `handle`'s re-send decision.
/// One leg: correlation 10, local message 5, account 1. Not a runtime proof: no account, Postbox,
/// message or upload exists here.
final class SGCallRecordingGateDenialRecoveryTests: XCTestCase {
    private final class Token {}

    private let postbox = Token()
    private let recordingId = "1790000000-ABCDEF12"
    private let directory = "/var/mobile/Containers/Data/Application/X/Library/Application Support/zenlygram-call-recordings"

    private func seededStorage() -> FakeLedgerStorage {
        let storage = FakeLedgerStorage()
        var entry = makeEntry(account: 1, correlation: 10, local: 5)
        entry.accountRecordId = 100
        seed(storage, [self.recordingId: entry])
        return storage
    }

    /// What `advance` publishes once proof is re-validated, and `revokeUploads` takes away.
    private func allowed(_ correlationId: Int64) -> SGCallRecordingUploadSnapshot {
        return SGCallRecordingUploadSnapshot(entries: [
            sgCallRecordingResourceRandomId(correlationId: correlationId): SGCallRecordingUploadAllowEntry(postboxIdentity: ObjectIdentifier(self.postbox), accountPeerId: 1, fileName: "rec.ogg", localMessageId: 5)
        ])
    }

    /// The pending-message manager restarting the leg's upload (message 5).
    private func restartedUpload(_ correlationId: Int64) -> SGCallRecordingUploadRequestFacts {
        return SGCallRecordingUploadRequestFacts(postboxIdentity: ObjectIdentifier(self.postbox), accountPeerId: 1, peerId: 1, messagePeerId: 1, messageNamespaceIsLocal: true, messageId: 5, localFilePath: self.directory + "/rec.ogg", resourceRandomId: sgCallRecordingResourceRandomId(correlationId: correlationId))
    }

    /// The decider: its verdict for a restarted upload, recorded exactly as it returns it.
    @discardableResult
    private func gateVerdict(_ recovery: SGCallRecordingGateDenialRecovery, _ snapshot: SGCallRecordingUploadSnapshot, _ correlationId: Int64) -> Bool {
        let request = self.restartedUpload(correlationId)
        let allowed = snapshot.allows(request)
        recovery.recordVerdict(resourceRandomId: request.resourceRandomId, allowed: allowed)
        return allowed
    }

    private func durableMark(_ ledger: SGCallRecordingDeliveryLedger, _ correlationId: Int64) -> Bool? {
        guard case let .known(entry?) = ledger.lookup(recordingId: self.recordingId) else {
            return nil
        }
        return entry.facts(legIndex: 0, correlationId: correlationId)?.uploadGateDenied
    }

    /// `handle` seeing the leg's own message: the durable mark is written first, as Delivery does.
    private func observeMessage(_ recovery: SGCallRecordingGateDenialRecovery, _ ledger: SGCallRecordingDeliveryLedger, _ correlationId: Int64, failed: Bool) -> Bool {
        let current = self.durableMark(ledger, correlationId) ?? false
        let denial = recovery.durableDenial(correlationId: correlationId, current: current, messageFailed: failed)
        if denial != current {
            XCTAssertTrue(ledger.update(recordingId: self.recordingId) { entry in
                return entry?.updatingLeg(legIndex: 0, correlationId: correlationId) { facts in
                    var facts = facts
                    facts.uploadGateDenied = denial
                    return facts
                }
            })
        }
        return denial
    }

    /// Built the way `gateDeniedLeg` builds it, provenance read from the ledger entry.
    private func leg(_ correlationId: Int64, ledger: SGCallRecordingDeliveryLedger, snapshot: SGCallRecordingUploadSnapshot, fileReadable: Bool = true, durablyDenied: Bool? = nil, autoSendEnabled: Bool = true) -> SGCallRecordingGateDeniedLeg {
        var isAutomatic: Bool?
        if case let .known(entry?) = ledger.lookup(recordingId: self.recordingId) {
            isAutomatic = entry.isAutomatic
        }
        return SGCallRecordingGateDeniedLeg(
            correlationId: correlationId,
            durablyDenied: durablyDenied ?? (self.durableMark(ledger, correlationId) ?? false),
            uploadAllowed: snapshot.entries[sgCallRecordingResourceRandomId(correlationId: correlationId)] != nil,
            fileReadable: fileReadable,
            resendConsented: sgCallRecordingGateDeniedResendConsented(isAutomatic: isAutomatic, autoSendEnabled: autoSendEnabled)
        )
    }

    /// The re-send itself: a fresh attempt replaces the denied one in the ledger.
    private func resend(_ recovery: SGCallRecordingGateDenialRecovery, _ ledger: SGCallRecordingDeliveryLedger, old: Int64, fresh: Int64) {
        recovery.markResent(old: old, fresh: fresh)
        XCTAssertTrue(ledger.update(recordingId: self.recordingId) { entry in
            return entry?.updatingLeg(legIndex: 0, correlationId: fresh) { $0 }
        })
    }

    func testLockedDenialThenProofRestoredReevaluatesTheExistingObserverAndResendsOnce() {
        let storage = self.seededStorage()
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)
        let recovery = SGCallRecordingGateDenialRecovery()

        // Locked launch: no proof, so nothing is allowed and the restarted upload is denied.
        var snapshot = SGCallRecordingUploadSnapshot()
        XCTAssertFalse(self.gateVerdict(recovery, snapshot, 10))
        // The ledger-only observer sees the failed message; the sidecar is unreadable.
        let denial = self.observeMessage(recovery, ledger, 10, failed: true)
        XCTAssertTrue(denial)
        XCTAssertEqual(self.durableMark(ledger, 10), true)
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot, fileReadable: false), messageFailed: true, sidecarReadable: false))
        // Nothing re-sendable yet, so `advance` keeps the observer.
        XCTAssertFalse(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot, fileReadable: false)]))

        // Unlock: `advance` re-validates and grants the allowance. The existing observer will not
        // report the unchanged failed message again, so it must be restarted.
        snapshot = self.allowed(10)
        XCTAssertTrue(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot)]))
        // The restarted observer reports the same failed message: re-sent.
        XCTAssertTrue(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot), messageFailed: true, sidecarReadable: true))
        self.resend(recovery, ledger, old: 10, fresh: 11)

        // Every later resume: no restart and no second re-send of either attempt.
        XCTAssertFalse(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot, durablyDenied: true)]))
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot, durablyDenied: true), messageFailed: true, sidecarReadable: true))
        let freshSnapshot = self.allowed(11)
        XCTAssertFalse(recovery.observerMustReevaluate([self.leg(11, ledger: ledger, snapshot: freshSnapshot)]))
        XCTAssertFalse(recovery.shouldResend(self.leg(11, ledger: ledger, snapshot: freshSnapshot), messageFailed: true, sidecarReadable: true))
    }

    func testRepeatedResumesBeforeTheObserverReportsStillResendOnce() {
        let ledger = SGCallRecordingDeliveryLedger(storage: self.seededStorage())
        let recovery = SGCallRecordingGateDenialRecovery()
        self.gateVerdict(recovery, SGCallRecordingUploadSnapshot(), 10)
        _ = self.observeMessage(recovery, ledger, 10, failed: true)
        let snapshot = self.allowed(10)

        // protectedDataDidBecomeAvailable and didBecomeActive back to back: two restarts.
        XCTAssertTrue(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot)]))
        XCTAssertTrue(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot)]))
        // Reports: the first re-sends, every other one is refused.
        var resends = 0
        for _ in 0 ..< 3 where recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot), messageFailed: true, sidecarReadable: true) {
            resends += 1
            self.resend(recovery, ledger, old: 10, fresh: 11)
        }
        XCTAssertEqual(resends, 1)
    }

    func testDenialSurvivesARelaunchAndIsResentOnceThere() {
        let storage = self.seededStorage()
        do {
            // Process A: denied while locked, failure seen, killed before proof returned.
            let ledger = SGCallRecordingDeliveryLedger(storage: storage)
            let recovery = SGCallRecordingGateDenialRecovery()
            self.gateVerdict(recovery, SGCallRecordingUploadSnapshot(), 10)
            _ = self.observeMessage(recovery, ledger, 10, failed: true)
        }

        // Process B: no verdict in memory (a failed message is not restarted); only the ledger knows.
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)
        let recovery = SGCallRecordingGateDenialRecovery()
        XCTAssertNil(recovery.lastVerdict(correlationId: 10))
        XCTAssertEqual(self.durableMark(ledger, 10), true)
        // The failure is seen again; no verdict means the durable mark stands.
        XCTAssertTrue(self.observeMessage(recovery, ledger, 10, failed: true))
        let snapshot = self.allowed(10)
        XCTAssertTrue(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot), messageFailed: true, sidecarReadable: true))
        self.resend(recovery, ledger, old: 10, fresh: 11)
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot, durablyDenied: true), messageFailed: true, sidecarReadable: true))

        // Process C: the re-sent attempt replaced the denied one; its mark went with it.
        let relaunched = SGCallRecordingDeliveryLedger(storage: storage)
        XCTAssertNil(self.durableMark(relaunched, 10))
        XCTAssertEqual(self.durableMark(relaunched, 11), false)
        let afterRelaunch = SGCallRecordingGateDenialRecovery()
        XCTAssertFalse(afterRelaunch.shouldResend(self.leg(11, ledger: relaunched, snapshot: self.allowed(11)), messageFailed: true, sidecarReadable: true))
    }

    func testStillDeniedProofResendsNothing() {
        let storage = self.seededStorage()
        do {
            let ledger = SGCallRecordingDeliveryLedger(storage: storage)
            let recovery = SGCallRecordingGateDenialRecovery()
            self.gateVerdict(recovery, SGCallRecordingUploadSnapshot(), 10)
            _ = self.observeMessage(recovery, ledger, 10, failed: true)
        }
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)
        let recovery = SGCallRecordingGateDenialRecovery()
        let none = SGCallRecordingUploadSnapshot()

        // Protection still unverifiable / peer protected without a grant / account signed out /
        // other database: `advance` grants nothing.
        XCTAssertFalse(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: none)]))
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: none), messageFailed: true, sidecarReadable: true))
        // A native restart in this state is denied again, and the mark stays.
        XCTAssertFalse(self.gateVerdict(recovery, none, 10))
        XCTAssertTrue(self.observeMessage(recovery, ledger, 10, failed: true))
        // Allowed, but the sidecar is unreadable or the audio file cannot be opened: still nothing.
        let snapshot = self.allowed(10)
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot), messageFailed: true, sidecarReadable: false))
        XCTAssertFalse(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot, fileReadable: false)]))
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot, fileReadable: false), messageFailed: true, sidecarReadable: true))
        // The message is not failed (yet): nothing.
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot), messageFailed: false, sidecarReadable: true))
    }

    func testAllowanceRevokedBeforeTheRestartedObserverReportsResendsNothing() {
        let ledger = SGCallRecordingDeliveryLedger(storage: self.seededStorage())
        let recovery = SGCallRecordingGateDenialRecovery()
        self.gateVerdict(recovery, SGCallRecordingUploadSnapshot(), 10)
        _ = self.observeMessage(recovery, ledger, 10, failed: true)
        var snapshot = self.allowed(10)
        XCTAssertTrue(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot)]))

        // Vaulted / locked peer, account removal, cancel or retirement: `revokeUploads`.
        snapshot.entries.removeValue(forKey: sgCallRecordingResourceRandomId(correlationId: 10))
        XCTAssertFalse(snapshot.allows(self.restartedUpload(10)))
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot), messageFailed: true, sidecarReadable: true))
        XCTAssertFalse(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot)]))
        // Nothing was consumed: proof returning later still recovers it once.
        XCTAssertTrue(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: self.allowed(10)), messageFailed: true, sidecarReadable: true))
    }

    func testOrdinaryFailuresAreNeverTreatedAsGateDenials() {
        let storage = self.seededStorage()
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)
        let snapshot = self.allowed(10)

        // No verdict and no mark: a failure of unknown cause (or one from before this build).
        let unknown = SGCallRecordingGateDenialRecovery()
        XCTAssertFalse(self.observeMessage(unknown, ledger, 10, failed: true))
        XCTAssertFalse(unknown.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot), messageFailed: true, sidecarReadable: true))
        XCTAssertFalse(unknown.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot)]))

        // Allowed, then failed (network, server): ordinary.
        let allowedThenFailed = SGCallRecordingGateDenialRecovery()
        XCTAssertTrue(self.gateVerdict(allowedThenFailed, snapshot, 10))
        XCTAssertFalse(self.observeMessage(allowedThenFailed, ledger, 10, failed: true))
        XCTAssertFalse(allowedThenFailed.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot), messageFailed: true, sidecarReadable: true))

        // Denied and marked, then let through by a later upload (Telegram's own Retry once proof
        // was back), then failed: the allow clears the mark durably.
        let recovery = SGCallRecordingGateDenialRecovery()
        self.gateVerdict(recovery, SGCallRecordingUploadSnapshot(), 10)
        XCTAssertTrue(self.observeMessage(recovery, ledger, 10, failed: true))
        XCTAssertTrue(self.gateVerdict(recovery, snapshot, 10))
        XCTAssertFalse(self.observeMessage(recovery, ledger, 10, failed: false))
        XCTAssertEqual(self.durableMark(ledger, 10), false)
        XCTAssertFalse(self.observeMessage(recovery, ledger, 10, failed: true))
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot), messageFailed: true, sidecarReadable: true))
        // A relaunch reads the cleared mark: still not a denial.
        let relaunched = SGCallRecordingGateDenialRecovery()
        let relaunchedLedger = SGCallRecordingDeliveryLedger(storage: storage)
        XCTAssertEqual(self.durableMark(relaunchedLedger, 10), false)
        XCTAssertFalse(relaunched.shouldResend(self.leg(10, ledger: relaunchedLedger, snapshot: snapshot), messageFailed: true, sidecarReadable: true))
    }

    func testDenialWithoutAFailureSeenIsNotWrittenDown() {
        let ledger = SGCallRecordingDeliveryLedger(storage: self.seededStorage())
        let recovery = SGCallRecordingGateDenialRecovery()
        self.gateVerdict(recovery, SGCallRecordingUploadSnapshot(), 10)
        XCTAssertFalse(self.observeMessage(recovery, ledger, 10, failed: false))
        XCTAssertEqual(self.durableMark(ledger, 10), false)
    }

    func testAutomaticLegIsNotResentOnceTheSettingIsOffEvenForAPartlyAcknowledgedLegacyPair() {
        // A legacy (pre-mix) AUTOMATIC pair: leg 1 acknowledged, leg 0 denied while locked.
        let storage = FakeLedgerStorage()
        seed(storage, [self.recordingId: SGCallRecordingDeliveryEntry(accountPeerId: 1, accountRecordId: 100, exportAuthorized: false, isAutomatic: true, legCount: 2, legs: [
            SGCallRecordingDeliveryLegFacts(legIndex: 0, correlationId: 10, localMessageId: 5),
            SGCallRecordingDeliveryLegFacts(legIndex: 1, correlationId: 20, localMessageId: 6, cloudMessageId: 900)
        ])])
        let ledger = SGCallRecordingDeliveryLedger(storage: storage)
        let recovery = SGCallRecordingGateDenialRecovery()
        self.gateVerdict(recovery, SGCallRecordingUploadSnapshot(), 10)
        XCTAssertTrue(self.observeMessage(recovery, ledger, 10, failed: true))
        // Something of it was handed to Telegram, so turning the setting off does not withdraw it:
        // the re-send decision is the only thing that can keep the other leg from going up.
        XCTAssertFalse(sgCallRecordingAutoOffWithdraws(isAutomatic: true, autoSendEnabled: false, anyLegEnqueued: true))

        let snapshot = self.allowed(10)
        XCTAssertFalse(recovery.observerMustReevaluate([self.leg(10, ledger: ledger, snapshot: snapshot, autoSendEnabled: false)]))
        XCTAssertFalse(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot, autoSendEnabled: false), messageFailed: true, sidecarReadable: true))
        // Refusing consumed nothing and forgot nothing.
        XCTAssertEqual(self.durableMark(ledger, 10), true)
        // The setting turned back on is consent again.
        XCTAssertTrue(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: snapshot, autoSendEnabled: true), messageFailed: true, sidecarReadable: true))
    }

    func testManualDeliveryIsResentWhateverTheAutomaticSetting() {
        let ledger = SGCallRecordingDeliveryLedger(storage: self.seededStorage())
        let recovery = SGCallRecordingGateDenialRecovery()
        self.gateVerdict(recovery, SGCallRecordingUploadSnapshot(), 10)
        _ = self.observeMessage(recovery, ledger, 10, failed: true)
        XCTAssertTrue(recovery.shouldResend(self.leg(10, ledger: ledger, snapshot: self.allowed(10), autoSendEnabled: false), messageFailed: true, sidecarReadable: true))
    }

    func testResendConsent() {
        XCTAssertTrue(sgCallRecordingGateDeniedResendConsented(isAutomatic: false, autoSendEnabled: false))
        XCTAssertTrue(sgCallRecordingGateDeniedResendConsented(isAutomatic: false, autoSendEnabled: true))
        XCTAssertTrue(sgCallRecordingGateDeniedResendConsented(isAutomatic: true, autoSendEnabled: true))
        XCTAssertFalse(sgCallRecordingGateDeniedResendConsented(isAutomatic: true, autoSendEnabled: false))
        // No ledger entry: provenance unknown, never consent.
        XCTAssertFalse(sgCallRecordingGateDeniedResendConsented(isAutomatic: nil, autoSendEnabled: true))
    }

    func testDurableMarkDecodesFromOlderLedgersAndRoundTrips() throws {
        let older = try JSONDecoder().decode(SGCallRecordingDeliveryLegFacts.self, from: Data(#"{"legIndex":0,"correlationId":10,"localMessageId":5}"#.utf8))
        XCTAssertEqual(older, SGCallRecordingDeliveryLegFacts(legIndex: 0, correlationId: 10, localMessageId: 5))
        XCTAssertFalse(older.uploadGateDenied)

        let marked = SGCallRecordingDeliveryLegFacts(legIndex: 0, correlationId: 10, localMessageId: 5, uploadGateDenied: true)
        let decoded = try JSONDecoder().decode(SGCallRecordingDeliveryLegFacts.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(decoded, marked)
    }
}

/// `resumeAll`'s second pass: which recordings it advances although their sidecar is not readable.
final class SGCallRecordingLedgerOnlyResumeTests: XCTestCase {
    private func entry(local: Int32?, cloud: Int32? = nil, retiring: Bool = false) -> SGCallRecordingDeliveryEntry {
        return makeEntry(account: 1, correlation: 10, local: local, cloud: cloud, retiring: retiring)
    }

    private func key(_ id: String) -> String {
        return SGCallRecordingDeliveryLedger.key(recordingId: id)
    }

    func testLockedAndCorruptSidecarsWithAnUnacknowledgedMessageAreAdvanced() {
        let entries = [self.key("locked"): self.entry(local: 5), self.key("corrupt"): self.entry(local: 6)]
        XCTAssertEqual(sgCallRecordingLedgerOnlyResumeIds(sidecars: [("locked", .lockedUnreadable), ("corrupt", .corrupt)], entries: entries), ["locked", "corrupt"])
    }

    func testUnreadableLedgerAdvancesNothing() {
        XCTAssertEqual(sgCallRecordingLedgerOnlyResumeIds(sidecars: [("locked", .lockedUnreadable)], entries: nil), [])
    }

    func testOnlyDeliveriesTheLedgerSaysAreOnTheirWay() {
        let entries = [
            self.key("retiring"): self.entry(local: 5, retiring: true),
            self.key("acknowledged"): self.entry(local: 5, cloud: 900),
            self.key("neverEnqueued"): self.entry(local: nil)
        ]
        let sidecars: [(id: String, condition: SGCallRecordingSidecarCondition)] = [
            ("retiring", .lockedUnreadable),
            ("acknowledged", .lockedUnreadable),
            ("neverEnqueued", .lockedUnreadable),
            ("noEntry", .lockedUnreadable)
        ]
        XCTAssertEqual(sgCallRecordingLedgerOnlyResumeIds(sidecars: sidecars, entries: entries), [])
    }

    func testReadableAndGoneSidecarsAreLeftToTheirOwnPaths() {
        let entries = [self.key("readable"): self.entry(local: 5), self.key("gone"): self.entry(local: 6)]
        // Readable: `pendingSends` already advanced it. Gone: retirement owns it.
        XCTAssertEqual(sgCallRecordingLedgerOnlyResumeIds(sidecars: [("readable", .readable(hasSendRecord: true)), ("gone", .gone)], entries: entries), [])
    }

    func testEachRecordingAtMostOnceInInputOrder() {
        let entries = [self.key("a"): self.entry(local: 5), self.key("b"): self.entry(local: 6)]
        XCTAssertEqual(sgCallRecordingLedgerOnlyResumeIds(sidecars: [("b", .lockedUnreadable), ("a", .corrupt), ("b", .lockedUnreadable)], entries: entries), ["b", "a"])
    }
}
