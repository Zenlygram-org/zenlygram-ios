import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display
import SGLogging
import SGEntitlement
import SGTasks
import SGCustomerSyncCore

/// Zenlygram — the customer-data pipeline of the main app (design 40 §1, §6.1): consent, the
/// automatic link, the profile snapshot, analytics and account deletion against our own server.
/// Main app only; never call it from an extension.
///
/// - `ensureLoaded()` (synchronous, idempotent, no network) reads the build's configuration, decides
///   the activation (`.notShipped` / `.active` / `.failed`), loads and verifies the bundled consent
///   texts and publishes `SGCustomerDataGate.isPipelineActive`.
/// - `start(sharedContext:)` (AppDelegate, BEFORE `SGTasksSyncCoordinator.start`) installs the
///   SGEntitlement hooks — the fail-closed variants for `.failed` — and, when active, the analytics
///   sink, the Link-screen hooks and the coordinator, which publishes every signed-in account's
///   clearance from persisted state at once (t = 0, offline or not).
/// - The consent screens (I-4), Settings (I-6) and the account roots (I-5) use the entry points
///   below; every decision is the core's (`SGCustomerCoordinatorCore`).
///
/// `accountPeerId` is always the packed `PeerId.toInt64()`.
public final class SGCustomerSync {
    public static let shared = SGCustomerSync()

    /// Posted on the main queue when an account's `consentSummary` (or its withdrawal's delivery)
    /// may have changed: `userInfo[accountPeerIdKey]` (`Int64`) for one account, none for all.
    public static let consentSummaryDidChangeNotification = Notification.Name("SGCustomerSyncConsentSummaryDidChange")
    /// Posted on the main queue when an account's `deletionReport` changed; `userInfo[accountPeerIdKey]`.
    public static let deletionDidChangeNotification = Notification.Name("SGCustomerSyncDeletionDidChange")
    public static let accountPeerIdKey = "accountPeerId"

    /// The Settings row's value (`Settings.Data.State.*`).
    public enum ConsentSummary: Equatable {
        /// A usable grant.
        case granted
        /// Never decided.
        case none
        /// Declined (optional builds).
        case declined
        /// Withdrawn here or on another device.
        case withdrawn
        /// The grant must be given again (`needs_reconsent`, a refused grant, a server-ended link).
        case review
    }

    /// "My data" (`GET /v1/profile/me`, design 40 §11.3).
    public enum MyData: Equatable {
        case loaded(SGProfileMe)
        /// No binding on this device: nothing was asked (`MyData.NotLinked`).
        case notLinked
        case offline
        case unavailable
        case rateLimited
        case failed
        /// A request for the account is already running.
        case inProgress
    }

    /// What `ensureLoaded` decided, once per process.
    struct Loaded {
        let config: SGCustomerSyncConfig
        let activation: SGCustomerSyncConfig.Activation
        /// `SGEntitlement.customerDataAuthority`, set only when active.
        let authority: String?
        let texts: SGConsentTextRepository?
        let store: SGConsentStore?
        let queueStore: SGAnalyticsQueueStore?
    }

    private let lock = NSLock()
    private var loadedValue: Loaded?
    private var myDataInFlight = Set<Int64>()
    let protectedData = SGProtectedData()
    let transport = SGCustomerTransportLive()

    // Main queue.
    private var isStarted = false
    private(set) var coordinator: SGCustomerSyncCoordinator?
    /// The consent wall's presenter (I-4, `UI/SGConsentWallPresenter.swift`) behind the wall entry
    /// points below; nil until it is installed (then no wall is ever up).
    var wallPresenter: SGConsentWallPresenting?

    private init() {
    }

    // MARK: - Loading and start

    /// Synchronous and idempotent; independent of `start(sharedContext:)` (an account root may attach
    /// first). Never touches the network.
    public func ensureLoaded() {
        _ = self.loaded()
    }

