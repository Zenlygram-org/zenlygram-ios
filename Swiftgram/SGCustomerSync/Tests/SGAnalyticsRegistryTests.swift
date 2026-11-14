import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — taxonomy v1 against the vendored registry (`Tests/Fixtures/analytics-events.json`,
/// a byte copy of `B/resources/contracts/analytics-events.json`; contract §3.2, §10): every enum
/// equals the registry one to one, every event the app can build validates against it with no prop
/// outside it, and every event stays within 2 KiB.
final class SGAnalyticsRegistryTests: XCTestCase {
    func testTheTaxonomyVersionAndTheTypesEqualTheRegistry() throws {
        let registry = try SGAnalyticsRegistry.vendored()
        XCTAssertEqual(registry.version, SGAnalyticsTaxonomy.version)
        XCTAssertEqual(Set(registry.types.keys), Set(SGAnalyticsIntegerType.allCases.map(\.rawValue) + SGAnalyticsPatternType.allCases.map(\.rawValue)))
        for type in SGAnalyticsIntegerType.allCases {
            let rule = try XCTUnwrap(registry.types[type.rawValue])
            XCTAssertEqual(rule["type"] as? String, "integer", type.rawValue)
            XCTAssertEqual(SGCustomerJSON.integer(rule["min"]), type.range.lowerBound, type.rawValue)
            XCTAssertEqual(SGCustomerJSON.integer(rule["max"]), type.range.upperBound, type.rawValue)
        }
        for type in SGAnalyticsPatternType.allCases {
            let rule = try XCTUnwrap(registry.types[type.rawValue])
            XCTAssertEqual(rule["type"] as? String, "string", type.rawValue)
            XCTAssertEqual(rule["pattern"] as? String, type.pattern, type.rawValue)
        }
    }

    func testThePublicEnumsEqualTheRegistryOneToOne() throws {
        let registry = try SGAnalyticsRegistry.vendored()
        let named: [(String, [String])] = [
            ("screen", SGAnalyticsScreen.allCases.map(\.rawValue)),
            ("feature", SGAnalyticsFeature.allCases.map(\.rawValue)),
            ("error_domain", SGAnalyticsErrorDomain.allCases.map(\.rawValue)),
            ("rail", SGAnalyticsRail.allCases.map(\.rawValue)),
            ("tasks_scope", SGAnalyticsTasksScope.allCases.map(\.rawValue)),
        ]
        XCTAssertEqual(Set(registry.enums.keys), Set(named.map(\.0)))
        for (name, values) in named {
            XCTAssertEqual(registry.enums[name], values, name)
        }
        let inline: [(String, String, [String])] = [
            ("app.session_start", "trigger", SGAnalyticsSessionTrigger.allCases.map(\.rawValue)),
            ("app.session_end", "reason", SGAnalyticsSessionEndReason.allCases.map(\.rawValue)),
            ("tasks.shared", "action", SGAnalyticsTasksSharedAction.allCases.map(\.rawValue)),
            ("tasks.migration", "phase", SGAnalyticsTasksMigrationPhase.allCases.map(\.rawValue)),
            ("tasks.sync_issue", "kind", SGAnalyticsTasksSyncIssueKind.allCases.map(\.rawValue)),
            ("vault.unlocked", "method", SGAnalyticsUnlockMethod.allCases.map(\.rawValue)),
            ("chat_lock.unlocked", "method", SGAnalyticsUnlockMethod.allCases.map(\.rawValue)),
            ("chat_lock.lock_set", "method", SGAnalyticsLockMethod.allCases.map(\.rawValue)),
            ("edit_history.viewed", "kind", SGAnalyticsEditHistoryKind.allCases.map(\.rawValue)),
            ("pro.screen_view", "source", SGAnalyticsProSource.allCases.map(\.rawValue)),
            ("pro.screen_view", "mode", SGAnalyticsProMode.allCases.map(\.rawValue)),
            ("pro.purchase_fail", "reason", SGAnalyticsPurchaseFailReason.allCases.map(\.rawValue)),
            ("pro.restore", "outcome", SGAnalyticsRestoreOutcome.allCases.map(\.rawValue)),
            ("pro.trial_start", "outcome", SGAnalyticsTrialOutcome.allCases.map(\.rawValue)),
            ("link.attempt", "trigger", SGAnalyticsLinkTrigger.allCases.map(\.rawValue)),
            ("link.attempt", "method", SGAnalyticsLinkMethod.allCases.map(\.rawValue)),
            ("link.attempt", "outcome", SGAnalyticsLinkOutcome.allCases.map(\.rawValue)),
        ]
        var inlineInRegistry: [String] = []
        for (event, rules) in registry.events {
            for (prop, rule) in rules where rule["enum"] is [Any] {
                inlineInRegistry.append("\(event).\(prop)")
            }
        }
        XCTAssertEqual(Set(inlineInRegistry), Set(inline.map { "\($0.0).\($0.1)" }), "every inline enum of the registry has its Swift enum")
        for (event, prop, values) in inline {
            XCTAssertEqual(registry.events[event]?[prop]?["enum"] as? [String], values, "\(event).\(prop)")
        }
    }

    func testTheSchemaEqualsTheRegistryOneToOne() throws {
        let registry = try SGAnalyticsRegistry.vendored()
        XCTAssertEqual(Set(registry.events.keys), Set(SGAnalyticsSchema.events.keys))
        XCTAssertEqual(registry.events.count, 29)
        for (name, rules) in registry.events {
            let schema = try XCTUnwrap(SGAnalyticsSchema.events[name], name)
            XCTAssertEqual(Set(rules.keys), Set(schema.keys), name)
            for (prop, rule) in rules {
                let mine = try XCTUnwrap(schema[prop], "\(name).\(prop)")
                XCTAssertTrue(Set(rule.keys).isSubset(of: ["type", "enum", "required"]), "\(name).\(prop)")
                XCTAssertEqual((rule["required"] as? Bool) ?? false, mine.required, "\(name).\(prop)")
                switch mine.kind {
                case .boolean:
                    XCTAssertEqual(rule["type"] as? String, "boolean", "\(name).\(prop)")
                case let .integer(type):
                    XCTAssertEqual(rule["type"] as? String, type.rawValue, "\(name).\(prop)")
                case let .pattern(type):
                    XCTAssertEqual(rule["type"] as? String, type.rawValue, "\(name).\(prop)")
                case let .named(enumName, values):
                    XCTAssertEqual(rule["enum"] as? String, enumName, "\(name).\(prop)")
                    XCTAssertEqual(registry.enums[enumName], values, "\(name).\(prop)")
                case let .inline(values):
                    XCTAssertEqual(rule["enum"] as? [String], values, "\(name).\(prop)")
                }
            }
        }
        XCTAssertEqual(SGAnalyticsSchema.enums.count, registry.enums.count)
        for (name, values) in SGAnalyticsSchema.enums {
            XCTAssertEqual(registry.enums[name], values, name)
        }
    }

    func testThePatternChecksAgreeWithTheRegistryPatterns() throws {
        let registry = try SGAnalyticsRegistry.vendored()
        let corpus = [
            "", "a", "A", "0", "_", "-", ".", "a-b", "a_b", "a.b", "zenlygram.pro.monthly", "zenlygram_pro", "monthly-base", "Monthly",
            "-monthly", "http_404", "storekit_-1", "telegram_bot_invalid", "Connection refused", "a b", "ä", "rate_limited\n", "\nrate_limited",
            String(repeating: "a", count: 63), String(repeating: "a", count: 64), String(repeating: "a", count: 65),
            String(repeating: "B", count: 100), String(repeating: "B", count: 101), "x/y", "x+y", "1abc", "ABC.def-1_2",
        ]
        for type in SGAnalyticsPatternType.allCases {
            let pattern = try XCTUnwrap(registry.types[type.rawValue]?["pattern"] as? String)
            for text in corpus {
                XCTAssertEqual(type.accepts(text), SGAnalyticsRegistry.fullMatch(pattern, text), "\(type.rawValue): \(text.debugDescription)")
            }
        }
    }

    func testEveryEventTheAppCanBuildValidatesAgainstTheRegistry() throws {
        let registry = try SGAnalyticsRegistry.vendored()
        let payloads = SGAnalyticsTestSamples.everyEvent().map(\.payload) + SGAnalyticsTestSamples.pipelinePayloads()
        for payload in payloads {
            let props = SGAnalyticsTestSamples.decodedProps(payload)
            XCTAssertNil(registry.verdict(name: payload.name, props: props), "\(payload.name) \(props)")
            XCTAssertEqual(SGAnalyticsPayload.validated(name: payload.name, props: props), payload, payload.name)
        }
        XCTAssertEqual(Set(payloads.map(\.name)), Set(registry.events.keys), "every registry name has a builder")
    }

    func testEveryEnumValueOfEveryPropIsBuilt() throws {
        let registry = try SGAnalyticsRegistry.vendored()
        var built = Set<String>()
        for payload in SGAnalyticsTestSamples.everyEvent().map(\.payload) + SGAnalyticsTestSamples.pipelinePayloads() {
            for (prop, value) in payload.props {
                if case let .string(text) = value {
                    built.insert("\(payload.name).\(prop)=\(text)")
                }
            }
        }
        for (name, rules) in registry.events {
            for (prop, rule) in rules {
                let values: [String]
                if let enumName = rule["enum"] as? String {
                    values = registry.enums[enumName] ?? []
                } else if let list = rule["enum"] as? [String] {
                    values = list
                } else {
                    continue
                }
                for value in values {
                    XCTAssertTrue(built.contains("\(name).\(prop)=\(value)"), "no event builds \(name).\(prop) = \(value)")
                }
            }
        }
    }

    func testEveryEventStaysWithinTwoKibibytes() throws {
        let registry = try SGAnalyticsRegistry.vendored()
        let payloads = SGAnalyticsTestSamples.largestEvents().map(\.payload) + SGAnalyticsTestSamples.everyEvent().map(\.payload) + SGAnalyticsTestSamples.pipelinePayloads()
        var largest = 0
        for payload in payloads {
            let event = SGAnalyticsWireEvent(id: SGCustomerTime.uuid4(), ts: "2026-11-01T09:58:00Z", sessionId: SGCustomerTime.uuid4(), seq: SGAnalyticsTaxonomy.maxSeq, payload: payload)
            let data = event.encoded()
            largest = max(largest, data.count)
            XCTAssertLessThanOrEqual(data.count, SGAnalyticsTaxonomy.maxEventBytes, payload.name)
            XCTAssertTrue(event.isValid, payload.name)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
            XCTAssertEqual(Set(object.keys), SGAnalyticsWireEvent.keys)
            XCTAssertNil(registry.verdict(name: payload.name, props: try XCTUnwrap(object["props"] as? [String: Any])), payload.name)
            XCTAssertEqual(SGAnalyticsWireEvent.validated(object), event, payload.name)
        }
        XCTAssertGreaterThan(largest, 400, "the largest values were exercised")
    }

    func testIntegersAreClampedToTheirRegistryTypes() {
        let created = SGAnalyticsEvent.tasksTaskCreated(scope: .cloud, hasDue: false, priority: 7, inList: true).payload
        XCTAssertEqual(created.props["priority"], .integer(4))
        XCTAssertEqual(SGAnalyticsEvent.tasksTaskCreated(scope: .local, hasDue: false, priority: -3, inList: true).payload.props["priority"], .integer(0))
        XCTAssertEqual(SGAnalyticsEvent.tasksListDeleted(scope: .cloud, tasks: 1_000_000).payload.props["tasks"], .integer(100_000))
        XCTAssertEqual(SGAnalyticsEvent.tasksListDeleted(scope: .cloud, tasks: -1).payload.props["tasks"], .integer(0))
        XCTAssertEqual(SGAnalyticsEvent.linkAttempt(trigger: .auto, method: .attest, outcome: .success, errorCode: nil, durationS: 100_000).payload.props["duration_s"], .integer(86_400))
        XCTAssertEqual(SGAnalyticsPayload.errorOccurred(domain: .network, code: .timeout, count: 0).props["count"], .integer(1))
        XCTAssertEqual(SGAnalyticsPayload.tasksSyncIssue(kind: .stalled, count: 5000).props["count"], .integer(1000))
        XCTAssertEqual(SGAnalyticsPayload.sessionEnd(durationS: -5, reason: .background).props["duration_s"], .integer(0))
        let migration = SGAnalyticsEvent.tasksMigration(phase: .completed, lists: 200_000, tasks: nil, skipped: -1, durationS: nil, errorCode: nil).payload
        XCTAssertEqual(migration.props, ["phase": .string("completed"), "lists": .integer(100_000), "skipped": .integer(0)], "an absent optional prop is left out, never null")
    }

    func testValuesAreValidatedAtConstruction() {
        XCTAssertNil(SGAnalyticsProductId(""))
        XCTAssertNil(SGAnalyticsProductId(String(repeating: "a", count: 101)))
        XCTAssertNil(SGAnalyticsProductId("zenlygram pro"))
        XCTAssertEqual(SGAnalyticsProductId("zenlygram.pro.monthly")?.rawValue, "zenlygram.pro.monthly")
        XCTAssertNil(SGAnalyticsBasePlanId("Monthly"))
        XCTAssertNil(SGAnalyticsBasePlanId("-monthly"))
        XCTAssertEqual(SGAnalyticsBasePlanId("monthly-base")?.rawValue, "monthly-base")
        XCTAssertNil(SGAnalyticsErrorCode("Connection refused"))
        XCTAssertNil(SGAnalyticsErrorCode("https://zenlygram.org/v1"))
        XCTAssertNil(SGAnalyticsErrorCode(""))
        XCTAssertEqual(SGAnalyticsErrorCode("trial_used")?.rawValue, "trial_used")
        XCTAssertEqual(SGAnalyticsErrorCode.http(404).rawValue, "http_404")
        XCTAssertEqual(SGAnalyticsErrorCode.http(42), .unknown)
        XCTAssertEqual(SGAnalyticsErrorCode.http(1000), .unknown)
        XCTAssertEqual(SGAnalyticsErrorCode.backend("rate_limited").rawValue, "rate_limited")
        XCTAssertEqual(SGAnalyticsErrorCode.backend("Rate limited, try later"), .unknown)
        XCTAssertEqual(SGAnalyticsErrorCode.backend(nil), .unknown)
        XCTAssertEqual(SGAnalyticsErrorCode.storekit(2).rawValue, "storekit_2")
        XCTAssertEqual(SGAnalyticsErrorCode.storekit(-1).rawValue, "storekit_-1")
        XCTAssertEqual(SGAnalyticsErrorCode.sqlite(13).rawValue, "sqlite_13")
        XCTAssertEqual(SGAnalyticsErrorCode.telegram(rpcError: "BOT_INVALID").rawValue, "telegram_bot_invalid")
        XCTAssertEqual(SGAnalyticsErrorCode.telegram(rpcError: "FLOOD_WAIT_30").rawValue, "telegram_flood_wait_30")
        XCTAssertEqual(SGAnalyticsErrorCode.telegram(rpcError: "Phone number +998901234567 invalid"), .unknown)
        XCTAssertEqual(SGAnalyticsErrorCode.telegram(rpcError: ""), .unknown)
        XCTAssertEqual(SGAnalyticsErrorCode.telegram(rpcError: String(repeating: "A", count: 80)).rawValue.count, 64)
        for code in [SGAnalyticsErrorCode.timeout, .offline, .dns, .tls, .unknown] {
            XCTAssertNotNil(SGAnalyticsErrorCode(code.rawValue))
        }
    }

    func testAnEventCarriesNoFreeText() {
        // Every string prop of every buildable event is a registry enum value or a patterned id.
        for payload in SGAnalyticsTestSamples.everyEvent().map(\.payload) + SGAnalyticsTestSamples.pipelinePayloads() {
            let rules = SGAnalyticsSchema.events[payload.name] ?? [:]
            for (prop, value) in payload.props {
                guard case let .string(text) = value else {
                    continue
                }
                switch rules[prop]?.kind {
                case let .named(_, values)?, let .inline(values)?:
                    XCTAssertTrue(values.contains(text), "\(payload.name).\(prop)")
                case let .pattern(type)?:
                    XCTAssertTrue(type.accepts(text), "\(payload.name).\(prop)")
                default:
                    XCTFail("\(payload.name).\(prop) is a string outside the registry")
                }
            }
        }
    }
}

// MARK: - Support shared by the analytics tests

/// The vendored registry, read independently of the app's schema: what the server's EventTaxonomy
/// checks (unknown name, a prop outside an event, a value outside its rule, a missing required prop).
struct SGAnalyticsRegistry {
    let version: Int
    let types: [String: [String: Any]]
    let enums: [String: [String]]
    let events: [String: [String: [String: Any]]]

    static func vendored() throws -> SGAnalyticsRegistry {
        let object = try SGCustomerSyncTestFixtures.jsonObject("analytics-events.json")
        let events = try XCTUnwrap(object["events"] as? [String: Any])
        var parsed: [String: [String: [String: Any]]] = [:]
        for (name, value) in events {
            parsed[name] = try XCTUnwrap(value as? [String: [String: Any]], name)
        }
        return SGAnalyticsRegistry(
            version: try XCTUnwrap(SGCustomerJSON.integer(object["taxonomy_version"])),
            types: try XCTUnwrap(object["types"] as? [String: [String: Any]]),
            enums: try XCTUnwrap(object["enums"] as? [String: [String]]),
            events: parsed
        )
    }

    /// nil when the server would store the event as sent; else why not (`unknown_event`,
    /// `invalid_props`, or `undeclared_prop` — the server would drop it, the app must never send one).
    func verdict(name: String, props: [String: Any]) -> String? {
        guard let rules = self.events[name] else {
            return "unknown_event"
        }
        for (key, value) in props {
            guard let rule = rules[key] else {
                return "undeclared_prop"
            }
            guard self.accepts(rule, value) else {
                return "invalid_props"
            }
        }
        for (key, rule) in rules where (rule["required"] as? Bool) == true && props[key] == nil {
            return "invalid_props"
        }
        return nil
    }

    private func accepts(_ rule: [String: Any], _ value: Any) -> Bool {
        if let type = rule["type"] as? String {
            if type == "boolean" {
                return SGCustomerJSON.bool(value) != nil
            }
            guard let definition = self.types[type] else {
                return false
            }
            switch definition["type"] as? String {
            case "integer":
                guard let number = SGCustomerJSON.integer(value), let min = SGCustomerJSON.integer(definition["min"]), let max = SGCustomerJSON.integer(definition["max"]) else {
                    return false
                }
                return (min ... max).contains(number)
            case "string":
                guard let text = value as? String, let pattern = definition["pattern"] as? String else {
                    return false
                }
                return SGAnalyticsRegistry.fullMatch(pattern, text)
            default:
                return false
            }
        }
        guard let text = value as? String else {
            return false
        }
        if let name = rule["enum"] as? String {
            return self.enums[name]?.contains(text) ?? false
        }
        if let list = rule["enum"] as? [String] {
            return list.contains(text)
        }
        return false
    }

    /// The whole of `text` matches `pattern` (PHP's `/…/D`: `$` never before a final newline).
    static func fullMatch(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return false
        }
        return match.range == range
    }
}

