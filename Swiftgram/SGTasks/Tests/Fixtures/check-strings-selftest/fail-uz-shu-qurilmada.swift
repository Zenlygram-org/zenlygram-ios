import Foundation

// check-strings self-test fixture (wf15 §15.4, outcome 2 — MUST FAIL): a `tasks_*` declaration
// whose uz value contains the banned phrase "shu qurilmada".

public extension SGTasksL10n {
    var tasks_selftest_bannedPhrase: String {
        pick(
            en: "Your changes are saved and wait to be sent.",
            uz: "Oʻzgarishlaringiz shu qurilmada saqlangan va yuborilishini kutmoqda.",
            ru: "Изменения сохранены и ждут отправки."
        )
    }
}
