// MARK: Swiftgram
import SGStrings

import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

// MARK: - Curated data
//
// Only the curated @username list is lifted from Novagram
// (github.com/Novagramorg/iOS, submodules/Fenixuz/ProMessager/Sources/FenixBotsData.swift).
// Brand names are plain strings; section titles are localized via SGStrings keys.
// NOTE: replace these usernames with bots that actually exist for your fork before shipping
// (see gotchas: "novogram_youtube_bot" is a probable upstream typo, reproduced verbatim).

private struct SGHelperBot {
    let title: String
    let username: String
}

private struct SGHelperBotSection {
    let titleKey: String
    let bots: [SGHelperBot]
}

private let sgHelperBotSections: [SGHelperBotSection] = [
    SGHelperBotSection(titleKey: "Settings.HelperBots.Downloaders", bots: [
        SGHelperBot(title: "YouTube", username: "novogram_youtube_bot"),
        SGHelperBot(title: "Shazam", username: "novagram_shazam_bot"),
        SGHelperBot(title: "Spotify", username: "novagram_spotify_bot"),
        SGHelperBot(title: "VK", username: "novagram_vk_bot"),
        SGHelperBot(title: "RuTube", username: "novagram_rutube_bot"),
        SGHelperBot(title: "Twitch", username: "novagram_twitch_bot"),
        SGHelperBot(title: "Pinterest", username: "novagram_pinterest_bot"),
        SGHelperBot(title: "Reddit", username: "novagram_reddit_bot"),
        SGHelperBot(title: "Facebook", username: "novagram_facebook_bot"),
        SGHelperBot(title: "Twitter / X", username: "novagram_twitter_bot"),
        SGHelperBot(title: "TikTok", username: "novagram_tiktok_bot"),
        SGHelperBot(title: "Instagram", username: "novagram_instagram_bot")
    ]),
    SGHelperBotSection(titleKey: "Settings.HelperBots.MediaTools", bots: [
        SGHelperBot(title: "Compress", username: "novagram_compress_bot"),
        SGHelperBot(title: "Crop", username: "novagram_crop_bot"),
        SGHelperBot(title: "Trimmer", username: "novagram_trimmer_bot"),
        SGHelperBot(title: "Blur", username: "novagram_blur_bot"),
        SGHelperBot(title: "BG Remover", username: "novagram_remover_bot"),
        SGHelperBot(title: "Upscaler", username: "novagram_upscaler_bot"),
        SGHelperBot(title: "Sticker Maker", username: "novagram_sticker_bot"),
        SGHelperBot(title: "Voice", username: "novagram_voice_bot")
    ]),
    SGHelperBotSection(titleKey: "Settings.HelperBots.Utilities", bots: [
        SGHelperBot(title: "QR Code", username: "novagram_qr_bot"),
        SGHelperBot(title: "Password", username: "novagram_password_bot"),
        SGHelperBot(title: "Temp Mail", username: "novagram_tempmail_bot"),
        SGHelperBot(title: "PDF Tools", username: "novagram_pdf_bot"),
        SGHelperBot(title: "Text to Speech", username: "novagram_tts_bot")
    ]),
    SGHelperBotSection(titleKey: "Settings.HelperBots.FunInfo", bots: [
        SGHelperBot(title: "Memes", username: "novagram_meme_bot"),
        SGHelperBot(title: "Transliterator", username: "novagram_translit_bot"),
        SGHelperBot(title: "Wallpapers", username: "novagram_wallpaper_bot"),
        SGHelperBot(title: "Movies", username: "novagram_movies_bot"),
        SGHelperBot(title: "Weather", username: "novagram_weather_bot"),
        SGHelperBot(title: "Currency Rates", username: "novagram_rates_bot"),
        SGHelperBot(title: "Facts", username: "novagram_facts_bot"),
        SGHelperBot(title: "Quotes", username: "novagram_quotes_bot"),
        SGHelperBot(title: "Proverbs", username: "novagram_proverbs_bot")
    ])
]

// MARK: - Arguments

private final class SGHelperBotsArguments {
    let context: AccountContext
    let openBot: (String) -> Void

    init(context: AccountContext, openBot: @escaping (String) -> Void) {
        self.context = context
        self.openBot = openBot
    }
}

// MARK: - Entries

private enum SGHelperBotsEntry: ItemListNodeEntry {
    case header(Int32, String)               // (sectionIndex, localized title)
    case bot(Int32, Int32, String, String)   // (sectionIndex, botIndex, title, @username)

