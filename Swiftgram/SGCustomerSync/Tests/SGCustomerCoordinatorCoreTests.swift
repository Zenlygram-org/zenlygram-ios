import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the coordinator reducer (design 40 §6.6): the withdraw effect order, the deletion erase
/// list, sessions on an account switch, the automatic-link triggers (one on the install), first-idle
/// gating, the link-ended normalisation, one request per (account, route) in flight, the logout purge
/// and the launch reconciliation — all from persisted inputs, nothing while unreadable.
final class SGCustomerCoordinatorCoreTests: XCTestCase {
    private typealias Core = SGCustomerCoordinatorCore

    private let alice = SGCustomerCoordinatorCore.SignedIn(accountPeerId: 7_000_555_000_111, tg: 555_000_111)
    private let bob = SGCustomerCoordinatorCore.SignedIn(accountPeerId: 7_000_555_000_222, tg: 555_000_222)
    private let carol: Int64 = 555_000_333
    /// 2026-11-01T10:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_793_527_200)
    private let deleteKey = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    private let withdrawId = "9b2d4f6a-8c0e-4a1b-b3d5-e7f9a1c3e5d7"
    private let full: SGCustomerDataGate.Clearance = [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync]

    // MARK: - Withdrawal (§6.6, §11.2)

    func testAWithdrawalRunsGateQueueReceiptTasksThenTheSend() throws {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        XCTAssertEqual(driver.state.publishedClearance(accountPeerId: self.alice.accountPeerId), self.full)
        self.withdraw(self.alice, in: driver)
        let effects = driver.send(.userWithdrew(account: self.alice.accountPeerId))
        XCTAssertEqual(effects, [
            .publishClearance(account: self.alice.accountPeerId, []),
            .purgeQueue(tg: self.alice.tg),
            .clearReceipt(account: self.alice.accountPeerId),
            .tasksRetire(account: self.alice.accountPeerId),
            .call(account: self.alice.accountPeerId, .consents(try self.body(self.withdrawal(self.alice))), budgeted: false),
        ], "gate → queue purge → receipt clear → Tasks retire → send; no session end (the queue is gone)")
        XCTAssertTrue(driver.state.isInFlight(.consents, accountPeerId: self.alice.accountPeerId))
        XCTAssertNil(driver.state.sessionAccount)
    }

    func testTheStoreNotificationAndTheUserEventRunTheWithdrawalOnce() throws {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        self.withdraw(self.alice, in: driver)
        // SGConsentStore.didChangeNotification may arrive first.
        XCTAssertEqual(driver.send(.consentChanged(tg: self.alice.tg)), [
            .publishClearance(account: self.alice.accountPeerId, []),
            .purgeQueue(tg: self.alice.tg),
            .clearReceipt(account: self.alice.accountPeerId),
            .tasksRetire(account: self.alice.accountPeerId),
            .call(account: self.alice.accountPeerId, .consents(try self.body(self.withdrawal(self.alice))), budgeted: false),
        ])
        XCTAssertEqual(driver.send(.userWithdrew(account: self.alice.accountPeerId)), [], "already running: no second sequence, no second send")
        XCTAssertEqual(driver.send(.consentChanged(tg: self.alice.tg)), [])
    }

    func testAWithdrawalGoesBeforeFirstIdleAndWithoutABindingOnlyLocally() throws {
        let early = self.driver([self.alice: self.linked(self.alice)], primary: self.alice, firstIdle: false)
        self.withdraw(self.alice, in: early)
        XCTAssertEqual(early.send(.userWithdrew(account: self.alice.accountPeerId)).last, .call(account: self.alice.accountPeerId, .consents(try self.body(self.withdrawal(self.alice))), budgeted: false), "user-initiated: no first idle")

        let unlinked = self.driver([self.alice: self.unlinked(self.alice)], primary: self.alice)
        self.withdraw(self.alice, in: unlinked)
        XCTAssertEqual(unlinked.send(.userWithdrew(account: self.alice.accountPeerId)), [
            .publishClearance(account: self.alice.accountPeerId, []),
            .purgeQueue(tg: self.alice.tg),
            .clearReceipt(account: self.alice.accountPeerId),
            .tasksRetire(account: self.alice.accountPeerId),
        ], "no binding: delivered after the next link or by the logout's final send")
    }

    func testAWithdrawalOnRecordAtLaunchIsNotRunAgain() {
        let driver = self.driver([self.alice: self.withdrawn(self.alice)], primary: self.alice)
        XCTAssertEqual(driver.send(.consentChanged(tg: self.alice.tg)).filter(\.isWithdrawalStep), [], "followed once, when the account was first read")
    }

    /// The process that withdrew may have died between the record and its effects (C§6.7): leftover
    /// events and unsent Tasks edits would then go out after a re-grant. The first read of the
    /// account runs the idempotent local steps again, in the withdrawal's order — never its send.
    func testAWithdrawalOnRecordAtLaunchRunsItsLocalStepsAgainButNotItsSend() throws {
        func localSteps(_ account: Core.SignedIn) -> [Core.Effect] {
            return [
                .publishClearance(account: account.accountPeerId, []),
                .purgeQueue(tg: account.tg),
                .clearReceipt(account: account.accountPeerId),
                .tasksRetire(account: account.accountPeerId),
            ]
        }
        let delivered = self.driver([self.alice: self.withdrawn(self.alice)], primary: self.alice, firstIdle: false, initialEffects: { effects in
            XCTAssertEqual(effects, localSteps(self.alice), "an acked withdrawal: the local steps, no send")
        })
        XCTAssertEqual(delivered.send(.firstIdle), [], "never sent again")
        XCTAssertEqual(delivered.send(.consentChanged(tg: self.alice.tg)), [], "once per process")

        // Not delivered yet: the planner sends it after first idle, once — no user-initiated send at launch.
        var pending = self.withdrawn(self.bob)
        pending.pendingUploads = [self.withdrawal(self.bob)]
        let undelivered = self.driver([self.bob: pending], primary: self.bob, firstIdle: false, initialEffects: { effects in
            XCTAssertEqual(effects, localSteps(self.bob))
        })
        XCTAssertEqual(undelivered.send(.firstIdle), [.call(account: self.bob.accountPeerId, .consents(try self.body(self.withdrawal(self.bob))), budgeted: true)])
        XCTAssertEqual(undelivered.send(.foreground), [], "one in flight")

        // Withdrawn on another device (`withdrawnRemotely` ran its steps in the earlier process): the same steps.
        var remote = self.withdrawn(self.alice)
        remote.record?.state = .withdrawnRemote
        _ = self.driver([self.alice: remote], primary: self.alice, firstIdle: false, initialEffects: { effects in
            XCTAssertEqual(effects, localSteps(self.alice))
        })

        // A grant on record: none of them.
        _ = self.driver([self.alice: self.linked(self.alice)], primary: self.alice, firstIdle: false, initialEffects: { effects in
            XCTAssertEqual(effects.filter(\.isWithdrawalStep), [])
            XCTAssertTrue(effects.contains(.publishClearance(account: self.alice.accountPeerId, self.full)))
        })
    }

    func testAFailedWithdrawSendIsRetriedOnTheBackoffAndAnAckEndsIt() throws {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        self.withdraw(self.alice, in: driver)
        driver.send(.userWithdrew(account: self.alice.accountPeerId))
        // Offline: the coordinator keeps retrying on the consents backoff (30 s full jitter).
        XCTAssertEqual(driver.send(.outcome(.consents, account: self.alice.accountPeerId, .unavailable(retryAfter: nil))), [
            .scheduleTimer(account: self.alice.accountPeerId, .route(.consents), at: self.now.addingTimeInterval(15)),
        ])
        driver.now = self.now.addingTimeInterval(15)
        XCTAssertEqual(driver.send(.timer(account: self.alice.accountPeerId, .route(.consents))), [
            .call(account: self.alice.accountPeerId, .consents(try self.body(self.withdrawal(self.alice))), budgeted: true),
        ])
        let acked = Data("{\"schema_version\":1,\"results\":[{\"consent_id\":\"\(self.withdrawId)\",\"outcome\":\"recorded\"}],\"consent\":{\"state\":\"withdrawn\",\"consent_id\":\"\(self.withdrawId)\",\"effective_at\":\"2026-11-01T10:00:00Z\"}}".utf8)
        XCTAssertEqual(driver.send(.outcome(.consents, account: self.alice.accountPeerId, .ok(acked))), [.markAcked(tg: self.alice.tg, consentIds: [self.withdrawId])])
    }

