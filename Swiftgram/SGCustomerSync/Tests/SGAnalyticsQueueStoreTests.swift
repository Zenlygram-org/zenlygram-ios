import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the on-disk event queue (design 40 §10.5, contract §6.5): per (origin, account)
/// paths, the line format, the bounds (5000 events / 2 MiB / 7 days, oldest first), a torn last
/// line, atomic rewrites, backup exclusion, the purge across origins, and no write while unreadable.
final class SGAnalyticsQueueStoreTests: XCTestCase {
    private let tg: Int64 = 555_000_111
    private let token = "8d6f0c1e2b"
    /// 2026-11-01T10:00:00Z.
    private let start = Date(timeIntervalSince1970: 1_793_527_200)

    private var directory: URL!
    private var removeDirectory: (() -> Void)?
    private var now = Date(timeIntervalSince1970: 1_793_527_200)
    private var readable = true
    private let ids = SGAnalyticsTestSamples.Ids()

    override func setUp() {
        super.setUp()
        let made = SGCustomerSyncTestFixtures.makeDirectory()
        self.directory = made.url
        self.removeDirectory = made.remove
        self.now = self.start
        self.readable = true
    }

    override func tearDown() {
        self.removeDirectory?()
        super.tearDown()
    }

    func testTheDefaultBounds() {
        XCTAssertEqual(SGAnalyticsQueueStore.maxEvents, 5000)
        XCTAssertEqual(SGAnalyticsQueueStore.maxBytes, 2 * 1024 * 1024)
        XCTAssertEqual(SGAnalyticsQueueStore.maxAge, 7 * 24 * 3600)
        XCTAssertEqual(SGAnalyticsQueueStore.Limits.standard, SGAnalyticsQueueStore.Limits(maxEvents: 5000, maxBytes: 2_097_152))
    }

