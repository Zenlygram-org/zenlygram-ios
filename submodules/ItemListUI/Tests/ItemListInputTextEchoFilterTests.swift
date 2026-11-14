import XCTest
import ItemListUI

/// Zenlygram — regression coverage for the settings-search fast-typing loss ("Tasks" → "Tas" in QA,
/// paced typing unaffected).
///
/// `ItemListSingleLineInputItemNode` reports every edit with `textUpdated`; the owner's state comes
/// back as a new item, asynchronously and in order, and the node's apply step decides through
/// `ItemListInputTextEchoFilter` whether to write `item.text` into the field. These tests drive that
/// real filter with the same two calls the node makes — `didEmit` on an edit and
/// `textToApply(incoming:fieldText:item:)` on apply — so a rewind to a stale echo shows up as a wrong
/// field. Each new owner state is a new item object, as in the app; `.relayout` re-applies the item
/// object applied last, as `ListView.updateAdjacent` and width changes do.
final class ItemListInputTextEchoFilterTests: XCTestCase {
    /// Stands in for one `ItemListSingleLineInputItem` instance.
    private final class Item {
        let text: String

        init(_ text: String) {
            self.text = text
        }
    }

    /// One user edit or one item apply, in the order the main thread sees them.
    private enum Event {
        case keystroke(Character)
        /// The owner's item for the `n`th emitted text (0-based) arrives, passed through the owner's
        /// own transform (identity for the settings search, which stores the query verbatim).
        case echo(Int)
        /// The owner sets its value itself (e.g. a reset), not in response to an edit.
        case ownerValue(String)
        /// The list lays the row out again with the item it applied last.
        case relayout
    }

    /// Replays the node: a keystroke appends to the field (the caret is at the end, which is also
    /// where a programmatic `text =` leaves it) and emits; an item applies through the filter.
    /// `onApply` sees the field after every item apply.
    private func replay(_ events: [Event], transform: (String) -> String = { $0 }, onApply: (String) -> Void = { _ in }) -> String {
        var filter = ItemListInputTextEchoFilter()
        var field = ""
        var emitted: [String] = []
        var lastItem: Item?
        for event in events {
            let item: Item
            switch event {
            case let .keystroke(character):
                field.append(character)
                emitted.append(field)
                filter.didEmit(field)
                continue
            case let .echo(index):
                item = Item(transform(emitted[index]))
            case let .ownerValue(value):
                item = Item(value)
            case .relayout:
                guard let lastItem else {
                    XCTFail("relayout before any item was applied")
                    continue
                }
                item = lastItem
            }
            lastItem = item
            if let text = filter.textToApply(incoming: item.text, fieldText: field, item: item) {
                field = text
            }
            onApply(field)
        }
        return field
    }

    /// One fresh owner item: a direct `textToApply` call that is never a relayout.
    private func apply(_ filter: inout ItemListInputTextEchoFilter, _ incoming: String, fieldText: String) -> String? {
        return filter.textToApply(incoming: incoming, fieldText: fieldText, item: Item(incoming))
    }

    /// Visits every schedule where echo `i` arrives after keystroke `i` and echoes stay in order (the
    /// item-list transition queue is FIFO), without materializing the whole set.
    private func forEachSchedule(of word: String, _ visit: ([Event]) -> Void) {
        let characters = Array(word)
        var current: [Event] = []
        current.reserveCapacity(characters.count * 2)
        func step(_ typed: Int, _ echoed: Int) {
            if typed == characters.count && echoed == characters.count {
                visit(current)
                return
            }
            if typed < characters.count {
                current.append(.keystroke(characters[typed]))
                step(typed + 1, echoed)
                current.removeLast()
            }
            if echoed < typed {
                current.append(.echo(echoed))
                step(typed, echoed + 1)
                current.removeLast()
            }
        }
        step(0, 0)
    }

    /// A schedule where every echo arrives `lag` keystrokes after its own edit (0 = paced typing);
    /// the remaining echoes drain once typing stops.
    private func fixedLagSchedule(of word: String, lag: Int) -> [Event] {
        let characters = Array(word)
        var events: [Event] = []
        var echoed = 0
        for (index, character) in characters.enumerated() {
            events.append(.keystroke(character))
            while echoed <= index - lag {
                events.append(.echo(echoed))
                echoed += 1
            }
        }
        while echoed < characters.count {
            events.append(.echo(echoed))
            echoed += 1
        }
        return events
    }

