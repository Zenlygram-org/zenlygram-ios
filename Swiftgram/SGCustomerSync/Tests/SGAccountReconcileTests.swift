import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — what goes when Telegram accounts leave the device (design 40 §11.5): the logout purge
/// set, the launch reconciliation, nothing at all while unreadable, and the logout's final withdraw
/// bodies.
final class SGAccountReconcileTests: XCTestCase {
    private let alice: Int64 = 555_000_111
    private let bob: Int64 = 555_000_222
    private let carol: Int64 = 555_000_333
    /// 2026-11-01T09:00:00Z.
    private let start = Date(timeIntervalSince1970: 1_793_523_600)
    private let authority = "zenlygram.org"

    func testALoggedOutAccountIsPurged() {
        XCTAssertEqual(SGAccountReconcile.purgeSet(known: [self.alice, self.bob], queueOwners: [self.alice, self.bob], signedIn: [self.alice], readable: true), [self.bob], "a record and a queue")
        XCTAssertEqual(SGAccountReconcile.purgeSet(known: [self.alice, self.bob], queueOwners: [], signedIn: [self.alice], readable: true), [self.bob], "a record only")
        XCTAssertEqual(SGAccountReconcile.purgeSet(known: [self.alice], queueOwners: [self.bob], signedIn: [self.alice], readable: true), [self.bob], "a queue only")
        XCTAssertEqual(SGAccountReconcile.purgeSet(known: [self.alice], queueOwners: [self.alice], signedIn: [self.alice], readable: true), [], "nothing of a signed-in account")
    }

    func testTheLaunchReconciliationPurgesEveryIdThatIsNotSignedIn() {
        // Logged out while the app was closed: whatever the store and the queue directory still hold.
        let purge = SGAccountReconcile.purgeSet(known: [self.carol, self.alice, self.bob, self.bob], queueOwners: [self.carol, 777], signedIn: [self.alice], readable: true)
        XCTAssertEqual(purge, [777, self.bob, self.carol], "ascending, each once")
        XCTAssertEqual(SGAccountReconcile.purgeSet(known: [0, -5, self.bob], queueOwners: [-1], signedIn: [], readable: true), [self.bob], "never an id that cannot be a Telegram user")
        XCTAssertEqual(SGAccountReconcile.purgeSet(known: [], queueOwners: [], signedIn: [], readable: true), [])
    }

    func testNothingIsPurgedWhileUnreadable() {
        // A launch before the first unlock sees empty defaults and no files: never "absent, so purge".
        XCTAssertEqual(SGAccountReconcile.purgeSet(known: [self.alice, self.bob], queueOwners: [self.bob], signedIn: [], readable: false), [], "the consent store")
        XCTAssertEqual(SGAccountReconcile.purgeSet(known: [self.alice, self.bob], queueOwners: nil, signedIn: [], readable: true), [], "the queue directory")
    }

    func testThePurgeSetEmptiesARealStoreForTheLoggedOutAccountOnly() throws {
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        defer {
            made.remove()
        }
        var readable = true
        var ids = ["3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a", "9b2d4f6a-8c0e-4a1b-b3d5-e7f9a1c3e5d7"]
        let store = SGConsentStore(defaults: made.defaults, isReadable: { readable }, now: { self.start }, makeConsentId: { ids.removeFirst() }, notify: { _ in })
        let text = try XCTUnwrap(try SGCustomerSyncTestFixtures.repository().render(version: 1, locale: .uz, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()))
        for tg in [self.alice, self.bob] {
            _ = try store.grant(tg: tg, text: text, mode: .required, appVersion: "12.0.1", now: self.start).get()
        }
        try store.setJSONObject(SGAutoLinkRecord(failures: 1).jsonObject, for: .autoLink(tg: self.bob, authority: self.authority)).get()
        try store.setString("01JBBINDINGAAAAAAAAAAAAAAA", for: .consentsSent(tg: self.bob, authority: self.authority)).get()

        readable = false
        XCTAssertEqual(SGAccountReconcile.purgeSet(known: store.knownTelegramUserIds(), queueOwners: [], signedIn: [self.alice], readable: store.isReadable), [], "locked: nothing")
        XCTAssertEqual(store.knownTelegramUserIds(), [self.alice, self.bob], "and nothing went")

        readable = true
        let purge = SGAccountReconcile.purgeSet(known: store.knownTelegramUserIds(), queueOwners: [], signedIn: [self.alice], readable: store.isReadable)
        XCTAssertEqual(purge, [self.bob])
        for tg in purge {
            try store.purge(tg: tg).get()
        }
        XCTAssertEqual(store.knownTelegramUserIds(), [self.alice])
        XCTAssertNil(store.jsonObject(.autoLink(tg: self.bob, authority: self.authority)))
        XCTAssertNil(store.string(.consentsSent(tg: self.bob, authority: self.authority)))
        XCTAssertEqual(store.record(tg: self.alice)?.state, .granted)
    }

    func testTheLogoutFinalSendCarriesTheNewestThreeWithdrawalsOnePerBody() throws {
        let withdrawals = (0 ..< 4).map { index in
            SGConsentEvent(consentId: "9b2d4f6a-8c0e-4a1b-b3d5-e7f9a1c3e5d\(index)", tgUserId: self.alice, action: .withdraw, scopes: SGConsentScope.allCases.map(\.rawValue), textVersion: 1, textSha256: nil, locale: .uz, consentMode: .required, ageConfirmed: nil, recordedAt: "2026-11-01T09:0\(index):00Z", appVersion: "12.0.1").encoded()
        }
        let bodies = SGAccountReconcile.finalUploads(pendingWithdraws: withdrawals)
        XCTAssertEqual(bodies.count, SGAccountReconcile.finalUploadLimit)
        XCTAssertEqual(bodies, try withdrawals.suffix(3).map { try XCTUnwrap(SGConsentsRequest.body(events: [$0])) }, "the newest three, oldest of them first")
        for body in bodies {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any])
            XCTAssertEqual((object["consents"] as? [Any])?.count, 1, "one entry per body")
        }
        XCTAssertEqual(SGAccountReconcile.finalUploads(pendingWithdraws: Array(withdrawals.prefix(1))).count, 1)
        XCTAssertEqual(SGAccountReconcile.finalUploads(pendingWithdraws: []), [])

        let grant = SGConsentEvent(consentId: "3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a", tgUserId: self.alice, action: .grant, scopes: SGConsentScope.allCases.map(\.rawValue), textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, ageConfirmed: true, recordedAt: "2026-11-01T08:00:00Z", appVersion: "12.0.1").encoded()
        XCTAssertEqual(SGAccountReconcile.finalUploads(pendingWithdraws: [grant, Data("{}".utf8)]), [], "only withdrawals, only valid events")
    }
}
