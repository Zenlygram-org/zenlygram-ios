import Foundation
import SGSimpleSettings

// Localized strings used exclusively by the ChatLock module.
// Keeping them here avoids touching the central FenixuzL10n.swift
// (owned by a separate agent) and makes the whole module self-contained.
//
// Usage: FenixuzChatLockStrings.title(.set, isDark: …)

public enum FenixuzChatLockStrings {

    // MARK: - Lock type labels

    static func pinTitle(mode: ChatLockSetupStep) -> String {
        switch mode {
        case .enterNew:    return localized(en: "Set PIN", uz: "PIN o'rnating", ru: "Установить PIN")
        case .confirmNew:  return localized(en: "Confirm PIN", uz: "PINni tasdiqlang", ru: "Подтвердите PIN")
        case .verify:      return localized(en: "Enter PIN", uz: "PIN kiriting", ru: "Введите PIN")
        case .verifyMaster: return localized(en: "Enter master pincode", uz: "Asosiy pinkodni kiriting", ru: "Введите главный пин-код")
        // SG: Chat Lock — the Settings screen that turns Chat Lock off also asks for the master pincode.
        case .disableChatLock: return pinTitle(mode: .verifyMaster)
        // Zenlygram — audit #40: the master pincode asked for as the SECOND rung of the vault recovery ladder.
        case .verifyMasterForVault: return pinTitle(mode: .verifyMaster)
        }
    }

    static func pinSubtitle(mode: ChatLockSetupStep) -> String {
        switch mode {
        case .enterNew:    return localized(en: "4-digit code", uz: "4 raqamli kod", ru: "4-значный код")
        case .confirmNew:  return localized(en: "Re-enter the same code", uz: "Kodni qayta kiriting", ru: "Введите код ещё раз")
        case .verify:      return localized(en: "Chat is locked", uz: "Chat qulflangan", ru: "Чат заблокирован")
        case .verifyMaster: return localized(en: "Unlocks this chat and removes its pincode", uz: "Chatni ochadi va pinkodini o'chiradi", ru: "Откроет чат и удалит его пин-код")
        // SG: Chat Lock — no single chat is involved: this turns the whole feature off.
        case .disableChatLock: return disableChatLockSubtitle
        case .verifyMasterForVault: return masterForVaultSubtitle
        }
    }

    static func textTitle(mode: ChatLockSetupStep) -> String {
        switch mode {
        case .enterNew:    return localized(en: "Set Password", uz: "Parol o'rnating", ru: "Установить пароль")
        case .confirmNew:  return localized(en: "Confirm Password", uz: "Parolni tasdiqlang", ru: "Подтвердите пароль")
        case .verify:      return localized(en: "Enter Password", uz: "Parol kiriting", ru: "Введите пароль")
        case .verifyMaster: return localized(en: "Enter master password", uz: "Asosiy parolni kiriting", ru: "Введите главный пароль")
        // SG: Chat Lock — the Settings screen that turns Chat Lock off also asks for the master password.
        case .disableChatLock: return textTitle(mode: .verifyMaster)
        case .verifyMasterForVault: return textTitle(mode: .verifyMaster)
        }
    }

    static func textSubtitle(mode: ChatLockSetupStep) -> String {
        switch mode {
        case .enterNew:    return localized(en: "Alphanumeric password", uz: "Harfli-raqamli parol", ru: "Буквенно-цифровой пароль")
        case .confirmNew:  return localized(en: "Re-enter the same password", uz: "Parolni qayta kiriting", ru: "Введите пароль ещё раз")
        case .verify:      return localized(en: "Chat is locked", uz: "Chat qulflangan", ru: "Чат заблокирован")
        case .verifyMaster: return localized(en: "Unlocks this chat and removes its pincode", uz: "Chatni ochadi va pinkodini o'chiradi", ru: "Откроет чат и удалит его пин-код")
        case .disableChatLock: return disableChatLockSubtitle
        case .verifyMasterForVault: return masterForVaultSubtitle
        }
    }

    /// SG: Chat Lock — subtitle of the master screen in Settings > Chat Lock that disables the feature:
    /// success removes the master pincode and every chat's lock (wording matches the "Disable Chat Lock?" alert).
    private static var disableChatLockSubtitle: String {
        localized(en: "Turns off Chat Lock and unlocks all chats", uz: "Chat qulfini o'chiradi va barcha chatlarni ochadi", ru: "Отключит блокировку чатов и разблокирует все чаты")
    }

