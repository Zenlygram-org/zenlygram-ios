import Foundation

// Zenlygram — Tasks: one board, Masʼul = assignment, both sides see each other (wf15). The strings
// of the single board's status line, the read-only Eski vazifalar / Sinxronlangan nusxa views, the
// owner's Masʼul section, the assignee's "Menga topshirilgan" view and izoh, the Takliflar hint,
// the one-time legacy-assignee sheet (D4) and the logout paragraph. Same pick(en:uz:ru:) scheme
// as SGTasksL10n.swift; the values are the wf15 strings table (STRINGS.json / §15.2), byte for byte.
//
// Wording rules (§15.1): no Bulut / Cloud / Облако, no "Shu qurilmada" / "On This Device", no
// "Qurilma arxivi" / "Device archive" (Tests/check-strings.sh); the Uzbek apostrophes are U+02BB in
// oʻ / gʻ and U+02BC for the tutuq belgisi (Masʼul, Maʼlumot, IDʼsi, baʼzi); counts are
// declension-free in every language ("…: {n}"); the owner-facing copy never describes the contact
// rule (§13); names are inserted by the caller (bidi-isolate them with `tasksIsolatedDisplayText`).

public extension SGTasksL10n {
    // MARK: - Sync status line of the single board (§3, states S1–S11)

    /// Single board, state S2: the ONE footer line (a11y id sgtasks.sync.off). Tap -> Data & consent
    /// via SGTasksConsentEntry.dataConsentController; plain text when the hook returns nil.
    var tasks_sync_off: String {
        pick(en: "Sync is off", uz: "Sinxronlash oʻchiq", ru: "Синхронизация выключена")
    }

    /// a11y hint of the sync-off line (only when tappable).
    var tasks_sync_off_a11yHint: String {
        pick(
            en: "Opens Data & consent in Settings.",
            uz: "Sozlamalardagi «Maʼlumotlar va rozilik» boʻlimini ochadi.",
            ru: "Открывает «Данные и согласие» в настройках."
        )
    }

    /// Status line S3/S4 (permission waiting); action = tasks_cloud_link_action (existing, normalised)
    /// -> sgLinkTelegramAccountController.
    var tasks_sync_waitingLink: String {
        pick(
            en: "Sync starts once this account is linked",
            uz: "Akkaunt bogʻlangach sinxronlash boshlanadi",
            ru: "Синхронизация начнётся после привязки аккаунта"
        )
    }

    /// Status line S5 (allowed, device rows not yet enqueued) and S7 when progress total is 0.
    var tasks_sync_turningOn: String {
        pick(en: "Turning sync on…", uz: "Sinxronlash yoqilmoqda…", ru: "Включаем синхронизацию…")
    }

    /// Status line S7 (archive migrating, copy on device). Tappable -> Eski vazifalar.
    func tasks_sync_progress(done: Int, total: Int) -> String {
        pick(
            en: "Syncing older tasks: \(done) of \(total)",
            uz: "Eski vazifalar sinxronlanmoqda: \(done) / \(total)",
            ru: "Синхронизация старых задач: \(done) из \(total)"
        )
    }

    /// Status line S8 (archive newRows). Action tasks_sync_newRows_action; the line itself is tappable
    /// -> Eski vazifalar.
    func tasks_sync_newRows(_ count: Int) -> String {
        pick(
            en: "Older tasks not synced yet: \(count)",
            uz: "\(count) ta eski vazifa hali sinxronlanmagan",
            ru: "Старых задач ещё не синхронизировано: \(count)"
        )
    }

    /// Action of S8 -> the import screen (CREATE-gated, existing commitLegacyImport).
    var tasks_sync_newRows_action: String {
        pick(en: "Sync", uz: "Sinxronlash", ru: "Синхронизировать")
    }

    /// Second line under S7/S8 when keptLocal > 0.
    func tasks_sync_keptLocal(_ count: Int) -> String {
        pick(
            en: "Older tasks that couldn't be synced: \(count)",
            uz: "\(count) ta eski vazifani sinxronlab boʻlmadi",
            ru: "Не удалось синхронизировать старых задач: \(count)"
        )
    }

    /// One-time dismissible notice S9 (archive otherAccount); dismissal stored per account
    /// (UserDefaults sgtasks.notice.otherAccount.<accountPeerId>).
    var tasks_sync_otherAccount: String {
        pick(
            en: "Older tasks went to the first account here that gave data consent. You can view them in Lists.",
            uz: "Eski vazifalar bu yerda birinchi boʻlib maʼlumotlar roziligini bergan akkauntga oʻtgan. Ularni Roʻyxatlar boʻlimida koʻrishingiz mumkin.",
            ru: "Старые задачи перешли к аккаунту, который первым дал здесь согласие на обработку данных. Их можно посмотреть в «Списках»."
        )
    }

