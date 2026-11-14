import XCTest
import CryptoKit
import Security
@testable import SGEntitlement

/// Zenlygram — bind-attest v1 (Telegram-signed Mini App `initData` confirms a bind without a code).
/// Covers the client half that decides whether to try it, what it takes out of Telegram's answer,
/// and the exact bytes it sends and signs. Every value is synthetic; no real `initData` or token.
final class SGEntitlementBindAttestTests: XCTestCase {
    private let attest = SGEntitlementBindAttest(botId: "8804541158", botUsername: "ZenlyPremiumbot", startParam: "zbABCDEFGH")

    private func decodeStart(_ json: String) throws -> SGEntitlementBindStart {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SGEntitlementBindStart.self, from: Data(json.utf8))
    }

    // MARK: - /bind/start `attest`

    func test_bindStartDecodesTheAttestBlock() throws {
        let start = try self.decodeStart("""
        {"code":"ABCDEFGH","deeplink":"https://t.me/ZenlyPremiumbot?start=bABCDEFGH","poll_token":"p","expires_at":"2030-01-01T00:00:00Z",
         "attest":{"bot_id":"8804541158","bot_username":"ZenlyPremiumbot","start_param":"zbABCDEFGH","url":"https://zenlygram.org/app"}}
        """)
        XCTAssertEqual(start.attest, self.attest)
        XCTAssertEqual(start.validatedAttest, self.attest)
        XCTAssertEqual(start.code, "ABCDEFGH", "existing fields are unchanged")
    }

    func test_aMissingNullOrMalformedAttestStillDecodesTheStartAndFallsBack() throws {
        let missing = try self.decodeStart(#"{"code":"ABCDEFGH","deeplink":null,"poll_token":"p","expires_at":"2030-01-01T00:00:00Z"}"#)
        XCTAssertNil(missing.attest)
        XCTAssertNil(missing.validatedAttest)
        let null = try self.decodeStart(#"{"code":"ABCDEFGH","poll_token":"p","expires_at":"2030-01-01T00:00:00Z","attest":null}"#)
        XCTAssertNil(null.validatedAttest)
        // A numeric bot id is not the contract's string: the start still works, by code.
        let malformed = try self.decodeStart(#"{"code":"ABCDEFGH","poll_token":"p","expires_at":"2030-01-01T00:00:00Z","attest":{"bot_id":8804541158,"bot_username":"ZenlyPremiumbot","start_param":"zbABCDEFGH","url":"https://127.0.0.1/app"}}"#)
        XCTAssertEqual(malformed.pollToken, "p")
        XCTAssertNil(malformed.validatedAttest)
    }

    func test_onlyAWellFormedAttestIsTried() {
        XCTAssertTrue(self.attest.isWellFormed)
        XCTAssertEqual(self.attest.botUserId, 8_804_541_158)
        func with(botId: String? = nil, username: String? = nil, startParam: String? = nil) -> SGEntitlementBindAttest {
            return SGEntitlementBindAttest(botId: botId ?? self.attest.botId, botUsername: username ?? self.attest.botUsername, startParam: startParam ?? self.attest.startParam)
        }
        for botId in ["", "0", "-5", "+5", "12a", "9007199254740992", "١٢٣", " 5"] {
            XCTAssertFalse(with(botId: botId).isWellFormed, "bot id \(botId)")
        }
        XCTAssertTrue(with(botId: "9007199254740991").isWellFormed, "2^53-1 is a valid user id")
        for username in ["", "abcd", "1abcd", "bad-name", "bad name", "a" + String(repeating: "b", count: 32), "@ZenlyPremiumbot"] {
            XCTAssertFalse(with(username: username).isWellFormed, "username \(username)")
        }
        for startParam in ["", "zb!", "zb ABC", String(repeating: "a", count: 65), "zb/../x"] {
            XCTAssertFalse(with(startParam: startParam).isWellFormed, "start_param \(startParam)")
        }
        XCTAssertTrue(with(startParam: String(repeating: "a", count: 64)).isWellFormed)
        // The server's `url` is not used by requestMainWebView, so it never decides anything.
        let anyURL = try? self.decodeStart(#"{"code":"ABCDEFGH","poll_token":"p","expires_at":"2030-01-01T00:00:00Z","attest":{"bot_id":"8804541158","bot_username":"ZenlyPremiumbot","start_param":"zbABCDEFGH","url":"http://127.0.0.1"}}"#)
        XCTAssertEqual(anyURL?.validatedAttest, self.attest)
    }

    func test_onlyTheResolvedBotWithTheAdvertisedIdAndAMainAppIsAsked() {
        XCTAssertTrue(self.attest.matchesResolvedBot(userId: 8_804_541_158, isBot: true, hasMainApp: true))
        XCTAssertFalse(self.attest.matchesResolvedBot(userId: 8_804_541_158, isBot: true, hasMainApp: false), "no Main Mini App (bot_has_main_app false): the code flow at once")
        XCTAssertFalse(self.attest.matchesResolvedBot(userId: 8_804_541_158, isBot: false, hasMainApp: true), "a user who took the username is not the bot")
        XCTAssertFalse(self.attest.matchesResolvedBot(userId: 1_234, isBot: true, hasMainApp: true), "another bot behind the username")
        XCTAssertFalse(self.attest.matchesResolvedBot(userId: nil, isBot: true, hasMainApp: true), "not resolved")
        let unusable = SGEntitlementBindAttest(botId: "x", botUsername: "ZenlyPremiumbot", startParam: "zbA")
        XCTAssertFalse(unusable.matchesResolvedBot(userId: 0, isBot: true, hasMainApp: true))
    }

    // MARK: - tgWebAppData

    /// Telegram's URL: `tgWebAppData` is the percent-encoded initData, whose own values are
    /// percent-encoded once more (`user=%7B…`). Decoding ONCE yields the form-urlencoded initData.
    func test_initDataIsTheFragmentParameterPercentDecodedExactlyOnce() {
        let initData = "query_id=AAH1&user=%7B%22id%22%3A42%2C%22first_name%22%3A%22%D0%90%22%7D&auth_date=1791806400&start_param=zbABCDEFGH&signature=Ab-_Cd&hash=0f1e"
        let encoded = initData.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        XCTAssertTrue(encoded.contains("%257B"), "premise: the inner encoding is encoded again")
        let url = "https://127.0.0.1/app?tgWebAppStartParam=zbABCDEFGH#tgWebAppData=\(encoded)&tgWebAppVersion=9.1&tgWebAppPlatform=ios&tgWebAppThemeParams=%7B%7D"
        XCTAssertEqual(SGEntitlementBindAttest.initData(fromWebAppURL: url), initData)
        // The parameter's position in the fragment does not matter.
        XCTAssertEqual(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app#tgWebAppVersion=9.1&tgWebAppData=\(encoded)"), initData)
    }

    func test_initDataIsNilForAnythingButOneUsableParameter() {
        XCTAssertNil(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app"), "no fragment")
        XCTAssertNil(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app?tgWebAppData=a%3Db"), "the query is not the fragment")
        XCTAssertNil(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app#tgWebAppVersion=9.1"), "missing")
        XCTAssertNil(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app#tgWebAppData="), "empty")
        XCTAssertNil(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app#tgWebAppData"), "no value")
        XCTAssertNil(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app#tgWebAppDataX=a%3Db"), "another key")
        XCTAssertNil(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app#tgWebAppData=a%3Db&tgWebAppData=c%3Dd"), "ambiguous duplicate")
        XCTAssertNil(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app#tgWebAppData=a%ZZb"), "invalid percent encoding")
        let large = String(repeating: "a", count: SGEntitlementBindAttest.maxInitDataBytes + 1)
        XCTAssertNil(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app#tgWebAppData=\(large)"), "larger than /bind/attest accepts")
        let fits = String(repeating: "a", count: SGEntitlementBindAttest.maxInitDataBytes)
        XCTAssertEqual(SGEntitlementBindAttest.initData(fromWebAppURL: "https://127.0.0.1/app#tgWebAppData=\(fits)"), fits)
    }

    // MARK: - /bind/attest body and proof

    func test_attestBodyCarriesThePollTokenAndInitDataUnchanged() throws {
        let initData = "user=%7B%22id%22%3A555000111%7D&auth_date=1791806400&start_param=zbABCDEFGH&signature=a/b+c&hash=fixture"
        let body = try XCTUnwrap(SGEntitlementDeviceProof.bindAttestBody(pollToken: "poll-token-fixture", initData: initData))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["poll_token": "poll-token-fixture", "init_data": initData], "nothing else, nothing re-encoded")
        XCTAssertNil(SGEntitlementDeviceProof.bindAttestBody(pollToken: "p", initData: String(repeating: "a", count: SGEntitlementDeviceProof.maxBindAttestBodyBytes)), "over 8 KiB is never sent")
    }

    /// The server hashes the raw body BYTES; the proof must sign exactly those bytes for
    /// `/v1/bind/attest` in mode `bind-attest`, and verify only for them.
    func test_attestProofSignsTheExactRawBodyForItsOwnPathAndMode() throws {
        let key = P256.Signing.PrivateKey()
        let spki = try XCTUnwrap(SGEntitlementCrypto.p256SPKI(fromX963: key.publicKey.x963Representation))
        let deviceId = String(repeating: "0f", count: 32)
        let body = try XCTUnwrap(SGEntitlementDeviceProof.bindAttestBody(pollToken: "poll-token-fixture", initData: "user=%7B%22first_name%22%3A%22%CF%80%22%7D&hash=x"))
        let material = try XCTUnwrap(SGEntitlementDeviceProof.make(mode: .bindAttest, deviceId: deviceId, nonce: "n1", timestamp: 1_791_806_400, spkiDER: spki, payload: SGEntitlementDeviceProof.payload(forRawBody: body), includeDeviceAuth: false, sign: { try key.signature(for: $0).rawRepresentation }))
        XCTAssertNil(material.deviceAuthSignature, "no X-Device-Sig on attest")
        XCTAssertNil(material.headers["X-Device-Sig"])

        // What the server rebuilds from the request: path, mode and sha256 of the raw bytes.
        let lines = [
            "zenlypay-device-proof-v1", "POST", "/v1/bind/attest", deviceId,
            SGEntitlementDeviceProof.sha256Hex(spki), "n1", "1791806400",
            SGEntitlementDeviceProof.sha256Hex(body), "bind-attest"
        ]
        let serverMessage = Data(lines.joined(separator: "\n").utf8)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Data(base64Encoded: material.proof)))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: serverMessage))

        var tampered = body
        tampered.append(0x20)
        let tamperedMessage = Data((lines.dropLast(2) + [SGEntitlementDeviceProof.sha256Hex(tampered), "bind-attest"]).joined(separator: "\n").utf8)
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: tamperedMessage), "one changed body byte must invalidate the proof")
        let asPoll = Data(lines.enumerated().map { $0.offset == 2 ? "/v1/bind/poll" : ($0.offset == 8 ? "bind-merge" : $0.element) }.joined(separator: "\n").utf8)
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: asPoll), "an attest proof is not a poll proof")
    }

    // MARK: - The client never sends an unproven attest

    func test_withoutTheRegisteredKeyNothingIsSent() async {
        let origin = "api.attest.zenlygram.invalid"
        let suite = "SGEntitlementBindAttestTests.\(UUID().uuidString)"
        defer {
            SGPolicyStubProtocol.reset(routes: [:])
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        SGPolicyStubProtocol.reset(routes: [
            origin: SGPolicyStubProtocol.Route(headers: ["Content-Type": "application/json"], chunks: [SGPolicyStubProtocol.json(["schema_version": 1, "state": "confirmed", "server_time": "2026-10-29T00:00:00Z"])])
        ])
        let store = SGEntitlementStore(
            defaults: UserDefaults(suiteName: suite),
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecMissingEntitlement },
                delete: { _ in }
            )
        )
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://\(origin)/v1")!)
        configuration.protocolClasses = [SGPolicyStubProtocol.self]
        let client = SGEntitlementClient(configuration: configuration, store: store)

        let result = await client.bindAttest(pollToken: "poll-token-fixture", registeredPublicKey: nil, initData: "user=%7B%7D&hash=x")
        if case .success = result {
            XCTFail("an attest without the bind key's proof must not succeed")
        }
        XCTAssertTrue(SGPolicyStubProtocol.requests.isEmpty, "the proof is mandatory: nothing may leave without it")
    }
}