    func loaded() -> Loaded {
        self.lock.lock()
        if let value = self.loadedValue {
            self.lock.unlock()
            return value
        }
        let value = SGCustomerSync.load(protectedData: self.protectedData)
        self.loadedValue = value
        self.lock.unlock()

        // The module's ONE logging call site (design 40 §1, §16): typed entries only, never a value.
        SGCustomerLog.sink = { entry in
            SGLogger.shared.log("SGCustomerSync", entry.line)
        }
        SGCustomerDataGate.shared.setPipelineActive(value.activation != .notShipped)
        if case let .failed(failure) = value.activation {
            SGCustomerLog.log(failure.logCode)
            #if DEBUG
            assertionFailure("the customer-data pipeline could not activate: \(failure.logCode)")
            #endif
        }
        return value
    }

    public var activation: SGCustomerSyncConfig.Activation {
        return self.loaded().activation
    }

    /// The pipeline runs (the wall, uploads, the automatic link, analytics).
    public var isActive: Bool {
        if case .active = self.activation {
            return true
        }
        return false
    }

    /// AppDelegate's Swiftgram start block, after `SGAccountCleanup.start` and BEFORE
    /// `SGTasksSyncCoordinator.shared.start`. Main queue, idempotent, returns at once, no network.
    public func start(sharedContext: SharedAccountContext) {
        assert(Thread.isMainThread)
        guard !self.isStarted, !SGEntitlement.isAppExtension else {
            return
        }
        self.isStarted = true
        let loaded = self.loaded()
        let entitlement = SGEntitlement.shared
        switch loaded.activation {
        case .notShipped:
            // No hook: SGEntitlement behaves as it always did; Tasks stays `.legacy`.
            return
        case .failed:
            SGCustomerSync.installFailClosedHooks(entitlement)
            return
        case .active:
            break
        }
        guard let store = loaded.store, let authority = loaded.authority, let queueStore = loaded.queueStore, let mode = loaded.config.mode else {
            // Not reachable (`.active` is decided with all four); fail closed all the same.
            SGCustomerSync.installFailClosedHooks(entitlement)
            return
        }
        self.protectedData.observe()

        // The SGEntitlement hooks (design 40 §7.1.4). Called from any thread; they read the
        // lock-guarded store only.
        entitlement.bindConsentProvider = { accountPeerId in
            guard let tg = SGEntitlementAccountIdentity.telegramUserId(accountPeerId: accountPeerId) else {
                return nil
            }
            return store.bindConsentObject(tg: tg, authority: authority)
        }
        entitlement.bindPermissionProvider = { accountPeerId in
            return SGCustomerSync.bindPermission(accountPeerId: accountPeerId, mode: mode, store: store, authority: authority, sessionEnd: SGEntitlement.shared.sessionEnd(accountPeerId: accountPeerId), texts: loaded.texts, operatorValues: loaded.config.operatorValues)
        }
        entitlement.preRevokeUploadsProvider = { accountPeerId in
            // Captured synchronously by `logout`, before anything of the account is purged.
            guard let tg = SGEntitlementAccountIdentity.telegramUserId(accountPeerId: accountPeerId) else {
                return []
            }
            return SGAccountReconcile.finalUploads(pendingWithdraws: store.pendingWithdraws(tg: tg, authority: authority))
        }
        entitlement.bindConsentRefused = { accountPeerId, consentId in
            guard let tg = SGEntitlementAccountIdentity.telegramUserId(accountPeerId: accountPeerId) else {
                return
            }
            _ = store.setBindRefused(tg: tg, authority: authority, consentId: consentId)
        }
        entitlement.bindConsentStale = { accountPeerId, consentId in
            // A manual start's 409 `consent_stale`: the grant it carried is asked again, as the
            // automatic path's `.consentStale` does (contract amendment A3).
            SGCustomerLinkEvents.bindConsentStale(accountPeerId: accountPeerId, consentId: consentId)
        }

        // The Tasks consent hooks (wf15 §6.1, D1): Tasks cannot import this module (F3), so the one
        // prompt, the Data & consent screen and "is a consent screen up" reach it through these.
        self.installTasksConsentEntry()

        let pipeline = SGAnalyticsPipeline(store: queueStore)
        SGAnalytics.install(pipeline)
        let coordinator = SGCustomerSyncCoordinator(store: store, authority: authority, texts: loaded.texts, operatorValues: loaded.config.operatorValues, pipeline: pipeline, queueStore: queueStore, transport: self.transport)
        self.coordinator = coordinator
        SGCustomerLinkEvents.install(handler: { [weak coordinator] event in
            // The Link screen calls on the main thread (an Unlink's suppression is persisted before
            // it returns); SGEntitlement's bind runs elsewhere and is delivered on main.
            if Thread.isMainThread {
                coordinator?.send(SGCustomerCoordinatorCore.Event(event))
            } else {
                DispatchQueue.main.async {
                    coordinator?.send(SGCustomerCoordinatorCore.Event(event))
                }
            }
        })
        coordinator.start(sharedContext: sharedContext)
    }