    /// Action of the S9 notice -> Eski vazifalar.
    var tasks_sync_view_action: String {
        pick(en: "View", uz: "Koʻrish", ru: "Открыть")
    }

    /// a11y hint of every tappable status line (S7, S8).
    var tasks_sync_olderHint: String {
        pick(
            en: "Opens older tasks (read-only)",
            uz: "Eski vazifalarni ochadi (faqat oʻqish uchun)",
            ru: "Открывает старые задачи (только чтение)"
        )
    }

    // MARK: - Eski vazifalar and Sinxronlangan nusxa (read-only views)

    /// Title of the read-only device-rows screen (TasksLegacyBoardController), its Lists entry and the
    /// accessory of tappable status lines.
    var tasks_older_title: String {
        pick(en: "Older Tasks", uz: "Eski vazifalar", ru: "Старые задачи")
    }

    /// Eski vazifalar footer, archive migrating with the copy on device.
    var tasks_older_footer_migrating: String {
        pick(
            en: "These tasks are being synced. Make changes in the main list.",
            uz: "Bu vazifalar sinxronlanmoqda. Oʻzgartirishlarni asosiy roʻyxatda kiriting.",
            ru: "Эти задачи синхронизируются. Изменения вносите в основном списке."
        )
    }

    /// Eski vazifalar footer after a logout/re-login (awaitsCloudCopy).
    var tasks_older_footer_awaiting: String {
        pick(
            en: "These tasks are synced. They show in your list once it has loaded.",
            uz: "Bu vazifalar sinxronlangan. Roʻyxatingiz yuklangach, ular u yerda koʻrinadi.",
            ru: "Эти задачи синхронизированы. Они появятся в списке, когда он загрузится."
        )
    }

    /// Eski vazifalar footer, archive newRows.
    func tasks_older_footer_newRows(_ count: Int) -> String {
        pick(
            en: "Not synced yet: \(count). Tap Sync on the main list to sync them.",
            uz: "Hali sinxronlanmagan: \(count) ta. Ularni sinxronlash uchun asosiy roʻyxatdagi «Sinxronlash»ni bosing.",
            ru: "Ещё не синхронизировано: \(count). Нажмите «Синхронизировать» в основном списке."
        )
    }

    /// Eski vazifalar footer, state S6b (record skipped existing_mappings/scope_changed) while the
    /// explicit-copy count is not known yet (snapshot incomplete).
    var tasks_older_footer_checking: String {
        pick(
            en: "Checking which of these tasks are already synced. Make changes in the main list.",
            uz: "Bu vazifalardan qaysilari sinxronlangani tekshirilmoqda. Oʻzgartirishlarni asosiy roʻyxatda kiriting.",
            ru: "Проверяем, какие из этих задач уже синхронизированы. Изменения вносите в основном списке."
        )
    }

    /// Eski vazifalar footer, otherAccount / device rows owned by another account.
    var tasks_older_footer_otherAccount: String {
        pick(
            en: "These tasks belong to the first account here that gave data consent. They are read-only.",
            uz: "Bu vazifalar bu yerda birinchi boʻlib rozilik bergan akkauntga tegishli. Ular faqat oʻqish uchun.",
            ru: "Эти задачи принадлежат аккаунту, который первым дал здесь согласие. Они только для чтения."
        )
    }

    /// Read-only device editor title (TasksTaskEditorController archive mode).
    var tasks_older_editorTitle: String {
        pick(en: "Older Task", uz: "Eski vazifa", ru: "Старая задача")
    }

    /// Toast when a read-only device write is refused (TodoDatabaseError.archived); read-only Lists
    /// screen notice.
    var tasks_older_readOnly: String {
        pick(
            en: "Older tasks are read-only. Make changes in the main list.",
            uz: "Eski vazifalar faqat oʻqish uchun. Oʻzgartirishlarni asosiy roʻyxatda kiriting.",
            ru: "Старые задачи только для чтения. Изменения вносите в основном списке."
        )
    }

    /// Lists entry + title of the read-only view of the account's own cached synced tasks after sync
    /// went off (withdrawn) — promised by DataConsent.Withdraw.Confirm.Text.
    var tasks_syncedCopy_title: String {
        pick(en: "Synced Copy", uz: "Sinxronlangan nusxa", ru: "Синхронизированная копия")
    }

