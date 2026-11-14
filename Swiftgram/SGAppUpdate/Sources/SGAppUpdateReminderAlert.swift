import Foundation
import UIKit
import Display
import TelegramPresentationData
import SGEntitlement
import SGStrings

/// Zenlygram — the one "Update available" alert (update_policy_spec §4g): Telegram's standard text
/// alert with "Later" and "Update", which reports the moment it is actually on screen
/// (`viewDidAppear`), so the reminder marker (`zg.app.policy.reminded@<origin>`) is written for an
/// alert that was shown and never for one that was only asked for.
final class SGAppUpdateReminderAlertController: AlertController {
    /// Called once, when the alert appeared.
    var onShown: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let shown = self.onShown
        self.onShown = nil
        shown?()
    }

    /// "Zenlygram <latest> is available in the App Store." — Later (dismisses), Update (`update`,
    /// then dismisses). The same shape as `standardTextAlertController` builds.
    static func make(presentation: SGAppUpdatePresentation, latest: SGAppUpdateVersion, update: @escaping () -> Void) -> SGAppUpdateReminderAlertController {
        let theme = AlertControllerTheme(presentationTheme: presentation.theme, fontSize: presentation.fontSize)
        let lang = presentation.lang
        var dismissImpl: (() -> Void)?
        let actions = [
            TextAlertAction(type: .genericAction, title: "AppUpdate.Available.Later".i18n(lang), action: {
                dismissImpl?()
            }),
            TextAlertAction(type: .defaultAction, title: "AppUpdate.Available.Update".i18n(lang), action: {
                dismissImpl?()
                update()
            }),
        ]
        let title = NSAttributedString(string: "AppUpdate.Available.Title".i18n(lang), font: Font.semibold(theme.baseFontSize), textColor: theme.primaryColor, paragraphAlignment: .center)
        let text = NSAttributedString(string: "AppUpdate.Available.Text".i18n(lang, args: latest.text), font: Font.regular(floor(theme.baseFontSize * 13.0 / 17.0)), textColor: theme.primaryColor, paragraphAlignment: .center)
        let content = TextAlertContentNode(theme: theme, title: title, text: text, actions: actions, actionLayout: .horizontal, dismissOnOutsideTap: true)
        let controller = SGAppUpdateReminderAlertController(theme: theme, contentNode: content)
        dismissImpl = { [weak controller] in
            controller?.dismissAnimated()
        }
        return controller
    }
}
