import Foundation

import SGAPIToken
import SGAPI
import SGLogging

import AccountContext

import SGSimpleSettings
import SGWebSettingsScheme
import TelegramCore

// MARK: Zenlygram — the Swiftgram backend is not used. Instead of fetching remote web
// settings, the built-in defaults are applied locally (which also clears any values a
// previous install may have cached from the remote), and settings posts are no-ops.

public func updateSGWebSettingsInteractivelly(context: AccountContext) {
    let _ = (context.account.postbox.transaction { transaction in
        updateAppConfiguration(transaction: transaction, { configuration -> AppConfiguration in
            var configuration = configuration
            configuration.sgWebSettings = SGWebSettings.defaultValue
            return configuration
        })
    }).startStandalone()
}


public func postSGWebSettingsInteractivelly(context: AccountContext, data: [String: Any]) {
    SGLogger.shared.log("SGAPI", "Remote backend disabled: web settings post skipped")
}
