import XCTest
@testable import SGEntitlement

final class SGEntitlementCapabilityTests: XCTestCase {
    func test_everyGatedActionIsACreate_andNoneOfThemIsARead() {
        // If a read, an un-hide, an unlock or a delete ever appears in this enum, a lapsed user is
        // locked out of their own chats. The names are the guard rail; this test is the alarm.
        // (`createRetainedHistoryRecord` gates only NEW history capture; retained history is read
        // and removed with no gate at all, in every mode.)
        let allowedPrefixes = ["create", "use"]
        for action in SGEntitlementGatedAction.allCases {
            XCTAssertTrue(
                allowedPrefixes.contains(where: { action.rawValue.hasPrefix($0) }),
                "\(action.rawValue) does not read as a create — a gate on anything else breaks the lapse policy"
            )
        }
    }

    func test_everyGatedActionMapsToACapability() {
        XCTAssertEqual(SGEntitlementGatedAction.createVaultEntry.capability, .vault)
        XCTAssertEqual(SGEntitlementGatedAction.createChatLockPincode.capability, .chatLock)
        XCTAssertEqual(SGEntitlementGatedAction.createTask.capability, .tasks)
        XCTAssertEqual(SGEntitlementGatedAction.useAIAssistant.capability, .ai)
        XCTAssertEqual(SGEntitlementGatedAction.createRetainedHistoryRecord.capability, .editHistory)
        XCTAssertEqual(Set(SGEntitlementGatedAction.allCases.map { $0.capability }).count, SGEntitlementGatedAction.allCases.count)
    }

    func test_everyUnrestrictedActionIsAllowedInEveryState() {
        for action in SGEntitlementUnrestrictedAction.allCases {
            XCTAssertTrue(SGEntitlement.can(action), "\(action.rawValue) must work offline, forever, with no token")
        }
    }

    func test_theCapabilityStringsAreTheOnesTheServerEmits() {
        XCTAssertEqual(SGEntitlementCapability.vault.rawValue, "vault")
        XCTAssertEqual(SGEntitlementCapability.chatLock.rawValue, "chatlock")
        XCTAssertEqual(SGEntitlementCapability.tasks.rawValue, "tasks")
        XCTAssertEqual(SGEntitlementCapability.editHistory.rawValue, "edithistory")
        XCTAssertEqual(SGEntitlementCapability.ai.rawValue, "ai")
        XCTAssertEqual(SGEntitlementCapability.wildcard, "*")
        XCTAssertFalse(SGEntitlementCapability.base.contains(.ai), "the StoreKit fallback and the local grace must not grant AI")
        XCTAssertTrue(SGEntitlementCapability.editHistory.isDeviceGlobal, "new-capture follows the same install-wide union as tasks and chat lock: one replay flag per install")
    }

    func test_stateHas_honoursTheWildcardAndIgnoresUnknownStrings() {
        // The wildcard restores ACCESS; it does not switch on a new data flow. `.ai` is refused by
        // this build (SGEntitlementCapability.refusedByThisBuild) because turning the assistant on
        // would send message text to a third party, which the shipped privacy disclosure says the
        // app does not do.
        XCTAssertFalse(SGEntitlementState.unlocked(capabilities: ["*"]).has(.ai))
        XCTAssertTrue(SGEntitlementState.unlocked(capabilities: ["*"]).has(.tasks))
        XCTAssertTrue(SGEntitlementState.unlocked(capabilities: ["vault", "something_from_2030"]).has(.vault))
        XCTAssertFalse(SGEntitlementState.unlocked(capabilities: ["something_from_2030"]).has(.vault))
        XCTAssertFalse(SGEntitlementState.degraded(reason: .lapsed).has(.vault))
    }

    func test_everyDegradedReasonHasAMessageKey() {
        for reason in SGEntitlementDegradedReason.allCases {
            XCTAssertFalse(SGEntitlementMessage.forDegraded(reason).localizationKey.isEmpty)
        }
        XCTAssertEqual(SGEntitlementMessage.forDegraded(.lapsed), .subscriptionEnded)
        XCTAssertEqual(SGEntitlementMessage.forDegraded(.stale), .reconnectToRestore, "'reconnect to restore Pro', never 'your subscription ended'")
        XCTAssertEqual(SGEntitlementMessage.forDegraded(.noToken), .notLinked)
    }
}

extension SGEntitlementCapabilityTests {
    func test_gateResultDistinguishesAPaywallFromAFeatureTheServerHasNotEnabled() {
        // Unlocked without "ai": the subscription is live, so a paywall would sell something that
        // does not change the answer.
        XCTAssertEqual(SGEntitlementGateResult.unavailable.isAllowed, false)
        XCTAssertEqual(SGEntitlementGateResult.blocked(reason: .lapsed).isAllowed, false)
        XCTAssertEqual(SGEntitlementGateResult.allowed.isAllowed, true)
    }
}