    /// Footer of the Sinxronlangan nusxa view (owner-role rows only).
    var tasks_syncedCopy_footer: String {
        pick(
            en: "Sync is off. This read-only copy of your synced tasks stays until you turn sync on again, log out or delete your Zenlygram account.",
            uz: "Sinxronlash oʻchiq. Sinxronlangan vazifalaringizning bu nusxasi faqat oʻqish uchun; u sinxronlashni qayta yoqmaguningizcha, akkauntdan chiqmaguningizcha yoki Zenlygram hisobingizni oʻchirmaguningizcha saqlanadi.",
            ru: "Синхронизация выключена. Эта копия синхронизированных задач только для чтения; она хранится, пока вы снова не включите синхронизацию, не выйдете из аккаунта или не удалите аккаунт Zenlygram."
        )
    }

    // MARK: - Masʼul — the owner's assignment (§4)

    /// Owner row metadata line and owner editor value (state = one of tasks_assign_state_*).
    func tasks_assign_line(name: String, state: String) -> String {
        pick(
            en: "Assignee: \(name) · \(state)",
            uz: "Masʼul: \(name) · \(state)",
            ru: "Исполнитель: \(name) · \(state)"
        )
    }

    /// Owner state word: a queued/in-flight invitation.request not yet acknowledged.
    var tasks_assign_state_sending: String {
        pick(en: "Sending…", uz: "Yuborilmoqda…", ru: "Отправляется…")
    }

    /// Owner state word: a deferred assignment (server budget 429 with Retry-After > 120 s), re-sent
    /// automatically.
    var tasks_assign_state_queued: String {
        pick(en: "Queued", uz: "Navbatda", ru: "В очереди")
    }

    /// Owner state word: server state pending, not expired.
    var tasks_assign_state_sent: String {
        pick(en: "Sent", uz: "Yuborildi", ru: "Отправлено")
    }

    /// Owner state word: accepted, task open.
    var tasks_assign_state_accepted: String {
        pick(en: "Accepted", uz: "Qabul qildi", ru: "Принял(а)")
    }

    /// Owner state word: accepted, completed, completed_by == assignee (wire 5 only).
    var tasks_assign_state_done: String {
        pick(en: "Done", uz: "Bajardi", ru: "Выполнил(а)")
    }

    /// Owner state word: accepted, completed by the owner or unknown (wire 4).
    var tasks_assign_state_completed: String {
        pick(en: "Completed", uz: "Bajarildi", ru: "Выполнена")
    }

    /// Owner state word: declined -> action tasks_assign_resend.
    var tasks_assign_state_declined: String {
        pick(en: "Declined", uz: "Rad etdi", ru: "Отклонил(а)")
    }

    /// Owner state word: left -> action tasks_assign_resend.
    var tasks_assign_state_left: String {
        pick(en: "Left the task", uz: "Vazifadan chiqdi", ru: "Вышел(ла) из задачи")
    }

    /// Owner state word: pending past expires_at -> action tasks_assign_resend.
    var tasks_assign_state_expired: String {
        pick(en: "Not accepted in 7 days", uz: "7 kun ichida qabul qilinmadi", ru: "Не принято за 7 дней")
    }

    /// Owner state word: revoked by the owner (until the 3-day detach).
    var tasks_assign_state_removed: String {
        pick(en: "Removed", uz: "Olib tashlandi", ru: "Снят(а)")
    }

    /// Owner state word: legacy owner-only annotation without an assignment -> action
    /// tasks_assign_send.
    var tasks_assign_state_notSent: String {
        pick(en: "Not sent yet", uz: "Hali yuborilmagan", ru: "Ещё не отправлено")
    }

    /// Suffix of a device-row assignee (never sent) on the device board and in Eski vazifalar.
    var tasks_assign_oldEntry: String {
        pick(en: "(old entry)", uz: "(eski yozuv)", ru: "(старая запись)")
    }

    /// Owner editor action on declined / left / expired (new invitation.request, new epoch).
    var tasks_assign_resend: String {
        pick(en: "Send Again", uz: "Qayta yuborish", ru: "Отправить снова")
    }

    /// Owner editor action on a legacy annotation-only task.
    var tasks_assign_send: String {
        pick(en: "Send", uz: "Yuborish", ru: "Отправить")
    }

    /// Owner editor action when an assignee is live.
    var tasks_assign_change: String {
        pick(en: "Change Assignee", uz: "Masʼulni almashtirish", ru: "Сменить исполнителя")
    }

    /// Alert before re-picking while an assignee is pending/accepted (the only assign confirmation).
    var tasks_assign_replace_title: String {
        pick(en: "Replace the assignee?", uz: "Masʼul almashtirilsinmi?", ru: "Сменить исполнителя?")
    }