    func testASyncAnsweredAfterTheWithdrawalRecordsNoReceiptSoARegrantSyncsFirst() throws {
        let stored = Data("{\"schema_version\":1,\"ingest\":\"stored\"}".utf8)
        var due = self.linked(self.alice)
        due.syncDueAt = self.now
        let driver = self.driver([self.alice: due], primary: self.alice, firstIdle: false)
        XCTAssertEqual(driver.send(.firstIdle), [.call(account: self.alice.accountPeerId, .sync, budgeted: true)])
        // The user withdraws while the sync is in flight: the withdraw waits behind it on the account's gate.
        self.withdraw(self.alice, in: driver)
        let withdrew = driver.send(.userWithdrew(account: self.alice.accountPeerId))
        XCTAssertTrue(withdrew.contains(.clearReceipt(account: self.alice.accountPeerId)))
        driver.persist(withdrew)
        // The server took the sync first (200), then the withdraw, which deletes that profile (C§9.3).
        let late = driver.send(.outcome(.sync, account: self.alice.accountPeerId, .ok(stored)))
        XCTAssertEqual(late, [], "superseded by the withdrawal: no receipt")
        XCTAssertFalse(driver.state.isInFlight(.sync, accountPeerId: self.alice.accountPeerId))
        driver.persist(late)
        let withdrawAck = Data("{\"schema_version\":1,\"results\":[{\"consent_id\":\"\(self.withdrawId)\",\"outcome\":\"recorded\"}],\"consent\":{\"state\":\"withdrawn\",\"consent_id\":\"\(self.withdrawId)\",\"effective_at\":\"2026-11-01T10:00:00Z\"}}".utf8)
        driver.persist(driver.send(.outcome(.consents, account: self.alice.accountPeerId, .ok(withdrawAck))))

        // A new grant on the same binding (no bind, so nothing else clears a receipt).
        let regrantId = "2c4e6a8b-0d1f-4a3b-8c5d-7e9f1a2b3c4d"
        let regrant = SGConsentEvent(consentId: regrantId, tgUserId: self.alice.tg, action: .grant, scopes: SGConsentScope.allCases.map(\.rawValue), textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, ageConfirmed: true, recordedAt: "2026-11-01T10:05:00Z", appVersion: "12.0.1").encoded()
        driver.update(self.alice) { facts in
            facts.record = SGConsentRecord(tgUserId: self.alice.tg, state: .granted, consentId: regrantId, textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, decidedAt: "2026-11-01T10:05:00Z")
            facts.pendingUploads = [regrant]
            facts.latestDecision = regrant
            // No receipt for the binding: the snapshot is due at once (§9.3 a).
            facts.syncDueAt = self.now
        }
        XCTAssertEqual(driver.send(.consentChanged(tg: self.alice.tg)).filter { !$0.isSession }, [
            .publishClearance(account: self.alice.accountPeerId, [.recordEvents]),
            .call(account: self.alice.accountPeerId, .consents(try self.body(regrant)), budgeted: true),
        ])
        let regrantAck = Data("{\"schema_version\":1,\"results\":[{\"consent_id\":\"\(regrantId)\",\"outcome\":\"recorded\"}],\"consent\":{\"state\":\"granted\",\"consent_id\":\"\(regrantId)\",\"effective_at\":\"2026-11-01T10:05:00Z\"}}".utf8)
        let acked = driver.send(.outcome(.consents, account: self.alice.accountPeerId, .ok(regrantAck)))
        XCTAssertEqual(acked, [
            .markAcked(tg: self.alice.tg, consentIds: [regrantId]),
            .publishClearance(account: self.alice.accountPeerId, [.recordEvents, .uploadProfile]),
            .call(account: self.alice.accountPeerId, .sync, budgeted: true),
        ], "C§6.4: the profile goes again before events and Tasks")
        driver.persist(acked)
        XCTAssertEqual(driver.send(.outcome(.sync, account: self.alice.accountPeerId, .ok(stored))), [
            .recordSyncReceipt(account: self.alice.accountPeerId, minIntervalS: nil),
            .publishClearance(account: self.alice.accountPeerId, self.full),
        ], "the new grant's own sync clears events and Tasks")
    }

    func testAWithdrawalOnAnotherDeviceAlsoSupersedesTheSyncInFlight() {
        var due = self.linked(self.alice)
        due.syncDueAt = self.now
        due.eventsDueAt = self.now
        let driver = self.driver([self.alice: due], primary: self.alice, firstIdle: false)
        XCTAssertEqual(driver.send(.firstIdle), [
            .call(account: self.alice.accountPeerId, .sync, budgeted: true),
            .call(account: self.alice.accountPeerId, .events(background: false), budgeted: true),
        ])
        // Here the events answer brings the withdrawal first (the reducer never relies on the answers' order).
        let remote = SGConsentRequiredExtras(reason: .withdrawn, consent: SGEffectiveConsent(state: .withdrawn, consentId: self.withdrawId, textVersion: 1, effectiveAt: "2026-11-01T09:30:00Z"))
        let withdrawn = driver.send(.outcome(.events, account: self.alice.accountPeerId, .consentRequired(remote)))
        XCTAssertTrue(withdrawn.contains(.clearReceipt(account: self.alice.accountPeerId)))
        driver.persist(withdrawn)
        XCTAssertEqual(driver.send(.outcome(.sync, account: self.alice.accountPeerId, .ok(Data("{\"schema_version\":1,\"ingest\":\"stored\"}".utf8)))), [], "no receipt")
    }

    /// An account's calls go one at a time (`SGCustomerTransportLive`): a sync or events batch that
    /// still waits its turn when the user withdraws is checked again once its turn comes, and sends
    /// nothing (`clearanceToSend`). Nothing went out, so no receipt, no failure and no backoff.
    func testACallTheAccountLostItsClearanceForBeforeItsTurnCountsNoFailure() throws {
        XCTAssertEqual(Core.clearanceToSend(.sync), .uploadProfile)
        XCTAssertEqual(Core.clearanceToSend(.events), .uploadEvents)
        for route in [SGCustomerRoute.consents, .me, .delete] {
            XCTAssertEqual(Core.clearanceToSend(route), [], "\(route): a withdrawal must reach the server; the user's calls are never held")
        }
        var due = self.linked(self.alice)
        due.syncDueAt = self.now
        due.eventsDueAt = self.now
        let driver = self.driver([self.alice: due], primary: self.alice, firstIdle: false)
        XCTAssertEqual(driver.send(.firstIdle), [
            .call(account: self.alice.accountPeerId, .sync, budgeted: true),
            .call(account: self.alice.accountPeerId, .events(background: false), budgeted: true),
        ])
        self.withdraw(self.alice, in: driver)
        driver.persist(driver.send(.userWithdrew(account: self.alice.accountPeerId)))
        XCTAssertEqual(driver.send(.notSent(.sync, account: self.alice.accountPeerId)), [], "no receipt, no retry timer")
        XCTAssertEqual(driver.send(.notSent(.events, account: self.alice.accountPeerId)), [])
        XCTAssertFalse(driver.state.isInFlight(.sync, accountPeerId: self.alice.accountPeerId))
        XCTAssertFalse(driver.state.isInFlight(.events, accountPeerId: self.alice.accountPeerId))
        XCTAssertTrue(driver.state.isInFlight(.consents, accountPeerId: self.alice.accountPeerId), "the withdraw goes on")
        XCTAssertEqual(driver.send(.notSent(.sync, account: self.alice.accountPeerId)), [], "nothing in flight: nothing")
        let withdrawAck = Data("{\"schema_version\":1,\"results\":[{\"consent_id\":\"\(self.withdrawId)\",\"outcome\":\"recorded\"}],\"consent\":{\"state\":\"withdrawn\",\"consent_id\":\"\(self.withdrawId)\",\"effective_at\":\"2026-11-01T10:00:00Z\"}}".utf8)
        driver.persist(driver.send(.outcome(.consents, account: self.alice.accountPeerId, .ok(withdrawAck))))

        // A new grant on the same binding: its sync goes as soon as it is acked — no backoff waits.
        let regrantId = "2c4e6a8b-0d1f-4a3b-8c5d-7e9f1a2b3c4d"
        let regrant = SGConsentEvent(consentId: regrantId, tgUserId: self.alice.tg, action: .grant, scopes: SGConsentScope.allCases.map(\.rawValue), textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, ageConfirmed: true, recordedAt: "2026-11-01T10:05:00Z", appVersion: "12.0.1").encoded()
        driver.update(self.alice) { facts in
            facts.record = SGConsentRecord(tgUserId: self.alice.tg, state: .granted, consentId: regrantId, textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, decidedAt: "2026-11-01T10:05:00Z")
            facts.pendingUploads = [regrant]
            facts.latestDecision = regrant
            facts.syncDueAt = self.now
        }
        driver.persist(driver.send(.consentChanged(tg: self.alice.tg)))
        let regrantAck = Data("{\"schema_version\":1,\"results\":[{\"consent_id\":\"\(regrantId)\",\"outcome\":\"recorded\"}],\"consent\":{\"state\":\"granted\",\"consent_id\":\"\(regrantId)\",\"effective_at\":\"2026-11-01T10:05:00Z\"}}".utf8)
        XCTAssertEqual(driver.send(.outcome(.consents, account: self.alice.accountPeerId, .ok(regrantAck))), [
            .markAcked(tg: self.alice.tg, consentIds: [regrantId]),
            .publishClearance(account: self.alice.accountPeerId, [.recordEvents, .uploadProfile]),
            .call(account: self.alice.accountPeerId, .sync, budgeted: true),
        ], "the sync that was not sent counted no failure")
    }

    // MARK: - Deletion (§11.4)

    func testADeletionFencesBeforeTheSendAndA200ErasesInTheDesignOrder() {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        let fence = SGCustomerDeletion.Record(key: self.deleteKey, sentUnknown: false, since: "2026-11-01T10:00:00Z")
        let confirmed = driver.send(.userDeleteConfirmed(account: self.alice.accountPeerId, idempotencyKey: self.deleteKey))
        XCTAssertEqual(confirmed, [
            .writeDeletion(tg: self.alice.tg, fence),
            .publishClearance(account: self.alice.accountPeerId, []),
            .call(account: self.alice.accountPeerId, .delete(idempotencyKey: self.deleteKey), budgeted: false),
        ])
        driver.persist(confirmed)
        XCTAssertEqual(driver.send(.consentChanged(tg: self.alice.tg)), [], "erasing: nothing planned, nothing linked, clearance stays []")

        let erased = driver.send(.deleteOutcome(account: self.alice.accountPeerId, self.deleteAnswer(200)))
        XCTAssertEqual(erased.withoutLogs, self.eraseList(self.alice))
        XCTAssertTrue(erased.contains(.log(.accountErasedLocally)))
        driver.persist(erased)
        XCTAssertEqual(driver.send(.entitlementChanged), [], "state none: no auto-link, nothing to upload")
    }

