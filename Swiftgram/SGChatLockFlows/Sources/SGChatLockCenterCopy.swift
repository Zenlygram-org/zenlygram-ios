import Foundation

// MARK: Zenlygram — Chat Lock Center: every NEW string of the feature (wf14-chatlock spec §1–§2), verbatim,
// in one Foundation-only table so the host tests can audit it: uz uses the straight ASCII apostrophe only,
// every `%@` key carries the same number of placeholders in en/ru/uz, nothing is billing copy ("Pro",
// "Premium", "obuna", "подписк"), and nothing claims encryption positively. Read through
// `SGChatLockCenterStrings`, which picks the language exactly like `FenixuzChatLockStrings.localized(en:uz:ru:)`.
//
// `%@` is "Face ID" / "Touch ID" resolved at runtime (or the chat's title for the chat captions); strings
// that say "Face ID / Touch ID" literally are static and never formatted.

/// One string in the module's three languages.
public struct SGChatLockCopy: Equatable {
    public let en: String
    public let uz: String
    public let ru: String

    public init(en: String, uz: String, ru: String) {
        self.en = en
        self.uz = uz
        self.ru = ru
    }
}

/// Every key of the table. `CaseIterable`, so an audit covers the whole table and `copy(for:)` cannot miss
/// a key (the switch is exhaustive).
public enum SGChatLockCopyKey: String, CaseIterable {
    // §1 — the model, one sentence
    case model

    // §2.1 — hub
    case title
    case turnOn
    case offExplainer
    case masterHeader
    case changeMaster
    case masterBiometrics
    case masterBiometricsFooter
    case masterFooter
    case lockedChatsHeader
    case lockTypePin
    case lockTypePassword
    case swipeRemove
    case addChat
    case listFooter
    case emptyFooter
    case vaultFooter
    case otherAccountsFooter
    case turnOffFooter
    case legacySetMaster
    case legacyNotice
    case legacyTurnOffFooter
    case unreadableTitle
    case unreadableText
    case toastChatLockOn
    case toastChatLockOff
    case toastMasterChanged
    case toastChatLocked
    case toastLockRemoved
    case toastPincodeChanged

    // §2.2 — per-chat detail
    case changePincode
    case unlockWithBiometrics
    /// First sentence of changePincodeFooter (always shown).
    case changePincodeFooterType
    /// Second sentence of changePincodeFooter (omitted while no master exists).
    case changePincodeFooterForgot
    case chatBiometricsFooter
    case removeLock
    /// First sentence of removeFooter (always shown).
    case removeFooterAsks
    /// Second sentence of removeFooter (omitted while no master exists).
    case removeFooterForgot

    // §2.3 — picker
    case pickerTitle

    // §2.4 — PIN screen captions
    case verifyToChange
    case verifyToRemove
    case verifyToEnableBiometrics
    case masterToChange
    case masterToEnableBiometrics
    case masterLadderForChange
    case masterLadderForRemove
    case masterLadderForBiometrics
    case captionMaster
    case captionNewMaster
    case captionChat
    case captionChatGeneric
    case captionNewChat
    case captionNewChatGeneric

    // §2.4 — explainer alerts
    case continueAction
    case setupTitle
    case setupTextFromHub
    case setupTextFromChat
    case setupTextLegacy

    // §2.5 — menus
    case menuLock
    case menuManageLock
    case menuRemoveLock
}

public extension SGChatLockCopy {
    // MARK: §1 — the model

    static let model = SGChatLockCopy(
        en: "Each locked chat has its own pincode. The master pincode turns Chat Lock on and is the recovery key: if you forget a chat's pincode, entering the master pincode on that chat's screen opens the chat and removes its lock.",
        uz: "Har bir qulflangan chatning o'z pinkodi bor. Asosiy pinkod Chat qulfini yoqadi va tiklash kaliti bo'ladi: chat pinkodini unutsangiz, o'sha chat ekranida asosiy pinkodni kiritasiz — chat ochiladi va qulfi olib tashlanadi.",
        ru: "У каждого заблокированного чата свой пин-код. Главный пин-код включает блокировку чатов и служит ключом восстановления: если вы забыли пин-код чата, введите главный пин-код на экране этого чата — чат откроется, а его блокировка снимется."
    )