    /// Replace and remove alerts.
    func tasks_assign_replace_text(_ name: String) -> String {
        pick(
            en: "\(name) will no longer see this task.",
            uz: "\(name) bu vazifani boshqa koʻrmaydi.",
            ru: "\(name) больше не увидит эту задачу."
        )
    }

    /// Replace alert button.
    var tasks_assign_replace_confirm: String {
        pick(en: "Replace", uz: "Almashtirish", ru: "Сменить")
    }

    /// Remove alert title (tasks_assignee_remove is the row).
    var tasks_assign_remove_title: String {
        pick(en: "Remove the assignee?", uz: "Masʼul olib tashlansinmi?", ru: "Убрать исполнителя?")
    }

    /// Remove alert button.
    var tasks_assign_remove_confirm: String {
        pick(en: "Remove", uz: "Olib tashlash", ru: "Убрать")
    }

    /// Owner editor Masʼul section footer, server_wire >= 5.
    func tasks_assign_footer_accepted(_ name: String) -> String {
        pick(
            en: "\(name) sees this task in their Tasks and can mark it done, write a note and leave it. Only you change the title, notes, due date and priority, reassign or delete it.",
            uz: "\(name) bu vazifani oʻz Vazifalarida koʻradi, uni bajarildi deb belgilashi, izoh yozishi va undan chiqishi mumkin. Sarlavha, izohlar, muddat va ustuvorlikni faqat siz oʻzgartirasiz, boshqa masʼul tanlaysiz yoki oʻchirasiz.",
            ru: "\(name) видит задачу в своих «Задачах» и может отметить выполнение, написать заметку и выйти из неё. Название, заметки, срок и приоритет меняете, переназначаете и удаляете только вы."
        )
    }

    /// Same footer while server_wire < 5 (no izoh).
    func tasks_assign_footer_accepted_noNote(_ name: String) -> String {
        pick(
            en: "\(name) sees this task in their Tasks and can mark it done and leave it. Only you change the title, notes, due date and priority, reassign or delete it.",
            uz: "\(name) bu vazifani oʻz Vazifalarida koʻradi, uni bajarildi deb belgilashi va undan chiqishi mumkin. Sarlavha, izohlar, muddat va ustuvorlikni faqat siz oʻzgartirasiz, boshqa masʼul tanlaysiz yoki oʻchirasiz.",
            ru: "\(name) видит задачу в своих «Задачах» и может отметить выполнение и выйти из неё. Название, заметки, срок и приоритет меняете, переназначаете и удаляете только вы."
        )
    }

    /// Owner editor footer, state sent. The middle sentence is general (never about this person), so it
    /// is no oracle; it also covers a recipient who has no Zenlygram, no consent or sync off (revision
    /// 1).
    func tasks_assign_footer_pending(_ name: String) -> String {
        pick(
            en: "Waiting for \(name) to accept. The assignee sees the task once their Zenlygram sync is on; if they start within 7 days, it still reaches them. If it isn't accepted in that time, you can send it again.",
            uz: "\(name) qabul qilishi kutilmoqda. Masʼul vazifani Zenlygramda sinxronlash yoqilganda koʻradi; 7 kun ichida boshlasa ham, vazifa unga yetib boradi. Shu muddatda qabul qilinmasa, qayta yuborishingiz mumkin.",
            ru: "Ждём, когда \(name) примет задачу. Исполнитель увидит её, когда у него включена синхронизация в Zenlygram; если он начнёт в течение 7 дней, задача всё равно до него дойдёт. Если её не примут за это время, её можно отправить снова."
        )
    }

    /// Owner editor footer, state queued (deferred assignment).
    var tasks_assign_footer_queued: String {
        pick(
            en: "The daily assignment limit is reached. It is sent automatically later.",
            uz: "Kunlik topshirish chegarasi toʻldi. Vazifa keyinroq avtomatik yuboriladi.",
            ru: "Дневной лимит назначений исчерпан. Задача отправится позже автоматически."
        )
    }

    /// Owner editor footer, states declined / left / expired / removed.
    var tasks_assign_footer_ended: String {
        pick(
            en: "Nobody has this task now. Send it again or choose another assignee.",
            uz: "Bu vazifa hozir hech kimga topshirilmagan. Qayta yuboring yoki boshqa masʼul tanlang.",
            ru: "Сейчас задача никому не поручена. Отправьте снова или выберите другого исполнителя."
        )
    }

    /// Owner editor footer, legacy annotation-only task.
    func tasks_assign_footer_notSent(_ name: String) -> String {
        pick(
            en: "\(name) was saved as the assignee earlier, but the task hasn't been sent to them.",
            uz: "\(name) avval masʼul sifatida saqlangan, lekin vazifa unga yuborilmagan.",
            ru: "\(name) ранее сохранён(а) как исполнитель, но задача ему (ей) не отправлена."
        )
    }

