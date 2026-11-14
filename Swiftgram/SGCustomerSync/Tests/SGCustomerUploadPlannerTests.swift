import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the upload order (contract §6.4, design 40 §6.3): nothing automatic before first
/// idle; consents → sync → events; withdrawn → consents (withdrawals) only; user-initiated routes in
/// every state; one in flight per (account, route); budgets and backoff hold automatic calls only.
final class SGCustomerUploadPlannerTests: XCTestCase {
    private let tg: Int64 = 555_000_111
    private let binding = "01JBBINDINGAAAAAAAAAAAAAAA"
    /// 2026-11-01T10:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_793_527_200)
    private let grantId = "3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a"
    private let withdrawId = "9b2d4f6a-8c0e-4a1b-b3d5-e7f9a1c3e5d7"

    func testNothingAutomaticRunsBeforeFirstIdle() {
        var account = self.ready()
        account.firstIdlePassed = false
        account.pendingUploads = [self.grant()]
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none)
        account.clearance.bindingDeviceId = nil
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "not even the auto-link")
    }

    func testAnUnlinkedGrantedAccountIsHandedToTheAutoLink() {
        var account = self.ready()
        account.clearance.bindingDeviceId = nil
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .autoLink)
        for state in SGConsentState.allCases where state != .granted {
            account.clearance.state = state
            XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, state.rawValue)
        }
        account.clearance.state = .granted
        account.clearance.latestGrantRejected = true
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "a rejected grant")
        account.clearance.latestGrantRejected = false
        account.clearance.linkEnded = true
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "a server-ended link waits for a new grant")
        account.clearance.linkEnded = false
        account.clearance.erasing = true
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "erasing")
    }

    func testConsentsThenSyncThenEvents() {
        // A new link: the grant is pending.
        var account = self.ready()
        account.pendingUploads = [self.grant()]
        account.clearance.latestGrantAcked = false
        account.consentsSentDeviceId = nil
        account.clearance.hasProfileReceipt = false
        account.syncDueAt = self.now
        account.eventsDueAt = self.now
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .consents(entry: self.grant(), reason: .pending))
        // Acked, the post-link upload recorded: the first sync, never events before it.
        account.pendingUploads = []
        account.clearance.latestGrantAcked = true
        account.consentsSentDeviceId = self.binding
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .sync)
        account.inFlight = [.sync]
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "events wait for this binding's receipt")
        // Synced: events.
        account.inFlight = []
        account.clearance.hasProfileReceipt = true
        account.syncDueAt = nil
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .events)
    }

    func testEveryLinkResendsTheLatestDecisionOnce() {
        var account = self.ready()
        account.consentsSentDeviceId = "01JBOLDBINDINGAAAAAAAAAAAA"
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .consents(entry: self.grant(), reason: .afterLink), "always after a link")
        account.consentsSentDeviceId = self.binding
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .sync)
        account.consentsSentDeviceId = nil
        account.clearance.latestGrantRejected = true
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "a rejected grant is never sent again")
        account.clearance.latestGrantRejected = false
        account.recordConsentId = "5e1d2c3b-4a59-4687-9a1b-2c3d4e5f6a7b"
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .sync, "only the record's own decision is re-sent")
    }

    func testWithdrawnRunsOnlyTheWithdrawalUpload() {
        var account = self.ready()
        account.clearance.state = .withdrawn
        account.recordConsentId = self.withdrawId
        account.latestDecision = self.withdraw()
        account.pendingUploads = [self.grant(), self.withdraw()]
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .consents(entry: self.withdraw(), reason: .pending), "only the withdrawal, never the old grant")
        account.pendingUploads = [self.grant()]
        account.consentsSentDeviceId = "01JBOLDBINDINGAAAAAAAAAAAA"
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .consents(entry: self.withdraw(), reason: .afterLink))
        account.consentsSentDeviceId = self.binding
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "no sync, no events")

        account.clearance.state = .withdrawnRemote
        account.recordConsentId = self.grantId
        account.latestDecision = self.grant()
        account.consentsSentDeviceId = nil
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "another device's withdrawal: the local grant is never re-sent")
        for state in [SGConsentState.needsReconsent, .declined, .none] {
            account.clearance.state = state
            account.pendingUploads = [self.grant()]
            XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, state.rawValue)
            account.pendingUploads = [self.grant(), self.withdraw()]
            XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .consents(entry: self.withdraw(), reason: .pending), "\(state.rawValue): a pending withdrawal still goes")
        }
    }

    /// A grant this build treats as stale (§4.6 rows 5–6: the record's version below the bundled
    /// minimum, or its text rendered here with another hash) is read as `needs_reconsent`, exactly as
    /// `SGCustomerClearance.derive` stops it: never handed to the automatic link (the bind would carry
    /// it), never sent again — only a pending withdrawal still goes.
    func testAStaleGrantIsNeitherLinkedWithNorSentAgain() {
        let hash = String(repeating: "0", count: 64)
        var current = self.ready()
        current.clearance.textVersion = 1
        current.clearance.textSha256 = hash
        current.clearance.bundledMinValidVersion = 1
        current.clearance.renderedSha256ForRecord = hash
        var belowMinimum = current
        belowMinimum.clearance.bundledMinValidVersion = 2
        var operatorChanged = current
        operatorChanged.clearance.renderedSha256ForRecord = String(repeating: "1", count: 64)
        for (label, base, stale) in [("current", current, false), ("below the bundled minimum", belowMinimum, true), ("operator values changed", operatorChanged, true)] {
            var account = base
            account.clearance.bindingDeviceId = nil
            XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), stale ? .none : .autoLink, "\(label): not linked")
            // Linked, the grant not acked yet: it would go first.
            account.clearance.bindingDeviceId = self.binding
            account.clearance.latestGrantAcked = false
            account.pendingUploads = [self.grant()]
            XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), stale ? .none : .consents(entry: self.grant(), reason: .pending), "\(label): pending")
            // Acked, a new binding: the post-link re-send.
            account.clearance.latestGrantAcked = true
            account.pendingUploads = []
            account.consentsSentDeviceId = nil
            XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), stale ? .none : .consents(entry: self.grant(), reason: .afterLink), "\(label): after a link")
            account.pendingUploads = [self.withdraw(), self.grant()]
            XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .consents(entry: self.withdraw(), reason: .pending), "\(label): a pending withdrawal still goes")
        }
    }

    func testSyncAndEventsNeedTheFullClearance() {
        var account = self.ready()
        account.consentsSentDeviceId = self.binding
        account.eventsDueAt = self.now
        account.clearance.latestGrantAcked = false
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "the latest grant is not acked")
        account.clearance.latestGrantAcked = true
        account.clearance.notLinkedDeviceId = self.binding
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "profile_account_not_linked for this binding")
        account.clearance.notLinkedDeviceId = nil
        account.clearance.erasing = true
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "erasing")
        account.clearance.erasing = false
        account.clearance.readable = false
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "unreadable")
        account.clearance.readable = true
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .sync)
    }

    func testOneRequestPerRouteIsInFlight() {
        var account = self.ready()
        account.consentsSentDeviceId = self.binding
        account.eventsDueAt = self.now
        account.inFlight = [.sync]
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .events, "another route may go")
        account.inFlight = [.events]
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .sync)
        account.inFlight = [.sync, .events]
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none)
        account.inFlight = [.consents]
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none, "a consents answer is awaited first")
        account.pendingUploads = [self.grant()]
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none)
    }

    func testBackoffBudgetsAndDueTimesHoldTheAutomaticSteps() {
        var account = self.ready()
        account.consentsSentDeviceId = self.binding
        account.eventsDueAt = self.now.addingTimeInterval(120)
        account.backoffUntil[.sync] = self.now.addingTimeInterval(300)
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .wait(.events, until: self.now.addingTimeInterval(120)), "the earliest of the waits")
        account.eventsDueAt = nil
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .wait(.sync, until: self.now.addingTimeInterval(300)))
        account.budgetUntil[.sync] = self.now.addingTimeInterval(900)
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .wait(.sync, until: self.now.addingTimeInterval(900)), "the later of backoff and budget")
        account.backoffUntil[.sync] = self.now.addingTimeInterval(-1)
        account.budgetUntil[.sync] = self.now
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .sync, "a past hold is none")
        account.pendingUploads = [self.withdraw()]
        account.budgetUntil[.consents] = self.now.addingTimeInterval(60)
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .wait(.consents, until: self.now.addingTimeInterval(60)), "consents first, also while held")
        account.syncDueAt = self.now.addingTimeInterval(30)
        account.pendingUploads = []
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .wait(.sync, until: self.now.addingTimeInterval(30)))
    }

    func testUserInitiatedCallsGoInEveryStateWithoutBudgetOrFirstIdle() {
        for route in [SGCustomerRoute.me, .consents, .delete] {
            XCTAssertEqual(SGCustomerUploadPlanner.userInitiated(route, isLinked: true, inFlight: []), .send, route.rawValue)
            XCTAssertEqual(SGCustomerUploadPlanner.userInitiated(route, isLinked: true, inFlight: [.sync, .events]), .send, route.rawValue)
            XCTAssertEqual(SGCustomerUploadPlanner.userInitiated(route, isLinked: true, inFlight: [route]), .inFlight, route.rawValue)
            XCTAssertEqual(SGCustomerUploadPlanner.userInitiated(route, isLinked: false, inFlight: []), .notLinked, route.rawValue)
        }
        XCTAssertEqual(SGCustomerUploadPlanner.userInitiated(.sync, isLinked: true, inFlight: []), .notUserInitiated)
        XCTAssertEqual(SGCustomerUploadPlanner.userInitiated(.events, isLinked: true, inFlight: []), .notUserInitiated)
        // The planner itself would hold every automatic step here; the user's calls take none of it into account.
        var account = self.ready()
        account.firstIdlePassed = false
        account.clearance.state = .needsReconsent
        account.clearance.erasing = true
        account.budgetUntil = [.consents: self.now.addingTimeInterval(3600), .me: self.now.addingTimeInterval(3600), .delete: self.now.addingTimeInterval(3600)]
        account.backoffUntil = account.budgetUntil
        XCTAssertEqual(SGCustomerUploadPlanner.next(account, now: self.now), .none)
        XCTAssertEqual(SGCustomerUploadPlanner.userInitiated(.delete, isLinked: account.clearance.isLinked, inFlight: account.inFlight), .send)
    }

    func testTheBudgetsBindAutomaticCallsOnly() {
        XCTAssertEqual(SGCustomerBudget.limit(for: .consents), 16)
        XCTAssertEqual(SGCustomerBudget.limit(for: .sync), 9)
        XCTAssertEqual(SGCustomerBudget.limit(for: .events), 48)
        XCTAssertNil(SGCustomerBudget.limit(for: .me))
        XCTAssertNil(SGCustomerBudget.limit(for: .delete))
        var budget = SGCustomerBudget(route: .me)
        for _ in 0 ..< 100 {
            budget.record(now: self.now)
        }
        XCTAssertNil(budget.nextAllowedAt(now: self.now), "the user-initiated routes are never held")
    }

    func testTheStoreFeedsThePlanner() throws {
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        defer {
            made.remove()
        }
        let store = SGConsentStore(defaults: made.defaults, isReadable: { true }, now: { self.now }, makeConsentId: { "3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a" }, notify: { _ in })
        let text = try XCTUnwrap(try SGCustomerSyncTestFixtures.repository().render(version: 1, locale: .uz, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()))
        let event = try store.grant(tg: self.tg, text: text, mode: .required, appVersion: "12.0.1", now: Date(timeIntervalSince1970: 1_793_523_600)).get()
        let authority = "zenlygram.org"
        func account() -> SGCustomerUploadPlanner.Account {
            return SGCustomerUploadPlanner.Account(
                clearance: SGCustomerClearance.inputs(store: store, tg: self.tg, authority: authority, bindingDeviceId: self.binding, linkEnded: false, hasProfileReceipt: false),
                recordConsentId: store.record(tg: self.tg)?.consentId,
                firstIdlePassed: true,
                pendingUploads: store.pendingUploads(tg: self.tg, authority: authority),
                latestDecision: store.latestDecision(tg: self.tg),
                consentsSentDeviceId: store.string(.consentsSent(tg: self.tg, authority: authority)),
                syncDueAt: SGProfileSyncCadence.dueAt(digest: String(repeating: "a", count: 64), receipt: nil, digestChangedAt: nil, lastAttemptAt: nil, minIntervalS: nil, isForeground: true, now: self.now),
                eventsDueAt: nil
            )
        }
        guard case let .consents(entry, reason) = SGCustomerUploadPlanner.next(account(), now: self.now) else {
            return XCTFail("the grant goes first")
        }
        XCTAssertEqual(reason, .pending)
        XCTAssertEqual(entry, event.encoded())
        let grantCase = try XCTUnwrap(try SGCustomerSyncTestFixtures.cases("consents-valid.json").first { $0["id"] as? String == "grant" })
        SGCustomerSyncTestFixtures.assertJSON(try XCTUnwrap(SGConsentsRequest.body(events: [entry])), equals: grantCase["body"], "one entry per request, the shared fixture's body")

        try store.markAcked(tg: self.tg, authority: authority, ids: [event.consentId]).get()
        try store.setString(self.binding, for: .consentsSent(tg: self.tg, authority: authority)).get()
        XCTAssertEqual(SGCustomerUploadPlanner.next(account(), now: self.now), .sync)
    }

    // MARK: - Helpers

    /// A consented account, linked, its grant acked, the post-link upload recorded, synced, first idle passed, a sync due.
    private func ready() -> SGCustomerUploadPlanner.Account {
        return SGCustomerUploadPlanner.Account(
            clearance: SGCustomerClearance.Inputs(readable: true, state: .granted, latestGrantRejected: false, erasing: false, linkEnded: false, bindingDeviceId: self.binding, latestGrantAcked: true, notLinkedDeviceId: nil, hasProfileReceipt: true),
            recordConsentId: self.grantId,
            firstIdlePassed: true,
            pendingUploads: [],
            latestDecision: self.grant(),
            consentsSentDeviceId: nil,
            syncDueAt: self.now,
            eventsDueAt: nil
        )
    }

    private func grant() -> Data {
        return SGConsentEvent(consentId: self.grantId, tgUserId: self.tg, action: .grant, scopes: ["link", "profile", "statistics", "tasks_sync"], textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, ageConfirmed: true, recordedAt: "2026-11-01T09:00:00Z", appVersion: "12.0.1").encoded()
    }

    private func withdraw() -> Data {
        return SGConsentEvent(consentId: self.withdrawId, tgUserId: self.tg, action: .withdraw, scopes: ["link", "profile", "statistics", "tasks_sync"], textVersion: 1, textSha256: nil, locale: .uz, consentMode: .required, ageConfirmed: nil, recordedAt: "2026-11-01T09:30:00Z", appVersion: "12.0.1").encoded()
    }
}
