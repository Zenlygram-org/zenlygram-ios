import Foundation

/// Zenlygram — one `POST /v1/profile/events` batch handed out by the pipeline (one in flight per
/// account): hand its answer to `SGAnalyticsBatcher.apply`, then `SGAnalyticsPipeline.complete`.
public struct SGAnalyticsBatch: Equatable {
    public let tg: Int64
    public let batchId: String
    public let sentAt: Date
    /// The envelope (contract §3.1), within the byte limit it was asked for.
    public let body: Data
    public let eventIds: [String]
    /// The queue's generation at hand-out: a purge since makes the completion a no-op.
    let generation: Int
}

/// Zenlygram — an account's event-flush state (design 40 §10.6): the batch size after 413 /
/// timeout halving, and the server's hints (persist `pausedUntil` / `flushInterval` in
/// `SGCustomerHints`).
public struct SGAnalyticsFlushState: Equatable {
    /// At most this many events in the next batch (200, halved by 413 and timeouts).
    public var batchLimit: Int
    /// An `"ingest": "paused"` answer stops uploads until then.
    public var pausedUntil: Date?
    /// The foreground flush interval (`flush_interval_s`, 60…3600, default 300).
    public var flushInterval: TimeInterval

    public init(batchLimit: Int = SGAnalyticsBatcher.maxEvents, pausedUntil: Date? = nil, flushInterval: TimeInterval = SGAnalyticsBatcher.defaultFlushInterval) {
        self.batchLimit = batchLimit
        self.pausedUntil = pausedUntil
        self.flushInterval = flushInterval
    }

    /// The state the stored hints describe.
    public init(hints: SGCustomerHints) {
        self.init(pausedUntil: hints.eventsPausedUntil, flushInterval: SGAnalyticsBatcher.clampedFlushInterval(hints.flushIntervalS.map(TimeInterval.init)))
    }
}

/// Zenlygram — event batches (design 40 §10.6, contract §3.1, §6.5): which queued events go
/// together, the envelope bytes, what an answer does to them, and when a flush is due.
///
/// A batch is the OLDEST queued events recorded under one context (batches split where the context
/// changes), ≤ 200 events and ≤ 256 KiB for the whole envelope (a background flush ≤ 64 KiB).
/// Events whose `ts` is more than 7 days before `sent_at` or more than 300 s after it are never
/// sent (the server would refuse them as `stale` / `future`): they are deleted instead.
public enum SGAnalyticsBatcher {
    public static let maxEvents = 200
    public static let maxBytes = 256 * 1024
    /// The background flush (`zg.customer.flush`): one batch per account, 8 s.
    public static let backgroundMaxBytes = 64 * 1024
    public static let backgroundDeadline: TimeInterval = 8
    /// A timeout halves the batch, never below this.
    public static let timeoutMinimum = 25
    /// A flush is due at once with this many events queued.
    public static let flushThreshold = 50
    public static let defaultFlushInterval: TimeInterval = 300
    public static let flushIntervalBounds: ClosedRange<TimeInterval> = 60 ... 3600
    /// `"ingest": "paused"` stops event uploads this long.
    public static let pause: TimeInterval = 24 * 3600
    public static let maxPast: TimeInterval = 7 * 86_400
    public static let maxFuture: TimeInterval = 300

    /// What `select` picked from a queue.
    struct Selection: Equatable {
        let contextId: String?
        let events: [SGAnalyticsQueuedEvent]
        /// Events outside the `sent_at` window: delete them.
        let expired: [String]
    }

