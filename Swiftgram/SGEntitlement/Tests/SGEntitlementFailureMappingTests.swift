import XCTest
@testable import SGEntitlement

/// The mapping in `SGEntitlementFailureMapping` is the most dangerous code in the module: one wrong
/// row either locks a paying user out of their own chats or hands a lapsed one a free ride. These
/// tests walk every case of every enum.
final class SGEntitlementFailureMappingTests: XCTestCase {
    private var allFailures: [SGEntitlementFailureClass] {
        var result: [SGEntitlementFailureClass] = []
        result += SGEntitlementOfflineCause.allCases.map { .offline($0) }
        result += SGEntitlementSessionFailure.allCases.map { .session($0) }
        result += SGEntitlementRefusalCode.allCases.map { .refused($0) }
        result.append(.rateLimited(retryAfter: 42))
        result.append(.unknownRefusal(code: "something_new", status: 418))
        return result
    }

    func test_noTransportOutcomeEverTouchesTheCachedEntitlement() {
        // The type cannot express "clear the token" — this asserts the property the type gives us,
        // so that adding such a case would fail here and not silently in production.
        for failure in self.allFailures {
            let recovery = SGEntitlementFailureMapping.recovery(for: failure)
            switch recovery.consequence {
            case .keepEverything:
                continue
            case let .dropSession(drop):
                XCTAssertTrue(
                    drop.isSubset(of: [.refreshToken, .enclaveKey]),
                    "\(failure) tried to drop something that is not session material"
                )
            }
        }
    }

    func test_everyOfflineCauseIncludingFiveHundredKeepsEverythingAndStaysSilent() {
        for cause in SGEntitlementOfflineCause.allCases {
            let recovery = SGEntitlementFailureMapping.recovery(for: .offline(cause))
            XCTAssertEqual(recovery.consequence, .keepEverything, "\(cause) must be 'offline', never 'unsubscribed'")
            XCTAssertNil(recovery.message, "\(cause) must be silent")
        }
    }

    func test_fiveHundredIsClassifiedAsOffline() {
        XCTAssertEqual(SGEntitlementFailureMapping.classify(status: 500, code: "server_error", retryAfter: nil), .offline(.serverError))
        XCTAssertEqual(SGEntitlementFailureMapping.classify(status: 502, code: nil, retryAfter: nil), .offline(.serverError))
    }

    func test_everyTimeoutAndTransportErrorIsOffline() {
        let codes: [URLError.Code] = [.timedOut, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost, .cancelled, .badServerResponse]
        for code in codes {
            guard case .offline = SGEntitlementFailureMapping.classify(urlErrorCode: code) else {
                XCTFail("\(code) must classify as offline")
                continue
            }
        }
    }

    func test_theStableCodeDecidesBeforeTheStatus() {
        // `apple_jws_invalid` is a 401 that has nothing to do with the device session: mapping it
        // into the 401 family would drop a refresh token over Apple's chain check.
        XCTAssertEqual(SGEntitlementFailureMapping.classify(status: 401, code: "apple_jws_invalid", retryAfter: nil), .refused(.appleJwsInvalid))
        XCTAssertEqual(SGEntitlementFailureMapping.classify(status: 401, code: "refresh_reuse", retryAfter: nil), .session(.refreshReuse))
        // ... and in the other direction: a 503 that names an operator switch is not an outage.
        XCTAssertEqual(SGEntitlementFailureMapping.classify(status: 503, code: "bind_paused", retryAfter: nil), .refused(.bindPaused))
        XCTAssertEqual(SGEntitlementFailureMapping.classify(status: 503, code: nil, retryAfter: nil), .offline(.serverError))
    }

    func test_theSessionLossFamilyDropsOnlyTheRefreshToken() {
        for failure in [SGEntitlementSessionFailure.invalidToken, .expiredToken, .sessionRevoked, .deviceRevoked, .refreshReuse] {
            let recovery = SGEntitlementFailureMapping.recovery(for: .session(failure))
            XCTAssertEqual(recovery.consequence, .dropSession(.refreshToken), "\(failure)")
            XCTAssertEqual(recovery.retry, .stop, "\(failure) must never loop")
        }
    }

    func test_deviceKeyMismatchAlsoRegeneratesTheEnclaveKey() {
        let recovery = SGEntitlementFailureMapping.recovery(for: .session(.deviceKeyMismatch))
        XCTAssertEqual(recovery.consequence, .dropSession([.refreshToken, .enclaveKey]))
    }

    func test_clockSkewIsRecoverableWithoutUserAction() {
        let recovery = SGEntitlementFailureMapping.recovery(for: .session(.clockSkew))
        XCTAssertEqual(recovery.consequence, .keepEverything)
        XCTAssertEqual(recovery.retry, .resignWithServerTimeOnce)
        XCTAssertEqual(recovery.message, .checkDateAndTime)
    }

    func test_nonceReplayIsSilentAndRetriedOnceWithFreshCredentials() {
        let recovery = SGEntitlementFailureMapping.recovery(for: .session(.nonceReplayed))
        XCTAssertEqual(recovery.retry, .retryOnceWithFreshCredentials)
        XCTAssertNil(recovery.message)
    }

