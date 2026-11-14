import Foundation
import SGEntitlement

// MARK: - The client pacer for assignments (wf15 §12.1): the first line before the server's budgets
//
// Pure: no store, no clock of its own. The repository keeps content-free counters per account in the
// store's `meta` table — `invite_day.<yyyymmdd>` (every manual pick of the UTC day),
// `invite_day.<yyyymmdd>.<recipientTgId>` (per recipient) and `invite_minute.<epochMinute>` —
// incremented when a manual pick is enqueued (conservative: a failed send still counts), deleted
// after two UTC days (`isExpired(counterKey:now:)`) and with the store. The automatic re-send of a
// deferred assignment (§12.2) is the user's own pick retried: it neither consults nor charges the
// pacer. The server stays authoritative (`TasksBudgets::chargeInvitation`: 10/min, 100/UTC day,
// 5/recipient/UTC day, ≤ 100 unexpired pending; F7, F15); the client refuses one step earlier, so
// the owner hears it at pick time as a sentence instead of as a 429 that gates the account. The
// legacy-assignee sheet (D4, §7.3) spends the same allowance and spaces its sends ten per minute.

/// `SGTasksAssignmentLimit` (the refusal's kind) is declared with `SGTasksCloudError` in
/// `SGTasksCloudModels.swift`, so the value types compile on their own.
public enum SGTasksInvitationPacer {
    /// Per recipient and UTC day (the server refuses the 6th).
    public static let recipientPerDay = 5
    /// Manual picks per minute (the server's minute bucket is 10).
    public static let picksPerMinute = 10
    /// Per UTC day (the server's day bucket is 100).
    public static let perDay = 95
    /// Owner assignments pending and unexpired (the server holds at most 100).
    public static let maximumPending = 95
    /// The D4 sheet's spacing: entries due ten per minute (§7.3).
    public static let spacedSendsPerMinute = 10
    /// A counter is deleted once it is older than this many UTC days (today and yesterday stay).
    public static let counterLifetimeDays = 2

    /// What the account has done so far, as the repository reads it: the recipient's and the day's
    /// counters, the current minute's counter and the pending assignments of the visible board
    /// (owner tasks whose assignment is pending and unexpired — the shadow plus queued invites).
    public struct Counts: Equatable {
        public var recipientToday: Int
        public var today: Int
        public var thisMinute: Int
        public var pending: Int

        public init(recipientToday: Int, today: Int, thisMinute: Int, pending: Int) {
            self.recipientToday = recipientToday
            self.today = today
            self.thisMinute = thisMinute
            self.pending = pending
        }
    }

    /// The first limit one more manual pick would exceed; nil when the pick is allowed. The order is
    /// the order of §4.2 item 3 (`_limitPerPerson | _limitPerMinute | _limitTotal | _limitPending`).
    public static func refusal(_ counts: Counts) -> SGTasksAssignmentLimit? {
        if counts.recipientToday >= Self.recipientPerDay {
            return .perPerson
        }
        if counts.thisMinute >= Self.picksPerMinute {
            return .perMinute
        }
        if counts.today >= Self.perDay {
            return .total
        }
        if counts.pending >= Self.maximumPending {
            return .pending
        }
        return nil
    }

    // MARK: Counter keys (content-free)

    static let dayPrefix = "invite_day."
    static let minutePrefix = "invite_minute."

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// The UTC day of `date` as `yyyymmdd` (the server's buckets are UTC days, `startOfDay()`).
    public static func dayKey(_ date: Date) -> String {
        let components = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// The epoch minute of `date`.
    public static func minuteKey(_ date: Date) -> Int64 {
        return Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    public static func dayCounterKey(day: String) -> String {
        return Self.dayPrefix + day
    }

    public static func recipientCounterKey(day: String, recipient: SGTasksWire.TelegramId) -> String {
        return Self.dayPrefix + day + "." + recipient.rawValue
    }

    public static func minuteCounterKey(minute: Int64) -> String {
        return Self.minutePrefix + String(minute)
    }

    /// A counter older than `counterLifetimeDays` UTC days (a day key below yesterday's, a minute
    /// key below two days ago). A key of neither shape is never reported expired.
    public static func isExpired(counterKey: String, now: Date) -> Bool {
        if counterKey.hasPrefix(Self.dayPrefix) {
            let day = counterKey.dropFirst(Self.dayPrefix.count).split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            guard day.count == 8, day.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            let cutoff = Self.dayKey(now.addingTimeInterval(-TimeInterval(Self.counterLifetimeDays - 1) * 86400))
            return day < cutoff
        }
        if counterKey.hasPrefix(Self.minutePrefix) {
            guard let minute = Int64(counterKey.dropFirst(Self.minutePrefix.count)) else { return false }
            return minute < Self.minuteKey(now) - Int64(Self.counterLifetimeDays) * 1440
        }
        return false
    }

    // MARK: The legacy-assignee sheet's allowance (§7.3)

    /// The counters as the store holds them at one moment (`SGTasksCloudRepository.
    /// invitationPacerSnapshot()`): the sheet computes its allowance and its spacing from them.
    public struct Snapshot: Equatable {
        /// `invite_day.<today>`.
        public var today: Int
        /// `invite_minute.<this minute>`.
        public var thisMinute: Int
        /// Owner tasks whose assignment is pending and unexpired.
        public var pending: Int
        /// `invite_day.<today>.<recipient>` per recipient (absent: 0).
        public var recipientToday: [SGTasksWire.TelegramId: Int]

        public init(today: Int, thisMinute: Int, pending: Int, recipientToday: [SGTasksWire.TelegramId: Int]) {
            self.today = today
            self.thisMinute = thisMinute
            self.pending = pending
            self.recipientToday = recipientToday
        }

        public static let zero = Snapshot(today: 0, thisMinute: 0, pending: 0, recipientToday: [:])
    }

    /// Of `candidates` in sheet order, the ones one tap may send now: per recipient at most
    /// `recipientPerDay` minus that recipient's count today, in all at most `perDay` minus today's
    /// count, and only while fewer than `maximumPending` assignments wait (each allowed candidate
    /// becomes one). The caller charges the pacer for each allowed candidate as it enqueues it.
    public static func allowance<ID>(candidates: [(id: ID, recipient: SGTasksWire.TelegramId)], recipientToday: (SGTasksWire.TelegramId) -> Int, today: Int, pending: Int) -> [ID] {
        var allowed: [ID] = []
        var sentToday = today
        var pendingNow = pending
        var perRecipient: [SGTasksWire.TelegramId: Int] = [:]
        for candidate in candidates {
            guard sentToday < Self.perDay, pendingNow < Self.maximumPending else { break }
            let count = perRecipient[candidate.recipient] ?? recipientToday(candidate.recipient)
            guard count < Self.recipientPerDay else { continue }
            perRecipient[candidate.recipient] = count + 1
            sentToday += 1
            pendingNow += 1
            allowed.append(candidate.id)
        }
        return allowed
    }

    /// When the `index`-th entry of a paced send is due: `now + floor((index + sentThisMinute) / 10)`
    /// minutes, so a tap never exceeds the server's minute bucket.
    public static func spacedDate(index: Int, sentThisMinute: Int, now: Date) -> Date {
        let slot = max(index + sentThisMinute, 0) / Self.spacedSendsPerMinute
        return now.addingTimeInterval(TimeInterval(slot) * 60)
    }
}
