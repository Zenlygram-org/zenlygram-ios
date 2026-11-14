// MARK: Zenlygram — call recording: what one row of the recordings list may show and offer.
//
// Kept here, free of UI, so the rules are testable and the list cannot drift from them:
//
//   * A LIVE recording (the call is still being recorded; its sidecar is written at start, so it has
//     a row) is a half-written file. It is labelled "recording now" — not "0:00 · stops early", the
//     label of a recording that was cut off — and offers no Play, Share or Send: only Delete, which
//     is durably deferred until the call ends.
//   * A recording of a protected chat is listed REDACTED (no name, no date, no duration). Playing,
//     sharing or sending it first needs the app's existing local authorization for that chat.
//   * A recording whose identity cannot be verified is redacted and offers Delete only.
//   * While recording itself is unavailable, nothing is exported: Share and Send are not offered,
//     but existing recordings can still be played locally and deleted.
//   * Status comes FIRST — in the right-hand label and at the start of the detail line — so the
//     one-line truncation of the detail can only ever eat the date or the size, never the "not sent"
//     or "stops early" that tells the user their only copy is still here.

import Foundation

public enum SGCallRecordingRowBadge: Equatable {
    case live
    case playing
    case sendFailed
    case incomplete
    case sending

    /// Badges that warn the user something did not go as expected.
    public var isWarning: Bool {
        switch self {
        case .sendFailed, .incomplete:
            return true
        case .live, .playing, .sending:
            return false
        }
    }
}

public struct SGCallRecordingRowPresentation: Equatable {
    /// Name, date and duration are withheld.
    public let isRedacted: Bool
    /// Most important first. The first one is the row's spoken/visible status.
    public let badges: [SGCallRecordingRowBadge]
    public let showsDate: Bool
    public let showsDuration: Bool
    public let canPlay: Bool
    public let canShare: Bool
    /// Still subject to the delivery's own `canSendManually` (account signed in, nothing in flight).
    public let canSend: Bool
    /// Play / Share / Send must pass `ChatLockSession.requireUnlock` for the recorded pair first.
    public let requiresAuthorization: Bool

    public var primaryBadge: SGCallRecordingRowBadge? {
        return self.badges.first
    }

    public init(privacy: SGCallRecordingPrivacy, isLive: Bool, isPlaying: Bool, isSendWaiting: Bool, isSendFailed: Bool, isComplete: Bool, isExportAvailable: Bool) {
        var badges: [SGCallRecordingRowBadge] = []
        if isLive {
            badges.append(.live)
        } else {
            if isPlaying {
                badges.append(.playing)
            }
            if isSendFailed {
                badges.append(.sendFailed)
            }
            if !isComplete {
                badges.append(.incomplete)
            }
            if isSendWaiting {
                badges.append(.sending)
            }
        }
        self.badges = badges
        self.isRedacted = privacy != .open
        self.showsDate = !self.isRedacted
        self.showsDuration = !self.isRedacted && !isLive
        let isPlayable: Bool
        switch privacy {
        case .open, .protected:
            isPlayable = !isLive
        case .unverifiable:
            isPlayable = false
        }
        self.canPlay = isPlayable
        self.canShare = isPlayable && isExportAvailable
        self.canSend = isPlayable && isExportAvailable
        if case .protected = privacy {
            self.requiresAuthorization = true
        } else {
            self.requiresAuthorization = false
        }
    }
}
