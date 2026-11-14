import Foundation
import SGProtectedStore

/// Zenlygram — the clock high-water mark (design §4.4, client contract §5.2).
public struct SGEntitlementClockMark: Codable, Equatable {
    /// The highest server-asserted time this install has ever seen.
    public var serverTime: Date
    /// `ProcessInfo.processInfo.systemUptime` when it was recorded.
    public var uptime: TimeInterval
    /// `Date() - uptime` at that moment — identifies the boot session.
    public var bootTime: Date

    public init(serverTime: Date, uptime: TimeInterval, bootTime: Date) {
        self.serverTime = serverTime
        self.uptime = uptime
        self.bootTime = bootTime
    }
}

/// Zenlygram — the device clock belongs to the user, so evaluation uses
/// `effectiveNow = max(Date(), monotonic)` instead of `Date()`.
///
/// Setting the clock **backwards** buys nothing (the monotonic branch dominates); setting it
/// **forwards** only expires the token sooner. `systemUptime` stalls while the device sleeps, so the
/// monotonic branch can only UNDER-count elapsed time — which errs toward the paying user, the
/// correct direction (invariant I2).
///
/// **And then stop.** This is a GPL client: anyone may clone it, flip one boolean and build an
/// unlocked copy, legitimately. Anti-tamper past this point buys nothing but complexity and worse
/// behaviour for honest users on bad clocks.
///
/// Two things this class keeps apart, and they must stay apart:
/// - `effectiveNow()` is for EVALUATION only.
/// - `transmitTimestamp()` is for the `X-Device-Ts` we SEND, and tracks the real clock plus the last
///   observed server offset. A device whose clock is behind would otherwise be permanently
///   `clock_skew`-rejected.
public final class SGEntitlementClock {
    public static let shared = SGEntitlementClock()

    /// Non-secret; mirrored into the app group so the Notification Service Extension evaluates the
    /// same way with no Keychain read and no network call.
    static let mirrorMarkKey = "zg.ent.clock.mark"
    static let mirrorOffsetKey = "zg.ent.clock.offset"

    /// A boot session is "the same" while the derived boot times agree to within this much.
    static let sameBootTolerance: TimeInterval = 120.0

    /// How far past what this device can independently corroborate a server may move the mark, and
    /// how far a forward device clock may run before the monotonic projection overrides it.
    ///
    /// The mark is a ONE-WAY, PERSISTENT high-water mark held in the Keychain as
    /// `…AfterFirstUnlockThisDeviceOnly`, so it survives reinstalling the app. Without a ceiling a
    /// single bad `server_time` — NTP after a reprovision, a container with a wrong epoch, an
    /// operator running `date` — was adopted by every client that made any request and then made
    /// `effectiveNow()` return that future for ever: every token evaluates lapsed, the offline
    /// grace is dead, and fixing the server recovers nothing because the mark only moves forward.
    /// The only recovery was erasing the phone.
    ///
    /// Two days is far wider than any real skew and far narrower than the years a broken epoch
    /// produces.
    static let markAdvanceTolerance: TimeInterval = 48.0 * 3600.0

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var mark: SGEntitlementClockMark?
    /// `server_time - Date()` at the last response. NOT monotonic: it must be able to move in both
    /// directions or a fast clock stays skewed forever.
    private var offset: TimeInterval = 0.0
    private var didLoad = false

    private init() {
        self.defaults = UserDefaults(suiteName: SGProtectedKeychain.sharedAccessGroup)
    }

    // MARK: - Loading

    private func loadIfNeededLocked() {
        guard !self.didLoad else {
            return
        }
        self.didLoad = true
        let decoder = JSONDecoder()
        if let data = SGEntitlementStore.shared.clockMarkData(), let decoded = try? decoder.decode(SGEntitlementClockMark.self, from: data) {
            self.mark = decoded
        } else if let data = self.defaults?.data(forKey: SGEntitlementClock.mirrorMarkKey), let decoded = try? decoder.decode(SGEntitlementClockMark.self, from: data) {
            // Extensions, and any process that cannot reach the Keychain right now, fall back to the
            // app-group mirror. It carries no secret.
            self.mark = decoded
        }
        if let stored = self.defaults?.object(forKey: SGEntitlementClock.mirrorOffsetKey) as? NSNumber {
            self.offset = stored.doubleValue
        }
    }

    // MARK: - Feeding