    /// Owner editor footer when the task is completed (row disabled).
    var tasks_assign_footer_completedTask: String {
        pick(
            en: "A completed task can't be assigned. Reopen it first.",
            uz: "Bajarilgan vazifani topshirib boʻlmaydi. Avval uni qayta oching.",
            ru: "Выполненную задачу нельзя поручить. Сначала откройте её снова."
        )
    }

    /// One-time sheet per account before the first pick on the synced board (UserDefaults
    /// sgtasks.assignExplainer.<accountPeerId>).
    var tasks_assign_explainer_title: String {
        pick(en: "How assigning works", uz: "Masʼul tayinlash qanday ishlaydi", ru: "Как работает назначение")
    }

    /// Explainer body, server_wire >= 5. Never mentions the contact rule (no sender-side oracle).
    /// States that the assignee sees the owner's Telegram ID (as the retired R4 share confirmation did)
    /// and the general not-on-Zenlygram-yet sentence (revision 1).
    var tasks_assign_explainer_text: String {
        pick(
            en: "The task goes to the assignee's Tasks in Zenlygram, not as a Telegram message. They see the title, notes and due date, can mark it done, write a note and leave it. They also see your Telegram ID. Your lists and other tasks stay private. The assignee sees the task once their Zenlygram sync is on; if they start within 7 days, it still reaches them. You see their name and what they do with the task.",
            uz: "Vazifa masʼulga Telegram xabari sifatida emas, uning Zenlygram Vazifalariga tushadi. U sarlavha, izohlar va muddatni koʻradi, bajarildi deb belgilashi, izoh yozishi va vazifadan chiqishi mumkin. U sizning Telegram IDʼingizni ham koʻradi. Roʻyxatlaringiz va boshqa vazifalaringiz unga koʻrinmaydi. Masʼul vazifani Zenlygramda sinxronlash yoqilganda koʻradi; 7 kun ichida boshlasa, vazifa unga yetib boradi. Siz uning ismini va vazifa bilan nima qilganini koʻrasiz.",
            ru: "Задача попадает в «Задачи» Zenlygram исполнителя, а не приходит сообщением Telegram. Исполнитель видит название, заметки и срок, может отметить выполнение, написать заметку и выйти из задачи. Он(а) также видит ваш Telegram ID. Ваши списки и другие задачи остаются скрытыми. Исполнитель увидит задачу, когда у него включена синхронизация в Zenlygram; если он начнёт в течение 7 дней, задача до него дойдёт. Вы видите имя исполнителя и что он(а) делает с задачей."
        )
    }

    /// Explainer body while server_wire < 5 (same additions as tasks_assign_explainer_text, revision
    /// 1).
    var tasks_assign_explainer_text_noNote: String {
        pick(
            en: "The task goes to the assignee's Tasks in Zenlygram, not as a Telegram message. They see the title, notes and due date, can mark it done and leave it. They also see your Telegram ID. Your lists and other tasks stay private. The assignee sees the task once their Zenlygram sync is on; if they start within 7 days, it still reaches them. You see their name and what they do with the task.",
            uz: "Vazifa masʼulga Telegram xabari sifatida emas, uning Zenlygram Vazifalariga tushadi. U sarlavha, izohlar va muddatni koʻradi, bajarildi deb belgilashi va vazifadan chiqishi mumkin. U sizning Telegram IDʼingizni ham koʻradi. Roʻyxatlaringiz va boshqa vazifalaringiz unga koʻrinmaydi. Masʼul vazifani Zenlygramda sinxronlash yoqilganda koʻradi; 7 kun ichida boshlasa, vazifa unga yetib boradi. Siz uning ismini va vazifa bilan nima qilganini koʻrasiz.",
            ru: "Задача попадает в «Задачи» Zenlygram исполнителя, а не приходит сообщением Telegram. Исполнитель видит название, заметки и срок, может отметить выполнение и выйти из задачи. Он(а) также видит ваш Telegram ID. Ваши списки и другие задачи остаются скрытыми. Исполнитель увидит задачу, когда у него включена синхронизация в Zenlygram; если он начнёт в течение 7 дней, задача до него дойдёт. Вы видите имя исполнителя и что он(а) делает с задачей."
        )
    }

    /// Explainer and S9 notice dismiss button.
    var tasks_assign_explainer_ok: String {
        pick(en: "Got It", uz: "Tushunarli", ru: "Понятно")
    }

