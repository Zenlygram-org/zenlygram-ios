import Foundation
import SGSimpleSettings

/// Localized strings for the redacted in-app notification banner shown for messages
/// arriving in Chat-Lock-locked chats. Self-contained en/uz/ru (same pattern as
/// FenixuzL10n+ChatLock.swift) and kept in its own file so concurrent work on the
/// other ChatLock sources never conflicts.
public enum ChatLockNotificationStrings {

    /// Generic banner title replacing the sender/chat name.
    public static var redactedTitle: String {
        localized(en: "New Message", uz: "Yangi xabar", ru: "Новое сообщение")
    }

    /// Generic banner body replacing the message content.
    public static var redactedText: String {
        localized(en: "Message in a locked chat", uz: "Qulflangan chatdagi xabar", ru: "Сообщение в заблокированном чате")
    }

    private static func localized(en: String, uz: String, ru: String) -> String {
        let lang = SGSimpleSettings.shared.languageCode
        switch lang {
        case "uz": return uz
        case "ru": return ru
        default:   return en
        }
    }
}