    func testFastTypingKeepsEveryCharacterForEveryEchoTimingOfShortQueries() {
        // Exhaustive: 42 schedules for 5 characters. "aaa" and "abab" repeat characters and prefixes.
        for word in ["Tasks", "vault", "aaa", "abab"] {
            var count = 0
            self.forEachSchedule(of: word) { schedule in
                count += 1
                XCTAssertEqual(self.replay(schedule), word, "schedule \(schedule)")
            }
            XCTAssertGreaterThan(count, 1)
        }
    }

    func testFastTypingKeepsEveryCharacterOfLongQueriesAtAnyFixedLag() {
        for word in ["Secret Vault", "Chat Lock", "Show Deleted Messages"] {
            for lag in 0 ... word.count {
                XCTAssertEqual(self.replay(self.fixedLagSchedule(of: word, lag: lag)), word, "lag \(lag)")
            }
        }
    }

    /// The interleaving that reproduces the QA truncation under the old unconditional write-back:
    /// "T" and "Ta" come back while newer text is already on screen.
    func testQAInterleavingDoesNotRewindTheField() {
        let events: [Event] = [
            .keystroke("T"), .keystroke("a"), .keystroke("s"),
            .echo(0),            // stale "T"
            .keystroke("k"),
            .echo(1),            // stale "Ta"
            .keystroke("s"),
            .echo(2), .echo(3), .echo(4)
        ]
        var applied: [String] = []
        XCTAssertEqual(self.replay(events, onApply: { applied.append($0) }), "Tasks")
        // The field never moved backwards on screen either.
        XCTAssertEqual(applied, ["Tas", "Task", "Tasks", "Tasks", "Tasks"])
    }

    func testOwnerResetIsAppliedWhileEchoesArePending() {
        let events: [Event] = [.keystroke("V"), .keystroke("a"), .ownerValue("")]
        XCTAssertEqual(self.replay(events), "")
    }

    func testOwnerResetIsAppliedAfterAllEchoesReturned() {
        let events: [Event] = [.keystroke("V"), .echo(0), .keystroke("a"), .echo(1), .ownerValue("")]
        XCTAssertEqual(self.replay(events), "")
    }

    func testTypingAfterAnOwnerResetConverges() {
        // The reset arrives while a later edit is still on its way back. The reset applies (the field
        // briefly shows it), the filter forgets the in-flight edit, and its echo then applies as an
        // owner value, ending on the newest text.
        let events: [Event] = [
            .keystroke("x"), .echo(0),
            .keystroke("y"),                // "xy"
            .ownerValue(""),                // reset computed before "xy" reached the owner
            .echo(1)                        // the owner then stored "xy"
        ]
        XCTAssertEqual(self.replay(events), "xy")
    }

    func testOwnerThatNormalizesTextStillWins() {
        // An owner that stores a transformed value never echoes the emitted text verbatim; its value
        // keeps being applied, exactly as before the fix.
        let events: [Event] = [.keystroke("a"), .echo(0), .keystroke("b"), .echo(1)]
        XCTAssertEqual(self.replay(events, transform: { $0.uppercased() }), "AB")
    }

    func testStaleClearDoesNotWipeNewerText() {
        var filter = ItemListInputTextEchoFilter()
        filter.didEmit("a")
        filter.didEmit("")   // cleared
        filter.didEmit("a")  // typed again
        XCTAssertNil(self.apply(&filter, "a", fieldText: "a"))
        XCTAssertNil(self.apply(&filter, "", fieldText: "a"))
        XCTAssertNil(self.apply(&filter, "a", fieldText: "a"))
    }

    func testCoalescedEchoesStillEndOnTheLatestText() {
        // Intermediate states merged: only "Tas" and then "Task" come back.
        var filter = ItemListInputTextEchoFilter()
        for text in ["T", "Ta", "Tas", "Task"] {
            filter.didEmit(text)
        }
        XCTAssertNil(self.apply(&filter, "Tas", fieldText: "Task"))
        XCTAssertNil(self.apply(&filter, "Task", fieldText: "Task"))
    }

    func testLatestEchoRepairsAFieldThatDriftedWithoutNotification() {
        var filter = ItemListInputTextEchoFilter()
        filter.didEmit("abc")
        XCTAssertEqual(self.apply(&filter, "abc", fieldText: "ab"), "abc")
    }