    /// Pick-time refusal toast.
    var tasks_assign_self: String {
        pick(
            en: "You can't assign a task to yourself.",
            uz: "Vazifani oʻzingizga topshirib boʻlmaydi.",
            ru: "Нельзя поручить задачу самому себе."
        )
    }

    /// Pick-time pacer refusal (recipient/UTC day).
    var tasks_assign_limitPerPerson: String {
        pick(
            en: "You can assign up to 5 tasks a day to one person. Try again tomorrow.",
            uz: "Bir kishiga kuniga 5 tagacha vazifa topshirish mumkin. Ertaga qayta urinib koʻring.",
            ru: "Одному человеку можно поручить до 5 задач в день. Попробуйте завтра."
        )
    }

    /// Pick-time pacer refusal (10/min).
    var tasks_assign_limitPerMinute: String {
        pick(
            en: "Too many assignments in a row. Try again in a minute.",
            uz: "Ketma-ket juda koʻp vazifa topshirildi. Bir daqiqadan soʻng qayta urinib koʻring.",
            ru: "Слишком много назначений подряд. Попробуйте через минуту."
        )
    }

    /// Pick-time pacer refusal (95/UTC day).
    var tasks_assign_limitTotal: String {
        pick(
            en: "Too many assignments today. Try again tomorrow.",
            uz: "Bugun juda koʻp vazifa topshirildi. Ertaga qayta urinib koʻring.",
            ru: "Слишком много назначений за сегодня. Попробуйте завтра."
        )
    }

    /// Pick-time pacer refusal (>= 95 pending).
    var tasks_assign_limitPending: String {
        pick(
            en: "Too many assignments are waiting for an answer. Try again when some are accepted or expire.",
            uz: "Javob kutayotgan topshiriqlar juda koʻp. Ulardan baʼzilari qabul qilingach yoki muddati tugagach qayta urinib koʻring.",
            ru: "Слишком много назначений ждут ответа. Повторите, когда часть из них будет принята или истечёт."
        )
    }

    /// Explainer sheet when the Masʼul pill/row is tapped on the device board (permission forbidden or
    /// waiting).
    var tasks_assign_needsSync_title: String {
        pick(
            en: "Sync is needed to assign",
            uz: "Masʼul tayinlash uchun sinxronlash kerak",
            ru: "Для назначения нужна синхронизация"
        )
    }

    /// Same sheet body.
    var tasks_assign_needsSync_text: String {
        pick(
            en: "So that the assignee sees the task in their Tasks, it is stored on the Zenlygram server. That needs your data consent and a linked account.",
            uz: "Masʼul vazifani oʻz Vazifalarida koʻrishi uchun u Zenlygram serverida saqlanadi. Buning uchun maʼlumotlar roziligi va bogʻlangan akkaunt kerak.",
            ru: "Чтобы исполнитель видел задачу в своих «Задачах», она хранится на сервере Zenlygram. Для этого нужны согласие на обработку данных и привязанный аккаунт."
        )
    }

    /// Sheet action (forbidden) -> Data & consent hook; under waiting the action is
    /// tasks_cloud_link_action.
    var tasks_assign_needsSync_action: String {
        pick(en: "Turn On Sync", uz: "Sinxronlashni yoqish", ru: "Включить синхронизацию")
    }

    /// Toast on the device board in state S5 (turningOn).
    var tasks_assign_waitForSync: String {
        pick(
            en: "Assigning becomes possible in a moment, once sync has started.",
            uz: "Sinxronlash boshlangach, birozdan soʻng masʼul tayinlash mumkin boʻladi.",
            ru: "Назначение станет доступно, как только начнётся синхронизация."
        )
    }

    /// Owner editor, read-only line under the assignee when assignment.note != nil (wire 5).
    var tasks_assign_noteHeader: String {
        pick(en: "Assignee's note", uz: "Masʼulning izohi", ru: "Заметка исполнителя")
    }

    // MARK: - Menga topshirilgan — the assignee's view (§5)

    /// Section header of the synced board before the assignee rows (only when >= 1); a11y id
    /// sgtasks.assigned.header.
    var tasks_assigned_header: String {
        pick(en: "Assigned to Me", uz: "Menga topshirilgan", ru: "Поручено мне")
    }

    /// Assignee row subtitle and assignee editor header. name = local contact name, else
    /// tasks_cloud_telegramUser(id).
    func tasks_assigned_by(_ name: String) -> String {
        pick(en: "Assigned by \(name)", uz: "Topshirdi: \(name)", ru: "Поручил(а): \(name)")
    }

    /// Assignee editor nav title.
    var tasks_assigned_editorTitle: String {
        pick(en: "Assigned Task", uz: "Topshirilgan vazifa", ru: "Порученная задача")
    }

