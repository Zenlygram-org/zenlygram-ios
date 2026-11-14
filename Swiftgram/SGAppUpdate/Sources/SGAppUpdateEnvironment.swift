import Foundation
import UIKit
import Display
import TelegramPresentationData
import TelegramUIPreferences

/// Zenlygram — which root of the main window a block is attached to (update_policy_spec §4e–f). The
/// decision is the install's, so both roots show the block; the reminder is offered on the authorized
/// root only (§4g).
public enum SGAppUpdateRootKind: Equatable {
    /// `AuthorizedApplicationContext.rootController` (the chat list), attached by its `init`.
    case authorized
    /// `UnauthorizedApplicationContext.rootController` (the login), attached by AppDelegate right
    /// before it is presented.
    case unauthorized
}

/// The theme, text size and language the block and the reminder are drawn with: `PresentationData`'s
/// pieces, so the presenter (and its tests) never need a whole `PresentationData` —
/// `defaultPresentationData()` wants the app's own string tables, which a logic test does not have.
public struct SGAppUpdatePresentation {
    public var theme: PresentationTheme
    public var fontSize: PresentationFontSize
    /// `presentationData.strings.baseLanguageCode`: the in-app language the captions are read in.
    public var lang: String

    public init(theme: PresentationTheme, fontSize: PresentationFontSize, lang: String) {
        self.theme = theme
        self.fontSize = fontSize
        self.lang = lang
    }
}

/// What the presenter needs from the app (§4f–g), installed once by AppDelegate
/// (`SGAppUpdate.configure(environment:)`) as soon as the build configuration is known — before any
/// root exists, so the first frame already knows the QA override and the TestFlight variant. Every
/// closure is resolved when it is called, never when it is installed: the shared context is created
/// after the environment is.
public struct SGAppUpdateEnvironment {
    /// `BuildConfig.isAppStoreBuild`: a store build never reads the QA override (§4h) — the belt under
    /// the compile-time exclusion (`SG_APP_UPDATE_DEBUG_OVERRIDE`).
    public var isAppStoreBuild: Bool
    /// `Bundle.main.appStoreReceiptURL` ends in `sandboxReceipt` (`SGDeviceInfo.distribution`'s rule):
    /// a TestFlight build offers "Open TestFlight".
    public var isSandboxReceipt: Bool
    public var presentation: () -> SGAppUpdatePresentation
    /// `applicationBindings.openAppStorePage`: `itms-apps://…/id<appstore_id>`, the build's App Store id.
    public var openAppStorePage: () -> Void
    /// TestFlight's page of this app (`itms-beta://…`); the completion says whether something opened
    /// it — `false` (no TestFlight on the device) makes the presenter open the App Store instead.
    /// `UIApplication.open`'s own answer: no `canOpenURL`, so no `LSApplicationQueriesSchemes` entry.
    public var openTestFlightPage: (@escaping (Bool) -> Void) -> Void
    /// The Help link (`applicationBindings.openUrl`).
    public var openURL: (URL) -> Void
    /// `callManager.hasActiveCall`: no reminder during a call; a block that goes up during one brings
    /// the call screen back above it.
    public var hasActiveCall: () -> Bool
    /// `sharedContext.navigateToCurrentCall()`: the call screen a block now covers is shown again,
    /// above it (`SGCallScreenPlacement`).
    public var navigateToCurrentCall: () -> Void
    /// Whether `root` is the main window's `viewController`. A call is shown on the window's root, so
    /// a block going up on a root the window does not show yet raises nothing (the consent wall's
    /// rule); and the reminder is offered on the authorized root only once it is the window's — an
    /// authorized root being readied during an account switch is not on screen yet (§4g).
    public var isWindowRoot: (NavigationController) -> Bool

    public init(
        isAppStoreBuild: Bool,
        isSandboxReceipt: Bool,
        presentation: @escaping () -> SGAppUpdatePresentation,
        openAppStorePage: @escaping () -> Void,
        openTestFlightPage: @escaping (@escaping (Bool) -> Void) -> Void,
        openURL: @escaping (URL) -> Void,
        hasActiveCall: @escaping () -> Bool,
        navigateToCurrentCall: @escaping () -> Void,
        isWindowRoot: @escaping (NavigationController) -> Bool
    ) {
        self.isAppStoreBuild = isAppStoreBuild
        self.isSandboxReceipt = isSandboxReceipt
        self.presentation = presentation
        self.openAppStorePage = openAppStorePage
        self.openTestFlightPage = openTestFlightPage
        self.openURL = openURL
        self.hasActiveCall = hasActiveCall
        self.navigateToCurrentCall = navigateToCurrentCall
        self.isWindowRoot = isWindowRoot
    }

    /// Before AppDelegate configures the presenter: a store build's facts (no override) and no-op
    /// actions — the signed policy still decides and a block is still shown; nothing opens, no root is
    /// the window's, so no reminder.
    static let unconfigured = SGAppUpdateEnvironment(
        isAppStoreBuild: true,
        isSandboxReceipt: false,
        presentation: {
            return SGAppUpdatePresentation(theme: defaultPresentationTheme, fontSize: .regular, lang: "en")
        },
        openAppStorePage: {},
        openTestFlightPage: { completion in
            completion(false)
        },
        openURL: { _ in },
        hasActiveCall: { false },
        navigateToCurrentCall: {},
        isWindowRoot: { _ in false }
    )
}