    // MARK: §2.1 — hub

    static let title = SGChatLockCopy(en: "Chat Lock", uz: "Chat qulfi", ru: "Блокировка чатов")
    static let turnOn = SGChatLockCopy(en: "Turn On Chat Lock", uz: "Chat qulfini yoqish", ru: "Включить блокировку чатов")
    static let offExplainer = SGChatLockCopy(
        en: "Each locked chat opens only with its own pincode. The master pincode turns Chat Lock on and is the recovery key: if you forget a chat's pincode, entering the master pincode on that chat's screen opens the chat and removes its lock.\n\nA locked chat hides its message previews in this app's chat list and in-app banners. This is a local lock in this app on this device, not encryption; pincodes stay on this device only and are not carried to a new one.",
        uz: "Har bir qulflangan chat faqat o'z pinkodi bilan ochiladi. Asosiy pinkod Chat qulfini yoqadi va tiklash kaliti bo'ladi: chat pinkodini unutsangiz, o'sha chat ekranida asosiy pinkodni kiritasiz — chat ochiladi va qulfi olib tashlanadi.\n\nQulflangan chatning xabar ko'rinishlari shu ilovaning chatlar ro'yxatida va ilova ichidagi bildirishnomalarda yashiriladi. Bu shu qurilmadagi ilova ichidagi lokal qulf, shifrlash emas; pinkodlar faqat shu qurilmada saqlanadi va yangi qurilmaga ko'chmaydi.",
        ru: "Каждый заблокированный чат открывается только своим пин-кодом. Главный пин-код включает блокировку чатов и служит ключом восстановления: если вы забыли пин-код чата, введите главный пин-код на экране этого чата — чат откроется, а его блокировка снимется.\n\nУ заблокированного чата скрыт предпросмотр сообщений в списке чатов этого приложения и во внутренних уведомлениях. Это локальная блокировка в этом приложении на этом устройстве, а не шифрование; пин-коды хранятся только на этом устройстве и не переносятся на новое."
    )
    static let masterHeader = SGChatLockCopy(en: "MASTER PINCODE", uz: "ASOSIY PINKOD", ru: "ГЛАВНЫЙ ПИН-КОД")
    static let changeMaster = SGChatLockCopy(en: "Change Master Pincode", uz: "Asosiy pinkodni o'zgartirish", ru: "Сменить главный пин-код")
    static let masterBiometrics = SGChatLockCopy(en: "%@ for the master pincode", uz: "Asosiy pinkod uchun %@", ru: "%@ для главного пин-кода")
    static let masterBiometricsFooter = SGChatLockCopy(
        en: "%@ can stand in for the master pincode on its own screens. After a %@ change on this device, the pincode is required again.",
        uz: "%@ asosiy pinkod ekranlarida uning o'rnini bosa oladi. Bu qurilmada %@ o'zgarsa, yana pinkod talab qilinadi.",
        ru: "%@ может заменять главный пин-код на его экранах. После изменения %@ на этом устройстве снова потребуется пин-код."
    )
    static let masterFooter = SGChatLockCopy(
        en: "The master pincode turns Chat Lock on and off and is the recovery key: on a locked chat's screen, \"Forgot pincode?\" takes the master pincode, opens the chat and removes its lock. Changing a chat's pincode with the master keeps the lock. After 4 wrong master entries, Chat Lock can be reset with this device's Face ID / Touch ID or passcode.",
        uz: "Asosiy pinkod Chat qulfini yoqadi va o'chiradi hamda tiklash kaliti bo'ladi: qulflangan chat ekranida \"Pinkodni unutdingizmi?\" asosiy pinkodni qabul qiladi — chat ochiladi va qulfi olib tashlanadi. Chat pinkodini asosiy pinkod bilan o'zgartirsangiz, qulf saqlanib qoladi. Asosiy pinkod 4 marta noto'g'ri kiritilsa, Chat qulfini bu qurilmaning Face ID / Touch ID yoki kod-paroli bilan reset qilish mumkin.",
        ru: "Главный пин-код включает и выключает блокировку чатов и служит ключом восстановления: на экране заблокированного чата «Забыли пин-код?» принимает главный пин-код — чат открывается, а его блокировка снимается. Смена пин-кода чата через главный пин-код сохраняет блокировку. После 4 неверных вводов главного пин-кода блокировку чатов можно сбросить с помощью Face ID / Touch ID или код-пароля этого устройства."
    )
    static let lockedChatsHeader = SGChatLockCopy(en: "LOCKED CHATS", uz: "QULFLANGAN CHATLAR", ru: "ЗАБЛОКИРОВАННЫЕ ЧАТЫ")
    static let lockTypePin = SGChatLockCopy(en: "PIN", uz: "PIN", ru: "PIN")
    static let lockTypePassword = SGChatLockCopy(en: "Password", uz: "Parol", ru: "Пароль")
    static let swipeRemove = SGChatLockCopy(en: "Remove", uz: "Olib tashlash", ru: "Снять")
    static let addChat = SGChatLockCopy(en: "Add a Chat…", uz: "Chat qo'shish…", ru: "Добавить чат…")
    static let listFooter = SGChatLockCopy(
        en: "Tap a chat to change its pincode, Face ID / Touch ID or remove the lock. Swipe left to remove.",
        uz: "Chatning pinkodini o'zgartirish, Face ID / Touch ID'ni sozlash yoki qulfni olib tashlash uchun uni bosing. Olib tashlash uchun chapga suring.",
        ru: "Нажмите на чат, чтобы сменить его пин-код, настроить Face ID / Touch ID или снять блокировку. Смахните влево, чтобы снять."
    )
    static let emptyFooter = SGChatLockCopy(
        en: "No locked chats yet. Add a chat and give it its own pincode. You can also hold a chat in the chat list or open its profile and choose \"Lock Chat\".",
        uz: "Hali qulflangan chat yo'q. Chat qo'shing va unga o'z pinkodini bering. Shuningdek, chatlar ro'yxatida chatni bosib turib yoki profilini ochib \"Chatni qulflash\"ni tanlashingiz mumkin.",
        ru: "Заблокированных чатов пока нет. Добавьте чат и задайте ему собственный пин-код. Можно также зажать чат в списке чатов или открыть его профиль и выбрать «Заблокировать чат»."
    )
    static let vaultFooter = SGChatLockCopy(
        en: "Chats hidden in the Secret Vault are locked from inside the vault.",
        uz: "Maxfiy seyfda yashirilgan chatlar seyf ichidan qulflanadi.",
        ru: "Чаты, скрытые в секретном хранилище, блокируются внутри хранилища."
    )
    static let otherAccountsFooter = SGChatLockCopy(
        en: "Locked chats of other accounts on this device are managed from those accounts.",
        uz: "Bu qurilmadagi boshqa akkauntlarning qulflangan chatlari o'sha akkauntlardan boshqariladi.",
        ru: "Заблокированные чаты других аккаунтов на этом устройстве настраиваются из этих аккаунтов."
    )
    static let turnOffFooter = SGChatLockCopy(
        en: "Removes the master pincode and every chat's pincode. Your messages are not deleted. The Secret Vault is not affected.",
        uz: "Asosiy pinkodni va barcha chatlarning pinkodlarini o'chiradi. Xabarlaringiz o'chmaydi. Maxfiy seyfga ta'sir qilmaydi.",
        ru: "Удаляет главный пин-код и пин-коды всех чатов. Сообщения не удаляются. Секретное хранилище не затрагивается."
    )
    static let legacySetMaster = SGChatLockCopy(en: "Set Master Pincode", uz: "Asosiy pinkod o'rnatish", ru: "Задать главный пин-код")
    static let legacyNotice = SGChatLockCopy(
        en: "Some locked chats have no master pincode, so a forgotten chat pincode has no way back. Set a master pincode to add \"Forgot pincode?\" to every locked chat, or turn Chat Lock off below.",
        uz: "Ba'zi qulflangan chatlarda asosiy pinkod yo'q, shuning uchun unutilgan chat pinkodini tiklab bo'lmaydi. Har bir qulflangan chatga \"Pinkodni unutdingizmi?\" qo'shilishi uchun asosiy pinkod o'rnating yoki pastda Chat qulfini o'chiring.",
        ru: "У некоторых заблокированных чатов нет главного пин-кода, поэтому забытый пин-код чата нельзя восстановить. Задайте главный пин-код, чтобы у каждого заблокированного чата появилось «Забыли пин-код?», или отключите блокировку чатов ниже."
    )
    static let legacyTurnOffFooter = SGChatLockCopy(
        en: "There is no master pincode to ask for, so turning Chat Lock off confirms it's you with this device's Face ID / Touch ID or passcode. Removes every chat's pincode. Your messages are not deleted.",
        uz: "So'raladigan asosiy pinkod yo'q, shuning uchun Chat qulfini o'chirish bu qurilmaning Face ID / Touch ID yoki kod-paroli bilan tasdiqlanadi. Barcha chatlarning pinkodlarini o'chiradi. Xabarlaringiz o'chmaydi.",
        ru: "Главного пин-кода нет, поэтому отключение блокировки чатов подтверждается Face ID / Touch ID или код-паролем этого устройства. Удаляет пин-коды всех чатов. Сообщения не удаляются."
    )
    static let unreadableTitle = SGChatLockCopy(en: "Try again in a moment", uz: "Birozdan so'ng qayta urining", ru: "Попробуйте через минуту")
    static let unreadableText = SGChatLockCopy(
        en: "Chat Lock cannot be read right now. Unlock this device, wait a moment and open this screen again.",
        uz: "Hozir Chat qulfi ma'lumotlarini o'qib bo'lmaydi. Qurilma qulfini oching, biroz kuting va bu ekranni qayta oching.",
        ru: "Сейчас данные блокировки чатов недоступны. Разблокируйте устройство, подождите немного и откройте этот экран снова."
    )
    static let toastChatLockOn = SGChatLockCopy(en: "Chat Lock turned on", uz: "Chat qulfi yoqildi", ru: "Блокировка чатов включена")
    static let toastChatLockOff = SGChatLockCopy(en: "Chat Lock turned off", uz: "Chat qulfi o'chirildi", ru: "Блокировка чатов выключена")
    static let toastMasterChanged = SGChatLockCopy(en: "Master pincode changed", uz: "Asosiy pinkod o'zgartirildi", ru: "Главный пин-код изменён")
    static let toastChatLocked = SGChatLockCopy(en: "Chat locked", uz: "Chat qulflandi", ru: "Чат заблокирован")
    static let toastLockRemoved = SGChatLockCopy(en: "Lock removed", uz: "Qulf olib tashlandi", ru: "Блокировка снята")
    static let toastPincodeChanged = SGChatLockCopy(en: "Pincode changed", uz: "Pinkod o'zgartirildi", ru: "Пин-код изменён")