    /// `.failed` (design 40 §1): fail closed for data, open for usability — no consent attached, the
    /// manual code flow only (no attestation), no final send. No clearance is ever published, so with
    /// the pipeline active every account's is `[]` and Tasks answers `.forbidden`.
    private static func installFailClosedHooks(_ entitlement: SGEntitlement) {
        entitlement.bindConsentProvider = nil
        entitlement.bindPermissionProvider = { _ in
            return .codeOnly
        }
        entitlement.preRevokeUploadsProvider = { _ in
            return []
        }
        entitlement.bindConsentRefused = nil
        entitlement.bindConsentStale = nil
    }

    // MARK: - The Tasks consent hooks (wf15 §6.1)

    /// Installs `SGTasksConsentEntry.installed` (main queue; `start`'s `.active` branch). Each hook is a thin
    /// forwarder to the entry points below, keyed by the packed account peer id, so the app-side test can drive
    /// the decisions without an `AccountContext`.
    func installTasksConsentEntry() {
        assert(Thread.isMainThread)
        SGTasksConsentEntry.installed = SGTasksConsentEntry(
            promptIfUndecided: { context in
                return SGCustomerSync.shared.tasksPromptIfUndecided(accountPeerId: context.account.peerId.toInt64())
            },
            dataConsentController: { context in
                let sync = SGCustomerSync.shared
                guard sync.isActive else {
                    return nil
                }
                return sync.dataAndConsentController(context: context)
            },
            isConsentScreenUp: { context in
                return SGCustomerSync.shared.isWallPresented(accountPeerId: context.account.peerId.toInt64())
            }
        )
    }

    /// The first open of Vazifalar (wf15 §6.2, D1): an optional build arms and shows the account's first prompt
    /// (state `none`) if this attach has not shown one; returns whether a prompt is now up. A required build never
    /// prompts from Tasks (the wall at launch decided), and so does an inactive pipeline: false, nothing touched.
    func tasksPromptIfUndecided(accountPeerId: Int64) -> Bool {
        assert(Thread.isMainThread)
        guard self.consentMode == .optional else {
            return false
        }
        return self.consentWallPresenter.armFirstPrompt(accountPeerId: accountPeerId)
    }

    // MARK: - What the consent screens read (nil unless active)

    /// The consent store of this device (`UserDefaults.standard`).
    public var consentStore: SGConsentStore? {
        return self.loaded().store
    }

    /// The bundled, verified consent texts.
    public var consentTexts: SGConsentTextRepository? {
        return self.loaded().texts
    }

    /// The backend authority every per-origin key is scoped to.
    public var customerDataAuthority: String? {
        return self.loaded().authority
    }

    /// `required` or `optional` (`sg_config.consent_mode`); nil unless active.
    public var consentMode: SGConsentMode? {
        let loaded = self.loaded()
        guard case .active = loaded.activation else {
            return nil
        }
        return loaded.config.mode
    }

