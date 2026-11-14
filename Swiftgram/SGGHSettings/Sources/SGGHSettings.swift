import Foundation
import SwiftSignalKit
import SGLogging
import SGGHSettingsScheme
import AccountContext
import TelegramCore

// MARK: Zenlygram — the Swiftgram remote config (raw.githubusercontent.com/Swiftgram/settings)
// is not fetched. The built-in defaults are applied locally instead, which also clears any
// announcements a previous install may have cached from the remote.

public func updateSGGHSettingsInteractivelly(context: AccountContext) {
    let _ = (context.account.postbox.transaction { transaction in
        updateAppConfiguration(transaction: transaction, { configuration -> AppConfiguration in
            var configuration = configuration
            configuration.sgGHSettings = SGGHSettings.defaultValue
            return configuration
        })
    }).startStandalone()
}
