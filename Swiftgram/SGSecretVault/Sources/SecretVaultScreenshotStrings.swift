import Foundation
import SGSimpleSettings

/// Localized strings for the vault screenshot-detection notice. Kept in their own file
/// (rather than SecretVaultStrings.swift) so concurrent work on the main strings file
/// never conflicts; same self-contained en/uz/ru pattern.
public extension SecretVaultStrings {

    static var screenshotNoticeTitle: String {
        screenshotLocalized(en: "Screenshot detected", uz: "Skrinshot aniqlandi", ru: "Обнаружен скриншот")
    }

    static var screenshotNoticeText: String {
        screenshotLocalized(
            en: "The screenshot may reveal your hidden chats.",
            uz: "Skrinshot yashirin chatlaringizni oshkor qilishi mumkin.",
            ru: "Скриншот может раскрыть ваши скрытые чаты."
        )
    }
}

private func screenshotLocalized(en: String, uz: String, ru: String) -> String {
    let lang = SGSimpleSettings.shared.languageCode
    switch lang {
    case "uz": return uz
    case "ru": return ru
    default:   return en
    }
}
