import Foundation
import Security

/// Zenlygram — the byte-level helpers the entitlement contract needs. No policy lives here.
enum SGEntitlementCrypto {
    // MARK: - base64url (the JWS alphabet; the server emits NO padding)

    static func base64urlDecode(_ string: String) -> Data? {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder == 2 {
            value += "=="
        } else if remainder == 3 {
            value += "="
        } else if remainder == 1 {
            // Not a valid base64 length; padding it would silently accept garbage.
            return nil
        }
        return Data(base64Encoded: value)
    }

    static func base64urlEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Random

    /// `count` cryptographically random bytes, or nil when the system RNG refuses (never silently
    /// falls back to a weaker source: a predictable nonce is a replayable credential).
    static func randomBytes(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
    }

    /// Lowercase hex, which is what the server's `bin2hex`-shaped ids look like.
    static func hexString(_ data: Data) -> String {
        var result = ""
        result.reserveCapacity(data.count * 2)
        for byte in data {
            result += String(format: "%02x", byte)
        }
        return result
    }

    // MARK: - P-256 key encodings
    //
    // The app's deployment target is iOS 13 (`Telegram/BUILD`), and CryptoKit's
    // `pemRepresentation` / `derRepresentation` initialisers are iOS 14. Rather than pushing an
    // `@available(iOS 14.0, *)` through the whole public surface, the SPKI wrapper is handled here
    // and the keys are built with `x963Representation`, which is iOS 13.

    /// The fixed 26-byte SPKI prefix of an uncompressed P-256 (prime256v1) public key.
    private static let p256SPKIPrefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
    ]

    /// SPKI DER -> the raw 65-byte X9.63 point (`0x04 || X || Y`).
    static func p256X963(fromSPKI der: Data) -> Data? {
        guard der.count == self.p256SPKIPrefix.count + 65 else {
            return nil
        }
        guard Array(der.prefix(self.p256SPKIPrefix.count)) == self.p256SPKIPrefix else {
            return nil
        }
        let point = der.suffix(65)
        guard point.first == 0x04 else {
            return nil
        }
        return Data(point)
    }

    /// The raw 65-byte X9.63 point -> SPKI DER, which is what `/bind/start` accepts as
    /// `device_pubkey` (base64 of the SPKI DER; `x963Representation` is rejected with 422).
    static func p256SPKI(fromX963 point: Data) -> Data? {
        guard point.count == 65, point.first == 0x04 else {
            return nil
        }
        var der = Data(self.p256SPKIPrefix)
        der.append(point)
        return der
    }

    /// Accepts a PEM (`-----BEGIN PUBLIC KEY-----`) or bare base64 of an SPKI DER, and answers the
    /// X9.63 point. Anything else is nil — a pinned key that does not parse must not verify.
    static func p256X963(fromPinnedKey value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmed.hasPrefix("-----BEGIN") {
            body = trimmed
                .components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("-----") }
                .joined()
        } else {
            body = trimmed
        }
        let compact = body.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        guard let der = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        if let point = self.p256X963(fromSPKI: der) {
            return point
        }
        // Tolerate a config that already holds the bare point.
        if der.count == 65, der.first == 0x04 {
            return der
        }
        return nil
    }
}
