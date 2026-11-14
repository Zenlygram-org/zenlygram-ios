import Foundation

/// Zenlygram — analytics taxonomy v1 (contract §3.2): the registry
/// `B/resources/contracts/analytics-events.json` (vendored byte for byte as
/// `Tests/Fixtures/analytics-events.json`) as Swift types. Every event name, prop and enum value
/// of the registry is spelled here once; `SGAnalyticsRegistryTests` holds this file to the
/// vendored registry one to one. Adding anything is a taxonomy bump, deployed to the server before
/// an app emits it.
///
/// An event cannot carry free text (contract §6.9): a string prop is a registry enum (the public
/// `String` raw-value enums below — Tasks builds them from raw values, T§2) or a value validated at
/// construction against its registry pattern (`SGAnalyticsProductId`, `SGAnalyticsBasePlanId`,
/// `SGAnalyticsErrorCode`), and every integer is clamped to its registry type.
public enum SGAnalyticsTaxonomy {
    public static let version = 1
    /// An event's compact JSON is at most 2 KiB (contract §3.1).
    public static let maxEventBytes = 2048
    /// `seq`: 0…1 000 000, strictly increasing per (account, session); `app.session_start` is 0.
    public static let maxSeq = 1_000_000
}

// MARK: - Registry enums (`enums.<name>`)

/// `enums.screen`: the screens a client reports (Telegram-native surfaces only at tab level).
public enum SGAnalyticsScreen: String, CaseIterable, Equatable, Hashable {
    case zgHub = "zg.hub"
    case zgPro = "zg.pro"
    case zgPaywall = "zg.paywall"
    case zgLinkAccount = "zg.link_account"
    case zgDataConsent = "zg.data_consent"
    case zgMyData = "zg.my_data"
    case zgAccountDelete = "zg.account_delete"
    case zgPreferences = "zg.preferences"
    case tasksBoard = "tasks.board"
    case tasksLists = "tasks.lists"
    case tasksTaskEditor = "tasks.task_editor"
    case tasksCalendar = "tasks.calendar"
    case tasksUnsentChanges = "tasks.unsent_changes"
    case tasksInvitations = "tasks.invitations"
    case tasksArchive = "tasks.archive"
    case vaultUnlock = "vault.unlock"
    case vaultChats = "vault.chats"
    case vaultSettings = "vault.settings"
    case chatLockUnlock = "chat_lock.unlock"
    case chatLockSettings = "chat_lock.settings"
    case editHistoryMessage = "edit_history.message"
    case editHistorySettings = "edit_history.settings"
    case callsRecordings = "calls.recordings"
    case tgChatList = "tg.chat_list"
    case tgContacts = "tg.contacts"
    case tgCalls = "tg.calls"
    case tgSettings = "tg.settings"
}

/// `enums.feature`. A platform reports only the features it has (`ocr` is Android's).
public enum SGAnalyticsFeature: String, CaseIterable, Equatable, Hashable {
    case tasks
    case tasksCloud = "tasks_cloud"
    case tasksCalendar = "tasks_calendar"
    case vault
    case chatLock = "chat_lock"
    case editHistory = "edit_history"
    case deletedMessages = "deleted_messages"
    case callRecording = "call_recording"
    case translation
    case unreadReminder = "unread_reminder"
    case strangerInbox = "stranger_inbox"
    case foreignUserBlock = "foreign_user_block"
    case messageFilter = "message_filter"
    case ocr
    case dictation
    case apkProtection = "apk_protection"
    case chatTools = "chat_tools"
    case folders
    case roundVideoFromGallery = "round_video_from_gallery"
    case storyConfirmation = "story_confirmation"
    case sendConfirmation = "send_confirmation"
    case appIcon = "app_icon"
}

/// `enums.error_domain` (`error.occurred`).
public enum SGAnalyticsErrorDomain: String, CaseIterable, Equatable, Hashable {
    case network
    case backend
    case link
    case tasksSync = "tasks_sync"
    case tasksMigration = "tasks_migration"
    case purchase
    case consentUpload = "consent_upload"
    case profileSync = "profile_sync"
    case eventsUpload = "events_upload"
    case storage
    case vault
    case chatLock = "chat_lock"
    case other
}

/// `enums.rail`: where a purchase runs.
public enum SGAnalyticsRail: String, CaseIterable, Equatable, Hashable {
    case apple
    case google
    case web
}

/// `enums.tasks_scope`.
public enum SGAnalyticsTasksScope: String, CaseIterable, Equatable, Hashable {
    case cloud
    case local
}

