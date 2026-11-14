import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — event batches (design 40 §10.6, contract §3.1, §3.5): the shared `events-valid.json`
/// envelopes equal what the builder makes (as parsed JSON), no `events-invalid.json` case can be
/// built, ≤ 200 events and ≤ 256 KiB (64 KiB in the background), batches split on a context change,
/// and what each answer does (200 deletes, paused, 413 / timeout halving).
final class SGAnalyticsBatcherTests: XCTestCase {
    private let tg: Int64 = 555_000_111
    /// 2026-11-01T10:00:00Z, the fixtures' `received_at`.
    private let received = Date(timeIntervalSince1970: 1_793_527_200)

    private var directory: URL!
    private var removeDirectory: (() -> Void)?
    private let ids = SGAnalyticsTestSamples.Ids()

    override func setUp() {
        super.setUp()
        let made = SGCustomerSyncTestFixtures.makeDirectory()
        self.directory = made.url
        self.removeDirectory = made.remove
    }

    override func tearDown() {
        self.removeDirectory?()
        super.tearDown()
    }

    // MARK: - Shared fixtures

    func testTheValidEnvelopesEqualTheBuilderOutput() throws {
        let cases = try SGCustomerSyncTestFixtures.cases("events-valid.json").filter { $0["client_built"] as? Bool == true }
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        var names = Set<String>()
        for item in cases {
            let id = item["id"] as? String ?? "?"
            XCTAssertEqual(item["binding_platform"] as? String, "ios", id)
            let body = try XCTUnwrap(item["body"] as? [String: Any], id)
            let sentAt = try XCTUnwrap((body["sent_at"] as? String).flatMap(SGCustomerTime.date(fromInstant:)), id)
            let fixtureContext = try XCTUnwrap(body["context"] as? [String: Any], id)
            let context = SGAnalyticsContext(facts: SGAnalyticsTestSamples.iPhoneFacts)
            SGCustomerSyncTestFixtures.assertJSON(context.encoded(), equals: fixtureContext, id)
            var events: [Data] = []
            for raw in try XCTUnwrap(body["events"] as? [[String: Any]], id) {
                let name = try XCTUnwrap(raw["name"] as? String)
                let payload = try XCTUnwrap(SGAnalyticsTestSamples.typedPayload(name: name, props: try XCTUnwrap(raw["props"] as? [String: Any])), "\(id): no builder makes \(raw)")
                let event = SGAnalyticsWireEvent(id: try XCTUnwrap(raw["id"] as? String), ts: try XCTUnwrap(raw["ts"] as? String), sessionId: try XCTUnwrap(raw["session_id"] as? String), seq: try XCTUnwrap(SGCustomerJSON.integer(raw["seq"])), payload: payload)
                XCTAssertTrue(event.isValid, "\(id): \(name)")
                SGCustomerSyncTestFixtures.assertJSON(event.encoded(), equals: raw, "\(id): \(name)")
                events.append(event.encoded())
                names.insert(name)
            }
            let envelope = SGAnalyticsBatcher.envelope(batchId: try XCTUnwrap(body["batch_id"] as? String), sentAt: sentAt, context: context.encoded(), events: events)
            SGCustomerSyncTestFixtures.assertJSON(envelope, equals: body, id)
            XCTAssertNotNil(SGAnalyticsBatcher.validatedEnvelope(body), "\(id) is an envelope this client can build")
            let expected = try XCTUnwrap(item["expected"] as? [String: Any], id)
            XCTAssertEqual((expected["rejected"] as? [Any])?.count, 0, id)
            XCTAssertEqual(SGCustomerJSON.integer(expected["dropped_props"]), 0, id)
        }
        XCTAssertEqual(names, Set(SGAnalyticsSchema.events.keys), "the client-built cases hold every event name")
    }

