import Foundation
import SGEntitlement

// Zenlygram — synced Tasks strings (sync state, invitations, repair, import). Same pick(en:uz:ru:)
// scheme as SGTasksL10n.swift; the Masʼul (assignment) strings are in SGTasksL10n+Assign.swift.
//
// Wording rules: never promise immediate delivery, push notifications or end-to-end encryption;
// assigning a Masʼul is a Zenlygram Tasks invitation, not a Telegram message. wf15 §15.3: the
// scope-switch, device-archive, sharing and "who can do what" keys of the two-board era are gone.

public extension SGTasksL10n {
    // MARK: - Account state

    var tasks_cloud_paused_title: String {
        pick(en: "Sync is paused", uz: "Sinxronlash toʻxtatilgan", ru: "Синхронизация приостановлена")
    }

    var tasks_cloud_paused_text: String {
        pick(
            en: "The Tasks service says this account is not linked. Your tasks and unsent changes are kept; link the account again to continue.",
            uz: "Tasks xizmati bu akkaunt bogʻlanmaganini bildirdi. Vazifalaringiz va yuborilmagan oʻzgarishlar saqlanib turadi; davom etish uchun akkauntni qayta bogʻlang.",
            ru: "Сервис задач сообщил, что аккаунт не привязан. Задачи и неотправленные изменения сохранены; привяжите аккаунт снова, чтобы продолжить."
        )
    }

    var tasks_cloud_link_action: String {
        pick(en: "Link Account", uz: "Akkauntni bogʻlash", ru: "Привязать аккаунт")
    }

    var tasks_cloud_unavailable_title: String {
        pick(en: "Tasks can't sync", uz: "Vazifalar sinxronlanmayapti", ru: "Задачи не синхронизируются")
    }

    var tasks_cloud_notConfigured_text: String {
        pick(
            en: "This version of the app can't reach the Tasks service.",
            uz: "Ilovaning bu versiyasi Tasks xizmatiga ulana olmaydi.",
            ru: "Эта версия приложения не может подключиться к сервису задач."
        )
    }

    var tasks_cloud_notSignedIn_text: String {
        pick(
            en: "This account has no Zenlygram session yet. Link the account to sync your tasks.",
            uz: "Bu akkauntda hali Zenlygram seansi yoʻq. Vazifalarni sinxronlash uchun akkauntni bogʻlang.",
            ru: "У этого аккаунта ещё нет сеанса Zenlygram. Привяжите аккаунт, чтобы синхронизировать задачи."
        )
    }

    // MARK: - Sync status

    var tasks_cloud_status_loading: String {
        pick(en: "Loading your tasks…", uz: "Vazifalar yuklanmoqda…", ru: "Загрузка задач…")
    }

    var tasks_cloud_status_offline: String {
        pick(
            en: "Can't reach the Tasks service. Your changes are saved and wait to be sent.",
            uz: "Tasks xizmatiga ulanib boʻlmadi. Oʻzgarishlaringiz saqlangan va yuborilishini kutmoqda.",
            ru: "Нет связи с сервисом задач. Изменения сохранены и ждут отправки."
        )
    }

    var tasks_cloud_status_unavailable: String {
        pick(
            en: "The Tasks service is unavailable right now. Your changes wait to be sent.",
            uz: "Tasks xizmati hozir ishlamayapti. Oʻzgarishlaringiz yuborilishini kutmoqda.",
            ru: "Сервис задач сейчас недоступен. Изменения ждут отправки."
        )
    }

    func tasks_cloud_status_rateLimited(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else {
            return pick(en: "Too many requests. Sync will try again later.", uz: "Soʻrovlar juda koʻp. Keyinroq qayta uriniladi.", ru: "Слишком много запросов. Синхронизация повторится позже.")
        }
        let minutes = max(1, Int((Double(seconds) / 60.0).rounded(.up)))
        return pick(
            en: minutes == 1 ? "Too many requests. Sync can try again in about a minute." : "Too many requests. Sync can try again in about \(minutes) minutes.",
            uz: "Soʻrovlar juda koʻp. Taxminan \(minutes) daqiqadan keyin qayta uriniladi.",
            ru: "Слишком много запросов. Повторить можно примерно через \(minutes) мин."
        )
    }

    var tasks_cloud_status_sessionProblem: String {
        pick(
            en: "Your Zenlygram session needs attention. Open the account link screen to sign in again.",
            uz: "Zenlygram seansingiz eʼtibor talab qiladi. Qayta kirish uchun akkaunt bogʻlash ekranini oching.",
            ru: "Сеанс Zenlygram требует внимания. Откройте экран привязки аккаунта, чтобы войти снова."
        )
    }

    func tasks_cloud_status_pending(_ count: Int) -> String {
        let ruWord = countRuWord(count, one: "изменение ждёт", few: "изменения ждут", many: "изменений ждут")
        return pick(
            en: count == 1 ? "1 change waiting to be sent" : "\(count) changes waiting to be sent",
            uz: "\(count) ta oʻzgarish yuborilishini kutmoqda",
            ru: "\(count) \(ruWord) отправки"
        )
    }

    func tasks_cloud_status_issues(_ count: Int) -> String {
        let ruWord = countRuWord(count, one: "изменение требует", few: "изменения требуют", many: "изменений требуют")
        return pick(
            en: count == 1 ? "1 change needs your attention" : "\(count) changes need your attention",
            uz: "\(count) ta oʻzgarish eʼtiboringizni talab qiladi",
            ru: "\(count) \(ruWord) внимания"
        )
    }

    var tasks_cloud_status_retry: String {
        pick(en: "Try Again", uz: "Qayta urinish", ru: "Повторить")
    }

    var tasks_cloud_status_review: String {
        pick(en: "Review", uz: "Koʻrib chiqish", ru: "Просмотреть")
    }

    /// R4: synced automatically while the app is open and when the user leaves it (design 30 §5.6).
    var tasks_cloud_privacyFooter: String {
        pick(
            en: "Tasks are stored and processed on the Zenlygram server in Tashkent; they are not end-to-end encrypted. Changes sync automatically while the app is open and when you leave it — there are no instant notifications.",
            uz: "Vazifalar Toshkentdagi Zenlygram serverida saqlanadi va qayta ishlanadi; ular uchdan-uchga shifrlanmagan. Oʻzgarishlar ilova ochiqligida va undan chiqqaningizda avtomatik sinxronlanadi — darhol bildirishnoma yoʻq.",
            ru: "Задачи хранятся и обрабатываются на сервере Zenlygram в Ташкенте; сквозного шифрования нет. Изменения синхронизируются автоматически, пока приложение открыто и когда вы из него выходите, — мгновенных уведомлений нет."
        )
    }

    // MARK: - Board rows

    var tasks_cloud_inbox_title: String {
        pick(en: "Inbox", uz: "Kiruvchi", ru: "Входящие")
    }

