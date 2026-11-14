import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display
import TelegramPresentationData
import SGEntitlement
import SGPayWall

/// The whole Telegram side of one attestation (resolve + `requestMainWebView`) must answer within
/// this, or the link screen shows the code instead.
private let sgBindAttestTimeout: Double = 15.0
/// A cached `@bot` resolution older than this is refreshed, so the bot's id and its
/// `bot_has_main_app` flag are current when deciding whether to ask at all.
private let sgBindAttestResolveAgeLimit: Int32 = 60

/// Zenlygram — the link screen's view of the Telegram account in `context`: its silent attestation
/// (bind-attest v1) and its in-app links. Every caller of `sgLinkTelegramAccountController` passes
/// the context of the account it links, so both always act AS that account.
public func sgLinkAccountTelegram(context: AccountContext) -> SGLinkAccountTelegram {
    let engine = context.engine
    return SGLinkAccountTelegram(
        attest: { attest in
            return await sgBindAttestInitData(engine: engine, attest: attest)
        },
        openLink: { [weak context] url, navigationController in
            guard let context else {
                return
            }
            // In-app resolution of the t.me link for this account (the bot chat with its start
            // payload), never `UIApplication.open`: a modal link screen has no navigation stack, so
            // the main one is used.
            let navigationController = navigationController ?? (context.sharedContext.mainWindow?.viewController as? NavigationController)
            context.sharedContext.openExternalUrl(
                context: context,
                urlContext: .generic,
                url: url,
                forceExternal: false,
                presentationData: context.sharedContext.currentPresentationData.with { $0 },
                navigationController: navigationController,
                dismissInput: {}
            )
        }
    )
}

/// Zenlygram — the Telegram side of one HEADLESS attestation for the automatic link (design 40
/// §7.3, §8): `initData` for this bind exactly as the link screen gets it, or why there is none, as
/// a stable code (`SGAutoLinkPolicy.localAttestCodes`) — never a value, a name or the URL:
/// - `attest_bot_not_found`: `@botUsername` resolved to nothing in this account;
/// - `attest_bot_mismatch`: it is not a cloud-user bot with the start's `bot_id`;
/// - `attest_no_main_app`: that bot has no Main Mini App (`bot_has_main_app`);
/// - `attest_webview_failed`: `messages.requestMainWebView` failed (`RequestWebViewError` is only
///   `.generic`);
/// - `attest_no_init_data`: the returned URL holds no usable `tgWebAppData`;
/// - `timeout`: no answer within `sgBindAttestTimeout`.
/// Runs AS the account in `context`; nothing is sent to the bot and the URL is never opened.
public func sgBindAttestEvidence(context: AccountContext, attest: SGEntitlementBindAttest) async -> SGEntitlementAttestEvidence {
    return await sgBindAttestEvidence(engine: context.engine, attest: attest)
}

/// The link screen's attestation: the evidence's `initData`, nil for any reason there is none.
private func sgBindAttestInitData(engine: TelegramEngine, attest: SGEntitlementBindAttest) async -> String? {
    if case let .initData(initData) = await sgBindAttestEvidence(engine: engine, attest: attest) {
        return initData
    }
    return nil
}

/// Resolves `@botUsername` in this account and requires a bot whose user id is `attest.botId` and
/// that has a Main Mini App; then asks Telegram for that Main Mini App with this bind's
/// `start_param` (`messages.requestMainWebView`, peer = bot = the bot, `start_param` only: no theme,
/// no other flags) and takes the Telegram-signed `initData` out of the returned URL's fragment. The
/// URL is never opened and nothing is sent to the bot. Any failure (e.g. `BOT_INVALID`), or no
/// answer within `sgBindAttestTimeout`, is `.unavailable` with its code.
private func sgBindAttestEvidence(engine: TelegramEngine, attest: SGEntitlementBindAttest) async -> SGEntitlementAttestEvidence {
    let signal: Signal<SGEntitlementAttestEvidence, NoError> = engine.peers.resolvePeerByName(name: attest.botUsername, referrer: nil, ageLimit: sgBindAttestResolveAgeLimit)
    |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
        guard case let .result(peer) = result else {
            return .complete()
        }
        return .single(peer)
    }
    |> take(1)
    |> mapToSignal { peer -> Signal<SGEntitlementAttestEvidence, NoError> in
        guard let peer else {
            return .single(.unavailable(reason: SGBindAttestReason.botNotFound))
        }
        guard case let .user(user) = peer, peer.id.namespace == Namespaces.Peer.CloudUser, let botInfo = user.botInfo, attest.botUserId == peer.id.id._internalGetInt64Value() else {
            return .single(.unavailable(reason: SGBindAttestReason.botMismatch))
        }
        let hasMainApp = botInfo.flags.contains(.hasWebApp)
        guard hasMainApp else {
            return .single(.unavailable(reason: SGBindAttestReason.noMainApp))
        }
        guard attest.matchesResolvedBot(userId: peer.id.id._internalGetInt64Value(), isBot: true, hasMainApp: hasMainApp) else {
            return .single(.unavailable(reason: SGBindAttestReason.botMismatch))
        }
        // `.inline(startParam:)` is exactly the method's `start_param` (flag 1) and nothing else.
        return engine.messages.requestMainWebView(peerId: peer.id, botId: peer.id, source: .inline(startParam: attest.startParam), themeParams: nil)
        |> map { result -> SGEntitlementAttestEvidence in
            guard let initData = SGEntitlementBindAttest.initData(fromWebAppURL: result.url) else {
                return .unavailable(reason: SGBindAttestReason.noInitData)
            }
            return .initData(initData)
        }
        |> `catch` { _ -> Signal<SGEntitlementAttestEvidence, NoError> in
            return .single(.unavailable(reason: SGBindAttestReason.webViewFailed))
        }
    }
    |> timeout(sgBindAttestTimeout, queue: Queue.concurrentDefaultQueue(), alternate: .single(.unavailable(reason: SGBindAttestReason.timeout)))

    // Exactly one resume: the first value, or — when the resolution ends without one — "not found".
    // The timeout bounds the wait, so a cancelled screen's attempt still finishes (and is then
    // discarded).
    return await withCheckedContinuation { continuation in
        let resumed = Atomic<Bool>(value: false)
        let finish: (SGEntitlementAttestEvidence) -> Void = { value in
            if !resumed.swap(true) {
                continuation.resume(returning: value)
            }
        }
        let _ = (signal |> take(1)).startStandalone(next: { value in
            finish(value)
        }, completed: {
            finish(.unavailable(reason: SGBindAttestReason.botNotFound))
        })
    }
}

/// The local attest codes of design 40 §7.3, spelled once (valid `error_code`s, contract §3.4).
private enum SGBindAttestReason {
    static let botNotFound = "attest_bot_not_found"
    static let botMismatch = "attest_bot_mismatch"
    static let noMainApp = "attest_no_main_app"
    static let webViewFailed = "attest_webview_failed"
    static let noInitData = "attest_no_init_data"
    static let timeout = "timeout"
}