    func test_rateLimitingHonoursRetryAfterAndChangesNothing() {
        let recovery = SGEntitlementFailureMapping.recovery(for: .rateLimited(retryAfter: 90))
        XCTAssertEqual(recovery.consequence, .keepEverything)
        XCTAssertEqual(recovery.retry, .backoff(after: 90))
    }

    func test_bindPausedNeverMentionsBillingAndIsNotALapse() {
        let recovery = SGEntitlementFailureMapping.recovery(for: .refused(.bindPaused))
        XCTAssertEqual(recovery.consequence, .keepEverything)
        XCTAssertEqual(recovery.message, .linkingUnavailable)
    }

    func test_appleConflictsStopRetryingAndAskForHelp() {
        for code in [SGEntitlementRefusalCode.appleEnvironmentMismatch, .appleSubscriptionConflict, .appleJwsInvalid, .appleFamilyShared] {
            let recovery = SGEntitlementFailureMapping.recovery(for: .refused(code))
            XCTAssertEqual(recovery.retry, .stop, "\(code) must not loop")
            XCTAssertEqual(recovery.message, .purchaseNeedsHelp)
            XCTAssertEqual(recovery.consequence, .keepEverything)
        }
    }

    func test_aFamilySharingCopyIsAKnownRefusalNotAnUnknownOne() {
        // The server answers 409 `apple_family_shared` for a FAMILY_SHARED transaction while shared
        // subscriptions are switched off. A build that did not know the code classified it as
        // `.unknownRefusal`; now it is a named refusal with the same stop-and-ask-for-help recovery.
        let failure = SGEntitlementFailureMapping.classify(status: 409, code: "apple_family_shared", retryAfter: nil)
        XCTAssertEqual(failure, .refused(.appleFamilyShared))
        XCTAssertEqual(SGEntitlementRefusalCode.appleFamilyShared.rawValue, "apple_family_shared")
    }

    func test_onlyTheTwoTransientRefusalsAreRetried_everyOtherRefusalStops() {
        // The attach outbox derives "stuck" from this table: a refusal the server would only repeat
        // is not helped by one more attempt. Only the two genuinely transient answers back off.
        let transient: Set<SGEntitlementRefusalCode> = [.appleTemporarilyUnavailable, .idempotencyInFlight]
        for code in SGEntitlementRefusalCode.allCases {
            let retry = SGEntitlementFailureMapping.recovery(for: .refused(code)).retry
            if transient.contains(code) {
                guard case .backoff = retry else {
                    return XCTFail("\(code) is transient and must back off, got \(retry)")
                }
            } else {
                XCTAssertEqual(retry, .stop, "\(code) must stop, not loop")
            }
        }
        XCTAssertEqual(SGEntitlementFailureMapping.recovery(for: .unknownRefusal(code: "invented_tomorrow", status: 409)).retry, .stop)
    }

    func test_everyTrialRefusalHasItsOwnMessageSoItIsNeverADeadEnd() {
        let expected: [SGEntitlementRefusalCode: SGEntitlementMessage] = [
            .trialAlreadyUsed: .trialAlreadyUsed,
            .trialDeviceCap: .trialDeviceCap,
            .trialDeviceBlocked: .trialDeviceBlocked,
            .trialPaused: .trialUnavailable,
            .trialDisabled: .trialNotOffered
        ]
        for (code, message) in expected {
            XCTAssertEqual(SGEntitlementFailureMapping.recovery(for: .refused(code)).message, message)
        }
    }

    func test_aDisabledTrialIsAKnownRefusalWithItsOwnCopyAndNothingToRetry() {
        // The server answers 409 `trial_disabled` while the policy is paid but the operator has not
        // enabled the server's trial. Not an outage ("temporarily unavailable"), not a consumed
        // ledger: its own copy, nothing dropped, nothing retried.
        XCTAssertEqual(SGEntitlementRefusalCode.trialDisabled.rawValue, "trial_disabled")
        XCTAssertEqual(SGEntitlementFailureMapping.classify(status: 409, code: "trial_disabled", retryAfter: nil), .refused(.trialDisabled))
        let recovery = SGEntitlementFailureMapping.recovery(for: .refused(.trialDisabled))
        XCTAssertEqual(recovery.consequence, .keepEverything)
        XCTAssertEqual(recovery.retry, .stop)
        XCTAssertEqual(recovery.message, .trialNotOffered)
        XCTAssertNotEqual(recovery.message, .trialUnavailable, "not the outage copy")
        XCTAssertEqual(SGEntitlementMessage.trialNotOffered.localizationKey, "Entitlement.Message.TrialNotOffered")
    }

    func test_anUnknownStableCodeIsTreatedLikeAnyOtherRefusal() {
        let recovery = SGEntitlementFailureMapping.recovery(for: .unknownRefusal(code: "invented_tomorrow", status: 422))
        XCTAssertEqual(recovery.consequence, .keepEverything)
    }
}