    /// The next batch of `queue` (oldest first): the run of events sharing the first sendable
    /// event's context, up to `limit` events and `maxBytes` of envelope.
    static func select(_ queue: [SGAnalyticsQueuedEvent], limit: Int, maxBytes: Int, sentAt: Date, contextBytes: (String) -> Data?) -> Selection {
        let sent = Int64(sentAt.timeIntervalSince1970.rounded(.down))
        let earliest = sent - Int64(SGAnalyticsBatcher.maxPast)
        let latest = sent + Int64(SGAnalyticsBatcher.maxFuture)
        let limit = min(max(limit, 1), SGAnalyticsBatcher.maxEvents)
        var expired: [String] = []
        var contextId: String?
        var budget = 0
        var events: [SGAnalyticsQueuedEvent] = []
        for event in queue {
            guard event.at >= earliest, event.at <= latest else {
                expired.append(event.id)
                continue
            }
            if let current = contextId {
                guard event.contextId == current, events.count < limit, budget + 1 + event.event.count <= maxBytes else {
                    break
                }
                budget += 1 + event.event.count
                events.append(event)
            } else {
                guard let context = contextBytes(event.contextId) else {
                    expired.append(event.id)
                    continue
                }
                // A uuid4 is always 36 characters.
                let overhead = SGAnalyticsBatcher.envelope(batchId: String(repeating: "0", count: 36), sentAt: sentAt, context: context, events: []).count
                guard overhead + event.event.count <= maxBytes else {
                    break
                }
                contextId = event.contextId
                budget = overhead + event.event.count
                events.append(event)
            }
        }
        return Selection(contextId: contextId, events: events, expired: expired)
    }

    /// `{"batch_id","context","events":[…],"schema_version":1,"sent_at","taxonomy_version":1}` around
    /// the exact event bytes, compact.
    public static func envelope(batchId: String, sentAt: Date, context: Data, events: [Data]) -> Data {
        var body = Data("{\"batch_id\":\(SGCustomerJSON.quoted(batchId)),\"context\":".utf8)
        body.append(context)
        body.append(Data(",\"events\":[".utf8))
        for (index, event) in events.enumerated() {
            if index > 0 {
                body.append(UInt8(ascii: ","))
            }
            body.append(event)
        }
        body.append(Data("],\"schema_version\":\(SGCustomerWire.schemaVersion),\"sent_at\":\(SGCustomerJSON.quoted(SGCustomerTime.instant(sentAt))),\"taxonomy_version\":\(SGAnalyticsTaxonomy.version)}".utf8))
        return body
    }

    /// What `outcome` (the classified answer to a batch of `batchSize` events) does: true = delete
    /// every event of the batch. `state` takes the server's hints and the halving:
    /// - 200: delete (accepted, duplicate and rejected alike); `"ingest": "paused"` pauses uploads
    ///   for 24 h; `flush_interval_s` is kept (60…3600); the batch size returns to 200;
    /// - 413: keep, halve (minimum 1); a timeout: keep, halve (minimum 25) — then the route backs off;
    /// - 409 / 422 / any other 4xx: delete (a client bug: never resent);
    /// - everything else (403 consent / not linked, 401, 429, 5xx, offline, nothing sent): keep.
    public static func apply(_ outcome: SGCustomerCallOutcome, batchSize: Int, state: inout SGAnalyticsFlushState, now: Date) -> Bool {
        switch outcome {
        case let .ok(body):
            let response = SGEventsResponse.decode(body)
            if response?.ingest == .paused {
                state.pausedUntil = now.addingTimeInterval(SGAnalyticsBatcher.pause)
            }
            if let interval = response?.flushIntervalS {
                state.flushInterval = SGAnalyticsBatcher.clampedFlushInterval(TimeInterval(interval))
            }
            state.batchLimit = SGAnalyticsBatcher.maxEvents
            return true
        case .payloadTooLarge:
            state.batchLimit = max(1, min(state.batchLimit, batchSize) / 2)
            return false
        case .timedOut:
            state.batchLimit = max(SGAnalyticsBatcher.timeoutMinimum, min(state.batchLimit, batchSize) / 2)
            return false
        case .terminal, .accountMismatch:
            return true
        case .consentRequired, .accountNotLinked, .rateLimited, .session, .unavailable, .notLinkedLocally, .credentialChanged, .notConfigured:
            return false
        }
    }

