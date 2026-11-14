import Foundation
import SGSimpleSettings

/// Zenlygram — copy for the protection RECOVERY states (audit batch 4: #70, #71, #41, #40).
///
/// Self-contained en/uz/ru, like the module's other strings (FenixuzL10n+ChatLock), so SGChatLock never has to
/// reach for the central localization. Every line is honest about what this build can and cannot do:
/// - PINs and the hidden-chat list live ONLY on the iPhone where they were set ("this iPhone"), so a backup,
///   an encrypted backup or Quick Start never carries them over;
/// - chats that were hidden are visible again, because their membership was device-only too;
/// - per-chat PINs cannot be told apart after the credentials are gone, so ONE new PIN replaces all of them.
public enum SGProtectionStrings {

    // MARK: - Device-owner authentication

    /// LocalAuthentication reason for every recovery action (the old credential no longer exists, so device
    /// ownership is the only proof left).
    public static var authReason: String {
        localized(
            en: "Confirm it's you to set up your chat protection again",
            uz: "Chat himoyasini qayta sozlash uchun shaxsingizni tasdiqlang",
            ru: "Подтвердите личность, чтобы заново настроить защиту чатов"
        )
    }

    /// Audit batch 4: every recovery action asks the device owner to confirm, and an iPhone with neither a
    /// passcode nor an enrolled biometric has nothing to confirm WITH. The flows report `.unavailable`
    /// instead of a silent cancel, and this is what the user is told. Distinct from
    /// `FenixuzChatLockStrings.recoveryUnavailable*`, which is about the in-app vault "Forgot" ladder —
    /// that one deliberately never accepts the iPhone passcode; this one asks for exactly that passcode.
    public static var deviceAuthUnavailableTitle: String {
        localized(
            en: "Set a device passcode first",
            uz: "Avval qurilma parolini o'rnating",
            ru: "Сначала задайте код-пароль"
        )
    }

    public static var deviceAuthUnavailableText: String {
        localized(
            en: "Setting protection up again asks you to confirm it's you, and this device has no passcode and no Face ID / Touch ID. Open the iOS Settings app > Face ID & Passcode (or Touch ID & Passcode), turn the passcode on, then come back here.",
            uz: "Himoyani qayta sozlash uchun shaxsingizni tasdiqlash so'raladi, bu qurilmada esa na parol, na Face ID / Touch ID bor. iOS Sozlamalar ilovasida Face ID va parol (yoki Touch ID va parol) bo'limini oching, parolni yoqing va bu yerga qayting.",
            ru: "Чтобы заново настроить защиту, нужно подтвердить личность, а на этом устройстве нет ни код-пароля, ни Face ID / Touch ID. Откройте приложение «Настройки» > «Face ID и код-пароль» (или «Touch ID и код-пароль»), включите код-пароль и вернитесь сюда."
        )
    }

    /// The same thing as one line inside the recovery sheet, above the actions it disables.
    public static var deviceAuthUnavailableHint: String {
        localized(
            en: "These actions need you to confirm it's you, so they stay off until this device has a passcode (iOS Settings > Face ID & Passcode).",
            uz: "Bu amallar uchun shaxsingizni tasdiqlash kerak, shuning uchun bu qurilmada parol o'rnatilmaguncha ular ishlamaydi (iOS Sozlamalar > Face ID va parol).",
            ru: "Для этих действий нужно подтвердить личность, поэтому они недоступны, пока на устройстве нет код-пароля («Настройки» > «Face ID и код-пароль»)."
        )
    }

    /// Dismiss action for the alerts this module presents itself ("OK" is the same word in en/uz/ru).
    public static var ok: String {
        return "OK"
    }

    // MARK: - Launch notice (chat list, once)

    public static var recoveryAlertTitle: String {
        localized(en: "Set up protection again", uz: "Himoyani qayta sozlang", ru: "Настройте защиту заново")
    }