// MARK: - Inline enums (an event's own list)

/// `app.session_start.trigger` (produced by the pipeline only).
public enum SGAnalyticsSessionTrigger: String, CaseIterable, Equatable, Hashable {
    case launch
    case foreground
    case accountSwitch = "account_switch"
}

/// `app.session_end.reason` (produced by the pipeline only; iOS never ends a session with
/// `logout`: a logout purges the account's queue, design 40 Contract issue 10).
public enum SGAnalyticsSessionEndReason: String, CaseIterable, Equatable, Hashable {
    case background
    case accountSwitch = "account_switch"
    case logout
    case terminate
}

/// `tasks.shared.action`.
public enum SGAnalyticsTasksSharedAction: String, CaseIterable, Equatable, Hashable {
    case inviteSent = "invite_sent"
    case inviteAccepted = "invite_accepted"
    case inviteDeclined = "invite_declined"
    case left
    case revoked
    case blocked
}

/// `tasks.migration.phase`.
public enum SGAnalyticsTasksMigrationPhase: String, CaseIterable, Equatable, Hashable {
    case started
    case completed
    case failed
}

/// `tasks.sync_issue.kind` (aggregated per session by the pipeline).
public enum SGAnalyticsTasksSyncIssueKind: String, CaseIterable, Equatable, Hashable {
    case conflictAutoResolved = "conflict_auto_resolved"
    case conflictManual = "conflict_manual"
    case stalled
    case blockedCreation = "blocked_creation"
    case invalid
}

/// `vault.unlocked.method`, `chat_lock.unlocked.method`.
public enum SGAnalyticsUnlockMethod: String, CaseIterable, Equatable, Hashable {
    case pin
    case password
    case biometric
}

/// `chat_lock.lock_set.method`.
public enum SGAnalyticsLockMethod: String, CaseIterable, Equatable, Hashable {
    case pin
    case password
}

/// `edit_history.viewed.kind`.
public enum SGAnalyticsEditHistoryKind: String, CaseIterable, Equatable, Hashable {
    case edited
    case deleted
}

/// `pro.screen_view.source`: how the paywall was reached (`SGAnalytics.takePaywallEntry()`).
public enum SGAnalyticsProSource: String, CaseIterable, Equatable, Hashable {
    case settings
    case paywall
    case featureGate = "feature_gate"
    case tasks
    case link
    case deeplink
    case other
}

/// `pro.screen_view.mode`: the monetization mode the screen showed.
public enum SGAnalyticsProMode: String, CaseIterable, Equatable, Hashable {
    case free
    case paid
}

/// `pro.purchase_fail.reason`.
public enum SGAnalyticsPurchaseFailReason: String, CaseIterable, Equatable, Hashable {
    case cancelled
    case pending
    case failed
    case notAllowed = "not_allowed"
    case unavailable
}

/// `pro.restore.outcome`.
public enum SGAnalyticsRestoreOutcome: String, CaseIterable, Equatable, Hashable {
    case restored
    case nothing
    case failed
}

/// `pro.trial_start.outcome`.
public enum SGAnalyticsTrialOutcome: String, CaseIterable, Equatable, Hashable {
    case started
    case refused
    case failed
}

/// `link.attempt.trigger`.
public enum SGAnalyticsLinkTrigger: String, CaseIterable, Equatable, Hashable {
    case auto
    case manual
}

/// `link.attempt.method`.
public enum SGAnalyticsLinkMethod: String, CaseIterable, Equatable, Hashable {
    case attest
    case code
}

/// `link.attempt.outcome`.
public enum SGAnalyticsLinkOutcome: String, CaseIterable, Equatable, Hashable {
    case success
    case failed
}

// MARK: - Validated values (`types.<name>`)

/// `types.product_id`: `^[A-Za-z0-9._-]{1,100}$`.
public struct SGAnalyticsProductId: Equatable, Hashable {
    public let rawValue: String

    public init?(_ value: String) {
        guard SGAnalyticsPatternType.productId.accepts(value) else {
            return nil
        }
        self.rawValue = value
    }
}

/// `types.base_plan_id` (Google Play base plans): `^[a-z0-9][a-z0-9-]{0,62}$`.
public struct SGAnalyticsBasePlanId: Equatable, Hashable {
    public let rawValue: String

    public init?(_ value: String) {
        guard SGAnalyticsPatternType.basePlanId.accepts(value) else {
            return nil
        }
        self.rawValue = value
    }
}

