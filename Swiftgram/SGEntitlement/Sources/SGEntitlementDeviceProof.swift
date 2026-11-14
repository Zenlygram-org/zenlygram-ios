import Foundation
import CryptoKit

/// Zenlygram — the intent an `X-Device-Proof` signs (apple-ownership-proof contract, 2026-10-12).
/// Each mode belongs to exactly one route, and the mode and path are both signed, so a proof cannot
/// move between routes or intents.
public enum SGEntitlementDeviceProofMode: String, CaseIterable {
    /// Anonymous `/apple/attach`: this install's key held this receipt first (orphan metadata).
    case appleOrphan = "apple-orphan"
    /// Authenticated, EXPLICIT Restore: claim this receipt's still-unlinked orphan. Never sent by a
    /// background attach.
    case appleRestore = "apple-restore"
    /// `/bind/poll`: the key `/bind/start` registered asks to merge the orphans it proved.
    case bindMerge = "bind-merge"
    /// `/bind/attest`: the key `/bind/start` registered presents Telegram-signed `initData` for its
    /// own bind. The payload is the EXACT raw request body.
    case bindAttest = "bind-attest"

    public var canonicalPath: String {
        switch self {
        case .appleOrphan, .appleRestore:
            return "/v1/apple/attach"
        case .bindMerge:
            return "/v1/bind/poll"
        case .bindAttest:
            return "/v1/bind/attest"
        }
    }
}

/// The credentials one proven request carries. `X-Device-Id`, `X-Device-Nonce` and `X-Device-Ts`
/// are the existing headers; `X-Device-Sig` (the unchanged DeviceAuth signature over the same nonce
/// and timestamp) is present only for an authenticated request.
public struct SGEntitlementDeviceProofMaterial: Equatable {
    public let deviceId: String
    public let nonce: String
    public let timestamp: Int64
    /// `device_pubkey`: standard base64 of the SPKI DER of the key that signed.
    public let publicKeySPKIBase64: String
    /// `X-Device-Proof`: standard base64 (with padding) of the raw 64-byte r||s signature.
    public let proof: String
    public let deviceAuthSignature: String?

    public var headers: [String: String] {
        var headers = [
            "X-Device-Id": self.deviceId,
            "X-Device-Nonce": self.nonce,
            "X-Device-Ts": "\(self.timestamp)",
            "X-Device-Proof": self.proof
        ]
        if let deviceAuthSignature = self.deviceAuthSignature {
            headers["X-Device-Sig"] = deviceAuthSignature
        }
        return headers
    }
}

public enum SGEntitlementDeviceProof {
    public static let version = "zenlypay-device-proof-v1"

