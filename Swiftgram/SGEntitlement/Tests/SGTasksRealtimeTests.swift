import XCTest
@testable import SGEntitlement

/// Zenlygram — the Tasks realtime wire (`x-realtime`, consumer contract 2ac6d7d8…) and the Pusher
/// protocol 7 socket lifecycle, through a deterministic scheduler and a scripted WebSocket. Every
/// assertion is about what the client accepted, sent, reported or refused.
final class SGTasksRealtimeTests: XCTestCase {
    private let apiBaseURL = URL(string: "https://tasks.zenlygram.test/v1")!
    private let key = "appkey20charsxyz0123"
    private let channel = "private-tasks." + String(repeating: "A", count: 42) + "_"
    private var signature: String {
        return String(repeating: "0123456789abcdef", count: 4)
    }
    private var auth: String {
        return self.key + ":" + self.signature
    }

    // MARK: - Endpoint

    func test_theEndpointIsRebuiltFromTheOriginAndTheValidatedKeyOnly() throws {
        let endpoint = try XCTUnwrap(SGTasksRealtime.Endpoint(wsURL: "wss://tasks.zenlygram.test/realtime/app/\(self.key)", apiBaseURL: self.apiBaseURL))
        XCTAssertEqual(endpoint.url.absoluteString, "wss://tasks.zenlygram.test/realtime/app/\(self.key)?protocol=7&client=zenlygram-ios&version=1.0&flash=false")
        XCTAssertEqual(endpoint.origin, "https://tasks.zenlygram.test")
        XCTAssertFalse(String(describing: endpoint).contains(self.key), "the key never appears in a description")

        let ported = URL(string: "https://tasks.zenlygram.test:8443/v1")!
        XCTAssertNotNil(SGTasksRealtime.Endpoint(wsURL: "wss://tasks.zenlygram.test:8443/realtime/app/\(self.key)", apiBaseURL: ported))
        XCTAssertNil(SGTasksRealtime.Endpoint(wsURL: "wss://tasks.zenlygram.test/realtime/app/\(self.key)", apiBaseURL: ported), "the origin's port is part of the authority")
    }

    func test_anythingButTheExactCanonicalEndpointIsRefused() {
        let refused = [
            "ws://tasks.zenlygram.test/realtime/app/\(self.key)",
            "https://tasks.zenlygram.test/realtime/app/\(self.key)",
            "WSS://tasks.zenlygram.test/realtime/app/\(self.key)",
            "wss://TASKS.zenlygram.test/realtime/app/\(self.key)",
            "wss://evil.test/realtime/app/\(self.key)",
            "wss://tasks.zenlygram.test.evil.test/realtime/app/\(self.key)",
            "wss://sub.tasks.zenlygram.test/realtime/app/\(self.key)",
            "wss://tasks.zenlygram.test:443/realtime/app/\(self.key)",
            "wss://user@tasks.zenlygram.test/realtime/app/\(self.key)",
            "wss://user:pass@tasks.zenlygram.test/realtime/app/\(self.key)",
            "wss://tasks.zenlygram.test/realtime/app/\(self.key)?protocol=7",
            "wss://tasks.zenlygram.test/realtime/app/\(self.key)#x",
            "wss://tasks.zenlygram.test/realtime/app/\(self.key)/",
            "wss://tasks.zenlygram.test/realtime/app/\(self.key)/extra",
            "wss://tasks.zenlygram.test/realtime/app/%61pp",
            "wss://tasks.zenlygram.test/realtime/app/..",
            "wss://tasks.zenlygram.test/realtime/app/a.b",
            "wss://tasks.zenlygram.test/realtime/app/",
            "wss://tasks.zenlygram.test/app/\(self.key)",
            "wss://tasks.zenlygram.test/realtime/apps/\(self.key)",
            "wss://tasks.zenlygram.test/realtime/app/" + String(repeating: "k", count: SGTasksRealtime.maximumAppKeyLength + 1),
            "wss://tasks.zenlygram.test/realtime/app/ключ",
            " wss://tasks.zenlygram.test/realtime/app/\(self.key)",
            ""
        ]
        for raw in refused {
            XCTAssertNil(SGTasksRealtime.Endpoint(wsURL: raw, apiBaseURL: self.apiBaseURL), raw)
        }
        XCTAssertNotNil(SGTasksRealtime.Endpoint(wsURL: "wss://tasks.zenlygram.test/realtime/app/" + String(repeating: "k", count: SGTasksRealtime.maximumAppKeyLength), apiBaseURL: self.apiBaseURL))
        XCTAssertNil(SGTasksRealtime.Endpoint(wsURL: "wss://tasks.zenlygram.test/realtime/app/\(self.key)", apiBaseURL: URL(string: "http://tasks.zenlygram.test/v1")!), "no endpoint without an https origin")
        XCTAssertNil(SGTasksRealtime.Endpoint(wsURL: "wss://tasks.zenlygram.test/realtime/app/\(self.key)", apiBaseURL: URL(string: "https://tasks.zenlygram.test/v2")!))
    }

    // MARK: - Socket id and subscription