    /// The operator values the consent text names (missing ones stay placeholders on a local host).
    public var operatorValues: SGConsentOperatorValues {
        return self.loaded().config.operatorValues
    }

    /// The privacy policy (`sg_config.privacy_policy_url`), when it is an https URL.
    public var privacyPolicyURL: URL? {
        return self.loaded().config.privacyPolicyURL
    }

    /// The Settings row's value for the account; nil when the pipeline is not active or the store
    /// cannot be read (a launch before the first unlock).
    public func consentSummary(accountPeerId: Int64) -> ConsentSummary? {
        let loaded = self.loaded()
        guard case .active = loaded.activation, let store = loaded.store, let authority = loaded.authority, store.isReadable,
              let tg = SGEntitlementAccountIdentity.telegramUserId(accountPeerId: accountPeerId) else {
            return nil
        }
        let record = store.record(tg: tg)
        switch record?.state ?? SGConsentState.none {
        case .none:
            return ConsentSummary.none
        case .declined:
            return .declined
        case .withdrawn, .withdrawnRemote:
            return .withdrawn
        case .needsReconsent:
            return .review
        case .granted:
            if store.latestGrantRejection(tg: tg, authority: authority) != nil {
                return .review
            }
            let sessionEnd = SGEntitlement.shared.sessionEnd(accountPeerId: accountPeerId).map(SGCustomerSync.sessionEnd)
            let handled = SGCustomerLinkState.Handled(jsonObject: store.jsonObject(.linkEnded(tg: tg, authority: authority)))
            if SGCustomerLinkState.linkEnded(record: record, sessionEnd: sessionEnd, handled: handled) {
                return .review
            }
            return .granted
        }
    }

    /// `Consent.Wall.Account`'s value for the account in `context` (design 40 §5.3), read locally.
    public func wallIdentity(context: AccountContext) -> Signal<String?, NoError> {
        return SGProfileReader.wallIdentity(context: context)
    }

    // MARK: - The consent wall (the presenter is I-4's; the account roots call these, I-5)

    /// The account's wall is up: key shortcuts and deep links are ignored behind it.
    public func isWallPresented(accountPeerId: Int64) -> Bool {
        assert(Thread.isMainThread)
        return self.wallPresenter?.isWallPresented(accountPeerId: accountPeerId) ?? false
    }

    /// The account's wall controller while it is up.
    public func wallController(accountPeerId: Int64) -> ViewController? {
        assert(Thread.isMainThread)
        return self.wallPresenter?.wallController(accountPeerId: accountPeerId)
    }

    /// The account root's global overlays changed (`NavigationController.globalOverlayControllersUpdated`):
    /// a wall that was removed by anything but its presenter is presented again.
    public func rootOverlaysChanged(accountPeerId: Int64) {
        assert(Thread.isMainThread)
        self.wallPresenter?.rootOverlaysChanged(accountPeerId: accountPeerId)
    }

    // MARK: - User-initiated sends (no first idle, no client budget; design 40 §6.3)

    /// After `SGConsentStore.withdraw` succeeded, or on Retry of a pending withdrawal: the coordinator
    /// runs gate `[]` → queue purge → receipt clear → Tasks retire (once per withdrawal) and sends the
    /// withdraw at once when the account is linked. Main queue.
    public func userWithdrew(accountPeerId: Int64) {
        assert(Thread.isMainThread)
        self.coordinator?.send(.userWithdrew(account: accountPeerId))
    }

    /// The user confirmed the deletion twice: the account is fenced (`erasing`) BEFORE the first send
    /// of `POST /v1/account/delete`. Returns the report when it is already decided (not linked, the
    /// store unreadable), nil while the request runs — `deletionDidChangeNotification` follows. Main
    /// queue.
    @discardableResult
    public func confirmDeletion(accountPeerId: Int64) -> SGCustomerDeletion.Report? {
        assert(Thread.isMainThread)
        guard let coordinator = self.coordinator else {
            return .notDeleted(.failed)
        }
        return coordinator.confirmDeletion(accountPeerId: accountPeerId)
    }

