import Foundation
import SwiftSignalKit

import SGConfig
import SGLogging
import SGSimpleSettings
import SGWebAppExtensions
import SGWebSettingsScheme
import SGRequests
import SGRegDateScheme

// MARK: Zenlygram — the Swiftgram backend (api.swiftgram.app) is not used. Every endpoint
// below resolves locally without issuing a network request: settings return the built-in
// defaults, writes and receipt uploads complete as no-ops, and regdate lookups fail softly
// (the caller degrades gracefully). Signatures are kept so call sites stay untouched.

public let SG_API_AUTHORIZATION_HEADER = "Authorization"
public let SG_API_DEVICE_TOKEN_HEADER = "Device-Token"

public enum SGAPIError {
    case generic(String? = nil)
}

public func getSGSettings(token: String) -> Signal<SGWebSettings, SGAPIError> {
    return Signal { subscriber in
        SGLogger.shared.log("SGAPI", "Remote backend disabled: returning built-in default settings")
        subscriber.putNext(SGWebSettings.defaultValue)
        subscriber.putCompletion()
        return EmptyDisposable
    }
}



public func postSGSettings(token: String, data: [String:Any]) -> Signal<Void, SGAPIError> {
    return Signal { subscriber in
        SGLogger.shared.log("SGAPI", "Remote backend disabled: settings update skipped")
        subscriber.putCompletion()
        return EmptyDisposable
    }
}

public func getSGAPIRegDate(token: String, deviceToken: String, userId: Int64) -> Signal<RegDate, SGAPIError> {
    return Signal { subscriber in
        SGLogger.shared.log("SGAPI", "Remote backend disabled: regdate lookup skipped")
        subscriber.putError(.generic())
        return EmptyDisposable
    }
}


public func postSGReceipt(token: String, deviceToken: String, encodedReceiptData: Data) -> Signal<Void, SGAPIError> {
    return Signal { subscriber in
        SGLogger.shared.log("SGAPI", "Remote backend disabled: receipt upload skipped")
        subscriber.putCompletion()
        return EmptyDisposable
    }
}