    // MARK: §2.2 — per-chat detail

    static let changePincode = SGChatLockCopy(en: "Change Pincode", uz: "Pinkodni o'zgartirish", ru: "Сменить пин-код")
    static let unlockWithBiometrics = SGChatLockCopy(en: "Unlock with %@", uz: "%@ bilan ochish", ru: "Открывать по %@")
    static let changePincodeFooterType = SGChatLockCopy(
        en: "The lock type (PIN or password) is chosen while changing the pincode.",
        uz: "Qulf turi (PIN yoki parol) pinkodni o'zgartirishda tanlanadi.",
        ru: "Тип блокировки (PIN или пароль) выбирается при смене пин-кода."
    )
    static let changePincodeFooterForgot = SGChatLockCopy(
        en: "Forgot the current pincode? The master pincode is accepted instead and the lock is kept.",
        uz: "Amaldagi pinkodni unutdingizmi? Uning o'rniga asosiy pinkod qabul qilinadi va qulf saqlanib qoladi.",
        ru: "Забыли текущий пин-код? Вместо него принимается главный пин-код, блокировка сохраняется."
    )
    static let chatBiometricsFooter = SGChatLockCopy(
        en: "%@ opens this chat instead of its pincode. After a %@ change on this device, the pincode is required once.",
        uz: "%@ bu chatni pinkod o'rniga ochadi. Bu qurilmada %@ o'zgarsa, bir marta pinkod talab qilinadi.",
        ru: "%@ открывает этот чат вместо пин-кода. После изменения %@ на этом устройстве один раз потребуется пин-код."
    )
    static let removeLock = SGChatLockCopy(en: "Remove Lock", uz: "Qulfni olib tashlash", ru: "Снять блокировку")
    static let removeFooterAsks = SGChatLockCopy(en: "Asks for this chat's pincode.", uz: "Shu chatning pinkodi so'raladi.", ru: "Потребуется пин-код этого чата.")
    static let removeFooterForgot = SGChatLockCopy(
        en: "Forgot it? The master pincode is accepted instead.",
        uz: "Unutdingizmi? Uning o'rniga asosiy pinkod qabul qilinadi.",
        ru: "Забыли его? Вместо него принимается главный пин-код."
    )

