// MARK: Zenlygram — call recording: what an explicit Record tap on the call screen may lead to.
//
// Kept here, free of UI, so the rules are testable:
//
//   * One tap, at most one prompt. While a consent prompt (or the iOS Call Integration explanation)
//     is on screen, further taps do nothing — a fast double tap must not stack two consent alerts,
//     each of which could later be accepted on its own.
//   * Accepting consent counts only for the prompt that is still current, and only if the call can
//     STILL start a recording at that moment. A prompt answered after the call ended, became a
//     conference or dropped back to connecting records nothing — not even the acceptance, so a stale
//     prompt cannot leave consent behind for a later call (or a later user after a logout).
//   * Cancel, a tap outside, or the prompt going away records nothing and starts nothing.
//   * Once the call has ended, nothing can be started from its screen any more. Stop is always
//     honoured.
//
// Nothing here starts a recording by itself: every `.start` / `.acceptAndStart` is the answer to an
// explicit user action, and the recorder re-checks consent, the account and the call on its own.

import Foundation

/// The call as the call screen sees it at the instant it has to decide.
public struct SGCallRecordingCallStatus: Equatable {
    public let isRecording: Bool
    /// The recorder would accept a start now (connected 1:1 call, feature available, CallKit on).
    public let canStart: Bool
    /// The only thing missing is iOS Call Integration, which the user switched off.
    public let requiresCallKit: Bool

    public init(isRecording: Bool, canStart: Bool, requiresCallKit: Bool) {
        self.isRecording = isRecording
        self.canStart = canStart
        self.requiresCallKit = requiresCallKit
    }
}

/// Identifies one presented prompt, so an answer can be matched to the prompt that is still current.
public struct SGCallRecordingPromptTicket: Equatable {
    fileprivate let value: Int
}

public enum SGCallRecordingTapDecision: Equatable {
    case stop
    /// Consent was given before: start now.
    case start
    /// Present the consent prompt; its answer goes back through `accept` / `promptClosed`.
    case askConsent(SGCallRecordingPromptTicket)
    /// Present the iOS Call Integration explanation; its closing goes back through `promptClosed`.
    case explainCallKitRequirement(SGCallRecordingPromptTicket)
    case ignore
}

public enum SGCallRecordingConsentDecision: Equatable {
    /// Store the acceptance and start this call's recording.
    case acceptAndStart
    /// Store nothing, start nothing.
    case discard
}

/// One per call screen (which is bound to one call). Main-queue only, like the screen.
public final class SGCallRecordingConsentFlow {
    private var pendingTicket: SGCallRecordingPromptTicket?
    private var nextTicketValue: Int = 0
    private var hasCallEnded: Bool = false

    public init() {
    }

    public var isPromptPending: Bool {
        return self.pendingTicket != nil
    }

    public func tap(status: SGCallRecordingCallStatus, consentAccepted: Bool) -> SGCallRecordingTapDecision {
        if status.isRecording {
            return .stop
        }
        if self.hasCallEnded || self.pendingTicket != nil {
            return .ignore
        }
        if status.requiresCallKit {
            return .explainCallKitRequirement(self.makePendingTicket())
        }
        if !status.canStart {
            return .ignore
        }
        if consentAccepted {
            return .start
        }
        return .askConsent(self.makePendingTicket())
    }

    /// The consent prompt's accept action. `status` must be read at the moment of the answer.
    public func accept(_ ticket: SGCallRecordingPromptTicket, status: SGCallRecordingCallStatus) -> SGCallRecordingConsentDecision {
        guard self.pendingTicket == ticket else {
            return .discard
        }
        self.pendingTicket = nil
        if self.hasCallEnded || status.isRecording || !status.canStart {
            return .discard
        }
        return .acceptAndStart
    }

    /// The prompt was cancelled, tapped away, or dismissed by anything else.
    public func promptClosed(_ ticket: SGCallRecordingPromptTicket) {
        if self.pendingTicket == ticket {
            self.pendingTicket = nil
        }
    }

    /// The presented prompt no longer exists (its window went away without dismissing it), so it can
    /// never be answered and must not keep blocking the button.
    public func abandonPendingPrompt() {
        self.pendingTicket = nil
    }

    /// The call is terminating. Any open prompt is void and nothing can be started any more.
    public func callEnded() {
        self.hasCallEnded = true
        self.pendingTicket = nil
    }

    private func makePendingTicket() -> SGCallRecordingPromptTicket {
        self.nextTicketValue += 1
        let ticket = SGCallRecordingPromptTicket(value: self.nextTicketValue)
        self.pendingTicket = ticket
        return ticket
    }
}

/// Whether a Record button can start anything on this device — what an empty recordings list should
/// point the user to. Mirrors the call screen: no iOS Call Integration on this device (simulator,
/// region) means no Record button at all; switched off means the button explains the requirement.
public enum SGCallRecordingStartSupport: Equatable {
    /// This build cannot start recordings.
    case featureUnavailable
    /// iOS Call Integration does not exist here, so the call screen never offers Record.
    case unsupportedOnDevice
    /// iOS Call Integration exists but is switched off in the app's call settings.
    case requiresCallKit
    case available

    public init(isFeatureAvailable: Bool, isCallKitAvailable: Bool, isCallKitEnabled: Bool) {
        if !isFeatureAvailable {
            self = .featureUnavailable
        } else if !isCallKitAvailable {
            self = .unsupportedOnDevice
        } else if !isCallKitEnabled {
            self = .requiresCallKit
        } else {
            self = .available
        }
    }
}