    func testAFirstDeleteThatGets401ClockSkewErasesNothingAndLiftsTheFence() {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        driver.persist(driver.send(.userDeleteConfirmed(account: self.alice.accountPeerId, idempotencyKey: self.deleteKey)))
        let answered = driver.send(.deleteOutcome(account: self.alice.accountPeerId, self.deleteAnswer(401, "clock_skew")))
        XCTAssertEqual(Array(answered.prefix(2)), [
            .writeDeletion(tg: self.alice.tg, nil),
            .deletionReport(account: self.alice.accountPeerId, .notDeleted(.failed)),
        ])
        XCTAssertTrue(answered.contains(.publishClearance(account: self.alice.accountPeerId, self.full)), "the account is usable again")
        XCTAssertFalse(answered.contains(where: \.isErasureStep), "nothing erased")
    }

    func testA401InvalidTokenAfterAnUnknownOutcomeErases() {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        driver.persist(driver.send(.userDeleteConfirmed(account: self.alice.accountPeerId, idempotencyKey: self.deleteKey)))
        let unknown = SGCustomerDeletion.Record(key: self.deleteKey, sentUnknown: true, since: "2026-11-01T10:00:00Z")
        let timedOut = driver.send(.deleteOutcome(account: self.alice.accountPeerId, SGCustomerDeleteOutcome(SGCustomerRawAnswer(transport: .timeout))))
        XCTAssertEqual(timedOut, [
            .writeDeletion(tg: self.alice.tg, unknown),
            .deletionReport(account: self.alice.accountPeerId, .pending(.offline)),
            .scheduleTimer(account: self.alice.accountPeerId, .route(.delete), at: self.now.addingTimeInterval(15)),
        ])
        driver.persist(timedOut)
        driver.now = self.now.addingTimeInterval(15)
        XCTAssertEqual(driver.send(.timer(account: self.alice.accountPeerId, .route(.delete))), [
            .call(account: self.alice.accountPeerId, .delete(idempotencyKey: self.deleteKey), budgeted: false),
        ], "the same key")
        XCTAssertEqual(driver.send(.deleteOutcome(account: self.alice.accountPeerId, self.deleteAnswer(401, "invalid_token"))).withoutLogs, self.eraseList(self.alice, at: self.now.addingTimeInterval(15)))
    }

    func testIdempotencyInFlightRetriesTheSameKeyAfterOneSecond() {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        driver.persist(driver.send(.userDeleteConfirmed(account: self.alice.accountPeerId, idempotencyKey: self.deleteKey)))
        let answered = driver.send(.deleteOutcome(account: self.alice.accountPeerId, self.deleteAnswer(409, "idempotency_in_flight")))
        XCTAssertEqual(answered, [
            .writeDeletion(tg: self.alice.tg, SGCustomerDeletion.Record(key: self.deleteKey, sentUnknown: true, since: "2026-11-01T10:00:00Z")),
            .deletionReport(account: self.alice.accountPeerId, .pending(.inProgress)),
            .scheduleTimer(account: self.alice.accountPeerId, .route(.delete), at: self.now.addingTimeInterval(1)),
        ])
        driver.persist(answered)
        XCTAssertEqual(driver.send(.userDeleteConfirmed(account: self.alice.accountPeerId, idempotencyKey: "5e1d2c3b-4a59-4687-9a1b-2c3d4e5f6a7b")), [.call(account: self.alice.accountPeerId, .delete(idempotencyKey: self.deleteKey), budgeted: false)], "Retry keeps the stored key")
        XCTAssertEqual(driver.send(.userDeleteConfirmed(account: self.alice.accountPeerId, idempotencyKey: self.deleteKey)), [], "one in flight")
    }

    func testAnUnlinkedAccountGetsTheWebPageAndAnUnresolvedDeletionResumes() {
        let unlinked = self.driver([self.alice: self.unlinked(self.alice)], primary: self.alice)
        XCTAssertEqual(unlinked.send(.userDeleteConfirmed(account: self.alice.accountPeerId, idempotencyKey: self.deleteKey)), [.deletionReport(account: self.alice.accountPeerId, .notDeleted(.notLinked))])

        // A fence left by a process that died mid-send: re-sent at first idle as an unknown outcome.
        var facts = self.linked(self.alice)
        facts.deletion = SGCustomerDeletion.Record(key: self.deleteKey, sentUnknown: false, since: "2026-11-01T09:59:00Z")
        let resumed = self.driver([self.alice: facts], primary: self.alice, firstIdle: false)
        XCTAssertEqual(resumed.state.publishedClearance(accountPeerId: self.alice.accountPeerId), [], "erasing at t = 0")
        XCTAssertEqual(resumed.send(.firstIdle), [
            .writeDeletion(tg: self.alice.tg, SGCustomerDeletion.Record(key: self.deleteKey, sentUnknown: true, since: "2026-11-01T09:59:00Z")),
            .call(account: self.alice.accountPeerId, .delete(idempotencyKey: self.deleteKey), budgeted: false),
        ])
    }

    // MARK: - Sessions (§10.4)

    func testAnAccountSwitchEndsTheOldSessionThenStartsTheNew() {
        let driver = self.driver([self.alice: self.linked(self.alice), self.bob: self.linked(self.bob)], primary: self.alice, firstIdle: false, initialEffects: { effects in
            XCTAssertEqual(effects.filter(\.isSession), [.sessionStart(account: self.alice.accountPeerId, .launch)], "the process's first session")
        })
        XCTAssertEqual(driver.send(.accountsChanged(signedIn: [self.alice, self.bob], primary: self.bob.accountPeerId)), [
            .sessionEnd(account: self.alice.accountPeerId, .accountSwitch),
            .sessionStart(account: self.bob.accountPeerId, .accountSwitch),
        ])
        XCTAssertEqual(driver.send(.background), [.sessionEnd(account: self.bob.accountPeerId, .background)])
        XCTAssertEqual(driver.send(.accountsChanged(signedIn: [self.alice, self.bob], primary: self.alice.accountPeerId)), [], "no session in the background")
        XCTAssertEqual(driver.send(.foreground), [.sessionStart(account: self.alice.accountPeerId, .foreground)])
        XCTAssertEqual(driver.send(.foreground), [], "didBecomeActive after willEnterForeground")
        XCTAssertEqual(driver.send(.terminate), [.sessionEnd(account: self.alice.accountPeerId, .terminate)])
    }

    func testALogoutEndsNoSessionAndTheNextAccountStartsOne() {
        let driver = self.driver([self.alice: self.linked(self.alice), self.bob: self.linked(self.bob)], primary: self.bob, firstIdle: false)
        XCTAssertEqual(driver.state.sessionAccount, self.bob.accountPeerId)
        XCTAssertEqual(driver.send(.accountsChanged(signedIn: [self.alice], primary: self.alice.accountPeerId)), [
            .publishClearance(account: self.bob.accountPeerId, []),
            .purgeConsent(tg: self.bob.tg),
            .purgeQueue(tg: self.bob.tg),
            .sessionStart(account: self.alice.accountPeerId, .accountSwitch),
        ], "iOS never sends session_end{logout}: the logged-out account's queue is purged")
    }

    func testAGrantInTheForegroundStartsTheSession() {
        let driver = self.driver([self.alice: Core.Facts(bindPermissionAllowed: true)], primary: self.alice, firstIdle: false, initialEffects: { effects in
            XCTAssertEqual(effects, [.publishClearance(account: self.alice.accountPeerId, [])], "no consent, no session")
        })
        driver.update(self.alice) { $0 = self.unlinked(self.alice) }
        XCTAssertEqual(driver.send(.consentChanged(tg: self.alice.tg)), [
            .publishClearance(account: self.alice.accountPeerId, [.recordEvents]),
            .sessionStart(account: self.alice.accountPeerId, .launch),
        ], "Contract issue 9: launch for the process's first session")
    }

    // MARK: - First idle and the automatic link (§6.3, §8)

    func testNothingAutomaticRunsBeforeFirstIdle() throws {
        var synced = self.linked(self.bob)
        synced.syncDueAt = self.now
        let driver = self.driver([self.alice: self.unlinked(self.alice), self.bob: synced], primary: self.bob, firstIdle: false, jitter: 12)
        for event in [Core.Event.foreground, .entitlementChanged, .consentChanged(tg: self.alice.tg), .protectedDataAvailable, .timer(account: self.bob.accountPeerId, .route(.sync))] {
            XCTAssertEqual(driver.send(event).filter(\.isAutomatic), [], "\(event)")
        }
        XCTAssertEqual(driver.send(.firstIdle), [
            .call(account: self.bob.accountPeerId, .sync, budgeted: true),
            .scheduleTimer(account: self.alice.accountPeerId, .autoLink, at: self.now.addingTimeInterval(12)),
        ], "first idle: the uploads go; the automatic link waits out the process's jitter")
        driver.now = self.now.addingTimeInterval(12)
        XCTAssertEqual(driver.send(.timer(account: self.alice.accountPeerId, .autoLink)), [
            .writeAutoLink(tg: self.alice.tg, SGAutoLinkRecord(starts: [self.now.addingTimeInterval(12)])),
            .autoLink(account: self.alice.accountPeerId),
        ])
    }