    /// Fed by `server_time` in EVERY response body — success AND error, 401 and 429 included — and by
    /// every verified token's `iat`.
    public func note(serverTime: Date) {
        self.lock.lock()
        self.loadIfNeededLocked()

        // The offset tracks the REAL clock and is always refreshed, even when the mark does not move.
        self.offset = serverTime.timeIntervalSince(Date())
        self.defaults?.set(self.offset, forKey: SGEntitlementClock.mirrorOffsetKey)

        let uptime = ProcessInfo.processInfo.systemUptime

        if let existing = self.mark {
            let wallClock = Date()
            let bootNow = wallClock.addingTimeInterval(-uptime)
            let sameBoot = abs(bootNow.timeIntervalSince(existing.bootTime)) < SGEntitlementClock.sameBootTolerance
            let projected = sameBoot ? existing.serverTime.addingTimeInterval(uptime - existing.uptime) : existing.serverTime
            // What this device can corroborate on its own, by either route.
            let corroborated = max(projected, wallClock)

            if serverTime > existing.serverTime {
                // FORWARD, BUT BOUNDED. Anything further ahead than this device can account for is
                // a broken clock somewhere, and adopting it is not recoverable afterwards.
                guard serverTime <= corroborated.addingTimeInterval(SGEntitlementClock.markAdvanceTolerance) else {
                    self.lock.unlock()
                    return
                }
            } else if serverTime >= existing.serverTime.addingTimeInterval(-SGEntitlementClock.markAdvanceTolerance) {
                // Ordinary jitter below the high-water mark: keep the mark where it is.
                self.lock.unlock()
                return
            }
            // Materially BELOW the mark: the mark itself was wrong, and this is the correction.
            // Letting it through is what makes a bad server clock recoverable without erasing the
            // device. It can only ever move evaluation time EARLIER, which grants access rather
            // than withholding it — the side this whole feature errs on.
        }

        let mark = SGEntitlementClockMark(serverTime: serverTime, uptime: uptime, bootTime: Date().addingTimeInterval(-uptime))
        self.mark = mark
        self.lock.unlock()

        self.persist(mark)
    }

    /// A verified token's `iat` is a server assertion too.
    public func note(tokenIssuedAt iat: Int64) {
        self.note(serverTime: Date(timeIntervalSince1970: TimeInterval(iat)))
    }

    private func persist(_ mark: SGEntitlementClockMark) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(mark) else {
            return
        }
        if !SGEntitlement.isAppExtension {
            SGEntitlementStore.shared.setClockMarkData(data)
        }
        self.defaults?.set(data, forKey: SGEntitlementClock.mirrorMarkKey)
    }

    // MARK: - Reading

    public var currentMark: SGEntitlementClockMark? {
        self.lock.lock()
        self.loadIfNeededLocked()
        let mark = self.mark
        self.lock.unlock()
        return mark
    }

    /// EVALUATION time. Never used for anything transmitted.
    public func effectiveNow() -> Date {
        self.lock.lock()
        self.loadIfNeededLocked()
        let mark = self.mark
        self.lock.unlock()
        return SGEntitlementClock.effectiveNow(mark: mark, wallClock: Date(), uptime: ProcessInfo.processInfo.systemUptime)
    }

    /// The pure form, so the rule is testable without a device clock.
    public static func effectiveNow(mark: SGEntitlementClockMark?, wallClock: Date, uptime: TimeInterval) -> Date {
        guard let mark else {
            return wallClock
        }
        let bootNow = wallClock.addingTimeInterval(-uptime)
        let sameBoot = abs(bootNow.timeIntervalSince(mark.bootTime)) < SGEntitlementClock.sameBootTolerance
        let monotonic = sameBoot ? mark.serverTime.addingTimeInterval(uptime - mark.uptime) : mark.serverTime

        // The floor stops a BACKWARD device clock from buying time. The ceiling stops a FORWARD one
        // from taking it away: within the same boot the uptime projection is an independent, real
        // measurement of elapsed time, so a wall clock running far ahead of it is the thing that is
        // wrong, not the projection. Without this, a user who set the date forward saw "Your
        // subscription ended" while holding a perfectly valid token.
        //
        // Across a reboot there is no projection to check against — the device may genuinely have
        // been off for a week — so only the floor applies there.
        if sameBoot {
            return min(max(wallClock, monotonic), monotonic.addingTimeInterval(SGEntitlementClock.markAdvanceTolerance))
        }

        return max(wallClock, monotonic)
    }

    /// TRANSMITTED time: the real clock plus the last observed server offset, as decimal Unix
    /// seconds. This is the value that goes in `X-Device-Ts` and into the signed message.
    public func transmitTimestamp() -> Int64 {
        self.lock.lock()
        self.loadIfNeededLocked()
        let offset = self.offset
        self.lock.unlock()
        return Int64((Date().timeIntervalSince1970 + offset).rounded())
    }

    /// `401 clock_skew` recovery: the error body carries `server_time`. Adopting it as the offset and
    /// re-signing once is what makes the skew recoverable with no user action.
    public func adoptServerOffset(serverTime: Date) {
        self.lock.lock()
        self.loadIfNeededLocked()
        self.offset = serverTime.timeIntervalSince(Date())
        self.defaults?.set(self.offset, forKey: SGEntitlementClock.mirrorOffsetKey)
        self.lock.unlock()
    }

    /// Tests only.
    func resetForTesting() {
        self.lock.lock()
        self.mark = nil
        self.offset = 0.0
        self.didLoad = true
        self.lock.unlock()
    }
}
