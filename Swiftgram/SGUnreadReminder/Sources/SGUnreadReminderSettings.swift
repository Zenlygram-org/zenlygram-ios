import Foundation
import SGSimpleSettings

/// Shared accessor for the "Unread message reminder" settings.
///
/// Ported from Novagram's FenixuzUnreadReminderSettings, but rewired onto
/// SGSimpleSettings (the Swiftgram fork's persisted-flag store) and stripped of
/// the bundled-.caf custom-sound support — the reminder uses the system default
/// notification sound. Enable + minute-threshold only.
public enum SGUnreadReminderSettings {
    // Default reminder threshold (minutes) when the user has not picked one.
    public static let defaultMinutes = 5

    // Selectable minute thresholds shown in the picker.
    public static let minuteOptions: [Int] = [1, 5, 10, 30, 60]

    public static var isEnabled: Bool {
        SGSimpleSettings.shared.unreadReminderEnabled
    }

    public static var minutes: Int {
        let value = Int(SGSimpleSettings.shared.unreadReminderMinutes)
        return value > 0 ? value : defaultMinutes
    }
}
