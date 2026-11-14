import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — `X-Device-Proof` (apple-ownership-proof contract, 2026-10-12). Shared canonical
/// vectors: the backend's verifier must produce byte-identical messages for these inputs. Keys are
/// ephemeral; no real credential is involved.
final class SGEntitlementDeviceProofTests: XCTestCase {
    /// SPKI DER of the fixed point 0x04 || 0x11 × 64 (not a valid curve point — the message only
    /// hashes the bytes). sha256 = 8dcf31a3…cc7f.
    private let vectorSPKI: Data = {
        var der = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04])
        der.append(Data(repeating: 0x11, count: 64))
        return der
    }()
    private let deviceId = String(repeating: "0f", count: 32)
    private let nonce = "00112233445566778899aabbccddeeff"
    private let timestamp: Int64 = 1790000000
    private let receipt = "eyJhbGciOiJFUzI1NiJ9.eyJ0cmFuc2FjdGlvbklkIjoiMjAwMCJ9.c2ln"
    private let pollToken = "pt_0123456789abcdef"

    func test_canonicalMessage_vectors() {
        let orphan = SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: self.deviceId, spkiDER: self.vectorSPKI, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt)
        XCTAssertEqual(orphan.map { String(decoding: $0, as: UTF8.self) }, [
            "zenlypay-device-proof-v1",
            "POST",
            "/v1/apple/attach",
            self.deviceId,
            "8dcf31a3ae6172b1df2b27702790897f2533ecd95c5dac56c39149fc2dd4cc7f",
            self.nonce,
            "1790000000",
            "21775aa51764228c9862ca8e8eb91cde1c43e043a8304075f871691da63bf216",
            "apple-orphan"
        ].joined(separator: "\n"), "no trailing LF, nine lines")

        let restore = SGEntitlementDeviceProof.message(mode: .appleRestore, deviceId: self.deviceId, spkiDER: self.vectorSPKI, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt)
        XCTAssertEqual(restore.map { String(decoding: $0, as: UTF8.self) }?.split(separator: "\n").map(String.init), [
            "zenlypay-device-proof-v1", "POST", "/v1/apple/attach", self.deviceId,
            "8dcf31a3ae6172b1df2b27702790897f2533ecd95c5dac56c39149fc2dd4cc7f", self.nonce, "1790000000",
            "21775aa51764228c9862ca8e8eb91cde1c43e043a8304075f871691da63bf216", "apple-restore"
        ])

        let merge = SGEntitlementDeviceProof.message(mode: .bindMerge, deviceId: self.deviceId, spkiDER: self.vectorSPKI, nonce: self.nonce, timestamp: self.timestamp, payload: self.pollToken)
        XCTAssertEqual(merge.map { String(decoding: $0, as: UTF8.self) }, [
            "zenlypay-device-proof-v1", "POST", "/v1/bind/poll", self.deviceId,
            "8dcf31a3ae6172b1df2b27702790897f2533ecd95c5dac56c39149fc2dd4cc7f", self.nonce, "1790000000",
            "ac96bd139816706f6379835ae8ecfa2f971381f25f48444eacdc541d8a1e611c", "bind-merge"
        ].joined(separator: "\n"))
    }

    /// The BACKEND's shared fixture (`zenlypay tests/Fixtures/device-proof-vectors.json`), embedded
    /// verbatim: the client must produce these canonical messages byte for byte, including the
    /// UTF-8 hashing of a non-ASCII payload ("π"). Public key only; no private key exists.
    private static let sharedVectorsJSON = #"""
{
  "description": "Synthetic canonical-message vectors; ephemeral public key only, private key discarded. Payloads are message fixtures, not valid Apple receipts.",
  "vectors": [
    {
      "mode": "apple-orphan",
      "path": "/v1/apple/attach",
      "device_id": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "device_pubkey": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEq4XO8PhXlPk7EEVNz+80iA4OOq8L6UvxiSIlnWoPE19/vAbZeYTWrTRSFhLfVp9pv7+i39dKuZDMy+Sx93W6vA==",
      "key_sha256": "506d396f2bcbb23f8003b39117b1dc66b9f64dcadbde5bd562e3e2aa2384dbf9",
      "nonce": "fixture-nonce-0123456789abcdef",
      "timestamp": "1791806400",
      "payload": "fixture-receipt-π",
      "canonical_message": "zenlypay-device-proof-v1\nPOST\n/v1/apple/attach\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n506d396f2bcbb23f8003b39117b1dc66b9f64dcadbde5bd562e3e2aa2384dbf9\nfixture-nonce-0123456789abcdef\n1791806400\nbb8deceded8e0c445645766962e1b614063ac2834390d47e97fbf3a08178f062\napple-orphan"
    },
    {
      "mode": "apple-restore",
      "path": "/v1/apple/attach",
      "device_id": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "device_pubkey": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEq4XO8PhXlPk7EEVNz+80iA4OOq8L6UvxiSIlnWoPE19/vAbZeYTWrTRSFhLfVp9pv7+i39dKuZDMy+Sx93W6vA==",
      "key_sha256": "506d396f2bcbb23f8003b39117b1dc66b9f64dcadbde5bd562e3e2aa2384dbf9",
      "nonce": "fixture-nonce-0123456789abcdef",
      "timestamp": "1791806400",
      "payload": "fixture-receipt-π",
      "canonical_message": "zenlypay-device-proof-v1\nPOST\n/v1/apple/attach\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n506d396f2bcbb23f8003b39117b1dc66b9f64dcadbde5bd562e3e2aa2384dbf9\nfixture-nonce-0123456789abcdef\n1791806400\nbb8deceded8e0c445645766962e1b614063ac2834390d47e97fbf3a08178f062\napple-restore"
    },
    {
      "mode": "bind-merge",
      "path": "/v1/bind/poll",
      "device_id": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "device_pubkey": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEq4XO8PhXlPk7EEVNz+80iA4OOq8L6UvxiSIlnWoPE19/vAbZeYTWrTRSFhLfVp9pv7+i39dKuZDMy+Sx93W6vA==",
      "key_sha256": "506d396f2bcbb23f8003b39117b1dc66b9f64dcadbde5bd562e3e2aa2384dbf9",
      "nonce": "fixture-nonce-0123456789abcdef",
      "timestamp": "1791806400",
      "payload": "poll-token-fixture-0123456789abcdef",
      "canonical_message": "zenlypay-device-proof-v1\nPOST\n/v1/bind/poll\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n506d396f2bcbb23f8003b39117b1dc66b9f64dcadbde5bd562e3e2aa2384dbf9\nfixture-nonce-0123456789abcdef\n1791806400\n3edb03fee46573f4616aeb927c94ad3ee63ecc67e47d68a77bc9f6a8c70d5a41\nbind-merge"
    },
    {
      "mode": "bind-attest",
      "path": "/v1/bind/attest",
      "device_id": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "device_pubkey": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEq4XO8PhXlPk7EEVNz+80iA4OOq8L6UvxiSIlnWoPE19/vAbZeYTWrTRSFhLfVp9pv7+i39dKuZDMy+Sx93W6vA==",
      "key_sha256": "506d396f2bcbb23f8003b39117b1dc66b9f64dcadbde5bd562e3e2aa2384dbf9",
      "nonce": "fixture-nonce-0123456789abcdef",
      "timestamp": "1791806400",
      "payload": "{\"poll_token\":\"poll-token-fixture-0123456789abcdef\",\"init_data\":\"user=%7B%22id%22%3A555000111%7D&auth_date=1791806400&start_param=zbABCDEFGH&signature=fixture&hash=fixture\"}",
      "canonical_message": "zenlypay-device-proof-v1\nPOST\n/v1/bind/attest\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n506d396f2bcbb23f8003b39117b1dc66b9f64dcadbde5bd562e3e2aa2384dbf9\nfixture-nonce-0123456789abcdef\n1791806400\n03680f82e67d4df7b1cac0c10f7ee4c35a5c0de8bacd51e1bca64a23a7f71cd9\nbind-attest"
    }
  ]
}
"""#

    func test_backendSharedVectors_matchByteForByte() throws {
        struct Fixture: Decodable {
            struct Vector: Decodable {
                let mode: String
                let path: String
                let device_id: String
                let device_pubkey: String
                let key_sha256: String
                let nonce: String
                let timestamp: String
                let payload: String
                let canonical_message: String
            }
            let vectors: [Vector]
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(SGEntitlementDeviceProofTests.sharedVectorsJSON.utf8))
        XCTAssertEqual(Set(fixture.vectors.map { $0.mode }), Set(SGEntitlementDeviceProofMode.allCases.map { $0.rawValue }), "every mode has a shared vector")
        for vector in fixture.vectors {
            let mode = try XCTUnwrap(SGEntitlementDeviceProofMode(rawValue: vector.mode))
            XCTAssertEqual(mode.canonicalPath, vector.path)
            let der = try XCTUnwrap(Data(base64Encoded: vector.device_pubkey), "device_pubkey is standard base64")
            XCTAssertNotNil(SGEntitlementCrypto.p256X963(fromSPKI: der), "device_pubkey is a P-256 SPKI DER the client itself would send")
            XCTAssertEqual(SGEntitlementDeviceProof.sha256Hex(der), vector.key_sha256)
            let timestamp = try XCTUnwrap(Int64(vector.timestamp))
            let message = try XCTUnwrap(SGEntitlementDeviceProof.message(mode: mode, deviceId: vector.device_id, spkiDER: der, nonce: vector.nonce, timestamp: timestamp, payload: vector.payload))
            XCTAssertEqual(message, Data(vector.canonical_message.utf8), "client canonical message differs from the backend's for \(vector.mode)")
        }
    }

    func test_canonicalMessage_refusesFieldsThatWouldForgeLines() {
        XCTAssertNil(SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: "id\nPOST", spkiDER: self.vectorSPKI, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt))
        XCTAssertNil(SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: self.deviceId, spkiDER: self.vectorSPKI, nonce: "n\r", timestamp: self.timestamp, payload: self.receipt))
        XCTAssertNil(SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: "", spkiDER: self.vectorSPKI, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt))
        XCTAssertNil(SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: self.deviceId, spkiDER: Data(), nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt))
        XCTAssertNil(SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: self.deviceId, spkiDER: self.vectorSPKI, nonce: self.nonce, timestamp: self.timestamp, payload: ""), "an empty receipt / poll token binds nothing")
        XCTAssertNil(SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: self.deviceId, spkiDER: self.vectorSPKI, nonce: self.nonce, timestamp: -1, payload: self.receipt))
    }

    func test_proofVerifiesOnlyForItsExactPathModeAndPayload() {
        let key = P256.Signing.PrivateKey()
        let spki = SGEntitlementCrypto.p256SPKI(fromX963: key.publicKey.x963Representation)!
        guard let material = SGEntitlementDeviceProof.make(mode: .appleOrphan, deviceId: self.deviceId, nonce: self.nonce, timestamp: self.timestamp, spkiDER: spki, payload: self.receipt, includeDeviceAuth: false, sign: { try key.signature(for: $0).rawRepresentation }) else {
            return XCTFail("proof not produced")
        }
        // Standard base64 with padding, 64-byte r||s, like X-Device-Sig.
        guard let raw = Data(base64Encoded: material.proof), let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else {
            return XCTFail("proof is not standard base64 of a raw P-256 signature")
        }
        XCTAssertEqual(raw.count, 64)
        XCTAssertEqual(material.publicKeySPKIBase64, spki.base64EncodedString(), "device_pubkey must be the key that signed")

        let exact = SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: self.deviceId, spkiDER: spki, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt)!
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: exact))
        // The proof cannot move to another mode / path, another receipt, a poll token or a nonce.
        let moved: [Data?] = [
            SGEntitlementDeviceProof.message(mode: .appleRestore, deviceId: self.deviceId, spkiDER: spki, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt),
            SGEntitlementDeviceProof.message(mode: .bindMerge, deviceId: self.deviceId, spkiDER: spki, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt),
            SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: self.deviceId, spkiDER: spki, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt + "x"),
            SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: self.deviceId, spkiDER: spki, nonce: "ffeeddccbbaa99887766554433221100", timestamp: self.timestamp, payload: self.receipt),
            SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: String(repeating: "1e", count: 32), spkiDER: spki, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt),
            SGEntitlementDeviceProof.message(mode: .appleOrphan, deviceId: self.deviceId, spkiDER: self.vectorSPKI, nonce: self.nonce, timestamp: self.timestamp, payload: self.receipt)
        ]
        for message in moved {
            XCTAssertFalse(key.publicKey.isValidSignature(signature, for: message!), "proof verified for a different request")
        }

        // A copied public key without the private key cannot produce a proof that verifies.
        let attacker = P256.Signing.PrivateKey()
        let forged = SGEntitlementDeviceProof.make(mode: .appleOrphan, deviceId: self.deviceId, nonce: self.nonce, timestamp: self.timestamp, spkiDER: spki, payload: self.receipt, includeDeviceAuth: false, sign: { try attacker.signature(for: $0).rawRepresentation })!
        let forgedSignature = try! P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: forged.proof)!)
        XCTAssertFalse(key.publicKey.isValidSignature(forgedSignature, for: exact))
    }

    func test_headers_anonymousCarryNoDeviceAuth_restoreCarriesBothOverOneNonce() {
        let key = P256.Signing.PrivateKey()
        let spki = SGEntitlementCrypto.p256SPKI(fromX963: key.publicKey.x963Representation)!
        let anonymous = SGEntitlementDeviceProof.make(mode: .appleOrphan, deviceId: self.deviceId, nonce: self.nonce, timestamp: self.timestamp, spkiDER: spki, payload: self.receipt, includeDeviceAuth: false, sign: { try key.signature(for: $0).rawRepresentation })!
        XCTAssertEqual(Set(anonymous.headers.keys), ["X-Device-Id", "X-Device-Nonce", "X-Device-Ts", "X-Device-Proof"])
        XCTAssertEqual(anonymous.headers["X-Device-Ts"], "1790000000")

        let restore = SGEntitlementDeviceProof.make(mode: .appleRestore, deviceId: self.deviceId, nonce: self.nonce, timestamp: self.timestamp, spkiDER: spki, payload: self.receipt, includeDeviceAuth: true, sign: { try key.signature(for: $0).rawRepresentation })!
        XCTAssertEqual(Set(restore.headers.keys), ["X-Device-Id", "X-Device-Nonce", "X-Device-Ts", "X-Device-Sig", "X-Device-Proof"])
        // The unchanged DeviceAuth message, over the same nonce and timestamp.
        let deviceAuth = try! P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: restore.headers["X-Device-Sig"]!)!)
        XCTAssertTrue(key.publicKey.isValidSignature(deviceAuth, for: Data("\(self.deviceId)\n\(self.nonce)\n\(self.timestamp)".utf8)))
        XCTAssertNotEqual(restore.headers["X-Device-Sig"], restore.headers["X-Device-Proof"])
    }

    /// The absence boundary (2026-10-12): `device_pubkey` and `X-Device-Proof` travel together or not
    /// at all, and a new client never downgrades to the legacy unsigned anonymous path.
    func test_anonymousAttach_sendsKeyAndProofAtomically_neverLegacy() {
        // No material (no key, RNG or signing failure): nothing is composed — the caller fails the
        // attempt as transient and retries; it never sends bare X-Device-Id/Nonce/Ts.
        XCTAssertNil(SGEntitlementDeviceProof.anonymousAttachCredentials(nil))

        let key = P256.Signing.PrivateKey()
        let spki = SGEntitlementCrypto.p256SPKI(fromX963: key.publicKey.x963Representation)!
        let material = SGEntitlementDeviceProof.make(mode: .appleOrphan, deviceId: self.deviceId, nonce: self.nonce, timestamp: self.timestamp, spkiDER: spki, payload: self.receipt, includeDeviceAuth: false, sign: { try key.signature(for: $0).rawRepresentation })!
        guard let composed = SGEntitlementDeviceProof.anonymousAttachCredentials(material) else {
            return XCTFail("valid material was not composed")
        }
        XCTAssertFalse(composed.devicePubkey.isEmpty)
        XCTAssertEqual(composed.devicePubkey, spki.base64EncodedString())
        XCTAssertEqual(composed.headers["X-Device-Proof"], material.proof)
        XCTAssertFalse(composed.headers["X-Device-Proof"]?.isEmpty ?? true)
        XCTAssertNil(composed.headers["X-Device-Sig"], "an anonymous attach carries no DeviceAuth")

        // Material for another mode, an empty proof or an empty key is never sent as an orphan proof.
        let restore = SGEntitlementDeviceProof.make(mode: .appleRestore, deviceId: self.deviceId, nonce: self.nonce, timestamp: self.timestamp, spkiDER: spki, payload: self.receipt, includeDeviceAuth: true, sign: { try key.signature(for: $0).rawRepresentation })!
        XCTAssertNil(SGEntitlementDeviceProof.anonymousAttachCredentials(restore), "a DeviceAuth-bearing material is not anonymous")
        let emptyProof = SGEntitlementDeviceProofMaterial(deviceId: self.deviceId, nonce: self.nonce, timestamp: self.timestamp, publicKeySPKIBase64: spki.base64EncodedString(), proof: "", deviceAuthSignature: nil)
        XCTAssertNil(SGEntitlementDeviceProof.anonymousAttachCredentials(emptyProof))
        let emptyKey = SGEntitlementDeviceProofMaterial(deviceId: self.deviceId, nonce: self.nonce, timestamp: self.timestamp, publicKeySPKIBase64: "", proof: material.proof, deviceAuthSignature: nil)
        XCTAssertNil(SGEntitlementDeviceProof.anonymousAttachCredentials(emptyKey))
    }

    func test_bindPoll_preparation_neverPollsWithAKnownDifferentKey() {
        let registeredKey = P256.Signing.PrivateKey()
        let registeredSPKI = SGEntitlementCrypto.p256SPKI(fromX963: registeredKey.publicKey.x963Representation)!.base64EncodedString()
        let otherKey = P256.Signing.PrivateKey()
        let otherSPKI = SGEntitlementCrypto.p256SPKI(fromX963: otherKey.publicKey.x963Representation)!
        func material(_ key: P256.Signing.PrivateKey) -> SGEntitlementDeviceProofMaterial? {
            let spki = SGEntitlementCrypto.p256SPKI(fromX963: key.publicKey.x963Representation)!
            return SGEntitlementDeviceProof.make(mode: .bindMerge, deviceId: self.deviceId, nonce: self.nonce, timestamp: self.timestamp, spkiDER: spki, payload: self.pollToken, includeDeviceAuth: false, sign: { try key.signature(for: $0).rawRepresentation })
        }
        var signed = 0

        // The registered key signs: prove.
        guard case let .prove(headers) = SGEntitlementDeviceProof.prepareBindPoll(registeredPublicKey: registeredSPKI, currentPublicKey: registeredSPKI, makeMaterial: { signed += 1; return material(registeredKey) }) else {
            return XCTFail("the registered key did not prove")
        }
        XCTAssertFalse(headers["X-Device-Proof"]?.isEmpty ?? true)

        // A KNOWN different install key: the server would issue the session for the OLD key, which
        // this install can no longer sign with. Restart the bind with the current key; nothing is
        // signed or sent, so the old poll is not consumed. Never a proofless poll.
        signed = 0
        XCTAssertEqual(SGEntitlementDeviceProof.prepareBindPoll(registeredPublicKey: registeredSPKI, currentPublicKey: otherSPKI.base64EncodedString(), makeMaterial: { signed += 1; return material(otherKey) }), .restartBind)
        XCTAssertEqual(signed, 0)
        // The key changed between the check and the signature: also a restart, never a send.
        XCTAssertEqual(SGEntitlementDeviceProof.prepareBindPoll(registeredPublicKey: registeredSPKI, currentPublicKey: registeredSPKI, makeMaterial: { material(otherKey) }), .restartBind)

        // The key is unavailable (locked Keychain) or signing failed: retry later, sending nothing.
        XCTAssertEqual(SGEntitlementDeviceProof.prepareBindPoll(registeredPublicKey: registeredSPKI, currentPublicKey: nil, makeMaterial: { material(registeredKey) }), .retryLater)
        XCTAssertEqual(SGEntitlementDeviceProof.prepareBindPoll(registeredPublicKey: registeredSPKI, currentPublicKey: registeredSPKI, makeMaterial: { nil }), .retryLater)

        // Only a start with no registration metadata at all (legacy) polls proofless.
        XCTAssertEqual(SGEntitlementDeviceProof.prepareBindPoll(registeredPublicKey: nil, currentPublicKey: registeredSPKI, makeMaterial: { material(registeredKey) }), .proofless)
        XCTAssertEqual(SGEntitlementDeviceProof.prepareBindPoll(registeredPublicKey: "", currentPublicKey: registeredSPKI, makeMaterial: { material(registeredKey) }), .proofless)
    }

    func test_bindMergeProofOnlyWithTheKeyBindStartRegistered() {
        XCTAssertTrue(SGEntitlementDeviceProof.canProveBindMerge(currentPublicKey: "AAA=", registeredPublicKey: "AAA="))
        XCTAssertFalse(SGEntitlementDeviceProof.canProveBindMerge(currentPublicKey: "BBB=", registeredPublicKey: "AAA="), "a regenerated key would make the server reject the poll; send it proofless instead")
        XCTAssertFalse(SGEntitlementDeviceProof.canProveBindMerge(currentPublicKey: "AAA=", registeredPublicKey: nil))
        XCTAssertFalse(SGEntitlementDeviceProof.canProveBindMerge(currentPublicKey: nil, registeredPublicKey: "AAA="))
    }
}