    var section: ItemListSectionId {
        switch self {
        case let .header(sectionIndex, _): return ItemListSectionId(sectionIndex)
        case let .bot(sectionIndex, _, _, _): return ItemListSectionId(sectionIndex)
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(sectionIndex, _):           return sectionIndex * 1000
        case let .bot(sectionIndex, botIndex, _, _): return sectionIndex * 1000 + 1 + botIndex
        }
    }

    static func == (lhs: SGHelperBotsEntry, rhs: SGHelperBotsEntry) -> Bool {
        switch lhs {
        case let .header(lSection, lTitle):
            if case let .header(rSection, rTitle) = rhs, lSection == rSection, lTitle == rTitle { return true }
            return false
        case let .bot(lSection, lIndex, lTitle, lUsername):
            if case let .bot(rSection, rIndex, rTitle, rUsername) = rhs,
               lSection == rSection, lIndex == rIndex, lTitle == rTitle, lUsername == rUsername { return true }
            return false
        }
    }

    static func < (lhs: SGHelperBotsEntry, rhs: SGHelperBotsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SGHelperBotsArguments
        switch self {
        case let .header(_, title):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: title,
                sectionId: self.section
            )
        case let .bot(_, _, title, username):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: title,
                label: "@\(username)",
                labelStyle: .detailText,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openBot(username)
                }
            )
        }
    }
}

private func sgHelperBotsEntries(presentationData: PresentationData) -> [SGHelperBotsEntry] {
    let lang = presentationData.strings.baseLanguageCode
    var entries: [SGHelperBotsEntry] = []
    for (sectionIndex, section) in sgHelperBotSections.enumerated() {
        let sIdx = Int32(sectionIndex)
        entries.append(.header(sIdx, i18n(section.titleKey, lang)))
        for (botIndex, bot) in section.bots.enumerated() {
            entries.append(.bot(sIdx, Int32(botIndex), bot.title, bot.username))
        }
    }
    return entries.sorted()
}

// MARK: - Controller

// Reachable from SGSettingsController via the "Helper Bots" disclosure row.
// Tapping a row resolves https://t.me/<username> and opens the chat / bot-start deep link
// using the same resolveUrl + openResolvedUrl flow as submodules/TelegramUI/Sources/OpenUrl.swift.
func sgHelperBotsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var getNavigationControllerImpl: (() -> NavigationController?)?

    let openBotDisposable = MetaDisposable()

    let arguments = SGHelperBotsArguments(context: context, openBot: { username in
        openBotDisposable.set((context.sharedContext.resolveUrl(context: context, peerId: nil, url: "https://t.me/\(username)", skipUrlAuth: true)
        |> deliverOnMainQueue).startStrict(next: { resolved in
            let navigationController = getNavigationControllerImpl?()
            if case let .externalUrl(value) = resolved {
                context.sharedContext.applicationBindings.openUrl(value)
            } else if case .peer(nil, _) = resolved {
                // Curated @username did not resolve to a real bot (placeholder / renamed / deleted).
                // Show a clear "unavailable" message instead of a dead-end tap.
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                presentControllerImpl?(textAlertController(context: context, title: nil, text: i18n("Settings.HelperBots.Unavailable", presentationData.strings.baseLanguageCode), actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), nil)
            } else {
                context.sharedContext.openResolvedUrl(
                    resolved,
                    context: context,
                    urlContext: .generic,
                    navigationController: navigationController,
                    forceExternal: false,
                    forceUpdate: false,
                    openPeer: { peer, navigation in
                        switch navigation {
                        case .info:
                            if let infoController = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) {
                                navigationController?.pushViewController(infoController)
                            }
                        case let .chat(_, subject, peekData):
                            if let navigationController {
                                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), subject: subject, peekData: peekData))
                            }
                        case let .withBotStartPayload(botStart):
                            if let navigationController {
                                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), botStart: botStart))
                            }
                        default:
                            if let navigationController {
                                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
                            }
                        }
                    },
                    sendFile: nil,
                    sendSticker: nil,
                    sendEmoji: nil,
                    requestMessageActionUrlAuth: nil,
                    joinVoiceChat: { _, _, _ in },
                    present: { c, a in
                        presentControllerImpl?(c, a as? ViewControllerPresentationArguments)
                    },
                    dismissInput: {},
                    contentContext: nil,
                    progress: nil,
                    completion: nil
                )
            }
        }))
    })

    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(i18n("Settings.HelperBots", lang)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: sgHelperBotsEntries(presentationData: presentationData),
            style: .blocks
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    getNavigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    return controller
}
