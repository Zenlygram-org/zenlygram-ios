import Foundation

/// Zenlygram — one event in an account's queue, as the batcher sees it.
public struct SGAnalyticsQueuedEvent: Equatable {
    public let id: String
    /// The id of the context it was recorded under (`SGAnalyticsContext.id`).
    public let contextId: String
    /// The event's `ts`, in Unix seconds.
    public let at: Int64
    public let sessionId: String
    public let seq: Int
    /// The exact event JSON (`SGAnalyticsWireEvent.encoded()`).
    public let event: Data
}

/// Zenlygram — an account's most recent session (`sessions-<tg>.json`): events recorded between
/// sessions, even in a later process, continue its `seq` (contract §3.6).
public struct SGAnalyticsSessionMarker: Equatable {
    public let sessionId: String
    /// The last `seq` given out in it.
    public let seq: Int

    public init(sessionId: String, seq: Int) {
        self.sessionId = sessionId
        self.seq = seq
    }
}

/// Zenlygram — the on-disk event queue (design 40 §10.5, contract §6.5), one per (backend origin,
/// Telegram account): `<base>/zenlygram-customer.o-<storageToken>/events-<tg>.jsonl` and the
/// sessions sidecar `sessions-<tg>.json`. `<base>` is the MAIN app's Application Support (never the
/// App Group); the directory is excluded from backup and every file is written with
/// `completeUntilFirstUserAuthentication`.
///
/// The queue is append-only JSON lines: `{"k":"c","id":"<16 hex>","context":{…}}` interns a context,
/// `{"k":"e","c":"<16 hex>","at":<unix s>,"event":{…}}` is an event recorded under it. A line that is
/// not valid (a torn last line after a crash, anything this build would not have written) is
/// skipped, and the file is rewritten before the next append. Removals and bound enforcement
/// rewrite the whole file atomically (a temp file + `replaceItemAt`).
///
/// Bounds per account: ≤ 5000 events, ≤ 2 MiB, ≤ 7 days old; the oldest go first. A queue over a
/// count or size bound is trimmed to 90 % of it, so a full queue is not rewritten on every append.
/// While the files' protection class is unavailable (`isReadable` false) the queue reads as empty
/// and nothing is written. `purge(tg:)` deletes the account's files under every origin and bumps its
/// generation, so a batch handed out before can never delete (or rewrite) anything after it.
///
/// Thread-safe (one lock); the pipeline calls it from its serial queue. It caches each queue it has
/// read, so the app keeps ONE instance per origin (the pipeline's).
public final class SGAnalyticsQueueStore {
    public static let maxEvents = 5000
    public static let maxBytes = 2 * 1024 * 1024
    public static let maxAge: TimeInterval = 7 * 86_400
    public static let directoryPrefix = "zenlygram-customer.o-"
    /// Every queue and sessions file is written with this protection class.
    static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    static let writingProtection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication

    /// The count and size bounds (smaller in tests).
    struct Limits: Equatable {
        var maxEvents: Int
        var maxBytes: Int

        static let standard = Limits(maxEvents: SGAnalyticsQueueStore.maxEvents, maxBytes: SGAnalyticsQueueStore.maxBytes)
    }

    private struct Queue {
        /// id → context JSON.
        var contexts: [String: Data] = [:]
        var events: [SGAnalyticsQueuedEvent] = []
        /// The file holds something the queue dropped (a torn or invalid line, an expired event):
        /// rewrite it before appending.
        var needsRewrite = false
    }

    /// Application Support (or a test directory).
    public let baseURL: URL
    /// `<base>/zenlygram-customer.o-<storageToken>`.
    public let directoryURL: URL
    private let readable: () -> Bool
    private let clock: () -> Date
    private let fileManager: FileManager
    private let limits: Limits
    private let lock = NSLock()
    private var queues: [Int64: Queue] = [:]
    private var generations: [Int64: Int] = [:]
    private var isDirectoryPrepared = false