    /// The one-time notice after a restore. `hiddenCount`: chats that were hidden and are visible again (0
    /// omits that sentence — pass the last known vault member count only when the membership was lost).
    /// `lockedCount`: chats still covered by Chat Lock.
    public static func recoveryAlertText(vault: Bool, chatLock: Bool, hiddenCount: Int, lockedCount: Int) -> String {
        var parts: [String] = []
        if vault && chatLock {
            parts.append(localized(
                en: "Your Secret Vault PIN and your Chat Lock pincodes are not on this device. They are kept only on the device where they were set — a backup or Quick Start does not carry them over.",
                uz: "Maxfiy seyf PIN kodi va chat qulfi pinkodlari bu qurilmada yo'q. Ular faqat o'rnatilgan qurilmada saqlanadi — zaxira nusxa yoki Quick Start ularni ko'chirmaydi.",
                ru: "PIN-кода Секретного хранилища и пин-кодов блокировки чатов нет на этом устройстве. Они хранятся только на том устройстве, где были заданы, — резервная копия и «Быстрое начало» их не переносят."
            ))
        } else if vault {
            parts.append(localized(
                en: "Your Secret Vault PIN is not on this device. It is kept only on the device where it was set — a backup or Quick Start does not carry it over.",
                uz: "Maxfiy seyf PIN kodi bu qurilmada yo'q. U faqat o'rnatilgan qurilmada saqlanadi — zaxira nusxa yoki Quick Start uni ko'chirmaydi.",
                ru: "PIN-кода Секретного хранилища нет на этом устройстве. Он хранится только на том устройстве, где был задан, — резервная копия и «Быстрое начало» его не переносят."
            ))
        } else {
            parts.append(localized(
                en: "Your Chat Lock pincodes are not on this device. They are kept only on the device where they were set — a backup or Quick Start does not carry them over.",
                uz: "Chat qulfi pinkodlari bu qurilmada yo'q. Ular faqat o'rnatilgan qurilmada saqlanadi — zaxira nusxa yoki Quick Start ularni ko'chirmaydi.",
                ru: "Пин-кодов блокировки чатов нет на этом устройстве. Они хранятся только на том устройстве, где были заданы, — резервная копия и «Быстрое начало» их не переносят."
            ))
        }
        if vault {
            if hiddenCount > 0 {
                parts.append(String(format: localized(
                    en: "The %@ that were hidden are visible again: the list of hidden chats stayed behind too.",
                    uz: "Berkitilgan %@ yana ko'rinadi: yashirin chatlar ro'yxati ham o'sha qurilmada qoldi.",
                    ru: "%@, которые были скрыты, снова видны: список скрытых чатов тоже остался там."
                ), self.chats(hiddenCount)))
            }
            parts.append(localized(
                en: "Set a new vault PIN to use the Secret Vault on this device. Your messages are untouched.",
                uz: "Bu qurilmada maxfiy seyfdan foydalanish uchun yangi PIN kod o'rnating. Xabarlaringizga hech narsa bo'lmaydi.",
                ru: "Задайте новый PIN, чтобы пользоваться Секретным хранилищем на этом устройстве. С сообщениями ничего не произошло."
            ))
        }
        if chatLock {
            if lockedCount > 0 {
                parts.append(String(format: localized(
                    en: "%@ stay covered here. One new pincode replaces all of them, or you can turn Chat Lock off.",
                    uz: "%@ bu yerda yopiq qoladi. Ularning barchasi uchun bitta yangi pinkod o'rnatiladi yoki chat qulfini o'chirishingiz mumkin.",
                    ru: "%@ остаются закрытыми. Один новый пин-код заменит их все, либо отключите блокировку чатов."
                ), self.lockedChats(lockedCount)))
            } else {
                parts.append(localized(
                    en: "Set a new pincode for Chat Lock, or turn it off.",
                    uz: "Chat qulfi uchun yangi pinkod o'rnating yoki uni o'chiring.",
                    ru: "Задайте новый пин-код для блокировки чатов или отключите её."
                ))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Vault recovery

    public static var vaultLostTitle: String {
        localized(en: "Secret Vault needs a new PIN", uz: "Maxfiy seyfga yangi PIN kerak", ru: "Хранилищу нужен новый PIN")
    }

    /// `count`: chats that were hidden and are visible again (0 omits that sentence).
    public static func vaultLostText(count: Int) -> String {
        var parts = [localized(
            en: "The vault PIN stays on the device where it was set, so it is not on this one.",
            uz: "Seyf PIN kodi o'rnatilgan qurilmada qoladi, shuning uchun u bu qurilmada yo'q.",
            ru: "PIN хранилища остаётся на том устройстве, где был задан, поэтому на этом его нет."
        )]
        if count > 0 {
            parts.append(String(format: localized(
                en: "The %@ that were hidden are visible again.",
                uz: "Berkitilgan %@ yana ko'rinadi.",
                ru: "%@, которые были скрыты, снова видны."
            ), self.chats(count)))
        }
        parts.append(localized(
            en: "A new PIN starts an empty vault. Your messages are untouched.",
            uz: "Yangi PIN kod bilan seyf bo'sh holda boshlanadi. Xabarlaringizga hech narsa bo'lmaydi.",
            ru: "С новым PIN хранилище начнётся пустым. С сообщениями ничего не произойдёт."
        ))
        return parts.joined(separator: " ")
    }

    public static var vaultUnverifiableTitle: String {
        localized(en: "Vault PIN cannot be checked", uz: "Seyf PIN kodini tekshirib bo'lmaydi", ru: "PIN хранилища нельзя проверить")
    }

    public static var vaultUnverifiableText: String {
        localized(
            en: "This device no longer has what it takes to check the saved vault PIN, so even the right one is refused. Set a new vault PIN to use the vault again. Your messages are untouched.",
            uz: "Bu qurilmada saqlangan seyf PIN kodini tekshirish uchun kerakli ma'lumot qolmagan, shuning uchun to'g'ri PIN ham qabul qilinmaydi. Seyfdan yana foydalanish uchun yangi PIN kod o'rnating. Xabarlaringizga hech narsa bo'lmaydi.",
            ru: "На этом устройстве не осталось того, чем проверяется сохранённый PIN хранилища, поэтому даже правильный PIN не принимается. Задайте новый PIN, чтобы снова пользоваться хранилищем. С сообщениями ничего не произойдёт."
        )
    }

    // MARK: - Chat Lock recovery

    public static var chatLockLostTitle: String {
        localized(en: "Chat Lock needs a new pincode", uz: "Chat qulfiga yangi pinkod kerak", ru: "Блокировке чатов нужен новый пин-код")
    }

    /// `count`: chats still covered.
    public static func chatLockLostText(count: Int) -> String {
        var parts = [localized(
            en: "The pincodes of your locked chats stay on the device where they were set, so they are not on this one.",
            uz: "Qulflangan chatlaringizning pinkodlari o'rnatilgan qurilmada qoladi, shuning uchun ular bu qurilmada yo'q.",
            ru: "Пин-коды заблокированных чатов остаются на том устройстве, где были заданы, поэтому на этом их нет."
        )]
        if count > 0 {
            parts.append(String(format: localized(
                en: "%@ stay covered.",
                uz: "%@ yopiq qoladi.",
                ru: "%@ остаются закрытыми."
            ), self.lockedChats(count)))
        }
        parts.append(localized(
            en: "One new pincode replaces the pincodes of all of them — they cannot be told apart any more. Your messages are untouched.",
            uz: "Bitta yangi pinkod ularning barchasining pinkodini almashtiradi — endi ularni ajratib bo'lmaydi. Xabarlaringizga hech narsa bo'lmaydi.",
            ru: "Один новый пин-код заменит пин-коды всех этих чатов — различить их уже нельзя. С сообщениями ничего не произойдёт."
        ))
        return parts.joined(separator: " ")
    }

    // MARK: - Actions

    public static var setNewVaultPin: String {
        localized(en: "Set a new vault PIN", uz: "Yangi seyf PIN kodini o'rnatish", ru: "Задать новый PIN хранилища")
    }

    public static var setNewChatLockPin: String {
        localized(en: "Set a new pincode for locked chats", uz: "Qulflangan chatlarga yangi pinkod", ru: "Задать новый пин-код для чатов")
    }

    public static var turnOffVault: String {
        localized(en: "Turn off Secret Vault", uz: "Maxfiy seyfni o'chirish", ru: "Отключить Секретное хранилище")
    }

    public static var turnOffChatLock: String {
        localized(en: "Turn off Chat Lock", uz: "Chat qulfini o'chirish", ru: "Отключить блокировку чатов")
    }

    public static var reviewMutedChats: String {
        localized(en: "Review muted chats", uz: "Ovozsiz chatlarni ko'rib chiqish", ru: "Проверить беззвучные чаты")
    }

    public static var later: String {
        localized(en: "Later", uz: "Keyinroq", ru: "Позже")
    }

    // MARK: - Settings rows

    public static var needsSetup: String {
        localized(en: "Needs setup", uz: "Sozlash kerak", ru: "Нужна настройка")
    }

    public static var restoreProtectionRow: String {
        localized(en: "Restore protection", uz: "Himoyani tiklash", ru: "Восстановить защиту")
    }

    public static var recoveryNotice: String {
        localized(
            en: "Protection pincodes are kept only on the device where they were set and never move to another one. Set them up again on this device.",
            uz: "Himoya pinkodlari faqat o'rnatilgan qurilmada saqlanadi va boshqasiga ko'chmaydi. Ularni bu qurilmada qaytadan sozlang.",
            ru: "Пин-коды защиты хранятся только на том устройстве, где были заданы, и не переносятся на другое. Настройте их заново на этом устройстве."
        )
    }

    /// Audit batch 4 (post-migration dead search): the "Reveal with a secret code" row used to DISAPPEAR
    /// while the vault waits for recovery, so nothing on screen connected a paused chat search to the vault.
    /// The row stays, inert, and says why.
    public static var secretCodePausedValue: String {
        localized(en: "Paused", uz: "To'xtatilgan", ru: "Приостановлено")
    }

    /// `searchPaused`: the secret-code reveal is still switched on, so the chat-list search field is holding
    /// what is typed into it instead of searching Telegram (it cannot tell a vault PIN from a query while the
    /// vault credential is unreadable).
    public static func secretCodePausedNotice(searchPaused: Bool) -> String {
        if searchPaused {
            return localized(
                en: "\"Reveal with a secret code\" cannot be changed until the Secret Vault is set up again on this device. Until then, searching in the chat list is paused: what you type there is kept on this device and is not sent to Telegram. Tap this row to set the vault up again.",
                uz: "\"Maxfiy kod bilan ochish\" sozlamasini maxfiy seyf bu qurilmada qaytadan sozlanmaguncha o'zgartirib bo'lmaydi. Shu paytgacha chatlar ro'yxatidagi qidiruv to'xtatilgan: u yerga yozganingiz shu qurilmada qoladi va Telegram'ga yuborilmaydi. Seyfni qaytadan sozlash uchun shu qatorni bosing.",
                ru: "«Показывать по секретному коду» нельзя изменить, пока Секретное хранилище не настроено заново на этом устройстве. До этого поиск в списке чатов приостановлен: набранное остаётся на этом устройстве и не отправляется в Telegram. Нажмите эту строку, чтобы настроить хранилище заново."
            )
        }
        return localized(
            en: "\"Reveal with a secret code\" cannot be changed until the Secret Vault is set up again on this device. Tap this row to set it up again.",
            uz: "\"Maxfiy kod bilan ochish\" sozlamasini maxfiy seyf bu qurilmada qaytadan sozlanmaguncha o'zgartirib bo'lmaydi. Uni qaytadan sozlash uchun shu qatorni bosing.",
            ru: "«Показывать по секретному коду» нельзя изменить, пока Секретное хранилище не настроено заново на этом устройстве. Нажмите эту строку, чтобы настроить его заново."
        )
    }

    // MARK: - "Review muted chats" screen (audit #74)

    public static var mutedReviewTitle: String {
        localized(en: "Muted chats", uz: "Ovozsiz chatlar", ru: "Беззвучные чаты")
    }

    public static func mutedReviewHeader(count: Int) -> String {
        return String(format: localized(
            en: "%@ muted forever",
            uz: "%@ butunlay ovozsiz",
            ru: "%@ без звука навсегда"
        ), self.chats(count))
    }

    public static var mutedReviewFooter: String {
        localized(
            en: "The Secret Vault mutes the chats it hides. After a restore it cannot tell those apart from chats you muted yourself, so nothing is selected — pick the ones to unmute.",
            uz: "Maxfiy seyf berkitgan chatlarini ovozsiz qiladi. Ko'chirishdan keyin ularni o'zingiz ovozsiz qilgan chatlardan ajratib bo'lmaydi, shuning uchun hech narsa tanlanmagan — ovozini yoqmoqchi bo'lganlaringizni belgilang.",
            ru: "Секретное хранилище выключает звук у чатов, которые скрывает. После переноса их не отличить от чатов, которые вы выключили сами, поэтому ничего не выбрано — отметьте те, где включить звук."
        )
    }

    public static func mutedReviewUnmuteSelected(count: Int) -> String {
        return String(format: localized(
            en: "Unmute %d",
            uz: "%d tasining ovozini yoqish",
            ru: "Включить звук: %d"
        ), count)
    }

    public static func mutedReviewConfirmText(count: Int) -> String {
        return String(format: localized(
            en: "Turn notifications back on for %@? Chats you muted yourself will notify again too.",
            uz: "%@ uchun bildirishnomalar yoqilsinmi? O'zingiz ovozsiz qilgan chatlar ham yana bildirishnoma beradi.",
            ru: "Включить уведомления для %@? Чаты, которые вы выключили сами, тоже начнут уведомлять."
        ), self.chats(count))
    }

    // MARK: - Helpers

    /// "3 chats" / "3 ta chat" / "3 чата" (the Russian form agrees with the number).
    private static func chats(_ count: Int) -> String {
        return localized(
            en: count == 1 ? "1 chat" : "\(count) chats",
            uz: "\(count) ta chat",
            ru: "\(count) " + ruPlural(count, one: "чат", few: "чата", many: "чатов")
        )
    }

    private static func lockedChats(_ count: Int) -> String {
        return localized(
            en: count == 1 ? "1 locked chat" : "\(count) locked chats",
            uz: "\(count) ta qulflangan chat",
            ru: "\(count) " + ruPlural(count, one: "заблокированный чат", few: "заблокированных чата", many: "заблокированных чатов")
        )
    }

    private static func ruPlural(_ count: Int, one: String, few: String, many: String) -> String {
        let tens = count % 100
        if tens >= 11 && tens <= 14 {
            return many
        }
        switch count % 10 {
        case 1:
            return one
        case 2, 3, 4:
            return few
        default:
            return many
        }
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