    var tasks_cloud_row_notSent: String {
        pick(en: "Not sent yet", uz: "Hali yuborilmagan", ru: "Ещё не отправлено")
    }

    var tasks_cloud_row_needsAttention: String {
        pick(en: "Not sent — needs your attention", uz: "Yuborilmadi — eʼtiboringiz kerak", ru: "Не отправлено — требует внимания")
    }

    func tasks_cloud_telegramUser(_ id: String) -> String {
        pick(en: "Telegram user \(id)", uz: "Telegram foydalanuvchisi \(id)", ru: "Пользователь Telegram \(id)")
    }

    var tasks_cloud_action_leave: String {
        pick(en: "Leave", uz: "Chiqish", ru: "Выйти")
    }

    // MARK: - Invitations

    var tasks_cloud_invitations_title: String {
        pick(en: "Invitations", uz: "Takliflar", ru: "Приглашения")
    }

    func tasks_cloud_invitations_banner(_ count: Int) -> String {
        let ruWord = countRuWord(count, one: "новое приглашение", few: "новых приглашения", many: "новых приглашений")
        return pick(
            en: count == 1 ? "1 task invitation" : "\(count) task invitations",
            uz: "\(count) ta vazifa taklifi",
            ru: "\(count) \(ruWord)"
        )
    }

    var tasks_cloud_invitations_empty: String {
        pick(en: "No invitations.", uz: "Takliflar yoʻq.", ru: "Приглашений нет.")
    }

    var tasks_cloud_invitations_footer: String {
        pick(
            en: "The sender's lists and other tasks are never shared. The sender's name is not verified — the number is their Telegram ID.",
            uz: "Yuboruvchining roʻyxatlari va boshqa vazifalari hech qachon ulashilmaydi. Yuboruvchining ismi tasdiqlanmagan — raqam uning Telegram IDʼsi.",
            ru: "Списки и другие задачи отправителя никогда не передаются. Имя отправителя не проверяется — число это его Telegram ID."
        )
    }

    var tasks_cloud_invitations_access_beforeLabel: String {
        pick(en: "Before you accept", uz: "Qabul qilishdan oldin", ru: "До принятия")
    }

    var tasks_cloud_invitations_access_before: String {
        pick(
            en: "You see only the title, the deadline and the sender's Telegram ID. You can't change anything.",
            uz: "Faqat sarlavha, muddat va yuboruvchining Telegram IDʼsini koʻrasiz. Hech narsani oʻzgartira olmaysiz.",
            ru: "Видны только название, срок и Telegram ID отправителя. Изменить ничего нельзя."
        )
    }

    var tasks_cloud_invitations_access_afterLabel: String {
        pick(en: "After you accept", uz: "Qabul qilgandan keyin", ru: "После принятия")
    }

    var tasks_cloud_invitations_access_after: String {
        pick(
            en: "You also see the notes, can mark the task done or not done, write a note and leave at any time. Only the sender changes, reassigns or deletes it. This access doesn't expire.",
            uz: "Izohlarni ham koʻrasiz, vazifani bajarildi/bajarilmadi deb belgilashingiz, izoh yozishingiz va istalgan vaqtda chiqishingiz mumkin. Oʻzgartirish, boshqa masʼul tanlash va oʻchirish faqat yuboruvchida. Bu kirish huquqi muddatsiz.",
            ru: "Видны и заметки; можно отмечать выполнение, написать заметку и выйти в любой момент. Изменяет, переназначает и удаляет только отправитель. Этот доступ бессрочный."
        )
    }

    func tasks_cloud_invitation_from(_ sender: String) -> String {
        pick(en: "From \(sender)", uz: "Kimdan: \(sender)", ru: "От: \(sender)")
    }

    func tasks_cloud_invitation_expires(_ date: String) -> String {
        pick(en: "Expires \(date)", uz: "Muddati: \(date)", ru: "Истекает \(date)")
    }

    var tasks_cloud_invitation_expired: String {
        pick(en: "Expired", uz: "Muddati tugagan", ru: "Истекло")
    }

    var tasks_cloud_invitation_accept: String {
        pick(en: "Accept", uz: "Qabul qilish", ru: "Принять")
    }

    var tasks_cloud_invitation_decline: String {
        pick(en: "Decline", uz: "Rad etish", ru: "Отклонить")
    }

    var tasks_cloud_invitation_block: String {
        pick(en: "Block Sender", uz: "Yuboruvchini bloklash", ru: "Заблокировать отправителя")
    }

    func tasks_cloud_invitation_blockConfirm_text(_ sender: String) -> String {
        pick(
            en: "\(sender) won't be able to send you task invitations, and their pending invitations are hidden. Tasks you already accepted from them stay until you leave them.",
            uz: "\(sender) sizga vazifa takliflarini yubora olmaydi, kutilayotgan takliflari yashiriladi. Ilgari qabul qilgan vazifalaringiz siz chiqmaguningizcha qoladi.",
            ru: "\(sender) не сможет присылать вам приглашения, его ожидающие приглашения будут скрыты. Уже принятые задачи останутся, пока вы из них не выйдете."
        )
    }

    var tasks_cloud_blocked_header: String {
        pick(en: "Blocked senders", uz: "Bloklangan yuboruvchilar", ru: "Заблокированные отправители")
    }

    var tasks_cloud_unblock: String {
        pick(en: "Unblock", uz: "Blokdan chiqarish", ru: "Разблокировать")
    }

    var tasks_cloud_unblock_footer: String {
        pick(
            en: "Unblocking lets this sender invite you again. Invitations hidden while they were blocked do not come back.",
            uz: "Blokdan chiqarilsa, bu yuboruvchi sizni yana taklif qila oladi. Bloklangan paytda yashirilgan takliflar qaytmaydi.",
            ru: "После разблокировки отправитель снова сможет вас приглашать. Скрытые за время блокировки приглашения не вернутся."
        )
    }

    // MARK: - Task editor

    var tasks_cloud_editor_editTitle: String {
        pick(en: "Edit Task", uz: "Vazifani tahrirlash", ru: "Изменить задачу")
    }

    var tasks_cloud_editor_titlePlaceholder: String {
        pick(en: "Task", uz: "Vazifa", ru: "Задача")
    }

    var tasks_cloud_editor_notesPlaceholder: String {
        pick(en: "Notes", uz: "Izohlar", ru: "Заметки")
    }

    var tasks_cloud_editor_list: String {
        pick(en: "List", uz: "Roʻyxat", ru: "Список")
    }

    var tasks_cloud_editor_priority: String {
        pick(en: "Priority", uz: "Muhimlik", ru: "Приоритет")
    }

    func tasks_cloud_priority(_ value: Int) -> String {
        switch value {
        case 1:
            return pick(en: "Low", uz: "Past", ru: "Низкий")
        case 2:
            return pick(en: "Medium", uz: "Oʻrta", ru: "Средний")
        case 3:
            return pick(en: "High", uz: "Yuqori", ru: "Высокий")
        case 4:
            return pick(en: "Urgent", uz: "Shoshilinch", ru: "Срочный")
        default:
            return pick(en: "None", uz: "Yoʻq", ru: "Нет")
        }
    }