    /// Assignee editor rights line, server_wire >= 5.
    var tasks_assigned_rights: String {
        pick(
            en: "You can mark it done or not done, write a note and leave the task. Only the person who assigned it changes, reassigns or deletes it.",
            uz: "Siz uni bajarildi/bajarilmadi deb belgilashingiz, izoh yozishingiz va vazifadan chiqishingiz mumkin. Oʻzgartirish, boshqa masʼul tanlash va oʻchirish faqat topshirgan odamda.",
            ru: "Вы можете отмечать выполнение, написать заметку и выйти из задачи. Изменять, переназначать и удалять её может только тот, кто её поручил."
        )
    }

    /// Same while server_wire < 5.
    var tasks_assigned_rights_noNote: String {
        pick(
            en: "You can mark it done or not done and leave the task. Only the person who assigned it changes, reassigns or deletes it.",
            uz: "Siz uni bajarildi/bajarilmadi deb belgilashingiz va vazifadan chiqishingiz mumkin. Oʻzgartirish, boshqa masʼul tanlash va oʻchirish faqat topshirgan odamda.",
            ru: "Вы можете отмечать выполнение и выйти из задачи. Изменять, переназначать и удалять её может только тот, кто её поручил."
        )
    }

    /// Assignee editor section (wire 5 only).
    var tasks_note_header: String {
        pick(en: "My Note", uz: "Izohim", ru: "Моя заметка")
    }

    /// Assignee note field placeholder.
    var tasks_note_placeholder: String {
        pick(
            en: "A note for the person who assigned it",
            uz: "Topshirgan odam uchun izoh",
            ru: "Заметка для того, кто поручил"
        )
    }

    /// Assignee note footer (revision 2: covers task deletion, leave, removal, reassignment and the
    /// prune of the ended invitation, so it never promises less than happens).
    var tasks_note_footer: String {
        pick(
            en: "The person who assigned the task sees this note. It is deleted when the task is deleted or is no longer assigned to you.",
            uz: "Bu izohni vazifani topshirgan odam koʻradi. Vazifa oʻchirilsa yoki endi sizga topshirilmagan boʻlsa, izoh ham oʻchadi.",
            ru: "Эту заметку видит тот, кто поручил задачу. Она удаляется, когда задачу удаляют или она больше не поручена вам."
        )
    }

    /// Assignee note action (empty text clears the note).
    var tasks_note_save: String {
        pick(en: "Save Note", uz: "Izohni saqlash", ru: "Сохранить заметку")
    }

    /// Assignee note validation.
    var tasks_note_tooLong: String {
        pick(
            en: "The note is too long. Use up to 1024 characters.",
            uz: "Izoh juda uzun. Koʻpi bilan 1024 ta belgi kiriting.",
            ru: "Заметка слишком длинная. Не более 1024 символов."
        )
    }

    /// Top line of Takliflar (recipient-side only; never shown to the sender).
    var tasks_invitations_hint: String {
        pick(
            en: "Tasks from people in your Telegram contacts are accepted automatically. Others wait here for your answer.",
            uz: "Telegram kontaktlaringizdagi odamlardan kelgan vazifalar avtomatik qabul qilinadi. Boshqalar shu yerda javobingizni kutadi.",
            ru: "Задачи от людей из ваших контактов Telegram принимаются автоматически. Остальные ждут здесь вашего ответа."
        )
    }

    /// Same while server_wire < 5.
    var tasks_cloud_invitations_access_after_noNote: String {
        pick(
            en: "You also see the notes, can mark the task done or not done and leave at any time. Only the sender changes, reassigns or deletes it. This access doesn't expire.",
            uz: "Izohlarni ham koʻrasiz, vazifani bajarildi/bajarilmadi deb belgilashingiz va istalgan vaqtda chiqishingiz mumkin. Oʻzgartirish, boshqa masʼul tanlash va oʻchirish faqat yuboruvchida. Bu kirish huquqi muddatsiz.",
            ru: "Видны и заметки; можно отмечать выполнение и выйти в любой момент. Изменяет, переназначает и удаляет только отправитель. Этот доступ бессрочный."
        )
    }

    // MARK: - Eski (qurilmadagi) masʼullar — the D4 sheet (§7)

    /// D4 sheet title (a11y id sgtasks.legacy.sheet).
    func tasks_legacySheet_title(_ count: Int) -> String {
        pick(
            en: "Tasks with an assignee: \(count)",
            uz: "\(count) ta vazifada masʼul bor",
            ru: "Задач с исполнителем: \(count)"
        )
    }