    func testOneAutomaticLinkOnTheInstallPrimaryFirst() {
        let driver = self.driver([self.alice: self.unlinked(self.alice), self.bob: self.unlinked(self.bob)], primary: self.bob, firstIdle: false)
        let idle = driver.send(.firstIdle)
        driver.persist(idle)
        XCTAssertEqual(idle.filter(\.isAutoLink), [.autoLink(account: self.bob.accountPeerId)], "the primary account first, one at a time")
        for event in [Core.Event.entitlementChanged, .foreground, .consentChanged(tg: self.alice.tg)] {
            XCTAssertEqual(driver.send(event).filter(\.isAutoLink), [], "\(event): one in flight")
        }
        let finished = driver.send(.autoLinkFinished(account: self.bob.accountPeerId, .offline, attestOffered: true))
        XCTAssertEqual(finished, [
            .writeAutoLink(tg: self.bob.tg, SGAutoLinkRecord(starts: [self.now], failures: 1, nextAt: self.now.addingTimeInterval(60))),
            .scheduleTimer(account: self.bob.accountPeerId, .autoLink, at: self.now.addingTimeInterval(60)),
            .writeAutoLink(tg: self.alice.tg, SGAutoLinkRecord(starts: [self.now])),
            .autoLink(account: self.alice.accountPeerId),
        ], "the next account goes once the first ended")
    }

    func testTheAutomaticLinkReEvaluatesOnItsTriggers() {
        var waiting = self.unlinked(self.alice)
        waiting.bindPermissionAllowed = false
        let driver = self.driver([self.alice: waiting], primary: self.alice)
        XCTAssertEqual(driver.send(.foreground).filter(\.isAutoLink), [])
        driver.update(self.alice) { $0.bindPermissionAllowed = true }
        XCTAssertEqual(driver.send(.entitlementChanged).filter(\.isAutoLink), [.autoLink(account: self.alice.accountPeerId)], "SGEntitlement.didChangeNotification")

        // A refusal that sent nothing stops it until the consent state or the permission changes.
        driver.persist(driver.send(.autoLinkFinished(account: self.alice.accountPeerId, .notPermitted, attestOffered: false)))
        XCTAssertEqual(driver.send(.foreground).filter(\.isAutoLink), [])
        XCTAssertEqual(driver.send(.consentChanged(tg: self.alice.tg)).filter(\.isAutoLink), [.autoLink(account: self.alice.accountPeerId)], "SGConsentStore.didChangeNotification")
    }

    func testConsentStaleNormalisesTheGrantTheAttemptCarriedAndStopsIt() {
        let driver = self.driver([self.alice: self.unlinked(self.alice)], primary: self.alice)
        let finished = driver.send(.autoLinkFinished(account: self.alice.accountPeerId, .consentStale, attestOffered: true))
        XCTAssertTrue(finished.contains(.normaliseLinkEnded(tg: self.alice.tg, consentId: self.grantId(self.alice))))
        XCTAssertTrue(finished.contains(.publishClearance(account: self.alice.accountPeerId, [])))
        XCTAssertFalse(finished.contains(where: \.isAutoLink))
        driver.persist(finished)
        XCTAssertEqual(driver.send(.entitlementChanged).filter(\.isAutoLink), [], "no automatic link until a new grant")
    }

    // MARK: - A binding the server ended (§8.1)

    func testADropAfterTheGrantNormalisesOnceAndAutoLinkWaitsForANewGrant() {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        let drop = SGCustomerLinkState.SessionEnd(code: "invalid_token", reason: nil, at: self.now, deviceId: self.binding(self.alice))
        driver.update(self.alice) { facts in
            facts.bindingDeviceId = nil
            facts.hasProfileReceipt = false
            facts.sessionEnd = drop
        }
        let dropped = driver.send(.entitlementChanged)
        XCTAssertEqual(dropped.withoutLogs, [
            .normaliseLinkEnded(tg: self.alice.tg, consentId: self.grantId(self.alice)),
            .publishClearance(account: self.alice.accountPeerId, []),
        ], "needs_reconsent / link_ended, clearance [] (Tasks .forbidden), no auto-link with the old grant")
        XCTAssertTrue(dropped.contains(.log(.linkEndedNormalised)))
        driver.persist(dropped)
        XCTAssertEqual(driver.send(.consentChanged(tg: self.alice.tg)), [.writeLinkEndedMarker(tg: self.alice.tg, SGCustomerLinkState.Handled(drop))], "marked once the normalisation landed")
        driver.persist([.writeLinkEndedMarker(tg: self.alice.tg, SGCustomerLinkState.Handled(drop))])
        XCTAssertEqual(driver.send(.entitlementChanged), [], "handled exactly once")

        // A new grant, later than the drop: auto-link resumes with it.
        let regrant = SGConsentRecord(tgUserId: self.alice.tg, state: .granted, consentId: "6f1e2d3c-4b5a-4968-8a7b-6c5d4e3f2a1b", textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, decidedAt: "2026-11-01T10:01:00Z")
        driver.now = self.now.addingTimeInterval(60)
        driver.update(self.alice) { $0.record = regrant }
        let granted = driver.send(.consentChanged(tg: self.alice.tg))
        XCTAssertFalse(granted.contains(where: \.isNormalisation), "a grant after the drop is never normalised")
        XCTAssertTrue(granted.contains(.autoLink(account: self.alice.accountPeerId)))
    }

    func testAnErasedAccountIsErasedLocallyWithoutANetworkCall() {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        driver.update(self.alice) { facts in
            facts.bindingDeviceId = nil
            facts.sessionEnd = SGCustomerLinkState.SessionEnd(code: "invalid_token", reason: "account_erased", at: self.now, deviceId: self.binding(self.alice))
        }
        let erased = driver.send(.entitlementChanged)
        XCTAssertEqual(erased.withoutLogs, self.eraseList(self.alice))
        XCTAssertFalse(erased.contains(where: \.isCall))
        XCTAssertEqual(driver.send(.entitlementChanged), [], "once for that drop, even if the session item could not be removed")

        var syncing = self.linked(self.bob)
        syncing.syncDueAt = self.now
        let other = self.driver([self.bob: syncing], primary: self.bob, firstIdle: false)
        XCTAssertEqual(other.send(.firstIdle), [.call(account: self.bob.accountPeerId, .sync, budgeted: true)])
        XCTAssertEqual(other.send(.outcome(.sync, account: self.bob.accountPeerId, .session(code: "invalid_token", reason: "account_erased"))).withoutLogs, self.eraseList(self.bob))
    }

    // MARK: - Uploads (§6.3, §6.5)

    func testOneRequestPerAccountAndRoute() throws {
        var due = self.linked(self.alice)
        due.syncDueAt = self.now
        due.eventsDueAt = self.now
        let driver = self.driver([self.alice: due], primary: self.alice, firstIdle: false)
        XCTAssertEqual(driver.send(.firstIdle), [
            .call(account: self.alice.accountPeerId, .sync, budgeted: true),
            .call(account: self.alice.accountPeerId, .events(background: false), budgeted: true),
        ])
        XCTAssertEqual(driver.send(.foreground), [], "both in flight")
        XCTAssertEqual(driver.send(.outcome(.sync, account: self.alice.accountPeerId, .ok(Data("{\"schema_version\":1,\"ingest\":\"stored\",\"min_interval_s\":600}".utf8)))), [
            .recordSyncReceipt(account: self.alice.accountPeerId, minIntervalS: 600),
        ], "delivered for this binding; events still in flight")

        // A pending grant goes first and alone.
        var pending = self.linked(self.bob)
        pending.latestGrantAcked = false
        pending.pendingUploads = [self.grant(self.bob)]
        pending.syncDueAt = self.now
        let first = self.driver([self.bob: pending], primary: self.bob, firstIdle: false)
        XCTAssertEqual(first.send(.firstIdle), [.call(account: self.bob.accountPeerId, .consents(try self.body(self.grant(self.bob))), budgeted: true)])
        XCTAssertEqual(first.send(.entitlementChanged), [], "nothing beside a consents request")
    }

    func testAPostLinkUploadIsRecordedForTheBinding() throws {
        var relinked = self.linked(self.alice)
        relinked.consentsSentDeviceId = nil
        let driver = self.driver([self.alice: relinked], primary: self.alice, firstIdle: false)
        XCTAssertEqual(driver.send(.firstIdle), [.call(account: self.alice.accountPeerId, .consents(try self.body(self.grant(self.alice))), budgeted: true)], "always after a link")
        let duplicate = Data("{\"schema_version\":1,\"results\":[{\"consent_id\":\"\(self.grantId(self.alice))\",\"outcome\":\"duplicate\"}],\"consent\":{\"state\":\"granted\",\"consent_id\":\"\(self.grantId(self.alice))\",\"effective_at\":\"2026-11-01T09:00:00Z\"}}".utf8)
        XCTAssertEqual(driver.send(.outcome(.consents, account: self.alice.accountPeerId, .ok(duplicate))), [
            .markAcked(tg: self.alice.tg, consentIds: [self.grantId(self.alice)]),
            .writeConsentsSent(tg: self.alice.tg, deviceId: self.binding(self.alice)),
        ])
    }

    func testARefusedGrantIsMarkedRejectedAndStopsUploads() throws {
        var pending = self.linked(self.alice)
        pending.latestGrantAcked = false
        pending.pendingUploads = [self.grant(self.alice)]
        let driver = self.driver([self.alice: pending], primary: self.alice)
        let refused = driver.send(.outcome(.consents, account: self.alice.accountPeerId, .terminal(status: 422, code: "consent_text_mismatch")))
        XCTAssertEqual(refused, [
            .log(.consentRejected),
            .markRejected(tg: self.alice.tg, consentId: self.grantId(self.alice), code: "consent_text_mismatch"),
            .publishClearance(account: self.alice.accountPeerId, []),
        ])
    }