    var tasks_cloud_editor_deleteTask: String {
        pick(en: "Delete Task", uz: "Vazifani oʻchirish", ru: "Удалить задачу")
    }

    var tasks_cloud_editor_reopen: String {
        pick(en: "Mark as Not Done", uz: "Bajarilmadi deb belgilash", ru: "Отметить невыполненной")
    }

    var tasks_cloud_editor_complete: String {
        pick(en: "Mark as Done", uz: "Bajarildi deb belgilash", ru: "Отметить выполненной")
    }

    // MARK: - Access (the assignee's side)

    /// A local change (task edit, assignment, removal or invitation answer) the server has not confirmed yet.
    /// It may already have been sent, so it never claims "not sent".
    var tasks_cloud_syncConfirmationPending: String {
        pick(en: "Waiting for sync confirmation", uz: "Sinxronlash tasdigʻi kutilmoqda", ru: "Ожидает подтверждения синхронизации")
    }

    var tasks_cloud_access_recipientInactive: String {
        pick(
            en: "Your access isn't active, so you can't change this task. Only the owner can invite you again.",
            uz: "Kirish huquqingiz faol emas, shuning uchun bu vazifani oʻzgartira olmaysiz. Sizni faqat egasi qayta taklif qila oladi.",
            ru: "Ваш доступ неактивен, поэтому изменить задачу нельзя. Пригласить вас снова может только владелец."
        )
    }

    var tasks_cloud_access_recipientDoesNotExpire: String {
        pick(
            en: "Your access doesn't expire. It ends if the person who assigned it removes you, assigns it to someone else or deletes it, or if you leave.",
            uz: "Kirish huquqingiz muddatsiz. Topshirgan odam sizni olib tashlasa, vazifani boshqa kishiga topshirsa yoki oʻchirsa yoxud siz chiqsangiz, u tugaydi.",
            ru: "Ваш доступ бессрочный. Он прекратится, если тот, кто поручил задачу, снимет вас, поручит её другому или удалит её либо если вы выйдете."
        )
    }

    var tasks_cloud_editor_leave: String {
        pick(en: "Leave Task", uz: "Vazifadan chiqish", ru: "Выйти из задачи")
    }

    var tasks_cloud_leave_title: String {
        pick(en: "Leave this task?", uz: "Vazifadan chiqasizmi?", ru: "Выйти из задачи?")
    }

    var tasks_cloud_leave_text: String {
        pick(
            en: "It disappears from your tasks. The person who assigned it sees that you left. To get it back, they have to assign it to you again.",
            uz: "U vazifalaringizdan yoʻqoladi. Topshirgan odam siz chiqqaningizni koʻradi. Qaytarish uchun u vazifani sizga qayta topshirishi kerak.",
            ru: "Задача исчезнет из ваших задач. Тот, кто её поручил, увидит, что вы вышли. Чтобы вернуть её, он(а) должен(на) поручить её вам снова."
        )
    }

    // MARK: - Lists

    var tasks_cloud_lists_footer: String {
        pick(
            en: "Tasks added without a list go to Inbox.",
            uz: "Roʻyxatsiz qoʻshilgan vazifalar Kiruvchiga tushadi.",
            ru: "Задачи без списка попадают во «Входящие»."
        )
    }

    func tasks_cloud_deleteList_text(taskCount: Int) -> String {
        let base = pick(
            en: "This can't be undone.",
            uz: "Buni qaytarib boʻlmaydi.",
            ru: "Это действие нельзя отменить."
        )
        guard taskCount > 0 else {
            return base
        }
        let tasks = pick(
            en: "Its \(taskCount) tasks are deleted too, also for the people they are assigned to.",
            uz: "Undagi \(taskCount) ta vazifa ham oʻchiriladi, ular topshirilgan kishilar uchun ham.",
            ru: "Задачи в нём (\(taskCount)) тоже будут удалены, в том числе у исполнителей."
        )
        return tasks + " " + base
    }

    // MARK: - Unsent changes (repair)

    var tasks_cloud_issues_title: String {
        pick(en: "Unsent Changes", uz: "Yuborilmagan oʻzgarishlar", ru: "Неотправленные изменения")
    }

    var tasks_cloud_issues_empty: String {
        pick(en: "All changes are sent.", uz: "Barcha oʻzgarishlar yuborilgan.", ru: "Все изменения отправлены.")
    }

    var tasks_cloud_issues_footer: String {
        pick(
            en: "Nothing here is merged or sent again without your choice. Discarding removes only the unsent change; nothing changes on the server.",
            uz: "Bu yerda hech narsa sizning tanlovingizsiz birlashtirilmaydi yoki qayta yuborilmaydi. Bekor qilish faqat yuborilmagan oʻzgarishni oʻchiradi; serverda hech narsa oʻzgarmaydi.",
            ru: "Здесь ничего не объединяется и не отправляется повторно без вашего выбора. «Отменить» удаляет только неотправленное изменение; на сервере ничего не меняется."
        )
    }

    func tasks_cloud_issue_operation(_ kind: TasksCloudOperationDisplayKind, title: String?) -> String {
        let quoted = title.map { tasksIsolatedDisplayText($0) }.map { pick(en: "“\($0)”", uz: "“\($0)”", ru: "«\($0)»") }
        let subject = quoted.map { " " + $0 } ?? ""
        switch kind {
        case .listCreate:
            return pick(en: "New list", uz: "Yangi roʻyxat", ru: "Новый список") + subject
        case .listUpdate:
            return pick(en: "List change", uz: "Roʻyxat oʻzgarishi", ru: "Изменение списка") + subject
        case .listDelete:
            return pick(en: "Delete list", uz: "Roʻyxatni oʻchirish", ru: "Удаление списка") + subject
        case .taskCreate:
            return pick(en: "New task", uz: "Yangi vazifa", ru: "Новая задача") + subject
        case .taskUpdate:
            return pick(en: "Task edit", uz: "Vazifa tahriri", ru: "Правка задачи") + subject
        case .taskComplete:
            return pick(en: "Done / not done", uz: "Bajarildi / bajarilmadi", ru: "Отметка выполнения") + subject
        case .taskDelete:
            return pick(en: "Delete task", uz: "Vazifani oʻchirish", ru: "Удаление задачи") + subject
        case .inviteRequest:
            return pick(en: "Assigning", uz: "Masʼul tayinlash", ru: "Назначение исполнителя") + subject
        case .inviteRespond:
            return pick(en: "Answer to an assignment", uz: "Topshiriqqa javob", ru: "Ответ на поручение") + subject
        case .inviteRevoke:
            return pick(en: "Remove assignee", uz: "Masʼulni olib tashlash", ru: "Снятие исполнителя") + subject
        case .senderBlock:
            return pick(en: "Block sender", uz: "Yuboruvchini bloklash", ru: "Блокировка отправителя") + subject
        case .senderUnblock:
            return pick(en: "Unblock sender", uz: "Blokdan chiqarish", ru: "Разблокировка отправителя") + subject
        }
    }

