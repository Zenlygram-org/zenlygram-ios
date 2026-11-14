import Foundation

// Zenlygram — Chat Lock Center: host tests of the pure decision layer (wf14-chatlock spec §7 #1–#10).
// Plain-assert `@main`, compiled by Tests/run-host-tests.sh together with Sources/SGChatLockFlowSpec.swift
// and Sources/SGChatLockCenterCopy.swift.

@main
struct SGChatLockFlowSpecTests {
    private static func check(_ condition: Bool, _ message: String = "Assertion failed", line: Int = #line) {
        precondition(condition, "line \(line): \(message)")
    }

    // Packed like `PeerId.toInt64()`: a user is its id, a legacy group is `1 << 32 | id`, a channel
    // `2 << 32 | id` (an id above 2^32 moves its high bits up by 35).
    private static let account: Int64 = 777
    private static let user: Int64 = 1001
    private static let user2: Int64 = 1002
    private static let group: Int64 = (1 << 32) | 2001
    private static let group2: Int64 = (1 << 32) | 2002
    private static let channel: Int64 = (2 << 32) | 3001
    private static let channel2: Int64 = (2 << 32) | 3002
    private static let bigChannel: Int64 = (2 << 32) | (1 << 35) | 5
    private static let secretChat: Int64 = (3 << 32) | 6
    /// Another account's lock: never resolved here.
    private static let foreign: Int64 = 4004
    /// Hidden in this account's Secret Vault.
    private static let hidden: Int64 = 5005

    private static func input(
        master: SGChatLockMasterState = .present,
        masterBiometric: Bool = false,
        locked: Set<Int64> = [],
        hidden: Set<Int64> = [],
        resolved: [Int64: Int64?] = [:],
        recovery: Bool = false,
        pending: Int = 0,
        canAuth: Bool = true,
        biometrics: Bool = true,
        accounts: Int = 1
    ) -> SGChatLockCenterInput {
        return SGChatLockCenterInput(
            masterState: master,
            masterBiometric: masterBiometric,
            lockedIds: locked,
            vaultHidden: hidden,
            accountPeerId: account,
            resolved: resolved,
            needsRecovery: recovery,
            pendingCount: pending,
            canAuthDeviceOwner: canAuth,
            hasBiometrics: biometrics,
            accountCount: accounts
        )
    }

    private static func peerIds(_ rows: [SGChatLockCenterRow]) -> [Int64] {
        return rows.compactMap { row -> Int64? in
            if case let .peer(id) = row {
                return id
            }
            return nil
        }
    }

    private static func hasMasterBiometrics(_ rows: [SGChatLockCenterRow]) -> Bool {
        return rows.contains { row in
            if case .masterBiometrics = row {
                return true
            }
            return false
        }
    }

    private static func hasTurnOffWithoutMaster(_ rows: [SGChatLockCenterRow]) -> Bool {
        return rows.contains { row in
            if case .turnOffWithoutMaster = row {
                return true
            }
            return false
        }
    }

    private static let allActions: [SGChatLockAction] = [
        .lockChat(peerId: user), .armMaster(legacy: false), .armMaster(legacy: true), .changePincode(peerId: user), .removeLock(peerId: user),
        .setBiometrics(true, peerId: user), .setBiometrics(false, peerId: user), .changeMaster,
        .setMasterBiometrics(true), .setMasterBiometrics(false), .turnOff, .turnOffWithoutMaster
    ]

    static func main() {
        recoveryState()
        vaultHidden()
        unreadableState()
        legacyState()
        visibleSet()
        flowInvariants()
        gateSites()
        stableIds()
        removalSet()
        copyAudit()
        onAndOffRows()
        footersVerbatim()
        print("PASS: Chat Lock Center state / rows / visible set / removal set / flow specs / copy audit")
    }

    // MARK: #1 — RECOVERY renders only the notice, the two device-owner actions and the hint

