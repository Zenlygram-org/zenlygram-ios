import Foundation
import CryptoKit

/// Zenlygram — the Tasks realtime hint channel (`x-realtime`, `tasks-sync.json` sha256 168dda50…,
/// consumer contract 2ac6d7d8…): two authenticated REST calls and a Laravel Reverb / Pusher
/// protocol 7 WebSocket that carries ONLY the content-free `tasks.changed` invalidation hint. Task
/// content, permissions and revocation stay with the REST snapshot / changes / mutations.
///
/// Pure (Foundation + CryptoKit): every value here is produced by a strict validating initialiser
/// or decoder. Nothing logs; the endpoint key, socket id, channel and signature never leave as text
/// (`description` is redacted).
public enum SGTasksRealtime {
    public static let schemaVersion: Int64 = 1
    /// `activity_timeout` is honoured only within 10...120 s (`client.heartbeat`).
    public static let activityTimeoutRange = 10 ... 120
    /// Every WebSocket message, both directions. Pusher control frames are ~150 bytes.
    public static let maximumFrameBytes = 8192
    /// GET /realtime and POST /realtime/auth answers (one small object each).
    static let responseLimit = 16384
    /// G1 (interop addendum bf071da6…): the Reverb public app key is ASCII `[A-Za-z0-9_-]{1,128}`.
    static let maximumAppKeyLength = 128
    static let channelPrefix = "private-tasks."
    /// HMAC-SHA256 (32 bytes) as base64url without padding.
    static let channelTokenLength = 43
    static let signatureHexLength = 64
    static let fixedQuery = "protocol=7&client=zenlygram-ios&version=1.0&flash=false"
    static let pathPrefix = "/realtime/app/"

    // MARK: Endpoint

    /// The validated WebSocket endpoint: rebuilt from the authenticated API origin and the
    /// validated public key only — the server's `ws_url` string itself is never used.
    public struct Endpoint: Equatable, CustomStringConvertible {
        /// `wss://{authority}/realtime/app/{key}?protocol=7&client=zenlygram-ios&version=1.0&flash=false`
        public let url: URL
        /// `https://{authority}`: the only handshake header this client sends.
        public let origin: String
        let appKey: String

        /// `wsURL` must be, byte for byte, `wss://` + the API base URL's authority +
        /// `/realtime/app/` + a bounded key: no explicit port the origin lacks, no userinfo, query,
        /// fragment, trailing slash, percent escape or dot segment. `apiBaseURL` is the client's
        /// `https://{authority}/v1`; anything else fails closed.
        public init?(wsURL: String, apiBaseURL: URL) {
            guard let authority = Self.authority(of: apiBaseURL) else {
                return nil
            }
            let prefix = "wss://" + authority + SGTasksRealtime.pathPrefix
            guard wsURL.hasPrefix(prefix) else {
                return nil
            }
            let key = String(wsURL.dropFirst(prefix.count))
            guard SGTasksRealtime.isValidAppKey(key), let url = URL(string: prefix + key + "?" + SGTasksRealtime.fixedQuery) else {
                return nil
            }
            self.url = url
            self.origin = "https://" + authority
            self.appKey = key
        }

