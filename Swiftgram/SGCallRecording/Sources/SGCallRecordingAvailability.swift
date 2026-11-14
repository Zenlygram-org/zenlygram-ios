// MARK: Zenlygram — call recording, compile-time availability.

import Foundation

import SGSimpleSettings

/// The single compile-time gate for local call recording.
///
/// New recording entry points and `SGCallRecordingSession.start` read this constant. Existing
/// recordings remain available for protected local playback and deletion when it is false;
/// disabling recording must not make stored private audio impossible to remove.
///
/// Availability never replaces explicit local consent, the user's Record action, a live 1:1 call
/// or the CallKit recording indicator. Enabling it does not enable automatic sending.
///
/// Deliberately NOT an entitlement capability and not a paid feature: a server that can turn
/// recording on remotely is the opposite of what the consent story promises.
public let sgCallRecordingAvailable: Bool = true

/// The user-facing gates that sit on top of the compile-time one. Kept here so the rules are stated
/// once and every caller (call screen, settings, the session itself) reads the same thing.
public enum SGCallRecordingGate {
    /// Has the user accepted the one-time consent screen? Recording never starts without it, and the
    /// acceptance is never assumed, re-derived or set by anything but that screen.
    public static var consentAccepted: Bool {
        get {
            return SGSimpleSettings.shared.callRecordingConsentAccepted
        }
        set {
            SGSimpleSettings.shared.callRecordingConsentAccepted = newValue
        }
    }

    /// "Tell the other party" — off by default, and honest about what it does: it sends an ordinary
    /// chat message and plays a tone in the user's own ear. It cannot inject audio into the call
    /// itself (see SGCallRecordingSession's header comment).
    public static var notifyOtherParty: Bool {
        get {
            return SGSimpleSettings.shared.callRecordingNotifyOtherParty
        }
        set {
            SGSimpleSettings.shared.callRecordingNotifyOtherParty = newValue
        }
    }

    /// "Send to Saved Messages" — off by default, and the ONLY thing that makes a finished
    /// recording upload itself.
    ///
    /// While it is false nothing is ever uploaded on its own: the manual per-recording action is
    /// the user tapping it in that moment, exactly like the share sheet, and it does not read this.
    /// Turning it on is the point at which the user is told, in the setting's own description, that
    /// the recording goes to a Telegram cloud chat, is stored on Telegram's servers, is not
    /// end-to-end encrypted, and contains the other party's voice as well as their own.
    public static var sendToSavedMessages: Bool {
        get {
            return SGSimpleSettings.shared.callRecordingSendToSavedMessages
        }
        set {
            SGSimpleSettings.shared.callRecordingSendToSavedMessages = newValue
        }
    }
}