    private static func recoveryState() {
        for canAuth in [true, false] {
            for master in [SGChatLockMasterState.present, .absent, .unreadable] {
                let input = input(master: master, masterBiometric: true, locked: [user, group], resolved: [user: nil, group: nil], recovery: true, pending: 2, canAuth: canAuth)
                check(sgChatLockCenterState(input) == .recovery, "recovery outranks \(master)")
                let rows = sgChatLockCenterRows(input)
                var expected: [SGChatLockCenterRow] = [
                    .recoveryNotice(pendingCount: 2),
                    .recoverySetNewPin(enabled: canAuth),
                    .recoveryTurnOff(enabled: canAuth)
                ]
                if !canAuth {
                    expected.append(.recoveryHint)
                }
                check(rows == expected, "RECOVERY rows for canAuth=\(canAuth), master=\(master)")
                check(peerIds(rows).isEmpty, "no peer rows in RECOVERY")
                check(!rows.contains(.addChat) && !rows.contains(.changeMaster) && !rows.contains(.legacySetMaster) && !rows.contains(.turnOn) && !rows.contains(.turnOff) && !hasMasterBiometrics(rows) && !hasTurnOffWithoutMaster(rows), "no add / manage / master rows in RECOVERY")
            }
        }
    }

    // MARK: #2 — vault-hidden ids never produce rows; the visible set and the picker exclusions

    private static func vaultHidden() {
        for master in [SGChatLockMasterState.present, .absent] {
            let input = input(master: master, locked: [user, hidden, group, channel], hidden: [hidden], resolved: [user: nil, hidden: nil, group: nil, channel: nil])
            let rows = sgChatLockCenterRows(input)
            let listed = peerIds(rows)
            check(!listed.contains(hidden), "vault-hidden id listed (\(master))")
            let visible = SGChatLockVisibleCount.compute(lockedIds: input.lockedIds, accountPeerId: account, isVaultHidden: { $0 == hidden }, resolved: input.resolved)
            check(listed == visible, "rows differ from compute() (\(master))")
            check(visible == [user, group, channel].sorted(), "visible set")
            check(sgChatLockVisibleIds(input) == visible)
            check(sgChatLockPickerExclusions(input) == Set(visible).union([account]), "picker exclusions = visible ∪ {account}")
        }
        // Everything hidden: the list is empty, the footer says so, and nothing names the hidden chat.
        let allHidden = input(locked: [hidden], hidden: [hidden], resolved: [hidden: nil])
        let rows = sgChatLockCenterRows(allHidden)
        check(peerIds(rows).isEmpty)
        check(rows.contains(.lockedChatsFooter(empty: true, otherAccounts: false)))
        check(sgChatLockPickerExclusions(allHidden) == [account])
    }

    // MARK: #3 — UNREADABLE renders only the notice, whatever else the input says

    private static func unreadableState() {
        for locked in [Set<Int64>(), [user], [user, foreign]] {
            for canAuth in [true, false] {
                for biometrics in [true, false] {
                    for accounts in [1, 2] {
                        for masterBiometric in [true, false] {
                            let input = input(master: .unreadable, masterBiometric: masterBiometric, locked: locked, resolved: [user: nil], canAuth: canAuth, biometrics: biometrics, accounts: accounts)
                            check(sgChatLockCenterState(input) == .unreadable)
                            check(sgChatLockCenterRows(input) == [.unreadableNotice], "UNREADABLE rows")
                        }
                    }
                }
            }
        }
        // Precedence: a pending recovery still wins.
        let recovering = input(master: .unreadable, recovery: true, pending: 1)
        check(sgChatLockCenterState(recovering) == .recovery)
        check(sgChatLockCenterRows(recovering).first == .recoveryNotice(pendingCount: 1))
    }

    // MARK: #4 — LEGACY

    private static func legacyState() {
        for canAuth in [true, false] {
            let input = input(master: .absent, locked: [user, group], resolved: [user: nil, group: nil], canAuth: canAuth)
            check(sgChatLockCenterState(input) == .legacy)
            let rows = sgChatLockCenterRows(input)
            check(rows.contains(.legacySetMaster), "legacySetMaster present")
            check(rows.contains(.legacyNotice))
            check(rows.contains(.addChat), "addChat present")
            check(rows.contains(.turnOffWithoutMaster(enabled: canAuth)), "turnOffWithoutMaster enabled == canAuthDeviceOwner")
            check(rows.contains(.legacyTurnOffFooter(deviceAuthHint: !canAuth)))
            check(!rows.contains(.changeMaster), "changeMaster absent")
            check(!hasMasterBiometrics(rows), "masterBiometrics absent")
            check(!rows.contains(.turnOff) && !rows.contains(.turnOffFooter), "master turn-off absent")
            check(!rows.contains(.turnOn))
            check(peerIds(rows) == [user, group].sorted())
        }
        // Only another account's chats are locked (all unresolved here): still LEGACY, no peer rows.
        let foreignOnly = input(master: .absent, locked: [foreign], resolved: [:])
        check(sgChatLockCenterState(foreignOnly) == .legacy)
        let rows = sgChatLockCenterRows(foreignOnly)
        check(peerIds(rows).isEmpty, "unresolved ids never render")
        check(rows.contains(.legacySetMaster) && rows.contains(.addChat) && hasTurnOffWithoutMaster(rows))
        check(rows.contains(.lockedChatsFooter(empty: true, otherAccounts: false)))
        // No locked ids and no master: OFF, not LEGACY.
        check(sgChatLockCenterState(input(master: .absent)) == .off)
    }