    /// - Parameters:
    ///   - baseURL: the main app's Application Support directory.
    ///   - storageToken: `SGEntitlement.shared.customerDataStorageToken` (lowercase hex); nil
    ///     result for anything that is not path-safe.
    ///   - isReadable: the files' protection class is available (after the first unlock).
    public convenience init?(baseURL: URL, storageToken: String, isReadable: @escaping () -> Bool, now: @escaping () -> Date = { Date() }, fileManager: FileManager = .default) {
        self.init(baseURL: baseURL, storageToken: storageToken, isReadable: isReadable, now: now, fileManager: fileManager, limits: .standard)
    }

    init?(baseURL: URL, storageToken: String, isReadable: @escaping () -> Bool, now: @escaping () -> Date, fileManager: FileManager, limits: Limits) {
        let token = Array(storageToken.utf8)
        guard (1 ... 128).contains(token.count), token.allSatisfy({ ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) }) else {
            return nil
        }
        self.baseURL = baseURL
        self.directoryURL = baseURL.appendingPathComponent(SGAnalyticsQueueStore.directoryPrefix + storageToken, isDirectory: true)
        self.readable = isReadable
        self.clock = now
        self.fileManager = fileManager
        self.limits = limits
    }

    public func eventsURL(tg: Int64) -> URL {
        return self.directoryURL.appendingPathComponent("events-\(tg).jsonl", isDirectory: false)
    }

    public func sessionsURL(tg: Int64) -> URL {
        return self.directoryURL.appendingPathComponent("sessions-\(tg).json", isDirectory: false)
    }

    public var isReadable: Bool {
        return self.readable()
    }

    /// The account's queued events (0 while unreadable).
    public func count(tg: Int64) -> Int {
        return self.locked { self.queueLocked(tg)?.events.count ?? 0 }
    }

    /// The Telegram ids with a queue or a sessions file under any origin (launch reconciliation,
    /// design 40 §11.5); nil while unreadable.
    public func queueOwners() -> [Int64]? {
        return self.locked {
            guard self.readable() else {
                return nil
            }
            var owners = Set<Int64>()
            for directory in self.originDirectoriesLocked() {
                for name in (try? self.fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                    if let tg = SGAnalyticsQueueStore.owner(ofFileNamed: name) {
                        owners.insert(tg)
                    }
                }
            }
            return owners.sorted()
        }
    }

    /// Deletes the account's queue and sessions file under EVERY origin and bumps its generation
    /// (withdrawal, deletion, logout). Deleting needs no readable protection class, so it is never
    /// refused. False when a file could not be removed.
    @discardableResult
    public func purge(tg: Int64) -> Bool {
        return self.locked {
            self.queues[tg] = nil
            self.generations[tg, default: 0] += 1
            var removedAll = true
            for directory in self.originDirectoriesLocked() {
                for name in (try? self.fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                    let isOwned = name == "events-\(tg).jsonl" || name == "sessions-\(tg).json" || name.hasPrefix(".events-\(tg).") || name.hasPrefix(".sessions-\(tg).")
                    guard isOwned else {
                        continue
                    }
                    do {
                        try self.fileManager.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
                    } catch {
                        removedAll = false
                    }
                }
            }
            return removedAll
        }
    }

    // MARK: - Queue (the pipeline)

    /// Appends `event` recorded under `context`, then enforces the bounds. False — nothing changed —
    /// while unreadable or when the write failed.
    func append(tg: Int64, context: SGAnalyticsContext, event: SGAnalyticsWireEvent) -> Bool {
        return self.locked {
            guard tg > 0, let ts = SGCustomerTime.date(fromInstant: event.ts), event.isValid, var queue = self.queueLocked(tg), self.prepareDirectoryLocked() else {
                return false
            }
            let contextId = context.id
            let isNewContext = queue.contexts[contextId] == nil
            let entry = SGAnalyticsQueuedEvent(id: event.id, contextId: contextId, at: Int64(ts.timeIntervalSince1970), sessionId: event.sessionId, seq: event.seq, event: event.encoded())
            queue.contexts[contextId] = context.encoded()
            queue.events.append(entry)
            let expired = self.pruneExpiredLocked(&queue)
            let bounded = SGAnalyticsQueueStore.enforceBounds(&queue, self.limits)
            // A file that vanished under the cache is written whole, so no event line ever lands
            // without its context line.
            let vanished = queue.events.count > 1 && !self.fileManager.fileExists(atPath: self.eventsURL(tg: tg).path)
            if queue.needsRewrite || expired || bounded || vanished {
                guard self.rewriteLocked(tg, queue) else {
                    return false
                }
                queue.needsRewrite = false
            } else {
                var lines = Data()
                if isNewContext {
                    lines.append(SGAnalyticsQueueStore.contextLine(contextId, queue.contexts[contextId] ?? Data()))
                }
                lines.append(SGAnalyticsQueueStore.eventLine(entry))
                guard self.appendLocked(lines, to: self.eventsURL(tg: tg)) else {
                    // The file may hold a torn line now: read it again next time.
                    self.queues[tg] = nil
                    return false
                }
            }
            self.queues[tg] = queue
            return true
        }
    }

    /// The account's events, oldest first (empty while unreadable).
    func entries(tg: Int64) -> [SGAnalyticsQueuedEvent] {
        return self.locked {
            guard var queue = self.queueLocked(tg) else {
                return []
            }
            if self.pruneExpiredLocked(&queue) {
                queue.needsRewrite = true
                self.queues[tg] = queue
            }
            return queue.events
        }
    }

    /// The JSON of a context of the account's queue.
    func context(tg: Int64, id: String) -> Data? {
        return self.locked { self.queueLocked(tg)?.contexts[id] }
    }

    /// Removes the events `ids` (a delivered batch, expired events). False — nothing changed — while
    /// unreadable or when the rewrite failed.
    @discardableResult
    func remove(tg: Int64, ids: Set<String>) -> Bool {
        return self.locked {
            guard var queue = self.queueLocked(tg) else {
                return false
            }
            let before = queue.events.count
            queue.events.removeAll { ids.contains($0.id) }
            _ = self.pruneExpiredLocked(&queue)
            guard queue.events.count != before || queue.needsRewrite else {
                return true
            }
            SGAnalyticsQueueStore.dropUnreferencedContexts(&queue)
            guard self.rewriteLocked(tg, queue) else {
                return false
            }
            queue.needsRewrite = false
            self.queues[tg] = queue
            return true
        }
    }

    /// Bumped by every `purge(tg:)` (in memory, per process).
    func generation(tg: Int64) -> Int {
        return self.locked { self.generations[tg] ?? 0 }
    }

    /// The account's most recent session, or nil (none, unreadable, malformed).
    func session(tg: Int64) -> SGAnalyticsSessionMarker? {
        return self.locked {
            guard self.readable(), let data = try? Data(contentsOf: self.sessionsURL(tg: tg)), let object = SGCustomerJSON.object(data),
                  SGCustomerJSON.integer(object["v"]) == 1, let sessionId = object["session_id"] as? String, SGCustomerTime.isUUID4(sessionId),
                  let seq = SGCustomerJSON.integer(object["seq"]), (0 ... SGAnalyticsTaxonomy.maxSeq).contains(seq) else {
                return nil
            }
            return SGAnalyticsSessionMarker(sessionId: sessionId, seq: seq)
        }
    }

    @discardableResult
    func setSession(_ marker: SGAnalyticsSessionMarker, tg: Int64) -> Bool {
        return self.locked {
            guard tg > 0, self.readable(), SGCustomerTime.isUUID4(marker.sessionId), (0 ... SGAnalyticsTaxonomy.maxSeq).contains(marker.seq), self.prepareDirectoryLocked() else {
                return false
            }
            let text = SGCustomerJSON.object([("v", "1"), ("session_id", SGCustomerJSON.quoted(marker.sessionId)), ("seq", String(marker.seq))])
            do {
                try Data(text.utf8).write(to: self.sessionsURL(tg: tg), options: [.atomic, SGAnalyticsQueueStore.writingProtection])
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Internals

    private func locked<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return body()
    }

    /// The account's queue (read from the file once), or nil while unreadable or when an existing
    /// file cannot be read.
    private func queueLocked(_ tg: Int64) -> Queue? {
        guard self.readable() else {
            return nil
        }
        if let queue = self.queues[tg] {
            return queue
        }
        let url = self.eventsURL(tg: tg)
        var queue = Queue()
        if self.fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            queue = SGAnalyticsQueueStore.parse(data)
            if self.pruneExpiredLocked(&queue) {
                queue.needsRewrite = true
            }
        }
        self.queues[tg] = queue
        return queue
    }

    private static func parse(_ data: Data) -> Queue {
        var queue = Queue()
        var seen = Set<String>()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                continue
            }
            // Only a line ended by a newline was written whole.
            guard index < lines.count - 1, let object = SGCustomerJSON.object(Data(line)) else {
                queue.needsRewrite = true
                continue
            }
            switch object["k"] as? String {
            case "c":
                if let id = object["id"] as? String, let context = SGAnalyticsContext.validated(object["context"]), context.id == id {
                    queue.contexts[id] = context.encoded()
                    continue
                }
            case "e":
                if let contextId = object["c"] as? String, queue.contexts[contextId] != nil, SGCustomerJSON.integer(object["at"]) != nil,
                   let event = object["event"].flatMap(SGAnalyticsWireEvent.validated), !seen.contains(event.id),
                   let ts = SGCustomerTime.date(fromInstant: event.ts) {
                    seen.insert(event.id)
                    queue.events.append(SGAnalyticsQueuedEvent(id: event.id, contextId: contextId, at: Int64(ts.timeIntervalSince1970), sessionId: event.sessionId, seq: event.seq, event: event.encoded()))
                    continue
                }
            default:
                break
            }
            queue.needsRewrite = true
        }
        return queue
    }

    /// Drops events older than 7 days; true when it dropped any.
    private func pruneExpiredLocked(_ queue: inout Queue) -> Bool {
        let cutoff = Int64((self.clock().timeIntervalSince1970 - SGAnalyticsQueueStore.maxAge).rounded(.up))
        let before = queue.events.count
        queue.events.removeAll { $0.at < cutoff }
        guard queue.events.count != before else {
            return false
        }
        SGAnalyticsQueueStore.dropUnreferencedContexts(&queue)
        return true
    }

    /// Over `limits.maxEvents` events or `limits.maxBytes` of lines: the oldest dropped until the
    /// queue is within 90 % of both; true when it dropped any.
    private static func enforceBounds(_ queue: inout Queue, _ limits: Limits) -> Bool {
        var references: [String: Int] = [:]
        var total = 0
        for event in queue.events {
            references[event.contextId, default: 0] += 1
            total += SGAnalyticsQueueStore.eventLineSize(event)
        }
        for (id, context) in queue.contexts where references[id] != nil {
            total += SGAnalyticsQueueStore.contextLineSize(id, context)
        }
        guard queue.events.count > limits.maxEvents || total > limits.maxBytes else {
            return false
        }
        let targetEvents = limits.maxEvents * 9 / 10
        let targetBytes = limits.maxBytes / 10 * 9
        var dropCount = 0
        while dropCount < queue.events.count, queue.events.count - dropCount > targetEvents || total > targetBytes {
            let dropped = queue.events[dropCount]
            total -= SGAnalyticsQueueStore.eventLineSize(dropped)
            references[dropped.contextId, default: 1] -= 1
            if references[dropped.contextId] == 0, let context = queue.contexts[dropped.contextId] {
                total -= SGAnalyticsQueueStore.contextLineSize(dropped.contextId, context)
            }
            dropCount += 1
        }
        guard dropCount > 0 else {
            return false
        }
        queue.events.removeFirst(dropCount)
        SGAnalyticsQueueStore.dropUnreferencedContexts(&queue)
        return true
    }

    private static func dropUnreferencedContexts(_ queue: inout Queue) {
        let referenced = Set(queue.events.map(\.contextId))
        queue.contexts = queue.contexts.filter { referenced.contains($0.key) }
    }

    private static func contextLine(_ id: String, _ context: Data) -> Data {
        var line = Data("{\"k\":\"c\",\"id\":\"\(id)\",\"context\":".utf8)
        line.append(context)
        line.append(Data("}\n".utf8))
        return line
    }

    private static func eventLine(_ event: SGAnalyticsQueuedEvent) -> Data {
        var line = Data("{\"k\":\"e\",\"c\":\"\(event.contextId)\",\"at\":\(event.at),\"event\":".utf8)
        line.append(event.event)
        line.append(Data("}\n".utf8))
        return line
    }

    private static func contextLineSize(_ id: String, _ context: Data) -> Int {
        return "{\"k\":\"c\",\"id\":\"\",\"context\":}\n".utf8.count + id.utf8.count + context.count
    }

    private static func eventLineSize(_ event: SGAnalyticsQueuedEvent) -> Int {
        return "{\"k\":\"e\",\"c\":\"\",\"at\":,\"event\":}\n".utf8.count + event.contextId.utf8.count + String(event.at).utf8.count + event.event.count
    }

    /// The queue's file written anew (temp file + replace); an empty queue removes the file.
    private func rewriteLocked(_ tg: Int64, _ queue: Queue) -> Bool {
        let url = self.eventsURL(tg: tg)
        guard !queue.events.isEmpty else {
            if self.fileManager.fileExists(atPath: url.path) {
                return (try? self.fileManager.removeItem(at: url)) != nil
            }
            return true
        }
        var data = Data()
        var written = Set<String>()
        for event in queue.events where !written.contains(event.contextId) {
            written.insert(event.contextId)
            data.append(SGAnalyticsQueueStore.contextLine(event.contextId, queue.contexts[event.contextId] ?? Data()))
        }
        for event in queue.events {
            data.append(SGAnalyticsQueueStore.eventLine(event))
        }
        let temporary = self.directoryURL.appendingPathComponent(".events-\(tg).\(UUID().uuidString.lowercased()).tmp", isDirectory: false)
        do {
            try data.write(to: temporary, options: [SGAnalyticsQueueStore.writingProtection])
            if self.fileManager.fileExists(atPath: url.path) {
                _ = try self.fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try self.fileManager.moveItem(at: temporary, to: url)
            }
            return true
        } catch {
            try? self.fileManager.removeItem(at: temporary)
            return false
        }
    }

    /// `lines` appended to the file (created, protected, when absent); false when not all of it
    /// was written.
    private func appendLocked(_ lines: Data, to url: URL) -> Bool {
        if !self.fileManager.fileExists(atPath: url.path) {
            return self.fileManager.createFile(atPath: url.path, contents: lines, attributes: [.protectionKey: SGAnalyticsQueueStore.fileProtection])
        }
        guard let stream = OutputStream(url: url, append: true) else {
            return false
        }
        stream.open()
        defer {
            stream.close()
        }
        let bytes = [UInt8](lines)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else {
                    return -1
                }
                return stream.write(base, maxLength: buffer.count)
            }
            guard written > 0 else {
                return false
            }
            offset += written
        }
        return true
    }

    /// The origin directory exists and is excluded from backup.
    private func prepareDirectoryLocked() -> Bool {
        if self.isDirectoryPrepared, self.fileManager.fileExists(atPath: self.directoryURL.path) {
            return true
        }
        do {
            try self.fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true, attributes: nil)
            var directory = self.directoryURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            self.isDirectoryPrepared = true
            return true
        } catch {
            return false
        }
    }

    private func originDirectoriesLocked() -> [URL] {
        let names = (try? self.fileManager.contentsOfDirectory(atPath: self.baseURL.path)) ?? []
        return names.filter { $0.hasPrefix(SGAnalyticsQueueStore.directoryPrefix) }.sorted().map { self.baseURL.appendingPathComponent($0, isDirectory: true) }
    }

    /// The tg of `events-<tg>.jsonl` / `sessions-<tg>.json`.
    private static func owner(ofFileNamed name: String) -> Int64? {
        let digits: Substring
        if name.hasPrefix("events-"), name.hasSuffix(".jsonl") {
            digits = name.dropFirst("events-".count).dropLast(".jsonl".count)
        } else if name.hasPrefix("sessions-"), name.hasSuffix(".json") {
            digits = name.dropFirst("sessions-".count).dropLast(".json".count)
        } else {
            return nil
        }
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }), let tg = Int64(digits), tg > 0 else {
            return nil
        }
        return tg
    }
}
