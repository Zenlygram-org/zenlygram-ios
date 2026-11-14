import SGSimpleSettings
import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramCore
import SwiftSignalKit
import AccountContext
import SwiftUI
import TelegramUIPreferences

public func presentTranslateScreen(
    context: AccountContext,
    text: String,
    entities: [MessageTextEntity] = [],
    canCopy: Bool,
    fromLanguage: String?,
    toLanguage: String? = nil,
    isExpanded: Bool = false,
    ignoredLanguages: [String]? = nil,
    replaceText: ((String, [MessageTextEntity]) -> Void)? = nil,
    translateChat: ((String, String) -> Void)? = nil,
    pushController: @escaping (ViewController) -> Void = { _ in },
    presentController: @escaping (ViewController) -> Void = { _ in },
    wasDismissed: (() -> Void)? = nil,
    display: (ViewController) -> Void
) {
    let translationConfiguration = TranslationConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
    var useSystemTranslation = SGSimpleSettings.shared.translationBackendEnum == .system
    switch translationConfiguration.manual {
    case .system:
        if #available(iOS 18.0, *) {
            useSystemTranslation = true
        }
    default:
        break
    }
    
    if useSystemTranslation {
        presentSystemTranslateScreen(context: context, text: text, replaceText: replaceText) // Zenlygram — #60: keep Replace in Apple's sheet
    } else {
    }
}

private func presentSystemTranslateScreen(context: AccountContext, text: String, replaceText: ((String, [MessageTextEntity]) -> Void)? = nil) {
    if #available(iOS 18.0, *), let rootViewController = context.sharedContext.mainWindow?.viewController?.view.window?.rootViewController {
        var dismissImpl: (() -> Void)?
        let pickerView = TranslateScreenHostingView(text: text, replacementAction: replaceText.map { replaceText in { translated in replaceText(translated, []) } }, completionHandler: { [weak rootViewController] in
            DispatchQueue.main.async(execute: {
                guard let presentedController = rootViewController?.presentedViewController, presentedController.isBeingDismissed == false else { return }
                dismissImpl?()
            })
        })
        let hostingController = UIHostingController(rootView: pickerView)
        hostingController.view.isHidden = true
        hostingController.modalPresentationStyle = .overCurrentContext
        rootViewController.present(hostingController, animated: true)
        dismissImpl = { [weak hostingController] in
            Queue.mainQueue().after(0.4, {
                hostingController?.dismiss(animated: false)
            })
        }
    }
}

@available(iOS 18.0, *)
struct TranslateScreenHostingView: View {
    @State var presented = true
    var text: String
    // Zenlygram — #60: Apple's "Replace with Translation" for input-field text.
    var replacementAction: ((String) -> Void)?
    var handler: () -> Void
    
    init(text: String, replacementAction: ((String) -> Void)? = nil, completionHandler: @escaping () -> Void) {
        self.text = text
        self.replacementAction = replacementAction
        self.handler = completionHandler
    }
    
    var body: some View {
        Spacer()
            .translationPresentation(
                isPresented: $presented,
                text: text,
                replacementAction: replacementAction
            )
            .onChange(of: presented) { newValue in
                if newValue == false {
                    handler()
                }
            }
    }
}