    /// When the account's next foreground flush is due (design 40 §10.6), or nil: nothing queued,
    /// or in the background (the background flush is triggered by `didEnterBackground` itself).
    /// Paused → the end of the pause; the first flush after first idle and ≥ 50 queued → now;
    /// otherwise the last flush + `flush_interval_s`.
    public static func flushDueAt(queued: Int, flushedSinceFirstIdle: Bool, lastFlushAt: Date?, isForeground: Bool, state: SGAnalyticsFlushState, now: Date) -> Date? {
        guard queued > 0 else {
            return nil
        }
        if let pausedUntil = state.pausedUntil, pausedUntil > now {
            return pausedUntil
        }
        if !flushedSinceFirstIdle || queued >= SGAnalyticsBatcher.flushThreshold {
            return now
        }
        guard isForeground else {
            return nil
        }
        guard let lastFlushAt else {
            return now
        }
        return lastFlushAt.addingTimeInterval(state.flushInterval)
    }

    static func clampedFlushInterval(_ seconds: TimeInterval?) -> TimeInterval {
        guard let seconds, seconds.isFinite else {
            return SGAnalyticsBatcher.defaultFlushInterval
        }
        return min(max(seconds, SGAnalyticsBatcher.flushIntervalBounds.lowerBound), SGAnalyticsBatcher.flushIntervalBounds.upperBound)
    }

    // MARK: - What this client can send

    /// A decoded envelope when this client could have built it — the server's strict rules
    /// (contract §3.1, §3.5) narrowed to what this client emits: exactly the six keys,
    /// `schema_version` 1, `taxonomy_version` 1, a uuid4 `batch_id`, an instant `sent_at`, a context
    /// of this build (`platform` `ios`), 1…200 events each `SGAnalyticsWireEvent.validated`, with
    /// distinct ids, `seq` strictly increasing per session, every `ts` within [`sent_at` − 7 d,
    /// `sent_at` + 300 s], and ≤ 256 KiB. Else nil.
    static func validatedEnvelope(_ value: Any) -> (context: SGAnalyticsContext, events: [SGAnalyticsWireEvent])? {
        guard let object = value as? [String: Any],
              Set(object.keys) == ["schema_version", "taxonomy_version", "batch_id", "sent_at", "context", "events"],
              SGCustomerJSON.integer(object["schema_version"]) == SGCustomerWire.schemaVersion,
              SGCustomerJSON.integer(object["taxonomy_version"]) == SGAnalyticsTaxonomy.version,
              let batchId = object["batch_id"] as? String, SGCustomerTime.isUUID4(batchId),
              let sentAtText = object["sent_at"] as? String, let sentAt = SGCustomerTime.date(fromInstant: sentAtText),
              let context = SGAnalyticsContext.validated(object["context"]),
              let items = object["events"] as? [Any], (1 ... SGAnalyticsBatcher.maxEvents).contains(items.count) else {
            return nil
        }
        var events: [SGAnalyticsWireEvent] = []
        var ids = Set<String>()
        var lastSeq: [String: Int] = [:]
        for item in items {
            guard let event = SGAnalyticsWireEvent.validated(item), ids.insert(event.id).inserted,
                  let ts = SGCustomerTime.date(fromInstant: event.ts),
                  ts.timeIntervalSince(sentAt) >= -SGAnalyticsBatcher.maxPast, ts.timeIntervalSince(sentAt) <= SGAnalyticsBatcher.maxFuture else {
                return nil
            }
            if let previous = lastSeq[event.sessionId], event.seq <= previous {
                return nil
            }
            lastSeq[event.sessionId] = event.seq
            events.append(event)
        }
        let size = SGAnalyticsBatcher.envelope(batchId: batchId, sentAt: sentAt, context: context.encoded(), events: events.map { $0.encoded() }).count
        guard size <= SGAnalyticsBatcher.maxBytes else {
            return nil
        }
        return (context, events)
    }
}
