import Foundation
import UIKit
import notify
import SGProtectedStore

/// Zenlygram — which Telegram accounts this install holds, and which of them is in front.
///
/// The entitlement is per account, but three of the four features it gates keep their data per
/// INSTALL (see `SGEntitlementCapability.isDeviceGlobal`), so the gate needs both.
public struct SGEntitlementAccounts: Equatable {
    /// The account whose subscription every account-scoped surface describes.
    public let primary: Int64?
    /// Every account signed in, `primary` included, de-duplicated and sorted.
    public let all: [Int64]

    /// `all` is normalised here rather than at the reader, so `==` answers "did the set actually
    /// move" instead of "did the app hand them over in a different order" — which is what makes a
    /// `distinctUntilChanged` over this value correct.
    public init(primary: Int64?, all: [Int64]) {
        var unique = Set(all)
        if let primary {
            unique.insert(primary)
        }
        self.primary = primary
        self.all = unique.sorted()
    }
}

/// Zenlygram — the single predicate the whole app asks, and the state behind it.
///
/// Two invariants outrank every line in this file:
///
/// 1. **The server is never on the path to the user's own data.** Vault and Chat Lock PINs are local.
///    Opening, listing, un-hiding, unlocking, removing a PIN and reading / completing / deleting
///    tasks work with the server unreachable, forever, and so does reading or removing retained
///    message history. Only creating NEW material is gated (`SGEntitlementGatedAction`), new
///    retained-history capture included — by the same cached decision, never by a request. Nothing
///    here touches the network on the launch critical path, and no gate ever awaits one:
///    `can(_:)`, `gate(_:)`, `has(_:)` and `state` read a cached decision under a lock and return
///    immediately.
/// 2. **Fail toward the paying user, never toward data loss.** A 5xx or a timeout is "offline", never
///    "unsubscribed". A lapse never deletes, never un-hides, never un-locks and never hides retained
///    history; it only stops creating new material. Only a successfully verified
///    token, a genuine lapse in a configured build, or the end of the local 7-day grace can ever
///    reduce what the user may do — no transport outcome may.
///
/// Threading: every member of this class is safe from any thread. Verification (one P-256 check)
/// happens when the decision is (re)computed, not on every query, and `prewarm()` moves the first
/// computation off the main thread.
public final class SGEntitlement {
    /// The app's instance: the shipped explicit public policy (if any), whether `sg_config` asked for
    /// one at all, and whether this build ships the authenticated client. Test instances default to
    /// no public policy (the legacy behavior) and inject one explicitly.
    public static let shared = SGEntitlement(
        publicPolicy: SGEntitlementPublicPolicyConfiguration.shipped,
        isPublicPolicyRequested: SGEntitlementPublicPolicyConfiguration.isRequested,
        isAuthenticatedEntitlementConfigured: SGEntitlementClient.Configuration.isShipped,
        appleBackend: .shipped
    )

    public static let isAppExtension: Bool = Bundle.main.bundlePath.hasSuffix(".appex")

    /// Posted on the main queue whenever the evaluated state, the session material or the StoreKit
    /// snapshot changed.
    public static let didChangeNotification = Notification.Name("SGEntitlementDidChange")

    /// Posted once per process, on the main queue, when the first idle window after launch has passed
    /// (`prewarm()`): background network work may start from then on (invariant I1).
    public static let didPassFirstIdleNotification = Notification.Name("SGEntitlementDidPassFirstIdle")

    /// Posted by the main app after any change; extensions drop their caches on it.
    public static var darwinNotificationName: String {
        return "\(SGProtectedKeychain.sharedAccessGroup).entitlement.changed"
    }

    static let storeKitSnapshotKey = "zg.ent.storekit.v1"
    /// P7 provenance ledger + per-original ownership (`SGEntitlementAppleProvenanceState`). App-group
    /// defaults, per install, next to the StoreKit snapshot it qualifies.
    static let appleProvenanceKey = "zg.ent.apple.provenance.v1"

    /// Posted (main app, at most once per process) when an identityless legacy StoreKit snapshot is
    /// quarantined by a live server revocation: `SGIAP` answers by re-reading StoreKit's own
    /// per-transaction entries, which replaces the legacy aggregate with an identified v2 snapshot.
    public static let storeKitProvenanceRequestedNotification = Notification.Name("SGEntitlementStoreKitProvenanceRequested")