    // MARK: #5 — compute()

    private static func visibleSet() {
        let locked: Set<Int64> = [account, user, user2, group, channel, foreign, hidden, bigChannel]
        let resolved: [Int64: Int64?] = [account: nil, user: nil, user2: nil, group: channel, channel: nil, hidden: nil, bigChannel: nil]
        let visible = SGChatLockVisibleCount.compute(lockedIds: locked, accountPeerId: account, isVaultHidden: { $0 == hidden }, resolved: resolved)
        check(visible == [user, user2, channel, bigChannel].sorted(), "visible set drops account / unresolved / migrated / hidden")
        check(!visible.contains(account), "account peer dropped even though locked")
        check(!visible.contains(foreign), "unresolved dropped")
        check(!visible.contains(group), "legacy group with a migration target dropped")
        check(!visible.contains(hidden), "vault-hidden dropped")
        check(visible.count >= 0 && visible.count <= locked.count, "never negative, never more than locked")
        check(visible == SGChatLockVisibleCount.compute(lockedIds: locked, accountPeerId: account, isVaultHidden: { $0 == hidden }, resolved: resolved), "deterministic")
        check(visible == visible.sorted(), "sorted")
        check(SGChatLockVisibleCount.compute(lockedIds: [], accountPeerId: account, isVaultHidden: { _ in false }, resolved: [:]).isEmpty)
        check(SGChatLockVisibleCount.compute(lockedIds: [account], accountPeerId: account, isVaultHidden: { _ in false }, resolved: [account: nil]).isEmpty, "account alone → empty")
        // A legacy group WITHOUT a migration target stays visible.
        check(SGChatLockVisibleCount.compute(lockedIds: [group], accountPeerId: account, isVaultHidden: { _ in false }, resolved: [group: nil]) == [group])
    }

    // MARK: #6 — flow spec invariants