    /// The account's last deletion outcome in this process (`AccountDelete.*`).
    public func deletionReport(accountPeerId: Int64) -> SGCustomerDeletion.Report? {
        assert(Thread.isMainThread)
        return self.coordinator?.deletionReport(accountPeerId: accountPeerId)
    }

    /// A request of `route` for the account is running (the withdraw progress, the deletion).
    public func isInFlight(_ route: SGCustomerRoute, accountPeerId: Int64) -> Bool {
        assert(Thread.isMainThread)
        return self.coordinator?.isInFlight(route, accountPeerId: accountPeerId) ?? false
    }

    /// `GET /v1/profile/me` for the account, in every consent state (the data subject's own channel);
    /// one at a time per account.
    public func fetchMyData(accountPeerId: Int64) async -> MyData {
        guard self.isActive else {
            return .failed
        }
        guard SGEntitlement.shared.isLinked(accountPeerId: accountPeerId) else {
            return .notLinked
        }
        guard self.beginMyData(accountPeerId) else {
            return .inProgress
        }
        let result = await self.transport.perform(.me, accountPeerId: accountPeerId)
        self.endMyData(accountPeerId)
        return SGCustomerSync.myData(result.outcome, answer: result.answer, isLinked: SGEntitlement.shared.isLinked(accountPeerId: accountPeerId))
    }

    static func myData(_ outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer, isLinked: Bool) -> MyData {
        switch outcome {
        case let .ok(body):
            return SGProfileMe.decode(body).map(MyData.loaded) ?? .failed
        case .notLinkedLocally:
            return .notLinked
        case .timedOut:
            return .offline
        case .unavailable:
            return answer.transport == .offline ? .offline : .unavailable
        case .rateLimited:
            return .rateLimited
        case .credentialChanged:
            return .unavailable
        case .session:
            // A 401 of the drop family ended the session: the account is no longer linked here.
            return isLinked ? .failed : .notLinked
        case .consentRequired, .accountNotLinked, .accountMismatch, .payloadTooLarge, .terminal, .notConfigured:
            return .failed
        }
    }