/// Events the app can build: every case with every enum value, the largest values, the pipeline's
/// own events, and the typed builder of a fixture event.
enum SGAnalyticsTestSamples {
    static let product = SGAnalyticsProductId("zenlygram.pro.monthly")!
    static let basePlan = SGAnalyticsBasePlanId("monthly-base")!

    static func everyEvent() -> [SGAnalyticsEvent] {
        var events: [SGAnalyticsEvent] = []
        let code = SGAnalyticsErrorCode.http(503)
        events += SGAnalyticsScreen.allCases.map { .screenView($0) }
        for feature in SGAnalyticsFeature.allCases {
            events += [.featureToggle(feature, enabled: true), .featureToggle(feature, enabled: false), .featureUsed(feature)]
        }
        for scope in SGAnalyticsTasksScope.allCases {
            events += [
                .tasksTaskCreated(scope: scope, hasDue: true, priority: 0, inList: false),
                .tasksTaskCreated(scope: scope, hasDue: false, priority: 4, inList: true),
                .tasksTaskCompleted(scope: scope, reopened: true),
                .tasksTaskCompleted(scope: scope, reopened: false),
                .tasksTaskDeleted(scope: scope),
                .tasksListCreated(scope: scope),
                .tasksListDeleted(scope: scope, tasks: 0),
                .tasksListDeleted(scope: scope, tasks: 3),
            ]
        }
        events += SGAnalyticsTasksSharedAction.allCases.map { .tasksShared(action: $0) }
        for phase in SGAnalyticsTasksMigrationPhase.allCases {
            events += [
                .tasksMigration(phase: phase, lists: nil, tasks: nil, skipped: nil, durationS: nil, errorCode: nil),
                .tasksMigration(phase: phase, lists: 2, tasks: 14, skipped: 0, durationS: 6, errorCode: code),
            ]
        }
        for method in SGAnalyticsUnlockMethod.allCases {
            events += [.vaultUnlocked(method: method), .chatLockUnlocked(method: method)]
        }
        events += [.vaultChatAdded, .vaultChatRemoved, .chatLockLockRemoved]
        for method in SGAnalyticsLockMethod.allCases {
            events += [.chatLockLockSet(method: method, biometric: true), .chatLockLockSet(method: method, biometric: false)]
        }
        events += SGAnalyticsEditHistoryKind.allCases.map { .editHistoryViewed(kind: $0) }
        for source in SGAnalyticsProSource.allCases {
            events += SGAnalyticsProMode.allCases.map { .proScreenView(source: source, mode: $0) }
        }
        for rail in SGAnalyticsRail.allCases {
            for plan in [nil, SGAnalyticsTestSamples.basePlan] {
                events += [
                    .proPlanSelect(productId: SGAnalyticsTestSamples.product, rail: rail, basePlanId: plan),
                    .proPurchaseStart(productId: SGAnalyticsTestSamples.product, rail: rail, basePlanId: plan),
                    .proPurchaseSuccess(productId: SGAnalyticsTestSamples.product, rail: rail, basePlanId: plan, trial: true),
                    .proPurchaseSuccess(productId: SGAnalyticsTestSamples.product, rail: rail, basePlanId: plan, trial: false),
                ]
                for reason in SGAnalyticsPurchaseFailReason.allCases {
                    events += [
                        .proPurchaseFail(productId: SGAnalyticsTestSamples.product, rail: rail, basePlanId: plan, reason: reason, errorCode: nil),
                        .proPurchaseFail(productId: SGAnalyticsTestSamples.product, rail: rail, basePlanId: plan, reason: reason, errorCode: .storekit(2)),
                    ]
                }
            }
            for outcome in SGAnalyticsRestoreOutcome.allCases {
                events += [.proRestore(rail: rail, outcome: outcome, errorCode: nil), .proRestore(rail: rail, outcome: outcome, errorCode: code)]
            }
        }
        for outcome in SGAnalyticsTrialOutcome.allCases {
            events += [.proTrialStart(outcome: outcome, errorCode: nil), .proTrialStart(outcome: outcome, errorCode: SGAnalyticsErrorCode("trial_used"))]
        }
        for trigger in SGAnalyticsLinkTrigger.allCases {
            for method in SGAnalyticsLinkMethod.allCases {
                for outcome in SGAnalyticsLinkOutcome.allCases {
                    events += [
                        .linkAttempt(trigger: trigger, method: method, outcome: outcome, errorCode: nil, durationS: nil),
                        .linkAttempt(trigger: trigger, method: method, outcome: outcome, errorCode: .backend("attest_unavailable"), durationS: 4),
                    ]
                }
            }
        }
        return events
    }