    /// D4 sheet body.
    var tasks_legacySheet_text: String {
        pick(
            en: "Send these tasks to them? Each person gets the task in their Zenlygram Tasks and sees your Telegram ID; only their Telegram ID is sent, never their name. Nothing is sent until you tap Send.",
            uz: "Ularga yuborilsinmi? Har bir kishi vazifani oʻz Zenlygram Vazifalarida oladi va sizning Telegram IDʼingizni koʻradi; ularning faqat Telegram IDʼsi yuboriladi, ismi hech qachon yuborilmaydi. «Yuborish»ni bosmaguningizcha hech narsa yuborilmaydi.",
            ru: "Отправить им эти задачи? Каждый получит задачу в своих «Задачах» Zenlygram и увидит ваш Telegram ID; отправляется только его Telegram ID, никогда не имя. Ничего не отправится, пока вы не нажмёте «Отправить»."
        )
    }

    /// One row per candidate task (every person by name, bidi-isolated).
    func tasks_legacySheet_row(title: String, name: String) -> String {
        pick(en: "\(title) → \(name)", uz: "\(title) → \(name)", ru: "\(title) → \(name)")
    }

    /// Greyed row suffix (unconvertible id).
    var tasks_legacySheet_notSendable: String {
        pick(en: "can't be sent", uz: "yuborib boʻlmaydi", ru: "нельзя отправить")
    }

    /// Greyed row suffix (the assignee is the account itself).
    var tasks_legacySheet_self: String {
        pick(en: "you — not sent", uz: "oʻzingiz — yuborilmaydi", ru: "вы — не отправляется")
    }

    /// Shown only when the pacer caps the send.
    func tasks_legacySheet_paced(now: Int, later: Int) -> String {
        pick(
            en: "\(now) can be sent today; send the other \(later) later from each task (up to 5 a day per person).",
            uz: "Bugun \(now) tasi yuboriladi; qolgan \(later) tasini keyinroq har bir vazifaning oʻzidan yuborasiz (bir kishiga kuniga 5 tagacha).",
            ru: "Сегодня отправится \(now); остальные (\(later)) отправьте позже из самих задач (до 5 в день одному человеку)."
        )
    }

    /// D4 primary button (a11y id sgtasks.legacy.send).
    var tasks_legacySheet_send: String {
        pick(en: "Send", uz: "Yuborish", ru: "Отправить")
    }

    /// D4 secondary button (a11y id sgtasks.legacy.later).
    var tasks_legacySheet_later: String {
        pick(en: "Later", uz: "Keyinroq", ru: "Позже")
    }

    /// Toast after Keyinroq.
    var tasks_legacySheet_laterHint: String {
        pick(
            en: "Nothing was sent. You can send each one later from the task, or from Lists › Unsent Assignees.",
            uz: "Hech narsa yuborilmadi. Har birini keyinroq vazifaning oʻzidan yoki Roʻyxatlar › Yuborilmagan masʼullar boʻlimidan yuborishingiz mumkin.",
            ru: "Ничего не отправлено. Каждую можно отправить позже из самой задачи или из «Списки › Неотправленные исполнители»."
        )
    }

    /// Lists entry that reopens the sheet while candidates remain (after Keyinroq or a paced send).
    func tasks_legacySheet_listsEntry(_ count: Int) -> String {
        pick(
            en: "Unsent Assignees (\(count))",
            uz: "Yuborilmagan masʼullar (\(count))",
            ru: "Неотправленные исполнители (\(count))"
        )
    }

    /// Toast after Yuborish.
    func tasks_legacySheet_sentToast(_ count: Int) -> String {
        pick(
            en: "Sending to assignees: \(count)",
            uz: "\(count) ta vazifa masʼullariga yuborilmoqda",
            ru: "Отправляется исполнителям: \(count)"
        )
    }

    // MARK: - Logout

    /// Logout confirmation paragraph (SGTasksLogoutNotice, WP-I6) when
    /// sgtasks.legacyAssignees.remaining.<accountPeerId> > 0 (device-row D4 candidates still unsent).
    /// Worded so it is true for a last and a non-last logout; no last-account flag at the call sites
    /// (revision 1).
    func tasks_logout_unsentAssignees(_ count: Int) -> String {
        pick(
            en: "Assignees not sent yet: \(count). If you log out and no other account stays signed in here, they are lost; the tasks themselves stay on the server.",
            uz: "\(count) ta vazifaning masʼuli hali yuborilmagan. Chiqsangiz va bu yerda boshqa akkaunt qolmasa, ular yoʻqoladi; vazifalarning oʻzi serverda qoladi.",
            ru: "Неотправленных исполнителей: \(count). Если выйти и здесь не останется других аккаунтов, они будут потеряны; сами задачи останутся на сервере."
        )
    }
}
