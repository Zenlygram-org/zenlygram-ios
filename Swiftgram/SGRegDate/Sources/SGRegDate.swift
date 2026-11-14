import Foundation
import SwiftSignalKit
import TelegramPresentationData

import SGLogging
import SGStrings
import SGRegDateScheme
import AccountContext
import SGSimpleSettings
import SGAPI
import SGAPIToken
import SGDeviceToken

public enum RegDateError {
    case generic
}

// MARK: Zenlygram — the Swiftgram regdate backend is not used, so no estimation is ever
// fetched. Previously cached estimations keep displaying; otherwise the peer-info row falls
// back to Telegram's own registrationDate (when the server provides it) or stays hidden.
public func getRegDate(context: AccountContext, peerId: Int64) -> Signal<RegDate?, NoError> {
    return Signal { subscriber in
        if let regDateData = SGSimpleSettings.shared.regDateCache[String(peerId)], let regDate = try? JSONDecoder().decode(RegDate.self, from: regDateData), regDate.validUntil == 0 || regDate.validUntil > Int64(Date().timeIntervalSince1970) {
            subscriber.putNext(regDate)
            subscriber.putCompletion()
        } else {
            subscriber.putNext(nil)
            subscriber.putCompletion()
        }

        return EmptyDisposable
    }
}