    func tasks_cloud_issue_state(_ state: TasksCloudIssueDisplayState) -> String {
        switch state {
        case .waiting:
            return pick(en: "Waiting to be sent", uz: "Yuborilishini kutmoqda", ru: "Ждёт отправки")
        case .sending:
            return pick(en: "Sending…", uz: "Yuborilmoqda…", ru: "Отправка…")
        case .waitingForEarlierChange:
            return pick(en: "Waits for an earlier change", uz: "Oldingi oʻzgarishni kutmoqda", ru: "Ждёт предыдущего изменения")
        case .paused:
            return pick(en: "Paused — account not linked", uz: "Toʻxtatilgan — akkaunt bogʻlanmagan", ru: "Приостановлено — аккаунт не привязан")
        case .creationNotPermitted:
            return pick(en: "Your current plan doesn't allow creating this", uz: "Joriy tarifingiz buni yaratishga ruxsat bermaydi", ru: "Текущий тариф не позволяет это создать")
        case .invalid:
            return pick(en: "The server didn't accept this change", uz: "Server bu oʻzgarishni qabul qilmadi", ru: "Сервер не принял это изменение")
        case .integrity:
            return pick(en: "Kept for review: the app found an inconsistency", uz: "Koʻrib chiqish uchun saqlandi: ilova nomuvofiqlik topdi", ru: "Сохранено для проверки: приложение обнаружило несоответствие")
        case let .conflict(reason):
            switch reason {
            case .revisionChanged:
                return pick(en: "Changed elsewhere since you edited it", uz: "Siz tahrirlaganingizdan keyin boshqa joyda oʻzgargan", ru: "Изменено в другом месте после вашей правки")
            case .invitationChanged:
                return pick(en: "The assignment changed", uz: "Topshiriq oʻzgargan", ru: "Поручение изменилось")
            case .invitationExpired:
                return pick(en: "The assignment expired (not accepted in 7 days)", uz: "Topshiriq muddati tugagan (7 kun ichida qabul qilinmadi)", ru: "Срок поручения истёк (не принято за 7 дней)")
            case .completedTask:
                return pick(en: "The task is already completed", uz: "Vazifa allaqachon bajarilgan", ru: "Задача уже выполнена")
            }
        case .notFound:
            return pick(en: "It no longer exists on the server", uz: "U serverda endi mavjud emas", ru: "Этого больше нет на сервере")
        case .awaitingSync:
            return pick(en: "Sent, waiting for confirmation", uz: "Yuborildi, tasdiq kutilmoqda", ru: "Отправлено, ждёт подтверждения")
        case .stalled:
            return pick(en: "Couldn't be sent after several tries", uz: "Bir necha urinishdan keyin ham yuborilmadi", ru: "Не удалось отправить после нескольких попыток")
        case let .rateLimited(seconds):
            return self.tasks_cloud_status_rateLimited(seconds: seconds)
        case .offline:
            return pick(en: "Waiting for connection", uz: "Ulanish kutilmoqda", ru: "Ожидание соединения")
        case .serviceUnavailable:
            return pick(en: "Waiting — the Tasks service is unavailable", uz: "Kutmoqda — Tasks xizmati ishlamayapti", ru: "Ожидание — сервис задач недоступен")
        case .sessionProblem:
            return pick(en: "Waiting — link your account to send", uz: "Kutmoqda — yuborish uchun akkauntni bogʻlang", ru: "Ожидание — привяжите аккаунт для отправки")
        case .accountChanged:
            return pick(
                en: "Not sent: this Telegram account is now linked to a different Zenlygram account",
                uz: "Yuborilmadi: bu Telegram akkaunti endi boshqa Zenlygram akkauntiga bogʻlangan",
                ru: "Не отправлено: этот аккаунт Telegram теперь привязан к другому аккаунту Zenlygram"
            )
        case let .fieldsChanged(fields):
            return self.tasks_cloud_conflict_fields(self.tasks_cloud_fieldList(fields))
        case .membersChanged:
            // Unsent Changes asks with the list's current task count (`tasks_cloud_members_changed`).
            return self.tasks_cloud_conflict_title
        case .consentRequired:
            return self.tasks_cloud_consentOff
        case .consentFenced:
            return self.tasks_cloud_consentFenced
        }
    }

    var tasks_cloud_issue_retry: String {
        pick(en: "Send Again", uz: "Qayta yuborish", ru: "Отправить снова")
    }

    var tasks_cloud_issue_discard: String {
        pick(en: "Discard Change", uz: "Oʻzgarishni bekor qilish", ru: "Отменить изменение")
    }

    var tasks_cloud_issue_keepServer: String {
        pick(en: "Keep Current Version", uz: "Joriy versiyani qoldirish", ru: "Оставить текущую версию")
    }

    var tasks_cloud_issue_applyMine: String {
        pick(en: "Apply My Change Again", uz: "Oʻzgarishimni qayta qoʻllash", ru: "Применить моё изменение снова")
    }

    var tasks_cloud_issue_saveAsNew: String {
        pick(en: "Save as New Task", uz: "Yangi vazifa sifatida saqlash", ru: "Сохранить как новую задачу")
    }

    var tasks_cloud_issue_discard_title: String {
        pick(en: "Discard this change?", uz: "Oʻzgarish bekor qilinsinmi?", ru: "Отменить изменение?")
    }

    var tasks_cloud_issue_discard_text: String {
        pick(
            en: "It was not sent and will be removed.",
            uz: "U yuborilmagan va olib tashlanadi.",
            ru: "Оно не было отправлено и будет удалено."
        )
    }

    var tasks_cloud_conflict_title: String {
        pick(en: "Changed elsewhere", uz: "Boshqa joyda oʻzgargan", ru: "Изменено в другом месте")
    }

    var tasks_cloud_conflict_text: String {
        pick(
            en: "The server has a newer version. Keep it, or apply your change on top of it as a new change.",
            uz: "Serverda yangiroq versiya bor. Uni qoldiring yoki oʻzgarishingizni uning ustiga yangi oʻzgarish sifatida qoʻllang.",
            ru: "На сервере более новая версия. Оставьте её или примените своё изменение поверх как новое."
        )
    }

    var tasks_cloud_notice_removed: String {
        pick(
            en: "A task assigned to you was removed.",
            uz: "Sizga topshirilgan bir vazifa olib tashlandi.",
            ru: "Порученная вам задача снята."
        )
    }

    // MARK: - Import

    var tasks_cloud_import_title: String {
        pick(en: "Sync Older Tasks", uz: "Eski vazifalarni sinxronlash", ru: "Синхронизировать старые задачи")
    }

