import Foundation
import UIKit
import SwiftUI
import Display
import LegacyUI
import TelegramPresentationData
import SGSwiftUI
import SGCustomerSyncCore

/// Zenlygram — the data-consent wall of one account (design 40 §5.1): a global overlay of the account's own root
/// `NavigationController`, hosting the SwiftUI wall (`SGConsentWallRoot`) the way `LegacySwiftUIController` hosts its
/// views (that class is final, so this is a `LegacyController` of its own).
///
/// - Opaque and full screen: what blocks the app is this view, not `blockInteraction` (global overlays ignore it).
///   VoiceOver stays inside it (the opaque-overlay flags hide what is under it; `accessibilityViewIsModal`).
/// - It cannot be dismissed by anything but its presenter: `dismiss(completion:)` and `dismiss(animated:completion:)`
///   are ignored unless `dismissForPresenter(token:)` armed them with the presenter's token. That defeats the generic
///   "dismiss every global overlay" paths (`tg://sharestory?session=…`, `OpenResolvedUrl`); a container removed
///   anyway is presented again by the presenter (`rootOverlaysChanged`).
/// - The wall's own pages (decline, rights, My data, deletion) live inside it, so nothing of the app is presented
///   above it; alerts go to the window.
/// - The account root's safe insets reach the SwiftUI content through the model (the hosting view ignores the
///   safe area, as `SGSwiftUIView` content does).
final class SGConsentWallController: LegacyController {
    let model: SGConsentWallViewModel
    private let token: UUID
    private var isDismissalArmed = false

    init(model: SGConsentWallViewModel, token: UUID, presentationData: PresentationData) {
        self.model = model
        self.token = token
        super.init(presentation: .custom, theme: presentationData.theme, strings: presentationData.strings)
        self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
        // Opaque: the account root hides the accessibility elements of everything under a global overlay that says
        // so (both iPad columns included), so VoiceOver cannot reach the app behind the wall.
        self.isOpaqueWhenInOverlay = true
        self.blocksBackgroundWhenInOverlay = true

        let hosting = UIHostingController(rootView: SGConsentWallRoot(model: model), ignoreSafeArea: true)
        hosting.overrideUserInterfaceStyle = presentationData.theme.overallDarkAppearance ? .dark : .light
        hosting.view.backgroundColor = UIColor.systemGroupedBackground
        hosting.view.accessibilityViewIsModal = true
        self.bind(controller: hosting)
    }

    @available(*, unavailable)
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func bind(controller: UIViewController) {
        super.bind(controller: controller)
        self.addChild(controller)
        controller.didMove(toParent: self)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let insets = EdgeInsets(
            top: max(layout.safeInsets.top, layout.statusBarHeight ?? 0.0),
            leading: layout.safeInsets.left,
            bottom: max(layout.safeInsets.bottom, layout.intrinsicInsets.bottom),
            trailing: layout.safeInsets.right
        )
        if self.model.insets != insets {
            self.model.insets = insets
        }
        // No keyboard stays up over the wall. The wall has no text input of its own, so a keyboard that is up belongs
        // to a field of the app behind it. Before iOS 27 the wall was drawn over that keyboard; on iOS 27 the system
        // draws the keyboard outside the app, above every app window, where it would cover the wall's buttons and
        // keep feeding the field behind the wall. Asynchronous: resigning inside a layout pass would start another.
        if let inputHeight = layout.inputHeight, inputHeight > 0.0 {
            DispatchQueue.main.async {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }

    /// Ignored unless the presenter armed it (see the type's comment).
    override func dismiss(completion: (() -> Void)? = nil) {
        guard self.isDismissalArmed else {
            return
        }
        super.dismiss(completion: completion)
    }

    /// Ignored unless the presenter armed it (see the type's comment).
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard self.isDismissalArmed else {
            return
        }
        super.dismiss(animated: flag, completion: completion)
    }

    /// The only way the wall is taken down: by its presenter, with the token it was presented with.
    func dismissForPresenter(token: UUID) {
        guard token == self.token, !self.isDismissalArmed else {
            return
        }
        self.isDismissalArmed = true
        super.dismiss(completion: nil)
    }
}