    func test_socketIdIsTwoAsciiDigitRuns() {
        XCTAssertNotNil(SGTasksRealtime.SocketId("123.456"))
        XCTAssertNotNil(SGTasksRealtime.SocketId(String(repeating: "9", count: 20) + "." + String(repeating: "1", count: 20)))
        for raw in ["", "123", "123.", ".456", "123.456.7", "12a.456", "-1.2", "1.2 ", String(repeating: "9", count: 21) + ".1", "١٢٣.٤٥٦", "１.２"] {
            XCTAssertNil(SGTasksRealtime.SocketId(raw), raw)
        }
    }

    func test_subscriptionShapeIsExact() throws {
        let socketId = try XCTUnwrap(SGTasksRealtime.SocketId("1.2"))
        XCTAssertNotNil(SGTasksRealtime.Subscription(socketId: socketId, channel: self.channel, auth: self.auth))
        let refused: [(String, String)] = [
            ("private-tasks." + String(repeating: "A", count: 42), self.auth),
            ("private-tasks." + String(repeating: "A", count: 44), self.auth),
            ("private-tasks." + String(repeating: "A", count: 42) + "=", self.auth),
            ("private-tasks." + String(repeating: "A", count: 42) + "+", self.auth),
            ("presence-tasks." + String(repeating: "A", count: 43), self.auth),
            ("private-other." + String(repeating: "A", count: 43), self.auth),
            (self.channel, self.key + ":" + self.signature.uppercased()),
            (self.channel, self.key + ":" + String(self.signature.dropLast())),
            (self.channel, self.key + ":" + self.signature + "0"),
            (self.channel, ":" + self.signature),
            (self.channel, self.signature)
        ]
        for (channel, auth) in refused {
            XCTAssertNil(SGTasksRealtime.Subscription(socketId: socketId, channel: channel, auth: auth), "\(channel) / \(auth.count)")
        }
    }

    // MARK: - Strict response decoding

    private func value(_ text: String) throws -> SGTasksJSON.Value {
        return try SGTasksJSON.parse(Data(text.utf8), maxBytes: 65536, maxDepth: 16)
    }