    /// Zenlygram — audit #40: the vault "Forgot" ladder's second rung. The iPhone passcode is never accepted
    /// for the vault, so the Chat Lock master pincode is what stands in for the forgotten vault PIN here.
    private static var masterForVaultSubtitle: String {
        localized(
            en: "Opens the Secret Vault instead of the vault PIN",
            uz: "Seyf PIN kodi o'rniga maxfiy seyfni ochadi",
            ru: "Откроет Секретное хранилище вместо PIN хранилища"
        )
    }

    // MARK: - Error strings

    static var mismatch: String {
        localized(en: "Codes don't match", uz: "Kod mos kelmadi", ru: "Коды не совпадают")
    }

    static var wrongCode: String {
        localized(en: "Incorrect code", uz: "Noto'g'ri kod", ru: "Неверный код")
    }

    static var wrongPassword: String {
        localized(en: "Incorrect password", uz: "Noto'g'ri parol", ru: "Неверный пароль")
    }

    static var passwordMismatch: String {
        localized(en: "Passwords don't match", uz: "Parol mos kelmadi", ru: "Пароли не совпадают")
    }

    // MARK: - Biometric toggle prompt (shown after first-time setup)

    static var biometricPromptTitle: String {
        localized(en: "Enable Biometrics?", uz: "Biometrikani yoqish?", ru: "Включить биометрию?")
    }

    static func biometricPromptSubtitle(type: ChatLockBiometricType) -> String {
        switch type {
        case .faceID:
            return localized(en: "Unlock this chat with Face ID", uz: "Chatni Face ID bilan oching", ru: "Разблокировать Face ID")
        case .touchID:
            return localized(en: "Unlock this chat with Touch ID", uz: "Chatni Touch ID bilan oching", ru: "Разблокировать Touch ID")
        }
    }

    static var biometricEnable: String {
        localized(en: "Enable", uz: "Yoqish", ru: "Включить")
    }

    static var biometricSkip: String {
        localized(en: "Skip", uz: "O'tkazib yuborish", ru: "Пропустить")
    }

    // MARK: - Biometric enrolment change (Zenlygram — audit #40)
    //
    // A face or fingerprint enrolled on this iPhone AFTER the pincode was set must not inherit the power to
    // open the chat or the vault. The unlock screen then shows this instead of a biometric sheet, and asks
    // for the pincode; the choice below is offered only once the right pincode has been entered.

    static var biometricEnrollmentChanged: String {
        localized(
            en: "Face ID / Touch ID changed on this device. Enter your pincode.",
            uz: "Bu qurilmada Face ID / Touch ID o'zgargan. Pinkodni kiriting.",
            ru: "На этом устройстве изменился Face ID / Touch ID. Введите пин-код."
        )
    }

    static var biometricEnrollmentKeepTitle: String {
        localized(
            en: "Face ID / Touch ID changed",
            uz: "Face ID / Touch ID o'zgardi",
            ru: "Face ID / Touch ID изменился"
        )
    }

    static var biometricEnrollmentKeepText: String {
        localized(
            en: "A face or fingerprint was added or removed on this device after this pincode was set. Keep using biometrics here, or unlock with the pincode only?",
            uz: "Bu pinkod o'rnatilgandan keyin qurilmaga yuz yoki barmoq izi qo'shilgan yoki o'chirilgan. Bu yerda biometrikadan foydalanishda davom etasizmi yoki faqat pinkod bilan ochasizmi?",
            ru: "После установки этого пин-кода на устройстве добавили или удалили лицо либо отпечаток. Продолжить пользоваться биометрией здесь или открывать только пин-кодом?"
        )
    }

    /// Names the biometry this iPhone actually has, so the choice is not "Face ID" on a Touch ID device.
    static var biometricEnrollmentKeep: String {
        if ChatLockBiometricHelper.availableType() == .touchID {
            return localized(en: "Keep using Touch ID", uz: "Touch ID'dan foydalanishda davom etish", ru: "Продолжить с Touch ID")
        }
        return localized(en: "Keep using Face ID", uz: "Face ID'dan foydalanishda davom etish", ru: "Продолжить с Face ID")
    }

    static var biometricEnrollmentPinOnly: String {
        localized(en: "Use pincode only", uz: "Faqat pinkod bilan", ru: "Только пин-код")
    }