    /// Regression for the former 64-entry cap: 65 edits in flight made the first echo ("a") look like
    /// an owner change, the field rewound to "a", the next keystroke produced "ab", and the drained
    /// echoes ended on "ab" instead of 65 × "a" + "b".
    func testFirstEchoOfSixtyFiveInFlightEditsDoesNotRewindTheField() {
        var events: [Event] = Array(repeating: .keystroke("a"), count: 65)
        events.append(.echo(0))
        events.append(.keystroke("b"))
        for index in 1 ... 65 {
            events.append(.echo(index))
        }
        let expected = String(repeating: "a", count: 65) + "b"
        var applied: [String] = []
        XCTAssertEqual(self.replay(events, onApply: { applied.append($0) }), expected)
        XCTAssertEqual(applied.first, String(repeating: "a", count: 65), "the first echo must not rewind the field")
        XCTAssertTrue(applied.dropFirst().allSatisfy { $0 == expected })
    }

    /// The list re-applying the row's current item after every echo (neighbors inserted or removed
    /// by the search filter, or a width change).
    private func withRelayoutAfterEachEcho(_ events: [Event]) -> [Event] {
        return events.flatMap { event -> [Event] in
            if case .echo = event {
                return [event, .relayout]
            }
            return [event]
        }
    }

    /// Regression for a stale echo laid out twice: the first apply consumed it, so by text the second
    /// looked like an owner change and rewound "ab" to "a"; the next keystroke then ended on "ac".
    func testRelayoutOfAConsumedStaleEchoDoesNotRewindTheField() {
        let events: [Event] = [
            .keystroke("a"), .keystroke("b"),
            .echo(0),        // stale "a", skipped
            .relayout,       // the same "a" item again
            .keystroke("c"),
            .echo(1), .echo(2)
        ]
        var applied: [String] = []
        XCTAssertEqual(self.replay(events, onApply: { applied.append($0) }), "abc")
        XCTAssertEqual(applied, ["ab", "ab", "abc", "abc"])
    }

    func testTypingContinuesThroughRelayoutsForEveryEchoTimingOfShortQueries() {
        for word in ["Tasks", "vault", "abab"] {
            self.forEachSchedule(of: word) { schedule in
                XCTAssertEqual(self.replay(self.withRelayoutAfterEachEcho(schedule)), word, "schedule \(schedule)")
            }
        }
    }

    func testTypingContinuesThroughRelayoutsOfLongQueriesAtAnyFixedLag() {
        let word = "Secret Vault"
        for lag in 0 ... word.count {
            XCTAssertEqual(self.replay(self.withRelayoutAfterEachEcho(self.fixedLagSchedule(of: word, lag: lag))), word, "lag \(lag)")
        }
    }

    func testOwnerResetToTheSameValueAgainIsStillApplied() {
        // A new reset item is new owner state even when its text repeats the previous owner value.
        let events: [Event] = [.ownerValue(""), .keystroke("x"), .ownerValue("")]
        XCTAssertEqual(self.replay(events), "")
    }

    func testRelayoutOfAnOwnerResetDoesNotWipeTextTypedAfterIt() {
        let events: [Event] = [
            .keystroke("x"), .echo(0),
            .ownerValue(""),     // reset applies
            .keystroke("y"),
            .relayout,           // the reset item again, not a second reset
            .echo(1)
        ]
        var applied: [String] = []
        XCTAssertEqual(self.replay(events, onApply: { applied.append($0) }), "y")
        XCTAssertEqual(applied, ["x", "", "y", "y"])
    }

    func testOverflowCasesHoldWithRelayouts() {
        var events: [Event] = Array(repeating: .keystroke("a"), count: 65)
        events.append(.echo(0))
        events.append(.keystroke("b"))
        for index in 1 ... 65 {
            events.append(.echo(index))
        }
        XCTAssertEqual(self.replay(self.withRelayoutAfterEachEcho(events)), String(repeating: "a", count: 65) + "b")

        let word = String(repeating: "Zenlygram ", count: 300)
        var shortest = Int.max
        let result = self.replay(self.withRelayoutAfterEachEcho(self.fixedLagSchedule(of: word, lag: word.count)), onApply: { shortest = min(shortest, $0.count) })
        XCTAssertEqual(result, word)
        XCTAssertEqual(shortest, word.count)
    }

    func testThousandsOfEditsInFlightStillEndOnTheTypedText() {
        let word = String(repeating: "Zenlygram ", count: 300)
        var shortest = Int.max
        let result = self.replay(self.fixedLagSchedule(of: word, lag: word.count), onApply: { shortest = min(shortest, $0.count) })
        XCTAssertEqual(result, word)
        XCTAssertEqual(shortest, word.count, "no echo rewound the field")
    }
}
