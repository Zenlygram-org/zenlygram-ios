import Foundation

/// A stand-in for `SGIAPSubscriptionStatus` (which needs SGEntitlement): the slot is generic, and
/// the rules under test are ordering and failure handling, not the status's fields.
private struct Status: Equatable {
    var willAutoRenew: Bool
}

@main
struct SubscriptionStatusSlotTests {
    private static func check(_ condition: Bool, _ message: String = "Assertion failed", line: Int = #line) {
        precondition(condition, "line \(line): \(message)")
    }

    private static let renews = Status(willAutoRenew: true)
    private static let cancelled = Status(willAutoRenew: false)

    static func main() {
        ordering()
        failurePreservesKnownValue()
        failedNewestBlocksOlderSuccess()
        successfulNoneClears()
        recoveryAfterFailure()
        print("PASS: subscription status — newest query wins; failure keeps the answer but unsettles it")
    }

    private static func ordering() {
        var slot = SGIAPSubscriptionStatusSlot<Status>()
        check(slot.value == nil && slot.settled == nil)

        // A first query against an empty slot hides nothing, and its answer is published.
        let first = slot.begin()
        check(!first.hidValue)
        check(slot.complete(first.generation, status: renews))
        check(slot.settled == renews)

        // Back from Apple's page (auto-renew turned off): while the re-query runs the old answer is
        // NOT settled, but the paywall's plan label keeps it.
        let foreground = slot.begin()
        check(foreground.hidValue, "Re-query did not hide the renewal claim")
        check(slot.settled == nil, "Renewal claim shown while it is being replaced")
        check(slot.value == renews)

        // A second query (Transaction.updates) overlaps; the OLDER one finishes last with a stale
        // answer and must not land.
        let update = slot.begin()
        check(!update.hidValue, "Already hidden; nothing new to announce")
        check(slot.complete(update.generation, status: cancelled))
        check(slot.settled == cancelled)
        check(!slot.complete(foreground.generation, status: renews), "A stale query overwrote a newer answer")
        check(slot.settled == cancelled && slot.value == cancelled)

        // A duplicate completion — or a late failure — of the newest query changes nothing.
        check(!slot.complete(update.generation, status: renews))
        check(!slot.fail(update.generation))
        check(slot.settled == cancelled)

        // The same answer again is announced once more, because the screen hid it meanwhile.
        let again = slot.begin()
        check(again.hidValue)
        check(slot.complete(again.generation, status: cancelled), "Hidden value never re-shown")
        check(slot.settled == cancelled)
    }

    /// Offline after Manage: the query fails. The paywall keeps labelling the known plan; the
    /// status screen does not repeat a renewal claim nobody re-confirmed.
    private static func failurePreservesKnownValue() {
        var slot = SGIAPSubscriptionStatusSlot<Status>()
        let first = slot.begin()
        _ = slot.complete(first.generation, status: renews)

        let offline = slot.begin()
        check(offline.hidValue)
        check(!slot.fail(offline.generation), "A failure has nothing new for readers to show")
        check(slot.value == renews, "A failed query read as 'not subscribed' for the paywall")
        check(slot.settled == nil, "Unconfirmed renewal claim shown after a failed re-query")

        // A failed query on an empty slot (products never loaded) stays empty and unknown.
        var empty = SGIAPSubscriptionStatusSlot<Status>()
        let none = empty.begin()
        check(!empty.fail(none.generation))
        check(empty.value == nil && empty.settled == nil)
    }

    /// The newest query failed; an OLDER query then answers. It must not revive a settled value.
    private static func failedNewestBlocksOlderSuccess() {
        var slot = SGIAPSubscriptionStatusSlot<Status>()
        let older = slot.begin()
        let newest = slot.begin()
        check(!slot.fail(newest.generation))
        check(!slot.complete(older.generation, status: renews), "An older answer landed after the newest query failed")
        check(slot.value == nil && slot.settled == nil)

        // Same with a known value: the old answer cannot overwrite it or re-settle it.
        var known = SGIAPSubscriptionStatusSlot<Status>()
        let seed = known.begin()
        _ = known.complete(seed.generation, status: cancelled)
        let stale = known.begin()
        let current = known.begin()
        _ = known.fail(current.generation)
        check(!known.complete(stale.generation, status: renews))
        check(known.value == cancelled && known.settled == nil)
    }

    /// StoreKit answering "nothing in the group" is authoritative: it clears the value.
    private static func successfulNoneClears() {
        var slot = SGIAPSubscriptionStatusSlot<Status>()
        let first = slot.begin()
        _ = slot.complete(first.generation, status: renews)
        let expired = slot.begin()
        check(slot.complete(expired.generation, status: nil))
        check(slot.value == nil && slot.settled == nil)

        // Nothing to hide and nothing found: no change to announce.
        let empty = slot.begin()
        check(!empty.hidValue)
        check(!slot.complete(empty.generation, status: nil))
    }

    /// After a failure, the next successful query settles again — the old value or a new one.
    private static func recoveryAfterFailure() {
        var slot = SGIAPSubscriptionStatusSlot<Status>()
        let first = slot.begin()
        _ = slot.complete(first.generation, status: renews)
        let offline = slot.begin()
        _ = slot.fail(offline.generation)

        let retry = slot.begin()
        check(!retry.hidValue, "Already unsettled; nothing new to announce")
        check(slot.complete(retry.generation, status: renews), "Recovery to the same answer was not announced")
        check(slot.settled == renews)

        let offlineAgain = slot.begin()
        _ = slot.fail(offlineAgain.generation)
        let changed = slot.begin()
        check(slot.complete(changed.generation, status: cancelled))
        check(slot.value == cancelled && slot.settled == cancelled)
    }
}