    // MARK: - Type picker (shown at the START of the setup flow)

    static var chooseTypeTitle: String {
        localized(en: "Lock Type", uz: "Qulf turi", ru: "Тип блокировки")
    }

    static var chooseTypePin: String {
        localized(en: "4-digit PIN", uz: "4 raqamli PIN", ru: "4-значный PIN")
    }

    static var chooseTypeText: String {
        localized(en: "Alphanumeric Password", uz: "Harfli-raqamli parol", ru: "Буквенно-цифровой пароль")
    }

    // MARK: - Biometric reason (the system prompt shown by iOS)

    static var biometricReason: String {
        localized(
            en: "Use biometrics to unlock this chat",
            uz: "Chatni biometrika bilan oching",
            ru: "Разблокировать чат с помощью биометрии"
        )
    }

    /// SG: Chat Lock — system biometric prompt of the Settings screen that turns Chat Lock off
    /// (`.disableChatLock`): no single chat is involved, so it names the feature instead.
    static var disableChatLockBiometricReason: String {
        localized(
            en: "Use biometrics to turn off Chat Lock",
            uz: "Chat qulfini biometrika bilan o'chiring",
            ru: "Отключить блокировку чатов с помощью биометрии"
        )
    }

    // MARK: - Keyboard return key

    static var done: String {
        localized(en: "Done", uz: "Tayyor", ru: "Готово")
    }

    // MARK: - Forgot pincode (master-pincode recovery)

    static var forgotPincode: String {
        localized(en: "Forgot pincode?", uz: "Pinkodni unutdingizmi?", ru: "Забыли пин-код?")
    }

    // Zenlygram — Chat Lock Center (wf14-chatlock spec §6 C7): the chat-list menu titles ("Set Pincode" /
    // "Remove Pincode") moved to `SGChatLockCenterStrings.menuLock` / `menuRemoveLock` in SGChatLockFlows.

    // MARK: - Master reset (device-owner recovery when the master pincode itself is forgotten)

    static var resetButtonTitle: String {
        localized(en: "Reset Chat Lock", uz: "Chat Lock'ni reset qilish", ru: "Сбросить Chat Lock")
    }
    static var resetConfirmTitle: String {
        localized(en: "Reset Chat Lock?", uz: "Chat Lock reset qilinsinmi?", ru: "Сбросить Chat Lock?")
    }
    static var resetConfirmMessage: String {
        localized(en: "This removes the master pincode and unlocks every chat. Your messages are not deleted.", uz: "Bu asosiy pinkodni o'chiradi va barcha chatlarni ochadi. Xabarlaringiz o'chmaydi.", ru: "Это удалит главный пин-код и разблокирует все чаты. Сообщения не удаляются.")
    }
    static var resetConfirmAction: String {
        localized(en: "Reset", uz: "Reset", ru: "Сбросить")
    }
    static var cancel: String {
        localized(en: "Cancel", uz: "Bekor qilish", ru: "Отмена")
    }
    static var resetReason: String {
        localized(en: "Confirm your identity to reset Chat Lock", uz: "Chat Lock'ni reset qilish uchun shaxsingizni tasdiqlang", ru: "Подтвердите личность для сброса Chat Lock")
    }

    /// Zenlygram — audit #40: the reset is REFUSED, instead of silently proceeding, when the device can prove
    /// nothing at all (no passcode and no usable biometrics). A merely CHANGED enrolment is not refused any
    /// more — it gets the confirmation + device-passcode rung below (batch 4).
    static var resetRefusedTitle: String {
        localized(en: "Reset unavailable", uz: "Reset qilib bo'lmaydi", ru: "Сброс недоступен")
    }

