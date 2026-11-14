import Foundation
import SGEntitlement

/// The only network surface the cloud repository uses: the named Tasks calls of SGEntitlement's
/// facade (fresh credential and creation evidence are chosen there at send time; nothing of them
/// reaches this module). Host tests substitute a scripted server behind the same seam.
///
/// `stillWanted` on every call is SGEntitlement's post-gate re-check: the repository passes its
/// account's CURRENT traffic permission (`SGTasksCloudTrafficCheck`). A call can wait in
/// SGEntitlement's account gate behind a token rotation or a customer-data call; one that is no
/// longer permitted when its turn comes sends nothing and answers like a call cancelled while it
/// waited (`.transport(.cancelled)`, `outcomeUnknown` false).
protocol SGTasksCloudTransport: AnyObject {
    /// `POST /v1/tasks/mutations` with any sealed mutation (an R4 `task.patch` included).
    func mutation(_ request: SGTasksWire.SealedMutation, accountPeerId: Int64, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.MutationResponse, SGTasksError>
    /// `POST /v1/tasks/mutations/batch` (R4): up to 100 sealed mutations, each answered on its own.
    func mutationBatch(_ request: SGTasksWire.MutationBatchRequest, accountPeerId: Int64, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.MutationBatchResponse, SGTasksError>
    func snapshot(accountPeerId: Int64, cursor: SGTasksWire.Cursor?, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.SnapshotResponse, SGTasksError>
    func changes(accountPeerId: Int64, cursor: SGTasksWire.Cursor, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.ChangesResponse, SGTasksError>
    /// Raw positive Telegram id of the account itself (own-row recognition only).
    func ownTelegramId(accountPeerId: Int64) -> SGTasksWire.TelegramId?
    /// The account has a stored linked session (import consent requires it).
    func isLinked(accountPeerId: Int64) -> Bool
    /// The canonical server account currently bound to this native account (nil when unbound).
    /// Outbox identities, cursors and the shadow are scoped to it; a change fences them.
    func principal(accountPeerId: Int64) -> String?
    /// This build has a Tasks backend at all (the facade's own readiness, no network). false means
    /// every call would answer `notConfigured`: the board says so instead of offering a link, and
    /// no cycle runs. Independent of any account, session or link.
    var isConfigured: Bool { get }
    var sessionChangeNotification: Notification.Name? { get }
    /// A persistable, content-free marker of the account's current binding (nil without a
    /// session): a `not_linked` pause recorded for one binding ends when it changes.
    func bindingMarker(accountPeerId: Int64) -> String?
    /// The `X-Tasks-Wire` value every request of this build sends (`SGTasksShippedWire.requestWire`:
    /// `sg_config.tasks_wire` clamped to 4 ... 5, wf15 §8.2). A build-time value, never probed; host
    /// tests script 4 or 5. What the server actually spoke is the store's numeric `server_wire`.
    var requestWire: Int { get }
}

/// One Tasks call's post-gate re-check (`stillWanted`): SGEntitlement asks `ask` once the account's
/// gate is held and before each attempt; `permits` is the repository's CURRENT traffic permission.
/// A call it refused sent nothing, and its answer — the same as a call cancelled while it waited —
/// is no failure of the call: `refused` tells the repository so (no attempt, no backoff, no error),
/// which an offline `.transport(.cancelled)` alone could not.
final class SGTasksCloudTrafficCheck: @unchecked Sendable {
    private let lock = NSLock()
    private let permits: () -> Bool
    private var didRefuse = false

    init(_ permits: @escaping () -> Bool) {
        self.permits = permits
    }

    /// SGEntitlement's `stillWanted`; any thread.
    func ask() -> Bool {
        let permitted = self.permits()
        if !permitted {
            self.lock.lock()
            self.didRefuse = true
            self.lock.unlock()
        }
        return permitted
    }

    /// The call ended on this check's refusal: nothing was sent.
    var refused: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.didRefuse
    }
}

// Host tests (-D SGTASKS_HOST_TESTS) link only the pure SGEntitlement core, without the facade.
#if !SGTASKS_HOST_TESTS
/// Production transport: forwards to the SGEntitlement Tasks facade only.
final class SGTasksCloudEntitlementTransport: SGTasksCloudTransport {
    static let shared = SGTasksCloudEntitlementTransport()

    func mutation(_ request: SGTasksWire.SealedMutation, accountPeerId: Int64, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.MutationResponse, SGTasksError> {
        return await SGEntitlement.shared.tasksMutation(request, accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    func mutationBatch(_ request: SGTasksWire.MutationBatchRequest, accountPeerId: Int64, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        return await SGEntitlement.shared.tasksMutationBatch(request, accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    func snapshot(accountPeerId: Int64, cursor: SGTasksWire.Cursor?, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.SnapshotResponse, SGTasksError> {
        return await SGEntitlement.shared.tasksSnapshot(accountPeerId: accountPeerId, cursor: cursor, limit: nil, stillWanted: stillWanted)
    }

    func changes(accountPeerId: Int64, cursor: SGTasksWire.Cursor, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.ChangesResponse, SGTasksError> {
        return await SGEntitlement.shared.tasksChanges(accountPeerId: accountPeerId, cursor: cursor, limit: nil, stillWanted: stillWanted)
    }

    func ownTelegramId(accountPeerId: Int64) -> SGTasksWire.TelegramId? {
        return SGEntitlement.shared.tasksTelegramUserId(accountPeerId: accountPeerId)
    }

    func isLinked(accountPeerId: Int64) -> Bool {
        return SGEntitlement.shared.isLinked(accountPeerId: accountPeerId)
    }

    func principal(accountPeerId: Int64) -> String? {
        return SGEntitlement.shared.tasksPrincipal(accountPeerId: accountPeerId)
    }

    var isConfigured: Bool {
        return SGEntitlement.shared.isTasksConfigured
    }

    var sessionChangeNotification: Notification.Name? {
        return SGEntitlement.didChangeNotification
    }

    func bindingMarker(accountPeerId: Int64) -> String? {
        return SGEntitlement.shared.tasksBindingMarker(accountPeerId: accountPeerId)
    }

    var requestWire: Int {
        return SGTasksShippedWire.requestWire
    }
}

/// Production realtime side: the two named SGEntitlement calls, the opaque session marker and the
/// native Pusher socket. The subscription stays opaque here; credentials never reach this module.
final class SGTasksCloudEntitlementRealtimeService: SGTasksCloudRealtimeService {
    static let shared = SGTasksCloudEntitlementRealtimeService()

    func metadata(accountPeerId: Int64, stillWanted: @escaping () -> Bool, completion: @escaping (Result<SGTasksRealtime.Metadata, SGTasksError>) -> Void) {
        Task {
            completion(await SGEntitlement.shared.tasksRealtimeMetadata(accountPeerId: accountPeerId, stillWanted: stillWanted))
        }
    }

    func authorize(accountPeerId: Int64, socketId: SGTasksRealtime.SocketId, stillWanted: @escaping () -> Bool, completion: @escaping (Result<SGTasksRealtime.Subscription, SGTasksError>) -> Void) {
        Task {
            completion(await SGEntitlement.shared.tasksRealtimeAuthorize(accountPeerId: accountPeerId, socketId: socketId, stillWanted: stillWanted))
        }
    }

    func sessionMarker(accountPeerId: Int64) -> SGTasksRealtime.SessionMarker? {
        return SGEntitlement.shared.tasksRealtimeSessionMarker(accountPeerId: accountPeerId)
    }

    func makeSocket(metadata: SGTasksRealtime.Metadata, scheduler: SGTasksRealtimeScheduler, authorize: @escaping SGTasksRealtimeSocket.Authorize, events: @escaping (SGTasksRealtimeSocket.Event) -> Void) -> SGTasksCloudRealtimeSocketHandle? {
        return SGTasksRealtimeSocket(metadata: metadata, scheduler: scheduler, authorize: authorize, events: events)
    }
}
#endif