    /// The nine LF-separated UTF-8 lines, no trailing LF:
    /// version, `POST`, canonical path, raw device id, sha256(SPKI DER) hex, nonce, decimal ts,
    /// sha256(payload UTF-8) hex, mode. nil when a field is empty, negative, or would inject a line.
    public static func message(mode: SGEntitlementDeviceProofMode, deviceId: String, spkiDER: Data, nonce: String, timestamp: Int64, payload: String) -> Data? {
        guard !deviceId.isEmpty, !nonce.isEmpty, !spkiDER.isEmpty, !payload.isEmpty, timestamp >= 0 else {
            return nil
        }
        for field in [deviceId, nonce] where field.contains("\n") || field.contains("\r") {
            return nil
        }
        let lines = [
            self.version,
            "POST",
            mode.canonicalPath,
            deviceId,
            self.sha256Hex(spkiDER),
            nonce,
            "\(timestamp)",
            self.sha256Hex(Data(payload.utf8)),
            mode.rawValue
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Builds the material with `sign` (the install key). `includeDeviceAuth` adds the unchanged
    /// DeviceAuth signature over the SAME nonce and timestamp (authenticated Restore).
    static func make(mode: SGEntitlementDeviceProofMode, deviceId: String, nonce: String, timestamp: Int64, spkiDER: Data, payload: String, includeDeviceAuth: Bool, sign: (Data) throws -> Data) -> SGEntitlementDeviceProofMaterial? {
        guard let message = self.message(mode: mode, deviceId: deviceId, spkiDER: spkiDER, nonce: nonce, timestamp: timestamp, payload: payload),
              let proof = try? sign(message)
        else {
            return nil
        }
        var deviceAuth: String?
        if includeDeviceAuth {
            guard let signature = try? sign(Data("\(deviceId)\n\(nonce)\n\(timestamp)".utf8)) else {
                return nil
            }
            deviceAuth = signature.base64EncodedString()
        }
        return SGEntitlementDeviceProofMaterial(
            deviceId: deviceId,
            nonce: nonce,
            timestamp: timestamp,
            publicKeySPKIBase64: spkiDER.base64EncodedString(),
            proof: proof.base64EncodedString(),
            deviceAuthSignature: deviceAuth
        )
    }

    /// The anonymous `/apple/attach` credentials: the headers and the body `device_pubkey`, composed
    /// from ONE material or not at all. The server treats a present `device_pubkey` as the proof
    /// protocol and rejects it without a proof, and rejects an empty or malformed proof; this build
    /// never sends the legacy unsigned anonymous form either. nil means: fail this attempt as
    /// transient (the transaction stays unfinished in the outbox and retries) — never downgrade.
    public static func anonymousAttachCredentials(_ material: SGEntitlementDeviceProofMaterial?) -> (headers: [String: String], devicePubkey: String)? {
        guard let material, material.deviceAuthSignature == nil, !material.proof.isEmpty, !material.publicKeySPKIBase64.isEmpty, !material.deviceId.isEmpty else {
            return nil
        }
        return (material.headers, material.publicKeySPKIBase64)
    }

    /// What `/bind/poll` (and `/bind/attest`, with its own mode) may do, decided BEFORE anything is
    /// sent.
    ///
    /// The server issues the bind's session for the key `/bind/start` registered. A poll with any
    /// other key — proven or proofless — would consume the bind into a session whose every later
    /// DeviceAuth request this install cannot sign. So a known key change never polls. `/bind/attest`
    /// requires the proof, so for it `.proofless` means "do not send".
    public enum BindPollPreparation: Equatable {
        /// Send the poll with these `bind-merge` proof headers (the registered key signed).
        case prove(headers: [String: String])
        /// Legacy compatibility ONLY: the start carries no registered key at all. Signs in, merges
        /// nothing.
        case proofless
        /// The install key is known and is NOT the registered one (or changed while signing).
        /// Nothing was sent: start a fresh `/bind/start` with the current key.
        case restartBind
        /// The key is unavailable (locked Keychain) or signing failed. Nothing was sent; retry.
        case retryLater
    }

    /// `registeredPublicKey`: `SGEntitlementBindStart.registeredPublicKey`. `currentPublicKey`: the
    /// install key now. `makeMaterial` signs the `bind-merge` proof and is called only when the two
    /// match; the material's own key is re-checked, so a key regenerated mid-signing restarts too.
    public static func prepareBindPoll(registeredPublicKey: String?, currentPublicKey: String?, makeMaterial: () -> SGEntitlementDeviceProofMaterial?) -> BindPollPreparation {
        guard let registeredPublicKey, !registeredPublicKey.isEmpty else {
            return .proofless
        }
        guard let currentPublicKey, !currentPublicKey.isEmpty else {
            return .retryLater
        }
        guard currentPublicKey == registeredPublicKey else {
            return .restartBind
        }
        guard let material = makeMaterial(), !material.publicKeySPKIBase64.isEmpty else {
            return .retryLater
        }
        guard material.publicKeySPKIBase64 == registeredPublicKey else {
            return .restartBind
        }
        guard material.deviceAuthSignature == nil, !material.proof.isEmpty else {
            return .retryLater
        }
        return .prove(headers: material.headers)
    }

    /// A `bind-merge` proof is only meaningful with the key `/bind/start` registered: the server
    /// verifies against that stored key. A different key never polls (`prepareBindPoll`).
    public static func canProveBindMerge(currentPublicKey: String?, registeredPublicKey: String?) -> Bool {
        guard let currentPublicKey, let registeredPublicKey, !currentPublicKey.isEmpty else {
            return false
        }
        return currentPublicKey == registeredPublicKey
    }

    /// The `/bind/attest` body, serialised ONCE: these bytes are both what the `bind-attest` proof
    /// signs (`payload(forRawBody:)`) and what is sent. Poll token in the body, never the query.
    /// nil when the body would exceed the endpoint's 8 KiB.
    public static func bindAttestBody(pollToken: String, initData: String) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["poll_token": pollToken, "init_data": initData], options: [.sortedKeys]) else {
            return nil
        }
        guard data.count <= SGEntitlementDeviceProof.maxBindAttestBodyBytes else {
            return nil
        }
        return data
    }

    static let maxBindAttestBodyBytes = 8 * 1024

    /// The proof payload for a raw body: the server hashes the raw body BYTES, the message hashes
    /// the payload's UTF-8, and JSON bodies are UTF-8 — so this string's UTF-8 is `body` exactly.
    public static func payload(forRawBody body: Data) -> String {
        return String(decoding: body, as: UTF8.self)
    }

    static func sha256Hex(_ data: Data) -> String {
        return SGEntitlementCrypto.hexString(Data(SHA256.hash(data: data)))
    }
}
