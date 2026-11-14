import UIKit

private func sgAIAssistantTopViewController() -> UIViewController? {
    var chosenWindow: UIWindow?
    for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else {
            continue
        }
        for window in windowScene.windows {
            if window.isKeyWindow {
                chosenWindow = window
            } else if chosenWindow == nil {
                chosenWindow = window
            }
        }
    }
    var top: UIViewController? = chosenWindow?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}

// Presents a secure UIAlertController text field to enter/update/clear the
// Anthropic API key. Callable from both the settings disclosure row and the
// context-menu submenu. Defaults are English; pass localized strings from the
// call site (i18n) to localize. A failed Keychain write is surfaced as a
// follow-up error alert instead of being silently dropped.
public func presentAIAssistantApiKeyEntry(title: String = "Anthropic API Key", message: String = "Stored only in this device's Keychain and sent directly to api.anthropic.com.", saveTitle: String = "Save", clearTitle: String = "Clear", cancelTitle: String = "Cancel", errorTitle: String = "Keychain Error", saveErrorText: String = "Could not save the API key to this device's Keychain. Please try again.", clearErrorText: String = "Could not remove the API key from this device's Keychain. Please try again.", okTitle: String = "OK") {
    guard let presenter: UIViewController = sgAIAssistantTopViewController() else {
        return
    }
    let presentKeychainError: (String, OSStatus) -> Void = { text, status in
        // The entry alert is still animating out while its action handler runs;
        // wait for that dismissal to settle, then re-resolve the top controller
        // before presenting the error alert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard var errorPresenter: UIViewController = sgAIAssistantTopViewController() else {
                return
            }
            while errorPresenter.isBeingDismissed, let presenting = errorPresenter.presentingViewController {
                errorPresenter = presenting
            }
            let errorAlert = UIAlertController(title: errorTitle, message: "\(text) (\(status))", preferredStyle: .alert)
            errorAlert.addAction(UIAlertAction(title: okTitle, style: .cancel, handler: nil))
            errorPresenter.present(errorAlert, animated: true, completion: nil)
        }
    }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addTextField { textField in
        textField.placeholder = "sk-ant-..."
        textField.isSecureTextEntry = true
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.text = SGAIAssistantKeychain.apiKey()
    }
    alert.addAction(UIAlertAction(title: saveTitle, style: .default, handler: { [weak alert] _ in
        if case let .failure(.unexpectedStatus(status)) = SGAIAssistantKeychain.setApiKey(alert?.textFields?.first?.text) {
            presentKeychainError(saveErrorText, status)
        }
    }))
    alert.addAction(UIAlertAction(title: clearTitle, style: .destructive, handler: { _ in
        if case let .failure(.unexpectedStatus(status)) = SGAIAssistantKeychain.setApiKey(nil) {
            presentKeychainError(clearErrorText, status)
        }
    }))
    alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel, handler: nil))
    presenter.present(alert, animated: true, completion: nil)
}
