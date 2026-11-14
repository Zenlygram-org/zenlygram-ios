import XCTest
@testable import SGEntitlement

/// Zenlygram — the headless attested bind (`bindWithTelegramAttestation`) over its injected steps:
/// what is sent and in which order, the poll cadence on a scripted clock, how every server answer
/// is classified, that a consent withdrawn mid-run stops it before its next step, and that every
/// exit which does not link ends the attempt it began. Nothing here sleeps for real or reaches a
/// network.
final class SGEntitlementAttestedBindTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// The scripted outside world of one run: the answers, a clock that only `sleep` moves, and
    /// everything the flow did.
    private final class Script: @unchecked Sendable {
        var begin: Result<SGEntitlementBindStart, SGEntitlementRequestError>
        var evidence: SGEntitlementAttestEvidence = .initData("user=%7B%22id%22%3A1%7D&hash=fixture")
        var postAttest: Result<Bool, SGEntitlementRequestError> = .success(true)
        /// Popped per poll; when empty every poll is `.pending`.
        var polls: [Result<SGEntitlementBindPollResult, SGEntitlementRequestError>] = []
        var completion: SGEntitlementAttestedBindFlow.Completion = .stored
        var isCurrent = true
        /// `bindPermission == .allowed`; a withdrawal turns it false.
        var permitted = true
        /// What changes while the `nth` call (from 1) of `step` is in flight — "begin", "attest",
        /// "postAttest" or "poll" — applied before that step answers.
        var whileInFlight: (step: String, nth: Int, change: (Script) -> Void)?
        var jitter: Double = 0.5
        var now: Date

        private(set) var log: [String] = []
        /// `log` with every permission read in place, as "permitted?".
        private(set) var trace: [String] = []
        private(set) var pollTimes: [TimeInterval] = []
        private(set) var sleeps: [TimeInterval] = []
        private(set) var ended = 0
        private(set) var postedInitData: [String] = []
        private let origin: Date

        init(begin: Result<SGEntitlementBindStart, SGEntitlementRequestError>, now: Date) {
            self.begin = begin
            self.now = now
            self.origin = now
        }

        /// Logs `step` and applies `whileInFlight` when this is its call.
        private func call(_ step: String) {
            self.log.append(step)
            self.trace.append(step)
            if let change = self.whileInFlight, change.step == step, self.log.filter({ $0 == step }).count == change.nth {
                change.change(self)
            }
        }

        func flow() -> SGEntitlementAttestedBindFlow {
            return SGEntitlementAttestedBindFlow(
                begin: {
                    self.call("begin")
                    return self.begin
                },
                attest: { _ in
                    self.call("attest")
                    return self.evidence
                },
                postAttest: { _, initData in
                    self.postedInitData.append(initData)
                    self.call("postAttest")
                    return self.postAttest
                },
                poll: { _ in
                    self.pollTimes.append(self.now.timeIntervalSince(self.origin))
                    self.call("poll")
                    return self.polls.isEmpty ? .success(.pending) : self.polls.removeFirst()
                },
                isCurrent: { _ in
                    return self.isCurrent
                },
                permitted: {
                    self.trace.append("permitted?")
                    return self.permitted
                },
                complete: { _, _ in
                    self.call("complete")
                    return self.completion
                },
                endAttempt: { _ in
                    self.ended += 1
                },
                sleep: { seconds in
                    self.sleeps.append(seconds)
                    self.now = self.now.addingTimeInterval(seconds)
                },
                now: {
                    return self.now
                },
                jitter: {
                    return self.jitter
                }
            )
        }
    }

    private func start(attest: Bool = true, expiresIn: TimeInterval = 300) throws -> SGEntitlementBindStart {
        let expiresAt = SGEntitlementTimestamp.string(from: self.t0.addingTimeInterval(expiresIn))
        let attestBlock = attest ? #","attest":{"bot_id":"8804541158","bot_username":"ZenlyPremiumbot","start_param":"zbABCDEFGH","url":"https://zenlygram.org/app"}"# : ""
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SGEntitlementBindStart.self, from: Data(#"{"code":"ABCDEFGH","deeplink":null,"poll_token":"poll-token","expires_at":"\#(expiresAt)"\#(attestBlock)}"#.utf8))
    }

    private func confirmation(mergeConflict: Bool? = nil) -> SGEntitlementBindConfirmation {
        return SGEntitlementBindConfirmation(
            refreshToken: "tok",
            entitlement: "jws",
            account: SGEntitlementBindAccount(id: "01JB8Q", tgUserId: 9_100_000_001, status: "paid", until: nil),
            device: SGEntitlementBindDevice(id: "01JB8R"),
            mergeConflict: mergeConflict
        )
    }

    private func error(_ status: Int, _ code: String, retryAfter: Int? = nil) -> SGEntitlementRequestError {
        return SGEntitlementRequestError(failure: SGEntitlementFailureMapping.classify(status: status, code: code, retryAfter: retryAfter), retryAfter: retryAfter, status: status, code: code)
    }

    // MARK: - Before anything is sent

    func test_thePreconditionsRunInOrder() {
        let check = SGEntitlementAttestedBindFlow.preflight
        XCTAssertEqual(check(false, true, .allowed, false, false), .notConfigured, "an extension")
        XCTAssertEqual(check(true, false, .allowed, false, false), .notConfigured, "no client")
        XCTAssertEqual(check(true, true, .codeOnly, false, false), .notPermitted)
        XCTAssertEqual(check(true, true, .refused, true, true), .notPermitted, "permission before anything else about the account")
        XCTAssertEqual(check(true, true, .allowed, true, true), .alreadyLinked)
        XCTAssertEqual(check(true, true, .allowed, false, true), .bindInProgress)
        XCTAssertNil(check(true, true, .allowed, false, false))
    }

    func test_theEntitlementRefusesWithoutSendingAnything() async throws {
        let storeSuite = "SGEntitlementAttestedBindTests.store.\(UUID().uuidString)"
        let schedulerSuite = "SGEntitlementAttestedBindTests.scheduler.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: storeSuite)?.removePersistentDomain(forName: storeSuite)
            UserDefaults(suiteName: schedulerSuite)?.removePersistentDomain(forName: schedulerSuite)
            SGEntitlementPathStubProtocol.reset()
        }
        SGEntitlementPathStubProtocol.reset()
        let store = SGEntitlementOwnedStore.make(suiteName: storeSuite)
        let entitlement = SGEntitlement(store: store, scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: schedulerSuite)))
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://api.attested.zenlygram.invalid/v1")!)
        configuration.protocolClasses = [SGEntitlementPathStubProtocol.self]
        entitlement.installClientForTesting(SGEntitlementClient(configuration: configuration, store: store))
        let telegram: (SGEntitlementBindAttest) async -> SGEntitlementAttestEvidence = { _ in
            XCTFail("Telegram is never asked when the flow may not run")
            return .unavailable(reason: "unexpected")
        }

        entitlement.bindPermissionProvider = { _ in .codeOnly }
        let codeOnly = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: telegram)
        XCTAssertEqual(codeOnly, .notPermitted, "a code-only account never attests")
        entitlement.bindPermissionProvider = nil

        let attempt = entitlement.newBindAttempt(accountPeerId: self.account, purpose: .manual) // the Link screen's
        let inProgress = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: telegram)
        XCTAssertEqual(inProgress, .bindInProgress)
        XCTAssertTrue(entitlement.isCurrentBindAttempt(attempt), "the live manual attempt is left alone")
        entitlement.endBindAttempt(attempt)

        store.updateSession(accountPeerId: self.account) { material in
            material.refreshToken = "tok-1"
        }
        let linked = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: telegram)
        XCTAssertEqual(linked, .alreadyLinked)
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded.isEmpty)
        store.clearSession(accountPeerId: self.account)
    }

    // MARK: - The attestation

    func test_aStartWithoutAUsableAttestBlockEndsAsAttestUnavailableWithoutAskingAnyone() async throws {
        let script = Script(begin: .success(try self.start(attest: false)), now: self.t0)
        let outcome = await script.flow().run()
        XCTAssertEqual(outcome, .attestUnavailable)
        XCTAssertEqual(script.log, ["begin"], "neither Telegram nor the server is asked")
        XCTAssertEqual(script.ended, 1)
    }

    func test_telegramWithoutInitDataEndsBeforeTheServerIsAsked() async throws {
        let script = Script(begin: .success(try self.start()), now: self.t0)
        script.evidence = .unavailable(reason: "attest_no_main_app")
        let outcome = await script.flow().run()
        XCTAssertEqual(outcome, .telegramUnavailable(reason: "attest_no_main_app"))
        XCTAssertEqual(script.log, ["begin", "attest"])
        XCTAssertEqual(script.ended, 1)
    }

    func test_aConfirmedAttestationPollsAtOnceThenOneSecondApartThenEveryThreeSecondsUntilExpiry() async throws {
        let script = Script(begin: .success(try self.start(expiresIn: 12)), now: self.t0)
        script.jitter = 0.5
        let outcome = await script.flow().run()
        XCTAssertEqual(outcome, .expired, "every poll pending until the start expired")
        XCTAssertEqual(script.postedInitData, ["user=%7B%22id%22%3A1%7D&hash=fixture"], "Telegram's initData is posted unchanged")
        XCTAssertEqual(script.pollTimes, [0, 1, 2, 5.5, 9], "at once, +1 s, +1 s, then 3 s + jitter")
        XCTAssertEqual(script.sleeps, [1, 1, 3.5, 3.5], "the next poll (12.5 s) would only go out after expiry: never waited for")
        XCTAssertEqual(script.ended, 1)
        XCTAssertEqual(Array(script.log.prefix(3)), ["begin", "attest", "postAttest"])
    }

    func test_theJitterStaysWithinItsBand() async throws {
        for jitter in [-0.4, 0.8] {
            let script = Script(begin: .success(try self.start(expiresIn: 20)), now: self.t0)
            script.jitter = jitter
            _ = await script.flow().run()
            XCTAssertEqual(Array(script.sleeps.prefix(3)), [1, 1, 3 + jitter])
        }
        XCTAssertEqual(SGEntitlementAttestedBindFlow.pollJitter, -0.4 ... 0.8)
    }

    func test_aConfirmationIsStoredAndLinks() async throws {
        let script = Script(begin: .success(try self.start()), now: self.t0)
        script.polls = [.success(.pending), .success(.pending), .success(.pending), .success(.confirmed(self.confirmation(mergeConflict: true)))]
        let outcome = await script.flow().run()
        XCTAssertEqual(outcome, .linked(mergeConflict: true))
        XCTAssertEqual(script.pollTimes, [0, 1, 2, 5.5])
        XCTAssertEqual(script.log.last, "complete")
        XCTAssertEqual(script.ended, 0, "a stored bind's attempt is the bind's own business")
    }

    func test_aConfirmationThatCannotBeStoredIsNotStoredOrSuperseded() async throws {
        for (completion, expected) in [(SGEntitlementAttestedBindFlow.Completion.notStored, SGEntitlementAttestedBindOutcome.notStored), (.superseded, .superseded)] {
            let script = Script(begin: .success(try self.start()), now: self.t0)
            script.polls = [.success(.confirmed(self.confirmation()))]
            script.completion = completion
            let outcome = await script.flow().run()
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(script.ended, 1, "\(expected): the attempt is ended")
        }
    }

    func test_aNewerBindStopsTheFlowBeforeItPostsOrPolls() async throws {
        let script = Script(begin: .success(try self.start()), now: self.t0)
        script.isCurrent = false
        let outcome = await script.flow().run()
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(script.log, ["begin"], "a superseded start never asks Telegram and is never confirmed")

        let late = Script(begin: .success(try self.start()), now: self.t0)
        late.whileInFlight = ("attest", 1, { $0.isCurrent = false })
        let lateOutcome = await late.flow().run()
        XCTAssertEqual(lateOutcome, .superseded)
        XCTAssertEqual(late.log, ["begin", "attest"], "replaced while Telegram was asked: never posted")
        XCTAssertEqual(late.ended, 1)
    }

    // MARK: - A withdrawal while the run is in flight

    /// The consent is withdrawn (`bindPermission` turns `.refused` / `.codeOnly`) while `step` is in
    /// flight: nothing after it reaches Telegram or the server, nothing is stored, the attempt ends.
    private func withdrawn(during step: String, nth: Int = 1, polls: [Result<SGEntitlementBindPollResult, SGEntitlementRequestError>] = []) async throws -> Script {
        let script = Script(begin: .success(try self.start()), now: self.t0)
        script.polls = polls
        script.whileInFlight = (step, nth, { $0.permitted = false })
        let outcome = await script.flow().run()
        XCTAssertEqual(outcome, .notPermitted, "withdrawn during \(step) #\(nth)")
        XCTAssertFalse(script.log.contains("complete"), "withdrawn during \(step) #\(nth): nothing is stored")
        XCTAssertEqual(script.ended, 1, "withdrawn during \(step) #\(nth): the attempt is ended")
        return script
    }

    func test_aWithdrawalDuringTheStartStopsTheRunBeforeTelegramIsAsked() async throws {
        let script = try await self.withdrawn(during: "begin")
        XCTAssertEqual(script.log, ["begin"], "no Mini App request is made as the account")
    }

    func test_aWithdrawalWhileTelegramIsAskedKeepsTheInitDataOnTheDevice() async throws {
        let script = try await self.withdrawn(during: "attest")
        XCTAssertEqual(script.log, ["begin", "attest"])
        XCTAssertEqual(script.postedInitData, [], "no /bind/attest")
    }

    func test_aWithdrawalWhileTheAttestationIsPostedStopsBeforeAnyPoll() async throws {
        let script = try await self.withdrawn(during: "postAttest")
        XCTAssertEqual(script.log, ["begin", "attest", "postAttest"], "the confirmed bind is never consumed: it expires on the server")
        XCTAssertEqual(script.pollTimes, [])
    }

    func test_aWithdrawalBetweenPollsStopsTheNextPoll() async throws {
        let script = try await self.withdrawn(during: "poll", nth: 2)
        XCTAssertEqual(script.pollTimes, [0, 1], "the third poll never goes out")
    }

    func test_aConfirmationThatArrivesAfterAWithdrawalIsNeverStored() async throws {
        let script = try await self.withdrawn(during: "poll", polls: [.success(.confirmed(self.confirmation()))])
        XCTAssertEqual(script.log, ["begin", "attest", "postAttest", "poll"], "never completed")
    }

    func test_thePermissionIsReadAgainBeforeEveryStepAfterTheStart() async throws {
        let script = Script(begin: .success(try self.start()), now: self.t0)
        script.polls = [.success(.pending), .success(.confirmed(self.confirmation()))]
        let outcome = await script.flow().run()
        XCTAssertEqual(outcome, .linked(mergeConflict: false), "a permission that stays allowed never stops the run")
        XCTAssertEqual(script.trace, ["begin", "permitted?", "attest", "permitted?", "postAttest", "permitted?", "poll", "permitted?", "poll", "permitted?", "complete"])
    }

    /// `bindPermission`'s answer, changed by a test while a run is in flight.
    private final class Permission: @unchecked Sendable {
        private let lock = NSLock()
        private var current: SGEntitlementBindPermission = .allowed

        var value: SGEntitlementBindPermission {
            get {
                self.lock.lock()
                defer {
                    self.lock.unlock()
                }
                return self.current
            }
            set {
                self.lock.lock()
                self.current = newValue
                self.lock.unlock()
            }
        }
    }

    /// The same on the entitlement's own wiring (`permitted` reads `bindPermission(accountPeerId:)`):
    /// the user withdraws while `/bind/start` is in flight, or while Telegram is asked as the account.
    func test_theEntitlementsAttestedBindStopsWhenTheConsentIsWithdrawnMidRun() async throws {
        let storeSuite = "SGEntitlementAttestedBindTests.store.\(UUID().uuidString)"
        let schedulerSuite = "SGEntitlementAttestedBindTests.scheduler.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: storeSuite)?.removePersistentDomain(forName: storeSuite)
            UserDefaults(suiteName: schedulerSuite)?.removePersistentDomain(forName: schedulerSuite)
            SGEntitlementPathStubProtocol.reset()
        }
        let store = SGEntitlementOwnedStore.make(suiteName: storeSuite)
        // `beginBind` needs the install key for `device_pubkey`; the logic-test host has no keychain.
        let identity = SGEntitlementDeviceIdentity.forTesting(store: store)
        _ = try XCTUnwrap(identity.publicKeySPKIBase64(), "the owned store could not hold an install key")
        let entitlement = SGEntitlement(store: store, identity: identity, scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: schedulerSuite)), isExtensionProcess: false)
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://api.attested.zenlygram.invalid/v1")!)
        configuration.protocolClasses = [SGEntitlementPathStubProtocol.self]
        entitlement.installClientForTesting(SGEntitlementClient(configuration: configuration, store: store, identity: identity))
        // A short-lived start, so a run that wrongly went on to poll would end within seconds.
        let answers: () -> [String: [SGEntitlementPathStubProtocol.Response]] = {
            return [
                "/v1/bind/start": [.json(200, [
                    "code": "ABCDEFGH",
                    "poll_token": "poll-token",
                    "expires_at": SGEntitlementTimestamp.string(from: Date().addingTimeInterval(5)),
                    "attest": ["bot_id": "8804541158", "bot_username": "ZenlyPremiumbot", "start_param": "zbABCDEFGH", "url": "https://zenlygram.org/app"]
                ])],
                "/v1/bind/attest": [.json(200, ["state": "confirmed"])]
            ]
        }

        for withdrawn in [SGEntitlementBindPermission.refused, .codeOnly] {
            let permission = Permission()
            entitlement.bindPermissionProvider = { _ in
                return permission.value
            }

            // While `/bind/start` is in flight: the grant it carries is read as it goes out.
            SGEntitlementPathStubProtocol.reset(answers())
            entitlement.bindConsentProvider = { _ in
                permission.value = withdrawn
                return ["consent_id": "c-1", "action": "grant"]
            }
            let duringStart = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: { _ in
                XCTFail("\(withdrawn): Telegram is never asked after the withdrawal")
                return .unavailable(reason: "unexpected")
            })
            XCTAssertEqual(duringStart, .notPermitted, "\(withdrawn)")
            XCTAssertEqual(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/start").count, 1)
            XCTAssertTrue(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/attest").isEmpty, "\(withdrawn)")
            XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account), "\(withdrawn): the attempt is ended")

            // While Telegram is asked: its `initData` never reaches `/bind/attest`.
            SGEntitlementPathStubProtocol.reset(answers())
            entitlement.bindConsentProvider = nil
            permission.value = .allowed
            let duringAttest = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: { _ in
                permission.value = withdrawn
                return .initData("user=%7B%22id%22%3A1%7D&hash=fixture")
            })
            XCTAssertEqual(duringAttest, .notPermitted, "\(withdrawn)")
            XCTAssertEqual(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/start").count, 1)
            XCTAssertTrue(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/attest").isEmpty, "\(withdrawn): no /bind/attest")
            XCTAssertTrue(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/poll").isEmpty, "\(withdrawn): no poll")
            XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account), "\(withdrawn): the attempt is ended")
            XCTAssertFalse(entitlement.isLinked(accountPeerId: self.account), "\(withdrawn): nothing is stored")
        }
        entitlement.bindPermissionProvider = nil
    }

    // MARK: - A withdrawal while beginBind waits, or before its consent-fallback retry

    /// What a scripted answer or a hook saw, from whichever thread it ran on.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            self.lock.lock()
            self.values.append(value)
            self.lock.unlock()
        }

        var all: [String] {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.values
        }
    }

    /// The defaults suites of one test; `remove()` also clears the stub's script.
    private struct Suites {
        let store = "SGEntitlementAttestedBindTests.store.\(UUID().uuidString)"
        let scheduler = "SGEntitlementAttestedBindTests.scheduler.\(UUID().uuidString)"

        func remove() {
            UserDefaults(suiteName: self.store)?.removePersistentDomain(forName: self.store)
            UserDefaults(suiteName: self.scheduler)?.removePersistentDomain(forName: self.scheduler)
            SGEntitlementPathStubProtocol.reset()
        }
    }

    /// The wiring of the test above over `suites`: an owned store, the install key over it, a client
    /// on the path stub, and `permission` as `bindPermission`.
    private func wired(_ suites: Suites, permission: Permission) throws -> (entitlement: SGEntitlement, store: SGEntitlementStore) {
        let store = SGEntitlementOwnedStore.make(suiteName: suites.store)
        let identity = SGEntitlementDeviceIdentity.forTesting(store: store)
        _ = try XCTUnwrap(identity.publicKeySPKIBase64(), "the owned store could not hold an install key")
        let entitlement = SGEntitlement(store: store, identity: identity, scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: suites.scheduler)), isExtensionProcess: false)
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://api.attested.zenlygram.invalid/v1")!)
        configuration.protocolClasses = [SGEntitlementPathStubProtocol.self]
        entitlement.installClientForTesting(SGEntitlementClient(configuration: configuration, store: store, identity: identity))
        entitlement.bindPermissionProvider = { _ in
            return permission.value
        }
        return (entitlement, store)
    }

    /// The attest start of the test above, valid for 5 s.
    private var attestStart: SGEntitlementPathStubProtocol.Response {
        return .json(200, [
            "code": "ABCDEFGH",
            "poll_token": "poll-token",
            "expires_at": SGEntitlementTimestamp.string(from: Date().addingTimeInterval(5)),
            "attest": ["bot_id": "8804541158", "bot_username": "ZenlyPremiumbot", "start_param": "zbABCDEFGH", "url": "https://zenlygram.org/app"]
        ])
    }

    /// Scripts `/bind/start` with `starts` and leaves a logout's `/bind/revoke` pending (a fresh
    /// session, then `logout`). The revoke is answered only once a bind attempt of the account has
    /// begun — `beginBind` begins it right after its first permission read and before it awaits the
    /// revoke — and only after the permission turned `change`, so the change happens while that
    /// `beginBind` waits. The recorder says, once, whether the attempt was seen within 5 s.
    /// `whileWaiting`, when given, runs right after the change, still before the revoke is answered.
    private func pendingRevoke(_ entitlement: SGEntitlement, store: SGEntitlementStore, permission: Permission, change: SGEntitlementBindPermission, starts: [SGEntitlementPathStubProtocol.Response], whileWaiting: (() -> Void)? = nil) -> Recorder {
        let served = Recorder()
        let account = self.account
        var revoke = SGEntitlementPathStubProtocol.Response.json(200, ["ok": true])
        revoke.onServe = {
            let deadline = Date().addingTimeInterval(5)
            var began = entitlement.isBindInProgress(accountPeerId: account)
            while !began, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
                began = entitlement.isBindInProgress(accountPeerId: account)
            }
            served.append(began ? "attempt began" : "timed out")
            permission.value = change
            whileWaiting?()
        }
        SGEntitlementPathStubProtocol.reset(["/v1/bind/revoke": [revoke], "/v1/bind/start": starts])
        let seeded = store.updateSession(accountPeerId: account) { material in
            material.refreshToken = "tok-\(UUID().uuidString)"
        }
        if case .failure = seeded {
            XCTFail("the owned store could not hold the session: \(seeded)")
        }
        entitlement.logout(accountPeerId: account)
        return served
    }

    /// The JSON body of every `/bind/start` that reached the origin, in order.
    private func startBodies() -> [[String: Any]] {
        return SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/start").map { recorded in
            return recorded.body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        }
    }

    /// The consent is withdrawn while `beginBind` waits for a logout's pending `/bind/revoke` (its
    /// final send, then the revoke): the permission is read again once the wait is over, so the
    /// automatic link sends no `/bind/start` at all.
    func test_aWithdrawalWhileALogoutsRevokeIsPendingSendsNoAutomaticStart() async throws {
        let suites = Suites()
        defer {
            suites.remove()
        }
        let permission = Permission()
        let (entitlement, store) = try self.wired(suites, permission: permission)
        for withdrawn in [SGEntitlementBindPermission.refused, .codeOnly] {
            permission.value = .allowed
            let served = self.pendingRevoke(entitlement, store: store, permission: permission, change: withdrawn, starts: [self.attestStart])
            let outcome = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: { _ in
                XCTFail("\(withdrawn): Telegram is never asked after the withdrawal")
                return .unavailable(reason: "unexpected")
            })
            XCTAssertEqual(served.all, ["attempt began"], "\(withdrawn): withdrawn while the run waited (the wait did not time out)")
            XCTAssertEqual(outcome, .notPermitted, "\(withdrawn)")
            XCTAssertEqual(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/revoke").count, 1, "\(withdrawn): the logout's revoke was pending")
            XCTAssertTrue(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/start").isEmpty, "\(withdrawn): no automatic /bind/start after the withdrawal")
            XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account), "\(withdrawn): the attempt is ended")
        }
    }

    /// A MANUAL start after the same wait goes out with what the permission allows by then: under
    /// `.codeOnly` the code flow still starts, without the grant; under `.refused` nothing is sent.
    func test_aManualStartAfterARevokeWaitCarriesOnlyWhatThePermissionAllowsThen() async throws {
        let suites = Suites()
        defer {
            suites.remove()
        }
        let permission = Permission()
        let (entitlement, store) = try self.wired(suites, permission: permission)
        entitlement.bindConsentProvider = { _ in
            return ["consent_id": "c-1", "action": "grant"]
        }

        permission.value = .allowed
        let codeOnlyServed = self.pendingRevoke(entitlement, store: store, permission: permission, change: .codeOnly, starts: [self.attestStart])
        let codeOnly = await entitlement.beginBind(accountPeerId: self.account, purpose: .manual)
        XCTAssertEqual(codeOnlyServed.all, ["attempt began"], "withdrawn while beginBind waited")
        guard case .success = codeOnly else {
            return XCTFail("the code flow still starts under .codeOnly: \(codeOnly)")
        }
        let bodies = self.startBodies()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertNotNil(bodies.first?["device_pubkey"], "the start's body was read")
        XCTAssertNil(bodies.first?["consent"], "the grant withdrawn during the wait is not attached")

        permission.value = .allowed
        let refusedServed = self.pendingRevoke(entitlement, store: store, permission: permission, change: .refused, starts: [self.attestStart])
        let refused = await entitlement.beginBind(accountPeerId: self.account, purpose: .manual)
        XCTAssertEqual(refusedServed.all, ["attempt began"], "withdrawn while beginBind waited")
        guard case let .failure(error) = refused else {
            return XCTFail("a refused account sends no start: \(refused)")
        }
        XCTAssertEqual(error.failure, .unknownRefusal(code: "consent_required_local", status: 0))
        XCTAssertEqual(error.code, SGEntitlement.consentRequiredLocalCode)
        XCTAssertNil(error.status, "nothing was sent")
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/start").isEmpty)
        XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account), "the attempt is ended")
    }

    /// A grant made while `beginBind` waits is not attached: a consent needs BOTH reads `.allowed`
    /// (the grant still reaches `/v1/profile/consents` after the link). Holds with the second read
    /// and without it: it pins the both-reads rule.
    func test_aGrantMadeDuringTheWaitIsNotAttached() async throws {
        let suites = Suites()
        defer {
            suites.remove()
        }
        let permission = Permission()
        let (entitlement, store) = try self.wired(suites, permission: permission)
        entitlement.bindConsentProvider = { _ in
            return ["consent_id": "c-1", "action": "grant"]
        }

        permission.value = .codeOnly
        let served = self.pendingRevoke(entitlement, store: store, permission: permission, change: .allowed, starts: [self.attestStart])
        let result = await entitlement.beginBind(accountPeerId: self.account, purpose: .manual)
        XCTAssertEqual(served.all, ["attempt began"], "granted while beginBind waited")
        guard case .success = result else {
            return XCTFail("the code flow starts: \(result)")
        }
        let bodies = self.startBodies()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertNotNil(bodies.first?["device_pubkey"], "the start's body was read")
        XCTAssertNil(bodies.first?["consent"], "the grant made during the wait is not attached")
    }

    /// `beginBind(purpose: .auto)` called directly: the automatic link starts only while the
    /// permission is `.allowed` (C§6.6), never under `.codeOnly`.
    func test_anAutomaticStartNeedsAnAllowedPermission() async throws {
        let suites = Suites()
        defer {
            suites.remove()
        }
        let permission = Permission()
        let (entitlement, _) = try self.wired(suites, permission: permission)
        permission.value = .codeOnly
        SGEntitlementPathStubProtocol.reset(["/v1/bind/start": [self.attestStart]])
        let result = await entitlement.beginBind(accountPeerId: self.account, purpose: .auto)
        guard case let .failure(error) = result else {
            return XCTFail("a code-only account never starts the automatic link: \(result)")
        }
        XCTAssertEqual(error.failure, .unknownRefusal(code: "consent_required_local", status: 0))
        XCTAssertEqual(error.code, SGEntitlement.consentRequiredLocalCode)
        XCTAssertNil(error.status, "nothing was sent")
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded.isEmpty)
        XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account), "no attempt began")
    }

    /// The consent is withdrawn while an automatic start that carried the grant is answered 422
    /// `invalid_consent`: the refused consent is still reported, but the retry without the consent
    /// never goes out.
    func test_aWithdrawalBeforeAnAutomaticConsentFallbackRetrySendsNoSecondStart() async throws {
        let suites = Suites()
        defer {
            suites.remove()
        }
        let permission = Permission()
        let (entitlement, _) = try self.wired(suites, permission: permission)
        entitlement.bindConsentProvider = { _ in
            return ["consent_id": "c-1", "action": "grant"]
        }
        for withdrawn in [SGEntitlementBindPermission.refused, .codeOnly] {
            permission.value = .allowed
            let refusals = Recorder()
            entitlement.bindConsentRefused = { account, consentId in
                refusals.append("\(account):\(consentId)")
            }
            var invalid = SGEntitlementPathStubProtocol.Response.json(422, ["error": "invalid_consent", "message": "m"])
            invalid.onServe = {
                permission.value = withdrawn
            }
            SGEntitlementPathStubProtocol.reset(["/v1/bind/start": [invalid, self.attestStart]])
            let outcome = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: { _ in
                XCTFail("\(withdrawn): Telegram is never asked after the withdrawal")
                return .unavailable(reason: "unexpected")
            })
            XCTAssertEqual(outcome, .notPermitted, "\(withdrawn)")
            let bodies = self.startBodies()
            XCTAssertEqual(bodies.count, 1, "\(withdrawn): no second /bind/start without the consent")
            XCTAssertEqual((bodies.first?["consent"] as? [String: Any])?["consent_id"] as? String, "c-1", "\(withdrawn): the first start carried the grant")
            XCTAssertEqual(refusals.all, ["\(self.account):c-1"], "\(withdrawn): the store still learns which consent was refused")
            XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account), "\(withdrawn): the attempt is ended")
        }
    }

    // MARK: - A newer attempt while beginBind waits, or before its consent-fallback retry

    /// A newer bind attempt begins while an automatic start waits for a logout's pending
    /// `/bind/revoke` (as a Link screen's `beginBind` begins its own): the replaced start sends no
    /// `/bind/start` (the server keeps one pending bind per device, so it would expire the newer
    /// attempt's) and the run ends `.superseded`; the newer attempt stays in progress.
    func test_aNewerAttemptDuringALogoutsRevokeWaitSendsNoStaleAutomaticStart() async throws {
        let suites = Suites()
        defer {
            suites.remove()
        }
        let permission = Permission()
        let (entitlement, store) = try self.wired(suites, permission: permission)
        let account = self.account
        permission.value = .allowed
        let served = self.pendingRevoke(entitlement, store: store, permission: permission, change: .allowed, starts: [self.attestStart], whileWaiting: {
            _ = entitlement.newBindAttempt(accountPeerId: account, purpose: .manual)
        })
        let outcome = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: { _ in
            XCTFail("Telegram is never asked for a replaced attempt")
            return .unavailable(reason: "unexpected")
        })
        XCTAssertEqual(served.all, ["attempt began"], "the newer attempt began while the run waited (the wait did not time out)")
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/revoke").count, 1, "the logout's revoke was pending")
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/start").isEmpty, "no /bind/start for the replaced attempt")
        XCTAssertTrue(entitlement.isBindInProgress(accountPeerId: self.account), "the newer attempt is untouched")
    }

    /// The same for a MANUAL start: it fails with the local `bind_superseded_local` refusal, nothing
    /// sent, and the newer attempt stays in progress.
    func test_aManualStartReplacedDuringTheWaitFailsLocallyWithoutSending() async throws {
        let suites = Suites()
        defer {
            suites.remove()
        }
        let permission = Permission()
        let (entitlement, store) = try self.wired(suites, permission: permission)
        let account = self.account
        permission.value = .allowed
        let served = self.pendingRevoke(entitlement, store: store, permission: permission, change: .allowed, starts: [self.attestStart], whileWaiting: {
            _ = entitlement.newBindAttempt(accountPeerId: account, purpose: .manual)
        })
        let result = await entitlement.beginBind(accountPeerId: self.account, purpose: .manual)
        XCTAssertEqual(served.all, ["attempt began"], "the newer attempt began while beginBind waited")
        guard case let .failure(error) = result else {
            return XCTFail("a replaced attempt sends no start: \(result)")
        }
        XCTAssertEqual(error.failure, .unknownRefusal(code: "bind_superseded_local", status: 0))
        XCTAssertEqual(error.code, SGEntitlement.bindSupersededLocalCode)
        XCTAssertNil(error.status, "nothing was sent")
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded(path: "/v1/bind/start").isEmpty)
        XCTAssertTrue(entitlement.isBindInProgress(accountPeerId: self.account), "the newer attempt is untouched")
    }

    /// A newer attempt begins while an automatic start that carried the grant is answered 422
    /// `invalid_consent`: the refused consent is still reported, but the retry without the consent
    /// never goes out, and the run ends `.superseded`.
    func test_aNewerAttemptBeforeAnAutomaticConsentFallbackRetrySendsNoSecondStart() async throws {
        let suites = Suites()
        defer {
            suites.remove()
        }
        let permission = Permission()
        let (entitlement, _) = try self.wired(suites, permission: permission)
        let account = self.account
        entitlement.bindConsentProvider = { _ in
            return ["consent_id": "c-1", "action": "grant"]
        }
        permission.value = .allowed
        let refusals = Recorder()
        entitlement.bindConsentRefused = { account, consentId in
            refusals.append("\(account):\(consentId)")
        }
        var invalid = SGEntitlementPathStubProtocol.Response.json(422, ["error": "invalid_consent", "message": "m"])
        invalid.onServe = {
            _ = entitlement.newBindAttempt(accountPeerId: account, purpose: .manual)
        }
        SGEntitlementPathStubProtocol.reset(["/v1/bind/start": [invalid, self.attestStart]])
        let outcome = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: { _ in
            XCTFail("Telegram is never asked for a replaced attempt")
            return .unavailable(reason: "unexpected")
        })
        XCTAssertEqual(outcome, .superseded)
        let bodies = self.startBodies()
        XCTAssertEqual(bodies.count, 1, "no second /bind/start for the replaced attempt")
        XCTAssertEqual((bodies.first?["consent"] as? [String: Any])?["consent_id"] as? String, "c-1", "the first start carried the grant")
        XCTAssertEqual(refusals.all, ["\(self.account):c-1"], "the store still learns which consent was refused")
        XCTAssertTrue(entitlement.isBindInProgress(accountPeerId: self.account), "the newer attempt is untouched")
    }

    // MARK: - Classification

    func test_attestAnswersAreClassifiedByTheirCode() async throws {
        let cases: [(SGEntitlementRequestError, SGEntitlementAttestedBindOutcome)] = [
            (self.error(409, "bind_conflict"), .refused(code: "bind_conflict", status: 409)),
            (self.error(422, "attest_invalid"), .refused(code: "attest_invalid", status: 422)),
            (self.error(422, "attest_stale"), .refused(code: "attest_stale", status: 422)),
            (self.error(422, "attest_mismatch"), .refused(code: "attest_mismatch", status: 422)),
            (self.error(404, "bind_not_found"), .refused(code: "bind_not_found", status: 404)),
            (self.error(410, "bind_expired"), .refused(code: "bind_expired", status: 410)),
            (self.error(503, "attest_unavailable"), .attestUnavailable),
            (self.error(503, "bind_paused", retryAfter: 600), .paused(retryAfter: 600)),
            (self.error(429, "rate_limited", retryAfter: 90), .rateLimited(retryAfter: 90)),
            (self.error(409, "consent_stale"), .consentStale),
            (self.error(500, "server_error"), .offline),
            (SGEntitlementRequestError(failure: .offline(.timeout)), .offline),
            (SGEntitlementRequestError(failure: .offline(.unknown), message: "cannot sign bind attest proof; attest not sent"), .offline)
        ]
        for (answer, expected) in cases {
            let script = Script(begin: .success(try self.start()), now: self.t0)
            script.postAttest = .failure(answer)
            let outcome = await script.flow().run()
            XCTAssertEqual(outcome, expected, "\(answer.code ?? "no code")")
            XCTAssertFalse(script.log.contains("poll"), "\(expected): nothing is polled after a refused attestation")
            XCTAssertEqual(script.ended, 1, "\(expected): the attempt is ended")
        }
        let unconfirmed = Script(begin: .success(try self.start()), now: self.t0)
        unconfirmed.postAttest = .success(false)
        let outcome = await unconfirmed.flow().run()
        XCTAssertEqual(outcome, .offline, "a 200 that is not `confirmed` is unreadable")
        XCTAssertEqual(unconfirmed.ended, 1)
    }

    func test_aFailedStartIsClassifiedAndAlreadyEndedItsOwnAttempt() async {
        let cases: [(SGEntitlementRequestError, SGEntitlementAttestedBindOutcome)] = [
            (self.error(409, "consent_stale"), .consentStale),
            (SGEntitlementRequestError(failure: .unknownRefusal(code: "consent_required_local", status: 0), code: "consent_required_local"), .notPermitted),
            (SGEntitlementRequestError(failure: .unknownRefusal(code: "bind_superseded_local", status: 0), code: "bind_superseded_local"), .superseded),
            (self.error(429, "rate_limited", retryAfter: 30), .rateLimited(retryAfter: 30)),
            (self.error(503, "bind_paused"), .paused(retryAfter: nil)),
            (SGEntitlementRequestError(failure: .offline(.noRoute)), .offline),
            (self.error(422, "invalid_pubkey"), .refused(code: "invalid_pubkey", status: 422))
        ]
        for (answer, expected) in cases {
            let script = Script(begin: .failure(answer), now: self.t0)
            let outcome = await script.flow().run()
            XCTAssertEqual(outcome, expected, "\(answer.code ?? "no code")")
            XCTAssertEqual(script.log, ["begin"])
            XCTAssertEqual(script.ended, 0, "beginBind ends a start that failed")
        }
    }

    func test_pollAnswersEndTheFlowOrKeepItWaiting() async throws {
        for terminal in [SGEntitlementBindPollResult.expired, .consumed, .restartBind] {
            let script = Script(begin: .success(try self.start()), now: self.t0)
            script.polls = [.success(.pending), .success(terminal)]
            let outcome = await script.flow().run()
            XCTAssertEqual(outcome, .expired, "\(terminal)")
            XCTAssertEqual(script.ended, 1)
        }
        let denied = Script(begin: .success(try self.start()), now: self.t0)
        denied.polls = [.success(.denied)]
        let deniedOutcome = await denied.flow().run()
        XCTAssertEqual(deniedOutcome, .refused(code: "bind_denied", status: nil))

        let notFound = Script(begin: .success(try self.start()), now: self.t0)
        notFound.polls = [.failure(self.error(404, "bind_not_found"))]
        let notFoundOutcome = await notFound.flow().run()
        XCTAssertEqual(notFoundOutcome, .refused(code: "bind_not_found", status: 404))
        XCTAssertEqual(notFound.ended, 1)

        // A lost answer is not the end: the confirmation may still be waiting on the server.
        let flaky = Script(begin: .success(try self.start()), now: self.t0)
        flaky.polls = [.failure(SGEntitlementRequestError(failure: .offline(.timeout))), .success(.confirmed(self.confirmation()))]
        let flakyOutcome = await flaky.flow().run()
        XCTAssertEqual(flakyOutcome, .linked(mergeConflict: false))

        let offline = Script(begin: .success(try self.start(expiresIn: 3)), now: self.t0)
        offline.polls = Array(repeating: .failure(SGEntitlementRequestError(failure: .offline(.noRoute))), count: 10)
        let offlineOutcome = await offline.flow().run()
        XCTAssertEqual(offlineOutcome, .offline, "still unreachable when the start expired")
        XCTAssertEqual(offline.ended, 1)
    }

    func test_aRateLimitedPollWaitsForItsRetryAfter() async throws {
        let script = Script(begin: .success(try self.start(expiresIn: 60)), now: self.t0)
        script.polls = [.failure(self.error(429, "rate_limited", retryAfter: 20)), .success(.confirmed(self.confirmation()))]
        let outcome = await script.flow().run()
        XCTAssertEqual(outcome, .linked(mergeConflict: false))
        XCTAssertEqual(script.pollTimes, [0, 20], "Retry-After wins over the 1 s cadence")

        let late = Script(begin: .success(try self.start(expiresIn: 30)), now: self.t0)
        late.polls = [.failure(self.error(429, "rate_limited", retryAfter: 3600))]
        let lateOutcome = await late.flow().run()
        XCTAssertEqual(lateOutcome, .rateLimited(retryAfter: 3600), "a wait past the expiry ends the run")
        XCTAssertEqual(late.sleeps, [], "and is never slept")
        XCTAssertEqual(late.ended, 1)
    }
}