    func testAConsentsAnswerThatTakesNothingWaitsTheBackoff() throws {
        var pending = self.linked(self.alice)
        pending.latestGrantAcked = false
        pending.pendingUploads = [self.grant(self.alice)]
        let driver = self.driver([self.alice: pending], primary: self.alice, firstIdle: false)
        let call = Core.Effect.call(account: self.alice.accountPeerId, .consents(try self.body(self.grant(self.alice))), budgeted: true)
        XCTAssertEqual(driver.send(.firstIdle), [call])
        let unknownOutcome = Data("{\"schema_version\":1,\"results\":[{\"consent_id\":\"\(self.grantId(self.alice))\",\"outcome\":\"queued\"}]}".utf8)
        XCTAssertEqual(driver.send(.outcome(.consents, account: self.alice.accountPeerId, .ok(unknownOutcome))), [
            .scheduleTimer(account: self.alice.accountPeerId, .route(.consents), at: self.now.addingTimeInterval(15)),
        ], "still pending, but not resent at once")
        driver.now = self.now.addingTimeInterval(15)
        XCTAssertEqual(driver.send(.timer(account: self.alice.accountPeerId, .route(.consents))), [call])
        XCTAssertEqual(driver.send(.outcome(.consents, account: self.alice.accountPeerId, .ok(Data("{\"schema_version\":1}".utf8)))), [
            .log(.consentsAnswerUnreadable),
            .scheduleTimer(account: self.alice.accountPeerId, .route(.consents), at: self.now.addingTimeInterval(30)),
        ])
    }

    func testConsentRequiredOnSyncFollowsTheServer() throws {
        var due = self.linked(self.alice)
        due.syncDueAt = self.now
        let driver = self.driver([self.alice: due], primary: self.alice)
        // Withdrawn on another device, later than the local grant: the withdrawal seam.
        let remote = SGConsentRequiredExtras(reason: .withdrawn, consent: SGEffectiveConsent(state: .withdrawn, consentId: self.withdrawId, textVersion: 1, effectiveAt: "2026-11-01T09:30:00Z"))
        XCTAssertEqual(driver.send(.outcome(.sync, account: self.alice.accountPeerId, .consentRequired(remote))), [
            .log(.consentWithdrawnRemote),
            .markWithdrawnRemote(tg: self.alice.tg, effectiveAt: "2026-11-01T09:30:00Z", consentId: self.withdrawId),
            .publishClearance(account: self.alice.accountPeerId, []),
            .purgeQueue(tg: self.alice.tg),
            .clearReceipt(account: self.alice.accountPeerId),
            .tasksRetire(account: self.alice.accountPeerId),
        ])

        // No consent on the server: the grant goes again once, then the call; a second refusal stops it.
        let again = self.driver([self.bob: { var facts = self.linked(self.bob); facts.syncDueAt = self.now; return facts }()], primary: self.bob, firstIdle: false)
        again.send(.firstIdle)
        let missing = SGConsentRequiredExtras(reason: .noConsent, consent: nil)
        XCTAssertEqual(again.send(.outcome(.sync, account: self.bob.accountPeerId, .consentRequired(missing))), [
            .log(.consentReupload),
            .call(account: self.bob.accountPeerId, .consents(try self.body(self.grant(self.bob))), budgeted: true),
        ])
        let recorded = Data("{\"schema_version\":1,\"results\":[{\"consent_id\":\"\(self.grantId(self.bob))\",\"outcome\":\"recorded\"}],\"consent\":{\"state\":\"granted\",\"consent_id\":\"\(self.grantId(self.bob))\",\"effective_at\":\"2026-11-01T09:00:00Z\"}}".utf8)
        XCTAssertEqual(again.send(.outcome(.consents, account: self.bob.accountPeerId, .ok(recorded))), [
            .markAcked(tg: self.bob.tg, consentIds: [self.grantId(self.bob)]),
            .call(account: self.bob.accountPeerId, .sync, budgeted: true),
        ], "the failed call once more")
        XCTAssertEqual(again.send(.outcome(.sync, account: self.bob.accountPeerId, .consentRequired(missing))), [], "stopped for this process")
        XCTAssertEqual(again.send(.foreground), [])
    }

    func testAFinalSyncRefusalCountsAsDeliveredForTheBinding() {
        XCTAssertEqual(Core.syncDelivered(.ok(Data("{\"schema_version\":1,\"ingest\":\"paused\"}".utf8))).delivered, true)
        for outcome in [SGCustomerCallOutcome.terminal(status: 422, code: "invalid_request"), .accountMismatch, .payloadTooLarge] {
            XCTAssertEqual(Core.syncDelivered(outcome).delivered, true, "Contract issue 5: \(outcome)")
        }
        for outcome in [SGCustomerCallOutcome.timedOut, .unavailable(retryAfter: nil), .rateLimited(retryAfter: 5), .session(code: "invalid_token", reason: nil), .accountNotLinked, .credentialChanged, .notLinkedLocally, .notConfigured] {
            XCTAssertEqual(Core.syncDelivered(outcome).delivered, false, "\(outcome)")
        }
        var due = self.linked(self.alice)
        due.syncDueAt = self.now
        let driver = self.driver([self.alice: due], primary: self.alice)
        XCTAssertEqual(driver.send(.outcome(.sync, account: self.alice.accountPeerId, .terminal(status: 422, code: "invalid_request"))), [.recordSyncReceipt(account: self.alice.accountPeerId, minIntervalS: nil)])
    }

    func testAnUnusableSessionOrNothingToSendWaitsTheBackoff() {
        var due = self.linked(self.alice)
        due.syncDueAt = self.now
        let driver = self.driver([self.alice: due], primary: self.alice)
        XCTAssertEqual(driver.send(.outcome(.sync, account: self.alice.accountPeerId, .session(code: "clock_skew", reason: nil))), [
            .scheduleTimer(account: self.alice.accountPeerId, .route(.sync), at: self.now.addingTimeInterval(15)),
        ], "not again at once")
        driver.now = self.now.addingTimeInterval(15)
        XCTAssertEqual(driver.send(.timer(account: self.alice.accountPeerId, .route(.sync))), [.call(account: self.alice.accountPeerId, .sync, budgeted: true)])
        XCTAssertEqual(driver.send(.outcome(.sync, account: self.alice.accountPeerId, .notConfigured)), [
            .scheduleTimer(account: self.alice.accountPeerId, .route(.sync), at: self.now.addingTimeInterval(15 + 30)),
        ], "nothing could be sent: the route waits")
    }

    func testABackgroundEntryFlushesOneBatchPerAccount() {
        var queued = self.linked(self.alice)
        queued.queuedEvents = 7
        let driver = self.driver([self.alice: queued, self.bob: self.unlinked(self.bob)], primary: self.alice)
        XCTAssertEqual(driver.send(.background), [
            .sessionEnd(account: self.alice.accountPeerId, .background),
            .call(account: self.alice.accountPeerId, .events(background: true), budgeted: true),
        ], "only an account cleared to upload events")
        let early = self.driver([self.alice: queued], primary: self.alice, firstIdle: false)
        XCTAssertEqual(early.send(.background), [.sessionEnd(account: self.alice.accountPeerId, .background)], "nothing automatic before first idle")
        let paused = self.driver([self.alice: queued], primary: self.alice)
        paused.inputs.eventsPausedUntil = self.now.addingTimeInterval(3_600)
        XCTAssertEqual(paused.send(.background), [.sessionEnd(account: self.alice.accountPeerId, .background)], "ingest paused")
    }

    func testATimerIsScheduledOnce() {
        var later = self.linked(self.alice)
        later.syncDueAt = self.now.addingTimeInterval(600)
        let driver = self.driver([self.alice: later], primary: self.alice, firstIdle: false)
        XCTAssertEqual(driver.send(.firstIdle), [.scheduleTimer(account: self.alice.accountPeerId, .route(.sync), at: self.now.addingTimeInterval(600))])
        XCTAssertEqual(driver.send(.foreground), [])
        XCTAssertEqual(driver.send(.entitlementChanged), [])
    }

    // MARK: - Logout and launch (§11.5)

    func testTheLaunchReconciliationPurgesAccountsThatAreNotSignedIn() {
        var inputs = self.inputs([self.alice: self.linked(self.alice)])
        inputs.knownTelegramUserIds = [self.alice.tg, self.carol]
        inputs.queueOwners = [self.carol, 999]
        let launch = Core.reduce(Core.State(isForeground: false, autoLinkJitter: 0), .accountsChanged(signedIn: [self.alice], primary: self.alice.accountPeerId), inputs: inputs, now: self.now)
        XCTAssertEqual(launch.effects, [
            .purgeConsent(tg: 999),
            .purgeQueue(tg: 999),
            .purgeConsent(tg: self.carol),
            .purgeQueue(tg: self.carol),
            .publishClearance(account: self.alice.accountPeerId, self.full),
        ])
    }

    func testNothingIsDecidedFromAnUnreadableStore() {
        var inputs = self.inputs([self.alice: self.linked(self.alice)])
        inputs.knownTelegramUserIds = [self.carol]
        inputs.readable = false
        let driver = Driver(state: Core.State(isForeground: true, autoLinkJitter: 0), inputs: inputs, now: self.now)
        XCTAssertEqual(driver.send(.accountsChanged(signedIn: [self.alice], primary: self.alice.accountPeerId)), [.publishClearance(account: self.alice.accountPeerId, [])], "fail closed: no purge, no session, no upload")
        XCTAssertEqual(driver.send(.firstIdle), [])
        XCTAssertEqual(driver.send(.userDeleteConfirmed(account: self.alice.accountPeerId, idempotencyKey: self.deleteKey)), [.deletionReport(account: self.alice.accountPeerId, .notDeleted(.failed))])
        driver.inputs.readable = true
        driver.inputs.queueOwners = nil
        XCTAssertEqual(driver.send(.protectedDataAvailable), [
            .publishClearance(account: self.alice.accountPeerId, self.full),
            .sessionStart(account: self.alice.accountPeerId, .launch),
        ], "readable: decided again — but no purge while the queue directory is not listed")
        driver.inputs.queueOwners = []
        XCTAssertEqual(driver.send(.protectedDataAvailable), [
            .purgeConsent(tg: self.carol),
            .purgeQueue(tg: self.carol),
        ], "the launch reconciliation, once both are readable")
        XCTAssertEqual(driver.send(.protectedDataAvailable), [], "once")
    }

