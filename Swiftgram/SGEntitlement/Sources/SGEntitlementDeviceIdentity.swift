import Foundation
import CryptoKit

/// Zenlygram — the five credentials every device-tier request carries.
///
/// They are single-use: `(device, nonce)` is claimed for 600 s, so **every retry needs a fresh
/// nonce, a fresh ts and a fresh signature**. Re-sending a captured set is `nonce_replayed`, not
/// de-duplication; body-level de-duplication is what `Idempotency-Key` is for.
public struct SGEntitlementDeviceCredentials: Equatable {
    public let deviceId: String
    public let nonce: String
    /// Decimal Unix seconds, exactly the bytes sent in `X-Device-Ts` and signed.
    public let timestamp: Int64
    /// Standard base64 WITH padding. base64url is rejected by the server's strict decoder.
    public let signature: String

    public var headers: [String: String] {
        return [
            "X-Device-Id": self.deviceId,
            "X-Device-Nonce": self.nonce,
            "X-Device-Ts": "\(self.timestamp)",
            "X-Device-Sig": self.signature
        ]
    }
}

/// Zenlygram — the device id and the signing keypair, one of each per INSTALL and backend ORIGIN (not
/// per Telegram account; `SGEntitlementStore.scope` — a new origin mints its own, never reusing an
/// earlier origin's), and the one place that signs.
///
/// The keypair lives in the Secure Enclave where there is one; the simulator and devices without one
/// fall back to a software P-256 key stored in the same Keychain item class. The server cannot tell
/// the difference and does not need to: the Enclave is what makes a stolen refresh token
/// insufficient on a different phone, and a simulator has nothing worth stealing.
public final class SGEntitlementDeviceIdentity {
    public static let shared = SGEntitlementDeviceIdentity()

    private enum KeyHolder {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var x963PublicKey: Data {
            switch self {
            case let .enclave(key):
                return key.publicKey.x963Representation
            case let .software(key):
                return key.publicKey.x963Representation
            }
        }

        func signature(for data: Data) throws -> Data {
            switch self {
            case let .enclave(key):
                return try key.signature(for: data).rawRepresentation
            case let .software(key):
                return try key.signature(for: data).rawRepresentation
            }
        }
    }

    private let lock = NSLock()
    /// The store holding this identity's device id and key: `SGEntitlementStore.shared` for `shared`.
    private let store: SGEntitlementStore
    private var cachedKey: KeyHolder?
    private var didLoadKey = false

    /// The app uses `shared` (the shipped store). Tests build an identity over a store of their own,
    /// so a device-tier request is really signed without touching the shipped Keychain items.
    init(store: SGEntitlementStore = .shared) {
        self.store = store
    }

    /// Tests only: an identity over a store of their own, so a logic-test host without a keychain
    /// can still mint and hold an install key. The app and extensions only ever use `shared`.
    static func forTesting(store: SGEntitlementStore) -> SGEntitlementDeviceIdentity {
        return SGEntitlementDeviceIdentity(store: store)
    }

    /// The raw device id, minted on first use. 32 random bytes as 64 lowercase hex characters.
    public func deviceId() -> String? {
        return self.store.ensureDeviceId()
    }