/// `types.error_code` (contract §3.4): `^[a-z0-9][a-z0-9_.-]{0,63}$`, a stable code — a backend
/// `error`, `http_<nnn>`, `timeout`, `offline`, `dns`, `tls`, `storekit_<int>`, `sqlite_<int>`,
/// `telegram_<rpc error>` or `unknown`. Never an exception message, a URL, an id, a name or user
/// text: build it with the helpers, from codes the app itself defines.
public struct SGAnalyticsErrorCode: Equatable, Hashable {
    public let rawValue: String

    /// `code` when it is a stable code, else nil.
    public init?(_ code: String) {
        guard SGAnalyticsPatternType.errorCode.accepts(code) else {
            return nil
        }
        self.rawValue = code
    }

    private init(unchecked code: String) {
        self.rawValue = code
    }

    public static let timeout = SGAnalyticsErrorCode(unchecked: "timeout")
    public static let offline = SGAnalyticsErrorCode(unchecked: "offline")
    public static let dns = SGAnalyticsErrorCode(unchecked: "dns")
    public static let tls = SGAnalyticsErrorCode(unchecked: "tls")
    public static let unknown = SGAnalyticsErrorCode(unchecked: "unknown")

    /// `http_<nnn>` for an HTTP status (100…599), else `unknown`.
    public static func http(_ status: Int) -> SGAnalyticsErrorCode {
        guard (100 ... 599).contains(status) else {
            return .unknown
        }
        return SGAnalyticsErrorCode(unchecked: "http_\(status)")
    }

    /// A backend stable `error` code (`rate_limited`, `attest_unavailable`, …) as received, else
    /// `unknown`.
    public static func backend(_ code: String?) -> SGAnalyticsErrorCode {
        return code.flatMap(SGAnalyticsErrorCode.init) ?? .unknown
    }

    /// `storekit_<code>` (a StoreKit error code).
    public static func storekit(_ code: Int) -> SGAnalyticsErrorCode {
        return SGAnalyticsErrorCode("storekit_\(code)") ?? .unknown
    }

    /// `sqlite_<code>` (an SQLite result code).
    public static func sqlite(_ code: Int) -> SGAnalyticsErrorCode {
        return SGAnalyticsErrorCode("sqlite_\(code)") ?? .unknown
    }

    /// `telegram_<rpc error lower-cased>`: `BOT_INVALID` → `telegram_bot_invalid`, clipped to 64
    /// characters; an error that is not an RPC error name (`[A-Za-z0-9_]`) → `unknown`.
    public static func telegram(rpcError: String) -> SGAnalyticsErrorCode {
        let bytes = Array(rpcError.utf8)
        let isName = !bytes.isEmpty && bytes.allSatisfy { byte in
            (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_")
        }
        guard isName else {
            return .unknown
        }
        return SGAnalyticsErrorCode(String(("telegram_" + rpcError.lowercased()).prefix(64))) ?? .unknown
    }
}

// MARK: - Events

/// Zenlygram — the events a feature module records (contract §3.2, design 40 §10.1), one case per
/// registry name. `app.session_start` / `app.session_end`, `error.occurred` and `tasks.sync_issue`
/// are produced by the pipeline only (sessions, and the per-session aggregates of
/// `SGAnalytics.error` / `SGAnalytics.tasksSyncIssue`).
public enum SGAnalyticsEvent: Equatable {
    case screenView(SGAnalyticsScreen)
    case featureToggle(SGAnalyticsFeature, enabled: Bool)
    /// At most once per feature per session (the pipeline drops repeats).
    case featureUsed(SGAnalyticsFeature)
    case tasksTaskCreated(scope: SGAnalyticsTasksScope, hasDue: Bool, priority: Int, inList: Bool)
    case tasksTaskCompleted(scope: SGAnalyticsTasksScope, reopened: Bool)
    case tasksTaskDeleted(scope: SGAnalyticsTasksScope)
    case tasksListCreated(scope: SGAnalyticsTasksScope)
    case tasksListDeleted(scope: SGAnalyticsTasksScope, tasks: Int)
    case tasksShared(action: SGAnalyticsTasksSharedAction)
    case tasksMigration(phase: SGAnalyticsTasksMigrationPhase, lists: Int?, tasks: Int?, skipped: Int?, durationS: Int?, errorCode: SGAnalyticsErrorCode?)
    case vaultUnlocked(method: SGAnalyticsUnlockMethod)
    case vaultChatAdded
    case vaultChatRemoved
    case chatLockLockSet(method: SGAnalyticsLockMethod, biometric: Bool)
    case chatLockUnlocked(method: SGAnalyticsUnlockMethod)
    case chatLockLockRemoved
    case editHistoryViewed(kind: SGAnalyticsEditHistoryKind)
    case proScreenView(source: SGAnalyticsProSource, mode: SGAnalyticsProMode)
    case proPlanSelect(productId: SGAnalyticsProductId, rail: SGAnalyticsRail, basePlanId: SGAnalyticsBasePlanId?)
    case proPurchaseStart(productId: SGAnalyticsProductId, rail: SGAnalyticsRail, basePlanId: SGAnalyticsBasePlanId?)
    case proPurchaseSuccess(productId: SGAnalyticsProductId, rail: SGAnalyticsRail, basePlanId: SGAnalyticsBasePlanId?, trial: Bool)
    case proPurchaseFail(productId: SGAnalyticsProductId, rail: SGAnalyticsRail, basePlanId: SGAnalyticsBasePlanId?, reason: SGAnalyticsPurchaseFailReason, errorCode: SGAnalyticsErrorCode?)
    case proRestore(rail: SGAnalyticsRail, outcome: SGAnalyticsRestoreOutcome, errorCode: SGAnalyticsErrorCode?)
    case proTrialStart(outcome: SGAnalyticsTrialOutcome, errorCode: SGAnalyticsErrorCode?)
    case linkAttempt(trigger: SGAnalyticsLinkTrigger, method: SGAnalyticsLinkMethod, outcome: SGAnalyticsLinkOutcome, errorCode: SGAnalyticsErrorCode?, durationS: Int?)