    // MARK: - A grant this build treats as stale (§4.6 rows 5–6)

    /// Two signed-in accounts, and an update makes the grant of the one that is not primary stale. The
    /// wall normalises only the primary account's record, so the coordinator stops the other one from
    /// this build's texts in its facts: clearance `[]`, no profile sync, no events.
    func testAStaleGrantOnTheAccountThatIsNotPrimaryClearsAndUploadsNothing() {
        let hash = String(repeating: "0", count: 64)
        var current = self.linked(self.alice)
        current.syncDueAt = self.now
        current.bundledMinValidVersion = 1
        current.renderedSha256ForRecord = hash
        var belowMinimum = self.linked(self.bob)
        belowMinimum.syncDueAt = self.now
        belowMinimum.eventsDueAt = self.now
        // An update raised min_valid_version above the granted v1 (row 5).
        belowMinimum.bundledMinValidVersion = 2
        belowMinimum.renderedSha256ForRecord = hash
        var operatorChanged = belowMinimum
        // This build renders the granted v1 with other operator values (row 6).
        operatorChanged.bundledMinValidVersion = 1
        operatorChanged.renderedSha256ForRecord = String(repeating: "1", count: 64)
        for (label, other) in [("below the bundled minimum", belowMinimum), ("operator values changed", operatorChanged)] {
            let driver = self.driver([self.alice: current, self.bob: other], primary: self.alice, firstIdle: false, initialEffects: { effects in
                XCTAssertTrue(effects.contains(.publishClearance(account: self.bob.accountPeerId, [])), label)
                XCTAssertTrue(effects.contains(.publishClearance(account: self.alice.accountPeerId, self.full)), "\(label): the primary account's grant is current")
            })
            XCTAssertEqual(driver.state.publishedClearance(accountPeerId: self.bob.accountPeerId), [], label)
            XCTAssertEqual(driver.send(.firstIdle), [.call(account: self.alice.accountPeerId, .sync, budgeted: true)], "\(label): no sync and no events for the other account")
        }

        // The same accounts with current grants both upload.
        var currentOther = belowMinimum
        currentOther.bundledMinValidVersion = 1
        let control = self.driver([self.alice: current, self.bob: currentOther], primary: self.alice, firstIdle: false, initialEffects: { effects in
            XCTAssertTrue(effects.contains(.publishClearance(account: self.bob.accountPeerId, self.full)))
        })
        XCTAssertEqual(control.send(.firstIdle), [
            .call(account: self.alice.accountPeerId, .sync, budgeted: true),
            .call(account: self.bob.accountPeerId, .sync, budgeted: true),
            .call(account: self.bob.accountPeerId, .events(background: false), budgeted: true),
        ])
    }

    /// Not linked, its grant stale: the automatic link would carry that grant to `bind/start`, so it
    /// waits — as for `needs_reconsent` — for the new grant the wall asks for.
    func testAStaleGrantIsNeverLinkedAutomatically() {
        var stale = self.unlinked(self.alice)
        stale.bundledMinValidVersion = 2
        let driver = self.driver([self.alice: stale], primary: self.alice, firstIdle: false, initialEffects: { effects in
            XCTAssertEqual(effects, [.publishClearance(account: self.alice.accountPeerId, [])], "nothing recorded, no session")
        })
        XCTAssertEqual(driver.send(.firstIdle), [], "no automatic link, no consents entry")
        XCTAssertEqual(driver.send(.entitlementChanged), [])

        var current = self.unlinked(self.alice)
        current.bundledMinValidVersion = 1
        current.renderedSha256ForRecord = String(repeating: "0", count: 64)
        let control = self.driver([self.alice: current], primary: self.alice, firstIdle: false)
        XCTAssertEqual(control.send(.firstIdle).filter(\.isAutoLink), [.autoLink(account: self.alice.accountPeerId)], "a current grant links")
    }

    // MARK: - The Link screen's hooks (§8.2)

    func testUnlinkSuppressesTheAutomaticLinkUntilAManualLink() {
        let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
        let unlinking = driver.send(.userWillUnlink(account: self.alice.accountPeerId))
        XCTAssertEqual(unlinking, [.writeAutoLink(tg: self.alice.tg, SGAutoLinkRecord(suppressed: "user_unlink"))])
        driver.persist(unlinking)
        // SGEntitlement.logout: the binding is gone, the grant stays.
        driver.update(self.alice) { facts in
            facts.bindingDeviceId = nil
            facts.hasProfileReceipt = false
        }
        XCTAssertEqual(driver.send(.entitlementChanged).filter(\.isAutoLink), [], "not linked again behind the user's back")
        let linked = driver.send(.userDidLink(account: self.alice.accountPeerId))
        XCTAssertEqual(linked.first, .writeAutoLink(tg: self.alice.tg, SGAutoLinkRecord()))
    }

    /// `SGLinkAccountModel.unlink()` has `.userWillUnlink` reduced synchronously and only then calls
    /// `SGEntitlement.logout`, which removes the session: a call that reduction started for the
    /// account would go under the session the next line removes (answered `.credentialChanged`, one
    /// budgeted request racing `/bind/revoke`). So it starts no consents, sync or events call for the
    /// account; every later reduction plans as before.
    func testAnUnlinkStartsNoUploadUnderTheSessionItsLogoutRemoves() throws {
        let relinked = "01JBALICENEWBINDINGAAAAAAA"
        // Both accounts linked, their sync and a flush due, events queued.
        func bothDue() -> Driver {
            let driver = self.driver([self.alice: self.linked(self.alice), self.bob: self.linked(self.bob)], primary: self.alice)
            for account in [self.alice, self.bob] {
                driver.update(account) { facts in
                    facts.syncDueAt = self.now
                    facts.eventsDueAt = self.now
                    facts.queuedEvents = 4
                }
            }
            return driver
        }
        let driver = bothDue()
        let unlinking = driver.send(.userWillUnlink(account: self.alice.accountPeerId))
        XCTAssertEqual(unlinking, [
            .writeAutoLink(tg: self.alice.tg, SGAutoLinkRecord(suppressed: "user_unlink")),
            .call(account: self.bob.accountPeerId, .sync, budgeted: true),
            .call(account: self.bob.accountPeerId, .events(background: false), budgeted: true),
        ], "nothing for alice under the session the logout removes; bob plans as before")
        driver.persist(unlinking)
        XCTAssertEqual(driver.send(.entitlementChanged), [
            .call(account: self.alice.accountPeerId, .sync, budgeted: true),
            .call(account: self.alice.accountPeerId, .events(background: false), budgeted: true),
        ], "a logout that left the session: the skip lasted one reduction")

        // SGEntitlement.logout removed the session: nothing goes and nothing is purged until the next link.
        let loggedOut = bothDue()
        loggedOut.persist(loggedOut.send(.userWillUnlink(account: self.alice.accountPeerId)))
        loggedOut.update(self.alice) { facts in
            facts.bindingDeviceId = nil
            facts.hasProfileReceipt = false
        }
        XCTAssertEqual(loggedOut.send(.entitlementChanged), [.publishClearance(account: self.alice.accountPeerId, [.recordEvents])], "no call, no purge: the queued events stay")
        loggedOut.update(self.alice) { $0.bindingDeviceId = relinked }
        let relinking = loggedOut.send(.entitlementChanged)
        XCTAssertEqual(relinking, [
            .publishClearance(account: self.alice.accountPeerId, [.recordEvents, .uploadProfile]),
            .call(account: self.alice.accountPeerId, .consents(try self.body(self.grant(self.alice))), budgeted: true),
        ], "the new binding's after-link re-send, first and alone")
        loggedOut.persist(relinking)
        let duplicate = Data("{\"schema_version\":1,\"results\":[{\"consent_id\":\"\(self.grantId(self.alice))\",\"outcome\":\"duplicate\"}],\"consent\":{\"state\":\"granted\",\"consent_id\":\"\(self.grantId(self.alice))\",\"effective_at\":\"2026-11-01T09:00:00Z\"}}".utf8)
        let resent = loggedOut.send(.outcome(.consents, account: self.alice.accountPeerId, .ok(duplicate)))
        XCTAssertEqual(resent, [
            .markAcked(tg: self.alice.tg, consentIds: [self.grantId(self.alice)]),
            .writeConsentsSent(tg: self.alice.tg, deviceId: relinked),
            .call(account: self.alice.accountPeerId, .sync, budgeted: true),
        ])
        loggedOut.persist(resent)
        XCTAssertEqual(loggedOut.send(.outcome(.sync, account: self.alice.accountPeerId, .ok(Data("{\"schema_version\":1,\"ingest\":\"stored\"}".utf8)))), [
            .recordSyncReceipt(account: self.alice.accountPeerId, minIntervalS: nil),
            .publishClearance(account: self.alice.accountPeerId, self.full),
            .call(account: self.alice.accountPeerId, .events(background: false), budgeted: true),
        ], "the queued events go once the new binding has the profile (C§6.4)")

        // A withdrawal the Unlink's reduction is the first to read: its local steps run, its send does not.
        func withdrawnThenUnlinked() -> (Driver, [Core.Effect]) {
            let driver = self.driver([self.alice: self.linked(self.alice)], primary: self.alice)
            self.withdraw(self.alice, in: driver)
            let effects = driver.send(.userWillUnlink(account: self.alice.accountPeerId))
            driver.persist(effects)
            return (driver, effects)
        }
        let (kept, withdrawing) = withdrawnThenUnlinked()
        XCTAssertEqual(withdrawing, [
            .writeAutoLink(tg: self.alice.tg, SGAutoLinkRecord(suppressed: "user_unlink")),
            .publishClearance(account: self.alice.accountPeerId, []),
            .purgeQueue(tg: self.alice.tg),
            .clearReceipt(account: self.alice.accountPeerId),
            .tasksRetire(account: self.alice.accountPeerId),
        ], "the suppression and the local steps as always; the logout's final send carries the withdraw")
        XCTAssertFalse(kept.state.isInFlight(.consents, accountPeerId: self.alice.accountPeerId))
        XCTAssertEqual(kept.send(.entitlementChanged), [
            .call(account: self.alice.accountPeerId, .consents(try self.body(self.withdrawal(self.alice))), budgeted: false),
        ], "a logout that left the session: the user's send goes in the next reduction")
        let (removed, _) = withdrawnThenUnlinked()
        removed.update(self.alice) { facts in
            facts.bindingDeviceId = nil
            facts.hasProfileReceipt = false
        }
        XCTAssertEqual(removed.send(.entitlementChanged), [], "no binding: no call")
        XCTAssertEqual(removed.inputs.accounts[self.alice.accountPeerId]?.pendingUploads, [self.withdrawal(self.alice)], "pending until a link acks it")
        removed.update(self.alice) { $0.bindingDeviceId = relinked }
        XCTAssertEqual(removed.send(.entitlementChanged), [
            .call(account: self.alice.accountPeerId, .consents(try self.body(self.withdrawal(self.alice))), budgeted: true),
        ], "after the next link the pending withdraw goes")
    }

