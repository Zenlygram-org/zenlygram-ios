import Foundation

// check-strings self-test fixture (wf15 §15.4, outcome 1 — MUST PASS).
//
// The real `settings_interface_unlimitedPins_subtitle` declaration of SGTasksL10n.swift (copied
// verbatim) says "shu qurilmada" / "on this device" / "на этом устройстве" about pinned chats. It is
// not a Tasks declaration, so the gate must not count it: a declaration runs from its `var|func`
// line to the next `var|func` declaration, and only `tasks_*` / `tab_tasks` declarations are
// scanned. It sits between two clean Tasks declarations so that the scanner must end the first one
// before the neighbour and start the second one after it.

public struct SGTasksL10n {
    private let langCode: String

    func pick(en: String, uz: String, ru: String) -> String {
        switch langCode {
        case "uz": return uz
        case "ru": return ru
        default:   return en
        }
    }

    public var tasks_selftest_before: String {
        pick(en: "Sync is off", uz: "Sinxronlash oʻchiq", ru: "Синхронизация выключена")
    }
    public var settings_interface_unlimitedPins_subtitle: String {
        pick(en: "Pin more than 5 chats — extra pins stay on this device", uz: "5 tadan ortiq chatni pin qilish — ortiqchasi shu qurilmada saqlanadi", ru: "Закрепляйте больше 5 чатов — сверх лимита остаются на этом устройстве")
    }
    public var tasks_selftest_after: String {
        pick(en: "Opens Data & consent in Settings.", uz: "Sozlamalardagi «Maʼlumotlar va rozilik» boʻlimini ochadi.", ru: "Открывает «Данные и согласие» в настройках.")
    }
}
