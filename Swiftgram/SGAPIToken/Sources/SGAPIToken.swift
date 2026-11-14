import Foundation
import SwiftSignalKit
import AccountContext
import TelegramCore
import SGLogging
import SGConfig
import SGWebAppExtensions

// MARK: Zenlygram — the Swiftgram backend is not used. No API token is ever requested and
// the Swiftgram settings web-app is never opened: neither function resolves the Swiftgram
// bot or issues a web-view request. Both fail immediately and every caller degrades
// gracefully (announcements, content settings and receipt flows are disabled elsewhere).

public enum SGAPITokenError {
    case generic(String? = nil)
}

public func getSGApiToken(context: AccountContext, botUsername: String = SG_CONFIG.botUsername) -> Signal<String, SGAPITokenError> {
    SGLogger.shared.log("SGAPI", "Remote backend disabled: token request skipped")
    return .fail(.generic())
}

public func getSGSettingsURL(context: AccountContext, botUsername: String = SG_CONFIG.botUsername, url: String = SG_CONFIG.webappUrl, themeParams: [String: Any]? = nil) -> Signal<String, SGAPITokenError> {
    SGLogger.shared.log("SGAPI", "Remote backend disabled: settings URL request skipped")
    return .fail(.generic())
}