    // MARK: §2.3 — picker

    static let pickerTitle = SGChatLockCopy(en: "Choose a Chat to Lock", uz: "Qulflash uchun chatni tanlang", ru: "Выберите чат для блокировки")

    // MARK: §2.4 — PIN screen captions

    static let verifyToChange = SGChatLockCopy(en: "Enter the current code to change it", uz: "O'zgartirish uchun amaldagi kodni kiriting", ru: "Введите текущий код, чтобы сменить его")
    static let verifyToRemove = SGChatLockCopy(en: "Enter the current code to remove the lock", uz: "Qulfni olib tashlash uchun amaldagi kodni kiriting", ru: "Введите текущий код, чтобы снять блокировку")
    static let verifyToEnableBiometrics = SGChatLockCopy(en: "Enter the code to turn on %@ for this chat", uz: "Bu chat uchun %@'ni yoqish uchun kodni kiriting", ru: "Введите код, чтобы включить %@ для этого чата")
    static let masterToChange = SGChatLockCopy(en: "Enter the current master pincode to change it", uz: "O'zgartirish uchun amaldagi asosiy pinkodni kiriting", ru: "Введите текущий главный пин-код, чтобы сменить его")
    static let masterToEnableBiometrics = SGChatLockCopy(en: "Enter the master pincode to turn on %@", uz: "%@'ni yoqish uchun asosiy pinkodni kiriting", ru: "Введите главный пин-код, чтобы включить %@")
    static let masterLadderForChange = SGChatLockCopy(en: "Confirms it's you; then set this chat's new pincode", uz: "Siz ekaningizni tasdiqlaydi; keyin chatning yangi pinkodini o'rnating", ru: "Подтверждает, что это вы; затем задайте новый пин-код чата")
    static let masterLadderForRemove = SGChatLockCopy(en: "Confirms it's you; then this chat's lock is removed", uz: "Siz ekaningizni tasdiqlaydi; keyin bu chatning qulfi olib tashlanadi", ru: "Подтверждает, что это вы; затем блокировка этого чата снимается")
    static let masterLadderForBiometrics = SGChatLockCopy(en: "Confirms it's you; then set this chat's new pincode and %@ is turned on", uz: "Siz ekaningizni tasdiqlaydi; keyin chatning yangi pinkodini o'rnating va %@ yoqiladi", ru: "Подтверждает, что это вы; затем задайте новый пин-код чата, и %@ включится")
    static let captionMaster = SGChatLockCopy(en: "Master pincode: turns Chat Lock on and is the recovery key", uz: "Asosiy pinkod: Chat qulfini yoqadi va tiklash kaliti bo'ladi", ru: "Главный пин-код: включает блокировку чатов и служит ключом восстановления")
    static let captionNewMaster = SGChatLockCopy(en: "New master pincode", uz: "Yangi asosiy pinkod", ru: "Новый главный пин-код")
    static let captionChat = SGChatLockCopy(en: "Pincode for %@", uz: "%@ uchun pinkod", ru: "Пин-код для %@")
    static let captionChatGeneric = SGChatLockCopy(en: "Pincode for this chat", uz: "Bu chat uchun pinkod", ru: "Пин-код для этого чата")
    static let captionNewChat = SGChatLockCopy(en: "New pincode for %@", uz: "%@ uchun yangi pinkod", ru: "Новый пин-код для %@")
    static let captionNewChatGeneric = SGChatLockCopy(en: "New pincode for this chat", uz: "Bu chat uchun yangi pinkod", ru: "Новый пин-код для этого чата")

