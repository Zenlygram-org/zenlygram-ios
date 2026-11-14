import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import ComponentFlow
import AlertComponent
import AlertInputFieldComponent

// SG: Tasks — audit #36
//
// Free-text single-line input alert for the Tasks feature.
//
// The Tasks screens used to reuse `quickReplyNameAlertController`, which is built for
// Quick Reply *shortcut names*: its `shouldChangeText` rejects every scalar that is not a
// letter or a digit (so spaces, apostrophes and punctuation could not be typed — "Buy milk"
// and "o'qish" were impossible), it forces `keyboardType: .URL` with no autocapitalisation,
// it shows the `QuickReply_ShortcutPlaceholder` placeholder, and its Done action passes
// `autoDismiss: false` on the assumption that the caller validates the shortcut and dismisses
// the alert itself — which the Tasks callers never did, so Done left the alert open and every
// extra tap created another folder/task.
//
// This controller is the plain-text counterpart: a *length-only* `shouldChangeText` filter
// (nothing is rejected by character class), the normal sentence keyboard, a localized
// placeholder, and the default `autoDismiss: true` so Done closes the alert. `didApply`
// additionally guards against a fast double tap creating two rows before the dismissal
// animation completes.
public func sgTaskNameAlertController(
    context: AccountContext,
    title: String,
    text: String,
    placeholder: String,
    value: String?,
    characterLimit: Int,
    apply: @escaping (String) -> Void
) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings

    let inputState = AlertInputFieldComponent.ExternalState()

    // Done is only enabled once the name has visible characters (same pattern as upstream
    // WebBrowserDomainController), so it can never close the alert without creating anything.
    let doneIsEnabled: Signal<Bool, NoError> = inputState.valueSignal
    |> map { value in
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var applyImpl: (() -> Void)?

    var content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = []
    content.append(AnyComponentWithIdentity(
        id: "title",
        component: AnyComponent(
            AlertTitleComponent(title: title)
        )
    ))
    content.append(AnyComponentWithIdentity(
        id: "text",
        component: AnyComponent(
            AlertTextComponent(content: .plain(text))
        )
    ))
    content.append(AnyComponentWithIdentity(
        id: "input",
        component: AnyComponent(
            AlertInputFieldComponent(
                context: context,
                initialValue: value,
                placeholder: placeholder,
                characterLimit: characterLimit,
                hasClearButton: true,
                keyboardType: .default,
                autocapitalizationType: .sentences,
                autocorrectionType: .default,
                isInitiallyFocused: true,
                externalState: inputState,
                // Length-only filter: every character the user can type is a valid
                // folder/task name, so nothing is rejected by character class; the edit is
                // refused only once the resulting text would exceed `characterLimit`.
                // `AlertInputFieldComponent` stores `characterLimit` but never reads it, so
                // this delegate hook is the only thing that actually caps the field.
                shouldChangeText: { $0.count <= characterLimit },
                returnKeyAction: {
                    applyImpl?()
                }
            )
        )
    ))

    let alertController = AlertScreen(
        configuration: AlertScreen.Configuration(allowInputInset: true),
        content: content,
        actions: [
            .init(title: strings.Common_Cancel),
            // autoDismiss is left at its default `true` so Done closes the alert.
            .init(title: strings.Common_Done, type: .default, action: {
                applyImpl?()
            }, isEnabled: doneIsEnabled)
        ],
        updatedPresentationData: (presentationData, context.sharedContext.presentationData)
    )

    var didApply = false
    applyImpl = { [weak alertController] in
        // Both the Done button and the keyboard return key route here; a double tap while the
        // alert dismisses must not create the row twice.
        if didApply {
            return
        }
        let trimmed = inputState.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return
        }
        didApply = true
        // Belt and braces: the filter above only sees edits that go through the text-field
        // delegate, so a programmatic or dictation-inserted value can still be over the limit.
        // Trim first, then clamp, so a long run of trailing whitespace cannot eat the budget.
        apply(String(trimmed.prefix(characterLimit)))
        // The Done action dismisses on its own (autoDismiss), but the keyboard return key does
        // not — dismiss here so both paths close the alert. `AlertScreen.dismiss` is idempotent.
        alertController?.dismiss(completion: nil)
    }

    return alertController
}
