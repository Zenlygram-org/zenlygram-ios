import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the analytics pipeline (design 40 §10.1, §10.3–10.4; contract §3.3, §3.6): the
/// accounts table and attribution, sessions and `seq`, the per-session dedup and aggregation, the
/// sessions sidecar, the batch hand-out and the purge fence; and the facade in front of it.
final class SGAnalyticsPipelineTests: XCTestCase {
    private let alice: Int64 = 0x0000_0001_2345_6789
    private let aliceTg: Int64 = 555_000_111
    private let bob: Int64 = 0x0000_0001_2345_0000
    private let bobTg: Int64 = 555_000_222
    /// 2026-11-01T09:30:00Z.
    private let start = Date(timeIntervalSince1970: 1_793_525_400)

    private var directory: URL!
    private var removeDirectory: (() -> Void)?
    private var now = Date(timeIntervalSince1970: 1_793_525_400)
    private var uptime: TimeInterval = 1000
    private var readable = true
    private var ids = SGAnalyticsTestSamples.Ids()
    private var store: SGAnalyticsQueueStore!
    private var pipeline: SGAnalyticsPipeline!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let made = SGCustomerSyncTestFixtures.makeDirectory()
        self.directory = made.url
        self.removeDirectory = made.remove
        self.now = self.start
        self.uptime = 1000
        self.readable = true
        self.ids = SGAnalyticsTestSamples.Ids()
        self.store = try XCTUnwrap(self.makeStore())
        self.pipeline = self.makePipeline(self.store)
        SGAnalytics.resetForTesting()
    }

    override func tearDown() {
        SGAnalytics.resetForTesting()
        SGAnalytics.uptime = { ProcessInfo.processInfo.systemUptime }
        SGAnalytics.clock = { Date() }
        SGAnalytics.isExtensionProcess = { Bundle.main.bundlePath.hasSuffix(".appex") }
        self.pipeline = nil
        self.store = nil
        self.removeDirectory?()
        super.tearDown()
    }

    // MARK: - Attribution

    func testAnAccountWithoutRecordEventsRecordsNothing() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.pipeline.sessionStart(accountPeerId: self.bob, trigger: .launch, at: self.now)
        self.record(.vaultChatAdded, account: self.bob)
        self.record(.vaultChatRemoved, account: nil)
        XCTAssertEqual(self.names(self.bobTg), [], "no session and no event for an account without recordEvents")
        XCTAssertEqual(self.names(self.aliceTg), ["app.session_start", "vault.chat_removed"], "nil = the active account")
    }

    func testAnExplicitAccountIsNeverReattributed() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        let stranger: Int64 = 42
        self.record(.vaultChatAdded, account: stranger)
        self.record(.vaultChatAdded, account: self.bob)
        self.pipeline.receive(.error(.vault, .unknown), accountPeerId: self.bob, at: self.now)
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .background, at: self.now)
        XCTAssertEqual(self.names(self.aliceTg), ["app.session_start", "app.session_end"], "neither event reached the active account")
        XCTAssertEqual(self.names(self.bobTg), [])
    }

    func testWithdrawalStopsRecordingAtOnce() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.record(.vaultChatAdded, account: nil)
        self.configure(aliceRecords: false, bobRecords: false, active: self.alice)
        self.record(.vaultChatRemoved, account: nil)
        self.pipeline.receive(.error(.network, .timeout), accountPeerId: nil, at: self.now)
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .background, at: self.now)
        XCTAssertEqual(self.names(self.aliceTg), ["app.session_start", "vault.chat_added"], "nothing after the clearance went; the session state was dropped")
    }

    func testCallsBeforeTheTablesAreSetWaitInOrder() {
        self.record(.vaultChatAdded, account: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.record(.vaultChatRemoved, account: self.alice)
        self.pipeline.waitUntilIdle()
        XCTAssertEqual(self.names(self.aliceTg), [])
        self.pipeline.setAccounts([SGAnalyticsPipeline.Account(accountPeerId: self.alice, tg: self.aliceTg, recordingAllowed: true)], activeAccountPeerId: self.alice)
        XCTAssertEqual(self.names(self.aliceTg), [], "the context is still missing")
        self.pipeline.setContext(SGAnalyticsContext(facts: SGAnalyticsTestSamples.iPhoneFacts))
        XCTAssertEqual(self.names(self.aliceTg), ["app.session_start", "vault.chat_removed"], "the first event had no session yet; the rest ran in order")
    }

    // MARK: - Sessions and seq

    func testSeqStartsAtZeroAndStrictlyIncreasesPerSession() throws {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.record(.vaultChatAdded, account: nil)
        self.record(.chatLockLockRemoved, account: nil)
        self.uptime += 840
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .background, at: self.now.addingTimeInterval(840))
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .foreground, at: self.now.addingTimeInterval(900))
        self.record(.vaultChatRemoved, account: nil)
        let events = self.events(self.aliceTg)
        XCTAssertEqual(events.map(\.name), ["app.session_start", "vault.chat_added", "chat_lock.lock_removed", "app.session_end", "app.session_start", "vault.chat_removed"])
        let first = events[0].sessionId
        let second = events[4].sessionId
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(events.map(\.seq), [0, 1, 2, 3, 0, 1])
        XCTAssertEqual(events.map(\.sessionId), [first, first, first, first, second, second])
        XCTAssertEqual(events[0].props["trigger"] as? String, "launch")
        XCTAssertEqual(events[3].props["reason"] as? String, "background")
        XCTAssertEqual(SGCustomerJSON.integer(events[3].props["duration_s"]), 840, "foreground seconds by the monotonic clock")
        XCTAssertEqual(events[4].props["trigger"] as? String, "foreground")
        XCTAssertEqual(events[0].ts, "2026-11-01T09:30:00Z")
        XCTAssertEqual(self.store.session(tg: self.aliceTg), SGAnalyticsSessionMarker(sessionId: second, seq: 1), "the sidecar holds the last seq given out")
    }

    func testASecondStartWhileOpenIsIgnored() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .foreground, at: self.now)
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .background, at: self.now)
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .background, at: self.now)
        XCTAssertEqual(self.names(self.aliceTg), ["app.session_start", "app.session_end"])
    }

    func testAnAccountSwitchEndsOneSessionAndStartsTheOther() {
        self.configure(aliceRecords: true, bobRecords: true, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.record(.vaultChatAdded, account: nil)
        self.uptime += 60
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .accountSwitch, at: self.now)
        self.configure(aliceRecords: true, bobRecords: true, active: self.bob)
        self.pipeline.sessionStart(accountPeerId: self.bob, trigger: .accountSwitch, at: self.now)
        self.record(.vaultChatRemoved, account: nil)
        let alice = self.events(self.aliceTg)
        XCTAssertEqual(alice.map(\.name), ["app.session_start", "vault.chat_added", "app.session_end"])
        XCTAssertEqual(alice.last?.props["reason"] as? String, "account_switch")
        XCTAssertEqual(SGCustomerJSON.integer(alice.last?.props["duration_s"]), 60)
        let bob = self.events(self.bobTg)
        XCTAssertEqual(bob.map(\.name), ["app.session_start", "vault.chat_removed"])
        XCTAssertEqual(bob.first?.props["trigger"] as? String, "account_switch")
        XCTAssertEqual(bob.map(\.seq), [0, 1])
    }

    func testEventsBetweenSessionsContinueTheMostRecentSession() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .background, at: self.now)
        self.record(.tasksMigration(phase: .completed, lists: 1, tasks: 2, skipped: 0, durationS: 3, errorCode: nil), account: self.alice)
        self.record(.screenView(.tasksBoard), account: self.alice)
        let events = self.events(self.aliceTg)
        XCTAssertEqual(events.map(\.name), ["app.session_start", "app.session_end", "tasks.migration", "screen.view"])
        XCTAssertEqual(events.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(Set(events.map(\.sessionId)).count, 1)
    }

    func testANewProcessContinuesTheSidecarSessionButDropsScreenViews() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.record(.vaultChatAdded, account: nil)
        let session = self.events(self.aliceTg)[0].sessionId

        // The next process: a fresh store and pipeline over the same files.
        let store = self.makeStore()!
        self.store = store
        self.pipeline = self.makePipeline(store)
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.record(.screenView(.zgHub), account: nil)
        self.record(.featureUsed(.translation), account: nil)
        self.pipeline.receive(.error(.storage, .sqlite(13)), accountPeerId: nil, at: self.now)
        _ = self.pipeline.nextBatch(tg: self.aliceTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now)
        let events = self.events(self.aliceTg)
        XCTAssertEqual(events.map(\.name), ["app.session_start", "vault.chat_added", "feature.used", "error.occurred"], "no screen view before this process's first session")
        XCTAssertEqual(events.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(Set(events.map(\.sessionId)), [session])
    }

    func testAnAccountThatNeverHadASessionDropsItsEvents() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.record(.vaultChatAdded, account: nil)
        self.record(.featureUsed(.vault), account: nil)
        self.pipeline.receive(.error(.vault, .unknown), accountPeerId: nil, at: self.now)
        self.pipeline.receive(.tasksSyncIssue(.stalled, count: 1), accountPeerId: nil, at: self.now)
        XCTAssertNil(self.pipeline.nextBatch(tg: self.aliceTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now))
        XCTAssertEqual(self.names(self.aliceTg), [])
    }

    // MARK: - Dedup and aggregation

    func testTheSameScreenWithinThirtySecondsIsDropped() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.record(.screenView(.zgHub), account: nil)
        self.uptime += 10
        self.record(.screenView(.zgHub), account: nil)
        self.uptime += 19.5
        self.record(.screenView(.zgHub), account: nil)
        self.uptime += 0.5
        self.record(.screenView(.zgHub), account: nil)
        self.uptime += 5
        self.record(.screenView(.zgPro), account: nil)
        self.uptime += 5
        self.record(.screenView(.zgHub), account: nil)
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .background, at: self.now)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .foreground, at: self.now)
        self.record(.screenView(.zgHub), account: nil)
        let screens = self.events(self.aliceTg).filter { $0.name == "screen.view" }.map { $0.props["screen"] as? String }
        XCTAssertEqual(screens, ["zg.hub", "zg.hub", "zg.pro", "zg.hub", "zg.hub"], "30 s after the last view of the same screen, another screen in between, a new session")
    }

    func testFeatureUsedIsKeptOncePerFeaturePerSession() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.record(.featureUsed(.translation), account: nil)
        self.record(.featureUsed(.translation), account: nil)
        self.record(.featureUsed(.callRecording), account: nil)
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .background, at: self.now)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .foreground, at: self.now)
        self.record(.featureUsed(.translation), account: nil)
        let used = self.events(self.aliceTg).filter { $0.name == "feature.used" }.map { $0.props["feature"] as? String }
        XCTAssertEqual(used, ["translation", "call_recording", "translation"])
    }

    func testErrorsAreAggregatedCappedAndEmittedAtSessionEnd() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        for _ in 0 ..< 3 {
            SGAnalyticsTestSupportSink.send(self.pipeline, .error(.network, .timeout), at: self.now)
        }
        SGAnalyticsTestSupportSink.send(self.pipeline, .error(.backend, .backend("rate_limited")), at: self.now)
        for _ in 0 ..< 1005 {
            SGAnalyticsTestSupportSink.send(self.pipeline, .error(.storage, .sqlite(13)), at: self.now)
        }
        self.pipeline.receive(.tasksSyncIssue(.stalled, count: 2), accountPeerId: nil, at: self.now)
        self.pipeline.receive(.tasksSyncIssue(.stalled, count: 1), accountPeerId: nil, at: self.now)
        self.pipeline.receive(.tasksSyncIssue(.conflictManual, count: 5000), accountPeerId: nil, at: self.now)
        XCTAssertEqual(self.names(self.aliceTg), ["app.session_start"], "aggregated, not yet emitted")
        self.pipeline.sessionEnd(accountPeerId: self.alice, reason: .background, at: self.now)
        let events = self.events(self.aliceTg)
        XCTAssertEqual(events.map(\.name), ["app.session_start", "error.occurred", "error.occurred", "error.occurred", "tasks.sync_issue", "tasks.sync_issue", "app.session_end"])
        XCTAssertEqual(events.map(\.seq), Array(0 ... 6))
        let errors = events.filter { $0.name == "error.occurred" }.map { "\($0.props["domain"] as? String ?? "")/\($0.props["code"] as? String ?? "")=\(SGCustomerJSON.integer($0.props["count"]) ?? -1)" }
        XCTAssertEqual(errors, ["network/timeout=3", "backend/rate_limited=1", "storage/sqlite_13=1000"])
        let issues = events.filter { $0.name == "tasks.sync_issue" }.map { "\($0.props["kind"] as? String ?? "")=\(SGCustomerJSON.integer($0.props["count"]) ?? -1)" }
        XCTAssertEqual(issues, ["stalled=3", "conflict_manual=1000"])
    }

    func testAggregatesAreQueuedBeforeEveryFlush() throws {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.pipeline.receive(.error(.eventsUpload, .http(503)), accountPeerId: nil, at: self.now)
        let batch = try XCTUnwrap(self.pipeline.nextBatch(tg: self.aliceTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now))
        let names = try self.batchNames(batch)
        XCTAssertEqual(names, ["app.session_start", "error.occurred"])
        self.pipeline.complete(batch, deleteEvents: true)
        self.pipeline.receive(.error(.eventsUpload, .http(503)), accountPeerId: nil, at: self.now)
        let next = try XCTUnwrap(self.pipeline.nextBatch(tg: self.aliceTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now))
        XCTAssertEqual(try self.batchNames(next), ["error.occurred"], "a new count after the flush")
    }

    // MARK: - Hand-out and purge

    func testOneBatchIsInFlightPerAccount() throws {
        self.configure(aliceRecords: true, bobRecords: true, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.pipeline.sessionStart(accountPeerId: self.bob, trigger: .launch, at: self.now)
        let batch = try XCTUnwrap(self.pipeline.nextBatch(tg: self.aliceTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now))
        XCTAssertNil(self.pipeline.nextBatch(tg: self.aliceTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now))
        XCTAssertNotNil(self.pipeline.nextBatch(tg: self.bobTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now), "another account is independent")
        self.pipeline.complete(batch, deleteEvents: false)
        let again = try XCTUnwrap(self.pipeline.nextBatch(tg: self.aliceTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now))
        XCTAssertEqual(again.eventIds, batch.eventIds, "kept events go again, with a new batch id")
        XCTAssertNotEqual(again.batchId, batch.batchId)
        self.pipeline.complete(again, deleteEvents: true)
        XCTAssertEqual(self.pipeline.queuedCount(tg: self.aliceTg), 0)
    }

    func testAPurgeFencesALateBatchCompletion() throws {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.record(.vaultChatAdded, account: nil)
        let batch = try XCTUnwrap(self.pipeline.nextBatch(tg: self.aliceTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now))
        self.pipeline.purge(tg: self.aliceTg)
        XCTAssertEqual(self.pipeline.queuedCount(tg: self.aliceTg), 0)
        XCTAssertNil(self.store.session(tg: self.aliceTg), "the sidecar went too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.store.eventsURL(tg: self.aliceTg).path))

        // Granted again: a new session; the old batch's answer arrives late.
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .foreground, at: self.now)
        self.record(.vaultChatRemoved, account: nil)
        self.pipeline.complete(batch, deleteEvents: true)
        XCTAssertEqual(self.names(self.aliceTg), ["app.session_start", "vault.chat_removed"], "nothing after the purge was touched")
        XCTAssertNotEqual(self.events(self.aliceTg).first?.sessionId, try self.batchSessionIds(batch).first)
    }

    func testExpiredEventsAreDeletedAtHandOut() throws {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        self.pipeline.receive(.event(.vaultChatAdded), accountPeerId: nil, at: self.now.addingTimeInterval(3600))
        let batch = try XCTUnwrap(self.pipeline.nextBatch(tg: self.aliceTg, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.now))
        XCTAssertEqual(try self.batchNames(batch), ["app.session_start"], "an event an hour in the future of sent_at is never sent")
        XCTAssertEqual(self.names(self.aliceTg), ["app.session_start"], "and it left the queue")
    }

    // MARK: - Facade

    func testTheFacadeIsANoOpUntilASinkIsInstalledAndInExtensions() {
        let sink = SGAnalyticsTestSupportSink()
        SGAnalytics.clock = { Date(timeIntervalSince1970: 1_793_527_200) }
        SGAnalytics.record(.vaultChatAdded)
        XCTAssertEqual(sink.received.count, 0)
        SGAnalytics.isExtensionProcess = { true }
        SGAnalytics.install(sink)
        SGAnalytics.record(.vaultChatAdded)
        XCTAssertEqual(sink.received.count, 0, "an extension never installs a sink")
        SGAnalytics.isExtensionProcess = { false }
        SGAnalytics.install(sink)
        SGAnalytics.record(.vaultChatAdded, accountPeerId: self.alice)
        SGAnalytics.screen(.zgHub)
        SGAnalytics.featureToggled(.vault, enabled: true, accountPeerId: self.bob)
        SGAnalytics.featureUsed(.translation)
        SGAnalytics.error(.purchase, .storekit(2))
        SGAnalytics.tasksSyncIssue(.invalid, count: 2, accountPeerId: self.alice)
        XCTAssertEqual(sink.received.map(\.input), [
            .event(.vaultChatAdded), .event(.screenView(.zgHub)), .event(.featureToggle(.vault, enabled: true)), .event(.featureUsed(.translation)),
            .error(.purchase, .storekit(2)), .tasksSyncIssue(.invalid, count: 2),
        ])
        XCTAssertEqual(sink.received.map(\.account), [self.alice, nil, self.bob, nil, nil, self.alice])
        XCTAssertEqual(Set(sink.received.map(\.at)), [Date(timeIntervalSince1970: 1_793_527_200)])
    }

    func testThePaywallEntryIsFreshForTenSeconds() {
        var uptime: TimeInterval = 100
        SGAnalytics.uptime = { uptime }
        XCTAssertNil(SGAnalytics.peekPaywallEntry())
        XCTAssertEqual(SGAnalytics.takePaywallEntry(), .other)
        SGAnalytics.notePaywallEntry(.deeplink)
        uptime += 9.9
        XCTAssertEqual(SGAnalytics.peekPaywallEntry(), .deeplink)
        XCTAssertEqual(SGAnalytics.peekPaywallEntry(), .deeplink, "peeking does not consume")
        XCTAssertEqual(SGAnalytics.takePaywallEntry(), .deeplink)
        XCTAssertEqual(SGAnalytics.takePaywallEntry(), .other, "taking consumes")
        SGAnalytics.notePaywallEntry(.featureGate)
        uptime += 10.1
        XCTAssertNil(SGAnalytics.peekPaywallEntry())
        XCTAssertEqual(SGAnalytics.takePaywallEntry(), .other, "stale after 10 s")
    }

    func testTheFacadeFeedsThePipeline() {
        self.configure(aliceRecords: true, bobRecords: false, active: self.alice)
        SGAnalytics.isExtensionProcess = { false }
        SGAnalytics.clock = { Date(timeIntervalSince1970: 1_793_525_430) }
        SGAnalytics.install(self.pipeline)
        self.pipeline.sessionStart(accountPeerId: self.alice, trigger: .launch, at: self.now)
        SGAnalytics.screen(.zgHub)
        SGAnalytics.record(.vaultChatAdded, accountPeerId: self.bob)
        self.pipeline.waitUntilIdle()
        let events = self.events(self.aliceTg)
        XCTAssertEqual(events.map(\.name), ["app.session_start", "screen.view"])
        XCTAssertEqual(events.last?.ts, "2026-11-01T09:30:30Z", "the event time is taken when it is recorded")
    }

    // MARK: - Helpers

    private struct Recorded {
        let name: String
        let ts: String
        let sessionId: String
        let seq: Int
        let props: [String: Any]
    }

    private func makeStore() -> SGAnalyticsQueueStore? {
        return SGAnalyticsQueueStore(baseURL: self.directory, storageToken: "5f2c0d9a", isReadable: { [unowned self] in self.readable }, now: { [unowned self] in self.now })
    }

    private func makePipeline(_ store: SGAnalyticsQueueStore) -> SGAnalyticsPipeline {
        let ids = self.ids
        return SGAnalyticsPipeline(store: store, uptime: { [unowned self] in self.uptime }, makeId: { ids.make() })
    }

    private func configure(aliceRecords: Bool, bobRecords: Bool, active: Int64?) {
        self.pipeline.setAccounts([
            SGAnalyticsPipeline.Account(accountPeerId: self.alice, tg: self.aliceTg, recordingAllowed: aliceRecords),
            SGAnalyticsPipeline.Account(accountPeerId: self.bob, tg: self.bobTg, recordingAllowed: bobRecords),
        ], activeAccountPeerId: active)
        self.pipeline.setContext(SGAnalyticsContext(facts: SGAnalyticsTestSamples.iPhoneFacts))
    }

    private func record(_ event: SGAnalyticsEvent, account: Int64?) {
        self.pipeline.receive(.event(event), accountPeerId: account, at: self.now)
        self.pipeline.waitUntilIdle()
    }

    private func events(_ tg: Int64) -> [Recorded] {
        self.pipeline.waitUntilIdle()
        return self.store.entries(tg: tg).compactMap { entry in
            guard let object = try? JSONSerialization.jsonObject(with: entry.event, options: []) as? [String: Any] else {
                return nil
            }
            return Recorded(name: object["name"] as? String ?? "", ts: object["ts"] as? String ?? "", sessionId: object["session_id"] as? String ?? "", seq: SGCustomerJSON.integer(object["seq"]) ?? -1, props: object["props"] as? [String: Any] ?? [:])
        }
    }

    private func names(_ tg: Int64) -> [String] {
        return self.events(tg).map(\.name)
    }

    private func batchEvents(_ batch: SGAnalyticsBatch) throws -> [[String: Any]] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: batch.body, options: []) as? [String: Any])
        XCTAssertNotNil(SGAnalyticsBatcher.validatedEnvelope(object), "the pipeline hands out only envelopes this client can build")
        return try XCTUnwrap(object["events"] as? [[String: Any]])
    }

    private func batchNames(_ batch: SGAnalyticsBatch) throws -> [String] {
        return try self.batchEvents(batch).map { $0["name"] as? String ?? "" }
    }

    private func batchSessionIds(_ batch: SGAnalyticsBatch) throws -> [String] {
        return try self.batchEvents(batch).map { $0["session_id"] as? String ?? "" }
    }
}

/// A sink that keeps what the facade hands it.
final class SGAnalyticsTestSupportSink: SGAnalyticsSink {
    struct Received {
        let input: SGAnalyticsInput
        let account: Int64?
        let at: Date
    }

    private let lock = NSLock()
    private var items: [Received] = []

    var received: [Received] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.items
    }

    func receive(_ input: SGAnalyticsInput, accountPeerId: Int64?, at: Date) {
        self.lock.lock()
        self.items.append(Received(input: input, account: accountPeerId, at: at))
        self.lock.unlock()
    }

    /// Hands `input` for the active account to `pipeline` and waits until it is processed.
    static func send(_ pipeline: SGAnalyticsPipeline, _ input: SGAnalyticsInput, at: Date) {
        pipeline.receive(input, accountPeerId: nil, at: at)
        pipeline.waitUntilIdle()
    }
}