    func test_metadataDecodesEnabledAndDisabledExactly() throws {
        let enabled = try SGTasksRealtime.decodeMetadata(try self.value(#"{"schema_version":1,"enabled":true,"ws_url":"wss://tasks.zenlygram.test/realtime/app/\#(self.key)","activity_timeout":30,"server_time":"2026-10-25T00:00:00Z"}"#), apiBaseURL: self.apiBaseURL)
        guard case let .enabled(endpoint) = enabled.availability else {
            return XCTFail("enabled metadata")
        }
        XCTAssertEqual(endpoint.appKey, self.key)
        XCTAssertEqual(enabled.activityTimeout, 30)
        let disabled = try SGTasksRealtime.decodeMetadata(try self.value(#"{"schema_version":1,"enabled":false,"ws_url":null,"activity_timeout":30,"server_time":"2026-10-25T00:00:00Z"}"#), apiBaseURL: self.apiBaseURL)
        XCTAssertEqual(disabled.availability, .disabled)
    }

    func test_metadataRefusesEveryInconsistency() throws {
        let good = #"{"schema_version":1,"enabled":true,"ws_url":"wss://tasks.zenlygram.test/realtime/app/\#(self.key)","activity_timeout":30,"server_time":"2026-10-25T00:00:00Z"}"#
        let variants = [
            good.replacingOccurrences(of: #""schema_version":1"#, with: #""schema_version":2"#),
            good.replacingOccurrences(of: #""ws_url":"wss://tasks.zenlygram.test/realtime/app/\#(self.key)""#, with: #""ws_url":null"#),
            good.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#),
            good.replacingOccurrences(of: "tasks.zenlygram.test", with: "evil.test"),
            good.replacingOccurrences(of: #""activity_timeout":30"#, with: #""activity_timeout":9"#),
            good.replacingOccurrences(of: #""activity_timeout":30"#, with: #""activity_timeout":121"#),
            good.replacingOccurrences(of: #""activity_timeout":30"#, with: #""activity_timeout":"30""#),
            good.replacingOccurrences(of: #""activity_timeout":30,"#, with: ""),
            good.replacingOccurrences(of: #""server_time":"2026-10-25T00:00:00Z""#, with: #""server_time":"later""#),
            good.replacingOccurrences(of: #"}"#, with: #","extra":1}"#),
            good.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":1"#)
        ]
        for variant in variants {
            XCTAssertThrowsError(try SGTasksRealtime.decodeMetadata(try self.value(variant), apiBaseURL: self.apiBaseURL), variant)
        }
        XCTAssertNoThrow(try SGTasksRealtime.decodeMetadata(try self.value(good.replacingOccurrences(of: #""activity_timeout":30"#, with: #""activity_timeout":10"#)), apiBaseURL: self.apiBaseURL))
        XCTAssertNoThrow(try SGTasksRealtime.decodeMetadata(try self.value(good.replacingOccurrences(of: #""activity_timeout":30"#, with: #""activity_timeout":120"#)), apiBaseURL: self.apiBaseURL))
    }

    func test_subscriptionResponseIsBoundToItsSocketAndExact() throws {
        let socketId = try XCTUnwrap(SGTasksRealtime.SocketId("123.456"))
        let good = #"{"schema_version":1,"channel":"\#(self.channel)","auth":"\#(self.auth)","server_time":"2026-10-25T00:00:00Z"}"#
        let subscription = try SGTasksRealtime.decodeSubscription(try self.value(good), socketId: socketId)
        XCTAssertEqual(subscription.socketId, socketId)
        XCTAssertEqual(subscription.appKey, self.key)
        XCTAssertFalse(String(describing: subscription).contains(self.signature))
        for variant in [
            good.replacingOccurrences(of: #""schema_version":1"#, with: #""schema_version":2"#),
            good.replacingOccurrences(of: self.channel, with: "private-tasks.short"),
            good.replacingOccurrences(of: self.signature, with: self.signature.uppercased()),
            good.replacingOccurrences(of: #"}"#, with: #","socket_id":"9.9"}"#)
        ] {
            XCTAssertThrowsError(try SGTasksRealtime.decodeSubscription(try self.value(variant), socketId: socketId), variant)
        }
        XCTAssertEqual(String(decoding: SGTasksRealtime.authRequestBody(socketId), as: UTF8.self), #"{"socket_id":"123.456"}"#)
    }

    // MARK: - Frames

    func test_framesAcceptStringOrObjectDataAndValidateTheirShape() throws {
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"pusher:connection_established","data":"{\"socket_id\":\"1.2\",\"activity_timeout\":30}"}"#), .connectionEstablished(SGTasksRealtime.SocketId("1.2")!, activityTimeout: 30))
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"pusher:connection_established","data":{"socket_id":"1.2","activity_timeout":120}}"#), .connectionEstablished(SGTasksRealtime.SocketId("1.2")!, activityTimeout: 120))
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"tasks.changed","channel":"c","data":"{\"v\":1}"}"#), .changed(channel: "c"))
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"tasks.changed","channel":"c","data":{"v":1}}"#), .changed(channel: "c"))
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"tasks.changed","channel":"c","data":"{\"v\":2}"}"#), .other, "an unknown hint version is ignored, not trusted")
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"tasks.changed","channel":"c","data":"{\"v\":1,\"title\":\"x\"}"}"#), .other, "a hint carrying content is not a hint")
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"tasks.changed","channel":"c","data":"{\"v\":true}"}"#), .other)
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"client-anything","data":{"x":1.5}}"#), .other)
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"pusher:error","data":{"code":4001,"message":"x"}}"#), .error(code: 4001))
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"pusher:ping","data":"{}"}"#), .ping)
    }

    /// Reverb drops an empty `data` (`array_filter`): the application ping/pong arrive without it.
    /// Only these control names may omit it; `connection_established` still requires its data.
    func test_dataLessPingAndPongAreAcceptedButEstablishedNeedsItsData() {
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"pusher:ping"}"#), .ping)
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"pusher:pong"}"#), .pong)
        for frame in [
            #"{"event":"pusher:connection_established"}"#,
            #"{"event":"pusher:connection_established","data":null}"#,
            #"{"event":"pusher:connection_established","data":""}"#,
            #"{"event":"pusher:connection_established","data":"[]"}"#,
            #"{"event":"pusher:connection_established","data":{"activity_timeout":30}}"#
        ] {
            XCTAssertThrowsError(try SGTasksRealtime.parseFrame(frame), frame)
        }
    }

    /// G2: only exactly `{"v":1}` (JSON-encoded string or object) is a hint; every other data shape
    /// on `tasks.changed` is ignored, never a hint and never a close.
    func test_aHintNeedsExactlyVersionOneData() {
        for data in [
            "",
            #","data":null"#,
            #","data":[]"#,
            #","data":"[1]""#,
            #","data":"null""#,
            #","data":"\"v\"""#,
            #","data":{}"#,
            #","data":{"x":1}"#,
            #","data":{"v":1,"v2":1}"#,
            #","data":{"v":"1"}"#,
            #","data":{"v":1.0}"#,
            #","data":"{\"v\":0}""#
        ] {
            let frame = #"{"event":"tasks.changed","channel":"c""# + data + "}"
            XCTAssertEqual(try SGTasksRealtime.parseFrame(frame), .other, frame)
        }
    }

    /// Reverb 1.12's private-channel ack is exactly `"data":"{}"` (no members, no count).
    func test_theSubscriptionAckNeedsPresentEmptyObjectData() {
        let channel = #""channel":"private-tasks.\#(String(repeating: "A", count: 43))""#
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"pusher_internal:subscription_succeeded","data":"{}",\#(channel)}"#), .subscriptionSucceeded(channel: "private-tasks." + String(repeating: "A", count: 43)))
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"pusher_internal:subscription_succeeded","data":{},\#(channel)}"#), .subscriptionSucceeded(channel: "private-tasks." + String(repeating: "A", count: 43)), "an already-decoded empty object, same rule")
        for data in [
            "",
            #","data":null"#,
            #","data":[]"#,
            #","data":"[]""#,
            #","data":"""#,
            #","data":"null""#,
            #","data":{"presence":{"count":1}}"#,
            #","data":"{\"count\":1}""#,
            #","data":"{not json""#,
            #","data":1"#
        ] {
            let frame = #"{"event":"pusher_internal:subscription_succeeded",\#(channel)"# + data + "}"
            XCTAssertThrowsError(try SGTasksRealtime.parseFrame(frame), frame)
        }
        XCTAssertThrowsError(try SGTasksRealtime.parseFrame(#"{"event":"pusher_internal:subscription_succeeded","data":"{}"}"#), "no channel")
    }

    func test_anAckWithTheWrongDataShapeIsAViolationNeverLive() {
        let rig = Rig(metadata: self.metadata())
        rig.socket.start()
        rig.establish()
        rig.authorizations[0].1(.success(self.subscription()))
        rig.frame(#"{"event":"pusher_internal:subscription_succeeded","channel":"\#(self.channel)","data":"[]"}"#)
        XCTAssertEqual(rig.events, [.closed(.protocolViolation)])
        XCTAssertEqual(rig.webSocket.closeCount, 1)
    }

    /// G3: the established frame's activity_timeout is REQUIRED, an integer within 10...120.
    func test_aMissingOutOfRangeOrMistypedActivityTimeoutRefusesTheFrame() {
        for timeout in ["9", "121", "0", "-30", "30.5", "\\\"30\\\"", "null", "1e2", "true", "{}"] {
            let frame = #"{"event":"pusher:connection_established","data":"{\"socket_id\":\"1.2\",\"activity_timeout\":\#(timeout)}"}"#
            XCTAssertThrowsError(try SGTasksRealtime.parseFrame(frame), timeout)
        }
        XCTAssertThrowsError(try SGTasksRealtime.parseFrame(#"{"event":"pusher:connection_established","data":"{\"socket_id\":\"1.2\"}"}"#), "a missing timeout is not guessed")
        XCTAssertNoThrow(try SGTasksRealtime.parseFrame(#"{"event":"pusher:connection_established","data":"{\"socket_id\":\"1.2\",\"activity_timeout\":10}"}"#))
    }

    func test_malformedAndOversizedFramesAreRefused() {
        let oversized = #"{"event":"other","data":""# + String(repeating: "x", count: SGTasksRealtime.maximumFrameBytes) + #""}"#
        XCTAssertThrowsError(try SGTasksRealtime.parseFrame(oversized)) { error in
            XCTAssertEqual(error as? SGTasksRealtime.FrameError, .tooLarge)
        }
        for frame in ["", "[]", "{}", #"{"event":1}"#, #"{"event":"a","event":"b"}"#, #"{"event":"pusher:connection_established","data":{"socket_id":"x"}}"#, #"{"event":"pusher:connection_established","data":"{not json"}"#, #"{"event":"tasks.changed","data":{"v":1}}"#, #"{"event":"pusher_internal:subscription_succeeded"}"#] {
            XCTAssertThrowsError(try SGTasksRealtime.parseFrame(frame), frame)
        }
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"some.unknown","data":"{not json"}"#), .other, "an unknown event's data is never parsed, so it never closes the socket")
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"tasks.changed","channel":"c","data":"{not json"}"#), .other, "an unreadable hint is ignored")
        XCTAssertEqual(try SGTasksRealtime.parseFrame(#"{"event":"pusher:error","data":"{not json"}"#), .error(code: nil))
    }

    func test_theSessionMarkerIsOpaqueAndOnlyComparable() {
        let a = SGTasksRealtime.SessionMarker(refreshToken: "token-1", accountId: "01acc", deviceId: "01dev")
        XCTAssertEqual(a, SGTasksRealtime.SessionMarker(refreshToken: "token-1", accountId: "01acc", deviceId: "01dev"))
        XCTAssertNotEqual(a, SGTasksRealtime.SessionMarker(refreshToken: "token-2", accountId: "01acc", deviceId: "01dev"), "rotation")
        XCTAssertNotEqual(a, SGTasksRealtime.SessionMarker(refreshToken: "token-1", accountId: "01acc", deviceId: "01dev2"), "rebind")
        XCTAssertNotEqual(a, SGTasksRealtime.SessionMarker(refreshToken: "token-1\u{0}01acc", accountId: "", deviceId: "01dev"), "parts are separated")
        XCTAssertFalse(String(describing: a).contains("token"))
        XCTAssertNotEqual(SGTasksRealtime.SessionMarker(refreshToken: "token-1", accountId: "01acc", deviceId: "01dev"), SGTasksRealtime.SessionMarker(refreshToken: "token-1", accountId: "01acc2", deviceId: "01dev"), "account change")
    }

    // MARK: - Socket lifecycle

    private func metadata(timeout: Int = 30) -> SGTasksRealtime.Metadata {
        return SGTasksRealtime.Metadata(availability: .enabled(SGTasksRealtime.Endpoint(wsURL: "wss://tasks.zenlygram.test/realtime/app/\(self.key)", apiBaseURL: self.apiBaseURL)!), activityTimeout: timeout)
    }

    private final class Rig {
        let scheduler = SGTasksRealtimeManualScheduler()
        let webSocket = SGTasksRealtimeFakeWebSocket()
        var authorizations: [(SGTasksRealtime.SocketId, (Result<SGTasksRealtime.Subscription, SGTasksError>) -> Void)] = []
        var events: [SGTasksRealtimeSocket.Event] = []
        var socket: SGTasksRealtimeSocket!

        init(metadata: SGTasksRealtime.Metadata) {
            self.socket = SGTasksRealtimeSocket(metadata: metadata, scheduler: self.scheduler, webSocket: self.webSocket, authorize: { [unowned self] socketId, completion in
                self.authorizations.append((socketId, completion))
            }, events: { [unowned self] event in
                self.events.append(event)
            })
        }

        func frame(_ text: String) {
            self.webSocket.deliver(.text(text))
        }

        func establish(_ socketId: String = "123.456", timeout: String? = "30") {
            self.webSocket.deliver(.opened)
            let extra = timeout.map { ",\\\"activity_timeout\\\":\($0)" } ?? ""
            self.frame(#"{"event":"pusher:connection_established","data":"{\"socket_id\":\"\#(socketId)\"\#(extra)}"}"#)
        }
    }

    private func subscription(_ socketId: String = "123.456", channel: String? = nil) -> SGTasksRealtime.Subscription {
        return SGTasksRealtime.Subscription(socketId: SGTasksRealtime.SocketId(socketId)!, channel: channel ?? self.channel, auth: self.auth)!
    }

    private func subscribed(_ rig: Rig) throws {
        rig.socket.start()
        rig.establish()
        XCTAssertEqual(rig.authorizations.count, 1)
        rig.authorizations[0].1(.success(self.subscription()))
        rig.frame(#"{"event":"pusher_internal:subscription_succeeded","channel":"\#(self.channel)","data":"{}"}"#)
        XCTAssertEqual(rig.events, [.subscribed])
    }

    func test_theHandshakeCarriesOnlyTheOriginAndNoCredential() throws {
        let rig = Rig(metadata: self.metadata())
        rig.socket.start()
        let request = try XCTUnwrap(rig.webSocket.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "wss://tasks.zenlygram.test/realtime/app/\(self.key)?protocol=7&client=zenlygram-ios&version=1.0&flash=false")
        XCTAssertEqual(request.allHTTPHeaderFields, ["Origin": "https://tasks.zenlygram.test"])
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(SGTasksRealtimeSocket(metadata: SGTasksRealtime.Metadata(availability: .disabled, activityTimeout: 30), scheduler: rig.scheduler, webSocket: rig.webSocket, authorize: { _, _ in }, events: { _ in }), "no socket for the kill switch")
        XCTAssertNil(SGTasksRealtimeSocket(metadata: self.metadata(timeout: 5), scheduler: rig.scheduler, webSocket: rig.webSocket, authorize: { _, _ in }, events: { _ in }), "no socket for an unvalidated timeout")
    }

    func test_aFreshAuthorizationOfTheExactSocketIdThenTheExactSubscribe() throws {
        let rig = Rig(metadata: self.metadata())
        try self.subscribed(rig)
        XCTAssertEqual(rig.authorizations.map { $0.0 }, [SGTasksRealtime.SocketId("123.456")!])
        XCTAssertEqual(rig.webSocket.sent, [#"{"event":"pusher:subscribe","data":{"auth":"\#(self.auth)","channel":"\#(self.channel)"}}"#])
        rig.frame(#"{"event":"tasks.changed","channel":"\#(self.channel)","data":"{\"v\":1}"}"#)
        rig.frame(#"{"event":"tasks.changed","channel":"private-tasks.\#(String(repeating: "B", count: 43))","data":"{\"v\":1}"}"#)
        rig.frame(#"{"event":"some.other","channel":"\#(self.channel)","data":"{}"}"#)
        XCTAssertEqual(rig.events, [.subscribed, .invalidated], "a hint counts only on the exact subscribed channel")
    }

    func test_noHintOrLiveClaimBeforeTheExactSubscriptionSucceeds() throws {
        let rig = Rig(metadata: self.metadata())
        rig.socket.start()
        rig.establish()
        rig.frame(#"{"event":"tasks.changed","channel":"\#(self.channel)","data":"{\"v\":1}"}"#)
        rig.authorizations[0].1(.success(self.subscription()))
        rig.frame(#"{"event":"tasks.changed","channel":"\#(self.channel)","data":"{\"v\":1}"}"#)
        XCTAssertEqual(rig.events, [])
        rig.frame(#"{"event":"pusher_internal:subscription_succeeded","channel":"private-tasks.\#(String(repeating: "B", count: 43))","data":"{}"}"#)
        XCTAssertEqual(rig.events, [.closed(.protocolViolation)], "success for another channel is a violation, never live")
        XCTAssertEqual(rig.webSocket.closeCount, 1)
    }

    func test_anAuthorizationForAnotherKeyOrSocketNeverSubscribes() throws {
        let otherKey = Rig(metadata: self.metadata())
        otherKey.socket.start()
        otherKey.establish()
        otherKey.authorizations[0].1(.success(SGTasksRealtime.Subscription(socketId: SGTasksRealtime.SocketId("123.456")!, channel: self.channel, auth: "otherkey:" + self.signature)!))
        XCTAssertEqual(otherKey.events, [.closed(.protocolViolation)])
        XCTAssertTrue(otherKey.webSocket.sent.isEmpty)

        let otherSocket = Rig(metadata: self.metadata())
        otherSocket.socket.start()
        otherSocket.establish()
        otherSocket.authorizations[0].1(.success(self.subscription("9.9")))
        XCTAssertEqual(otherSocket.events, [.closed(.protocolViolation)], "a signature for another socket id is never sent")
        XCTAssertTrue(otherSocket.webSocket.sent.isEmpty)
    }

    func test_aRefusedAuthorizationClosesWithItsTypedError() {
        let rig = Rig(metadata: self.metadata())
        rig.socket.start()
        rig.establish()
        let refusal = SGTasksError(kind: .accountNotLinked)
        rig.authorizations[0].1(.failure(refusal))
        XCTAssertEqual(rig.events, [.closed(.authorization(refusal))])
        XCTAssertTrue(rig.webSocket.sent.isEmpty)
    }

    func test_lateCallbacksAfterStopDoNothing() throws {
        let rig = Rig(metadata: self.metadata())
        rig.socket.start()
        rig.establish()
        rig.socket.stop()
        XCTAssertEqual(rig.webSocket.closeCount, 1)
        XCTAssertEqual(rig.scheduler.activeCount, 0, "every timer is cancelled on stop")
        rig.authorizations[0].1(.success(self.subscription()))
        rig.frame(#"{"event":"pusher_internal:subscription_succeeded","channel":"\#(self.channel)","data":"{}"}"#)
        rig.frame(#"{"event":"tasks.changed","channel":"\#(self.channel)","data":"{\"v\":1}"}"#)
        rig.webSocket.deliver(.failed)
        rig.scheduler.advance(by: 1000)
        XCTAssertTrue(rig.webSocket.sent.isEmpty, "a late authorization after stop never subscribes")
        XCTAssertEqual(rig.events, [], "stop is silent and final")
        XCTAssertEqual(rig.webSocket.closeCount, 1)
    }

    func test_theServersPingIsAnsweredAndAnyFrameKeepsTheConnectionAlive() throws {
        let rig = Rig(metadata: self.metadata(timeout: 30))
        try self.subscribed(rig)
        rig.webSocket.sent.removeAll()
        rig.frame(#"{"event":"pusher:ping","data":"{}"}"#)
        rig.frame(#"{"event":"pusher:ping"}"#)
        XCTAssertEqual(rig.webSocket.sent, [SGTasksRealtime.pongFrame, SGTasksRealtime.pongFrame], "every inbound application ping, with or without data, is answered")
        rig.scheduler.advance(by: 29)
        rig.frame(#"{"event":"pusher:pong","data":"{}"}"#)
        rig.scheduler.advance(by: 29)
        XCTAssertEqual(rig.webSocket.sent.count, 2, "activity resets the idle timer")
    }

    /// Our ping, then a data-less pong: the dead deadline is cancelled, the connection lives on.
    func test_aDataLessPongAnswersOurPingAndCancelsTheDeadDeadline() throws {
        let rig = Rig(metadata: self.metadata(timeout: 30))
        try self.subscribed(rig)
        rig.webSocket.sent.removeAll()
        rig.scheduler.advance(by: 30)
        XCTAssertEqual(rig.webSocket.sent, [SGTasksRealtime.pingFrame])
        rig.scheduler.advance(by: 20)
        rig.frame(#"{"event":"pusher:pong"}"#)
        rig.scheduler.advance(by: 29)
        XCTAssertEqual(rig.events, [.subscribed], "a pong within the deadline keeps the connection")
        XCTAssertEqual(rig.webSocket.closeCount, 0)
        rig.scheduler.advance(by: 1)
        XCTAssertEqual(rig.webSocket.sent, [SGTasksRealtime.pingFrame, SGTasksRealtime.pingFrame], "the next silence pings again")
    }

    func test_silenceSendsOnePingAndThenCloses() throws {
        let rig = Rig(metadata: self.metadata(timeout: 30))
        try self.subscribed(rig)
        rig.webSocket.sent.removeAll()
        rig.scheduler.advance(by: 30)
        XCTAssertEqual(rig.webSocket.sent, [SGTasksRealtime.pingFrame])
        rig.scheduler.advance(by: 29)
        XCTAssertEqual(rig.events, [.subscribed])
        rig.scheduler.advance(by: 1)
        XCTAssertEqual(rig.events, [.subscribed, .closed(.heartbeatTimeout)], "dead after at most 2 × activity timeout")
        XCTAssertEqual(rig.webSocket.closeCount, 1)
        XCTAssertEqual(rig.scheduler.activeCount, 0)
    }

    /// G3: the connection's own valid value governs, longer or shorter than the metadata value.
    func test_theFramesActivityTimeoutGovernsTheHeartbeat() throws {
        let shorter = Rig(metadata: self.metadata(timeout: 60))
        shorter.socket.start()
        shorter.establish(timeout: "20")
        shorter.scheduler.advance(by: 20)
        XCTAssertEqual(shorter.webSocket.sent, [SGTasksRealtime.pingFrame])

        let longer = Rig(metadata: self.metadata(timeout: 20))
        longer.socket.start()
        longer.establish(timeout: "60")
        longer.scheduler.advance(by: 59)
        XCTAssertTrue(longer.webSocket.sent.isEmpty, "the metadata value does not override the connection's own")
        longer.scheduler.advance(by: 1)
        XCTAssertEqual(longer.webSocket.sent, [SGTasksRealtime.pingFrame])
        longer.scheduler.advance(by: 60)
        XCTAssertEqual(longer.events, [.closed(.heartbeatTimeout)], "dead within 2 × the governing timeout")

        for invalid in ["500", "9", nil] as [String?] {
            let rig = Rig(metadata: self.metadata(timeout: 30))
            rig.socket.start()
            rig.establish(timeout: invalid)
            XCTAssertEqual(rig.events, [.closed(.protocolViolation)], "\(String(describing: invalid)): refused, never clamped or guessed")
            XCTAssertTrue(rig.authorizations.isEmpty)
        }
    }

    func test_aConnectionThatNeverEstablishesTimesOut() {
        let rig = Rig(metadata: self.metadata())
        rig.socket.start()
        rig.webSocket.deliver(.opened)
        rig.scheduler.advance(by: SGTasksRealtimeSocket.connectTimeout - 0.5)
        XCTAssertEqual(rig.events, [])
        rig.scheduler.advance(by: 0.5)
        XCTAssertEqual(rig.events, [.closed(.transport)])
    }

    func test_protocolViolationsClose() {
        let cases: [(String, SGTasksRealtimeWebSocketEvent)] = [
            ("binary", .binary),
            ("oversized", .text(#"{"event":"x","data":""# + String(repeating: "x", count: SGTasksRealtime.maximumFrameBytes) + #""}"#)),
            ("not json", .text("hello")),
            ("second established", .text(#"{"event":"pusher:connection_established","data":"{\"socket_id\":\"7.7\",\"activity_timeout\":30}"}"#))
        ]
        for (name, event) in cases {
            let rig = Rig(metadata: self.metadata())
            rig.socket.start()
            rig.establish()
            rig.webSocket.deliver(event)
            XCTAssertEqual(rig.events, [.closed(.protocolViolation)], name)
            XCTAssertEqual(rig.authorizations.count, 1, name)
        }
    }

    func test_closeAndErrorCodesAreReportedForTheReconnectPolicy() {
        let cases: [(SGTasksRealtimeWebSocketEvent, SGTasksRealtimeSocket.CloseReason)] = [
            (.closed(code: 4001), .server(code: 4001)),
            (.closed(code: 4150), .server(code: 4150)),
            (.closed(code: 4299), .server(code: 4299)),
            (.closed(code: 4300), .transport),
            (.closed(code: 1006), .transport),
            (.closed(code: nil), .transport),
            (.failed, .transport),
            (.text(#"{"event":"pusher:error","data":{"code":4201}}"#), .server(code: 4201)),
            (.text(#"{"event":"pusher:error","data":{}}"#), .server(code: nil)),
            (.text(#"{"event":"pusher:subscription_error","data":{}}"#), .subscriptionRefused)
        ]
        for (event, reason) in cases {
            let rig = Rig(metadata: self.metadata())
            rig.socket.start()
            rig.establish()
            rig.authorizations[0].1(.success(self.subscription()))
            rig.webSocket.deliver(event)
            XCTAssertEqual(rig.events, [.closed(reason)], "\(event)")
            rig.webSocket.deliver(.failed)
            XCTAssertEqual(rig.events.count, 1, "exactly one terminal event")
        }
    }

    // MARK: - Revalidation (rotation vs re-bind)

    func test_revalidationWithTheSameChannelKeepsTheSocket() throws {
        let rig = Rig(metadata: self.metadata())
        try self.subscribed(rig)
        rig.socket.revalidate()
        XCTAssertEqual(rig.authorizations.count, 2)
        XCTAssertEqual(rig.authorizations[1].0, SGTasksRealtime.SocketId("123.456")!, "a fresh signed auth for the SAME socket id")
        rig.authorizations[1].1(.success(self.subscription()))
        XCTAssertEqual(rig.events, [.subscribed], "a refresh rotation keeps the live socket")
        XCTAssertEqual(rig.webSocket.closeCount, 0)
        rig.frame(#"{"event":"tasks.changed","channel":"\#(self.channel)","data":"{\"v\":1}"}"#)
        XCTAssertEqual(rig.events, [.subscribed, .invalidated])
    }

    func test_revalidationWithAnotherChannelClosesTheOldGeneration() throws {
        let rig = Rig(metadata: self.metadata())
        try self.subscribed(rig)
        rig.socket.revalidate()
        let rebound = "private-tasks." + String(repeating: "C", count: 43)
        rig.authorizations[1].1(.success(self.subscription(channel: rebound)))
        XCTAssertEqual(rig.events, [.subscribed, .closed(.channelChanged)], "a re-bind never stays on the old generation's channel")
        XCTAssertEqual(rig.webSocket.closeCount, 1)
        rig.frame(#"{"event":"tasks.changed","channel":"\#(self.channel)","data":"{\"v\":1}"}"#)
        XCTAssertEqual(rig.events.count, 2, "the closed old generation reports nothing more")
    }

    func test_aRevalidationAnswerAfterStopIsDropped() throws {
        let rig = Rig(metadata: self.metadata())
        try self.subscribed(rig)
        rig.socket.revalidate()
        rig.socket.stop()
        rig.authorizations[1].1(.success(self.subscription(channel: "private-tasks." + String(repeating: "C", count: 43))))
        XCTAssertEqual(rig.events, [.subscribed], "a stopped socket reports nothing, not even a re-bind")
        XCTAssertEqual(rig.authorizations.count, 2)
    }

    /// A same-principal re-bind while the FIRST authorization is in flight: that authorization may
    /// carry the old generation's channel, so the socket revalidates as soon as it is subscribed.
    func test_aRevalidationDuringTheFirstAuthorizationRunsOnceSubscribed() throws {
        let rig = Rig(metadata: self.metadata())
        rig.socket.start()
        rig.establish()
        rig.socket.revalidate()
        XCTAssertEqual(rig.authorizations.count, 1, "nothing is asked while the first authorization runs")
        rig.authorizations[0].1(.success(self.subscription()))
        rig.frame(#"{"event":"pusher_internal:subscription_succeeded","channel":"\#(self.channel)","data":"{}"}"#)
        XCTAssertEqual(rig.authorizations.count, 2, "the remembered revalidation runs right after the subscription")
        XCTAssertEqual(rig.authorizations[1].0, SGTasksRealtime.SocketId("123.456")!)
        rig.authorizations[1].1(.success(self.subscription(channel: "private-tasks." + String(repeating: "C", count: 43))))
        XCTAssertEqual(rig.events, [.subscribed, .closed(.channelChanged)], "the old-generation socket is never left live")
    }

    /// The re-bind lands after the authorization answered but before `subscription_succeeded`.
    func test_aRevalidationWhileSubscribingRunsOnceSubscribed() throws {
        let rig = Rig(metadata: self.metadata())
        rig.socket.start()
        rig.establish()
        rig.authorizations[0].1(.success(self.subscription()))
        rig.socket.revalidate()
        XCTAssertEqual(rig.authorizations.count, 1)
        rig.frame(#"{"event":"pusher_internal:subscription_succeeded","channel":"\#(self.channel)","data":"{}"}"#)
        XCTAssertEqual(rig.authorizations.count, 2)
        rig.authorizations[1].1(.success(self.subscription()))
        XCTAssertEqual(rig.events, [.subscribed], "same channel: a rotation, the socket stays")
        XCTAssertEqual(rig.webSocket.closeCount, 0)
    }

    /// A second session change while a revalidation runs is confirmed after it, not dropped.
    func test_aRevalidationDuringAnotherRevalidationRunsAfterIt() throws {
        let rig = Rig(metadata: self.metadata())
        try self.subscribed(rig)
        rig.socket.revalidate()
        rig.socket.revalidate()
        XCTAssertEqual(rig.authorizations.count, 2, "one revalidation at a time")
        rig.authorizations[1].1(.success(self.subscription()))
        XCTAssertEqual(rig.authorizations.count, 3, "the remembered one runs after the first confirmed the channel")
        rig.authorizations[2].1(.success(self.subscription(channel: "private-tasks." + String(repeating: "C", count: 43))))
        XCTAssertEqual(rig.events, [.subscribed, .closed(.channelChanged)])
    }

    func test_aSocketDroppedWithoutStopClosesItsConnection() {
        let rig = Rig(metadata: self.metadata())
        rig.socket.start()
        rig.establish()
        rig.socket = nil
        XCTAssertEqual(rig.webSocket.closeCount, 1, "deinit closes: the session would otherwise keep it open")
        XCTAssertEqual(rig.scheduler.activeCount, 0)
        rig.authorizations[0].1(.success(self.subscription()))
        XCTAssertTrue(rig.webSocket.sent.isEmpty)
        XCTAssertEqual(rig.events, [])
    }

    func test_aRefusedRevalidationClosesWithTheTypedError() throws {
        let rig = Rig(metadata: self.metadata())
        try self.subscribed(rig)
        rig.socket.revalidate()
        let revoked = SGTasksError(kind: .session(.deviceRevoked))
        rig.authorizations[1].1(.failure(revoked))
        XCTAssertEqual(rig.events, [.subscribed, .closed(.authorization(revoked))])
    }
}

/// A manual clock: actions run only when the test advances past their due time.
final class SGTasksRealtimeManualScheduler: SGTasksRealtimeScheduler {
    private final class Item: SGTasksRealtimeCancellable {
        let due: TimeInterval
        let order: Int
        let action: () -> Void
        var isCancelled = false

        init(due: TimeInterval, order: Int, action: @escaping () -> Void) {
            self.due = due
            self.order = order
            self.action = action
        }

        func cancel() {
            self.isCancelled = true
        }
    }

    private(set) var now: TimeInterval = 0
    private var items: [Item] = []
    private var counter = 0

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SGTasksRealtimeCancellable {
        self.counter += 1
        let item = Item(due: self.now + max(delay, 0), order: self.counter, action: action)
        self.items.append(item)
        return item
    }

    var activeCount: Int {
        return self.items.filter { !$0.isCancelled }.count
    }

    /// Due times of the live timers, soonest first.
    var pendingDelays: [TimeInterval] {
        return self.items.filter { !$0.isCancelled }.map { $0.due - self.now }.sorted()
    }

    func advance(by interval: TimeInterval) {
        let target = self.now + interval
        while let next = self.items.filter({ !$0.isCancelled && $0.due <= target }).min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            self.now = next.due
            next.isCancelled = true
            next.action()
        }
        self.now = target
        self.items.removeAll { $0.isCancelled }
    }
}

final class SGTasksRealtimeFakeWebSocket: SGTasksRealtimeWebSocket {
    private(set) var requests: [URLRequest] = []
    var sent: [String] = []
    private(set) var closeCount = 0
    private var events: ((SGTasksRealtimeWebSocketEvent) -> Void)?

    func open(_ request: URLRequest, events: @escaping (SGTasksRealtimeWebSocketEvent) -> Void) {
        self.requests.append(request)
        self.events = events
    }

    func send(_ text: String) {
        self.sent.append(text)
    }

    func close() {
        self.closeCount += 1
    }

    /// Delivers even after close: a real task may still call back; the socket must ignore it.
    func deliver(_ event: SGTasksRealtimeWebSocketEvent) {
        self.events?(event)
    }
}
