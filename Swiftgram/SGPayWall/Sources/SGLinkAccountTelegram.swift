import Foundation
import Display
import SGEntitlement

/// Zenlygram — what the "Link Telegram Account" screen needs from the Telegram account it links,
/// supplied by the caller that holds that account's context. SGPayWall never imports TelegramCore,
/// so both capabilities arrive here as closures already bound to that one account.
///
/// `@unchecked Sendable`: it is immutable, and only the link screen's main-actor model and view
/// ever call its closures; it is Sendable only so that model's `nonisolated init` may store it.
public struct SGLinkAccountTelegram: @unchecked Sendable {
    /// bind-attest v1.1: Telegram-signed Mini App `initData` for `attest`, obtained silently AS THIS
    /// ACCOUNT over MTProto (`messages.requestMainWebView` of the resolved bot, whose user id must be
    /// `attest.botId` and which must have a Main Mini App). nil on any failure, and the screen then
    /// shows the code. It never opens the returned URL, shows no WebView and sends no message.
    public let attest: (SGEntitlementBindAttest) async -> String?
    /// Opens a validated `t.me` link INSIDE the app, for this account — never `UIApplication.open`.
    /// `navigationController` is the link screen's own, nil when it is presented modally. Called on
    /// the main thread.
    public let openLink: (String, NavigationController?) -> Void

    public init(
        attest: @escaping (SGEntitlementBindAttest) async -> String?,
        openLink: @escaping (String, NavigationController?) -> Void
    ) {
        self.attest = attest
        self.openLink = openLink
    }
}