    /// The registry name.
    public var name: String {
        return self.payload.name
    }

    /// The name and props as sent, integers clamped to their registry types.
    var payload: SGAnalyticsPayload {
        switch self {
        case let .screenView(screen):
            return SGAnalyticsPayload("screen.view", ["screen": .string(screen.rawValue)])
        case let .featureToggle(feature, enabled):
            return SGAnalyticsPayload("feature.toggle", ["feature": .string(feature.rawValue), "enabled": .boolean(enabled)])
        case let .featureUsed(feature):
            return SGAnalyticsPayload("feature.used", ["feature": .string(feature.rawValue)])
        case let .tasksTaskCreated(scope, hasDue, priority, inList):
            return SGAnalyticsPayload("tasks.task_created", ["scope": .string(scope.rawValue), "has_due": .boolean(hasDue), "priority": .integer(SGAnalyticsIntegerType.priority.clamp(priority)), "in_list": .boolean(inList)])
        case let .tasksTaskCompleted(scope, reopened):
            return SGAnalyticsPayload("tasks.task_completed", ["scope": .string(scope.rawValue), "reopened": .boolean(reopened)])
        case let .tasksTaskDeleted(scope):
            return SGAnalyticsPayload("tasks.task_deleted", ["scope": .string(scope.rawValue)])
        case let .tasksListCreated(scope):
            return SGAnalyticsPayload("tasks.list_created", ["scope": .string(scope.rawValue)])
        case let .tasksListDeleted(scope, tasks):
            return SGAnalyticsPayload("tasks.list_deleted", ["scope": .string(scope.rawValue), "tasks": .integer(SGAnalyticsIntegerType.amount.clamp(tasks))])
        case let .tasksShared(action):
            return SGAnalyticsPayload("tasks.shared", ["action": .string(action.rawValue)])
        case let .tasksMigration(phase, lists, tasks, skipped, durationS, errorCode):
            var props: [String: SGAnalyticsValue] = ["phase": .string(phase.rawValue)]
            props["lists"] = lists.map { .integer(SGAnalyticsIntegerType.amount.clamp($0)) }
            props["tasks"] = tasks.map { .integer(SGAnalyticsIntegerType.amount.clamp($0)) }
            props["skipped"] = skipped.map { .integer(SGAnalyticsIntegerType.amount.clamp($0)) }
            props["duration_s"] = durationS.map { .integer(SGAnalyticsIntegerType.durationS.clamp($0)) }
            props["error_code"] = errorCode.map { .string($0.rawValue) }
            return SGAnalyticsPayload("tasks.migration", props)
        case let .vaultUnlocked(method):
            return SGAnalyticsPayload("vault.unlocked", ["method": .string(method.rawValue)])
        case .vaultChatAdded:
            return SGAnalyticsPayload("vault.chat_added", [:])
        case .vaultChatRemoved:
            return SGAnalyticsPayload("vault.chat_removed", [:])
        case let .chatLockLockSet(method, biometric):
            return SGAnalyticsPayload("chat_lock.lock_set", ["method": .string(method.rawValue), "biometric": .boolean(biometric)])
        case let .chatLockUnlocked(method):
            return SGAnalyticsPayload("chat_lock.unlocked", ["method": .string(method.rawValue)])
        case .chatLockLockRemoved:
            return SGAnalyticsPayload("chat_lock.lock_removed", [:])
        case let .editHistoryViewed(kind):
            return SGAnalyticsPayload("edit_history.viewed", ["kind": .string(kind.rawValue)])
        case let .proScreenView(source, mode):
            return SGAnalyticsPayload("pro.screen_view", ["source": .string(source.rawValue), "mode": .string(mode.rawValue)])
        case let .proPlanSelect(productId, rail, basePlanId):
            return SGAnalyticsPayload("pro.plan_select", SGAnalyticsEvent.purchaseProps(productId, rail, basePlanId))
        case let .proPurchaseStart(productId, rail, basePlanId):
            return SGAnalyticsPayload("pro.purchase_start", SGAnalyticsEvent.purchaseProps(productId, rail, basePlanId))
        case let .proPurchaseSuccess(productId, rail, basePlanId, trial):
            var props = SGAnalyticsEvent.purchaseProps(productId, rail, basePlanId)
            props["trial"] = .boolean(trial)
            return SGAnalyticsPayload("pro.purchase_success", props)
        case let .proPurchaseFail(productId, rail, basePlanId, reason, errorCode):
            var props = SGAnalyticsEvent.purchaseProps(productId, rail, basePlanId)
            props["reason"] = .string(reason.rawValue)
            props["error_code"] = errorCode.map { .string($0.rawValue) }
            return SGAnalyticsPayload("pro.purchase_fail", props)
        case let .proRestore(rail, outcome, errorCode):
            var props: [String: SGAnalyticsValue] = ["rail": .string(rail.rawValue), "outcome": .string(outcome.rawValue)]
            props["error_code"] = errorCode.map { .string($0.rawValue) }
            return SGAnalyticsPayload("pro.restore", props)
        case let .proTrialStart(outcome, errorCode):
            var props: [String: SGAnalyticsValue] = ["outcome": .string(outcome.rawValue)]
            props["error_code"] = errorCode.map { .string($0.rawValue) }
            return SGAnalyticsPayload("pro.trial_start", props)
        case let .linkAttempt(trigger, method, outcome, errorCode, durationS):
            var props: [String: SGAnalyticsValue] = ["trigger": .string(trigger.rawValue), "method": .string(method.rawValue), "outcome": .string(outcome.rawValue)]
            props["error_code"] = errorCode.map { .string($0.rawValue) }
            props["duration_s"] = durationS.map { .integer(SGAnalyticsIntegerType.durationS.clamp($0)) }
            return SGAnalyticsPayload("link.attempt", props)
        }
    }

