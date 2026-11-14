import Foundation
import CryptoKit

/// Zenlygram — the Tasks backend, as named account-bound calls (`SGTasksTransport`), on wire R4:
/// every request carries `X-Tasks-Wire: 4`, and every REST result records the server's echo
/// (`serverWire`, nil without one — the downgrade signal).
///
/// `accountPeerId` is the same `PeerId.toInt64()` every other `SGEntitlement` API takes. The owner
/// the server acts for is the account's current binding, read at send — never an id the caller
/// supplies. Each call reads the stored session afresh, waits behind any rotation for that account,
/// and chooses a sponsor `creation_proof` (creates only) at send; nothing transport-related is ever
/// handed out or stored.
///
/// `stillWanted` on every call is the caller's own condition for sending at all (nil: none) — the
/// cloud engine passes its account's CURRENT traffic permission. A call can wait in the account's
/// gate behind a token rotation, a customer-data call or another Tasks call, so it is asked again
/// once the gate is held, right before each attempt; false ends the call exactly like one cancelled
/// while it waited: `.transport(.cancelled)`, `outcomeUnknown` false, nothing signed or sent. It is
/// never the task's cancellation, which aborts a request already on the wire.
///
/// Outcomes worth knowing (`SGTasksError.Kind`, `SGTasksError.refinement`):
/// - `.accountNotLinked` (`403 tasks_account_not_linked`): the session is valid but has no verified
///   Telegram link. NOTHING is dropped — refresh token, cached JWS, binding, key and every cache stay.
///   Pause the account's sync until the user links Telegram (`didChangeNotification` fires then).
/// - refinement `.consentRequired` (`403 tasks_consent_required`, on every route and per batch item):
///   never terminal — requeue without an attempt, back the account off; nothing is dropped.
/// - `.session(_)`: the DeviceAuth 401 family, already applied by `apply(_:credential:)` to the exact
///   session the request presented (a batch item's 401 too).
/// - `.credentialChanged`: the session changed under the call (rotation, logout, re-bind); its answer
///   was discarded. Calling again uses the current session.
extension SGEntitlement {
    /// `POST /v1/tasks/mutations` with the request's sealed bytes. The receipt is checked to answer
    /// THIS mutation before it is returned.
    public func tasksMutation(_ request: SGTasksWire.MutationRequest, accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.MutationResponse, SGTasksError> {
        return await self.tasksMutation(.mutation(request), accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    /// `POST /v1/tasks/mutations` with any sealed mutation — a `task.patch` (R4) included. Send an
    /// R4-only mutation (`requiresWire4`) only while the server has echoed wire 4.
    public func tasksMutation(_ request: SGTasksWire.SealedMutation, accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.MutationResponse, SGTasksError> {
        guard let transport = await self.tasksTransport() else {
            return .failure(SGTasksError(kind: .notConfigured))
        }
        return await transport.mutate(request, accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    /// `POST /v1/tasks/mutations/batch` (R4): one request, each item executed and answered on its
    /// own (`results` in the request's order; `skipped` items never started — resend with the SAME
    /// mutation). Its own client budget: 10 s idle, 20 s for the whole exchange. A 404 (no batch
    /// route), 413 (`.rejected(status: 413)`) and 503 refinement `.batchDisabled` are the
    /// envelope's answers to send less or use the single route.
    public func tasksMutationBatch(_ request: SGTasksWire.MutationBatchRequest, accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        guard let transport = await self.tasksTransport() else {
            return .failure(SGTasksError(kind: .notConfigured))
        }
        return await transport.mutateBatch(request, accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    /// `GET /v1/tasks/snapshot`. `cursor` nil starts a snapshot; keep `limit` (1...100, nil = server
    /// default 50) fixed for every page of one snapshot.
    public func tasksSnapshot(accountPeerId: Int64, cursor: SGTasksWire.Cursor?, limit: Int? = nil, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.SnapshotResponse, SGTasksError> {
        guard let transport = await self.tasksTransport() else {
            return .failure(SGTasksError(kind: .notConfigured))
        }
        return await transport.snapshot(cursor: cursor, limit: limit, accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    /// `GET /v1/tasks/changes` from a snapshot's `changesCursor` or a previous `nextCursor`.
    public func tasksChanges(accountPeerId: Int64, cursor: SGTasksWire.Cursor, limit: Int? = nil, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.ChangesResponse, SGTasksError> {
        guard let transport = await self.tasksTransport() else {
            return .failure(SGTasksError(kind: .notConfigured))
        }
        return await transport.changes(cursor: cursor, limit: limit, accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    /// `GET /v1/tasks/realtime` (shared reads budget). `.enabled` carries an endpoint validated
    /// against this build's own API origin; `.disabled` is only the intentional kill switch (an
    /// unconfigured service is `.unavailable`). Same capture / gate / fence / per-code session
    /// handling as every other Tasks call.
    public func tasksRealtimeMetadata(accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksRealtime.Metadata, SGTasksError> {
        guard let transport = await self.tasksTransport() else {
            return .failure(SGTasksError(kind: .notConfigured))
        }
        return await transport.realtimeMetadata(accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    /// `POST /v1/tasks/realtime/auth` for ONE socket id, signed with the account's session at send.
    /// The opaque subscription is valid for that socket only; call again for every reconnect.
    public func tasksRealtimeAuthorize(accountPeerId: Int64, socketId: SGTasksRealtime.SocketId, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksRealtime.Subscription, SGTasksError> {
        guard let transport = await self.tasksTransport() else {
            return .failure(SGTasksError(kind: .notConfigured))
        }
        return await transport.realtimeAuth(socketId: socketId, accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    /// An opaque, in-memory marker of the account's stored session (nil without one). It changes on
    /// refresh rotation, bind, re-bind and logout; it reveals nothing and is never persisted. The
    /// realtime owner revalidates its live socket when it changes: the server's channel tells a
    /// rotation (same channel) from a re-bind (new generation).
    public func tasksRealtimeSessionMarker(accountPeerId: Int64) -> SGTasksRealtime.SessionMarker? {
        let material = self.session(accountPeerId: accountPeerId)
        guard let refreshToken = material.refreshToken, !refreshToken.isEmpty else {
            return nil
        }
        return SGTasksRealtime.SessionMarker(refreshToken: refreshToken, accountId: material.accountId, deviceId: material.deviceId)
    }

    /// A persistable marker of the account's current BINDING: lowercase hex SHA-256 of
    /// `accountId` + NUL + `deviceId` of the stored session (nil without a session, or before both
    /// are known). Unlike `tasksRealtimeSessionMarker` it survives refresh rotation and restarts and
    /// changes only with a new binding (a re-bind, another account), so state paused for one
    /// binding can tell when it no longer applies. It reveals neither id.
    public func tasksBindingMarker(accountPeerId: Int64) -> String? {
        let material = self.session(accountPeerId: accountPeerId)
        guard let refreshToken = material.refreshToken, !refreshToken.isEmpty, let accountId = material.accountId, !accountId.isEmpty, let deviceId = material.deviceId, !deviceId.isEmpty else {
            return nil
        }
        return SGEntitlement.tasksBindingMarker(accountId: accountId, deviceId: deviceId)
    }

    static func tasksBindingMarker(accountId: String, deviceId: String) -> String {
        return SHA256.hash(data: Data((accountId + "\u{0}" + deviceId).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The account's own raw Telegram user id (never the packed peer id), for recognising the
    /// viewer as owner / recipient.
    public func tasksTelegramUserId(accountPeerId: Int64) -> SGTasksWire.TelegramId? {
        return SGTasksWire.TelegramId(cloudUserPeerId: accountPeerId)
    }

    /// The account's stored canonical backend account id (the JWS `sub`), byte for byte — the
    /// `principal` of `SGTasksWire.MutationRequest.businessHash`. nil unless a session (a non-empty
    /// refresh token) is stored: a dropped session keeps its old `accountId`, and a later re-bind may
    /// store another one. This only says a session is stored (Apple-only accounts included); whether
    /// the server treats it as Telegram-linked is its answer (`.accountNotLinked`).
    public func tasksPrincipal(accountPeerId: Int64) -> String? {
        let material = self.session(accountPeerId: accountPeerId)
        guard let refreshToken = material.refreshToken, !refreshToken.isEmpty, let accountId = material.accountId, !accountId.isEmpty else {
            return nil
        }
        return accountId
    }

    /// Whether this build can reach the Tasks backend at all: the main app with a configured
    /// endpoint. Exactly when every Tasks call answers `.notConfigured` without a request, this is
    /// false. No I/O, no network, nothing about any account, session or link.
    public var isTasksConfigured: Bool {
        return self.tasksClient() != nil
    }

    private func tasksClient() -> SGEntitlementClient? {
        guard !SGEntitlement.isAppExtension else {
            return nil
        }
        return self.client
    }

    private func tasksTransport() async -> SGTasksTransport? {
        guard let client = self.tasksClient() else {
            return nil
        }
        let endpoint = await client.tasksEndpoint()
        let parts = self.tasksTransportParts
        let protocolClasses = endpoint.protocolClasses
        return SGTasksTransport(environment: SGTasksTransport.Environment(
            baseURL: endpoint.baseURL,
            timeout: endpoint.timeout,
            gate: client.accountGate,
            storedRefreshToken: { account in
                return parts.store.session(accountPeerId: account).refreshToken
            },
            deviceCredentials: {
                return parts.identity.credentials(timestamp: parts.clock.transmitTimestamp())
            },
            noteServerTime: { serverTime in
                parts.clock.note(serverTime: serverTime)
            },
            adoptServerOffset: { serverTime in
                parts.clock.adoptServerOffset(serverTime: serverTime)
            },
            creationProof: { [weak self] owner in
                return self?.tasksCreationProof(owner: owner)
            },
            applySessionFailure: { [weak self] error, credential in
                self?.apply(error, credential: credential)
            },
            fetch: { request, timeout, limit in
                return await SGTasksBoundedExchange.perform(request, timeout: timeout, limit: limit, protocolClasses: protocolClasses)
            }
        ))
    }
}