    // MARK: §2.4 — explainer alerts

    static let continueAction = SGChatLockCopy(en: "Continue", uz: "Davom etish", ru: "Продолжить")
    static let setupTitle = SGChatLockCopy(en: "Set up Chat Lock", uz: "Chat qulfini sozlash", ru: "Настройка блокировки чатов")
    static let setupTextFromHub = SGChatLockCopy(
        en: "First a master pincode: it turns Chat Lock on and is your recovery key. Then pick the first chat to lock and give it its own pincode.",
        uz: "Avval asosiy pinkod: u Chat qulfini yoqadi va tiklash kaliti bo'ladi. Keyin birinchi chatni tanlab, unga o'z pinkodini bering.",
        ru: "Сначала главный пин-код: он включает блокировку чатов и служит ключом восстановления. Затем выберите первый чат и задайте ему собственный пин-код."
    )
    static let setupTextFromChat = SGChatLockCopy(
        en: "Two short steps: first a master pincode (it turns Chat Lock on and is your recovery key), then this chat's own pincode.",
        uz: "Ikki qisqa qadam: avval asosiy pinkod (u Chat qulfini yoqadi va tiklash kaliti bo'ladi), keyin shu chatning o'z pinkodi.",
        ru: "Два коротких шага: сначала главный пин-код (он включает блокировку чатов и служит ключом восстановления), затем собственный пин-код этого чата."
    )
    // LEGACY (chats already locked, no master): nothing is promised after the master — no picker follows
    // "Set Master Pincode", and "Add a Chat…" was the user's own choice.
    static let setupTextLegacy = SGChatLockCopy(
        en: "A master pincode: it turns Chat Lock on and is the recovery key for the chats already locked.",
        uz: "Asosiy pinkod: u Chat qulfini yoqadi va allaqachon qulflangan chatlar uchun tiklash kaliti bo'ladi.",
        ru: "Главный пин-код: он включает блокировку чатов и служит ключом восстановления для уже заблокированных чатов."
    )