    /// Declension-free counts in every language (§15.1).
    func tasks_cloud_import_summary(lists: Int, tasks: Int) -> String {
        pick(
            en: "Lists: \(lists), tasks: \(tasks). They will be synced to this account; the older copies stay read-only in Older Tasks.",
            uz: "\(lists) ta roʻyxat va \(tasks) ta vazifa shu akkauntga sinxronlanadi; eski nusxalar «Eski vazifalar»da faqat oʻqish uchun qoladi.",
            ru: "Списков: \(lists), задач: \(tasks). Они будут синхронизированы с этим аккаунтом; старые копии останутся только для чтения в «Старых задачах»."
        )
    }

    var tasks_cloud_import_listsHeader: String {
        pick(en: "Lists to copy", uz: "Nusxalanadigan roʻyxatlar", ru: "Копируемые списки")
    }

    /// R4 (one inbox semantics): the device Inbox under its default title maps to the synced board's
    /// Inbox; a renamed one is a list like any other.
    var tasks_cloud_import_inboxNote: String {
        pick(
            en: "Tasks from the old Inbox go to Inbox; every other list becomes its own list.",
            uz: "Eski Kiruvchidagi vazifalar Kiruvchiga oʻtadi; boshqa har bir roʻyxat alohida roʻyxat boʻladi.",
            ru: "Задачи из старых «Входящих» попадут во «Входящие»; каждый другой список станет отдельным списком."
        )
    }

    /// wf15 (D4): legacy assignees are asked about separately (the one-time sheet) and are never sent
    /// automatically; the copy itself never carries them.
    var tasks_cloud_import_annotationsNote: String {
        pick(
            en: "Assignees are asked about separately and are never sent automatically.",
            uz: "Masʼullar alohida soʻraladi; ular hech qachon avtomatik yuborilmaydi.",
            ru: "Об исполнителях спросим отдельно; автоматически они никогда не отправляются."
        )
    }

    /// R4 normalization (design 30 §7.1): rows are adjusted instead of refused.
    var tasks_cloud_import_normalizationNote: String {
        pick(
            en: "A title that is too long is shortened and kept in full in the notes; an empty title gets a standard name.",
            uz: "Juda uzun sarlavha qisqartiriladi va toʻliq holda izohlarda saqlanadi; boʻsh sarlavha oʻrniga standart nom qoʻyiladi.",
            ru: "Слишком длинное название сокращается и целиком сохраняется в заметках; пустое название заменяется стандартным."
        )
    }

    var tasks_cloud_import_privacyNote: String {
        pick(
            en: "Synced tasks are stored and processed on the Zenlygram server and are not end-to-end encrypted. Creating them follows your current plan; anything the server refuses stays unsent for you to review.",
            uz: "Sinxronlangan vazifalar Zenlygram serverida saqlanadi va qayta ishlanadi, uchdan-uchga shifrlanmagan. Ularni yaratish joriy tarifingizga bogʻliq; server rad etgan narsalar koʻrib chiqishingiz uchun yuborilmagan holda qoladi.",
            ru: "Синхронизированные задачи хранятся и обрабатываются на сервере Zenlygram и не защищены сквозным шифрованием. Создание зависит от вашего текущего тарифа; отклонённое сервером останется неотправленным для проверки."
        )
    }

    var tasks_cloud_import_confirm: String {
        pick(en: "Sync", uz: "Sinxronlash", ru: "Синхронизировать")
    }

    var tasks_cloud_import_nothing: String {
        pick(en: "There are no older tasks to sync.", uz: "Sinxronlanadigan eski vazifalar yoʻq.", ru: "Нет старых задач для синхронизации.")
    }

    var tasks_cloud_import_alreadyDone: String {
        pick(
            en: "These older tasks are already synced to this account.",
            uz: "Bu eski vazifalar allaqachon shu akkauntga sinxronlangan.",
            ru: "Эти старые задачи уже синхронизированы с этим аккаунтом."
        )
    }

    var tasks_cloud_import_started: String {
        pick(
            en: "Syncing started. Changes are sent as soon as sync allows.",
            uz: "Sinxronlash boshlandi. Oʻzgarishlar imkon boʻlishi bilan yuboriladi.",
            ru: "Синхронизация началась. Изменения отправятся, как только это станет возможно."
        )
    }
}

public extension SGTasksL10n {
    var tasks_cloud_notice_importBlocked: String {
        pick(
            en: "A list couldn't be created on the server. Its tasks wait until you choose what to do.",
            uz: "Roʻyxatni serverda yaratib boʻlmadi. Uning vazifalari siz qaror qilguningizcha kutadi.",
            ru: "Список не удалось создать на сервере. Его задачи ждут, пока вы не решите, что с ними делать."
        )
    }

    var tasks_cloud_issue_moveListTasksToInbox: String {
        pick(en: "Move Its Tasks to Inbox", uz: "Vazifalarini Kiruvchiga koʻchirish", ru: "Переместить его задачи во «Входящие»")
    }

    var tasks_cloud_error_title: String {
        pick(
            en: "This title can't be used. Titles need visible text, no spaces at the start or end, and at most 200 characters.",
            uz: "Bu sarlavhadan foydalanib boʻlmaydi. Sarlavhada koʻrinadigan matn boʻlishi, boshi va oxirida boʻsh joy boʻlmasligi va koʻpi bilan 200 belgi boʻlishi kerak.",
            ru: "Это название нельзя использовать. Нужен видимый текст без пробелов в начале и конце, не длиннее 200 символов."
        )
    }

    var tasks_cloud_error_description: String {
        pick(
            en: "Notes can be at most 4,096 characters.",
            uz: "Izohlar koʻpi bilan 4096 belgidan iborat boʻlishi mumkin.",
            ru: "Заметки могут содержать не более 4096 символов."
        )
    }

    /// Usually transient: recent changes to the list's tasks are waiting for the next sync to confirm
    /// them (and only stays if a change needs attention in Unsent Changes).
    var tasks_cloud_error_listPending: String {
        pick(
            en: "Waiting for sync to confirm recent changes in this list. Try again in a moment. If it keeps waiting, check Unsent Changes.",
            uz: "Bu roʻyxatdagi soʻnggi oʻzgarishlar sinxronlash orqali tasdiqlanishi kutilmoqda. Birozdan keyin qayta urinib koʻring. Agar kutish davom etsa, Yuborilmagan oʻzgarishlarni tekshiring.",
            ru: "Ожидается подтверждение последних изменений в этом списке при синхронизации. Попробуйте ещё раз через минуту. Если ожидание затянется, проверьте «Неотправленные изменения»."
        )
    }

    var tasks_cloud_error_recipient: String {
        pick(
            en: "Only a Telegram user from your contacts can be chosen.",
            uz: "Faqat kontaktlaringizdagi Telegram foydalanuvchisini tanlash mumkin.",
            ru: "Можно выбрать только пользователя Telegram из ваших контактов."
        )
    }

