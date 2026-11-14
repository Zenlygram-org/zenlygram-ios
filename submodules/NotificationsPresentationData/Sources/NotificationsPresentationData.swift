import Foundation

public struct NotificationsPresentationData: Codable, Equatable {
    public var applicationLockedMessageString: String
    public var incomingCallString: String
    // Zenlygram — Secret Vault / Chat Lock (audit batch 3): localized generic "Incoming Call" text the
    // NotificationService shows instead of the caller for a locked or vaulted peer. Optional, so JSON written by an
    // older app version (no such key) still decodes; the extension then falls back to English.
    public var incomingCallGenericString: String?
    
    public init(applicationLockedMessageString: String, incomingCallString: String, incomingCallGenericString: String? = nil) {
        self.applicationLockedMessageString = applicationLockedMessageString
        self.incomingCallString = incomingCallString
        self.incomingCallGenericString = incomingCallGenericString
    }
}

public func notificationsPresentationDataPath(rootPath: String) -> String {
    return rootPath + "/notificationsPresentationData.json"
}
