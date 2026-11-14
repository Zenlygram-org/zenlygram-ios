import Foundation
import CryptoKit

/// Zenlygram — a bind whose install key changed after `/bind/start` (Keychain loss, a
/// `device_key_mismatch` regeneration). The server issues the bind's session for the key the START
/// registered, so polling with another key — even proofless — consumes the bind into a session the
/// next DeviceAuth request can never authenticate. These tests drive the real client preparation
/// (`SGEntitlementDeviceProof.prepareBindPoll`), the real restart budget and real P-256 signatures
/// against a server model that verifies exactly what the backend verifies.

/// The backend's bind contract, reduced to what this boundary depends on.
private final class BindServer {
    struct Session {
        let devicePublicKeySPKI: Data
    }

    private var registeredKeys: [String: Data] = [:]
    private(set) var consumedPolls = 0
    private(set) var rejectedProofs = 0
    private var counter = 0

    /// `/bind/start`: stores the presented key with the new poll token.
    func start(devicePublicKeySPKI: Data) -> String {
        self.counter += 1
        let token = "poll-token-\(self.counter)"
        self.registeredKeys[token] = devicePublicKeySPKI
        return token
    }

    /// `/bind/poll` after the bot confirmed: a present proof is verified against the STORED key
    /// before anything is consumed; a consumed bind issues the session for the stored key.
    func poll(token: String, headers: [String: String]) -> Session? {
        guard let stored = self.registeredKeys[token] else {
            return nil
        }
        if let proof = headers["X-Device-Proof"] {
            guard let deviceId = headers["X-Device-Id"], let nonce = headers["X-Device-Nonce"],
                  let tsText = headers["X-Device-Ts"], let ts = Int64(tsText),
                  let message = SGEntitlementDeviceProof.message(mode: .bindMerge, deviceId: deviceId, spkiDER: stored, nonce: nonce, timestamp: ts, payload: token),
                  BindServer.verify(signatureBase64: proof, message: message, spki: stored)
            else {
                self.rejectedProofs += 1
                return nil
            }
        }
        self.registeredKeys.removeValue(forKey: token)
        self.consumedPolls += 1
        return Session(devicePublicKeySPKI: stored)
    }

    /// Any later DeviceAuth request (`/entitlement/refresh`): the signature must verify with the
    /// session's key.
    func refresh(session: Session, deviceId: String, nonce: String, timestamp: Int64, signatureBase64: String) -> Bool {
        return BindServer.verify(signatureBase64: signatureBase64, message: Data("\(deviceId)\n\(nonce)\n\(timestamp)".utf8), spki: session.devicePublicKeySPKI)
    }