    var tasks_cloud_error_importNotReady: String {
        pick(
            en: "Your tasks are still syncing. Try again once they are up to date.",
            uz: "Vazifalaringiz hali sinxronlanmoqda. Ular yangilangach, qayta urinib koʻring.",
            ru: "Задачи ещё синхронизируются. Повторите после обновления."
        )
    }

    var tasks_cloud_error_gone: String {
        pick(
            en: "This item is no longer available.",
            uz: "Bu element endi mavjud emas.",
            ru: "Этот элемент больше недоступен."
        )
    }

    var tasks_cloud_import_status_alreadyCopied: String {
        pick(en: "Already copied", uz: "Allaqachon nusxalangan", ru: "Уже скопировано")
    }

    var tasks_cloud_import_status_needsCorrection: String {
        pick(en: "Needs a fix — stays in Older Tasks", uz: "Tuzatish kerak — «Eski vazifalar»da qoladi", ru: "Нужно исправить — остаётся в «Старых задачах»")
    }

    func tasks_cloud_import_skipped(_ count: Int) -> String {
        pick(
            en: "Tasks that can't be synced as they are (for example, a title or date doesn't fit the rules, or an earlier attempt failed): \(count). They stay in Older Tasks.",
            uz: "\(count) ta vazifani shu holicha sinxronlab boʻlmaydi (masalan, sarlavha yoki sana qoidalarga mos emas yoki oldingi urinish muvaffaqiyatsiz boʻlgan); ular «Eski vazifalar»da qoladi.",
            ru: "Задач, которые нельзя синхронизировать как есть (например, название или дата не подходят под правила либо прежняя попытка не удалась): \(count). Они остаются в «Старых задачах»."
        )
    }

    /// One preview row's state, as the consent screen lists it.
    func tasks_cloud_import_status(_ status: SGTasksCloudImportPreview.ItemStatus, taskCount: Int) -> String {
        switch status {
        case .importable:
            return self.tasks_cloud_taskCount(taskCount)
        case .resendPreviousAttempt:
            return pick(en: "Will be sent again", uz: "Qayta yuboriladi", ru: "Будет отправлено снова")
        case .alreadyInCloud:
            return self.tasks_cloud_import_status_alreadyCopied
        case .importPending:
            return pick(en: "Syncing already in progress", uz: "Sinxronlash allaqachon davom etmoqda", ru: "Синхронизация уже идёт")
        case .importBlocked:
            return pick(en: "Earlier copy needs attention in Unsent Changes", uz: "Oldingi nusxalash Yuborilmagan oʻzgarishlarda eʼtibor talab qiladi", ru: "Прежнее копирование требует внимания в «Неотправленных изменениях»")
        case .removedFromCloud:
            return pick(en: "Deleted after syncing — not synced again", uz: "Sinxronlangach oʻchirilgan — qayta sinxronlanmaydi", ru: "Удалено после синхронизации — повторно не синхронизируется")
        case .needsCorrection:
            return self.tasks_cloud_import_status_needsCorrection
        }
    }

    var tasks_cloud_import_resendNote: String {
        pick(
            en: "Some items were sent before without a confirmation from the server; they are sent again as the same items. If one of them had already reached the server and was deleted since, it will not reappear.",
            uz: "Baʼzi elementlar avval serverdan tasdiqsiz yuborilgan; ular xuddi oʻsha elementlar sifatida qayta yuboriladi. Agar ulardan biri serverga yetib borgan va keyin oʻchirilgan boʻlsa, u qayta paydo boʻlmaydi.",
            ru: "Некоторые элементы уже отправлялись без подтверждения сервера; они будут отправлены снова как те же элементы. Если какой-то из них уже попал на сервер и был удалён, он не появится снова."
        )
    }

    var tasks_cloud_import_removedNote: String {
        pick(
            en: "Items synced before and deleted later are not synced again.",
            uz: "Avval sinxronlanib, keyin oʻchirilgan elementlar qayta sinxronlanmaydi.",
            ru: "Элементы, которые уже синхронизировались и потом были удалены, повторно не синхронизируются."
        )
    }

    var tasks_cloud_import_waitingOnEarlier: String {
        pick(
            en: "An earlier copy of some device tasks is still being sent or needs attention in Unsent Changes. It is not copied again from here.",
            uz: "Baʼzi qurilma vazifalarining oldingi nusxasi hali yuborilmoqda yoki Yuborilmagan oʻzgarishlarda eʼtibor talab qiladi. U bu yerdan qayta nusxalanmaydi.",
            ru: "Прежняя копия части задач с устройства ещё отправляется или требует внимания в «Неотправленных изменениях». Отсюда она повторно не копируется."
        )
    }

    func tasks_cloud_import_result_notCopied(_ count: Int) -> String {
        pick(
            en: "Items not synced: \(count). They stay in Older Tasks.",
            uz: "\(count) ta element sinxronlanmadi va «Eski vazifalar»da qoladi.",
            ru: "Не синхронизировано элементов: \(count). Они остаются в «Старых задачах»."
        )
    }

    var tasks_cloud_error_laterChangesPending: String {
        pick(
            en: "This task has newer unsent changes. Discard them in Unsent Changes first, then fix this one.",
            uz: "Bu vazifada yangiroq yuborilmagan oʻzgarishlar bor. Avval ularni Yuborilmagan oʻzgarishlarda bekor qiling, keyin buni tuzating.",
            ru: "У задачи есть более новые неотправленные изменения. Сначала отмените их в «Неотправленных изменениях», затем исправьте это."
        )
    }

    // MARK: - Repair of a refused change

    var tasks_cloud_issue_repairTask: String {
        pick(en: "Edit Task and Send Again…", uz: "Vazifani tahrirlab qayta yuborish…", ru: "Изменить задачу и отправить снова…")
    }

    var tasks_cloud_issue_repairList: String {
        pick(en: "Rename List and Send Again…", uz: "Roʻyxat nomini oʻzgartirib qayta yuborish…", ru: "Переименовать список и отправить снова…")
    }

    var tasks_cloud_issue_repairTitle: String {
        pick(en: "Fix Unsent Change", uz: "Yuborilmagan oʻzgarishni tuzatish", ru: "Исправить изменение")
    }

    var tasks_cloud_repair_explanation: String {
        pick(
            en: "The server didn't accept this task as it is — the title, notes or assignee may not fit its rules. Change what needs fixing and tap Done to save it as a new change. Nothing is sent before you tap Done.",
            uz: "Server bu vazifani shu holicha qabul qilmadi — sarlavha, izohlar yoki masʼul qoidalarga mos kelmasligi mumkin. Tuzatish kerak boʻlgan joyni oʻzgartiring va yangi oʻzgarish sifatida saqlash uchun Tayyor tugmasini bosing. Tayyor bosilmaguncha hech narsa yuborilmaydi.",
            ru: "Сервер не принял задачу в таком виде — название, заметки или исполнитель могут не соответствовать правилам. Исправьте нужное и нажмите «Готово», чтобы сохранить это как новое изменение. До нажатия «Готово» ничего не отправляется."
        )
    }