    private func beginMyData(_ accountPeerId: Int64) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.myDataInFlight.insert(accountPeerId).inserted
    }

    private func endMyData(_ accountPeerId: Int64) {
        self.lock.lock()
        self.myDataInFlight.remove(accountPeerId)
        self.lock.unlock()
    }

    // MARK: - Rules

    /// `bindPermissionProvider` (design 40 §0, §7.1.4, §11.4): `.allowed` only for an account with a
    /// usable grant — `granted`, not rejected at this authority, its link not ended by the server,
    /// not stale against this build's `texts` and `operatorValues` (§4.6 rows 5–6, read as
    /// `needs_reconsent` before the wall persists it); an `erasing` account is refused in both
    /// modes; any other account (or an unreadable store) is refused in required mode (defence in
    /// depth behind the wall) and limited to the code flow in optional mode (no attestation, no
    /// consent attached).
    static func bindPermission(accountPeerId: Int64, mode: SGConsentMode, store: SGConsentStore, authority: String, sessionEnd: SGEntitlementSessionEnd?, texts: SGConsentTextRepository? = nil, operatorValues: SGConsentOperatorValues? = nil) -> SGEntitlementBindPermission {
        let withoutGrant: SGEntitlementBindPermission = mode == .required ? .refused : .codeOnly
        guard let tg = SGEntitlementAccountIdentity.telegramUserId(accountPeerId: accountPeerId), store.isReadable else {
            return withoutGrant
        }
        if store.isErasing(tg: tg, authority: authority) {
            return .refused
        }
        guard let record = store.record(tg: tg), record.state == .granted, store.latestGrantRejection(tg: tg, authority: authority) == nil else {
            return withoutGrant
        }
        let handled = SGCustomerLinkState.Handled(jsonObject: store.jsonObject(.linkEnded(tg: tg, authority: authority)))
        if SGCustomerLinkState.linkEnded(record: record, sessionEnd: sessionEnd.map(SGCustomerSync.sessionEnd), handled: handled) {
            return withoutGrant
        }
        if let texts, SGCustomerClearance.inputs(store: store, tg: tg, authority: authority, bindingDeviceId: nil, linkEnded: false, hasProfileReceipt: false, texts: texts, operatorValues: operatorValues).staleGrantNotice != nil {
            return withoutGrant
        }
        return .allowed
    }

    /// `SGEntitlementSessionEnd` as the core reads it.
    static func sessionEnd(_ end: SGEntitlementSessionEnd) -> SGCustomerLinkState.SessionEnd {
        return SGCustomerLinkState.SessionEnd(code: end.code, reason: end.reason, at: end.at, deviceId: end.deviceId)
    }

    private static func load(protectedData: SGProtectedData) -> Loaded {
        let entitlement = SGEntitlement.shared
        let config = SGCustomerSyncConfig.current()
        let authority = entitlement.customerDataAuthority
        guard entitlement.isAuthenticatedBackendConfigured, let authority else {
            return Loaded(config: config, activation: .notShipped, authority: nil, texts: nil, store: nil, queueStore: nil)
        }
        let texts: Result<SGConsentTextRepository, SGConsentTextRepository.Problem> = config.consentRootURL.map { SGConsentTextRepository.load(rootURL: $0) } ?? .failure(.manifestUnreadable)
        let queueStore = entitlement.customerDataStorageToken.flatMap { token -> SGAnalyticsQueueStore? in
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            return SGAnalyticsQueueStore(baseURL: base, storageToken: token, isReadable: {
                return protectedData.isAvailable
            })
        }
        let activation = SGCustomerSyncConfig.activation(backendShipped: true, hasAuthority: true, mode: config.mode, texts: texts, operatorValues: config.operatorValues, apiHost: config.apiHost, hasQueueStore: queueStore != nil)
        guard case .active = activation, case let .success(repository) = texts else {
            return Loaded(config: config, activation: activation, authority: nil, texts: nil, store: nil, queueStore: nil)
        }
        let store = SGConsentStore(defaults: .standard, isReadable: {
            return protectedData.isAvailable
        }, now: {
            return entitlement.entitlementClock.effectiveNow()
        })
        return Loaded(config: config, activation: activation, authority: authority, texts: repository, store: store, queueStore: queueStore)
    }
}

/// Zenlygram — I-4's consent-wall presenter as `SGCustomerSync` reaches it (main queue).
protocol SGConsentWallPresenting: AnyObject {
    func isWallPresented(accountPeerId: Int64) -> Bool
    func wallController(accountPeerId: Int64) -> ViewController?
    func rootOverlaysChanged(accountPeerId: Int64)
}

/// Zenlygram — whether protected data (the consent store's defaults, the event queue's files) can be
/// read: `UIApplication.isProtectedDataAvailable` on the main thread, its last known value anywhere
/// else (the bind hooks and the analytics queue run off main). False until first read.
final class SGProtectedData {
    private let lock = NSLock()
    private var available: Bool?
    private var observers: [NSObjectProtocol] = []

    var isAvailable: Bool {
        if Thread.isMainThread {
            let value = UIApplication.shared.isProtectedDataAvailable
            self.lock.lock()
            self.available = value
            self.lock.unlock()
            return value
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.available ?? false
    }

    /// Main queue, once: keeps the off-main answer current.
    func observe() {
        assert(Thread.isMainThread)
        guard self.observers.isEmpty else {
            return
        }
        _ = self.isAvailable
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.set(false)
        }))
        self.observers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.set(true)
        }))
    }

    private func set(_ value: Bool) {
        self.lock.lock()
        self.available = value
        self.lock.unlock()
    }
}