    func testAManualConsentStaleNormalisesTheGrantItCarried() {
        let driver = self.driver([self.alice: self.unlinked(self.alice)], primary: self.alice)
        let stale = driver.send(.bindConsentStale(account: self.alice.accountPeerId, consentId: self.grantId(self.alice)))
        XCTAssertEqual(stale, [
            .log(.consentStale),
            .normaliseLinkEnded(tg: self.alice.tg, consentId: self.grantId(self.alice)),
            .publishClearance(account: self.alice.accountPeerId, []),
        ])
    }

    func testTheLinkEventsReachTheInstalledHandlerSynchronously() {
        var received: [Core.Event] = []
        SGCustomerLinkEvents.install { received.append(Core.Event($0)) }
        SGCustomerLinkEvents.userWillUnlink(accountPeerId: self.alice.accountPeerId)
        SGCustomerLinkEvents.userDidLink(accountPeerId: self.alice.accountPeerId)
        SGCustomerLinkEvents.bindConsentStale(accountPeerId: self.alice.accountPeerId, consentId: nil)
        XCTAssertEqual(received, [
            .userWillUnlink(account: self.alice.accountPeerId),
            .userDidLink(account: self.alice.accountPeerId),
            .bindConsentStale(account: self.alice.accountPeerId, consentId: nil),
        ], "delivered before each call returns")
        SGCustomerLinkEvents.install(handler: nil)
        SGCustomerLinkEvents.userWillUnlink(accountPeerId: self.alice.accountPeerId)
        XCTAssertEqual(received.count, 3, "no handler: nothing")
    }

    // MARK: - Reading the inputs

    func testTheStoreHalfOfTheFactsIsReadFromTheConsentStore() throws {
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        defer {
            made.remove()
        }
        let authority = "zenlygram.org"
        let store = SGConsentStore(defaults: made.defaults, isReadable: { true }, makeConsentId: { self.grantId(self.alice) }, notify: { _ in })
        let text = try XCTUnwrap(try SGCustomerSyncTestFixtures.repository().render(version: 1, locale: .uz, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()))
        let event = try store.grant(tg: self.alice.tg, text: text, mode: .required, appVersion: "12.0.1", now: Date(timeIntervalSince1970: 1_793_523_600)).get()

        var facts = Core.Facts(store: store, tg: self.alice.tg, authority: authority)
        XCTAssertEqual(facts.record?.state, .granted)
        XCTAssertEqual(facts.pendingUploads, [event.encoded()])
        XCTAssertEqual(facts.latestDecision, event.encoded())
        XCTAssertFalse(facts.latestGrantAcked)
        XCTAssertFalse(facts.latestGrantRejected)
        XCTAssertNil(facts.deletion)
        XCTAssertEqual(facts.autoLink, SGAutoLinkRecord())
        XCTAssertFalse(facts.isLinked, "SGEntitlement's half is the driver's")
        XCTAssertFalse(facts.bindPermissionAllowed, "fails closed until the driver reads it")

        let fence = SGCustomerDeletion.Record(key: self.deleteKey, sentUnknown: true, since: "2026-11-01T09:30:00Z")
        let handled = SGCustomerLinkState.Handled(deviceId: self.binding(self.alice), code: "invalid_token", at: "2026-11-01T09:10:00Z")
        try store.markAcked(tg: self.alice.tg, authority: authority, ids: [event.consentId]).get()
        try store.setString(self.binding(self.alice), for: .consentsSent(tg: self.alice.tg, authority: authority)).get()
        try store.setString(self.binding(self.alice), for: .notLinked(tg: self.alice.tg, authority: authority)).get()
        try store.setJSONObject(handled.jsonObject, for: .linkEnded(tg: self.alice.tg, authority: authority)).get()
        try store.setJSONObject(fence.jsonObject, for: .deletion(tg: self.alice.tg, authority: authority)).get()
        try store.setJSONObject(SGAutoLinkRecord(failures: 2).jsonObject, for: .autoLink(tg: self.alice.tg, authority: authority)).get()
        facts = Core.Facts(store: store, tg: self.alice.tg, authority: authority)
        XCTAssertTrue(facts.latestGrantAcked)
        XCTAssertEqual(facts.pendingUploads, [])
        XCTAssertEqual(facts.consentsSentDeviceId, self.binding(self.alice))
        XCTAssertEqual(facts.notLinkedDeviceId, self.binding(self.alice))
        XCTAssertEqual(facts.linkEndedHandled, handled)
        XCTAssertEqual(facts.deletion, fence)
        XCTAssertEqual(facts.autoLink.failures, 2)
        XCTAssertFalse(Core.Facts(store: store, tg: self.alice.tg, authority: "127.0.0.1:8443").latestGrantAcked, "per authority")
    }

    // MARK: - Analytics errors of automatic calls (§10.2)

    func testAFailedAutomaticCallBecomesAnAggregatedError() {
        let answer = SGCustomerRawAnswer(transport: .ok, status: 503, code: "profile_unavailable")
        XCTAssertEqual(Core.callError(route: .sync, outcome: SGCustomerWire.classify(answer), answer: answer), .error(.profileSync, SGAnalyticsErrorCode("profile_unavailable")!))
        let offline = SGCustomerRawAnswer(transport: .offline)
        XCTAssertEqual(Core.callError(route: .events, outcome: SGCustomerWire.classify(offline), answer: offline), .error(.eventsUpload, .offline))
        let timeout = SGCustomerRawAnswer(transport: .timeout)
        XCTAssertEqual(Core.callError(route: .consents, outcome: SGCustomerWire.classify(timeout), answer: timeout), .error(.consentUpload, .timeout))
        let secret = SGCustomerRawAnswer(transport: .ok, status: 422, code: "+998901234567")
        XCTAssertEqual(Core.callError(route: .consents, outcome: SGCustomerWire.classify(secret), answer: secret), .error(.consentUpload, SGAnalyticsErrorCode("server_other")!), "never a value")
        let ok = SGCustomerRawAnswer(transport: .ok, status: 200, body: Data("{\"schema_version\":1}".utf8))
        XCTAssertNil(Core.callError(route: .sync, outcome: SGCustomerWire.classify(ok), answer: ok))
        XCTAssertNil(Core.callError(route: .delete, outcome: SGCustomerWire.classify(answer), answer: answer), "the screens show user-initiated failures")
        XCTAssertNil(Core.callError(route: .sync, outcome: .credentialChanged, answer: SGCustomerRawAnswer(transport: .credentialChanged)))
        for code in [SGCustomerLogCode.linkEndedNormalised, .accountErasedLocally, .consentsAnswerUnreadable] {
            XCTAssertTrue(SGCustomerLogCode.isStableCode(code.rawValue), code.rawValue)
        }
    }

    // MARK: - Helpers

    /// A driver that runs the reducer and, like the app-side one, persists the store writes back
    /// into the inputs it reads before the next event.
    private final class Driver {
        var state: Core.State
        var inputs: Core.Inputs
        var now: Date

        init(state: Core.State, inputs: Core.Inputs, now: Date) {
            self.state = state
            self.inputs = inputs
            self.now = now
        }

        @discardableResult
        func send(_ event: Core.Event) -> [Core.Effect] {
            let result = Core.reduce(self.state, event, inputs: self.inputs, now: self.now, random: { 0.5 })
            self.state = result.state
            return result.effects
        }

        func update(_ account: Core.SignedIn, _ change: (inout Core.Facts) -> Void) {
            var facts = self.inputs.accounts[account.accountPeerId] ?? Core.Facts()
            change(&facts)
            self.inputs.accounts[account.accountPeerId] = facts
        }