    // MARK: §2.5 — menus

    static let menuLock = SGChatLockCopy(en: "Lock Chat", uz: "Chatni qulflash", ru: "Заблокировать чат")
    static let menuManageLock = SGChatLockCopy(en: "Chat Lock…", uz: "Chat qulfi…", ru: "Блокировка чата…")
    static let menuRemoveLock = SGChatLockCopy(en: "Remove Lock", uz: "Qulfni olib tashlash", ru: "Снять блокировку")

    // MARK: Table

    /// The copy of `key`. Exhaustive, so every key has its text.
    static func copy(for key: SGChatLockCopyKey) -> SGChatLockCopy {
        switch key {
        case .model: return SGChatLockCopy.model
        case .title: return SGChatLockCopy.title
        case .turnOn: return SGChatLockCopy.turnOn
        case .offExplainer: return SGChatLockCopy.offExplainer
        case .masterHeader: return SGChatLockCopy.masterHeader
        case .changeMaster: return SGChatLockCopy.changeMaster
        case .masterBiometrics: return SGChatLockCopy.masterBiometrics
        case .masterBiometricsFooter: return SGChatLockCopy.masterBiometricsFooter
        case .masterFooter: return SGChatLockCopy.masterFooter
        case .lockedChatsHeader: return SGChatLockCopy.lockedChatsHeader
        case .lockTypePin: return SGChatLockCopy.lockTypePin
        case .lockTypePassword: return SGChatLockCopy.lockTypePassword
        case .swipeRemove: return SGChatLockCopy.swipeRemove
        case .addChat: return SGChatLockCopy.addChat
        case .listFooter: return SGChatLockCopy.listFooter
        case .emptyFooter: return SGChatLockCopy.emptyFooter
        case .vaultFooter: return SGChatLockCopy.vaultFooter
        case .otherAccountsFooter: return SGChatLockCopy.otherAccountsFooter
        case .turnOffFooter: return SGChatLockCopy.turnOffFooter
        case .legacySetMaster: return SGChatLockCopy.legacySetMaster
        case .legacyNotice: return SGChatLockCopy.legacyNotice
        case .legacyTurnOffFooter: return SGChatLockCopy.legacyTurnOffFooter
        case .unreadableTitle: return SGChatLockCopy.unreadableTitle
        case .unreadableText: return SGChatLockCopy.unreadableText
        case .toastChatLockOn: return SGChatLockCopy.toastChatLockOn
        case .toastChatLockOff: return SGChatLockCopy.toastChatLockOff
        case .toastMasterChanged: return SGChatLockCopy.toastMasterChanged
        case .toastChatLocked: return SGChatLockCopy.toastChatLocked
        case .toastLockRemoved: return SGChatLockCopy.toastLockRemoved
        case .toastPincodeChanged: return SGChatLockCopy.toastPincodeChanged
        case .changePincode: return SGChatLockCopy.changePincode
        case .unlockWithBiometrics: return SGChatLockCopy.unlockWithBiometrics
        case .changePincodeFooterType: return SGChatLockCopy.changePincodeFooterType
        case .changePincodeFooterForgot: return SGChatLockCopy.changePincodeFooterForgot
        case .chatBiometricsFooter: return SGChatLockCopy.chatBiometricsFooter
        case .removeLock: return SGChatLockCopy.removeLock
        case .removeFooterAsks: return SGChatLockCopy.removeFooterAsks
        case .removeFooterForgot: return SGChatLockCopy.removeFooterForgot
        case .pickerTitle: return SGChatLockCopy.pickerTitle
        case .verifyToChange: return SGChatLockCopy.verifyToChange
        case .verifyToRemove: return SGChatLockCopy.verifyToRemove
        case .verifyToEnableBiometrics: return SGChatLockCopy.verifyToEnableBiometrics
        case .masterToChange: return SGChatLockCopy.masterToChange
        case .masterToEnableBiometrics: return SGChatLockCopy.masterToEnableBiometrics
        case .masterLadderForChange: return SGChatLockCopy.masterLadderForChange
        case .masterLadderForRemove: return SGChatLockCopy.masterLadderForRemove
        case .masterLadderForBiometrics: return SGChatLockCopy.masterLadderForBiometrics
        case .captionMaster: return SGChatLockCopy.captionMaster
        case .captionNewMaster: return SGChatLockCopy.captionNewMaster
        case .captionChat: return SGChatLockCopy.captionChat
        case .captionChatGeneric: return SGChatLockCopy.captionChatGeneric
        case .captionNewChat: return SGChatLockCopy.captionNewChat
        case .captionNewChatGeneric: return SGChatLockCopy.captionNewChatGeneric
        case .continueAction: return SGChatLockCopy.continueAction
        case .setupTitle: return SGChatLockCopy.setupTitle
        case .setupTextFromHub: return SGChatLockCopy.setupTextFromHub
        case .setupTextFromChat: return SGChatLockCopy.setupTextFromChat
        case .setupTextLegacy: return SGChatLockCopy.setupTextLegacy
        case .menuLock: return SGChatLockCopy.menuLock
        case .menuManageLock: return SGChatLockCopy.menuManageLock
        case .menuRemoveLock: return SGChatLockCopy.menuRemoveLock
        }
    }

    /// The keys whose text takes `%@` (the biometry name, or the chat's title for the two chat captions).
    static let placeholderKeys: Set<SGChatLockCopyKey> = [
        .masterBiometrics, .masterBiometricsFooter, .unlockWithBiometrics, .chatBiometricsFooter,
        .verifyToEnableBiometrics, .masterToEnableBiometrics, .masterLadderForBiometrics,
        .captionChat, .captionNewChat
    ]

    /// Fills the `%@` placeholders of `text` in order. Plain replacement, never `String(format:)`: a chat
    /// title is user data and must not be read as a format string.
    static func fill(_ text: String, _ arguments: [String]) -> String {
        var result = text
        for argument in arguments {
            guard let range = result.range(of: "%@") else {
                break
            }
            result.replaceSubrange(range, with: argument)
        }
        return result
    }
}
