import Foundation
import Security

public enum SGAIAssistantKeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

public enum SGAIAssistantKeychain {
    private static let service: String = "app.swiftgram.aiassistant"
    private static let account: String = "anthropic_api_key"

    // Reads the stored key. `.success(nil)` means no key is stored;
    // `.failure` means the Keychain itself failed (device locked, etc.) and
    // the caller must surface the error instead of treating it as "no key".
    public static func readApiKey() -> Result<String?, SGAIAssistantKeychainError> {
        var query: [String: Any] = [:]
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
            case errSecSuccess:
                guard let data: Data = item as? Data, let key: String = String(data: data, encoding: .utf8) else {
                    return .failure(.unexpectedStatus(errSecDecode))
                }
                return .success(key)
            case errSecItemNotFound:
                return .success(nil)
            default:
                return .failure(.unexpectedStatus(status))
        }
    }

    // Convenience accessor for non-critical paths (text-field prefill);
    // Keychain failures degrade to nil here.
    public static func apiKey() -> String? {
        if case let .success(key) = readApiKey() {
            return key
        }
        return nil
    }

    // Saves (or, for nil/empty, clears) the key. Every Keychain status is
    // checked so a failed write can be surfaced to the user instead of
    // silently leaving the feature broken.
    public static func setApiKey(_ key: String?) -> Result<Void, SGAIAssistantKeychainError> {
        var base: [String: Any] = [:]
        base[kSecClass as String] = kSecClassGenericPassword
        base[kSecAttrService as String] = service
        base[kSecAttrAccount as String] = account

        let deleteStatus: OSStatus = SecItemDelete(base as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return .failure(.unexpectedStatus(deleteStatus))
        }

        guard let key: String = key, !key.isEmpty, let data: Data = key.data(using: .utf8) else {
            return .success(())
        }

        var attributes: [String: Any] = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus: OSStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return .failure(.unexpectedStatus(addStatus))
        }
        return .success(())
    }

    public static var hasApiKey: Bool {
        if let key: String = apiKey(), !key.isEmpty {
            return true
        }
        return false
    }
}