    static func verify(signatureBase64: String, message: Data, spki: Data) -> Bool {
        guard let raw = Data(base64Encoded: signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              let point = SGEntitlementCrypto.p256X963(fromSPKI: spki),
              let key = try? P256.Signing.PublicKey(x963Representation: point)
        else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}

/// The install: one current key, which can be replaced.
private struct Install {
    let deviceId = String(repeating: "ab", count: 32)
    var key = P256.Signing.PrivateKey()

    var spki: Data {
        return SGEntitlementCrypto.p256SPKI(fromX963: self.key.publicKey.x963Representation)!
    }

    func proofMaterial(token: String) -> SGEntitlementDeviceProofMaterial? {
        let key = self.key
        return SGEntitlementDeviceProof.make(mode: .bindMerge, deviceId: self.deviceId, nonce: UUID().uuidString, timestamp: 1791806400, spkiDER: self.spki, payload: token, includeDeviceAuth: false, sign: { try key.signature(for: $0).rawRepresentation })
    }

    func deviceAuthSignature(nonce: String, timestamp: Int64) -> String {
        return try! self.key.signature(for: Data("\(self.deviceId)\n\(nonce)\n\(timestamp)".utf8)).rawRepresentation.base64EncodedString()
    }
}

private enum FlowOutcome: Equatable {
    case linked
    case failed
}

@main
struct BindKeyChangeTests {
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    /// The link screen's poll step for one confirmed bind, with the real preparation and budget.
    private static func link(server: BindServer, install: Install, registeredKey: inout Data, token: inout String, budget: inout SGLinkAccountKeyRestartBudget) -> (FlowOutcome, BindServer.Session?) {
        while true {
            let preparation = SGEntitlementDeviceProof.prepareBindPoll(
                registeredPublicKey: registeredKey.base64EncodedString(),
                currentPublicKey: install.spki.base64EncodedString(),
                makeMaterial: { install.proofMaterial(token: token) }
            )
            switch preparation {
            case let .prove(headers):
                guard let session = server.poll(token: token, headers: headers) else {
                    return (.failed, nil)
                }
                return (.linked, session)
            case .proofless:
                guard let session = server.poll(token: token, headers: [:]) else {
                    return (.failed, nil)
                }
                return (.linked, session)
            case .restartBind:
                guard budget.consumeRestart() else {
                    return (.failed, nil)
                }
                // A fresh /bind/start with the CURRENT key (the user confirms the new code).
                registeredKey = install.spki
                token = server.start(devicePublicKeySPKI: registeredKey)
            case .retryLater:
                return (.failed, nil)
            }
        }
    }

    static func main() {
        // 1. The key changes between /bind/start and the poll.
        let server = BindServer()
        var install = Install()
        var registeredKey = install.spki
        var token = server.start(devicePublicKeySPKI: registeredKey)
        let oldToken = token
        install.key = P256.Signing.PrivateKey()   // regenerated / lost

        // What a proofless poll would have done: the bind is consumed into a session for the OLD
        // key, and the very next DeviceAuth request from this install cannot authenticate.
        let shadowServer = BindServer()
        let shadowToken = shadowServer.start(devicePublicKeySPKI: registeredKey)
        let unusable = shadowServer.poll(token: shadowToken, headers: [:])!
        check(!shadowServer.refresh(session: unusable, deviceId: install.deviceId, nonce: "n1", timestamp: 1791806400, signatureBase64: install.deviceAuthSignature(nonce: "n1", timestamp: 1791806400)), "test premise: an old-key session is unusable after the key changed")

        var budget = SGLinkAccountKeyRestartBudget()
        let (outcome, session) = self.link(server: server, install: install, registeredKey: &registeredKey, token: &token, budget: &budget)
        check(outcome == .linked, "the bind did not complete under the current key")
        check(token != oldToken, "the flow polled the old start instead of restarting")
        check(server.consumedPolls == 1, "exactly the fresh bind is consumed")
        check(server.rejectedProofs == 0, "a proof was sent under a key the server could not accept")
        check(server.poll(token: oldToken, headers: [:]) != nil, "the old poll was consumed on mismatch (it must remain untouched)")
        check(session!.devicePublicKeySPKI == install.spki, "the session is not bound to the install's current key")
        check(server.refresh(session: session!, deviceId: install.deviceId, nonce: "n2", timestamp: 1791806401, signatureBase64: install.deviceAuthSignature(nonce: "n2", timestamp: 1791806401)), "refresh after the fresh-key bind did not authenticate")
        print("PASS: a changed key restarts the bind without consuming the old poll; the fresh-key session refreshes")

        // 2. Unchanged key: one proven poll, no restart.
        let steadyServer = BindServer()
        let steady = Install()
        var steadyKey = steady.spki
        var steadyToken = steadyServer.start(devicePublicKeySPKI: steadyKey)
        var steadyBudget = SGLinkAccountKeyRestartBudget()
        let (steadyOutcome, steadySession) = self.link(server: steadyServer, install: steady, registeredKey: &steadyKey, token: &steadyToken, budget: &steadyBudget)
        check(steadyOutcome == .linked && steadyBudget.used == 0 && steadyServer.consumedPolls == 1, "an unchanged key restarted or polled twice")
        check(steadyServer.refresh(session: steadySession!, deviceId: steady.deviceId, nonce: "n3", timestamp: 1791806402, signatureBase64: steady.deviceAuthSignature(nonce: "n3", timestamp: 1791806402)), "refresh after the steady-key bind did not authenticate")
        print("PASS: an unchanged key links with one proven poll")

        // 3. The budget ends a flow whose key keeps changing, without consuming anything.
        var exhausted = SGLinkAccountKeyRestartBudget()
        check(exhausted.consumeRestart(), "the first restart was refused")
        check(!exhausted.consumeRestart(), "the restart budget is unbounded")
        let loopServer = BindServer()
        var looping = Install()
        var loopKey = looping.spki
        var loopToken = loopServer.start(devicePublicKeySPKI: loopKey)
        looping.key = P256.Signing.PrivateKey()
        let (loopOutcome, _) = self.link(server: loopServer, install: looping, registeredKey: &loopKey, token: &loopToken, budget: &exhausted)
        check(loopOutcome == .failed && loopServer.consumedPolls == 0, "an exhausted budget polled with the wrong key")
        exhausted.reset()
        check(exhausted.used == 0, "reset did not restore the budget")
        print("PASS: restarts are bounded and consume nothing")
    }
}