        /// `host[:port]` of `https://{authority}/v1`, exactly as the origin was built.
        static func authority(of apiBaseURL: URL) -> String? {
            let raw = apiBaseURL.absoluteString
            guard raw.hasPrefix("https://"), raw.hasSuffix("/v1") else {
                return nil
            }
            let authority = String(raw.dropFirst("https://".count).dropLast("/v1".count))
            guard !authority.isEmpty, authority.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":") }) else {
                return nil
            }
            return authority
        }

        public var description: String {
            return "SGTasksRealtime.Endpoint(<redacted>)"
        }
    }

    // MARK: Metadata (GET /v1/tasks/realtime)

    public struct Metadata: Equatable {
        public enum Availability: Equatable {
            case enabled(Endpoint)
            /// The intentional kill switch only. A broken service is a 503, never this.
            case disabled
        }

        public let availability: Availability
        /// Validated 10...120.
        public let activityTimeout: Int

        public init(availability: Availability, activityTimeout: Int) {
            self.availability = availability
            self.activityTimeout = activityTimeout
        }
    }

    // MARK: Socket id and subscription (POST /v1/tasks/realtime/auth)

    /// `^[0-9]{1,20}\.[0-9]{1,20}$`, ASCII digits only.
    public struct SocketId: Equatable, Hashable, CustomStringConvertible {
        let rawValue: String

        public init?(_ raw: String) {
            let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ (1 ... 20).contains($0.count) && $0.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") } }) else {
                return nil
            }
            self.rawValue = raw
        }

        public var description: String {
            return "SGTasksRealtime.SocketId(<redacted>)"
        }
    }

    /// The server's signed subscription for ONE socket id: kept in memory for that socket only,
    /// never persisted, never reused for another socket id. Opaque outside this module.
    public struct Subscription: Equatable, CustomStringConvertible {
        let socketId: SocketId
        let channel: String
        let auth: String
        let appKey: String

        /// Test and adapter construction with the decoder's own rules (exact channel form,
        /// `{key}:{64 lowercase hex}`).
        public init?(socketId: SocketId, channel: String, auth: String) {
            guard let separator = auth.lastIndex(of: ":") else {
                return nil
            }
            let appKey = String(auth[..<separator])
            guard SGTasksRealtime.isValidChannel(channel), SGTasksRealtime.isValidAppKey(appKey), SGTasksRealtime.isValidAuth(auth, appKey: appKey) else {
                return nil
            }
            self.socketId = socketId
            self.channel = channel
            self.auth = auth
            self.appKey = appKey
        }

        public var description: String {
            return "SGTasksRealtime.Subscription(<redacted>)"
        }
    }

    /// An opaque, in-memory-only marker of the stored session (refresh token, account, device).
    /// It changes on every rotation, bind, rebind and logout. It is a keyed digest under a key
    /// generated per process, so it is not a stable fingerprint of the token, and it has no
    /// accessors: only equality. Never persisted.
    public struct SessionMarker: Equatable, CustomStringConvertible {
        let digest: Data

        static let processKey = SymmetricKey(size: .bits256)

        public init(refreshToken: String, accountId: String?, deviceId: String?) {
            var message = Data("zenlygram-tasks-realtime-session-v1".utf8)
            for part in [refreshToken, accountId ?? "", deviceId ?? ""] {
                message.append(0)
                message.append(contentsOf: Array(part.utf8))
            }
            self.digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: SessionMarker.processKey))
        }

        public var description: String {
            return "SGTasksRealtime.SessionMarker(<redacted>)"
        }

        /// Constant-time over the fixed-length digest.
        public static func == (lhs: SessionMarker, rhs: SessionMarker) -> Bool {
            guard lhs.digest.count == rhs.digest.count else {
                return false
            }
            var difference: UInt8 = 0
            for (left, right) in zip(lhs.digest, rhs.digest) {
                difference |= left ^ right
            }
            return difference == 0
        }
    }

    static func isValidAppKey(_ key: String) -> Bool {
        return (1 ... self.maximumAppKeyLength).contains(key.utf8.count) && key.utf8.allSatisfy(self.isBase64URLByte)
    }

    static func isBase64URLByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    static func isValidChannel(_ channel: String) -> Bool {
        guard channel.hasPrefix(self.channelPrefix) else {
            return false
        }
        let token = channel.utf8.dropFirst(self.channelPrefix.utf8.count)
        return token.count == self.channelTokenLength && token.allSatisfy(self.isBase64URLByte)
    }

    /// `{key}:{64 lowercase hex}` where the key is byte-equal to the endpoint's.
    static func isValidAuth(_ auth: String, appKey: String) -> Bool {
        let prefix = appKey + ":"
        guard auth.hasPrefix(prefix) else {
            return false
        }
        let signature = auth.utf8.dropFirst(prefix.utf8.count)
        return signature.count == self.signatureHexLength && signature.allSatisfy { ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) }
    }

    // MARK: Response decoding (strict, success bodies only)

    static func decodeMetadata(_ value: SGTasksJSON.Value, apiBaseURL: URL) throws -> Metadata {
        let r = try SGTasksWireCodec.Reader(value, path: "response", required: ["schema_version", "enabled", "ws_url", "activity_timeout", "server_time"])
        guard try r.integer("schema_version") == self.schemaVersion else {
            throw SGTasksWire.ValidationError(path: "response.schema_version")
        }
        let timeout = try r.integer("activity_timeout")
        guard let activityTimeout = Int(exactly: timeout), self.activityTimeoutRange.contains(activityTimeout) else {
            throw SGTasksWire.ValidationError(path: "response.activity_timeout")
        }
        _ = try r.instant("server_time")
        let availability: Metadata.Availability
        if try r.bool("enabled") {
            guard let raw = try r.nullableString("ws_url"), let endpoint = Endpoint(wsURL: raw, apiBaseURL: apiBaseURL) else {
                throw SGTasksWire.ValidationError(path: "response.ws_url")
            }
            availability = .enabled(endpoint)
        } else {
            guard try r.isNull("ws_url") else {
                throw SGTasksWire.ValidationError(path: "response.ws_url")
            }
            availability = .disabled
        }
        return Metadata(availability: availability, activityTimeout: activityTimeout)
    }

    /// The key is checked against the endpoint by the socket (it knows which endpoint it opened);
    /// here the shape: exact channel form and `{key}:{hex}` with a valid key.
    static func decodeSubscription(_ value: SGTasksJSON.Value, socketId: SocketId) throws -> Subscription {
        let r = try SGTasksWireCodec.Reader(value, path: "response", required: ["schema_version", "channel", "auth", "server_time"])
        guard try r.integer("schema_version") == self.schemaVersion else {
            throw SGTasksWire.ValidationError(path: "response.schema_version")
        }
        _ = try r.instant("server_time")
        let channel = try r.string("channel")
        guard self.isValidChannel(channel) else {
            throw SGTasksWire.ValidationError(path: "response.channel")
        }
        guard let subscription = Subscription(socketId: socketId, channel: channel, auth: try r.string("auth")) else {
            throw SGTasksWire.ValidationError(path: "response.auth")
        }
        return subscription
    }

    static func authRequestBody(_ socketId: SocketId) -> Data {
        return SGTasksJSON.encode(.object([SGTasksJSON.Member(name: "socket_id", value: .string(socketId.rawValue))]))
    }

    // MARK: Pusher frames

    enum Frame: Equatable {
        case connectionEstablished(SocketId, activityTimeout: Int)
        case ping
        case pong
        case subscriptionSucceeded(channel: String)
        case subscriptionError(channel: String?)
        case error(code: Int?)
        /// `tasks.changed` on `channel`; `data` is parsed only for its bound and form (gap G2).
        case changed(channel: String)
        /// Any other well-formed event: ignored, never logged.
        case other
    }

    enum FrameError: Error, Equatable {
        case tooLarge
        case malformed
    }

    /// One server text frame. Size, UTF-8, depth and duplicate keys are enforced; numbers in
    /// unknown metadata are tolerated (error-style lenient numbers). `data` may be a JSON-encoded
    /// string (Pusher/Reverb) or an object.
    static func parseFrame(_ text: String) throws -> Frame {
        let bytes = Data(text.utf8)
        guard bytes.count <= self.maximumFrameBytes else {
            throw FrameError.tooLarge
        }
        guard case let .object(members)? = try? SGTasksJSON.parse(bytes, maxBytes: self.maximumFrameBytes, maxDepth: 8, lenientNumbers: true) else {
            throw FrameError.malformed
        }
        var event: String?
        var channel: String?
        var data: SGTasksJSON.Value?
        for member in members {
            switch (member.name, member.value) {
            case let ("event", .string(text)):
                event = text
            case let ("channel", .string(text)):
                channel = text
            case ("data", _):
                data = member.value
            default:
                break
            }
        }
        guard let event = event else {
            throw FrameError.malformed
        }
        switch event {
        case "pusher:connection_established":
            guard case let .object(fields)? = try self.payload(data), case let .string(raw)? = fields.first(where: { $0.name == "socket_id" })?.value, let socketId = SocketId(raw) else {
                throw FrameError.malformed
            }
            // G3: a REQUIRED integer within 10...120 that governs this connection; missing,
            // mistyped or out of range refuses the frame (never clamped, never guessed).
            guard case let .integer(seconds)? = fields.first(where: { $0.name == "activity_timeout" })?.value, let timeout = Int(exactly: seconds), self.activityTimeoutRange.contains(timeout) else {
                throw FrameError.malformed
            }
            return .connectionEstablished(socketId, activityTimeout: timeout)
        case "pusher:ping":
            return .ping
        case "pusher:pong":
            return .pong
        case "pusher_internal:subscription_succeeded":
            // A private channel's ack (Reverb 1.12 `PrivateChannel`): `"data":"{}"`, no member list
            // or count. Present data decoding to an EMPTY object (the JSON string "{}", or an
            // already-decoded `{}`) and the channel are required; anything else is a violation.
            guard let channel = channel, case let .object(fields)? = try self.payload(data), fields.isEmpty else {
                throw FrameError.malformed
            }
            return .subscriptionSucceeded(channel: channel)
        case "pusher:subscription_error":
            return .subscriptionError(channel: channel)
        case "pusher:error":
            var code: Int?
            // An unreadable error payload still ends the connection, with no code.
            if case let .object(fields)? = (try? self.payload(data)) ?? nil, case let .integer(value)? = fields.first(where: { $0.name == "code" })?.value {
                code = Int(clamping: value)
            }
            return .error(code: code)
        case "tasks.changed":
            guard let channel = channel else {
                throw FrameError.malformed
            }
            // Exactly `{"v":1}` (object or JSON-encoded string). Anything else — another version,
            // extra members, content — is not a hint this build understands and is ignored.
            guard case let .object(fields)? = (try? self.payload(data)) ?? nil, fields.count == 1, fields[0].name == "v", fields[0].value == .integer(1) else {
                return .other
            }
            return .changed(channel: channel)
        default:
            return .other
        }
    }

    /// `data` as a value: a string is decoded once more (bounded), an object is taken as is.
    private static func payload(_ data: SGTasksJSON.Value?) throws -> SGTasksJSON.Value? {
        guard let data = data else {
            return nil
        }
        if case let .string(inner) = data {
            if inner.isEmpty {
                return nil
            }
            guard let value = try? SGTasksJSON.parse(Data(inner.utf8), maxBytes: self.maximumFrameBytes, maxDepth: 6, lenientNumbers: true) else {
                throw FrameError.malformed
            }
            return value
        }
        return data
    }

    static let pingFrame = #"{"event":"pusher:ping","data":{}}"#
    static let pongFrame = #"{"event":"pusher:pong","data":{}}"#

    static func subscribeFrame(_ subscription: Subscription) -> String {
        let value = SGTasksJSON.Value.object([
            SGTasksJSON.Member(name: "event", value: .string("pusher:subscribe")),
            SGTasksJSON.Member(name: "data", value: .object([
                SGTasksJSON.Member(name: "auth", value: .string(subscription.auth)),
                SGTasksJSON.Member(name: "channel", value: .string(subscription.channel))
            ]))
        ])
        return String(decoding: SGTasksJSON.encode(value), as: UTF8.self)
    }
}