    var tasks_cloud_repair_unchanged: String {
        pick(
            en: "Nothing was changed. The same content would be refused again — edit it first, or discard the change.",
            uz: "Hech narsa oʻzgartirilmadi. Xuddi shu mazmun yana rad etiladi — avval uni tahrirlang yoki oʻzgarishni bekor qiling.",
            ru: "Ничего не изменено. То же содержимое снова будет отклонено — сначала исправьте его или отмените изменение."
        )
    }

    // MARK: - Counts and accessibility

    func tasks_cloud_taskCount(_ count: Int) -> String {
        let ruWord = countRuWord(count, one: "задача", few: "задачи", many: "задач")
        return pick(
            en: count == 1 ? "1 task" : "\(count) tasks",
            uz: "\(count) ta vazifa",
            ru: "\(count) \(ruWord)"
        )
    }

    func tasks_cloud_listProgress(done: Int, total: Int) -> String {
        return pick(
            en: "\(done) of \(total) done",
            uz: "\(total) tadan \(done) tasi bajarilgan",
            ru: "Выполнено \(done) из \(total)"
        )
    }

    var tasks_cloud_a11y_openHint: String {
        pick(en: "Opens the assigned task", uz: "Topshirilgan vazifani ochadi", ru: "Открывает порученную задачу")
    }

    func tasks_cloud_a11y_added(_ title: String) -> String {
        pick(en: "Added: \(title)", uz: "Qoʻshildi: \(title)", ru: "Добавлено: \(title)")
    }

    func tasks_cloud_a11y_markedDone(_ title: String) -> String {
        pick(en: "Done: \(title)", uz: "Bajarildi: \(title)", ru: "Выполнено: \(title)")
    }

    func tasks_cloud_a11y_markedOpen(_ title: String) -> String {
        pick(en: "Not done: \(title)", uz: "Bajarilmadi: \(title)", ru: "Не выполнено: \(title)")
    }

    // MARK: - Stale and refused actions

    var tasks_cloud_error_invitationExpired: String {
        pick(en: "This invitation has expired.", uz: "Bu taklifning muddati tugagan.", ru: "Срок этого приглашения истёк.")
    }

    var tasks_cloud_error_changedElsewhere: String {
        pick(
            en: "This changed while you were deciding. Nothing was sent — look at the current version and try again.",
            uz: "Siz qaror qilayotganingizda bu oʻzgardi. Hech narsa yuborilmadi — joriy versiyani koʻrib, qayta urinib koʻring.",
            ru: "Пока вы решали, это изменилось. Ничего не отправлено — посмотрите текущую версию и попробуйте снова."
        )
    }

    var tasks_cloud_error_alreadyPending: String {
        pick(
            en: "An answer for this is already waiting to be sent.",
            uz: "Bunga javob allaqachon yuborilishini kutmoqda.",
            ru: "Ответ на это уже ждёт отправки."
        )
    }

    var tasks_cloud_error_notOwner: String {
        pick(
            en: "Only the task's owner can do this. Nothing was changed.",
            uz: "Buni faqat vazifa egasi qila oladi. Hech narsa oʻzgarmadi.",
            ru: "Это может сделать только владелец задачи. Ничего не изменено."
        )
    }

    var tasks_cloud_error_notAssignee: String {
        pick(
            en: "Your access to this task isn't active, so nothing was changed. Only the person who assigned it can assign it to you again.",
            uz: "Bu vazifaga kirish huquqingiz faol emas, shuning uchun hech narsa oʻzgarmadi. Uni sizga faqat topshirgan odam qayta topshira oladi.",
            ru: "Ваш доступ к этой задаче неактивен, поэтому ничего не изменено. Поручить её вам снова может только тот, кто её поручил."
        )
    }

    var tasks_cloud_unblock_title: String {
        pick(en: "Unblock this sender?", uz: "Yuboruvchi blokdan chiqarilsinmi?", ru: "Разблокировать отправителя?")
    }

    var tasks_cloud_accountChanged_copy_title: String {
        pick(en: "Copy to the current account?", uz: "Joriy akkauntga nusxalansinmi?", ru: "Скопировать в текущий аккаунт?")
    }

    var tasks_cloud_accountChanged_copy_text: String {
        pick(
            en: "This change was made while this Telegram account was linked to a different Zenlygram account, so it was not sent. Saving it as a new task creates it in the Zenlygram account linked now, under your current plan.",
            uz: "Bu oʻzgarish Telegram akkaunti boshqa Zenlygram akkauntiga bogʻlangan paytda qilingan, shuning uchun yuborilmagan. Uni yangi vazifa sifatida saqlash hozir bogʻlangan Zenlygram akkauntida joriy tarifingiz boʻyicha yaratadi.",
            ru: "Это изменение сделано, когда аккаунт Telegram был привязан к другому аккаунту Zenlygram, поэтому оно не отправлено. Сохранение как новой задачи создаст её в привязанном сейчас аккаунте Zenlygram по текущему тарифу."
        )
    }

    var tasks_cloud_editor_goneWithChanges_title: String {
        pick(en: "This task is no longer available", uz: "Bu vazifa endi mavjud emas", ru: "Эта задача больше недоступна")
    }

    var tasks_cloud_editor_goneWithChanges_text: String {
        pick(
            en: "It was deleted or changed elsewhere. You can save your edits as a new task or discard them.",
            uz: "U boshqa joyda oʻchirilgan yoki oʻzgartirilgan. Tahrirlaringizni yangi vazifa sifatida saqlashingiz yoki bekor qilishingiz mumkin.",
            ru: "Её удалили или изменили в другом месте. Можно сохранить правки как новую задачу или отменить их."
        )
    }

    var tasks_cloud_editor_goneDraft_footer: String {
        pick(
            en: "This task is no longer available to you. Your edits are kept until you save them as a new task or discard them.",
            uz: "Bu vazifa endi sizga mavjud emas. Tahrirlaringiz yangi vazifa sifatida saqlaguningizcha yoki bekor qilguningizcha saqlanadi.",
            ru: "Эта задача вам больше недоступна. Правки сохранятся, пока вы не сохраните их как новую задачу или не отмените."
        )
    }

    var tasks_cloud_import_done: String {
        pick(en: "Syncing started", uz: "Sinxronlash boshlandi", ru: "Синхронизация началась")
    }
}

// MARK: - R4: automatic sync — cut-over, consent, conflicts, logout (design 30 §5.6, §5.7)
//
// Uzbek uses U+02BB (oʻ, gʻ) and U+02BC (tutuq belgisi), like the compliance texts. Russian counts
// use declension-free phrasing ("…: %1"), so no plural rules are needed.