    private static func flowInvariants() {
        for action in allActions {
            for masterExists in [true, false] {
                for hasBiometrics in [true, false] {
                    let steps = sgChatLockFlow(for: action, masterExists: masterExists, hasBiometrics: hasBiometrics)
                    check(!steps.isEmpty, "empty flow for \(action)")
                    let ladder = sgChatLockMasterLadder(for: action, masterExists: masterExists)
                    var turnsOffCount = 0
                    var deviceOwnerCount = 0
                    for step in steps {
                        switch step {
                        case let .verify(scope, purpose, recovery, isMasterRecovery, biometricEnabled, turnsOffChatLock, subtitleKey):
                            switch scope {
                            case let .chat(id):
                                check(id == user, "per-chat verify names the chat (\(action))")
                                check(purpose == .manage, "per-chat verify is .manage (\(action))")
                                check(!isMasterRecovery && !turnsOffChatLock, "per-chat verify is not a master screen (\(action))")
                                check((recovery == .masterPin) == masterExists, ".masterPin iff a master exists (\(action), master=\(masterExists))")
                                check(recovery != .resetChatLock)
                                if recovery == .masterPin {
                                    check(ladder != nil, "a .masterPin verify has a ladder (\(action))")
                                }
                            case .master:
                                check(isMasterRecovery, "master verify carries isMasterRecovery (\(action))")
                                check(recovery == .resetChatLock, "master verify carries .resetChatLock (\(action))")
                                if action == .turnOff {
                                    check(purpose == .unlock && turnsOffChatLock && biometricEnabled == hasBiometrics, "turnOff verify is today's Settings screen")
                                } else {
                                    check(purpose == .manage, "master management verify is .manage (\(action))")
                                }
                            }
                            if purpose == .manage {
                                check(!biometricEnabled, "manage verify never offers biometrics (\(action))")
                            }
                            if turnsOffChatLock {
                                turnsOffCount += 1
                                check(action == .turnOff, "turnsOffChatLock only in turnOff")
                            }
                            check(subtitleKey.isEmpty || SGChatLockCopyKey(rawValue: subtitleKey) != nil, "subtitle key is a copy key (\(action))")
                        case let .set(scope, captionKey):
                            guard let key = SGChatLockCopyKey(rawValue: captionKey) else {
                                check(false, "caption key is a copy key (\(action))")
                                return
                            }
                            switch scope {
                            case let .chat(id):
                                check(id == user, "per-chat set names the chat (\(action))")
                                check(key == .captionChat || key == .captionNewChat, "per-chat set caption (\(action))")
                            case .master:
                                check(key == .captionMaster || key == .captionNewMaster, "master set caption (\(action))")
                            }
                        case .deviceOwnerTurnOff:
                            deviceOwnerCount += 1
                            check(action == .turnOffWithoutMaster, "deviceOwnerTurnOff only in turnOffWithoutMaster")
                        case .gate, .explainer, .write:
                            break
                        }
                    }
                    check((action == .turnOff) == (turnsOffCount == 1), "turnOff has exactly one turnsOffChatLock verify")
                    check((action == .turnOffWithoutMaster) == (deviceOwnerCount == 1), "turnOffWithoutMaster has exactly one deviceOwnerTurnOff")

                    // The master ladder: present iff a master exists and the action has one; always the
                    // same invariants; its caption matches the action.
                    let expectedLadderKey: SGChatLockCopyKey?
                    switch action {
                    case .changePincode:
                        expectedLadderKey = .masterLadderForChange
                    case .removeLock:
                        expectedLadderKey = .masterLadderForRemove
                    case .setBiometrics(true, _):
                        expectedLadderKey = .masterLadderForBiometrics
                    default:
                        expectedLadderKey = nil
                    }
                    if masterExists, let expectedLadderKey {
                        check(ladder == .verify(scope: .master, purpose: .manage, recovery: .resetChatLock, isMasterRecovery: true, biometricEnabled: false, turnsOffChatLock: false, subtitleKey: expectedLadderKey.rawValue), "ladder spec for \(action)")
                    } else {
                        check(ladder == nil, "no ladder for \(action), master=\(masterExists)")
                    }
                }
            }
        }
        // OFF needs no proof.
        check(sgChatLockFlow(for: .setBiometrics(false, peerId: user), masterExists: true, hasBiometrics: true) == [.write(.setBiometrics)])
        check(sgChatLockFlow(for: .setMasterBiometrics(false), masterExists: true, hasBiometrics: true) == [.write(.setMasterBiometrics)])
        // F10 is device-owner proof then the sweep.
        check(sgChatLockFlow(for: .turnOffWithoutMaster, masterExists: false, hasBiometrics: false) == [.deviceOwnerTurnOff, .write(.disableChatLock)])
    }

    // MARK: #7 — the two CREATE gate sites

