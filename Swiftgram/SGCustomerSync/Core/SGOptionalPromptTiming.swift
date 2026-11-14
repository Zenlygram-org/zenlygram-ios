import Foundation

/// Zenlygram — WHEN an optional build shows its consent prompt (wf15 §6.2, D1 "bir marta").
///
/// An optional build's account root prompts at most once per attach. Before wf15 that one prompt
/// went up at attach (the first evaluation after the root was added). Now the account's FIRST
/// prompt — `.prompt(.none)`, the record in state `none`, the account never decided — waits until
/// Vazifalar is opened for the first time (`armed`), so the one consent screen appears where the
/// data it asks about is used; it is still shown at most once per attach. Every other prompt
/// (reconsent, operatorChanged, linkEnded: a record that once was granted) keeps the attach timing.
/// The forced prompt from Data & consent is decided outside this rule (the presenter asks whatever
/// this rule says when `isForcedPrompt` is set).
///
/// Pure: the presenter feeds it the entry's two flags and what the wall policy asks, and stores
/// the answer's `decided` back. Nothing here reads a store or a screen.
public enum SGOptionalPromptTiming {
    /// What the wall policy asks of an optional build, with no wall or prompt on screen.
    public enum Ask: Equatable {
        /// `.none` presentation: nothing to ask (granted and usable, declined, withdrawn, deleted).
        case nothing
        /// `.prompt(.none)`: the account's first prompt (state `none`).
        case firstPrompt
        /// Any other `.prompt(notice)`: reconsent, operatorChanged, linkEnded.
        case otherPrompt
    }

    public struct Outcome: Equatable {
        /// The prompt goes up now.
        public let shows: Bool
        /// The entry's `promptDecided` after this evaluation.
        public let decided: Bool

        public init(shows: Bool, decided: Bool) {
            self.shows = shows
            self.decided = decided
        }
    }

    /// The spec's rule (§6.2): a first prompt is shown only when `armed && !decided`; any other
    /// prompt only when `!decided` (today's attach timing).
    public static func shouldShow(armed: Bool, decided: Bool, kindIsFirstPrompt: Bool) -> Bool {
        return SGOptionalPromptTiming.decide(ask: kindIsFirstPrompt ? .firstPrompt : .otherPrompt, armed: armed, decided: decided).shows
    }

    /// The rule with its state transition. `decided` becomes true when a prompt is shown, when
    /// nothing needs asking, or when another prompt was already decided; a first prompt that waits
    /// for Vazifalar leaves it false, so the open of Vazifalar can still show it.
    public static func decide(ask: Ask, armed: Bool, decided: Bool) -> Outcome {
        switch ask {
        case .nothing:
            return Outcome(shows: false, decided: true)
        case .firstPrompt:
            let shows = armed && !decided
            return Outcome(shows: shows, decided: decided || shows)
        case .otherPrompt:
            return Outcome(shows: !decided, decided: true)
        }
    }
}