    public var isUsingSecureEnclave: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if case .enclave = self.loadKeyLocked() {
            return true
        }
        return false
    }

    /// `device_pubkey` for `/bind/start`: base64 of the P-256 SPKI DER. The raw X9.63 point is
    /// rejected with `422 invalid_pubkey`, which is why it is wrapped here.
    public func publicKeySPKIBase64() -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let holder = self.loadKeyLocked(), let der = SGEntitlementCrypto.p256SPKI(fromX963: holder.x963PublicKey) else {
            return nil
        }
        return der.base64EncodedString()
    }

    /// Signs `device_id + "\n" + nonce + "\n" + ts` — a single LF, no CR, no trailing newline, no
    /// spaces — with ECDSA P-256 / SHA-256, and returns the credential set.
    ///
    /// `timestamp` must be the TRANSMITTED clock (`SGEntitlementClock.transmitTimestamp()`), never
    /// `effectiveNow()`: a device whose clock is behind would otherwise be permanently
    /// `clock_skew`-rejected.
    public func credentials(timestamp: Int64) -> SGEntitlementDeviceCredentials? {
        guard let deviceId = self.deviceId() else {
            return nil
        }
        guard let nonceBytes = SGEntitlementCrypto.randomBytes(16) else {
            return nil
        }
        let nonce = SGEntitlementCrypto.hexString(nonceBytes)

        self.lock.lock()
        let holder = self.loadKeyLocked()
        self.lock.unlock()

        guard let holder else {
            return nil
        }
        let message = Data("\(deviceId)\n\(nonce)\n\(timestamp)".utf8)
        guard let raw = try? holder.signature(for: message) else {
            return nil
        }
        return SGEntitlementDeviceCredentials(
            deviceId: deviceId,
            nonce: nonce,
            timestamp: timestamp,
            signature: raw.base64EncodedString()
        )
    }

    /// `X-Device-Proof` material signed with the EXISTING install key, for `mode` over `payload` (the
    /// exact `signed_transaction`, or the effective poll token). The SPKI, the proof and — when
    /// `includeDeviceAuth` — the unchanged DeviceAuth signature all come from ONE key load and share
    /// one fresh nonce and `timestamp` (the transmitted clock, like `credentials(timestamp:)`), so a
    /// concurrent key regeneration can never pair one key's `device_pubkey` with another's proof.
    /// Fresh per attempt: a retry must call this again.
    public func proofMaterial(mode: SGEntitlementDeviceProofMode, payload: String, timestamp: Int64, includeDeviceAuth: Bool) -> SGEntitlementDeviceProofMaterial? {
        guard let deviceId = self.deviceId(), let nonceBytes = SGEntitlementCrypto.randomBytes(16) else {
            return nil
        }
        self.lock.lock()
        let holder = self.loadKeyLocked()
        self.lock.unlock()
        guard let holder, let spki = SGEntitlementCrypto.p256SPKI(fromX963: holder.x963PublicKey) else {
            return nil
        }
        return SGEntitlementDeviceProof.make(
            mode: mode,
            deviceId: deviceId,
            nonce: SGEntitlementCrypto.hexString(nonceBytes),
            timestamp: timestamp,
            spkiDER: spki,
            payload: payload,
            includeDeviceAuth: includeDeviceAuth,
            sign: { try holder.signature(for: $0) }
        )
    }

    /// Throws the keypair away and mints a new one. Used after `401 device_key_mismatch` (the old
    /// binding cannot be repaired) and after `422 invalid_pubkey`. Re-binding overwrites the key the
    /// server holds, so this is the recovery path, not a reset.
    @discardableResult
    public func regenerateKeyPair() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.store.setEnclaveKeyBlob(nil)
        self.store.setSoftwareKeyBlob(nil)
        self.cachedKey = nil
        self.didLoadKey = false
        return self.loadKeyLocked() != nil
    }

    // MARK: - Key material

    private func loadKeyLocked() -> KeyHolder? {
        if self.didLoadKey {
            return self.cachedKey
        }
        self.didLoadKey = true

        if let blob = self.store.enclaveKeyBlob(),
           let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) {
            self.cachedKey = .enclave(key)
            return self.cachedKey
        }
        if let blob = self.store.softwareKeyBlob(),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: blob) {
            self.cachedKey = .software(key)
            return self.cachedKey
        }
        self.cachedKey = self.mintKeyLocked()
        return self.cachedKey
    }

    private func mintKeyLocked() -> KeyHolder? {
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            if self.store.setEnclaveKeyBlob(key.dataRepresentation) {
                return .enclave(key)
            }
            // The Enclave key exists but could not be persisted: a key we cannot reload is worse than
            // none, because the next launch would sign with a different one and earn
            // `device_key_mismatch`. Fall through to the software key.
        }
        let key = P256.Signing.PrivateKey()
        guard self.store.setSoftwareKeyBlob(key.rawRepresentation) else {
            return nil
        }
        return .software(key)
    }
}