    private static func gateSites() {
        func gates(_ steps: [SGChatLockFlowSpec]) -> Int {
            return steps.filter { $0 == .gate(.createChatLockPincode) }.count
        }
        for masterExists in [true, false] {
            for hasBiometrics in [true, false] {
                for action in allActions {
                    let count = gates(sgChatLockFlow(for: action, masterExists: masterExists, hasBiometrics: hasBiometrics))
                    switch action {
                    case .lockChat, .armMaster:
                        check(count == 1, "exactly one gate in \(action)")
                    default:
                        check(count == 0, "no gate in \(action)")
                    }
                }
            }
        }
        let guided = sgChatLockFlow(for: .lockChat(peerId: user), masterExists: false, hasBiometrics: true)
        let screens = guided.filter { step in
            if case .write = step {
                return false
            }
            return true
        }
        check(screens == [
            .explainer(.chat),
            .gate(.createChatLockPincode),
            .set(scope: .master, captionKey: SGChatLockCopyKey.captionMaster.rawValue),
            .set(scope: .chat(user), captionKey: SGChatLockCopyKey.captionChat.rawValue)
        ], "guided set-up from a chat: explainer, gate, master set, chat set")
        guard let masterWrite = guided.firstIndex(of: .write(.setMasterPincode)), let chatWrite = guided.firstIndex(of: .write(.setPincode)) else {
            check(false, "guided set-up writes the master and the chat")
            return
        }
        check(masterWrite < chatWrite, "setPincode never precedes setMasterPincode")
        check(guided.filter { $0 == .write(.setPincode) }.count == 1 && guided.filter { $0 == .write(.setMasterPincode) }.count == 1)
        // With a master: gate, the chat's set, the write — no master step at all.
        check(sgChatLockFlow(for: .lockChat(peerId: user), masterExists: true, hasBiometrics: false) == [
            .gate(.createChatLockPincode),
            .set(scope: .chat(user), captionKey: SGChatLockCopyKey.captionChat.rawValue),
            .write(.setPincode)
        ])
        // From the hub: the hub's explainer text, then the master only (the picker is the hub's business).
        check(sgChatLockFlow(for: .armMaster(legacy: false), masterExists: false, hasBiometrics: true) == [
            .explainer(.hub),
            .gate(.createChatLockPincode),
            .set(scope: .master, captionKey: SGChatLockCopyKey.captionMaster.rawValue),
            .write(.setMasterPincode)
        ])
        // LEGACY (chats already locked, no master): the legacy explainer — the hub text's "then pick the first
        // chat to lock" would be false there — and otherwise the same flow.
        check(sgChatLockFlow(for: .armMaster(legacy: true), masterExists: false, hasBiometrics: true) == [
            .explainer(.legacy),
            .gate(.createChatLockPincode),
            .set(scope: .master, captionKey: SGChatLockCopyKey.captionMaster.rawValue),
            .write(.setMasterPincode)
        ])
        for legacy in [true, false] {
            check(sgChatLockFlow(for: .armMaster(legacy: legacy), masterExists: false, hasBiometrics: true).dropFirst() == sgChatLockFlow(for: .armMaster(legacy: !legacy), masterExists: false, hasBiometrics: true).dropFirst(), "only the explainer differs between the two arm-master flows")
        }
    }

    // MARK: #8 — stable ids

    private static func stableIds() {
        var kinds: [Int64: SGChatLockCenterRowKind] = [:]
        func absorb(_ rows: [SGChatLockCenterRow]) {
            var seen = Set<Int64>()
            for row in rows {
                check(seen.insert(row.stableId).inserted, "duplicate stable id \(row.stableId) in one build")
                if let kind = kinds[row.stableId] {
                    check(kind == row.kind, "stable id \(row.stableId) maps to two kinds")
                } else {
                    kinds[row.stableId] = row.kind
                }
            }
        }
        let lockedSets: [Set<Int64>] = [[], [user], [user, group, channel, hidden, foreign, bigChannel]]
        let resolved: [Int64: Int64?] = [user: nil, group: nil, channel: nil, hidden: nil, bigChannel: nil]
        for master in [SGChatLockMasterState.present, .absent, .unreadable] {
            for recovery in [false, true] {
                for locked in lockedSets {
                    for canAuth in [true, false] {
                        for biometrics in [true, false] {
                            for accounts in [1, 2] {
                                for masterBiometric in [true, false] {
                                    absorb(sgChatLockCenterRows(input(master: master, masterBiometric: masterBiometric, locked: locked, hidden: [hidden], resolved: resolved, recovery: recovery, pending: locked.count, canAuth: canAuth, biometrics: biometrics, accounts: accounts)))
                                }
                            }
                        }
                    }
                }
            }
        }
        // Every fixed row has its own id, whatever its payload.
        let catalog: [SGChatLockCenterRow] = [
            .turnOn, .offExplainer, .masterHeader, .changeMaster, .masterBiometrics(enabled: true), .masterFooter(biometrics: true),
            .legacySetMaster, .legacyNotice, .lockedChatsHeader, .addChat, .lockedChatsFooter(empty: true, otherAccounts: true),
            .turnOff, .turnOffFooter, .turnOffWithoutMaster(enabled: true), .legacyTurnOffFooter(deviceAuthHint: true),
            .recoveryNotice(pendingCount: 0), .recoverySetNewPin(enabled: true), .recoveryTurnOff(enabled: true), .recoveryHint, .unreadableNotice
        ]
        let fixedIds = Set(catalog.map { $0.stableId })
        check(fixedIds.count == catalog.count, "fixed ids are unique")
        check(SGChatLockCenterRow.masterBiometrics(enabled: false).stableId == SGChatLockCenterRow.masterBiometrics(enabled: true).stableId)
        check(SGChatLockCenterRow.lockedChatsFooter(empty: false, otherAccounts: false).stableId == SGChatLockCenterRow.lockedChatsFooter(empty: true, otherAccounts: true).stableId)
        check(SGChatLockCenterRow.addChat.stableId == Int64.max - 1)
        // Packed peer ids: positive, below 2^40 for every real namespace, never a fixed id.
        for peerId in [user, user2, group, group2, channel, channel2, bigChannel, secretChat, account, foreign, hidden, 1] {
            check(peerId > 0, "packed peer id is positive")
            check(peerId < (1 << 40), "packed peer id below 2^40")
            check(!fixedIds.contains(peerId), "peer id collides with a fixed id")
            check(SGChatLockCenterRow.peer(peerId).stableId == peerId)
            check(SGChatLockCenterRow.peer(peerId).kind == .peer)
        }
        // The extremes a fixed id uses are out of reach of any packed id (the namespace sits at bits 32–34
        // and the id's high bits start at 35, so a packed id stays far below Int64.max - 64 and far above
        // Int64.min + 64 for every id the server could hand out).
        for fixedId in fixedIds {
            check(fixedId <= Int64.min + 64 || fixedId >= Int64.max - 64, "fixed id lives at an extreme")
        }
    }