    private static func purchaseProps(_ productId: SGAnalyticsProductId, _ rail: SGAnalyticsRail, _ basePlanId: SGAnalyticsBasePlanId?) -> [String: SGAnalyticsValue] {
        var props: [String: SGAnalyticsValue] = ["product_id": .string(productId.rawValue), "rail": .string(rail.rawValue)]
        props["base_plan_id"] = basePlanId.map { .string($0.rawValue) }
        return props
    }
}

// MARK: - Wire form

/// A prop value: the registry knows strings (enums and patterned ids), integers and booleans only.
enum SGAnalyticsValue: Equatable {
    case string(String)
    case integer(Int)
    case boolean(Bool)

    var json: String {
        switch self {
        case let .string(value):
            return SGCustomerJSON.quoted(value)
        case let .integer(value):
            return String(value)
        case let .boolean(value):
            return value ? "true" : "false"
        }
    }
}

/// One event's `name` and `props` as sent — built only from `SGAnalyticsEvent` or by the pipeline.
struct SGAnalyticsPayload: Equatable {
    let name: String
    let props: [String: SGAnalyticsValue]

    init(_ name: String, _ props: [String: SGAnalyticsValue]) {
        self.name = name
        self.props = props
    }

    // The pipeline's own events.

    static func sessionStart(_ trigger: SGAnalyticsSessionTrigger) -> SGAnalyticsPayload {
        return SGAnalyticsPayload("app.session_start", ["trigger": .string(trigger.rawValue)])
    }