    /// The longest values every patterned or integer prop allows.
    static func largestEvents() -> [SGAnalyticsEvent] {
        let product = SGAnalyticsProductId(String(repeating: "P", count: 100))!
        let plan = SGAnalyticsBasePlanId("p" + String(repeating: "-", count: 62))!
        let code = SGAnalyticsErrorCode("e" + String(repeating: "_", count: 63))!
        return [
            .proPurchaseFail(productId: product, rail: .google, basePlanId: plan, reason: .notAllowed, errorCode: code),
            .proPurchaseSuccess(productId: product, rail: .google, basePlanId: plan, trial: true),
            .proRestore(rail: .apple, outcome: .restored, errorCode: code),
            .proTrialStart(outcome: .refused, errorCode: code),
            .tasksMigration(phase: .completed, lists: 100_000, tasks: 100_000, skipped: 100_000, durationS: 86_400, errorCode: code),
            .linkAttempt(trigger: .manual, method: .attest, outcome: .success, errorCode: code, durationS: 86_400),
            .screenView(.tasksUnsentChanges),
            .featureToggle(.roundVideoFromGallery, enabled: false),
        ]
    }

    static func pipelinePayloads() -> [SGAnalyticsPayload] {
        var payloads = SGAnalyticsSessionTrigger.allCases.map { SGAnalyticsPayload.sessionStart($0) }
        payloads += SGAnalyticsSessionEndReason.allCases.map { SGAnalyticsPayload.sessionEnd(durationS: 840, reason: $0) }
        payloads += SGAnalyticsErrorDomain.allCases.map { SGAnalyticsPayload.errorOccurred(domain: $0, code: .timeout, count: 3) }
        payloads.append(SGAnalyticsPayload.errorOccurred(domain: .other, code: SGAnalyticsErrorCode("e" + String(repeating: "_", count: 63))!, count: 1000))
        payloads += SGAnalyticsTasksSyncIssueKind.allCases.map { SGAnalyticsPayload.tasksSyncIssue(kind: $0, count: 1) }
        return payloads
    }