    /// Zenlygram — audit batch 4: the old copy ended with "delete and reinstall Zenlygram". That advice was
    /// wrong and made things worse — the master and per-chat credentials are keychain items that deliberately
    /// survive app deletion (audit #41), so after the reinstall `rebuildLockedCache` finds the same accounts
    /// and the chats are locked again with the same unknown pincodes. Only what the code really does is
    /// offered now: make a device-owner proof possible, or turn Chat Lock off with the master pincode.
    static var resetRefusedText: String {
        localized(
            en: "Resetting Chat Lock needs proof that this device is yours: an unchanged Face ID / Touch ID, or a device passcode. Set a device passcode in iOS Settings (or set up Face ID / Touch ID again) and try once more, or turn Chat Lock off in Zenlygram settings with your master pincode. Deleting and reinstalling Zenlygram does NOT remove the lock. Your messages are never lost.",
            uz: "Chat qulfini reset qilish uchun bu qurilma sizniki ekanini isbotlash kerak: o'zgarmagan Face ID / Touch ID yoki qurilma paroli. iOS sozlamalarida qurilma parolini o'rnating (yoki Face ID / Touch ID'ni qaytadan sozlang) va yana urinib ko'ring, yoxud Zenlygram sozlamalarida asosiy pinkod bilan Chat Lock'ni o'chiring. Zenlygram'ni o'chirib qayta o'rnatish qulfni olib tashlamaydi. Xabarlaringiz hech qachon yo'qolmaydi.",
            ru: "Для сброса блокировки чатов нужно доказать, что устройство ваше: неизменившийся Face ID / Touch ID либо код-пароль устройства. Установите код-пароль в настройках iOS (или заново настройте Face ID / Touch ID) и повторите попытку либо отключите блокировку чатов в настройках Zenlygram с помощью главного пин-кода. Удаление и повторная установка Zenlygram замок НЕ снимает. Сообщения при этом не теряются."
        )
    }

    /// Zenlygram — audit #40 (batch 4): asked before the device-passcode reset rung when the Face ID / Touch
    /// ID enrolment changed after the master pincode was set. Without it a re-enrolled face would leave a user
    /// who also forgot the master pincode with no way out at all.
    static var resetEnrollmentChangedTitle: String {
        localized(en: "Face ID / Touch ID changed", uz: "Face ID / Touch ID o'zgargan", ru: "Face ID / Touch ID изменился")
    }

    static var resetEnrollmentChangedText: String {
        localized(
            en: "The Face ID / Touch ID on this device changed after the master pincode was set, so it cannot stand in for it any more. Confirm this device is yours and enter its passcode to reset Chat Lock. Your messages are not deleted.",
            uz: "Asosiy pinkod o'rnatilgandan keyin bu qurilmadagi Face ID / Touch ID o'zgargan, shuning uchun u endi pinkod o'rnini bosa olmaydi. Chat Lock'ni reset qilish uchun bu qurilma sizniki ekanini tasdiqlang va uning parolini kiriting. Xabarlaringiz o'chmaydi.",
            ru: "После установки главного пин-кода Face ID / Touch ID на этом устройстве изменился, поэтому он больше не может его заменить. Подтвердите, что это ваше устройство, и введите его код-пароль, чтобы сбросить блокировку чатов. Сообщения не удаляются."
        )
    }

    static var resetEnrollmentChangedConfirm: String {
        localized(en: "Confirm", uz: "Tasdiqlash", ru: "Подтвердить")
    }

    static var recoveryHint: String {
        localized(en: "Forgot it? Use the option below.", uz: "Unutdingizmi? Pastdagi variantdan foydalaning.", ru: "Забыли? Используйте вариант ниже.")
    }

    // MARK: - Forgot vault PIN (device-owner recovery for the Secret Vault)

    /// Zenlygram — audit #40: the vault exists to hide chats from someone who knows the iPhone passcode, so
    /// this rung is Face ID / Touch ID ONLY (and only with the enrolment the vault PIN was set with). The
    /// wording names biometrics so the sheet never reads as an invitation to type the device passcode.
    static var forgotVaultReason: String {
        localized(en: "Use Face ID / Touch ID to recover access to hidden chats", uz: "Maxfiy chatlarga kirishni tiklash uchun Face ID / Touch ID'dan foydalaning", ru: "Используйте Face ID / Touch ID, чтобы восстановить доступ к скрытым чатам")
    }

    static var recoveryUnavailableTitle: String {
        localized(en: "Recovery unavailable", uz: "Tiklash imkonsiz", ru: "Восстановление недоступно")
    }

