import Foundation
import UIKit
import SwiftUI
import Display
import LegacyUI
import TelegramPresentationData
import SGSwiftUI

/// Zenlygram — the "Update required" block (update_policy_spec §4f): a global overlay of the main
/// window's root `NavigationController`, hosting the SwiftUI screen (`SGAppUpdateBlockRoot`) the way
/// `SGConsentWallController` hosts the consent wall (`LegacySwiftUIController` is final, so this is
/// a `LegacyController` of its own).
///
/// - Opaque and full screen: what blocks the app is this view, not `blockInteraction` (global
///   overlays ignore it). VoiceOver stays inside it (the opaque-overlay flags hide what is under it;
///   `accessibilityViewIsModal`).
/// - It cannot be dismissed by anything but its presenter: `dismiss(completion:)` and
///   `dismiss(animated:completion:)` are ignored unless `dismissForPresenter(token:)` armed them with
///   the presenter's token — the generic "dismiss every global overlay" paths (`tg://sharestory?
///   session=…`, `OpenResolvedUrl`) take nothing down. A container removed anyway is presented again
///   by the presenter (`rootOverlaysChanged`).
/// - Nothing of the app is presented above it: the store and Help leave the app; a call screen is
///   placed above it by `SGCallScreenPlacement`.
/// - The root's safe insets reach the SwiftUI content through the model (the hosting view ignores the
///   safe area, as `SGSwiftUIView` content does).
final class SGAppUpdateBlockController: LegacyController {
    let model: SGAppUpdateBlockViewModel
    private let token: UUID
    private var isDismissalArmed = false

    init(model: SGAppUpdateBlockViewModel, token: UUID, theme: PresentationTheme) {
        self.model = model
        self.token = token
        super.init(presentation: .custom, theme: theme, strings: nil)
        self.statusBar.statusBarStyle = theme.rootController.statusBarStyle.style
        // Opaque: the root hides the accessibility elements of everything under a global overlay that
        // says so (both iPad columns included), so VoiceOver cannot reach the app behind the block.
        self.isOpaqueWhenInOverlay = true
        self.blocksBackgroundWhenInOverlay = true

        let hosting = UIHostingController(rootView: SGAppUpdateBlockRoot(model: model), ignoreSafeArea: true)
        hosting.overrideUserInterfaceStyle = theme.overallDarkAppearance ? .dark : .light
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
        // No keyboard stays up over the block (it has no text input of its own): on iOS 27 the system draws the
        // keyboard outside the app, above every app window, where it would cover the block's buttons and keep feeding
        // the field behind it. Asynchronous: resigning inside a layout pass would start another. Same rule as the
        // data-consent wall (SGConsentWallController).
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

    /// The only way the block is taken down: by its presenter, with the token it was presented with.
    func dismissForPresenter(token: UUID) {
        guard token == self.token, !self.isDismissalArmed else {
            return
        }
        self.isDismissalArmed = true
        super.dismiss(completion: nil)
    }
}