    // MARK: #9 — removal set

    private static func removalSet() {
        let otherChannel: Int64 = (2 << 32) | 9999
        let lockedIds: Set<Int64> = [channel, group, group2, account, user]
        let migration: [Int64: Int64?] = [group: channel, group2: otherChannel, account: nil, user: nil]
        check(sgChatLockRemovalSet(target: channel, lockedIds: lockedIds, migrationTargets: migration) == [channel, group], "target + its locked legacy pair")
        check(!sgChatLockRemovalSet(target: channel, lockedIds: lockedIds, migrationTargets: migration).contains(group2), "a legacy id whose target differs is not included")
        check(!sgChatLockRemovalSet(target: channel, lockedIds: lockedIds, migrationTargets: migration).contains(account), "the account peer is never included")
        check(sgChatLockRemovalSet(target: channel, lockedIds: [channel, user], migrationTargets: migration) == [channel], "an unlocked pair is not included")
        check(sgChatLockRemovalSet(target: user, lockedIds: lockedIds, migrationTargets: migration) == [user], "a chat without pairs removes only itself")
        check(sgChatLockRemovalSet(target: channel, lockedIds: lockedIds, migrationTargets: [:]) == [channel], "unresolved pairs are not guessed")
        check(sgChatLockRemovalSet(target: group, lockedIds: lockedIds, migrationTargets: migration) == [group], "removing the legacy group itself takes nothing else")
        check(sgChatLockRemovalSet(target: channel, lockedIds: [], migrationTargets: migration) == [channel], "the target is always included")
    }

    // MARK: #10 — copy audit

    private static func copyAudit() {
        let forbiddenApostrophes: [Character] = ["\u{02BB}", "\u{02BC}", "\u{2019}"]
        let billingWords = ["Pro", "Premium", "obuna", "подписк"]
        for key in SGChatLockCopyKey.allCases {
            let copy = SGChatLockCopy.copy(for: key)
            for apostrophe in forbiddenApostrophes {
                check(!copy.uz.contains(apostrophe), "\(key): uz uses a non-ASCII apostrophe")
            }
            let counts = [copy.en, copy.ru, copy.uz].map { $0.components(separatedBy: "%@").count - 1 }
            check(counts[0] == counts[1] && counts[1] == counts[2], "\(key): %@ count differs across en/ru/uz")
            check((counts[0] > 0) == SGChatLockCopy.placeholderKeys.contains(key), "\(key): placeholder registry")
            for text in [copy.en, copy.ru, copy.uz] {
                check(!text.isEmpty, "\(key): empty")
                for word in billingWords {
                    check(!text.contains(word), "\(key): billing word \(word)")
                }
                checkNoPositiveEncryptionClaim(text, key: key)
            }
        }
        check(SGChatLockCopy.fill("a %@ b %@", ["x", "y"]) == "a x b y")
        check(SGChatLockCopy.fill("%@ bilan ochish", ["Face ID"]) == "Face ID bilan ochish")
        check(SGChatLockCopy.fill("Pincode for %@", ["100%@"]) == "Pincode for 100%@", "user data is never re-read as a placeholder")
        check(SGChatLockCopy.fill("no placeholder", ["x"]) == "no placeholder")
    }

