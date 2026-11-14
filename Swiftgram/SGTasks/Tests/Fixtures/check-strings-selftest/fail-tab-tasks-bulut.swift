import Foundation

// check-strings self-test fixture (wf15 §15.4, outcome 4 — MUST FAIL): the `tab_tasks` declaration
// (the one gated declaration whose name does not start with `tasks_`) with the banned word "Bulut".

public struct SGTasksL10n {
    private let langCode: String

    func pick(en: String, uz: String, ru: String) -> String {
        switch langCode {
        case "uz": return uz
        case "ru": return ru
        default:   return en
        }
    }

    public var tab_tasks: String {
        pick(en: "Tasks", uz: "Bulut", ru: "Задачи")
    }
}