    /// The backend trust domain the event ordering is scoped to: the configured entitlement host
    /// (and port). Derived from the build's configuration, so extensions agree with the app.
    static let appleTrustDomain: String = {
        guard let url = SGEntitlementClient.Configuration.shipped(appVersion: nil, osVersion: nil)?.baseURL, let host = url.host?.lowercased() else {
            return "unconfigured"
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }()

    private let lock = NSLock()
    private let store: SGEntitlementStore
    private let clock: SGEntitlementClock
    private let identity: SGEntitlementDeviceIdentity
    private let scheduler: SGEntitlementScheduler
    private let defaults: UserDefaults?
    private let refreshQueue = DispatchQueue(label: "app.swiftgram.ios.entitlement", qos: .utility)

    // Guarded by `lock`.
    private var activeAccount: Int64?
    /// Every Telegram account signed in on this install, primary included. Fed by the app; empty in
    /// an extension, where `activeAccount` alone is all there is.
    private var knownAccounts: [Int64] = []
    private var cachedDeviceWide: SGEntitlementDeviceWideDecision?
    private var cachedDecision: SGEntitlementEvaluator.Decision?
    private var cachedStoreKit: SGEntitlementStoreKitSnapshot?
    private var didLoadStoreKit = false
    private var cachedAppleProvenance = SGEntitlementAppleProvenanceState()
    private var didLoadAppleProvenance = false
    /// The stored ledger exists but could not be decoded: it is kept byte-for-byte and never
    /// overwritten by this process (`mutateAppleProvenance`).
    private var isAppleProvenanceStoreReadOnly = false
    private var didRequestStoreKitProvenance = false
    /// The local 7-day grace record, per install (`SGEntitlementLocalGrace`). Loaded — and, in the
    /// main app, minted — on the first evaluation; nil in an extension that finds no record.
    private var localGraceValue: SGEntitlementLocalGrace?
    private var didLoadLocalGrace = false
    /// The `lastSeenAt` last proven persisted, so the record's high-water mark is rewritten as it
    /// moves (`localGraceHighWaterPersistInterval`) and not on every evaluation.
    private var localGraceSeenAtPersisted: Date = .distantPast
    /// D9 — the paid-policy mark (`SGEntitlementPaidModeMark.firstPaidPolicyAt`), the second
    /// minted-once record the paid-mode grace window is re-based on. Loaded — and, in the main app,
    /// minted — on the first evaluation under a PAID policy; never consulted in free mode. nil where
    /// no record exists (an extension on an install the app has never evaluated under paid).
    private var paidModeMarkValue: Date?
    private var didLoadPaidModeMark = false
    /// The one-shot that re-decides at the next horizon (`scheduleHorizon`).
    private var horizonWorkItem: DispatchWorkItem?
    /// The periodic policy refresh while the app is active (`SGEntitlementScheduler
    /// .policyRefreshInterval`): armed by `applicationDidBecomeActive`, cancelled by
    /// `applicationWillResignActive`. nil while the app is not active. Guarded by `lock`.
    private var policyRefreshTimer: DispatchSourceTimer?
    private var pinnedKeys: SGEntitlementPinnedKeys = .shipped
    /// Whether this build can enforce at all. A build with no pinned key and no product ids has no
    /// grant path, so it must not gate anything. See `SGEntitlementEnforcement`.
    private var enforcement: SGEntitlementEnforcement = .shipped
    private var clientValue: SGEntitlementClient?
    private var deviceName: String = "iPhone"
    /// The APNs token; which bindings have it is each binding's own receipt
    /// (`SGEntitlementSessionMaterial.pushTokenDigest`).
    private var pushToken: String?
    /// Set once the first idle window after launch has passed; an account switch refreshes only
    /// after it, so nothing about the entitlement reaches the network on the launch path (I1).
    private var didPassFirstIdle = false
    /// Opened by the first `setAccounts`: a refresh push answered before the app has published its
    /// accounts waits for them (`handleSilentPush`).
    private let accountsReady = SGEntitlementReadinessGate()
    private var didSeeUnknownKid = false
    private var lastWrittenMirror: SGEntitlementMirror?
    private var darwinToken: Int32 = 0
    private var isDarwinObserverRegistered = false
    private var observers: [NSObjectProtocol] = []
    /// `/bind/revoke` calls still in flight, keyed by an id of their own. `beginBind` waits for all of
    /// them: the server revokes the device BINDING the old token belongs to, and re-binding this
    /// device reuses that same binding, so a revoke that lands after a re-bind would revoke the new
    /// link.
    private var pendingRevokes: [UUID: Task<Void, Never>] = [:]
    /// Serializes the two writers that decide which device key a binding holds: a bind being stored
    /// (`completeBind`) and a failure's key regeneration (`apply`). Outermost: taken while no other
    /// lock is held, and it in turn takes the store's lock and the identity's lock, never the
    /// reverse.
    private let bindingLock = NSLock()
    /// Guarded by `bindingLock`: the device key a bind stored in this process registered. A
    /// `device_key_mismatch` on some other session never regenerates THIS key — a binding the
    /// server accepted it for would break, and the failing account re-binds with it anyway.
    private var boundPublicKey: String?
    /// Guarded by `bindingLock`, including its check immediately before a bind's session write.
    private var bindAttempts = SGEntitlementBindAttempts()

    /// The signed monetization policy (`SGEntitlementPolicy`). Guarded by `lock`; loaded — and
    /// re-verified against the policy ring (`policyKeysLocked`) — on first use, so an install with
    /// nothing stored, or with a stored policy that no longer verifies, is FREE. With an explicit
    /// public policy the store is scoped to that policy's origin.
    private let policyStore: SGEntitlementPolicyStore
    private var policyState: SGEntitlementPolicyState = .initial
    private var didLoadPolicy = false
    /// One policy request at a time, 60 s apart (`SGEntitlementPolicyRefreshGate`).
    private var policyGate = SGEntitlementPolicyRefreshGate()
    /// The POLICY clock: the wall clock in the app, injected by tests. Deliberately not `clock`
    /// (`SGEntitlementClock`), whose mark every other response's UNSIGNED `server_time` moves;
    /// `SGEntitlementPolicyState.accepting` floors it at the accepted policy's signed `iat`.
    private let policyClock: () -> Date
    /// The explicit public policy (`sg_config.public_policy_url` / `public_policy_keys`), or nil:
    /// then the policy comes from the authenticated base URL and verifies against the entitlement
    /// ring, as it always has. Its ring verifies the policy ONLY — it is never `pinnedKeys`.
    private let publicPolicy: SGEntitlementPublicPolicyConfiguration?
    /// `sg_config` named a public-policy key, valid or not. With `publicPolicy` nil this is a
    /// requested-but-invalid configuration, which fails CLOSED: no policy transport, an empty policy
    /// ring, a store that reads and writes nothing — never the legacy endpoint, the entitlement ring
    /// or the bare legacy cache.
    private let isPublicPolicyRequested: Bool
    /// Whether this build ships the authenticated entitlement client (pinned keys AND `api_url`).
    /// A build constant, injected by tests: never inferred from `client`, which is also nil until
    /// `configure(...)` has run.
    private let isAuthenticatedEntitlementConfigured: Bool
    /// The explicit `apple_backend_enabled` flag and the product ids. A build constant, injected by tests.
    private let appleBackend: SGEntitlementAppleBackendConfiguration
    /// Guarded by `lock`: the policy endpoint of a build without an explicit public policy, derived
    /// from the same configuration as `clientValue` by `configure(...)`.
    private var legacyPolicyEndpoint: SGEntitlementPolicyEndpoint?
    /// Guarded by `lock`. Tests only: the transport every lifecycle-driven policy refresh (first
    /// idle, foreground, the periodic timer, the refresh push) uses instead of a network endpoint.
    private var policyTransportOverride: SGEntitlementPolicyTransport?
    /// The signed app-update policy (`SGAppUpdatePolicy`), the second public policy of the same
    /// origin. Guarded by `lock`; loaded — and re-verified against the same policy ring
    /// (`policyKeysLocked`) — on first use. Its slot is the monetization slot's sibling
    /// (`zg.app.policy.v1@<origin>`, `SGEntitlementPolicyStore.rebased`), scoped identically. It
    /// decides nothing about access: only whether this build is still supported
    /// (`appUpdateDecision`).
    private let appUpdatePolicyStore: SGEntitlementPolicyStore
    private var appUpdatePolicyState: SGAppUpdatePolicyState = .initial
    private var didLoadAppUpdatePolicy = false
    /// Its own gate (`SGEntitlementPolicyRefreshGate`): an app-policy attempt never consumes the
    /// monetization gate's in-flight slot or cooldown, nor the purchase slot.
    private var appUpdatePolicyGate = SGEntitlementPolicyRefreshGate()
    /// Guarded by `lock`: the app-policy endpoint of a build without an explicit public policy,
    /// derived by `configure(...)` beside `legacyPolicyEndpoint`.
    private var legacyAppPolicyEndpoint: SGEntitlementPolicyEndpoint?
    /// Guarded by `lock`. Tests only: the transport `refreshAppUpdatePolicy()` uses.
    private var appUpdatePolicyTransportOverride: SGEntitlementPolicyTransport?
    /// Guarded by `lock`. Tests only: replaces the random stagger of the app-policy GET
    /// (`appUpdatePolicyStagger`).
    private var appUpdatePolicyStaggerOverride: TimeInterval?
    /// Guarded by `lock`: the installed `CFBundleShortVersionString` the app-update decision
    /// compares — never the build number. Tests inject.
    private var installedAppVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    /// Guarded by `lock`: paid-mode tokens without account claims still to be asked about
    /// (`SGEntitlementAccountClaimsLedger`).
    private var accountClaims = SGEntitlementAccountClaimsLedger()
    /// Guarded by `lock`: one pending re-try after a scheduler `.wait`, never a pile of them.
    private var isAccountClaimsRetryScheduled = false
    /// Guarded by `lock`: bumped by every input change that invalidates the cached decision (the
    /// policy above all). A recompute commits only while it is unchanged since its inputs were read,
    /// so a decision made under an older policy can never overwrite one made under a newer one.
    private var inputGeneration: UInt64 = 0
    /// Guarded by `lock`. Tests only: runs between a recompute's evaluation and its commit.
    private var recomputeWillCommitHook: (() -> Void)?
    /// Whether this instance runs in an app extension: `isAppExtension` for `shared`, injected by
    /// tests. The customer-data facade, the attested bind and the hooks below answer for the main app
    /// only (this module is linked into the Notification Service Extension).
    let isExtensionProcess: Bool
    /// Guarded by `lock`: the main app's consent pipeline (`bindConsentProvider` and its siblings).
    /// Always nil in an extension.
    private var bindConsentProviderValue: ((Int64) -> [String: Any]?)?
    private var bindPermissionProviderValue: ((Int64) -> SGEntitlementBindPermission)?
    private var preRevokeUploadsProviderValue: ((Int64) -> [Data])?
    private var bindConsentRefusedValue: ((Int64, String) -> Void)?
    private var bindConsentStaleValue: ((Int64, String?) -> Void)?

    /// Tests construct their own instance to own the scheduler; the app uses `shared`.
    init(
        store: SGEntitlementStore = .shared,
        clock: SGEntitlementClock = .shared,
        identity: SGEntitlementDeviceIdentity = .shared,
        scheduler: SGEntitlementScheduler = SGEntitlementScheduler(),
        policyStore: SGEntitlementPolicyStore = .shared,
        policyClock: @escaping () -> Date = { Date() },
        publicPolicy: SGEntitlementPublicPolicyConfiguration? = nil,
        isPublicPolicyRequested: Bool = false,
        isAuthenticatedEntitlementConfigured: Bool = true,
        appleBackend: SGEntitlementAppleBackendConfiguration = .held,
        isExtensionProcess: Bool = SGEntitlement.isAppExtension
    ) {
        self.store = store
        self.clock = clock
        self.identity = identity
        self.scheduler = scheduler
        self.isExtensionProcess = isExtensionProcess
        // An explicit public policy reads and writes only its own origin's key: the bare legacy key
        // and every other origin's stay untouched, byte for byte. A requested but invalid one has no
        // origin and no cache at all.
        let scopedPolicyStore: SGEntitlementPolicyStore
        if let publicPolicy {
            scopedPolicyStore = policyStore.scoped(toOrigin: publicPolicy.origin)
        } else if isPublicPolicyRequested {
            scopedPolicyStore = SGEntitlementPolicyStore(defaults: nil)
        } else {
            // No explicit public policy: the authenticated (or keyless) build's policy is origin-bound
            // like every other origin-bound item — `zg.ent.policy.v1@<authority>`, never the bare
            // legacy key or another origin's.
            scopedPolicyStore = policyStore.scoped(toOrigin: store.scope.identifier)
        }
        self.policyStore = scopedPolicyStore
        // The app-update policy's slot: the same defaults, the same origin, its own layout key.
        self.appUpdatePolicyStore = scopedPolicyStore.rebased(to: SGEntitlementPolicyStore.appUpdateDefaultsKey)
        self.policyClock = policyClock
        self.publicPolicy = publicPolicy
        self.isPublicPolicyRequested = isPublicPolicyRequested
        self.isAuthenticatedEntitlementConfigured = isAuthenticatedEntitlementConfigured
        self.appleBackend = appleBackend
        self.defaults = UserDefaults(suiteName: SGProtectedKeychain.sharedAccessGroup)
        self.registerDarwinObserver()
        if !SGEntitlement.isAppExtension {
            // Notification NAMES only — this module is linked into extensions, so `UIApplication.shared`
            // is never touched (the same discipline as SGProtectedStore).
            let center = NotificationCenter.default
            self.observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.applicationDidBecomeActive()
            }))
            self.observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.applicationWillResignActive()
            }))
        }
    }

    // MARK: - Configuration

    /// Wires the values the transport needs. Call once, early, from the main app — it performs no
    /// I/O and no network call, so it is safe on the launch path.
    public func configure(appVersion: String, osVersion: String, deviceName: String) {
        let configuration = SGEntitlementClient.Configuration.shipped(appVersion: appVersion, osVersion: osVersion)
        self.lock.lock()
        self.deviceName = deviceName
        self.clientValue = configuration.map { configuration in
            SGEntitlementClient(configuration: configuration, store: self.store, clock: self.clock, identity: self.identity)
        }
        self.legacyPolicyEndpoint = configuration.map { SGEntitlementPolicyEndpoint.legacy($0) }
        self.legacyAppPolicyEndpoint = configuration.map { SGEntitlementPolicyEndpoint.legacyAppPolicy($0) }
        self.lock.unlock()
    }

    /// The transport. `nil` when `SG_CONFIG.apiUrl` is not usable in this build — every feature still
    /// works, the app simply never reaches the server.
    public var client: SGEntitlementClient? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.clientValue
    }

    /// Tests only: the client `configure(...)` would build (a scripted origin), or none.
    func installClientForTesting(_ client: SGEntitlementClient?) {
        self.lock.lock()
        self.clientValue = client
        self.lock.unlock()
    }

    /// Tests only: the policy transport `refreshMonetizationPolicy()` uses — so the lifecycle
    /// triggers (foreground, the periodic timer, the refresh push) can be driven against a scripted
    /// answer and counted. nil restores the build's own endpoint (or none).
    func installPolicyTransportForTesting(_ transport: SGEntitlementPolicyTransport?) {
        self.lock.lock()
        self.policyTransportOverride = transport
        self.lock.unlock()
    }

    /// Tests only: the transport `refreshAppUpdatePolicy()` uses instead of the app-policy endpoint.
    /// nil restores the build's own endpoint (or none).
    func installAppUpdatePolicyTransportForTesting(_ transport: SGEntitlementPolicyTransport?) {
        self.lock.lock()
        self.appUpdatePolicyTransportOverride = transport
        self.lock.unlock()
    }

    /// Tests only: the delay between a lifecycle trigger's monetization GET and its app-policy GET,
    /// instead of the random 5–30 s (`appUpdatePolicyStagger`). nil restores the random stagger.
    func overrideAppUpdatePolicyStaggerForTesting(_ delay: TimeInterval?) {
        self.lock.lock()
        self.appUpdatePolicyStaggerOverride = delay
        self.lock.unlock()
    }

    /// Tests only: the installed `CFBundleShortVersionString` the app-update decision compares.
    func overrideInstalledAppVersion(_ version: String?) {
        self.lock.lock()
        self.installedAppVersion = version
        self.lock.unlock()
    }

    /// Whether this build ships the authenticated entitlement backend (pinned keys AND a valid
    /// `api_url`). A build constant: correct before `configure(...)` has run, unlike `client`.
    public var isAuthenticatedBackendConfigured: Bool {
        return self.isAuthenticatedEntitlementConfigured
    }

    /// The session store, for the customer-data facade's per-binding receipts.
    var sessionStore: SGEntitlementStore {
        return self.store
    }

    // MARK: - Consent hooks (set by the main app's consent pipeline; nil in extensions)

    /// The account's local grant as the `consent` object of `/bind/start` (a grant ConsentEvent), or
    /// nil. Asked by `beginBind` only while `bindPermission` is `.allowed`.
    public var bindConsentProvider: ((Int64) -> [String: Any]?)? {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.bindConsentProviderValue
        }
        set {
            guard !self.isExtensionProcess else {
                return
            }
            self.lock.lock()
            self.bindConsentProviderValue = newValue
            self.lock.unlock()
        }
    }

    /// Whether `/bind/start` may run for an account (`bindPermission(accountPeerId:)`); `.allowed`
    /// while none is installed.
    public var bindPermissionProvider: ((Int64) -> SGEntitlementBindPermission)? {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.bindPermissionProviderValue
        }
        set {
            guard !self.isExtensionProcess else {
                return
            }
            self.lock.lock()
            self.bindPermissionProviderValue = newValue
            self.lock.unlock()
        }
    }

    /// The `/v1/profile/consents` bodies `logout` delivers with the session it removes (the account's
    /// un-acked withdraws): asked synchronously, before anything is purged; at most
    /// `logoutFinalUploadLimit` are sent.
    public var preRevokeUploadsProvider: ((Int64) -> [Data])? {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.preRevokeUploadsProviderValue
        }
        set {
            guard !self.isExtensionProcess else {
                return
            }
            self.lock.lock()
            self.preRevokeUploadsProviderValue = newValue
            self.lock.unlock()
        }
    }

    /// Told `(account, consent_id)` when `/bind/start` refused the attached consent as malformed
    /// (422 `invalid_consent`); the start is then retried once without it (an automatic start only
    /// while its permission still allows one, `startWithConsentFallback`).
    public var bindConsentRefused: ((Int64, String) -> Void)? {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.bindConsentRefusedValue
        }
        set {
            guard !self.isExtensionProcess else {
                return
            }
            self.lock.lock()
            self.bindConsentRefusedValue = newValue
            self.lock.unlock()
        }
    }

    /// Told `(account, consent_id)` when a MANUAL `/bind/start` answered 409 `consent_stale` for the
    /// attached consent (the grant predates an erasure of this Telegram id); the start is then retried
    /// once without it (`startWithConsentFallback`), so the consent store would otherwise never learn.
    /// An automatic start returns the failure instead (`bindWithTelegramAttestation`'s
    /// `.consentStale`). `consent_id` is nil when the attached consent named none.
    public var bindConsentStale: ((Int64, String?) -> Void)? {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.bindConsentStaleValue
        }
        set {
            guard !self.isExtensionProcess else {
                return
            }
            self.lock.lock()
            self.bindConsentStaleValue = newValue
            self.lock.unlock()
        }
    }

    /// Synchronous accessors, so an `async` caller never touches an `NSLock` (which is unavailable
    /// from an asynchronous context).
    private func currentDeviceName() -> String {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.deviceName
    }

    /// Whether `accountPeerId`'s binding still needs the current APNs token, and that token.
    func pendingTelemetry(accountPeerId: Int64) -> SGEntitlementPushTelemetry {
        return self.pushTelemetry(material: self.store.session(accountPeerId: accountPeerId))
    }

    private func pushTelemetry(material: SGEntitlementSessionMaterial) -> SGEntitlementPushTelemetry {
        self.lock.lock()
        let pushToken = self.pushToken
        self.lock.unlock()
        return SGEntitlementPushTelemetry(pushToken: pushToken, material: material)
    }

    private func currentPinnedKeys() -> SGEntitlementPinnedKeys {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.pinnedKeys
    }

    private func markFirstIdlePassed() {
        self.lock.lock()
        let isFirst = !self.didPassFirstIdle
        self.didPassFirstIdle = true
        self.lock.unlock()
        if isFirst {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: SGEntitlement.didPassFirstIdleNotification, object: nil)
            }
        }
    }

    /// Tests only: the first idle window has passed (`prewarm` does this 8 s after launch), so the
    /// lifecycle triggers may reach the (scripted) network.
    func markFirstIdlePassedForTesting() {
        self.markFirstIdlePassed()
    }

    /// Caller holds `lock`. Every input change that makes the cached decision stale goes through
    /// here, so `recompute` can tell that its inputs moved under it.
    private func invalidateCachedDecisionLocked() {
        self.cachedDecision = nil
        self.cachedDeviceWide = nil
        self.inputGeneration &+= 1
    }

    /// Tests only: runs between a recompute's evaluation and its commit, with no lock held.
    var recomputeWillCommitForTesting: (() -> Void)? {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.recomputeWillCommitHook
        }
        set {
            self.lock.lock()
            self.recomputeWillCommitHook = newValue
            self.lock.unlock()
        }
    }

    public var outbox: SGEntitlementOutbox {
        return SGEntitlementOutbox.shared
    }

    public var deviceIdentity: SGEntitlementDeviceIdentity {
        return self.identity
    }

    public var entitlementClock: SGEntitlementClock {
        return self.clock
    }

    /// Tests only: point verification at a different key set.
    ///
    /// Enforcement follows the keys: a test that installs a key set is testing the evaluation rule
    /// and must not accidentally land in the unconfigured-build branch, and one that installs an
    /// empty set is testing exactly that branch.
    func overridePinnedKeys(_ keys: SGEntitlementPinnedKeys) {
        self.lock.lock()
        self.pinnedKeys = keys
        self.enforcement = SGEntitlementEnforcement(
            canVerifyTokens: !keys.isEmpty,
            knowsProducts: SGEntitlementEnforcement.shipped.knowsProducts
        )
        self.invalidateCachedDecisionLocked()
        // The stored policy is re-verified against the ring now in force.
        self.didLoadPolicy = false
        self.lock.unlock()
    }

    /// Tests only: force the enforcement decision independently of the key set.
    func overrideEnforcement(_ value: SGEntitlementEnforcement) {
        self.lock.lock()
        self.enforcement = value
        self.invalidateCachedDecisionLocked()
        self.lock.unlock()
    }

    /// Tests only: pin the local grace. `nil` means "no record, and do not mint one" — the state of
    /// an extension on an install that has never evaluated. The paid-policy mark (D9) is pinned from
    /// the same value: `value.firstPaidPolicyAt`, so nil unless the test asks for the re-based
    /// window; a test that wants the REAL mark read (or minted) from the store calls
    /// `resetPaidModeMarkForTesting()` afterwards.
    func overrideLocalGrace(_ value: SGEntitlementLocalGrace?) {
        self.lock.lock()
        // Stored un-rebased, as the real load does; `localGrace(now:monetization:)` recombines.
        self.localGraceValue = value?.rebased(firstPaidPolicyAt: nil)
        self.didLoadLocalGrace = true
        self.paidModeMarkValue = value?.firstPaidPolicyAt
        self.didLoadPaidModeMark = true
        // Never let a test's record reach the Keychain through the high-water rewrite.
        self.localGraceSeenAtPersisted = .distantFuture
        self.invalidateCachedDecisionLocked()
        self.lock.unlock()
    }

    /// Tests only: forget both pinned records so the next evaluation reads (or mints) the real ones.
    func resetLocalGraceForTesting() {
        self.lock.lock()
        self.localGraceValue = nil
        self.didLoadLocalGrace = false
        self.localGraceSeenAtPersisted = .distantPast
        self.paidModeMarkValue = nil
        self.didLoadPaidModeMark = false
        self.invalidateCachedDecisionLocked()
        self.lock.unlock()
    }

    /// Tests only: forget the pinned paid-policy mark alone, so the next PAID evaluation reads — or,
    /// in the main app, mints — the real record through the store.
    func resetPaidModeMarkForTesting() {
        self.lock.lock()
        self.paidModeMarkValue = nil
        self.didLoadPaidModeMark = false
        self.invalidateCachedDecisionLocked()
        self.lock.unlock()
    }

    /// Tests only: the paid-policy mark as loaded or minted so far (nil before any paid evaluation).
    var paidModeMarkForTesting: Date? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.paidModeMarkValue
    }

    /// Tests only: pin the policy state (built from a really signed policy).
    func overridePolicyState(_ state: SGEntitlementPolicyState) {
        self.lock.lock()
        self.policyState = state
        self.didLoadPolicy = true
        self.invalidateCachedDecisionLocked()
        self.lock.unlock()
    }

    /// Tests only: forget the pinned policy so the next evaluation reads the stored one.
    func resetPolicyForTesting() {
        self.lock.lock()
        self.policyState = .initial
        self.didLoadPolicy = false
        self.invalidateCachedDecisionLocked()
        self.lock.unlock()
    }

    /// Tests only: forget the loaded app-update policy so the next read restores the stored one.
    func resetAppUpdatePolicyForTesting() {
        self.lock.lock()
        self.appUpdatePolicyState = .initial
        self.didLoadAppUpdatePolicy = false
        self.lock.unlock()
    }

    // MARK: - The predicate

    /// Is this CREATE allowed right now?
    ///
    /// Every case of `SGEntitlementGatedAction` creates new material — new retained-history capture
    /// (`createRetainedHistoryRecord`) included. Reads, un-hides, unlocks and deletes of existing
    /// material are in `SGEntitlementUnrestrictedAction`, which the overload below always answers
    /// `true` for; retained history is read and removed with no gate at all.
    public func can(_ action: SGEntitlementGatedAction) -> Bool {
        return self.isGranted(action.capability)
    }

    /// Always `true`, by contract — offline, forever, with no token at all.
    ///
    /// The overload exists so that a caller reaching for a gate on a read path finds a name that
    /// compiles and documents why there is nothing to check, instead of reaching for
    /// `SGEntitlementGatedAction` and inventing one. Mistaking the two therefore fails in the
    /// permissive direction, which is the only direction that does not cost someone their data.
    public func can(_ action: SGEntitlementUnrestrictedAction) -> Bool {
        return true
    }

    /// `can(_:)` plus the reason, for the paywall's copy. A blocked action shows the PAYWALL — never
    /// an error, never a retry loop, never "contact support", and never a purchase link that leaves
    /// the App Store (guideline 3.1.3(b)).
    public func gate(_ action: SGEntitlementGatedAction) -> SGEntitlementGateResult {
        return self.gateResult(for: action.capability)
    }

    /// The app-group flag the Postbox replay reads before recording new retained history
    /// (`SGSimpleSettings.editHistoryCaptureBlocked`), or nil to leave the stored value alone while no
    /// account is known yet. See `SGEntitlementRetainedHistoryCapture`.
    public var retainedHistoryCaptureBlockedFlag: Bool? {
        return SGEntitlementRetainedHistoryCapture.blockedFlag(
            captureAllowed: self.can(.createRetainedHistoryRecord),
            isDecisionKnown: self.activeAccountPeerId != nil
        )
    }

    /// The one rule behind every `can(_:)`: the active account's decision, then — for the
    /// device-global capabilities — the union over every linked account on the install.
    private func isGranted(_ capability: SGEntitlementCapability) -> Bool {
        if self.has(capability) {
            return true
        }
        // Tasks, Chat Lock pincodes and Edit History's capture flag are one store / one replay flag
        // per INSTALL, so their gate is the union over every linked account — otherwise switching the
        // account switcher to an unlinked account paywalls the task list the OTHER account paid for,
        // and stops capturing in the chats of the account that pays for it (invariant I2: never fail
        // toward losing data).
        guard capability.isDeviceGlobal else {
            return false
        }
        return self.deviceWideHas(capability)
    }

    private func gateResult(for capability: SGEntitlementCapability) -> SGEntitlementGateResult {
        let decision = self.currentDecision()
        if decision.state.has(capability) {
            return .allowed
        }
        if capability.isDeviceGlobal, self.deviceWideHas(capability) {
            // Another account on this install pays for the store this action writes to.
            // See `SGEntitlementCapability.isDeviceGlobal`.
            return .allowed
        }
        guard let reason = decision.state.degradedReason else {
            // Unlocked, but this capability is not in the list: the subscription is fine and the
            // feature is simply not enabled for this account (today, only `ai`). A paywall here would
            // sell something that would not change the answer.
            return .unavailable
        }
        return .blocked(reason: reason)
    }

    /// Raw capability predicate.
    ///
    /// Use it for UI that DESCRIBES the subscription (the paywall, a settings badge) and for the
    /// whole-feature gate of a feature that holds no pre-existing user data — `has(.ai)` is the only
    /// such feature. **Never use it to gate access to data the user already has**: that is what
    /// `SGEntitlementUnrestrictedAction` is for.
    public func has(_ capability: SGEntitlementCapability) -> Bool {
        return self.currentDecision().state.has(capability)
    }

    /// Whether the AI Assistant may be shown.
    ///
    /// The entitlement's `ai` capability is NECESSARY but not SUFFICIENT, and that is deliberate.
    /// Enabling the assistant changes what leaves the device — message text goes to a third-party
    /// model — and the App Privacy answers, the privacy policy and the store metadata all describe
    /// an app that does not do that. A capability string arriving from the server could otherwise
    /// make every one of those documents false on installed binaries, with no release and no
    /// review. Apple requires the shipped app's disclosure to be accurate; a remotely flippable
    /// data-collection switch cannot satisfy that.
    ///
    /// So the build must also opt in: `has(.ai)` is false while `.ai` is in
    /// `SGEntitlementCapability.refusedByThisBuild`, even under `"*"`. Removing it from that set is
    /// the release in which the privacy documents are updated; until then the server may carry
    /// `ai` harmlessly. See appstore/CHECKLIST.md.
    public var isAIAssistantAvailable: Bool {
        return self.has(.ai)
    }

    /// Does ANY Telegram account signed in on this install currently grant `capability`?
    ///
    /// Only the device-global capabilities ask this (`SGEntitlementCapability.isDeviceGlobal`). The
    /// union is decided together with the active account's decision in `recompute` — once per
    /// account, cached until the earliest horizon among them — so it stays synchronous, offline and
    /// off the main thread's way, exactly like every other predicate in this class. Crossing the
    /// union's own horizon (another account's token lapsing) goes through the same `recompute`, so
    /// the mirror, the horizon timer and `didChangeNotification` follow the union exactly as they
    /// follow the active account: new capture that runs on another account's subscription stops
    /// when that subscription ends, instead of outliving it until the next foreground.
    private func deviceWideHas(_ capability: SGEntitlementCapability) -> Bool {
        let now = self.clock.effectiveNow()
        self.lock.lock()
        if let cached = self.cachedDeviceWide, now < cached.validUntil {
            self.lock.unlock()
            return cached.grants(capability)
        }
        self.lock.unlock()
        self.recompute(now: now, notify: false)
        self.lock.lock()
        let value = self.cachedDeviceWide
        self.lock.unlock()
        return value?.grants(capability) ?? false
    }

    public var state: SGEntitlementState {
        return self.currentDecision().state
    }

    public var source: SGEntitlementSource {
        return self.currentDecision().source
    }

    /// The mode the app acts on: the last verified monetization policy's, FREE until the owner
    /// deliberately enables paid mode — and always FREE in a public-policy-only build
    /// (`isPublicPolicyOnly`), which has no way to sell or verify anything. Synchronous, offline,
    /// from the cached and re-verified policy.
    public var monetizationMode: SGEntitlementPolicyMode {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.effectiveMonetizationLocked()
    }

    /// True when this build asked for an explicit public policy (`sg_config` named either key — even
    /// an invalid one) but does NOT ship the authenticated entitlement client: it verifies the two
    /// public policies and nothing else. The app then stays FREE whatever the signed monetization
    /// policy says (no plan, no countdown, no purchase admission), and `SGIAP` leaves every App Store
    /// transaction and attach entry exactly as it found it; the app-update policy still applies —
    /// it is about the build, not about selling. A build constant.
    public var isPublicPolicyOnly: Bool {
        return (self.publicPolicy != nil || self.isPublicPolicyRequested) && !self.isAuthenticatedEntitlementConfigured
    }

    /// The single Apple predicate: the explicit build flag, the authenticated configuration, a
    /// non-empty product list, and not public-policy-only. While false, nothing from StoreKit grants, and
    /// SGIAP starts no listener, snapshot, provenance re-read, drain, delivery, Restore or purchase.
    public var isAppleBackendEnabled: Bool {
        return self.appleBackend.isEnabled(isAuthenticatedEntitlementConfigured: self.isAuthenticatedEntitlementConfigured, isPublicPolicyOnly: self.isPublicPolicyOnly)
    }

    /// The accepted signed policy itself, for diagnostics only — in a public-policy-only build it
    /// may say paid while `monetizationMode` stays free. nil before the first verified policy.
    public var signedMonetizationPolicy: SGEntitlementPolicy? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.loadPolicyLocked().accepted
    }

    /// May a NEW purchase, plan switch or trial start right now? Asked again by `SGIAP` immediately
    /// before anything is sent to Apple or the server, so a paywall left on screen when the policy
    /// turned free cannot charge anyone. Restore, attach of already-paid transactions, linking and
    /// Apple's management page never ask this.
    public var offersNewSubscriptions: Bool {
        return self.monetizationMode == .paid
    }

    /// The server's own trial the paywall may offer, in days: the accepted policy's signed
    /// `trial_days` (`SGEntitlementPolicy.offersServerTrial`), or nil when there is nothing to
    /// offer — no accepted policy, a free policy, a v1 policy (which cannot say), `trial_days` 0,
    /// or a public-policy-only build, which is always FREE whatever the signed policy says
    /// (`effectiveMonetizationLocked`). Synchronous, offline, from the cached and re-verified
    /// policy. Never purchase admission (`authorizeNewPurchase` is), and never the trial's real
    /// end: that is `trial_ends_at` from `POST /v1/trial/start`, granted for the policy's days at
    /// start time. An open paywall re-reads it on `didChangeNotification`, which every adopted
    /// policy posts (`performPolicyRefresh`, `authorizeNewPurchase`) — a change of `trial_days`
    /// alone included, though no decision moves for it.
    public var serverTrialDays: Int? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard self.effectiveMonetizationLocked() == .paid, let policy = self.loadPolicyLocked().accepted, policy.offersServerTrial else {
            return nil
        }
        return policy.trialDays
    }

    /// The end of the local 7-day grace — "free until <date>" — or nil once it has passed (or, in an
    /// extension on an install that has never evaluated, never). It is the window's own horizon,
    /// independent of what is currently granting: a paywall / status surface shows it when `source`
    /// is `.localGrace`, and may still mention it while a token or a purchase grants in front of it.
    /// Always nil while the policy is free: free access is not a countdown. In paid mode it is the
    /// re-based window (D9): seven days from the later of first launch and the first adopted paid
    /// policy.
    public var localGraceEndsAt: Date? {
        guard self.monetizationMode == .paid else {
            return nil
        }
        let now = self.clock.effectiveNow()
        guard let grace = self.localGrace(now: now, monetization: .paid).grace, grace.isActive(at: now) else {
            return nil
        }
        return grace.endsAt
    }

    /// The account's genuine grant horizon (`account_until`) read the CHEAP way: for the active
    /// account from the cached decision — computed off-main by `prewarm`, re-decided only at its
    /// horizon or on new material — so the Settings row, the deep link and the Pro visibility signal
    /// (`sgProSettingsRowOpensStatus`, asked on the main thread on every Settings rebuild and every
    /// `didChangeNotification`) cost a lock, not a Keychain read plus an ES256 verification. Another
    /// account's token is re-verified (`genuineGrantUntil`), as the status screen does for its own
    /// account. nil for a legacy token, a locked grant or no token.
    public func cachedGrantUntil(accountPeerId: Int64) -> Date? {
        guard self.activeAccountPeerId == accountPeerId else {
            return self.genuineGrantUntil(accountPeerId: accountPeerId)
        }
        return self.currentDecision().claims?.accountGrant?.untilDate
    }

    /// The account's GENUINE grant horizon (`account_until`) from its stored, verifying token — what
    /// the status screen may quote while that token is what grants. A Keychain read and a signature
    /// check on the caller's thread: for a hot path prefer `cachedGrantUntil`. nil for a legacy
    /// token, a locked grant or no token.
    public func genuineGrantUntil(accountPeerId: Int64) -> Date? {
        let material = self.store.session(accountPeerId: accountPeerId)
        guard let jws = material.entitlement,
              case let .success(claims) = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: self.currentPinnedKeys(), boundDeviceId: material.deviceId, boundAccountId: material.accountId, accountPeerId: accountPeerId)
        else {
            return nil
        }
        return claims.accountGrant?.untilDate
    }

    /// D9 — the one-time notice for the first CREATE the paid flip blocks, or nil.
    ///
    /// Asked by the gate's UI half (`sgPresentPayWall`) with the reason a create was just blocked
    /// for. A user who never subscribed needs the offer, not an explanation — so `.noToken` shows no
    /// reason copy — except once: the first time a create is blocked after the owner enabled paid
    /// mode, this install says that Zenlygram Pro is now a subscription. Answered exactly once per
    /// FLIP — a free policy giving way to a paid one on this install — and never while the policy
    /// is free, in an extension, or for any other degraded reason (those have their own copy). The
    /// marker lives beside the policy (`SGEntitlementPolicyStore.loadNoticedRevision`): nil while
    /// the notice is pending, set once it is shown, so a relaunch does not repeat it. The server
    /// bumps `revision` on every admin `set` (a price text, a trial setting), so a paid -> paid
    /// revision is NOT a flip and announces nothing; a flip back to free and then to paid again does
    /// (`finishPolicyAttempt` clears the marker at that transition). An install whose first adopted
    /// policy is already paid never knew Pro as free and is never told it "is now" a subscription.
    public func takePaidModeNotice(for reason: SGEntitlementDegradedReason) -> SGEntitlementMessage? {
        guard reason == .noToken, !self.isExtensionProcess else {
            return nil
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard self.effectiveMonetizationLocked() == .paid, let revision = self.loadPolicyLocked().accepted?.revision else {
            return nil
        }
        // Check-then-set under the lock: two blocked creates racing each other show one notice.
        guard self.policyStore.loadNoticedRevision() == nil else {
            return nil
        }
        self.policyStore.saveNoticedRevision(revision)
        return .paidModeNotice
    }

    /// The copy a degraded surface shows, or nil while unlocked. An unknown `kid` that has persisted
    /// upgrades the message to "update the app".
    public var degradedMessage: SGEntitlementMessage? {
        let decision = self.currentDecision()
        guard let reason = decision.state.degradedReason else {
            return nil
        }
        self.lock.lock()
        let sawUnknownKid = self.didSeeUnknownKid
        self.lock.unlock()
        if reason == .unverifiable && sawUnknownKid {
            return .updateTheApp
        }
        return SGEntitlementMessage.forDegraded(reason)
    }

    // MARK: - Static forwarders (the call shape feature code uses)

    public static func can(_ action: SGEntitlementGatedAction) -> Bool {
        return SGEntitlement.shared.can(action)
    }

    public static func can(_ action: SGEntitlementUnrestrictedAction) -> Bool {
        return SGEntitlement.shared.can(action)
    }

    public static func gate(_ action: SGEntitlementGatedAction) -> SGEntitlementGateResult {
        return SGEntitlement.shared.gate(action)
    }

    public static func has(_ capability: SGEntitlementCapability) -> Bool {
        return SGEntitlement.shared.has(capability)
    }

    // MARK: - Accounts

    /// The Telegram account whose binding governs right now. The app supports several, and each has
    /// its own binding, refresh token and JWS. `peerId` is `PeerId.toInt64()`, the same key
    /// `SGProtectionSnapshot` uses.
    public func setActiveAccount(peerId: Int64?) {
        self.setAccounts(SGEntitlementAccounts(primary: peerId, all: peerId.map { [$0] } ?? []))
    }

    /// The primary account AND the full set signed in on this install.
    ///
    /// The set matters because the device-global gates (`SGEntitlementCapability.isDeviceGlobal`)
    /// are evaluated over all of it. It must be re-fed when the SET changes and not only when the
    /// primary does — adding or removing an account moves the union without moving `primary`.
    public func setAccounts(_ accounts: SGEntitlementAccounts) {
        self.lock.lock()
        let changed = self.activeAccount != accounts.primary || self.knownAccounts != accounts.all
        self.activeAccount = accounts.primary
        self.knownAccounts = accounts.all
        if changed {
            self.invalidateCachedDecisionLocked()
        }
        let mayRefresh = self.didPassFirstIdle
        self.lock.unlock()
        // Published, even if unchanged or empty: a push waiting for the accounts may read them now.
        self.accountsReady.open(queue: self.refreshQueue)
        if changed {
            self.recomputeAndNotifyIfChanged()
            // A switch to (or the arrival of) an account whose token is a day old asks the server
            // now rather than at the next foreground — with the same staleness rule, and never
            // before the first idle window after launch.
            if mayRefresh {
                self.refresh(trigger: .foreground)
            }
        }
    }

    public var activeAccountPeerId: Int64? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.activeAccount
    }

    public func isLinked(accountPeerId: Int64) -> Bool {
        return self.store.session(accountPeerId: accountPeerId).isLinked
    }

    public func session(accountPeerId: Int64) -> SGEntitlementSessionMaterial {
        return self.store.session(accountPeerId: accountPeerId)
    }

    /// The session an authenticated request for `accountPeerId` should run under, captured NOW — or
    /// nil when the account holds no binding. Capture it once per request and hand the same value
    /// to the client and to whatever applies the response (`adopt`, `apply`).
    public func sessionCredential(accountPeerId: Int64) -> SGEntitlementSessionCredential? {
        guard let refreshToken = self.store.session(accountPeerId: accountPeerId).refreshToken else {
            return nil
        }
        return SGEntitlementSessionCredential(accountPeerId: accountPeerId, refreshToken: refreshToken)
    }

    // MARK: - Tasks transport inputs (`SGEntitlementTasks.swift`)

    /// The session store, clock and install identity the Tasks transport reads afresh for every
    /// attempt. Nothing from them is cached across attempts.
    var tasksTransportParts: (store: SGEntitlementStore, clock: SGEntitlementClock, identity: SGEntitlementDeviceIdentity) {
        return (self.store, self.clock, self.identity)
    }

    /// The sponsor `creation_proof` for a create owned by `owner`, chosen from every account signed in
    /// on this install as they are NOW (`SGTasksCreationProof`). Never stored.
    func tasksCreationProof(owner: Int64) -> String? {
        self.lock.lock()
        var accounts = Set(self.knownAccounts)
        if let active = self.activeAccount {
            accounts.insert(active)
        }
        let keys = self.pinnedKeys
        self.lock.unlock()
        let candidates = accounts.sorted().map { account in
            SGTasksCreationProof.Candidate(accountPeerId: account, material: self.store.session(accountPeerId: account))
        }
        // The later of the evaluation clock and the server-offset transmit clock: a token about to
        // expire by either is not offered.
        let transmitted = Date(timeIntervalSince1970: TimeInterval(self.clock.transmitTimestamp()))
        let now = max(self.clock.effectiveNow(), transmitted)
        return SGTasksCreationProof.select(owner: owner, candidates: candidates, pinnedKeys: keys, now: now)
    }

    // MARK: - Lifecycle

    /// Computes the first decision off the main thread and schedules the first refresh AFTER the
    /// first idle window. Call it from the app's post-launch idle hook, never from `application(_:
    /// didFinishLaunchingWithOptions:)`'s critical path.
    public func prewarm() {
        self.refreshQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.recomputeAndNotifyIfChanged()
            self.refreshQueue.asyncAfter(deadline: .now() + SGEntitlementScheduler.firstIdleDelay) { [weak self] in
                self?.markFirstIdlePassed()
                self?.refreshMonetizationPolicy()
                self?.scheduleAppUpdatePolicyRefresh()
                self?.refresh(trigger: .firstIdleAfterLaunch)
                self?.requestDueAccountClaims()
            }
        }
    }

    /// Foreground. On a cold launch this also fires before the first idle window; nothing reaches
    /// the network then (invariant I1) — the first-idle pass above does it. Also arms the periodic
    /// policy refresh that runs while the app stays active (`startPolicyRefreshTimer`).
    public func applicationDidBecomeActive() {
        self.startPolicyRefreshTimer()
        self.refreshQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.invalidate()
            if self.hasPassedFirstIdle {
                self.refreshMonetizationPolicy()
                self.scheduleAppUpdatePolicyRefresh()
                self.requestDueAccountClaims()
            }
            self.refresh(trigger: .foreground)
        }
    }

    /// The app is leaving the foreground: the periodic policy refresh stops with it. The next
    /// foreground refreshes at once and re-arms it, so nothing is lost by stopping.
    public func applicationWillResignActive() {
        self.stopPolicyRefreshTimer()
    }

    /// Arms the repeating policy refresh (`SGEntitlementScheduler.policyRefreshInterval`), once:
    /// a second become-active while it runs keeps the running one. Never in an extension.
    private func startPolicyRefreshTimer() {
        guard !SGEntitlement.isAppExtension else {
            return
        }
        self.lock.lock()
        guard self.policyRefreshTimer == nil else {
            self.lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: self.refreshQueue)
        let interval = SGEntitlementScheduler.policyRefreshInterval
        // A minute of leeway: the fetch is a coalescable background GET, not a deadline.
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            self?.policyRefreshTimerDidFire()
        }
        self.policyRefreshTimer = timer
        self.lock.unlock()
        timer.resume()
    }

    private func stopPolicyRefreshTimer() {
        self.lock.lock()
        let timer = self.policyRefreshTimer
        self.policyRefreshTimer = nil
        self.lock.unlock()
        timer?.cancel()
    }

    /// One tick of the periodic refresh: the same gated fetches every other lifecycle trigger makes
    /// (`refreshMonetizationPolicy`, then the staggered `refreshAppUpdatePolicy`), so a tick landing
    /// inside a 60 s cooldown or beside a request in flight sends nothing. Never before the first
    /// idle window (invariant I1). The tick keeps running while an update block is up, so a
    /// corrected app-update policy lifts it within one interval.
    func policyRefreshTimerDidFire() {
        guard self.hasPassedFirstIdle else {
            return
        }
        self.refreshMonetizationPolicy()
        self.scheduleAppUpdatePolicyRefresh()
    }

    /// Whether the periodic policy refresh is armed (active app). Tests read it.
    var isPolicyRefreshTimerScheduled: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.policyRefreshTimer != nil
    }

    private var hasPassedFirstIdle: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.didPassFirstIdle
    }

    /// Whether the first idle window after launch has passed (`didPassFirstIdleNotification`).
    public var hasPassedFirstIdleWindow: Bool {
        return self.hasPassedFirstIdle
    }

    // MARK: - Monetization policy

    /// Asks `GET /v1/monetization` for the current signed policy — independent of any binding, never
    /// blocking the caller, at most one request in flight and at least 60 s between attempts
    /// (`SGEntitlementPolicyRefreshGate`). Called at the first idle window after launch, on every
    /// later foreground, every `SGEntitlementScheduler.policyRefreshInterval` while the app stays
    /// active, on the server's refresh push (`handleSilentPush`) and when a Pro screen opens — so a
    /// flip on the server reaches an open app within 30 minutes and a closed one at its next
    /// launch. A failure changes nothing: the last verified mode stands. An explicit public policy
    /// is fetched with no authenticated client at all.
    public func refreshMonetizationPolicy() {
        guard !SGEntitlement.isAppExtension, let transport = self.policyTransport() else {
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            _ = await self?.performPolicyRefresh(transport: transport, uptime: uptime)
        }
    }

    /// The anonymous policy GET this build makes: the explicit public endpoint, or — without one —
    /// the authenticated base URL's, once `configure(...)` has run. nil when there is neither, and
    /// for a requested-but-invalid public configuration (never the legacy endpoint instead).
    private func policyTransport() -> SGEntitlementPolicyTransport? {
        self.lock.lock()
        let override = self.policyTransportOverride
        let endpoint = self.legacyPolicyEndpoint
        self.lock.unlock()
        if let override {
            return override
        }
        if let publicPolicy = self.publicPolicy {
            return SGEntitlementPolicyTransport.live(publicPolicy.endpoint)
        }
        guard !self.isPublicPolicyRequested else {
            return nil
        }
        return endpoint.map { SGEntitlementPolicyTransport.live($0) }
    }

    /// One gated policy refresh: fetch, verify against the policy ring and the POLICY clock (never
    /// the account clock mark), adopt only a newer `(revision, iat)`, persist the exact signed bytes,
    /// re-decide and publish. A public-policy-only build re-decides nothing: its decision never
    /// follows the signed mode (`effectiveMonetizationLocked`).
    func performPolicyRefresh(transport: SGEntitlementPolicyTransport, uptime: TimeInterval) async -> SGEntitlementPolicyRefreshAttempt {
        guard self.beginPolicyAttempt(uptime: uptime, forPurchase: false) else {
            return .skipped
        }
        let answer = await transport.fetch()
        guard let finished = self.finishPolicyAttempt(answer, now: self.policyClock()) else {
            return .failed
        }
        let outcome = finished.0
        switch outcome {
        case .adopted:
            if !self.isPublicPolicyOnly {
                // `notify: true` posts `didChangeNotification` whether or not the decision moved:
                // an adopted policy may change only its `trial_days` (`serverTrialDays`), which
                // no decision reflects but an open paywall must re-read.
                self.recompute(now: self.clock.effectiveNow(), notify: true)
            }
            return .adopted
        case .unchanged:
            return .unchanged
        case .rejected:
            return .rejected
        }
    }

    /// May a NEW App Store purchase start right now? Fetches the public signed policy FOR THIS
    /// PURCHASE and answers from what that fetch proves — never from the cached mode: `.paid` only
    /// when the freshly fetched policy verified, is inside its signed window and is (or equals) the
    /// newest accepted one, and the resulting mode is paid. A transport failure, an invalid, older
    /// or conflicting answer is `.unavailable`; a fresh free policy is adopted and answers `.free`.
    ///
    /// Not held back by the background refresh cooldown (the user asked), but never a second policy
    /// request beside one in flight: that answers `.busy`, retryable. Needs no account binding —
    /// the policy names no one. Called by `SGIAP` before every new purchase; Restore, attach and
    /// existing grants never ask. Always `.unavailable` in a public-policy-only build, with no
    /// request: it has nothing to sell and no server to attach a purchase to.
    public func authorizeNewPurchase() async -> SGEntitlementPurchaseAuthorization {
        guard !SGEntitlement.isAppExtension, !self.isPublicPolicyOnly, let transport = self.policyTransport() else {
            return .unavailable
        }
        return await self.authorizeNewPurchase(transport: transport)
    }

    func authorizeNewPurchase(transport: SGEntitlementPolicyTransport) async -> SGEntitlementPurchaseAuthorization {
        guard !self.isPublicPolicyOnly else {
            return .unavailable
        }
        guard self.beginPolicyAttempt(uptime: ProcessInfo.processInfo.systemUptime, forPurchase: true) else {
            return .busy
        }
        let answer = await transport.fetch()
        guard let finished = self.finishPolicyAttempt(answer, now: self.policyClock()) else {
            return .unavailable
        }
        let mode = finished.1
        switch finished.0 {
        case .adopted:
            // Posted whether or not the decision moved, as in `performPolicyRefresh`: the fetched
            // policy's `trial_days` may be all that changed.
            self.recompute(now: self.clock.effectiveNow(), notify: true)
            return mode == .paid ? .paid : .free
        case .unchanged:
            return mode == .paid ? .paid : .free
        case .rejected:
            return .unavailable
        }
    }

    private func beginPolicyAttempt(uptime: TimeInterval, forPurchase: Bool) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if forPurchase {
            return self.policyGate.beginPurchaseAuthorization(uptime: uptime)
        }
        return self.policyGate.begin(uptime: uptime)
    }

    /// Ends the attempt and applies a fetched token: what happened to it, and the mode that results.
    /// nil after a transport failure. `.adopted` covers a newer issuance AND the accepted issuance
    /// in its v2 shape (`trial_days` now legible); the caller re-decides and publishes for both,
    /// since `serverTrialDays` may have changed without the mode.
    private func finishPolicyAttempt(_ answer: Result<String, SGEntitlementRequestError>, now: Date) -> (SGEntitlementPolicyOutcome, SGEntitlementPolicyMode)? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.policyGate.finish()
        guard case let .success(token) = answer else {
            return nil
        }
        let previous = self.loadPolicyLocked()
        let acceptance = previous.accepting(fetched: token, pinnedKeys: self.policyKeysLocked(), now: now)
        if case .adopted = acceptance.outcome {
            self.policyState = acceptance.state
            // Only a decision that follows the signed mode is stale now; a public-policy-only one
            // is always made under FREE (`effectiveMonetizationLocked`) and stays.
            if !self.isPublicPolicyOnly {
                self.invalidateCachedDecisionLocked()
            }
            // Persisted under the lock so the stored bytes always match the adopted order. A failed
            // write keeps the mode for this process; the next launch re-fetches.
            self.policyStore.save(token)
            self.notePaidModeTransitionLocked(from: previous.accepted, to: acceptance.state.accepted)
        }
        return (acceptance.outcome, acceptance.state.mode)
    }

    /// Caller holds `lock`. D9 — keeps the one-time notice's marker (`takePaidModeNotice`) in step
    /// with the FLIP rather than with the revision, at the moment a policy is adopted.
    private func notePaidModeTransitionLocked(from previous: SGEntitlementPolicy?, to adopted: SGEntitlementPolicy?) {
        guard let adopted, adopted.mode == .paid else {
            // Adopting a free policy announces nothing and changes no marker: the next free -> paid
            // transition clears it.
            return
        }
        guard let previous else {
            // The first policy this install ever adopted is already paid (first launched after the
            // flip): it never knew Pro as free under a policy, so there is no flip to announce.
            self.policyStore.saveNoticedRevision(adopted.revision)
            return
        }
        if previous.mode == .free {
            // free -> paid: the flip reached this install; the next blocked create says so, once.
            self.policyStore.saveNoticedRevision(nil)
        }
        // paid -> paid (an operator edit of the same mode): not a flip. A pending notice stays
        // pending, a shown one stays shown.
    }

    /// Caller holds `lock`.
    private func loadPolicyLocked() -> SGEntitlementPolicyState {
        if !self.didLoadPolicy {
            self.policyState = SGEntitlementPolicyState.restoring(stored: self.policyStore.load(), pinnedKeys: self.policyKeysLocked())
            self.didLoadPolicy = true
        }
        return self.policyState
    }

    /// Caller holds `lock`. The ring the two public policies verify against — exactly the two, the
    /// monetization policy (`SGEntitlementPolicyVerifier`) and the app-update policy
    /// (`SGAppUpdatePolicyVerifier`), each verifier refusing the other's audience: the explicit
    /// public policy's own ring, or — without one — the entitlement ring, as always. Never the other
    /// way round: the public ring verifies no entitlement token.
    private func policyKeysLocked() -> SGEntitlementPinnedKeys {
        if let publicPolicy = self.publicPolicy {
            return publicPolicy.pinnedKeys
        }
        if self.isPublicPolicyRequested {
            // Requested but invalid: nothing verifies, rather than the entitlement ring.
            return SGEntitlementPinnedKeys(keysByKid: [:])
        }
        return self.pinnedKeys
    }

    /// Caller holds `lock`. The mode every decision is made under (`monetizationMode`).
    private func effectiveMonetizationLocked() -> SGEntitlementPolicyMode {
        if self.isPublicPolicyOnly {
            return .free
        }
        return self.loadPolicyLocked().mode
    }

    // MARK: - App-update policy

    /// How long after a lifecycle trigger's monetization GET its app-policy GET follows: a random
    /// delay in this range, drawn per trigger (`appUpdatePolicyStaggerDelay`), so the two anonymous
    /// GETs of every device never land on the origin in the same instant and the per-IP buckets see
    /// one request at a time. Spec §1 / §4d.
    static let appUpdatePolicyStagger: ClosedRange<TimeInterval> = 5 ... 30

    static func appUpdatePolicyStaggerDelay() -> TimeInterval {
        return TimeInterval.random(in: SGEntitlement.appUpdatePolicyStagger)
    }

    /// `refreshAppUpdatePolicy()` a random 5–30 s after the monetization refresh of the same trigger
    /// (first idle, foreground, the periodic tick — never the silent push). A pile of pending
    /// delays is harmless: each lands on the gate, which sends at most one request per 60 s.
    private func scheduleAppUpdatePolicyRefresh() {
        guard !SGEntitlement.isAppExtension else {
            return
        }
        self.lock.lock()
        let delay = self.appUpdatePolicyStaggerOverride ?? SGEntitlement.appUpdatePolicyStaggerDelay()
        self.lock.unlock()
        self.refreshQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refreshAppUpdatePolicy()
        }
    }

    /// Asks `GET /v1/app-policy` for the current signed app-update policy — independent of any
    /// binding, never blocking the caller, at most one request in flight and at least 60 s between
    /// attempts on a gate of its own (`appUpdatePolicyGate`: it never consumes the monetization
    /// gate or the purchase slot). Called a random 5–30 s after `refreshMonetizationPolicy()` at
    /// the first idle window after launch, on every later foreground and on every periodic tick —
    /// NEVER from the silent push (`handleSilentPush`), which is the entitlement's, and never in an
    /// extension. A 429, a 503, an offline answer or an invalid token changes nothing: the accepted
    /// policy stands, and a block that cannot be refreshed lifts itself after 30 days
    /// (`SGAppUpdateDecision.blockValve`). An adopted policy re-decides and posts
    /// `SGAppUpdate.decisionDidChange` on the main queue.
    public func refreshAppUpdatePolicy() {
        guard !SGEntitlement.isAppExtension, let transport = self.appUpdatePolicyTransport() else {
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            _ = await self?.performAppUpdatePolicyRefresh(transport: transport, uptime: uptime)
        }
    }

    /// The anonymous app-policy GET this build makes: the explicit public origin's
    /// (`SGEntitlementPublicPolicyConfiguration.appPolicyEndpoint`), or — without one — the
    /// authenticated base URL's, once `configure(...)` has run. nil when there is neither, and for
    /// a requested-but-invalid public configuration, exactly like `policyTransport()`.
    private func appUpdatePolicyTransport() -> SGEntitlementPolicyTransport? {
        self.lock.lock()
        let override = self.appUpdatePolicyTransportOverride
        let endpoint = self.legacyAppPolicyEndpoint
        self.lock.unlock()
        if let override {
            return override
        }
        if let publicPolicy = self.publicPolicy {
            return SGEntitlementPolicyTransport.live(publicPolicy.appPolicyEndpoint)
        }
        guard !self.isPublicPolicyRequested else {
            return nil
        }
        return endpoint.map { SGEntitlementPolicyTransport.live($0) }
    }

    /// One gated app-policy refresh: fetch, verify against the policy ring and the POLICY clock,
    /// adopt only a newer `(revision, iat)`, persist the exact signed bytes, re-decide and publish.
    func performAppUpdatePolicyRefresh(transport: SGEntitlementPolicyTransport, uptime: TimeInterval) async -> SGEntitlementPolicyRefreshAttempt {
        guard self.beginAppUpdatePolicyAttempt(uptime: uptime) else {
            return .skipped
        }
        let answer = await transport.fetch()
        guard let outcome = self.finishAppUpdatePolicyAttempt(answer, now: self.policyClock()) else {
            return .failed
        }
        switch outcome {
        case .adopted:
            self.publishAppUpdateDecision()
            return .adopted
        case .unchanged:
            return .unchanged
        case .rejected:
            return .rejected
        }
    }

    private func beginAppUpdatePolicyAttempt(uptime: TimeInterval) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.appUpdatePolicyGate.begin(uptime: uptime)
    }

    /// Ends the attempt and applies a fetched token: what happened to it, or nil after a transport
    /// failure.
    private func finishAppUpdatePolicyAttempt(_ answer: Result<String, SGEntitlementRequestError>, now: Date) -> SGAppUpdatePolicyOutcome? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.appUpdatePolicyGate.finish()
        guard case let .success(token) = answer else {
            return nil
        }
        let acceptance = self.loadAppUpdatePolicyLocked().accepting(fetched: token, pinnedKeys: self.policyKeysLocked(), now: now)
        if case .adopted = acceptance.outcome {
            self.appUpdatePolicyState = acceptance.state
            // Persisted under the lock so the stored bytes always match the adopted order. A failed
            // write keeps the policy for this process; the next launch re-fetches.
            self.appUpdatePolicyStore.save(token)
        }
        return acceptance.outcome
    }

    /// Caller holds `lock`.
    private func loadAppUpdatePolicyLocked() -> SGAppUpdatePolicyState {
        if !self.didLoadAppUpdatePolicy {
            self.appUpdatePolicyState = SGAppUpdatePolicyState.restoring(stored: self.appUpdatePolicyStore.load(), pinnedKeys: self.policyKeysLocked())
            self.didLoadAppUpdatePolicy = true
        }
        return self.appUpdatePolicyState
    }

    /// The accepted signed app-update policy itself, for diagnostics; nil before the first verified
    /// one.
    public var signedAppUpdatePolicy: SGAppUpdatePolicy? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.loadAppUpdatePolicyLocked().accepted
    }

    /// What the app shows for its installed version (`SGAppUpdateDecision.evaluate`): the stored,
    /// re-verified policy, `CFBundleShortVersionString`, the reminder marker and the policy clock,
    /// read under the lock — synchronous and offline, so a known-blocked install is decided before
    /// its first frame (`SGAppUpdate.restoreDecision`). The one ES256 verification happens on the
    /// first read of the process; later reads cost a lock and a defaults read.
    public var appUpdateDecision: SGAppUpdateDecision {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.appUpdateDecisionLocked(now: self.policyClock())
    }

    /// Caller holds `lock`.
    private func appUpdateDecisionLocked(now: Date) -> SGAppUpdateDecision {
        return SGAppUpdateDecision.evaluate(policy: self.loadAppUpdatePolicyLocked().accepted, installed: self.installedAppVersion, remindedLatest: self.appUpdatePolicyStore.loadRemindedLatest(), now: now)
    }

    /// The presenter showed the reminder for `latest`: remembered under the policy's origin
    /// (`zg.app.policy.reminded@<origin>`), so this `latest` reminds no more — on this launch or any
    /// later one. Called only after the alert was actually on screen, never on the decision alone.
    public func noteAppUpdateReminderShown(latest: SGAppUpdateVersion) {
        self.lock.lock()
        self.appUpdatePolicyStore.saveRemindedLatest(latest.text)
        self.lock.unlock()
    }

    /// Posts `SGAppUpdate.decisionDidChange` on the main queue after an adopted app-update policy.
    /// Posted whether or not the decision moved — the observer re-reads `appUpdateDecision`, which
    /// is cheap and idempotent — so the wiring stays free of a second cached decision.
    private func publishAppUpdateDecision() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SGAppUpdate.decisionDidChange, object: nil)
        }
    }

    /// `Transaction.updates` delivered something (called by `SGIAP`).
    public func storeKitTransactionsDidChange() {
        self.refresh(trigger: .storeKitUpdate)
    }

    /// The entitlement server's refresh hint arrived (`isRefreshPush`). It names no account, so
    /// every linked account on the install is refreshed, each under its own captured session.
    ///
    /// `completion` runs exactly once, on the main queue, with what actually happened
    /// (`SGEntitlementPushRefreshOutcome`) — when every attempt has answered, or at
    /// `silentPushDeadline` (monotonic, from this call). Nothing is reported before the requests
    /// have actually returned. A push that relaunched the app before it published its accounts
    /// waits for them within that same deadline; without them it answers `.noData`.
    ///
    /// The push also refreshes the signed monetization policy first — the policy names no account,
    /// so it needs no binding and does not wait for the accounts — which is how a server flip
    /// reaches a backgrounded app before its next foreground. That fetch is gated like every other
    /// (`SGEntitlementPolicyRefreshGate`), can only adopt a newer signed policy, and takes no part
    /// in `completion`'s outcome, which is about the entitlement tokens alone. The app-update
    /// policy is NOT fetched from the push (`refreshAppUpdatePolicy` is a foreground concern): a
    /// background wake never spends its budget on a block the user cannot see.
    public func handleSilentPush(completion: @escaping (SGEntitlementPushRefreshOutcome) -> Void) {
        guard !SGEntitlement.isAppExtension else {
            DispatchQueue.main.async {
                completion(.noData)
            }
            return
        }
        self.refreshMonetizationPolicy()
        let deadline = DispatchTime.now() + SGEntitlement.silentPushDeadline
        self.accountsReady.whenOpen(timeout: SGEntitlement.silentPushDeadline, queue: self.refreshQueue) { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.noData)
                }
                return
            }
            let now = DispatchTime.now()
            let remaining = deadline > now ? TimeInterval(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000.0 : 0
            guard remaining > 0 else {
                DispatchQueue.main.async {
                    completion(.noData)
                }
                return
            }
            let targets = self.refreshTargets()
            let join = SGEntitlementPushRefreshCompletion(expected: targets.count, deadline: remaining, completion: completion)
            for account in targets {
                self.startRefresh(trigger: .silentPush, accountPeerId: account, completion: { attempt in
                    join.record(attempt)
                })
            }
        }
    }

    /// The APNs device token, pushed to each binding on its next `POST /entitlement/refresh`.
    public func setPushToken(_ token: String?) {
        self.lock.lock()
        self.pushToken = token
        self.lock.unlock()
    }

    /// Forget the cached decision and re-decide from the stored material.
    public func invalidate() {
        self.lock.lock()
        self.invalidateCachedDecisionLocked()
        self.lock.unlock()
        self.store.invalidateCache()
        self.recomputeAndNotifyIfChanged()
    }

    // MARK: - Adopting material

    /// Verifies a JWS and, only if it verifies, stores it and adopts it.
    ///
    /// A token that does not verify is DISCARDED and the previously stored one keeps governing:
    /// "never discard a known-good cached token because a NEW one failed to verify". An unknown `kid`
    /// is not a forgery signal — it is usually an old build meeting a rotated key — so it only raises
    /// the "update the app" hint.
    ///
    /// `credential` is the session the response came from. The token is written only while that
    /// session's refresh token is STILL the account's stored one: a fetch, trial, attach or refresh
    /// answer that lands after a logout or a re-bind belongs to a session that no longer exists, and
    /// writing it would resurrect cleared material or overwrite the fresh binding's own token.
    @discardableResult
    public func adopt(entitlement jws: String, credential: SGEntitlementSessionCredential) -> Bool {
        let accountPeerId = credential.accountPeerId
        let material = self.store.session(accountPeerId: accountPeerId)
        guard material.refreshToken == credential.refreshToken else {
            return false
        }
        self.lock.lock()
        let keys = self.pinnedKeys
        self.lock.unlock()

        switch SGEntitlementTokenVerifier.verify(jws, pinnedKeys: keys, boundDeviceId: material.deviceId, boundAccountId: material.accountId, accountPeerId: accountPeerId) {
        case let .success(claims):
            let stored = self.store.updateSession(accountPeerId: accountPeerId, if: { $0.refreshToken == credential.refreshToken }, { material in
                material.entitlement = jws
                material.until = claims.until
                if material.accountId == nil {
                    material.accountId = claims.sub
                }
                if material.deviceId == nil {
                    material.deviceId = claims.dev
                }
            })
            guard case .success = stored else {
                // The token is authentic but we could not persist it. Say so: the caller must not
                // report success, and the previously stored token keeps governing.
                return false
            }
            self.clock.note(tokenIssuedAt: claims.iat)
            if case let .source(source) = claims.appleSource, !claims.sub.isEmpty {
                // Verified AND stored for this exact session, so `sub` is this account's owner id.
                self.mutateAppleProvenance { state in
                    state.observe(source, ownerAccountId: claims.sub, ownerAccountPeerId: accountPeerId, domain: SGEntitlement.appleTrustDomain, now: self.clock.effectiveNow())
                }
            }
            self.lock.lock()
            self.didSeeUnknownKid = false
            self.invalidateCachedDecisionLocked()
            self.lock.unlock()
            self.recomputeAndNotifyIfChanged()
            return true
        case let .failure(failure):
            if case .unknownKid = failure {
                self.lock.lock()
                self.didSeeUnknownKid = true
                self.lock.unlock()
            }
            return false
        }
    }

    /// Step 4 of the bind flow: persist ATOMICALLY, before dismissing any UI.
    ///
    /// The refresh token, `account.id`, `device.id` and `until` land in one verified write.
    /// `device.id` must be stored: every later verification checks the token's `dev` claim against
    /// it, so a token minted for another binding is rejected.
    ///
    /// The JWS is NOT written here unless the slot is empty. `adopt` below is its only writer, and
    /// only after verification: a bind that arrives while the server signs with a `kid` this build
    /// does not pin must not destroy a token that is still governing (contract §4.2 — this state is
    /// reachable after a `.dropSession(.refreshToken)` 401, which keeps the JWS and sends the user
    /// straight back into the bind flow). An EMPTY slot has nothing to lose, and keeping the token
    /// there lets the app update that pins the new key verify it with no network call.
    ///
    /// `start` is the `/bind/start` this confirmation answers. If the device key it registered is no
    /// longer the device's key — a `device_key_mismatch` regenerated it while the user was in
    /// Telegram — nothing is stored and this returns false: the new binding would hold a key nothing
    /// here can sign with. The check and the write happen under `bindingLock`, so no regeneration
    /// can land between them.
    @discardableResult
    public func completeBind(_ confirmation: SGEntitlementBindConfirmation, start: SGEntitlementBindStart, accountPeerId: Int64) -> Bool {
        self.lock.lock()
        let keys = self.pinnedKeys
        self.lock.unlock()
        guard confirmation.belongs(to: accountPeerId, pinnedKeys: keys) else {
            return false
        }
        self.bindingLock.lock()
        guard self.bindAttempts.isCurrent(start.attempt, accountPeerId: accountPeerId),
              let registeredPublicKey = start.registeredPublicKey, registeredPublicKey == self.identity.publicKeySPKIBase64() else {
            self.bindingLock.unlock()
            return false
        }
        let stored = self.store.updateSession(accountPeerId: accountPeerId) { material in
            // A new binding has received neither the APNs token (its next refresh carries it) nor the
            // profile, and the server has not ended it (`SGEntitlementSessionMaterial.afterBind`).
            material = material.afterBind(confirmation)
        }
        if case .success = stored {
            self.boundPublicKey = registeredPublicKey
            self.bindAttempts.invalidate(accountPeerId: accountPeerId)
        }
        self.bindingLock.unlock()
        guard case .success = stored else {
            return false
        }
        self.scheduler.resetCauses(accountPeerId: accountPeerId)
        // Re-adopt through `adopt` so the token is verified against the freshly stored `dev` and its
        // `iat` feeds the clock mark — under the session this bind just created.
        let adopted = self.adopt(entitlement: confirmation.entitlement, credential: SGEntitlementSessionCredential(accountPeerId: accountPeerId, refreshToken: confirmation.refreshToken))
        if !adopted {
            self.invalidate()
        }
        return true
    }

    /// Step 1 of the bind flow. Mints the device id and the keypair if they do not exist yet and asks
    /// the server for an 8-character code, a deeplink and a poll token. The device key sent is
    /// recorded on the returned start (`registeredPublicKey`) for `completeBind`.
    ///
    /// Waits for any `/bind/revoke` a logout left in flight first (`pendingRevokes`): that revoke
    /// targets the same device binding this bind is about to reuse.
    ///
    /// Consent (`bindPermissionProvider`, `bindConsentProvider`): a start the permission does not
    /// permit (`permitsStart`: nothing while `.refused`, the automatic link only while `.allowed`)
    /// sends nothing and fails with `unknownRefusal("consent_required_local")`. The permission is read
    /// before the attempt begins and read again once the wait for a logout's revoke is over (its
    /// final send alone can take `logoutFinalUploadBudget`), so a consent withdrawn meanwhile sends
    /// no start; an automatic start reads it once more before its consent-fallback retry. The
    /// account's grant is attached as `consent` only while both reads are `.allowed` — a grant made
    /// during the wait reaches `/v1/profile/consents` after the link instead — and its refusals fall
    /// back as `startWithConsentFallback` says. Without the hooks the start is exactly what it always
    /// was.
    ///
    /// The attempt this begins becomes the account's current one (`isBindInProgress`) until its
    /// start's `expires_at`; a start that fails ends it at once. An attempt that is no longer current
    /// when a `/bind/start` would go out (a newer start, a logout of the account or a stored bind
    /// replaced it during the wait or the first start) sends nothing and fails with
    /// `unknownRefusal("bind_superseded_local")`; the automatic link reads that as `.superseded`.
    public func beginBind(accountPeerId: Int64, purpose: SGEntitlementBindPurpose = .manual) async -> Result<SGEntitlementBindStart, SGEntitlementRequestError> {
        let permission = self.bindPermission(accountPeerId: accountPeerId)
        guard SGEntitlement.permitsStart(permission, purpose: purpose) else {
            return .failure(SGEntitlement.consentRequiredLocalRefusal())
        }
        let attempt = self.newBindAttempt(accountPeerId: accountPeerId, purpose: purpose)
        for revoke in self.pendingRevokeTasks() {
            await revoke.value
        }
        guard let client = self.client else {
            self.endBindAttempt(attempt)
            return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "no endpoint configured"))
        }
        guard let publicKey = self.identity.publicKeySPKIBase64() else {
            self.endBindAttempt(attempt)
            return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "no device identity"))
        }
        // Read again once the wait is over: a consent withdrawn while a logout's final send and
        // revoke ran sends no start.
        let latestPermission = self.bindPermission(accountPeerId: accountPeerId)
        guard SGEntitlement.permitsStart(latestPermission, purpose: purpose) else {
            self.endBindAttempt(attempt)
            return .failure(SGEntitlement.consentRequiredLocalRefusal())
        }
        // A consent only while both reads allow one: a withdrawal during the wait removes it, and a
        // grant made during it is not attached (it reaches `/v1/profile/consents` after the link).
        let consentPermission: SGEntitlementBindPermission = (permission == .allowed && latestPermission == .allowed) ? .allowed : .codeOnly
        let consent = SGEntitlement.bindConsent(permission: consentPermission, provider: self.bindConsentProvider, accountPeerId: accountPeerId)
        let refusedHook = self.bindConsentRefused
        let staleHook = self.bindConsentStale
        let deviceName = self.currentDeviceName()
        let result = await SGEntitlement.startWithConsentFallback(consent: consent, purpose: purpose, send: { (consent: [String: Any]?) -> Result<SGEntitlementBindStart, SGEntitlementRequestError> in
            // Before every send, the first one and a fallback retry: an attempt a newer start, a
            // logout or a stored bind replaced (while it waited for a revoke, or while its first
            // start was in flight) sends nothing, so it never expires the newer attempt's pending
            // bind on the server.
            guard self.isCurrentBindAttempt(attempt) else {
                return .failure(SGEntitlement.bindSupersededLocalRefusal())
            }
            let answer = await client.bindStart(deviceName: deviceName, publicKey: publicKey, consent: consent)
            // Exactly the answer `startWithConsentFallback` retries without the consent: a manual
            // start whose attached consent is stale. The retry itself carries none.
            if purpose == .manual, let consent, case let .failure(error) = answer, error.code == SGEntitlement.consentStaleCode {
                staleHook?(accountPeerId, consent["consent_id"] as? String)
            }
            return answer
        }, refused: { consentId in
            refusedHook?(accountPeerId, consentId)
        }, mayRetry: {
            // The automatic link's retry without the consent reads the permission once more: a
            // consent withdrawn while the first start was in flight sends no second one.
            return purpose == .manual || SGEntitlement.permitsStart(self.bindPermission(accountPeerId: accountPeerId), purpose: purpose)
        })
        switch result {
        case let .success(start):
            self.setBindAttemptExpiry(start.expiresAtDate, for: attempt)
            var start = start
            start.attempt = attempt
            return .success(start)
        case let .failure(error):
            self.endBindAttempt(attempt)
            return .failure(error)
        }
    }

    /// Begins the account's new current bind attempt (the previous one, if any, is no longer current).
    func newBindAttempt(accountPeerId: Int64, purpose: SGEntitlementBindPurpose = .manual) -> SGEntitlementBindAttempt {
        let now = self.clock.effectiveNow()
        self.bindingLock.lock()
        defer { self.bindingLock.unlock() }
        return self.bindAttempts.begin(accountPeerId: accountPeerId, purpose: purpose, now: now)
    }

    private func setBindAttemptExpiry(_ expiresAt: Date?, for attempt: SGEntitlementBindAttempt) {
        self.bindingLock.lock()
        self.bindAttempts.setExpiresAt(expiresAt, for: attempt)
        self.bindingLock.unlock()
    }

    /// Whether `attempt` is still its account's current, not-ended bind attempt.
    func isCurrentBindAttempt(_ attempt: SGEntitlementBindAttempt?) -> Bool {
        self.bindingLock.lock()
        defer { self.bindingLock.unlock() }
        return self.bindAttempts.isCurrent(attempt)
    }

    /// Ends `attempt` if it is still current — never a newer attempt of the same account — so a bind
    /// its flow abandoned no longer reads as in progress and can no longer be stored.
    func endBindAttempt(_ attempt: SGEntitlementBindAttempt?) {
        self.bindingLock.lock()
        self.bindAttempts.end(attempt)
        self.bindingLock.unlock()
    }

    /// Whether a bind for the account is live right now: a current, not-ended attempt whose start has
    /// not expired (`expires_at`, or 300 s after it began while that is unknown). The automatic link
    /// never starts while one is.
    public func isBindInProgress(accountPeerId: Int64) -> Bool {
        let now = self.clock.effectiveNow()
        self.bindingLock.lock()
        defer { self.bindingLock.unlock() }
        return self.bindAttempts.isInProgress(accountPeerId: accountPeerId, now: now)
    }

    /// Logout of ONE Telegram account on this device.
    ///
    /// The local material goes FIRST and synchronously, before anything waits on the network: the
    /// caller (an account being removed, an explicit unlink) returns with the session already gone,
    /// so nothing the account left behind can be read, refreshed or attached against after this line
    /// — and a later re-bind of the same account is never wiped by a slow revoke finishing behind it.
    /// `/bind/revoke` then runs in the background with the refresh token captured here, and it is
    /// best-effort: a failure leaves a server-side binding that the next bind or the LRU cap
    /// replaces, never local material. The subscription is NOT cancelled — signing back in restores
    /// it and the paid period is untouched; say so in the confirmation copy. Vault, Chat Lock, task
    /// and edit-history data are never touched, and neither is the StoreKit outbox: an unfinished
    /// paid transaction attributed to this account is still attached (unbound) and only then
    /// finished.
    ///
    /// The final send: the bodies `preRevokeUploadsProvider` hands over (the account's un-acked
    /// consent withdrawals), captured synchronously before anything is removed, go to
    /// `/v1/profile/consents` with the removed session — at most `logoutFinalUploadLimit`, within
    /// `logoutFinalUploadBudget` in total — and only then is the binding revoked, in the same
    /// background task (so a new bind awaits both).
    public func logout(accountPeerId: Int64) {
        let finalUploads = Array((self.preRevokeUploadsProvider?(accountPeerId) ?? []).prefix(SGEntitlement.logoutFinalUploadLimit))
        self.bindingLock.lock()
        self.bindAttempts.invalidate(accountPeerId: accountPeerId)
        let removed = self.store.clearSession(accountPeerId: accountPeerId)
        // Explicit logout keeps its old privacy: the bare pre-origin session item is deleted locally,
        // never read, revoked or sent.
        self.store.discardLegacySession(accountPeerId: accountPeerId)
        if let refreshToken = removed.refreshToken, let client = self.client {
            let credential = SGEntitlementSessionCredential(accountPeerId: accountPeerId, refreshToken: refreshToken)
            let id = UUID()
            let sendsFinalUploads = !finalUploads.isEmpty && !self.isExtensionProcess
            // Register before releasing `bindingLock`, so a new bind cannot begin between the
            // session removal and registering the revoke it must await. The state lock also keeps
            // a fast task's completion from removing itself before its insertion.
            self.lock.lock()
            self.pendingRevokes[id] = Task.detached(priority: .utility) { [weak self] in
                if sendsFinalUploads, let self {
                    let transport = await self.customerDataTransport(client: client)
                    let deadline = transport.environment.uptime() + SGEntitlement.logoutFinalUploadBudget
                    await SGEntitlement.sendFinalUploads(finalUploads, deadline: deadline, uptime: transport.environment.uptime, send: { body in
                        _ = await transport.sendPresentingRemovedCredential(.profileConsents, body: body, credential: credential, deadline: deadline)
                    })
                }
                _ = await client.bindRevoke(credential: credential)
                self?.finishRevoke(id)
            }
            self.lock.unlock()
        }
        self.bindingLock.unlock()
        self.scheduler.resetCauses(accountPeerId: accountPeerId)
        self.invalidate()
    }

    /// At most this many bodies are delivered by a logout's final send.
    static let logoutFinalUploadLimit = 3
    /// The final send's whole budget, every body included; `/bind/revoke` follows either way.
    static let logoutFinalUploadBudget: TimeInterval = 10.0

    /// The final send's loop: `bodies` in order, at most `logoutFinalUploadLimit`, none started at or
    /// past `deadline` (`uptime` seconds). One that fails does not stop the next.
    static func sendFinalUploads(_ bodies: [Data], deadline: TimeInterval, uptime: () -> TimeInterval, send: (Data) async -> Void) async {
        for body in bodies.prefix(SGEntitlement.logoutFinalUploadLimit) {
            guard uptime() < deadline else {
                return
            }
            await send(body)
        }
    }

    /// The local half of `logout`, for an account the SERVER erased (a completed deletion): the
    /// session item goes — its profile receipt and `sessionEnd` with it — and any bind attempt ends;
    /// no `/bind/revoke` (there is no binding left to revoke) and no final send.
    public func forgetErasedAccount(accountPeerId: Int64) {
        self.bindingLock.lock()
        self.bindAttempts.invalidate(accountPeerId: accountPeerId)
        self.store.clearSession(accountPeerId: accountPeerId)
        self.store.discardLegacySession(accountPeerId: accountPeerId)
        self.bindingLock.unlock()
        self.scheduler.resetCauses(accountPeerId: accountPeerId)
        self.invalidate()
    }

    private func pendingRevokeTasks() -> [Task<Void, Never>] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return Array(self.pendingRevokes.values)
    }

    private func finishRevoke(_ id: UUID) {
        self.lock.lock()
        self.pendingRevokes.removeValue(forKey: id)
        self.lock.unlock()
    }

    /// Applies a failure's consequence to the LOCAL session material. Never touches the cached JWS
    /// and never changes the capability set.
    ///
    /// `credential` is the session the failed request ran under, nil for an unauthenticated one (the
    /// bind flow's `/bind/start`). A failure of a session that is no longer the account's — logged
    /// out, re-bound, rotated past — is about material that is already gone and changes NOTHING: an
    /// old 401 must not drop the new binding's refresh token, and an old `device_key_mismatch` must
    /// not throw away the key the new binding was registered with.
    ///
    /// The token drop and the key regeneration happen together under `bindingLock`, which
    /// `completeBind` holds while it checks the key and stores a binding — so a bind can never be
    /// stored between this failure's check and its regeneration. A session's `device_key_mismatch`
    /// regenerates only a key no bind in this process registered (`boundPublicKey`); the
    /// unauthenticated `invalid_pubkey` of `/bind/start` always does.
    ///
    /// Dropping the stored refresh token records why, in the same write
    /// (`SGEntitlementSessionMaterial.afterServerDrop`): the code, the body's `reason` and the
    /// moment, so the main app can tell a binding the server ended from one never made.
    public func apply(_ error: SGEntitlementRequestError, credential: SGEntitlementSessionCredential?) {
        let recovery = error.recovery
        guard case let .dropSession(drop) = recovery.consequence else {
            if let credential, case let .session(cause) = error.failure, self.store.session(accountPeerId: credential.accountPeerId).refreshToken == credential.refreshToken {
                self.refresh(trigger: .unauthorized(cause), accountPeerId: credential.accountPeerId)
            }
            return
        }
        let endedAt = self.clock.effectiveNow()
        let endCode: String
        if case let .session(cause) = error.failure {
            endCode = cause.rawValue
        } else {
            endCode = error.code ?? "unknown"
        }
        self.bindingLock.lock()
        if let credential {
            // The session is gone; the ENTITLEMENT is not. The cached token keeps governing until
            // `exp + grace_days`, and no user data is touched. Compared under the store's lock: a
            // logout, a re-bind or a rotation that won the race means this failure is about material
            // that no longer exists, and nothing below happens.
            let current = self.store.updateSession(accountPeerId: credential.accountPeerId, if: { $0.refreshToken == credential.refreshToken }, { material in
                if drop.contains(.refreshToken) {
                    material = material.afterServerDrop(code: endCode, reason: error.reason, at: endedAt)
                }
            })
            if case .failure(.preconditionFailed) = current {
                self.bindingLock.unlock()
                return
            }
        }
        if drop.contains(.enclaveKey) {
            if credential == nil || self.boundPublicKey != self.identity.publicKeySPKIBase64() {
                self.identity.regenerateKeyPair()
            }
        }
        self.bindingLock.unlock()
        self.postChange()
        if let credential, case let .session(cause) = error.failure {
            // The failing session's own account — never whichever account happens to be in front.
            self.refresh(trigger: .unauthorized(cause), accountPeerId: credential.accountPeerId)
        }
    }

    // MARK: - StoreKit bridge

    /// `SGIAP` pushes what `Transaction.currentEntitlements` says. This module never imports StoreKit
    /// (iOS 15, `async`) because the gate must stay synchronous.
    /// The snapshot is origin-bound (`store.scope`): only what this build's SGIAP recorded for the
    /// CURRENT backend grants, is preserved or is cleared. The bare pre-origin `storeKitSnapshotKey` is
    /// never read for a grant, rewritten or removed — see `manageableStoreKitSnapshot`.
    public func updateStoreKitFallback(_ snapshot: SGEntitlementStoreKitSnapshot?) {
        self.lock.lock()
        self.cachedStoreKit = snapshot
        self.didLoadStoreKit = true
        self.invalidateCachedDecisionLocked()
        self.lock.unlock()
        let encoder = JSONEncoder()
        if let snapshot, let data = try? encoder.encode(snapshot) {
            self.defaults?.set(data, forKey: self.scopedStoreKitSnapshotKey)
        } else {
            self.defaults?.removeObject(forKey: self.scopedStoreKitSnapshotKey)
        }
        self.recomputeAndNotifyIfChanged()
    }

    /// This origin's snapshot: what grants (while the Apple backend is enabled), what the plan line
    /// reads and what SGIAP preserves or extends.
    public var storeKitFallback: SGEntitlementStoreKitSnapshot? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.loadStoreKitLocked()
    }

    /// DISPLAY ONLY: may Apple's management page be offered for existing billing? This origin's own
    /// snapshot, else a snapshot an earlier (pre-origin) build left under the bare key — but only while
    /// it is active with a finite expiry still ahead on the effective clock. Never refreshed by this
    /// build, a bare snapshot with no expiry would otherwise read as active forever. Never grants, never
    /// feeds a plan, a renewal line or provenance; the bare bytes are only read.
    public var manageableStoreKitSnapshot: SGEntitlementStoreKitSnapshot? {
        if let own = self.storeKitFallback {
            return own
        }
        guard let data = self.defaults?.data(forKey: SGEntitlement.storeKitSnapshotKey), let legacy = try? JSONDecoder().decode(SGEntitlementStoreKitSnapshot.self, from: data) else {
            return nil
        }
        guard legacy.hasActiveSubscription, let expiry = legacy.effectiveExpirationDate, self.clock.effectiveNow() < expiry else {
            return nil
        }
        return legacy
    }

    /// `storeKitSnapshotKey@<authority>` for this instance's store scope.
    private var scopedStoreKitSnapshotKey: String {
        return self.store.scope.scopedKey(SGEntitlement.storeKitSnapshotKey)
    }

    /// A SUCCESSFUL `/apple/attach` for `transactionId` (`SGIAP`): records what the server said about
    /// the original's owner (`SGEntitlementAppleOwnership.fromAttach`). A response for a different
    /// transaction than the one presented is ignored. A claim is never demoted.
    public func recordAppleAttach(presentedTransactionId: String, transactionId: String?, originalTransactionId: String?, environment: String?, accountId: String?, linkedTelegram: Bool?, boundAccountPeerId: Int64?) {
        guard let transactionId, transactionId == presentedTransactionId, let originalTransactionId, !originalTransactionId.isEmpty, let environment, !environment.isEmpty else {
            return
        }
        let ownership = SGEntitlementAppleOwnership.fromAttach(boundAccountPeerId: boundAccountPeerId, accountId: accountId, linkedTelegram: linkedTelegram)
        let changed = self.mutateAppleProvenance { state in
            state.recordAttach(originalTransactionId: originalTransactionId, environment: environment, ownership: ownership, domain: SGEntitlement.appleTrustDomain)
        }
        if changed {
            self.recomputeAndNotifyIfChanged()
        }
    }

    /// A BOUND `/apple/attach` of `signedTransaction` for `accountPeerId` was refused with
    /// `apple_subscription_conflict` (`SGIAP`): another Telegram account owns this original, so this
    /// receipt must not grant `accountPeerId` (`SGEntitlementAppleProvenanceState.recordConflict`).
    /// Without it the original stays `unresolved`, which grants every account. Local and
    /// non-granting only; a later positive owner statement for `accountPeerId` lifts it.
    public func recordAppleAttachConflict(signedTransaction: String, accountPeerId: Int64) {
        guard let fields = SGEntitlementAppleSignedTransactionFields(signedTransaction: signedTransaction) else {
            return
        }
        let changed = self.mutateAppleProvenance { state in
            state.recordConflict(originalTransactionId: fields.originalTransactionId, environment: fields.environment, accountPeerId: accountPeerId, domain: SGEntitlement.appleTrustDomain)
        }
        if changed {
            self.recomputeAndNotifyIfChanged()
        }
    }

    public var appleProvenance: SGEntitlementAppleProvenanceState {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.loadAppleProvenanceLocked()
    }

    /// Caller holds `lock`.
    private func loadAppleProvenanceLocked() -> SGEntitlementAppleProvenanceState {
        if self.didLoadAppleProvenance {
            return self.cachedAppleProvenance
        }
        self.didLoadAppleProvenance = true
        let load = SGEntitlementAppleProvenanceStoredLoad(stored: self.defaults?.data(forKey: SGEntitlement.appleProvenanceKey))
        self.cachedAppleProvenance = load.initialState
        self.isAppleProvenanceStoreReadOnly = load.preservesStoredBytes
        return self.cachedAppleProvenance
    }

    /// Read-modify-write under `lock`, persisted before the lock is released, so two observations
    /// can never interleave and lose one. Drops expired tombstones on the way. Invalidates the
    /// cached decision when anything changed; returns whether it did.
    ///
    /// A stored ledger this build could not decode (corrupt, or written by a newer build) is NEVER
    /// overwritten: its tombstones and claims are what keep refunded and other accounts' receipts
    /// from granting, so a write from an empty start would erase them for good. Changes then live
    /// in memory for this process only, and while the ledger is unreadable the StoreKit creation
    /// fallback grants nothing (`SGEntitlementStoreKitEligibility.isLedgerReadable`).
    @discardableResult
    private func mutateAppleProvenance(_ transform: (inout SGEntitlementAppleProvenanceState) -> Bool) -> Bool {
        let now = self.clock.effectiveNow()
        self.lock.lock()
        var state = self.loadAppleProvenanceLocked()
        let before = state
        _ = transform(&state)
        state.prune(now: now)
        let changed = state != before
        if changed {
            self.cachedAppleProvenance = state
            self.invalidateCachedDecisionLocked()
            if !self.isAppleProvenanceStoreReadOnly, let data = try? JSONEncoder().encode(state) {
                self.defaults?.set(data, forKey: SGEntitlement.appleProvenanceKey)
            }
        }
        self.lock.unlock()
        return changed
    }

    private func loadStoreKitLocked() -> SGEntitlementStoreKitSnapshot? {
        if self.didLoadStoreKit {
            return self.cachedStoreKit
        }
        self.didLoadStoreKit = true
        if let data = self.defaults?.data(forKey: self.scopedStoreKitSnapshotKey) {
            self.cachedStoreKit = try? JSONDecoder().decode(SGEntitlementStoreKitSnapshot.self, from: data)
        }
        return self.cachedStoreKit
    }

    // MARK: - Local grace

    /// The record's high-water mark is rewritten once it has moved this far past the persisted one.
    static let localGraceHighWaterPersistInterval: TimeInterval = 3600

    /// The install's local grace for an evaluation under `monetization` (`SGEntitlementLocalGrace`):
    /// the first-launch record, and — in PAID mode — re-based on the paid-policy mark (D9), the
    /// later of the two windows. Free mode never consults the grace, so the mark is neither read nor
    /// minted there; and without a first-launch record (an extension on an install the app has never
    /// evaluated) there is no window to re-base. The combined load is verified only when both
    /// records are: an unreadable mark, like an unreadable first-launch record, grants this
    /// evaluation only and is never cached or mirrored.
    private func localGrace(now: Date, monetization: SGEntitlementPolicyMode) -> SGEntitlementLocalGraceLoad {
        let load = self.firstLaunchGrace(now: now)
        guard monetization == .paid, let grace = load.grace else {
            return load
        }
        let mark = self.paidModeMark(now: now)
        return SGEntitlementLocalGraceLoad(grace: grace.rebased(firstPaidPolicyAt: mark.firstPaidPolicyAt), isVerified: load.isVerified && mark.isVerified, persistedSeenAt: load.persistedSeenAt)
    }

    /// The install's first-launch grace record, read once from the Keychain and — in the main app,
    /// on the very first evaluation — minted at `now`, which is `effectiveNow`: the clock high-water
    /// mark, so a clock wound backwards later cannot extend the window it started. Extensions never
    /// mint; they read what the main app wrote (and evaluate the mirror anyway).
    ///
    /// Minted once and never rewritten (except for its own high-water mark, `lastSeenAt`): logging
    /// out, switching accounts and clearing the app-group defaults leave it alone
    /// (`SGEntitlementStore.clearSession` never touches it). Only a Keychain wipe — a device erase —
    /// resets it, and that is accepted (`SGEntitlementLocalGrace`).
    ///
    /// "Once" is only true if a record that could not be READ is never re-minted. Before the first
    /// unlock after a reboot the item's Keychain class is unavailable, and a launch there (a VoIP
    /// push) would otherwise mint a fresh 7 days over an expired record, keep it for the process and
    /// mirror it to the extensions. So the rule (`resolveLocalGrace`, pure and tested) is: mint only
    /// on a definite "absent", and only count a record as loaded once it is proven persisted. Any
    /// other outcome — unreadable, or a write that did not verify — grants the window in memory for
    /// THIS evaluation only (invariant I2: fail toward the user), is not cached, is not mirrored, and
    /// is retried on the next evaluation, which after the unlock reads the real record.
    private func firstLaunchGrace(now: Date) -> SGEntitlementLocalGraceLoad {
        self.lock.lock()
        if self.didLoadLocalGrace {
            guard let current = self.localGraceValue else {
                self.lock.unlock()
                return SGEntitlementLocalGraceLoad(grace: nil, isVerified: true)
            }
            let observed = current.observing(now)
            let persist = self.localGraceHighWaterNeedsPersistLocked(observed)
            self.localGraceValue = observed
            self.lock.unlock()
            if persist {
                self.persistLocalGraceHighWater(observed)
            }
            return SGEntitlementLocalGraceLoad(grace: observed, isVerified: true)
        }
        self.lock.unlock()

        // Keychain I/O outside the lock, like every other read of the store in this class.
        let load = SGEntitlement.resolveLocalGrace(read: self.store.localGraceRecord(), now: now, canMint: !SGEntitlement.isAppExtension, persist: { [store = self.store] minted in
            return store.setLocalGraceData(SGEntitlement.encodeLocalGrace(minted))
        })
        guard load.isVerified else {
            return load
        }

        self.lock.lock()
        if self.didLoadLocalGrace {
            // Another thread got here first; its record (possibly minted a moment earlier) wins.
            let value = self.localGraceValue
            self.lock.unlock()
            return SGEntitlementLocalGraceLoad(grace: value, isVerified: true)
        }
        // What is on disk is the record as read (or minted); observing `now` may move the mark past it.
        self.localGraceSeenAtPersisted = load.persistedSeenAt ?? .distantPast
        let observed = load.grace?.observing(now)
        let persist = observed.map { self.localGraceHighWaterNeedsPersistLocked($0) } ?? false
        self.localGraceValue = observed
        self.didLoadLocalGrace = true
        self.lock.unlock()
        if persist, let observed {
            self.persistLocalGraceHighWater(observed)
        }
        return SGEntitlementLocalGraceLoad(grace: observed, isVerified: true)
    }

    /// The pure form of the load rule, so it is testable without a Keychain. `persist` writes a
    /// freshly minted record and reports whether the write was proven; it is called at most once.
    static func resolveLocalGrace(
        read: SGEntitlementStoreItemRead,
        now: Date,
        canMint: Bool,
        persist: (SGEntitlementLocalGrace) -> Bool
    ) -> SGEntitlementLocalGraceLoad {
        switch read {
        case let .present(data):
            if let decoded = try? JSONDecoder().decode(SGEntitlementLocalGrace.self, from: data) {
                return SGEntitlementLocalGraceLoad(grace: decoded, isVerified: true, persistedSeenAt: decoded.lastSeenAt)
            }
            // A record that does not decode is a record that cannot govern; fall through to minting.
        case .absent:
            break
        case .unreadable:
            // Locked Keychain: grant this evaluation only, never cache, never mirror.
            return SGEntitlementLocalGraceLoad(grace: canMint ? SGEntitlementLocalGrace(firstLaunchAt: now) : nil, isVerified: false)
        }
        guard canMint else {
            return SGEntitlementLocalGraceLoad(grace: nil, isVerified: true)
        }
        let minted = SGEntitlementLocalGrace(firstLaunchAt: now)
        guard persist(minted) else {
            // Nothing is proven: the window is granted in memory for this evaluation, and the next
            // one tries again (after the first unlock the write goes through).
            return SGEntitlementLocalGraceLoad(grace: minted, isVerified: false)
        }
        return SGEntitlementLocalGraceLoad(grace: minted, isVerified: true, persistedSeenAt: minted.lastSeenAt)
    }

    static func encodeLocalGrace(_ grace: SGEntitlementLocalGrace) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(grace)) ?? Data()
    }

    /// The install's paid-policy mark (D9, `SGEntitlementPaidModeMark`), read once from the Keychain
    /// and — in the main app, on the first evaluation under a PAID policy — minted at `now`
    /// (`effectiveNow`). That first paid evaluation is the recompute the adoption itself triggers,
    /// so the mark is the moment the flip reached this install. Only ever called for a paid
    /// evaluation (`localGrace(now:monetization:)`), never from free mode.
    ///
    /// Exactly the first-launch record's rules (`resolvePaidModeMark`, pure and tested): minted once
    /// and never rewritten — a later free → paid flip re-bases nothing — minted only on a definite
    /// "absent", counted as loaded only once proven persisted, and an unreadable record (a launch
    /// before the first unlock) grants its window in memory for THIS evaluation only.
    private func paidModeMark(now: Date) -> SGEntitlementPaidModeMarkLoad {
        self.lock.lock()
        if self.didLoadPaidModeMark {
            let value = self.paidModeMarkValue
            self.lock.unlock()
            return SGEntitlementPaidModeMarkLoad(firstPaidPolicyAt: value, isVerified: true)
        }
        self.lock.unlock()

        // Keychain I/O outside the lock, like every other read of the store in this class.
        let load = SGEntitlement.resolvePaidModeMark(read: self.store.paidModeMarkRecord(), now: now, canMint: !SGEntitlement.isAppExtension, persist: { [store = self.store] minted in
            return store.setPaidModeMarkData(SGEntitlement.encodePaidModeMark(minted))
        })
        guard load.isVerified else {
            return load
        }

        self.lock.lock()
        if !self.didLoadPaidModeMark {
            self.paidModeMarkValue = load.firstPaidPolicyAt
            self.didLoadPaidModeMark = true
        }
        // Another thread may have got here first; its record (possibly minted a moment earlier) wins.
        let value = self.paidModeMarkValue
        self.lock.unlock()
        return SGEntitlementPaidModeMarkLoad(firstPaidPolicyAt: value, isVerified: true)
    }

    /// The pure form of the paid-policy mark's load rule, so it is testable without a Keychain.
    /// `persist` writes a freshly minted mark and reports whether the write was proven; it is called
    /// at most once.
    static func resolvePaidModeMark(
        read: SGEntitlementStoreItemRead,
        now: Date,
        canMint: Bool,
        persist: (SGEntitlementPaidModeMark) -> Bool
    ) -> SGEntitlementPaidModeMarkLoad {
        switch read {
        case let .present(data):
            if let decoded = try? JSONDecoder().decode(SGEntitlementPaidModeMark.self, from: data) {
                return SGEntitlementPaidModeMarkLoad(firstPaidPolicyAt: decoded.firstPaidPolicyAt, isVerified: true)
            }
            // A record that does not decode is a record that cannot govern; fall through to minting.
        case .absent:
            break
        case .unreadable:
            // Locked Keychain: grant this evaluation only, never cache, never mirror.
            return SGEntitlementPaidModeMarkLoad(firstPaidPolicyAt: canMint ? now : nil, isVerified: false)
        }
        guard canMint else {
            return SGEntitlementPaidModeMarkLoad(firstPaidPolicyAt: nil, isVerified: true)
        }
        let minted = SGEntitlementPaidModeMark(firstPaidPolicyAt: now)
        guard persist(minted) else {
            // Nothing is proven: the re-based window is granted in memory for this evaluation, and
            // the next one tries again (after the first unlock the write goes through).
            return SGEntitlementPaidModeMarkLoad(firstPaidPolicyAt: now, isVerified: false)
        }
        return SGEntitlementPaidModeMarkLoad(firstPaidPolicyAt: now, isVerified: true)
    }

    static func encodePaidModeMark(_ mark: SGEntitlementPaidModeMark) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(mark)) ?? Data()
    }

    /// Caller holds `lock`.
    private func localGraceHighWaterNeedsPersistLocked(_ observed: SGEntitlementLocalGrace) -> Bool {
        guard !SGEntitlement.isAppExtension else {
            return false
        }
        guard observed.lastSeenAt.timeIntervalSince(self.localGraceSeenAtPersisted) >= SGEntitlement.localGraceHighWaterPersistInterval else {
            return false
        }
        self.localGraceSeenAtPersisted = observed.lastSeenAt
        return true
    }

    /// Rewrites the record with its advanced high-water mark. A failed write is ignored: the mark
    /// still holds in memory, and the next advance tries again.
    private func persistLocalGraceHighWater(_ grace: SGEntitlementLocalGrace) {
        self.store.setLocalGraceData(SGEntitlement.encodeLocalGrace(grace))
    }

    // MARK: - Evaluation

    private func currentDecision() -> SGEntitlementEvaluator.Decision {
        let now = self.clock.effectiveNow()
        self.lock.lock()
        // Both horizons: the active account's own, and the union's — another account's token lapsing
        // must re-decide too, or the capture it granted would outlive it until the next foreground.
        if let cached = self.cachedDecision, now < cached.validUntil, let union = self.cachedDeviceWide, now < union.validUntil {
            self.lock.unlock()
            return cached
        }
        self.lock.unlock()
        return self.recompute(now: now, notify: false)
    }

    /// Re-decides the active account AND the device-wide union in one pass, caches both, mirrors
    /// them for the extensions, arms the horizon timer and posts `didChangeNotification` when either
    /// moved. Every horizon crossing and every material change ends up here.
    ///
    /// Evaluation runs with the lock released, so an input can change under it — a newly adopted
    /// policy above all. The result is committed only while `inputGeneration` is still the one the
    /// inputs were read at; otherwise it is re-evaluated, and a decision made under an older input
    /// is never cached (it would hold until the next foreground: free and degraded decisions have
    /// no horizon of their own).
    @discardableResult
    private func recompute(now: Date, notify shouldNotify: Bool) -> SGEntitlementEvaluator.Decision {
        var attempt = 1
        while true {
            let (decision, committed) = self.recomputeOnce(now: now, notify: shouldNotify)
            if committed || attempt >= SGEntitlement.recomputeAttempts {
                return decision
            }
            attempt += 1
        }
    }

    /// More input changes than this during one recompute leave the cache empty (the next read
    /// re-decides) rather than spin.
    static let recomputeAttempts = 4

    private func recomputeOnce(now: Date, notify shouldNotify: Bool) -> (SGEntitlementEvaluator.Decision, committed: Bool) {
        self.lock.lock()
        let account = self.activeAccount
        let accounts = self.knownAccounts
        let keys = self.pinnedKeys
        let enforcement = self.enforcement
        let monetization = self.effectiveMonetizationLocked()
        // Held: the cached snapshot (bytes untouched) grants nothing, and asks for no provenance re-read.
        let storeKit = self.isAppleBackendEnabled ? self.loadStoreKitLocked() : nil
        let provenance = self.loadAppleProvenanceLocked()
        // Read with the ledger, under the same lock: the app and every extension load the same
        // stored bytes, so both fail closed together while they cannot be decoded.
        let isLedgerReadable = !self.isAppleProvenanceStoreReadOnly
        let previous = self.cachedDecision
        let previousDeviceWide = self.cachedDeviceWide
        let generation = self.inputGeneration
        let willCommit = self.recomputeWillCommitHook
        self.lock.unlock()

        let graceLoad = self.localGrace(now: now, monetization: monetization)
        let localGrace = graceLoad.grace

        // Paid mode only: the accounts whose verifying token carries no genuine account claims. It
        // proves nothing, so the server is asked for one that does (`requestDueAccountClaims`).
        // Every other evaluated account is settled.
        var missingAccountClaims: [SGEntitlementAccountClaimsRequest] = []
        var settledAccounts: [Int64] = []
        let decideWith: (Int64?, Bool) -> SGEntitlementEvaluator.Decision = { [store = self.store] peerId, ledgerReadable in
            var cached: SGEntitlementCachedToken?
            var accountId: String?
            if let peerId {
                let material = store.session(accountPeerId: peerId)
                accountId = material.accountId
                if let jws = material.entitlement {
                    cached = SGEntitlementCachedToken(jws: jws, boundDeviceId: material.deviceId, boundAccountId: material.accountId, accountPeerId: peerId)
                }
            }
            // The SAME provenance for every account, so a quarantined legacy aggregate cannot come
            // back through another account's evaluation and the device-wide union.
            let eligibility = SGEntitlementStoreKitEligibility(provenance: provenance, domain: SGEntitlement.appleTrustDomain, accountId: accountId, accountPeerId: peerId, isLedgerReadable: ledgerReadable)
            let decision = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: storeKit, pinnedKeys: keys, now: now, enforcement: enforcement, localGrace: localGrace, storeKitEligibility: eligibility, monetization: monetization)
            if let peerId {
                if monetization == .paid, let cached, let claims = decision.claims, claims.accountGrant == nil {
                    missingAccountClaims.append(SGEntitlementAccountClaimsRequest(accountPeerId: peerId, token: cached.jws))
                } else {
                    settledAccounts.append(peerId)
                }
            }
            return decision
        }
        // The union over every account on the install (`SGEntitlementCapability.isDeviceGlobal`),
        // seeded with the active account's own decision and holding until the EARLIEST horizon
        // among the accounts, so a lapse anywhere re-decides it.
        let unionWith: (SGEntitlementEvaluator.Decision, Bool) -> SGEntitlementDeviceWideDecision = { own, ledgerReadable in
            var unionCapabilities = own.state.capabilities
            var unionValidUntil = own.validUntil
            for other in accounts where other != account {
                let otherDecision = decideWith(other, ledgerReadable)
                unionCapabilities.formUnion(otherDecision.state.capabilities)
                unionValidUntil = min(unionValidUntil, otherDecision.validUntil)
            }
            return SGEntitlementDeviceWideDecision(capabilities: unionCapabilities, validUntil: unionValidUntil)
        }

        let decision = decideWith(account, isLedgerReadable)
        let deviceWide = unionWith(decision, isLedgerReadable)

        willCommit?()

        self.lock.lock()
        guard self.inputGeneration == generation else {
            // An input changed while this ran: the decision may be the old policy's.
            self.lock.unlock()
            return (decision, committed: false)
        }
        self.cachedDecision = decision
        self.cachedDeviceWide = deviceWide
        if let failure = decision.tokenFailure, case .unknownKid = failure {
            self.didSeeUnknownKid = true
        }
        for peerId in settledAccounts {
            self.accountClaims.noteSatisfied(accountPeerId: peerId)
        }
        for request in missingAccountClaims {
            self.accountClaims.noteMissing(accountPeerId: request.accountPeerId, token: request.token)
        }
        self.lock.unlock()

        // The mirror is only overwritten once an account is actually known. Between
        // `SharedAccountContextImpl.init` and the account records loading there is none, so every
        // cold launch would otherwise stamp `capabilities: []` / `degradedReason: "noToken"` over a
        // perfectly good mirror and hand that to the extensions — "unknown", published as "no".
        // Likewise never while the grace record is unverified (a launch before the first unlock):
        // an in-memory window must not reach the extensions as seven mirrored days.
        if !SGEntitlement.isAppExtension, account != nil, graceLoad.isVerified {
            // The same decisions with the StoreKit fallback withheld, mirrored alongside for the
            // extensions to use if the shared ledger becomes unreadable after this write
            // (`SGEntitlementMirror.state(now:isLedgerReadable:)`). Identical when StoreKit cannot
            // contribute anyway: no active snapshot, or the ledger is already unreadable here.
            let storeKitCanGrant = isLedgerReadable && (storeKit?.hasActiveSubscription ?? false)
            let withheldDecision = storeKitCanGrant ? decideWith(account, false) : decision
            let withheldDeviceWide = storeKitCanGrant ? unionWith(withheldDecision, false) : deviceWide
            self.writeMirror(decision, localGrace: localGrace, deviceWide: deviceWide, withheldDecision: withheldDecision, withheldDeviceWide: withheldDeviceWide, now: now)
        }
        self.scheduleHorizon(min(decision.validUntil, deviceWide.validUntil), now: now)
        self.requestDueAccountClaims()
        if let storeKit, storeKit.receipts == nil, storeKit.hasActiveSubscription, provenance.hasLiveTombstone(domain: SGEntitlement.appleTrustDomain, now: now) {
            self.requestStoreKitProvenance()
        }
        let unionMoved = previousDeviceWide.map { $0.capabilities != deviceWide.capabilities } ?? false
        if shouldNotify || previous?.state != decision.state || unionMoved {
            self.postChange()
        }
        return (decision, committed: true)
    }

    /// Asks `SGIAP` once per process to replace a quarantined legacy aggregate with identified receipts.
    private func requestStoreKitProvenance() {
        guard !SGEntitlement.isAppExtension else {
            return
        }
        self.lock.lock()
        let alreadyRequested = self.didRequestStoreKitProvenance
        self.didRequestStoreKitProvenance = true
        self.lock.unlock()
        guard !alreadyRequested else {
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SGEntitlement.storeKitProvenanceRequestedNotification, object: nil)
        }
    }

    /// Paid mode met a legacy token (no `account_ent` / `account_until`): ask the server at once for
    /// one that carries them (`SGEntitlementAccountClaimsLedger`). Never before the first idle
    /// window. A request is spent only when the scheduler admits it; a `.wait` re-tries once the
    /// wait is over, a failure makes it due again, and the scheduler still bounds every call (in
    /// flight, the 60 s collapse, the device budget, any backoff). Restore and the management page
    /// stay available meanwhile.
    private func requestDueAccountClaims() {
        guard !SGEntitlement.isAppExtension else {
            return
        }
        self.lock.lock()
        let due = self.accountClaims.due(firstIdlePassed: self.didPassFirstIdle)
        self.lock.unlock()
        guard !due.isEmpty else {
            return
        }
        self.refreshQueue.async { [weak self] in
            guard let self else {
                return
            }
            for request in due {
                self.startRefresh(trigger: .accountClaimsMissing, accountPeerId: request.accountPeerId, admission: { [weak self] decision in
                    self?.accountClaimsAdmission(decision, for: request)
                }, completion: { [weak self] attempt in
                    guard let self, attempt == .failed else {
                        return
                    }
                    self.lock.lock()
                    self.accountClaims.failed(request)
                    self.lock.unlock()
                })
            }
        }
    }

    private func accountClaimsAdmission(_ decision: SGEntitlementScheduler.Decision, for request: SGEntitlementAccountClaimsRequest) {
        switch decision {
        case .fetch, .rotate:
            self.lock.lock()
            self.accountClaims.admitted(request)
            self.lock.unlock()
        case let .wait(delay):
            self.lock.lock()
            let alreadyScheduled = self.isAccountClaimsRetryScheduled
            self.isAccountClaimsRetryScheduled = true
            self.lock.unlock()
            guard !alreadyScheduled else {
                return
            }
            self.refreshQueue.asyncAfter(deadline: .now() + max(delay, 1)) { [weak self] in
                guard let self else {
                    return
                }
                self.lock.lock()
                self.isAccountClaimsRetryScheduled = false
                self.lock.unlock()
                self.requestDueAccountClaims()
            }
        case .skip:
            // In flight, inside the collapse, or out of budget: still due, and asked again at the
            // next recompute or foreground.
            break
        }
    }

    /// Re-decides now and posts `didChangeNotification` when the decision actually moved.
    private func recomputeAndNotifyIfChanged() {
        self.recompute(now: self.clock.effectiveNow(), notify: false)
    }

    /// A one-shot for the next horizon, so the end of the grace, of a token or of a purchase reaches
    /// an app that stays in the foreground — an open chat on day 7 re-renders at `firstLaunchAt +
    /// 7 d`, not when something next happens to ask a gate. Wall-clock deadline: it survives sleep
    /// and lands at the horizon itself. Re-armed by every `recompute`, cancelled by the next.
    private func scheduleHorizon(_ horizon: Date, now: Date) {
        guard !SGEntitlement.isAppExtension else {
            return
        }
        self.lock.lock()
        self.horizonWorkItem?.cancel()
        self.horizonWorkItem = nil
        guard horizon < Date.distantFuture else {
            self.lock.unlock()
            return
        }
        // Computed in the evaluation timeline (`effectiveNow`), then applied as a wall-clock delay:
        // both advance together, and a fire that lands early merely re-arms itself.
        let delay = min(max(horizon.timeIntervalSince(now), 0) + 0.1, SGEntitlement.horizonMaxDelay)
        let item = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.recompute(now: self.clock.effectiveNow(), notify: false)
        }
        self.horizonWorkItem = item
        self.lock.unlock()
        self.refreshQueue.asyncAfter(wallDeadline: .now() + delay, execute: item)
    }

    /// A horizon further away than this is re-armed in steps; the next `recompute` re-measures.
    static let horizonMaxDelay: TimeInterval = 30 * 86400

    private func writeMirror(_ decision: SGEntitlementEvaluator.Decision, localGrace: SGEntitlementLocalGrace?, deviceWide: SGEntitlementDeviceWideDecision, withheldDecision: SGEntitlementEvaluator.Decision, withheldDeviceWide: SGEntitlementDeviceWideDecision, now: Date) {
        let mirror = SGEntitlement.composeMirror(
            decision: decision,
            localGrace: localGrace,
            storeKitExpiry: self.isAppleBackendEnabled ? self.storeKitFallback?.effectiveExpirationDate : nil,
            deviceWide: deviceWide,
            withheldDecision: withheldDecision,
            withheldDeviceWide: withheldDeviceWide,
            updatedAt: Int64(Date().timeIntervalSince1970)
        )
        self.lock.lock()
        var previous = self.lastWrittenMirror
        previous?.updatedAt = mirror.updatedAt
        let isUnchanged = previous == mirror
        self.lastWrittenMirror = mirror
        self.lock.unlock()
        guard !isUnchanged else {
            return
        }
        SGEntitlementMirrorStore.write(mirror)
        notify_post(SGEntitlement.darwinNotificationName)
    }

    /// The mirror for the extensions: the active account's decision, widened by the device-global
    /// capabilities the union grants (`SGEntitlementCapability.isDeviceGlobal`).
    ///
    /// The app answers `can(.createRetainedHistoryRecord)` over the union, so the mirror must too, or
    /// a free account in front of a paying one would hand the Notification Service's replay a "no"
    /// the app itself does not give. When the union adds anything, `until` becomes the earliest
    /// horizon among the decisions that grant — conservative, and rewritten at that horizon by the
    /// `recompute` it triggers. Pure, so the rule is tested without the App Group.
    /// `composeMirror` for the decisions as made, plus the same composition of the decisions made
    /// with the StoreKit fallback withheld (`SGEntitlementMirror.storeKitWithheld`).
    static func composeMirror(
        decision: SGEntitlementEvaluator.Decision,
        localGrace: SGEntitlementLocalGrace?,
        storeKitExpiry: Date?,
        deviceWide: SGEntitlementDeviceWideDecision?,
        withheldDecision: SGEntitlementEvaluator.Decision,
        withheldDeviceWide: SGEntitlementDeviceWideDecision?,
        updatedAt: Int64
    ) -> SGEntitlementMirror {
        var mirror = self.composeMirror(decision: decision, localGrace: localGrace, storeKitExpiry: storeKitExpiry, deviceWide: deviceWide, updatedAt: updatedAt)
        let withheld = self.composeMirror(decision: withheldDecision, localGrace: localGrace, storeKitExpiry: nil, deviceWide: withheldDeviceWide, updatedAt: updatedAt)
        mirror.storeKitWithheld = SGEntitlementMirrorDecision(withheld)
        return mirror
    }

    static func composeMirror(
        decision: SGEntitlementEvaluator.Decision,
        localGrace: SGEntitlementLocalGrace?,
        storeKitExpiry: Date?,
        deviceWide: SGEntitlementDeviceWideDecision?,
        updatedAt: Int64
    ) -> SGEntitlementMirror {
        let claims = decision.claims
        var until: Int64?
        if case .storeKit = decision.source {
            if let storeKitExpiry {
                until = Int64(storeKitExpiry.timeIntervalSince1970)
            }
        } else if case .localGrace = decision.source {
            // The grace's own horizon, so the extension stops capturing when the window closes.
            if let localGrace {
                until = Int64(localGrace.endsAt.timeIntervalSince1970)
            }
        } else if case .token = decision.source, let date = claims?.accountGrant?.untilDate {
            // Only a token-sourced decision has a token horizon: the genuine grant's. Free access
            // (`.freeAccess`) has none, so the extension never ends it on its own.
            until = Int64(date.timeIntervalSince1970)
        }

        var capabilities = decision.state.capabilities
        var degradedReason = decision.state.degradedReason
        if let deviceWide, !capabilities.contains(SGEntitlementCapability.wildcard), deviceWide.validUntil < Date.distantFuture {
            let deviceGlobal = Set(SGEntitlementCapability.allCases.filter { $0.isDeviceGlobal }.map { $0.rawValue })
            var granted: Set<String> = []
            if deviceWide.capabilities.contains(SGEntitlementCapability.wildcard) {
                granted = deviceGlobal
            } else {
                granted = deviceWide.capabilities.intersection(deviceGlobal)
            }
            let added = granted.subtracting(capabilities)
            if !added.isEmpty {
                capabilities.formUnion(added)
                degradedReason = nil
                let unionUntil = Int64(deviceWide.validUntil.timeIntervalSince1970)
                if decision.state.isUnlocked, let own = until {
                    until = min(own, unionUntil)
                } else {
                    until = unionUntil
                }
            }
        }

        return SGEntitlementMirror(
            capabilities: Array(capabilities),
            until: until,
            exp: decision.source == .token ? claims?.exp : nil,
            graceDays: claims?.graceDays ?? SGEntitlementClaims.defaultGraceDays,
            source: decision.source.rawValue,
            degradedReason: degradedReason?.rawValue,
            updatedAt: updatedAt
        )
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SGEntitlement.didChangeNotification, object: nil)
        }
    }

    /// Extensions only. The main app is the writer: registering there would make it react to its own
    /// post, re-evaluate, write the mirror again and post again.
    private func registerDarwinObserver() {
        guard SGEntitlement.isAppExtension, !self.isDarwinObserverRegistered else {
            return
        }
        self.isDarwinObserverRegistered = true
        var token: Int32 = 0
        let status = notify_register_dispatch(SGEntitlement.darwinNotificationName, &token, DispatchQueue.main, { [weak self] _ in
            guard let self else {
                return
            }
            self.lock.lock()
            self.invalidateCachedDecisionLocked()
            // The app may have recorded a revocation or an owner: re-read it, like the session.
            self.didLoadAppleProvenance = false
            self.didLoadStoreKit = false
            // …and the monetization policy the app may have adopted.
            self.didLoadPolicy = false
            self.lock.unlock()
            self.store.invalidateCache()
            self.postChange()
        })
        if status == NOTIFY_STATUS_OK {
            self.darwinToken = token
        }
    }

    // MARK: - Refresh

    /// Considers a refresh of every account signed in on this install, the active one first. Never
    /// blocks the caller, never runs on the launch critical path, and silently does nothing for an
    /// account that is not linked, while the budget is spent or a backoff is in force.
    ///
    /// Every account, not only the one in front: the device-global gates answer over the union of
    /// all of them, and a server-side change (an operator, a refund, a renewal) can concern any.
    /// Each account decides on its own token's age (`SGEntitlementScheduler`).
    public func refresh(trigger: SGEntitlementRefreshTrigger) {
        guard !SGEntitlement.isAppExtension else {
            return
        }
        self.refreshQueue.async { [weak self] in
            guard let self else {
                return
            }
            for account in self.refreshTargets() {
                self.startRefresh(trigger: trigger, accountPeerId: account, completion: nil)
            }
        }
    }

    /// A refresh of ONE account (a 401 is about the session that received it).
    private func refresh(trigger: SGEntitlementRefreshTrigger, accountPeerId: Int64) {
        guard !SGEntitlement.isAppExtension else {
            return
        }
        self.refreshQueue.async { [weak self] in
            self?.startRefresh(trigger: trigger, accountPeerId: accountPeerId, completion: nil)
        }
    }

    private func refreshTargets() -> [Int64] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return SGEntitlement.refreshTargets(active: self.activeAccount, known: self.knownAccounts)
    }

    /// The `iat` of the account's stored token, when it verifies — the same claims the evaluator
    /// would decide with.
    private func storedTokenIssuedAt(_ material: SGEntitlementSessionMaterial, accountPeerId: Int64) -> Date? {
        guard let jws = material.entitlement else {
            return nil
        }
        guard case let .success(claims) = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: self.currentPinnedKeys(), boundDeviceId: material.deviceId, boundAccountId: material.accountId, accountPeerId: accountPeerId) else {
            return nil
        }
        return claims.issuedAtDate
    }

    /// Runs on `refreshQueue`: decides for `account` and, when the scheduler says go, sends under
    /// the session captured here. `completion`, when given, receives how it ended — exactly once.
    private func startRefresh(trigger: SGEntitlementRefreshTrigger, accountPeerId account: Int64, admission: ((SGEntitlementScheduler.Decision) -> Void)? = nil, completion: ((SGEntitlementRefreshAttempt) -> Void)?) {
        guard let client = self.client else {
            admission?(.skip)
            completion?(.notAttempted)
            return
        }
        let material = self.store.session(accountPeerId: account)
        let telemetry = self.pushTelemetry(material: material)
        let decision = self.scheduler.decide(
            trigger: trigger,
            accountPeerId: account,
            tokenIssuedAt: self.storedTokenIssuedAt(material, accountPeerId: account),
            isLinked: material.isLinked,
            wantsRotation: telemetry.wantsRotation
        )
        // The session this refresh runs under, captured once: sent, compared against when a rotated
        // token is stored, and the only session a failure may act on.
        guard decision == .fetch || decision == .rotate, let refreshToken = material.refreshToken else {
            admission?(decision == .fetch || decision == .rotate ? .skip : decision)
            completion?(.notAttempted)
            return
        }
        admission?(decision)
        let credential = SGEntitlementSessionCredential(accountPeerId: account, refreshToken: refreshToken)
        self.scheduler.willPerform(decision, accountPeerId: account)
        let transport = SGEntitlementRefreshTransport.live(client)
        Task {
            let attempt = await self.performRefresh(decision, credential: credential, telemetry: telemetry, transport: transport)
            completion?(attempt)
        }
    }

    /// Sends the decided call and applies its answer to `credential`'s account ONLY: a token is
    /// adopted only while that exact session is still the account's (`adopt`), and a failure only
    /// ever acts on it (`apply`) — never on whichever account is in front by the time it returns.
    /// A failure changes no access (I2): the cached token keeps governing. An answer that belongs to
    /// a session that has since changed hands is `.notAdopted`, and backs nothing off: the server
    /// answered.
    func performRefresh(_ decision: SGEntitlementScheduler.Decision, credential: SGEntitlementSessionCredential, telemetry: SGEntitlementPushTelemetry, transport: SGEntitlementRefreshTransport) async -> SGEntitlementRefreshAttempt {
        let account = credential.accountPeerId
        if case .rotate = decision {
            switch await transport.rotate(credential, telemetry.pushToken) {
            case let .rotated(value):
                // The successor and the push-token receipt were stored in one write
                // (`SGEntitlementClient.persistRotation`). The JWS belongs to that session.
                let adopted = self.adopt(entitlement: value.entitlement, credential: SGEntitlementSessionCredential(accountPeerId: account, refreshToken: value.refreshToken))
                self.scheduler.didSucceed(accountPeerId: account)
                return adopted ? .adopted : .notAdopted
            case .sessionChanged:
                self.scheduler.didSucceed(accountPeerId: account)
                return .notAdopted
            case .notPersisted:
                self.scheduler.didFail(accountPeerId: account, retryAfter: nil)
                return .failed
            case let .failed(error):
                self.apply(error, credential: credential)
                self.scheduler.didFail(accountPeerId: account, retryAfter: error.retryAfter.map { TimeInterval($0) })
                return .failed
            }
        }
        switch await transport.fetch(credential) {
        case let .success(jws):
            let adopted = self.adopt(entitlement: jws, credential: credential)
            self.scheduler.didSucceed(accountPeerId: account)
            return adopted ? .adopted : .notAdopted
        case let .failure(error):
            self.apply(error, credential: credential)
            self.scheduler.didFail(accountPeerId: account, retryAfter: error.retryAfter.map { TimeInterval($0) })
            return .failed
        }
    }
}