    func testPathsArePerOriginAndAccountAndExcludedFromBackup() throws {
        let store = try XCTUnwrap(self.makeStore())
        XCTAssertEqual(store.directoryURL.lastPathComponent, "zenlygram-customer.o-8d6f0c1e2b")
        XCTAssertEqual(store.directoryURL.deletingLastPathComponent().standardizedFileURL, self.directory.standardizedFileURL)
        XCTAssertEqual(store.eventsURL(tg: self.tg).lastPathComponent, "events-555000111.jsonl")
        XCTAssertEqual(store.sessionsURL(tg: self.tg).lastPathComponent, "sessions-555000111.json")
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: self.event()))
        let values = try store.directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        // The protection class every write uses (the simulator and the Mac do not enforce it).
        XCTAssertEqual(SGAnalyticsQueueStore.fileProtection, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(SGAnalyticsQueueStore.writingProtection, .completeFileProtectionUntilFirstUserAuthentication)
        for token in ["", "../up", "A1", "token/x", String(repeating: "a", count: 129)] {
            XCTAssertNil(SGAnalyticsQueueStore(baseURL: self.directory, storageToken: token, isReadable: { true }), token)
        }
    }

    func testTheLineFormat() throws {
        let store = try XCTUnwrap(self.makeStore())
        let first = self.event()
        let second = self.event(ts: "2026-11-01T09:59:00Z")
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: first))
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: second))
        let text = String(decoding: try Data(contentsOf: store.eventsURL(tg: self.tg)), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 4, "context, event, event, and the final newline")
        XCTAssertEqual(lines.last, "")
        let context = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8), options: []) as? [String: Any])
        XCTAssertEqual(context["k"] as? String, "c")
        XCTAssertEqual(context["id"] as? String, self.context().id)
        XCTAssertEqual((context["id"] as? String)?.count, 16)
        SGCustomerSyncTestFixtures.assertJSON(self.context().encoded(), equals: context["context"])
        let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1].utf8), options: []) as? [String: Any])
        XCTAssertEqual(event["k"] as? String, "e")
        XCTAssertEqual(event["c"] as? String, self.context().id)
        XCTAssertEqual(SGCustomerJSON.integer(event["at"]), 1_793_527_140, "the event's ts in Unix seconds")
        SGCustomerSyncTestFixtures.assertJSON(first.encoded(), equals: event["event"])
        XCTAssertTrue(lines[2].hasPrefix("{\"k\":\"e\""), "a known context is not written again")

        // A second store (the next launch) reads the same queue.
        let reread = try XCTUnwrap(self.makeStore())
        XCTAssertEqual(reread.entries(tg: self.tg).map(\.id), [first.id, second.id])
        XCTAssertEqual(reread.entries(tg: self.tg).map(\.event), [first.encoded(), second.encoded()])
        XCTAssertEqual(reread.context(tg: self.tg, id: self.context().id), self.context().encoded())
    }

    func testTheEventBoundDropsTheOldestFirst() throws {
        let store = try XCTUnwrap(self.makeStore(limits: SGAnalyticsQueueStore.Limits(maxEvents: 50, maxBytes: SGAnalyticsQueueStore.maxBytes)))
        var appended: [String] = []
        for _ in 0 ..< 51 {
            let event = self.event()
            appended.append(event.id)
            XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: event))
            XCTAssertLessThanOrEqual(store.count(tg: self.tg), 50)
        }
        XCTAssertEqual(store.entries(tg: self.tg).map(\.id), Array(appended.suffix(45)), "trimmed to 90 % of the bound, the oldest gone")
        XCTAssertEqual(try XCTUnwrap(self.makeStore()).entries(tg: self.tg).map(\.id), Array(appended.suffix(45)), "and so is the file")
    }

    func testTheByteBoundDropsTheOldestFirst() throws {
        let limits = SGAnalyticsQueueStore.Limits(maxEvents: 5000, maxBytes: 16 * 1024)
        let store = try XCTUnwrap(self.makeStore(limits: limits))
        var appended: [String] = []
        for _ in 0 ..< 60 {
            let event = self.event(payload: SGAnalyticsTestSamples.largestEvents()[0].payload)
            appended.append(event.id)
            XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: event))
            let size = try Data(contentsOf: store.eventsURL(tg: self.tg)).count
            XCTAssertLessThanOrEqual(size, limits.maxBytes)
        }
        let kept = store.entries(tg: self.tg).map(\.id)
        XCTAssertLessThan(kept.count, 60)
        XCTAssertEqual(kept, Array(appended.suffix(kept.count)), "only the newest are left")
    }

    func testEventsOlderThanSevenDaysAreDropped() throws {
        let store = try XCTUnwrap(self.makeStore())
        let old = self.event(ts: "2026-10-25T10:00:00Z")
        let recent = self.event(ts: "2026-10-31T10:00:00Z")
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: old))
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: recent))
        XCTAssertEqual(store.count(tg: self.tg), 2, "exactly seven days old is kept")
        self.now = self.start.addingTimeInterval(1)
        XCTAssertEqual(store.entries(tg: self.tg).map(\.id), [recent.id])
        XCTAssertEqual(try XCTUnwrap(self.makeStore()).entries(tg: self.tg).map(\.id), [recent.id], "a reload drops it too")
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: self.event()))
        let lines = String(decoding: try Data(contentsOf: store.eventsURL(tg: self.tg)), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "the next append rewrote the file without the expired event")
    }

    func testATornLastLineIsSkippedAndRepaired() throws {
        let store = try XCTUnwrap(self.makeStore())
        let kept = self.event()
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: kept))
        let url = store.eventsURL(tg: self.tg)
        var data = try Data(contentsOf: url)
        data.append(Data("{\"k\":\"e\",\"c\":\"\(self.context().id)\",\"at\":1793527140,\"event\":{\"id\":\"".utf8))
        try data.write(to: url)

        let reloaded = try XCTUnwrap(self.makeStore())
        XCTAssertEqual(reloaded.entries(tg: self.tg).map(\.id), [kept.id], "the torn line is skipped")
        let next = self.event()
        XCTAssertTrue(reloaded.append(tg: self.tg, context: self.context(), event: next))
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"))
        for line in text.split(separator: "\n") {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8), options: []), "every line parses after the repair: \(line)")
        }
        XCTAssertEqual(try XCTUnwrap(self.makeStore()).entries(tg: self.tg).map(\.id), [kept.id, next.id])
    }

    func testAnInvalidLineIsSkipped() throws {
        let store = try XCTUnwrap(self.makeStore())
        let kept = self.event()
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: kept))
        let url = store.eventsURL(tg: self.tg)
        var data = try Data(contentsOf: url)
        // An event this build would never write (a prop outside the registry), and an unknown context.
        let forged = "{\"k\":\"e\",\"c\":\"\(self.context().id)\",\"at\":1793527140,\"event\":{\"id\":\"\(self.ids.make())\",\"name\":\"screen.view\",\"props\":{\"screen\":\"zg.hub\",\"chat_title\":\"Family\"},\"seq\":1,\"session_id\":\"\(self.ids.make())\",\"ts\":\"2026-11-01T09:59:00Z\"}}\n"
        data.append(Data(forged.utf8))
        data.append(Data("{\"k\":\"e\",\"c\":\"0123456789abcdef\",\"at\":1793527140,\"event\":\(String(decoding: self.event().encoded(), as: UTF8.self))}\n".utf8))
        try data.write(to: url)
        XCTAssertEqual(try XCTUnwrap(self.makeStore()).entries(tg: self.tg).map(\.id), [kept.id])
    }

    func testRemovalRewritesTheFileAtomically() throws {
        let store = try XCTUnwrap(self.makeStore())
        let events = (0 ..< 5).map { _ in self.event() }
        for event in events {
            XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: event))
        }
        XCTAssertTrue(store.remove(tg: self.tg, ids: [events[0].id, events[2].id]))
        XCTAssertEqual(store.entries(tg: self.tg).map(\.id), [events[1].id, events[3].id, events[4].id])
        XCTAssertEqual(try XCTUnwrap(self.makeStore()).entries(tg: self.tg).map(\.id), [events[1].id, events[3].id, events[4].id])
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)
        XCTAssertEqual(Set(names), ["events-555000111.jsonl"], "no temp file is left behind")
        XCTAssertTrue(store.remove(tg: self.tg, ids: Set(events.map(\.id))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.eventsURL(tg: self.tg).path), "an empty queue has no file")
    }

    func testAContextChangeInternsANewContext() throws {
        let store = try XCTUnwrap(self.makeStore())
        var facts = SGAnalyticsTestSamples.iPhoneFacts
        let first = SGAnalyticsContext(facts: facts)
        facts.appVersion = "12.0.2"
        let second = SGAnalyticsContext(facts: facts)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(store.append(tg: self.tg, context: first, event: self.event()))
        XCTAssertTrue(store.append(tg: self.tg, context: second, event: self.event()))
        XCTAssertTrue(store.append(tg: self.tg, context: first, event: self.event()))
        XCTAssertEqual(store.entries(tg: self.tg).map(\.contextId), [first.id, second.id, first.id])
        let reread = try XCTUnwrap(self.makeStore())
        XCTAssertEqual(reread.context(tg: self.tg, id: second.id), second.encoded())
    }

    func testNothingIsReadOrWrittenWhileUnreadable() throws {
        let store = try XCTUnwrap(self.makeStore())
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: self.event()))
        XCTAssertTrue(store.setSession(SGAnalyticsSessionMarker(sessionId: self.ids.make(), seq: 3), tg: self.tg))
        let before = try Data(contentsOf: store.eventsURL(tg: self.tg))

        let locked = try XCTUnwrap(self.makeStore())
        self.readable = false
        XCTAssertFalse(locked.append(tg: self.tg, context: self.context(), event: self.event()))
        XCTAssertEqual(locked.count(tg: self.tg), 0, "an unreadable queue reads as empty")
        XCTAssertEqual(locked.entries(tg: self.tg), [])
        XCTAssertNil(locked.session(tg: self.tg))
        XCTAssertFalse(locked.setSession(SGAnalyticsSessionMarker(sessionId: self.ids.make(), seq: 9), tg: self.tg))
        XCTAssertFalse(locked.remove(tg: self.tg, ids: []))
        XCTAssertNil(locked.queueOwners())
        XCTAssertFalse(store.append(tg: self.tg, context: self.context(), event: self.event()), "also for a store that read the queue before")
        XCTAssertEqual(try Data(contentsOf: store.eventsURL(tg: self.tg)), before, "nothing was written")
        self.readable = true
        XCTAssertEqual(locked.count(tg: self.tg), 1, "readable again: the queue as it was")
        XCTAssertEqual(locked.session(tg: self.tg)?.seq, 3)
    }

    func testPurgeRemovesTheAccountUnderEveryOriginAndBumpsTheGeneration() throws {
        let store = try XCTUnwrap(self.makeStore())
        let other = try XCTUnwrap(SGAnalyticsQueueStore(baseURL: self.directory, storageToken: "0a1b2c", isReadable: { true }, now: { [unowned self] in self.now }))
        let otherTg: Int64 = 555_000_222
        XCTAssertTrue(store.append(tg: self.tg, context: self.context(), event: self.event()))
        XCTAssertTrue(store.setSession(SGAnalyticsSessionMarker(sessionId: self.ids.make(), seq: 0), tg: self.tg))
        XCTAssertTrue(other.append(tg: self.tg, context: self.context(), event: self.event()))
        XCTAssertTrue(store.append(tg: otherTg, context: self.context(), event: self.event()))
        XCTAssertEqual(store.queueOwners(), [self.tg, otherTg])
        let generation = store.generation(tg: self.tg)
        XCTAssertTrue(store.purge(tg: self.tg))
        XCTAssertEqual(store.generation(tg: self.tg), generation + 1)
        XCTAssertEqual(store.count(tg: self.tg), 0)
        XCTAssertNil(store.session(tg: self.tg))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.eventsURL(tg: self.tg).path), "the other origin's queue of the account went too")
        XCTAssertEqual(store.count(tg: otherTg), 1, "another account is untouched")
        XCTAssertEqual(store.queueOwners(), [otherTg])
        self.readable = false
        XCTAssertTrue(store.purge(tg: otherTg), "deleting needs no readable protection class")
        self.readable = true
        XCTAssertEqual(store.queueOwners(), [])
    }

    func testTheSessionsSidecar() throws {
        let store = try XCTUnwrap(self.makeStore())
        XCTAssertNil(store.session(tg: self.tg))
        let marker = SGAnalyticsSessionMarker(sessionId: self.ids.make(), seq: 12)
        XCTAssertTrue(store.setSession(marker, tg: self.tg))
        XCTAssertEqual(try XCTUnwrap(self.makeStore()).session(tg: self.tg), marker)
        SGCustomerSyncTestFixtures.assertJSON(try Data(contentsOf: store.sessionsURL(tg: self.tg)), equals: ["v": 1, "session_id": marker.sessionId, "seq": 12])
        XCTAssertFalse(store.setSession(SGAnalyticsSessionMarker(sessionId: "not-a-uuid", seq: 1), tg: self.tg))
        XCTAssertFalse(store.setSession(SGAnalyticsSessionMarker(sessionId: self.ids.make(), seq: 1_000_001), tg: self.tg))
        try Data("{\"v\":1,\"session_id\":\"x\",\"seq\":1}".utf8).write(to: store.sessionsURL(tg: self.tg))
        XCTAssertNil(store.session(tg: self.tg), "a malformed sidecar reads as none")
    }

    // MARK: - Helpers

    private func makeStore(limits: SGAnalyticsQueueStore.Limits = .standard) -> SGAnalyticsQueueStore? {
        return SGAnalyticsQueueStore(baseURL: self.directory, storageToken: self.token, isReadable: { [unowned self] in self.readable }, now: { [unowned self] in self.now }, fileManager: .default, limits: limits)
    }

    private func context() -> SGAnalyticsContext {
        return SGAnalyticsContext(facts: SGAnalyticsTestSamples.iPhoneFacts)
    }

    private func event(ts: String = "2026-11-01T09:59:00Z", payload: SGAnalyticsPayload = SGAnalyticsEvent.vaultChatAdded.payload) -> SGAnalyticsWireEvent {
        return SGAnalyticsWireEvent(id: self.ids.make(), ts: ts, sessionId: "88375902-7c42-43a8-9066-aba2d6d2d42a", seq: 1, payload: payload)
    }
}