public extension SGTasksL10n {
    // MARK: Migration

    /// The copy's placeholders are the normalizer's (the record's locale is stored with the copy, so
    /// a rerun seals the same bytes); the same words in the UI language.
    var tasks_migration_untitledTask: String {
        pick(
            en: SGTasksMigrationNormalizer(locale: .en).untitledTaskPlaceholder,
            uz: SGTasksMigrationNormalizer(locale: .uz).untitledTaskPlaceholder,
            ru: SGTasksMigrationNormalizer(locale: .ru).untitledTaskPlaceholder
        )
    }

    var tasks_migration_importedList: String {
        pick(
            en: SGTasksMigrationNormalizer(locale: .en).importedListPlaceholder,
            uz: SGTasksMigrationNormalizer(locale: .uz).importedListPlaceholder,
            ru: SGTasksMigrationNormalizer(locale: .ru).importedListPlaceholder
        )
    }

    /// A write met a migration step copying the device database (`TodoDatabaseError.migrating`).
    var tasks_migration_busy: String {
        pick(
            en: "Your older tasks are being synced. Try again in a moment.",
            uz: "Eski vazifalaringiz sinxronlanmoqda. Birozdan soʻng qayta urinib koʻring.",
            ru: "Старые задачи синхронизируются. Повторите через мгновение."
        )
    }

    // MARK: Consent states of the synced board

    var tasks_cloud_consentOff: String {
        pick(
            en: "Sync is off, so changes can't be made here.",
            uz: "Sinxronlash oʻchiq, shuning uchun bu yerda oʻzgartirib boʻlmaydi.",
            ru: "Синхронизация выключена, поэтому изменения здесь недоступны."
        )
    }

    var tasks_cloud_withdrawn: String {
        pick(
            en: "Sync stopped after you withdrew consent. Changes can't be made here.",
            uz: "Rozilikni qaytarib olganingizdan soʻng sinxronlash toʻxtadi. Bu yerda oʻzgartirib boʻlmaydi.",
            ru: "Синхронизация остановлена после отзыва согласия. Изменения здесь недоступны."
        )
    }

    var tasks_cloud_consentFenced: String {
        pick(
            en: "Sync is paused while your data consent is being confirmed. Changes can't be made right now.",
            uz: "Maʼlumotlar roziligingiz tasdiqlanayotgani uchun sinxronlash toʻxtatildi. Hozircha oʻzgartirib boʻlmaydi.",
            ru: "Синхронизация приостановлена, пока подтверждается ваше согласие на обработку данных. Изменения сейчас недоступны."
        )
    }

    /// Why the cached Cloud board is read-only.
    func tasks_cloud_readOnly(_ reason: TasksCloudReadOnlyReason) -> String {
        switch reason {
        case .consentOff:
            return self.tasks_cloud_consentOff
        case .withdrawn:
            return self.tasks_cloud_withdrawn
        case .consentFenced:
            return self.tasks_cloud_consentFenced
        }
    }

    // MARK: Automatic resolution and explicit conflicts

    var tasks_cloud_notice_deleteKept: String {
        pick(
            en: "A task you deleted had changed on another device, so it was kept.",
            uz: "Siz oʻchirgan vazifa boshqa qurilmada oʻzgargan edi, shuning uchun u saqlab qolindi.",
            ru: "Удалённая вами задача изменилась на другом устройстве, поэтому она сохранена."
        )
    }

    /// `fields` already joined (`tasks_cloud_fieldList`).
    func tasks_cloud_conflict_fields(_ fields: String) -> String {
        pick(
            en: "Changed on another device: \(fields)",
            uz: "Boshqa qurilmada oʻzgargan: \(fields)",
            ru: "Изменено на другом устройстве: \(fields)"
        )
    }

    var tasks_cloud_conflict_keepMine: String {
        pick(en: "Keep mine", uz: "Menikini qoldirish", ru: "Оставить моё")
    }

    var tasks_cloud_conflict_useOther: String {
        pick(en: "Use the other version", uz: "Boshqa versiyani olish", ru: "Взять другую версию")
    }

    func tasks_cloud_members_changed(_ count: Int) -> String {
        pick(
            en: count == 1 ? "This list changed on another device and now has 1 task. Delete the list and all its tasks?" : "This list changed on another device and now has \(count) tasks. Delete the list and all its tasks?",
            uz: "Bu roʻyxat boshqa qurilmada oʻzgargan, endi unda \(count) ta vazifa bor. Roʻyxat va undagi barcha vazifalar oʻchirilsinmi?",
            ru: "Список изменён на другом устройстве, задач в нём теперь: \(count). Удалить список и все его задачи?"
        )
    }

    func tasks_cloud_field(_ field: SGTasksWire.ContentField) -> String {
        switch field {
        case .title:
            return pick(en: "Title", uz: "Sarlavha", ru: "Название")
        case .description:
            return pick(en: "Notes", uz: "Izoh", ru: "Заметки")
        case .listId:
            return pick(en: "List", uz: "Roʻyxat", ru: "Список")
        case .dueAt:
            return pick(en: "Deadline", uz: "Muddat", ru: "Срок")
        case .priority:
            return pick(en: "Priority", uz: "Muhimlik", ru: "Приоритет")
        case .sortOrder:
            return pick(en: "Position", uz: "Tartib", ru: "Порядок")
        case .annotation:
            return pick(en: "Assignee", uz: "Masʼul", ru: "Исполнитель")
        }
    }

    /// Field names in content order, comma-separated.
    func tasks_cloud_fieldList(_ fields: [SGTasksWire.ContentField]) -> String {
        return fields.sorted().map { self.tasks_cloud_field($0) }.joined(separator: ", ")
    }

    // MARK: Logout

    func tasks_logout_unsent(_ count: Int) -> String {
        pick(
            en: "Changes to your tasks that haven't reached the server yet: \(count). They will be lost if you log out now.",
            uz: "Vazifalaringizdagi \(count) ta oʻzgarish hali serverga yetib bormagan. Hozir chiqsangiz, ular yoʻqoladi.",
            ru: "Изменений задач, ещё не дошедших до сервера: \(count). При выходе сейчас они будут потеряны."
        )
    }

    var tasks_logout_migration: String {
        pick(
            en: "Syncing your older tasks continues the next time you sign in to this account.",
            uz: "Eski vazifalaringizni sinxronlash shu akkauntga keyingi safar kirganingizda davom etadi.",
            ru: "Синхронизация старых задач продолжится при следующем входе в этот аккаунт."
        )
    }

    // MARK: Copy preview (R4 rules)

    /// The device Inbox under its default title: its tasks go to the synced board's Inbox (no list is created).
    var tasks_cloud_import_status_cloudInbox: String {
        pick(en: "Its tasks go to Inbox", uz: "Vazifalari Kiruvchiga oʻtadi", ru: "Задачи попадут во «Входящие»")
    }
}