    static var recoveryUnavailableText: String {
        localized(
            en: "The vault PIN cannot be recovered on this device: it is a lock inside this app, and the device passcode is never accepted for it. Only Face ID / Touch ID with the enrolment the PIN was set with — or a Chat Lock master pincode that already existed when you set the PIN — can stand in for it. Otherwise delete and reinstall Zenlygram to remove the vault — hidden chats reappear and your messages are never lost.",
            uz: "Seyf PIN kodini bu qurilmada tiklab bo'lmaydi: u shu ilova ichidagi qulf va unga qurilma paroli hech qachon qabul qilinmaydi. Uning o'rnini faqat PIN o'rnatilgan paytdagi Face ID / Touch ID — yoki PIN o'rnatilganda allaqachon mavjud bo'lgan Chat Lock asosiy pinkodi bosa oladi. Aks holda seyfni olib tashlash uchun Zenlygram'ni o'chirib qayta o'rnating — berkitilgan chatlar qayta ko'rinadi, xabarlaringiz esa yo'qolmaydi.",
            ru: "PIN хранилища нельзя восстановить на этом устройстве: это замок внутри приложения, и код-пароль устройства для него никогда не принимается. Заменить его могут только Face ID / Touch ID с той регистрацией, при которой был задан PIN, — или главный пин-код блокировки чатов, если он уже существовал в тот момент. Иначе удалите и установите Zenlygram заново, чтобы убрать хранилище: скрытые чаты снова появятся, сообщения не теряются."
        )
    }

    /// Zenlygram — audit #70: the vault recovery screen offers only "set a new PIN"; turning the vault off
    /// lives in Settings, so the copy says where it is instead of leaving a dead end.
    static var vaultRecoveryTurnOffHint: String {
        localized(
            en: "To turn the Secret Vault off instead, open Zenlygram settings.",
            uz: "Maxfiy seyfni butunlay o'chirmoqchi bo'lsangiz, Zenlygram sozlamalarini oching.",
            ru: "Чтобы вместо этого отключить Секретное хранилище, откройте настройки Zenlygram."
        )
    }

    static var close: String {
        localized(en: "Close", uz: "Yopish", ru: "Закрыть")
    }

    static func tooManyAttempts(seconds: Int) -> String {
        let base = localized(
            en: "Too many attempts. Try again in %d s.",
            uz: "Juda ko'p urinish. %d soniyadan keyin urinib ko'ring.",
            ru: "Слишком много попыток. Повторите через %d с."
        )
        return String(format: base, seconds)
    }

    // MARK: - Locked chat surfaces (Zenlygram — Chat Lock central gate)

    /// Replaces a locked chat's last-message preview / snippet everywhere outside the chat itself.
    public static var lockedChatPreview: String {
        localized(en: "Locked chat", uz: "Qulflangan chat", ru: "Заблокированный чат")
    }

    /// VoiceOver hint for a locked chat's row.
    public static var lockedChatAccessibilityHint: String {
        localized(en: "PIN required to open", uz: "Ochish uchun PIN kerak", ru: "Для открытия нужен PIN")
    }

    /// Title on the opaque cover drawn over a locked chat's content until it is unlocked.
    static var coverTitle: String {
        localized(en: "This chat is locked", uz: "Bu chat qulflangan", ru: "Этот чат заблокирован")
    }

    /// Cover button that asks for the chat's PIN.
    static var unlock: String {
        localized(en: "Unlock", uz: "Ochish", ru: "Разблокировать")
    }

    // MARK: - Accessibility (VoiceOver-only strings)

    static var deleteKey: String {
        localized(en: "Delete", uz: "O'chirish", ru: "Удалить")
    }

    static var pinCodeLabel: String {
        localized(en: "PIN code", uz: "PIN kod", ru: "PIN-код")
    }

    static func pinDigitsEntered(count: Int, total: Int) -> String {
        let base = localized(
            en: "%1$d of %2$d entered",
            uz: "%2$d tadan %1$d tasi kiritildi",
            ru: "Введено %1$d из %2$d"
        )
        return String(format: base, count, total)
    }

    // MARK: - Helpers

    private static func localized(en: String, uz: String, ru: String) -> String {
        let lang = SGSimpleSettings.shared.languageCode
        switch lang {
        case "uz": return uz
        case "ru": return ru
        default:   return en
        }
    }
}

// Step used internally by ChatPincodeViewController to drive the title/subtitle.
enum ChatLockSetupStep {
    case enterNew
    case confirmNew
    case verify
    case verifyMaster
    // SG: Chat Lock — the master screen in Settings that turns Chat Lock off for every chat.
    case disableChatLock
    // Zenlygram — audit #40: the master pincode asked for as the vault recovery ladder's second rung.
    case verifyMasterForVault
}

// Biometric type detected at runtime.
// Zenlygram — Chat Lock Center: public because `ChatLockBiometricHelper.availableType()` returns it.
public enum ChatLockBiometricType {
    case faceID
    case touchID
}