    /// `payload.props` as decoded JSON.
    static func decodedProps(_ payload: SGAnalyticsPayload) -> [String: Any] {
        let data = Data(payload.propsJSON.utf8)
        return ((try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]) ?? [:]
    }

    /// The builder's payload for a fixture event: the typed constructors fed with the fixture's
    /// values (nil when no constructor takes them).
    static func typedPayload(name: String, props: [String: Any]) -> SGAnalyticsPayload? {
        func string(_ key: String) -> String? {
            return props[key] as? String
        }
        func int(_ key: String) -> Int? {
            return SGCustomerJSON.integer(props[key])
        }
        func bool(_ key: String) -> Bool? {
            return SGCustomerJSON.bool(props[key])
        }
        func code(_ key: String) -> SGAnalyticsErrorCode? {
            return string(key).flatMap(SGAnalyticsErrorCode.init)
        }
        func scope() -> SGAnalyticsTasksScope? {
            return string("scope").flatMap(SGAnalyticsTasksScope.init(rawValue:))
        }
        func purchase() -> (SGAnalyticsProductId, SGAnalyticsRail, SGAnalyticsBasePlanId?)? {
            guard let product = string("product_id").flatMap(SGAnalyticsProductId.init), let rail = string("rail").flatMap(SGAnalyticsRail.init(rawValue:)) else {
                return nil
            }
            return (product, rail, string("base_plan_id").flatMap(SGAnalyticsBasePlanId.init))
        }
        let event: SGAnalyticsEvent?
        switch name {
        case "app.session_start":
            return string("trigger").flatMap(SGAnalyticsSessionTrigger.init(rawValue:)).map { SGAnalyticsPayload.sessionStart($0) }
        case "app.session_end":
            guard let duration = int("duration_s"), let reason = string("reason").flatMap(SGAnalyticsSessionEndReason.init(rawValue:)) else {
                return nil
            }
            return SGAnalyticsPayload.sessionEnd(durationS: duration, reason: reason)
        case "error.occurred":
            guard let domain = string("domain").flatMap(SGAnalyticsErrorDomain.init(rawValue:)), let code = code("code"), let count = int("count") else {
                return nil
            }
            return SGAnalyticsPayload.errorOccurred(domain: domain, code: code, count: count)
        case "tasks.sync_issue":
            guard let kind = string("kind").flatMap(SGAnalyticsTasksSyncIssueKind.init(rawValue:)), let count = int("count") else {
                return nil
            }
            return SGAnalyticsPayload.tasksSyncIssue(kind: kind, count: count)
        case "screen.view":
            event = string("screen").flatMap(SGAnalyticsScreen.init(rawValue:)).map { .screenView($0) }
        case "feature.toggle":
            event = string("feature").flatMap(SGAnalyticsFeature.init(rawValue:)).flatMap { feature in bool("enabled").map { .featureToggle(feature, enabled: $0) } }
        case "feature.used":
            event = string("feature").flatMap(SGAnalyticsFeature.init(rawValue:)).map { .featureUsed($0) }
        case "tasks.task_created":
            guard let scope = scope(), let hasDue = bool("has_due"), let priority = int("priority"), let inList = bool("in_list") else {
                return nil
            }
            event = .tasksTaskCreated(scope: scope, hasDue: hasDue, priority: priority, inList: inList)
        case "tasks.task_completed":
            event = scope().flatMap { scope in bool("reopened").map { .tasksTaskCompleted(scope: scope, reopened: $0) } }
        case "tasks.task_deleted":
            event = scope().map { .tasksTaskDeleted(scope: $0) }
        case "tasks.list_created":
            event = scope().map { .tasksListCreated(scope: $0) }
        case "tasks.list_deleted":
            event = scope().flatMap { scope in int("tasks").map { .tasksListDeleted(scope: scope, tasks: $0) } }
        case "tasks.shared":
            event = string("action").flatMap(SGAnalyticsTasksSharedAction.init(rawValue:)).map { .tasksShared(action: $0) }
        case "tasks.migration":
            event = string("phase").flatMap(SGAnalyticsTasksMigrationPhase.init(rawValue:)).map {
                .tasksMigration(phase: $0, lists: int("lists"), tasks: int("tasks"), skipped: int("skipped"), durationS: int("duration_s"), errorCode: code("error_code"))
            }
        case "vault.unlocked":
            event = string("method").flatMap(SGAnalyticsUnlockMethod.init(rawValue:)).map { .vaultUnlocked(method: $0) }
        case "vault.chat_added":
            event = .vaultChatAdded
        case "vault.chat_removed":
            event = .vaultChatRemoved
        case "chat_lock.lock_set":
            event = string("method").flatMap(SGAnalyticsLockMethod.init(rawValue:)).flatMap { method in bool("biometric").map { .chatLockLockSet(method: method, biometric: $0) } }
        case "chat_lock.unlocked":
            event = string("method").flatMap(SGAnalyticsUnlockMethod.init(rawValue:)).map { .chatLockUnlocked(method: $0) }
        case "chat_lock.lock_removed":
            event = .chatLockLockRemoved
        case "edit_history.viewed":
            event = string("kind").flatMap(SGAnalyticsEditHistoryKind.init(rawValue:)).map { .editHistoryViewed(kind: $0) }
        case "pro.screen_view":
            guard let source = string("source").flatMap(SGAnalyticsProSource.init(rawValue:)), let mode = string("mode").flatMap(SGAnalyticsProMode.init(rawValue:)) else {
                return nil
            }
            event = .proScreenView(source: source, mode: mode)
        case "pro.plan_select":
            event = purchase().map { .proPlanSelect(productId: $0.0, rail: $0.1, basePlanId: $0.2) }
        case "pro.purchase_start":
            event = purchase().map { .proPurchaseStart(productId: $0.0, rail: $0.1, basePlanId: $0.2) }
        case "pro.purchase_success":
            event = purchase().flatMap { purchase in bool("trial").map { .proPurchaseSuccess(productId: purchase.0, rail: purchase.1, basePlanId: purchase.2, trial: $0) } }
        case "pro.purchase_fail":
            event = purchase().flatMap { purchase in
                string("reason").flatMap(SGAnalyticsPurchaseFailReason.init(rawValue:)).map {
                    .proPurchaseFail(productId: purchase.0, rail: purchase.1, basePlanId: purchase.2, reason: $0, errorCode: code("error_code"))
                }
            }
        case "pro.restore":
            guard let rail = string("rail").flatMap(SGAnalyticsRail.init(rawValue:)), let outcome = string("outcome").flatMap(SGAnalyticsRestoreOutcome.init(rawValue:)) else {
                return nil
            }
            event = .proRestore(rail: rail, outcome: outcome, errorCode: code("error_code"))
        case "pro.trial_start":
            event = string("outcome").flatMap(SGAnalyticsTrialOutcome.init(rawValue:)).map { .proTrialStart(outcome: $0, errorCode: code("error_code")) }
        case "link.attempt":
            guard let trigger = string("trigger").flatMap(SGAnalyticsLinkTrigger.init(rawValue:)), let method = string("method").flatMap(SGAnalyticsLinkMethod.init(rawValue:)),
                  let outcome = string("outcome").flatMap(SGAnalyticsLinkOutcome.init(rawValue:)) else {
                return nil
            }
            event = .linkAttempt(trigger: trigger, method: method, outcome: outcome, errorCode: code("error_code"), durationS: int("duration_s"))
        default:
            return nil
        }
        return event?.payload
    }

    /// The iPhone context of the shared events fixtures (`events-valid.json`).
    static var iPhoneFacts: SGCustomerDeviceFacts {
        return SGCustomerDeviceFacts(deviceClass: .phone, deviceModel: "iPhone17,1", osVersion: "18.1", appVersion: "12.0.1", appBuild: "1234", uiLanguage: "uz", locale: "uz_UZ", timezone: "Asia/Tashkent", distribution: .appstore)
    }

    /// A deterministic uuid4 generator (`00000000-0000-4000-8000-<n>`).
    final class Ids {
        private var next = 0
        private let lock = NSLock()

        func make() -> String {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            self.next += 1
            return String(format: "00000000-0000-4000-8000-%012x", self.next)
        }
    }
}