    static func sessionEnd(durationS: Int, reason: SGAnalyticsSessionEndReason) -> SGAnalyticsPayload {
        return SGAnalyticsPayload("app.session_end", ["duration_s": .integer(SGAnalyticsIntegerType.durationS.clamp(durationS)), "reason": .string(reason.rawValue)])
    }

    static func errorOccurred(domain: SGAnalyticsErrorDomain, code: SGAnalyticsErrorCode, count: Int) -> SGAnalyticsPayload {
        return SGAnalyticsPayload("error.occurred", ["domain": .string(domain.rawValue), "code": .string(code.rawValue), "count": .integer(SGAnalyticsIntegerType.count.clamp(count))])
    }

    static func tasksSyncIssue(kind: SGAnalyticsTasksSyncIssueKind, count: Int) -> SGAnalyticsPayload {
        return SGAnalyticsPayload("tasks.sync_issue", ["kind": .string(kind.rawValue), "count": .integer(SGAnalyticsIntegerType.count.clamp(count))])
    }

    /// `{…}` with sorted keys.
    var propsJSON: String {
        return SGCustomerJSON.object(self.props.map { ($0.key, $0.value.json) })
    }

    /// The payload of decoded JSON `props` when it is exactly what this client builds for `name`:
    /// a registry name, every prop declared, every value within its rule (strictly typed, no
    /// null), every required prop present. Else nil — the server would reject it, or drop props.
    static func validated(name: String, props: [String: Any]) -> SGAnalyticsPayload? {
        guard let rules = SGAnalyticsSchema.events[name] else {
            return nil
        }
        var values: [String: SGAnalyticsValue] = [:]
        for (key, raw) in props {
            guard let rule = rules[key], let value = rule.kind.value(raw) else {
                return nil
            }
            values[key] = value
        }
        for (key, rule) in rules where rule.required && values[key] == nil {
            return nil
        }
        return SGAnalyticsPayload(name, values)
    }
}

/// One queued or sent event (contract §3.1): `{"id","name","ts","session_id","seq","props"}`.
struct SGAnalyticsWireEvent: Equatable {
    static let keys: Set<String> = ["id", "name", "ts", "session_id", "seq", "props"]

    let id: String
    let ts: String
    let sessionId: String
    let seq: Int
    let payload: SGAnalyticsPayload

    /// Compact JSON with sorted keys, slashes and non-ASCII unescaped — the form the server measures
    /// the 2 KiB limit on.
    func encoded() -> Data {
        return Data(SGCustomerJSON.object([
            ("id", SGCustomerJSON.quoted(self.id)),
            ("name", SGCustomerJSON.quoted(self.payload.name)),
            ("props", self.payload.propsJSON),
            ("seq", String(self.seq)),
            ("session_id", SGCustomerJSON.quoted(self.sessionId)),
            ("ts", SGCustomerJSON.quoted(self.ts)),
        ]).utf8)
    }

    /// The envelope fields within the contract and the size within 2 KiB.
    var isValid: Bool {
        return SGCustomerTime.isUUID4(self.id) && SGCustomerTime.isUUID4(self.sessionId) && SGCustomerTime.isInstant(self.ts)
            && (0 ... SGAnalyticsTaxonomy.maxSeq).contains(self.seq) && self.encoded().count <= SGAnalyticsTaxonomy.maxEventBytes
    }

    /// The event of a decoded JSON value when this client could have built it (`isValid` and
    /// `SGAnalyticsPayload.validated`), else nil.
    static func validated(_ value: Any) -> SGAnalyticsWireEvent? {
        guard let object = value as? [String: Any], Set(object.keys) == SGAnalyticsWireEvent.keys,
              let id = object["id"] as? String, let name = object["name"] as? String, let ts = object["ts"] as? String,
              let sessionId = object["session_id"] as? String, let seq = SGConsentManifest.integer(object["seq"]),
              let props = object["props"] as? [String: Any],
              let payload = SGAnalyticsPayload.validated(name: name, props: props) else {
            return nil
        }
        let event = SGAnalyticsWireEvent(id: id, ts: ts, sessionId: sessionId, seq: seq, payload: payload)
        return event.isValid ? event : nil
    }
}

// MARK: - Schema (the client's copy of the registry)

/// The integer `types` of the registry; values are clamped into them when an event is built.
enum SGAnalyticsIntegerType: String, CaseIterable {
    case count
    case amount
    case durationS = "duration_s"
    case priority

    var range: ClosedRange<Int> {
        switch self {
        case .count:
            return 1 ... 1000
        case .amount:
            return 0 ... 100_000
        case .durationS:
            return 0 ... 86_400
        case .priority:
            return 0 ... 4
        }
    }