    private static func checkNoPositiveEncryptionClaim(_ text: String, key: SGChatLockCopyKey) {
        for needle in ["encrypt", "shifrlash", "шифрован"] {
            var searchStart = text.startIndex
            while let range = text.range(of: needle, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
                let before = text[(text.index(range.lowerBound, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex)..<range.lowerBound]
                let after = text[range.upperBound..<(text.index(range.upperBound, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex)]
                let negated = before.contains("not") || before.contains("не") || before.contains("emas") || after.contains("emas")
                check(negated, "\(key): '\(needle)' without a negation")
                searchStart = range.upperBound
            }
        }
    }

    // MARK: Extra — ON / OFF row layouts

    private static func onAndOffRows() {
        check(sgChatLockCenterRows(input(master: .absent)) == [.turnOn, .offExplainer], "OFF rows")
        let on = input(masterBiometric: true, locked: [user, group], resolved: [user: nil, group: nil], biometrics: true, accounts: 2)
        check(sgChatLockCenterRows(on) == [
            .masterHeader, .changeMaster, .masterBiometrics(enabled: true), .masterFooter(biometrics: true),
            .lockedChatsHeader, .peer(user), .peer(group), .addChat, .lockedChatsFooter(empty: false, otherAccounts: true),
            .turnOff, .turnOffFooter
        ], "ON rows with biometrics and two accounts")
        let onNoBiometrics = input(masterBiometric: true, locked: [], biometrics: false)
        check(sgChatLockCenterRows(onNoBiometrics) == [
            .masterHeader, .changeMaster, .masterFooter(biometrics: false),
            .lockedChatsHeader, .addChat, .lockedChatsFooter(empty: true, otherAccounts: false),
            .turnOff, .turnOffFooter
        ], "ON rows without biometrics")
        check(sgChatLockCenterRows(on).allSatisfy { row in
            switch row.kind {
            case .toggle:
                if case .masterBiometrics = row {
                    return true
                }
                return false
            case .action, .header, .text, .peer, .peerAction:
                return true
            }
        })
    }

    // MARK: Extra — the split footers re-join to the spec's full text (§2.2)

    private static func footersVerbatim() {
        check(SGChatLockCopy.changePincodeFooterType.en + " " + SGChatLockCopy.changePincodeFooterForgot.en == "The lock type (PIN or password) is chosen while changing the pincode. Forgot the current pincode? The master pincode is accepted instead and the lock is kept.")
        check(SGChatLockCopy.changePincodeFooterType.ru + " " + SGChatLockCopy.changePincodeFooterForgot.ru == "Тип блокировки (PIN или пароль) выбирается при смене пин-кода. Забыли текущий пин-код? Вместо него принимается главный пин-код, блокировка сохраняется.")
        check(SGChatLockCopy.changePincodeFooterType.uz + " " + SGChatLockCopy.changePincodeFooterForgot.uz == "Qulf turi (PIN yoki parol) pinkodni o'zgartirishda tanlanadi. Amaldagi pinkodni unutdingizmi? Uning o'rniga asosiy pinkod qabul qilinadi va qulf saqlanib qoladi.")
        check(SGChatLockCopy.removeFooterAsks.en + " " + SGChatLockCopy.removeFooterForgot.en == "Asks for this chat's pincode. Forgot it? The master pincode is accepted instead.")
        check(SGChatLockCopy.removeFooterAsks.ru + " " + SGChatLockCopy.removeFooterForgot.ru == "Потребуется пин-код этого чата. Забыли его? Вместо него принимается главный пин-код.")
        check(SGChatLockCopy.removeFooterAsks.uz + " " + SGChatLockCopy.removeFooterForgot.uz == "Shu chatning pinkodi so'raladi. Unutdingizmi? Uning o'rniga asosiy pinkod qabul qilinadi.")
        // The uz menu fix of C1 and the module's menu strings share one vocabulary.
        check(SGChatLockCopy.menuRemoveLock.uz == "Qulfni olib tashlash" && SGChatLockCopy.menuLock.uz == "Chatni qulflash")
    }
}
