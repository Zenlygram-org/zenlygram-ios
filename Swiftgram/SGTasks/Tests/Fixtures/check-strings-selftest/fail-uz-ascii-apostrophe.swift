import Foundation

// check-strings self-test fixture (wf15 §15.4, outcome 3 — MUST FAIL): a `tasks_*` declaration
// whose uz value has an ASCII apostrophe between letters ("Ro'yxat" instead of "Roʻyxat").

public extension SGTasksL10n {
    var tasks_selftest_asciiApostrophe: String {
        pick(en: "Lists", uz: "Ro'yxatlar", ru: "Списки")
    }
}