/// Zenlygram — the union of every account's capabilities on this install, for the device-global
/// gates (`SGEntitlementCapability.isDeviceGlobal`). Holds until the earliest horizon among them.
struct SGEntitlementDeviceWideDecision: Equatable {
    let capabilities: Set<String>
    let validUntil: Date

    func grants(_ capability: SGEntitlementCapability) -> Bool {
        return self.capabilities.contains(SGEntitlementCapability.wildcard) || self.capabilities.contains(capability.rawValue)
    }
}

/// Zenlygram — what one evaluation learned about the install's local grace record
/// (`SGEntitlement.resolveLocalGrace`).
struct SGEntitlementLocalGraceLoad: Equatable {
    let grace: SGEntitlementLocalGrace?
    /// False while the record could neither be read nor proven written — a launch before the first
    /// unlock after a reboot. The window is then granted in memory for this evaluation only: never
    /// cached, never mirrored to the extensions, retried on the next evaluation.
    let isVerified: Bool
    /// The `lastSeenAt` known to be on disk, when the record is verified.
    let persistedSeenAt: Date?

    init(grace: SGEntitlementLocalGrace?, isVerified: Bool, persistedSeenAt: Date? = nil) {
        self.grace = grace
        self.isVerified = isVerified
        self.persistedSeenAt = persistedSeenAt
    }
}

/// Zenlygram — what one paid-mode evaluation learned about the install's paid-policy mark
/// (`SGEntitlement.resolvePaidModeMark`, D9).
struct SGEntitlementPaidModeMarkLoad: Equatable {
    /// `SGEntitlementPaidModeMark.firstPaidPolicyAt`; nil where no record exists and none may be
    /// minted (an extension).
    let firstPaidPolicyAt: Date?
    /// False while the record could neither be read nor proven written: the re-based window is then
    /// granted in memory for this evaluation only, never cached, never mirrored.
    let isVerified: Bool
}

extension SGEntitlementPolicyStore {
    /// The app group, next to the mirror: the app writes it, every process re-verifies it.
    public static let shared = SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: SGProtectedKeychain.sharedAccessGroup))
}