    func clamp(_ value: Int) -> Int {
        return min(max(value, self.range.lowerBound), self.range.upperBound)
    }
}

/// The string `types` of the registry, each an anchored ASCII pattern checked byte by byte.
enum SGAnalyticsPatternType: String, CaseIterable {
    case productId = "product_id"
    case basePlanId = "base_plan_id"
    case errorCode = "error_code"

    /// The registry's `pattern`, verbatim (`SGAnalyticsRegistryTests` compares it).
    var pattern: String {
        switch self {
        case .productId:
            return "^[A-Za-z0-9._-]{1,100}$"
        case .basePlanId:
            return "^[a-z0-9][a-z0-9-]{0,62}$"
        case .errorCode:
            return "^[a-z0-9][a-z0-9_.-]{0,63}$"
        }
    }

    func accepts(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func isLower(_ byte: UInt8) -> Bool {
            return byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
        }
        func isUpper(_ byte: UInt8) -> Bool {
            return byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
        }
        func isDigit(_ byte: UInt8) -> Bool {
            return byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
        switch self {
        case .productId:
            return (1 ... 100).contains(bytes.count) && bytes.allSatisfy { isLower($0) || isUpper($0) || isDigit($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
        case .basePlanId:
            guard let first = bytes.first, bytes.count <= 63, isLower(first) || isDigit(first) else {
                return false
            }
            return bytes.dropFirst().allSatisfy { isLower($0) || isDigit($0) || $0 == UInt8(ascii: "-") }
        case .errorCode:
            return SGCustomerLogCode.isStableCode(text)
        }
    }
}

/// The client's copy of the registry (contract §3.2), built from the Swift enums above:
/// `SGAnalyticsRegistryTests` compares it with the vendored `analytics-events.json` one to one, and
/// `SGAnalyticsPayload.validated` checks every event against it.
enum SGAnalyticsSchema {
    struct Rule: Equatable {
        enum Kind: Equatable {
            case boolean
            case integer(SGAnalyticsIntegerType)
            case pattern(SGAnalyticsPatternType)
            /// `{"enum": "<name>"}`: `enums.<name>`.
            case named(String, [String])
            /// `{"enum": [...]}`.
            case inline([String])

            /// `raw` (a decoded JSON value) as this kind's value, strictly typed, or nil.
            func value(_ raw: Any) -> SGAnalyticsValue? {
                switch self {
                case .boolean:
                    guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                        return nil
                    }
                    return .boolean(number.boolValue)
                case let .integer(type):
                    guard let value = SGConsentManifest.integer(raw), type.range.contains(value) else {
                        return nil
                    }
                    return .integer(value)
                case let .pattern(type):
                    guard let text = raw as? String, type.accepts(text) else {
                        return nil
                    }
                    return .string(text)
                case let .named(_, values), let .inline(values):
                    guard let text = raw as? String, values.contains(text) else {
                        return nil
                    }
                    return .string(text)
                }
            }
        }

        let kind: Kind
        let required: Bool

        static func required(_ kind: Kind) -> Rule {
            return Rule(kind: kind, required: true)
        }

        static func optional(_ kind: Kind) -> Rule {
            return Rule(kind: kind, required: false)
        }
    }

    /// `enums`.
    static let enums: [String: [String]] = [
        "screen": SGAnalyticsScreen.allCases.map(\.rawValue),
        "feature": SGAnalyticsFeature.allCases.map(\.rawValue),
        "error_domain": SGAnalyticsErrorDomain.allCases.map(\.rawValue),
        "rail": SGAnalyticsRail.allCases.map(\.rawValue),
        "tasks_scope": SGAnalyticsTasksScope.allCases.map(\.rawValue),
    ]

    /// `events`: name → prop → rule.
    static let events: [String: [String: Rule]] = {
        let screen = Rule.Kind.named("screen", SGAnalyticsScreen.allCases.map(\.rawValue))
        let feature = Rule.Kind.named("feature", SGAnalyticsFeature.allCases.map(\.rawValue))
        let errorDomain = Rule.Kind.named("error_domain", SGAnalyticsErrorDomain.allCases.map(\.rawValue))
        let rail = Rule.Kind.named("rail", SGAnalyticsRail.allCases.map(\.rawValue))
        let scope = Rule.Kind.named("tasks_scope", SGAnalyticsTasksScope.allCases.map(\.rawValue))
        let unlockMethod = Rule.Kind.inline(SGAnalyticsUnlockMethod.allCases.map(\.rawValue))
        let errorCode = Rule.Kind.pattern(.errorCode)
        let purchase: [String: Rule] = [
            "product_id": .required(.pattern(.productId)),
            "rail": .required(rail),
            "base_plan_id": .optional(.pattern(.basePlanId)),
        ]
        func merged(_ base: [String: Rule], _ extra: [String: Rule]) -> [String: Rule] {
            return base.merging(extra, uniquingKeysWith: { _, new in new })
        }
        return [
            "app.session_start": ["trigger": .required(.inline(SGAnalyticsSessionTrigger.allCases.map(\.rawValue)))],
            "app.session_end": [
                "duration_s": .required(.integer(.durationS)),
                "reason": .required(.inline(SGAnalyticsSessionEndReason.allCases.map(\.rawValue))),
            ],
            "screen.view": ["screen": .required(screen)],
            "feature.toggle": ["feature": .required(feature), "enabled": .required(.boolean)],
            "feature.used": ["feature": .required(feature)],
            "tasks.task_created": [
                "scope": .required(scope),
                "has_due": .required(.boolean),
                "priority": .required(.integer(.priority)),
                "in_list": .required(.boolean),
            ],
            "tasks.task_completed": ["scope": .required(scope), "reopened": .required(.boolean)],
            "tasks.task_deleted": ["scope": .required(scope)],
            "tasks.list_created": ["scope": .required(scope)],
            "tasks.list_deleted": ["scope": .required(scope), "tasks": .required(.integer(.amount))],
            "tasks.shared": ["action": .required(.inline(SGAnalyticsTasksSharedAction.allCases.map(\.rawValue)))],
            "tasks.migration": [
                "phase": .required(.inline(SGAnalyticsTasksMigrationPhase.allCases.map(\.rawValue))),
                "lists": .optional(.integer(.amount)),
                "tasks": .optional(.integer(.amount)),
                "skipped": .optional(.integer(.amount)),
                "duration_s": .optional(.integer(.durationS)),
                "error_code": .optional(errorCode),
            ],
            "tasks.sync_issue": [
                "kind": .required(.inline(SGAnalyticsTasksSyncIssueKind.allCases.map(\.rawValue))),
                "count": .required(.integer(.count)),
            ],
            "vault.unlocked": ["method": .required(unlockMethod)],
            "vault.chat_added": [:],
            "vault.chat_removed": [:],
            "chat_lock.lock_set": [
                "method": .required(.inline(SGAnalyticsLockMethod.allCases.map(\.rawValue))),
                "biometric": .required(.boolean),
            ],
            "chat_lock.unlocked": ["method": .required(unlockMethod)],
            "chat_lock.lock_removed": [:],
            "edit_history.viewed": ["kind": .required(.inline(SGAnalyticsEditHistoryKind.allCases.map(\.rawValue)))],
            "pro.screen_view": [
                "source": .required(.inline(SGAnalyticsProSource.allCases.map(\.rawValue))),
                "mode": .required(.inline(SGAnalyticsProMode.allCases.map(\.rawValue))),
            ],
            "pro.plan_select": purchase,
            "pro.purchase_start": purchase,
            "pro.purchase_success": merged(purchase, ["trial": .required(.boolean)]),
            "pro.purchase_fail": merged(purchase, [
                "reason": .required(.inline(SGAnalyticsPurchaseFailReason.allCases.map(\.rawValue))),
                "error_code": .optional(errorCode),
            ]),
            "pro.restore": [
                "rail": .required(rail),
                "outcome": .required(.inline(SGAnalyticsRestoreOutcome.allCases.map(\.rawValue))),
                "error_code": .optional(errorCode),
            ],
            "pro.trial_start": [
                "outcome": .required(.inline(SGAnalyticsTrialOutcome.allCases.map(\.rawValue))),
                "error_code": .optional(errorCode),
            ],
            "link.attempt": [
                "trigger": .required(.inline(SGAnalyticsLinkTrigger.allCases.map(\.rawValue))),
                "method": .required(.inline(SGAnalyticsLinkMethod.allCases.map(\.rawValue))),
                "outcome": .required(.inline(SGAnalyticsLinkOutcome.allCases.map(\.rawValue))),
                "error_code": .optional(errorCode),
                "duration_s": .optional(.integer(.durationS)),
            ],
            "error.occurred": [
                "domain": .required(errorDomain),
                "code": .required(errorCode),
                "count": .required(.integer(.count)),
            ],
        ]
    }()
}