    func testNoInvalidCaseCanBeBuilt() throws {
        let cases = try SGCustomerSyncTestFixtures.cases("events-invalid.json")
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let body = try XCTUnwrap(item["body"], id)
            XCTAssertNil(SGAnalyticsBatcher.validatedEnvelope(body), "\(id) would be built")
            guard let offending = SGCustomerJSON.integer(item["offending_event"]) else {
                XCTAssertEqual(item["reason"] as? String, "batch", id)
                continue
            }
            var object = try XCTUnwrap(body as? [String: Any], id)
            var events = try XCTUnwrap(object["events"] as? [Any], id)
            let culprit = events.remove(at: offending)
            object["events"] = events
            XCTAssertNotNil(SGAnalyticsBatcher.validatedEnvelope(object), "\(id): without the offending event the batch is one this client builds")
            switch item["reason"] as? String {
            case "unknown_event", "invalid_props", "invalid_envelope":
                if id != "invalid-envelope-seq-order" {
                    XCTAssertNil(SGAnalyticsWireEvent.validated(culprit), "\(id): no builder makes the event")
                }
            case "stale", "future":
                XCTAssertNotNil(SGAnalyticsWireEvent.validated(culprit), "\(id): only its time is wrong")
            default:
                XCTFail("\(id): unknown reason")
            }
        }
    }

    func testTheTypedBuildersRefuseTheInvalidValues() {
        XCTAssertNil(SGAnalyticsErrorCode("Connection refused"), "invalid-props-pattern")
        XCTAssertNil(SGAnalyticsScreen(rawValue: "tg.chat"), "invalid-props-enum")
        XCTAssertEqual(SGAnalyticsEvent.tasksTaskCreated(scope: .cloud, hasDue: false, priority: 5, inList: true).payload.props["priority"], .integer(4), "invalid-props-range: clamped")
        XCTAssertNil(SGAnalyticsPayload.validated(name: "app.crashed", props: [:]), "unknown-event")
        XCTAssertNil(SGAnalyticsPayload.validated(name: "link.attempt", props: ["trigger": "manual", "method": "code", "outcome": "failed", "error_code": NSNull()]), "invalid-props-null-optional")
        XCTAssertNil(SGAnalyticsPayload.validated(name: "feature.toggle", props: ["feature": "vault", "enabled": "yes"]), "invalid-props-type")
        XCTAssertNil(SGAnalyticsPayload.validated(name: "error.occurred", props: ["domain": "storage", "code": "sqlite_13", "count": "2"]), "invalid-props-integer-as-string")
        XCTAssertNil(SGAnalyticsPayload.validated(name: "error.occurred", props: ["domain": "storage", "code": "sqlite_13", "count": 2.0]), "a float is not an integer")
        XCTAssertNil(SGAnalyticsPayload.validated(name: "feature.toggle", props: ["feature": "vault", "enabled": 1]), "a number is not a boolean")
        XCTAssertNil(SGAnalyticsPayload.validated(name: "screen.view", props: ["screen": "zg.hub", "chat_title": "Family"]), "an undeclared prop")
        XCTAssertNil(SGAnalyticsPayload.validated(name: "screen.view", props: [:]), "invalid-props-missing-required")
        XCTAssertNotNil(SGAnalyticsPayload.validated(name: "vault.chat_added", props: [:]))
        XCTAssertFalse(SGAnalyticsWireEvent(id: "CDDD65EF-0E77-4BD5-B5E9-E701AC575DC3", ts: "2026-11-01T09:58:30Z", sessionId: SGCustomerTime.uuid4(), seq: 1, payload: SGAnalyticsEvent.vaultChatAdded.payload).isValid, "an upper-case id")
        XCTAssertFalse(SGAnalyticsWireEvent(id: SGCustomerTime.uuid4(), ts: "2026-11-01T09:58:30.250Z", sessionId: SGCustomerTime.uuid4(), seq: 1, payload: SGAnalyticsEvent.vaultChatAdded.payload).isValid, "a fraction")
        XCTAssertFalse(SGAnalyticsWireEvent(id: SGCustomerTime.uuid4(), ts: "2026-11-01T09:58:30Z", sessionId: SGCustomerTime.uuid4(), seq: -1, payload: SGAnalyticsEvent.vaultChatAdded.payload).isValid, "seq below 0")
        XCTAssertFalse(SGAnalyticsWireEvent(id: SGCustomerTime.uuid4(), ts: "2026-11-01T09:58:30Z", sessionId: SGCustomerTime.uuid4(), seq: 1_000_001, payload: SGAnalyticsEvent.vaultChatAdded.payload).isValid, "seq above 1 000 000")
    }

    // MARK: - Selection

    func testABatchHoldsAtMostTwoHundredEvents() throws {
        let store = try self.makeStore()
        let context = SGAnalyticsContext(facts: SGAnalyticsTestSamples.iPhoneFacts)
        for _ in 0 ..< 450 {
            XCTAssertTrue(store.append(tg: self.tg, context: context, event: self.event()))
        }
        let selection = self.select(store, limit: 500, maxBytes: SGAnalyticsBatcher.maxBytes)
        XCTAssertEqual(selection.events.count, 200)
        XCTAssertEqual(selection.events.map(\.id), Array(store.entries(tg: self.tg).prefix(200).map(\.id)), "the oldest first")
        XCTAssertEqual(self.select(store, limit: 30, maxBytes: SGAnalyticsBatcher.maxBytes).events.count, 30)
    }

    func testABatchStaysWithinTheByteLimits() throws {
        let store = try self.makeStore()
        let context = SGAnalyticsContext(facts: SGAnalyticsTestSamples.iPhoneFacts)
        let large = SGAnalyticsTestSamples.largestEvents()[0].payload
        for _ in 0 ..< 600 {
            XCTAssertTrue(store.append(tg: self.tg, context: context, event: self.event(payload: large)))
        }
        let full = self.select(store, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes)
        XCTAssertEqual(full.events.count, 200, "these events are small enough for the count to bind first")
        XCTAssertLessThanOrEqual(SGAnalyticsBatcher.envelope(batchId: SGCustomerTime.uuid4(), sentAt: self.received, context: context.encoded(), events: full.events.map(\.event)).count, SGAnalyticsBatcher.maxBytes)
        for limit in [SGAnalyticsBatcher.backgroundMaxBytes, 4096] {
            let selection = self.select(store, limit: 200, maxBytes: limit)
            let envelope = SGAnalyticsBatcher.envelope(batchId: SGCustomerTime.uuid4(), sentAt: self.received, context: context.encoded(), events: selection.events.map(\.event))
            XCTAssertLessThanOrEqual(envelope.count, limit)
            let next = SGAnalyticsBatcher.envelope(batchId: SGCustomerTime.uuid4(), sentAt: self.received, context: context.encoded(), events: (selection.events + [store.entries(tg: self.tg)[selection.events.count]]).map(\.event))
            XCTAssertGreaterThan(next.count, limit, "as many as fit")
            XCTAssertNotNil(SGAnalyticsBatcher.validatedEnvelope(try JSONSerialization.jsonObject(with: envelope, options: [])))
        }
        XCTAssertEqual(SGAnalyticsBatcher.maxBytes, 262_144)
        XCTAssertEqual(SGAnalyticsBatcher.backgroundMaxBytes, 65_536)
        XCTAssertEqual(SGAnalyticsBatcher.backgroundDeadline, 8)
    }

    func testBatchesSplitWhereTheContextChanges() throws {
        let store = try self.makeStore()
        var facts = SGAnalyticsTestSamples.iPhoneFacts
        let first = SGAnalyticsContext(facts: facts)
        facts.timezone = "Asia/Samarkand"
        let second = SGAnalyticsContext(facts: facts)
        for context in [first, first, first, second, second, first] {
            XCTAssertTrue(store.append(tg: self.tg, context: context, event: self.event()))
        }
        var sizes: [Int] = []
        var contexts: [String?] = []
        while true {
            let selection = self.select(store, limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes)
            guard !selection.events.isEmpty else {
                break
            }
            sizes.append(selection.events.count)
            contexts.append(selection.contextId)
            store.remove(tg: self.tg, ids: Set(selection.events.map(\.id)))
        }
        XCTAssertEqual(sizes, [3, 2, 1])
        XCTAssertEqual(contexts, [first.id, second.id, first.id])
    }

    func testEventsOutsideTheSentAtWindowAreNeverSent() throws {
        let context = SGAnalyticsContext(facts: SGAnalyticsTestSamples.iPhoneFacts)
        let stale = self.event(ts: "2026-10-25T09:59:59Z")
        let oldest = self.event(ts: "2026-10-25T10:00:00Z")
        let latest = self.event(ts: "2026-11-01T10:05:00Z")
        let future = self.event(ts: "2026-11-01T10:05:01Z")
        // The queue's own 7-day bound runs on the clock of the append; set it early so the stale one is queued.
        let queue = try self.makeStore(now: Date(timeIntervalSince1970: 1_793_000_000))
        for event in [stale, oldest, latest, future] {
            XCTAssertTrue(queue.append(tg: self.tg, context: context, event: event))
        }
        let selection = SGAnalyticsBatcher.select(queue.entries(tg: self.tg), limit: 200, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.received) { queue.context(tg: self.tg, id: $0) }
        XCTAssertEqual(selection.events.map(\.id), [oldest.id, latest.id], "exactly 7 days and exactly 300 s are inside")
        XCTAssertEqual(Set(selection.expired), [stale.id, future.id])
    }

    // MARK: - Answers

    func testATwoHundredDeletesTheWholeBatchAndKeepsTheHints() {
        var state = SGAnalyticsFlushState(batchLimit: 25)
        let body = Data("{\"schema_version\":1,\"accepted\":197,\"duplicates\":1,\"dropped_props\":0,\"rejected\":[{\"id\":null,\"reason\":\"invalid_envelope\"},{\"id\":\"30100b08-4662-4c89-a020-25d3fa7143a3\",\"reason\":\"unknown_event\"}],\"ingest\":\"stored\",\"flush_interval_s\":120,\"server_time\":\"2026-11-01T10:00:00Z\",\"extra\":true}".utf8)
        XCTAssertTrue(SGAnalyticsBatcher.apply(.ok(body), batchSize: 25, state: &state, now: self.received), "accepted, duplicate and rejected alike")
        XCTAssertEqual(state, SGAnalyticsFlushState(batchLimit: 200, pausedUntil: nil, flushInterval: 120))
        for (hint, expected) in [(10, 60.0), (99_999, 3600.0), (300, 300.0)] {
            let answer = Data("{\"schema_version\":1,\"accepted\":1,\"duplicates\":0,\"dropped_props\":0,\"rejected\":[],\"ingest\":\"stored\",\"flush_interval_s\":\(hint)}".utf8)
            XCTAssertTrue(SGAnalyticsBatcher.apply(.ok(answer), batchSize: 1, state: &state, now: self.received))
            XCTAssertEqual(state.flushInterval, expected, "flush_interval_s \(hint) is clamped to 60…3600")
        }
    }

    func testAPausedIngestDeletesAndPausesForADay() {
        var state = SGAnalyticsFlushState()
        let body = Data("{\"schema_version\":1,\"accepted\":0,\"duplicates\":0,\"dropped_props\":0,\"rejected\":[],\"ingest\":\"paused\",\"flush_interval_s\":300}".utf8)
        XCTAssertTrue(SGAnalyticsBatcher.apply(.ok(body), batchSize: 10, state: &state, now: self.received))
        XCTAssertEqual(state.pausedUntil, self.received.addingTimeInterval(24 * 3600))
        XCTAssertEqual(SGAnalyticsBatcher.flushDueAt(queued: 80, flushedSinceFirstIdle: false, lastFlushAt: nil, isForeground: true, state: state, now: self.received), state.pausedUntil, "nothing goes before the pause ends")
        let hints = SGCustomerHints(flushIntervalS: 300, eventsPausedUntil: state.pausedUntil, minIntervalS: nil)
        XCTAssertEqual(SGAnalyticsFlushState(hints: SGCustomerHints(jsonObject: hints.jsonObject)).pausedUntil, state.pausedUntil, "the pause survives a relaunch through the hints")
    }

    func testA413HalvesTheBatchDownToOne() {
        var state = SGAnalyticsFlushState()
        var limits: [Int] = []
        for _ in 0 ..< 9 {
            XCTAssertFalse(SGAnalyticsBatcher.apply(.payloadTooLarge, batchSize: state.batchLimit, state: &state, now: self.received))
            limits.append(state.batchLimit)
        }
        XCTAssertEqual(limits, [100, 50, 25, 12, 6, 3, 1, 1, 1])
    }

    func testATimeoutHalvesTheBatchToNoFewerThanTwentyFive() {
        var state = SGAnalyticsFlushState()
        var limits: [Int] = []
        for _ in 0 ..< 5 {
            XCTAssertFalse(SGAnalyticsBatcher.apply(.timedOut, batchSize: state.batchLimit, state: &state, now: self.received))
            limits.append(state.batchLimit)
        }
        XCTAssertEqual(limits, [100, 50, 25, 25, 25])
        var small = SGAnalyticsFlushState()
        XCTAssertFalse(SGAnalyticsBatcher.apply(.timedOut, batchSize: 30, state: &small, now: self.received))
        XCTAssertEqual(small.batchLimit, 25, "half of a short batch, still at least 25")
    }

    func testFinalAnswersDropTheBatchAndTransientOnesKeepIt() {
        let dropped: [SGCustomerCallOutcome] = [.terminal(status: 422, code: "invalid_request"), .terminal(status: 400, code: nil), .accountMismatch]
        let kept: [SGCustomerCallOutcome] = [
            .consentRequired(SGConsentRequiredExtras(reason: .withdrawn, consent: nil)), .accountNotLinked, .rateLimited(retryAfter: 30),
            .session(code: "invalid_token", reason: nil), .unavailable(retryAfter: nil), .notLinkedLocally, .credentialChanged, .notConfigured,
        ]
        for outcome in dropped {
            var state = SGAnalyticsFlushState(batchLimit: 50)
            XCTAssertTrue(SGAnalyticsBatcher.apply(outcome, batchSize: 50, state: &state, now: self.received), "\(outcome)")
            XCTAssertEqual(state.batchLimit, 50)
        }
        for outcome in kept {
            var state = SGAnalyticsFlushState(batchLimit: 50)
            XCTAssertFalse(SGAnalyticsBatcher.apply(outcome, batchSize: 50, state: &state, now: self.received), "\(outcome)")
            XCTAssertEqual(state, SGAnalyticsFlushState(batchLimit: 50))
        }
    }

    func testTheEndToEndFlushOfAPipelineBatch() throws {
        let store = try self.makeStore()
        let pipeline = SGAnalyticsPipeline(store: store, uptime: { 1000 }, makeId: { self.ids.make() })
        pipeline.setAccounts([SGAnalyticsPipeline.Account(accountPeerId: 7, tg: self.tg, recordingAllowed: true)], activeAccountPeerId: 7)
        pipeline.setContext(SGAnalyticsContext(facts: SGAnalyticsTestSamples.iPhoneFacts))
        pipeline.sessionStart(accountPeerId: 7, trigger: .launch, at: self.received.addingTimeInterval(-60))
        for _ in 0 ..< 260 {
            pipeline.receive(.event(.vaultChatAdded), accountPeerId: nil, at: self.received.addingTimeInterval(-30))
        }
        var state = SGAnalyticsFlushState()
        var delivered = 0
        while let batch = pipeline.nextBatch(tg: self.tg, limit: state.batchLimit, maxBytes: SGAnalyticsBatcher.maxBytes, sentAt: self.received) {
            XCTAssertLessThanOrEqual(batch.eventIds.count, 200)
            let answer = Data("{\"schema_version\":1,\"accepted\":\(batch.eventIds.count),\"duplicates\":0,\"dropped_props\":0,\"rejected\":[],\"ingest\":\"stored\",\"flush_interval_s\":300}".utf8)
            let delete = SGAnalyticsBatcher.apply(SGCustomerWire.classify(SGCustomerRawAnswer(transport: .ok, status: 200, body: answer)), batchSize: batch.eventIds.count, state: &state, now: self.received)
            pipeline.complete(batch, deleteEvents: delete)
            delivered += batch.eventIds.count
        }
        XCTAssertEqual(delivered, 261)
        XCTAssertEqual(pipeline.queuedCount(tg: self.tg), 0)
    }

    // MARK: - Flush triggers

    func testWhenAFlushIsDue() {
        let state = SGAnalyticsFlushState()
        let now = self.received
        XCTAssertNil(SGAnalyticsBatcher.flushDueAt(queued: 0, flushedSinceFirstIdle: false, lastFlushAt: nil, isForeground: true, state: state, now: now), "nothing queued")
        XCTAssertEqual(SGAnalyticsBatcher.flushDueAt(queued: 1, flushedSinceFirstIdle: false, lastFlushAt: nil, isForeground: false, state: state, now: now), now, "once after first idle")
        XCTAssertEqual(SGAnalyticsBatcher.flushDueAt(queued: 50, flushedSinceFirstIdle: true, lastFlushAt: now, isForeground: false, state: state, now: now), now, "≥ 50 queued")
        XCTAssertEqual(SGAnalyticsBatcher.flushDueAt(queued: 49, flushedSinceFirstIdle: true, lastFlushAt: now.addingTimeInterval(-100), isForeground: true, state: state, now: now), now.addingTimeInterval(200), "every flush_interval_s in the foreground")
        XCTAssertNil(SGAnalyticsBatcher.flushDueAt(queued: 49, flushedSinceFirstIdle: true, lastFlushAt: now.addingTimeInterval(-1000), isForeground: false, state: state, now: now), "the background flush is the lifecycle's")
        XCTAssertEqual(SGAnalyticsBatcher.flushDueAt(queued: 3, flushedSinceFirstIdle: true, lastFlushAt: nil, isForeground: true, state: SGAnalyticsFlushState(flushInterval: 60), now: now), now)
        XCTAssertEqual(SGAnalyticsFlushState(hints: SGCustomerHints()).flushInterval, 300, "the default interval")
        XCTAssertEqual(SGAnalyticsFlushState(hints: SGCustomerHints(flushIntervalS: 5)).flushInterval, 60)
    }

    // MARK: - Helpers

    private func makeStore(now: Date? = nil) throws -> SGAnalyticsQueueStore {
        let clock = now ?? self.received
        return try XCTUnwrap(SGAnalyticsQueueStore(baseURL: self.directory, storageToken: "77aa", isReadable: { true }, now: { clock }))
    }

    private func select(_ store: SGAnalyticsQueueStore, limit: Int, maxBytes: Int) -> SGAnalyticsBatcher.Selection {
        return SGAnalyticsBatcher.select(store.entries(tg: self.tg), limit: limit, maxBytes: maxBytes, sentAt: self.received) { store.context(tg: self.tg, id: $0) }
    }

    private var seq = 0

    /// The next event of one session (`seq` 1, 2, …).
    private func event(ts: String = "2026-11-01T09:59:00Z", payload: SGAnalyticsPayload = SGAnalyticsEvent.vaultChatAdded.payload) -> SGAnalyticsWireEvent {
        self.seq += 1
        return SGAnalyticsWireEvent(id: self.ids.make(), ts: ts, sessionId: "eaef78c6-169a-4595-8620-66a414cffbcb", seq: self.seq, payload: payload)
    }
}