        /// The store, SGEntitlement and Tasks writes of `effects`, as the next read would see them.
        func persist(_ effects: [Core.Effect]) {
            for effect in effects {
                switch effect {
                case let .writeAutoLink(tg, record):
                    self.change(tg: tg) { $0.autoLink = record ?? SGAutoLinkRecord() }
                case let .writeAutoLinkInstall(install):
                    self.inputs.autoLinkInstall = install
                case let .writeDeletion(tg, record):
                    self.change(tg: tg) { $0.deletion = record }
                case let .writeLinkEndedMarker(tg, handled):
                    self.change(tg: tg) { $0.linkEndedHandled = handled }
                case let .normaliseLinkEnded(tg, consentId):
                    self.change(tg: tg) { facts in
                        if facts.record?.state == .granted, consentId == nil || consentId == facts.record?.consentId {
                            facts.record?.state = .needsReconsent
                        }
                    }
                case let .writeConsentsSent(tg, deviceId):
                    self.change(tg: tg) { $0.consentsSentDeviceId = deviceId }
                case let .markAcked(tg, consentIds):
                    self.change(tg: tg) { facts in
                        facts.pendingUploads = facts.pendingUploads.filter { entry in SGConsentEvent.decode(entry).map { !consentIds.contains($0.consentId) } ?? true }
                        if facts.record?.state == .granted, let grantId = facts.record?.consentId, consentIds.contains(grantId) {
                            facts.latestGrantAcked = true
                        }
                    }
                case let .markWithdrawnRemote(tg, effectiveAt, consentId):
                    self.change(tg: tg) { facts in
                        guard var record = facts.record, record.state == .granted || record.state == .needsReconsent else {
                            return
                        }
                        record.state = .withdrawnRemote
                        record.consentId = consentId ?? record.consentId
                        record.decidedAt = effectiveAt
                        facts.record = record
                        facts.latestGrantAcked = false
                    }
                case let .clearReceipt(account):
                    self.inputs.accounts[account]?.hasProfileReceipt = false
                case let .recordSyncReceipt(account, _):
                    // The same digest is not due again for hours (§9.3).
                    self.inputs.accounts[account]?.hasProfileReceipt = true
                    self.inputs.accounts[account]?.syncDueAt = nil
                case let .purgeConsent(tg):
                    self.change(tg: tg) { $0 = Core.Facts(bindPermissionAllowed: $0.bindPermissionAllowed) }
                case let .forgetErasedAccount(account):
                    if var facts = self.inputs.accounts[account] {
                        facts.bindingDeviceId = nil
                        facts.sessionEnd = nil
                        facts.hasProfileReceipt = false
                        self.inputs.accounts[account] = facts
                    }
                default:
                    break
                }
            }
        }

        private func change(tg: Int64, _ change: (inout Core.Facts) -> Void) {
            guard let account = self.state.accountPeerIds.first(where: { self.state.tg(accountPeerId: $0) == tg }), var facts = self.inputs.accounts[account] else {
                return
            }
            change(&facts)
            self.inputs.accounts[account] = facts
        }
    }

    /// Accounts signed in (`accountsChanged`) in the foreground, first idle passed unless told.
    private func driver(_ accounts: [Core.SignedIn: Core.Facts], primary: Core.SignedIn?, firstIdle: Bool = true, jitter: TimeInterval = 0, initialEffects: (([Core.Effect]) -> Void)? = nil) -> Driver {
        let driver = Driver(state: Core.State(isForeground: true, autoLinkJitter: jitter), inputs: self.inputs(accounts), now: self.now)
        let signedIn = accounts.keys.sorted { $0.accountPeerId < $1.accountPeerId }
        let effects = driver.send(.accountsChanged(signedIn: signedIn, primary: primary?.accountPeerId))
        initialEffects?(effects)
        driver.persist(effects)
        if firstIdle {
            driver.persist(driver.send(.firstIdle))
        }
        return driver
    }

    private func inputs(_ accounts: [Core.SignedIn: Core.Facts]) -> Core.Inputs {
        var facts: [Int64: Core.Facts] = [:]
        for (account, value) in accounts {
            facts[account.accountPeerId] = value
        }
        return Core.Inputs(readable: true, accounts: facts, queueOwners: [], autoLinkInstall: SGAutoLinkInstallRecord(appVersion: "12.0.1"), appVersion: "12.0.1")
    }

    /// Consented, linked, its grant acked, the post-link upload recorded, synced: full clearance.
    private func linked(_ account: Core.SignedIn) -> Core.Facts {
        return Core.Facts(record: self.granted(account), latestGrantAcked: true, latestDecision: self.grant(account), consentsSentDeviceId: self.binding(account), bindingDeviceId: self.binding(account), hasProfileReceipt: true, bindPermissionAllowed: true)
    }

    /// Consented, not linked: the grant waits for the link.
    private func unlinked(_ account: Core.SignedIn) -> Core.Facts {
        return Core.Facts(record: self.granted(account), pendingUploads: [self.grant(account)], latestDecision: self.grant(account), bindPermissionAllowed: true)
    }

    /// Withdrawn in an earlier process, the withdrawal acked.
    private func withdrawn(_ account: Core.SignedIn) -> Core.Facts {
        var facts = self.linked(account)
        facts.record = SGConsentRecord(tgUserId: account.tg, state: .withdrawn, consentId: self.withdrawId, textVersion: 1, locale: .uz, consentMode: .required, decidedAt: "2026-11-01T09:30:00Z")
        facts.latestGrantAcked = false
        facts.latestDecision = self.withdrawal(account)
        facts.hasProfileReceipt = false
        return facts
    }

    /// What `SGConsentStore.withdraw` leaves for the next read.
    private func withdraw(_ account: Core.SignedIn, in driver: Driver) {
        driver.update(account) { facts in
            facts.record = SGConsentRecord(tgUserId: account.tg, state: .withdrawn, consentId: self.withdrawId, textVersion: 1, locale: .uz, consentMode: .required, decidedAt: "2026-11-01T10:00:00Z")
            facts.latestGrantAcked = false
            facts.pendingUploads = [self.withdrawal(account)]
            facts.latestDecision = self.withdrawal(account)
        }
    }

    private func grantId(_ account: Core.SignedIn) -> String {
        return account == self.alice ? "3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a" : "5e1d2c3b-4a59-4687-9a1b-2c3d4e5f6a7b"
    }

    private func binding(_ account: Core.SignedIn) -> String {
        return account == self.alice ? "01JBALICEBINDINGAAAAAAAAAA" : "01JBBOBBINDINGAAAAAAAAAAAA"
    }

    private func granted(_ account: Core.SignedIn) -> SGConsentRecord {
        return SGConsentRecord(tgUserId: account.tg, state: .granted, consentId: self.grantId(account), textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, decidedAt: "2026-11-01T09:00:00Z")
    }

    private func grant(_ account: Core.SignedIn) -> Data {
        return SGConsentEvent(consentId: self.grantId(account), tgUserId: account.tg, action: .grant, scopes: SGConsentScope.allCases.map(\.rawValue), textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, ageConfirmed: true, recordedAt: "2026-11-01T09:00:00Z", appVersion: "12.0.1").encoded()
    }

    private func withdrawal(_ account: Core.SignedIn) -> Data {
        return SGConsentEvent(consentId: self.withdrawId, tgUserId: account.tg, action: .withdraw, scopes: SGConsentScope.allCases.map(\.rawValue), textVersion: 1, textSha256: nil, locale: .uz, consentMode: .required, ageConfirmed: nil, recordedAt: "2026-11-01T10:00:00Z", appVersion: "12.0.1").encoded()
    }

    private func body(_ entry: Data) throws -> Data {
        return try XCTUnwrap(SGConsentsRequest.body(events: [entry]))
    }

    private func deleteAnswer(_ status: Int, _ code: String? = nil) -> SGCustomerDeleteOutcome {
        let body = status == 200 ? "{\"schema_version\":1,\"state\":\"erased\",\"retained\":[\"payment_records\"]}" : "{\"error\":\"\(code ?? "")\"}"
        return SGCustomerDeleteOutcome(SGCustomerRawAnswer(transport: .ok, status: status, code: code, body: Data(body.utf8)))
    }

    /// Design 40 §11.4's local erase, in its order, then the screen's report.
    private func eraseList(_ account: Core.SignedIn, at date: Date? = nil) -> [Core.Effect] {
        return [
            .forgetErasedAccount(account: account.accountPeerId),
            .tasksErased(account: account.accountPeerId),
            .purgeQueue(tg: account.tg),
            .publishClearance(account: account.accountPeerId, []),
            .purgeConsent(tg: account.tg),
            .writeAutoLink(tg: account.tg, nil),
            .writeDeletion(tg: account.tg, nil),
            .writeDeletedNotice(tg: account.tg, at: date ?? self.now),
            .deletionReport(account: account.accountPeerId, .deleted),
        ]
    }
}

private extension Array where Element == SGCustomerCoordinatorCore.Effect {
    var withoutLogs: [Element] {
        return self.filter { effect in
            if case .log = effect {
                return false
            }
            return true
        }
    }
}

private extension SGCustomerCoordinatorCore.Effect {
    var isSession: Bool {
        switch self {
        case .sessionStart, .sessionEnd:
            return true
        default:
            return false
        }
    }

    var isAutoLink: Bool {
        if case .autoLink = self {
            return true
        }
        return false
    }

    var isCall: Bool {
        if case .call = self {
            return true
        }
        return false
    }

    /// A call, an automatic link or a timer: what nothing automatic before first idle rules out.
    var isAutomatic: Bool {
        switch self {
        case .call, .autoLink, .scheduleTimer:
            return true
        default:
            return false
        }
    }

    var isNormalisation: Bool {
        switch self {
        case .normalise, .normaliseLinkEnded:
            return true
        default:
            return false
        }
    }

    var isWithdrawalStep: Bool {
        switch self {
        case .purgeQueue, .clearReceipt, .tasksRetire, .call:
            return true
        default:
            return false
        }
    }

    var isErasureStep: Bool {
        switch self {
        case .forgetErasedAccount, .tasksErased, .purgeConsent, .writeDeletedNotice:
            return true
        default:
            return false
        }
    }
}
