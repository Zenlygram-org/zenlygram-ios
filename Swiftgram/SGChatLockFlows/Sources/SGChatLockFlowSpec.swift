import Foundation

// MARK: Zenlygram — Chat Lock Center: the pure decision layer (wf14-chatlock spec §6 C2).
//
// Foundation only, no other import: the host tests (Tests/run-host-tests.sh) compile this file and the copy
// table with plain `swiftc`, so everything the Chat Lock screen, the per-chat screen and the flows DECIDE
// lives here, testable without the app — which of the five states the screen is in, which rows it shows
// under which stable ids, which locked chats the current account may list, which ids a removal must take
// with it (the upgraded-group pair), and which screens each user action walks through with which
// invariants (throttle scope, purpose, recovery, entitlement gate). Ids are packed `PeerId.toInt64()`
// values, so this file never needs Postbox.

// MARK: - Input

/// Presence of the master credential, as `ChatPincodeManager.masterCredentialState()` reports it.
public enum SGChatLockMasterState: Equatable {
    case present
    case absent
    /// Cannot be answered right now (protected data not yet available, keychain error). Never read as
    /// "absent": a set-up offered on that answer would overwrite a real master.
    case unreadable
}

/// Everything the Chat Lock screen is built from, read again on every refresh.
public struct SGChatLockCenterInput: Equatable {
    public var masterState: SGChatLockMasterState
    /// `getMasterMetadata().biometricEnabled`.
    public var masterBiometric: Bool
    /// `lockedPeerIds()`: device-wide, every account's locks.
    public var lockedIds: Set<Int64>
    /// Ids hidden in the CURRENT account's Secret Vault (fail-closed: an unreadable membership counts as hidden).
    public var vaultHidden: Set<Int64>
    public var accountPeerId: Int64
    /// id → migration target, for the locked ids the CURRENT account resolved. An absent key is a chat this
    /// account does not know (typically another account's lock); a `nil` value is a resolved chat with no
    /// migration target; a value is the supergroup this legacy group was upgraded to.
    public var resolved: [Int64: Int64?]
    /// `protectionRecoveryStatus().chatLockNeedsRecovery`.
    public var needsRecovery: Bool
    /// `protectionRecoveryStatus().pendingLockedChatCount`.
    public var pendingCount: Int
    /// `ChatLockSession.shared.canAuthenticateDeviceOwner`.
    public var canAuthDeviceOwner: Bool
    /// `ChatLockBiometricHelper.availableType() != nil`.
    public var hasBiometrics: Bool
    /// Accounts logged in on this device.
    public var accountCount: Int

    public init(
        masterState: SGChatLockMasterState,
        masterBiometric: Bool,
        lockedIds: Set<Int64>,
        vaultHidden: Set<Int64>,
        accountPeerId: Int64,
        resolved: [Int64: Int64?],
        needsRecovery: Bool,
        pendingCount: Int,
        canAuthDeviceOwner: Bool,
        hasBiometrics: Bool,
        accountCount: Int
    ) {
        self.masterState = masterState
        self.masterBiometric = masterBiometric
        self.lockedIds = lockedIds
        self.vaultHidden = vaultHidden
        self.accountPeerId = accountPeerId
        self.resolved = resolved
        self.needsRecovery = needsRecovery
        self.pendingCount = pendingCount
        self.canAuthDeviceOwner = canAuthDeviceOwner
        self.hasBiometrics = hasBiometrics
        self.accountCount = accountCount
    }
}

// MARK: - State

/// The five states of the Chat Lock screen (spec §2.1).
public enum SGChatLockCenterState: Equatable {
    /// Master absent, no locked ids, no recovery.
    case off
    /// Master present.
    case on
    /// Locked ids exist but no master (`reconcileProtectionFlags`'s "configured" edge; also what a second
    /// account sees when only another account's chats are locked).
    case legacy
    /// The Chat Lock credentials did not come along with a device migration (`chatLockNeedsRecovery`).
    case recovery
    /// The master credential cannot be read right now.
    case unreadable
}

/// Precedence: RECOVERY > UNREADABLE > LEGACY (locked ids exist, master absent) > ON (master present) > OFF.
public func sgChatLockCenterState(_ input: SGChatLockCenterInput) -> SGChatLockCenterState {
    if input.needsRecovery {
        return .recovery
    }
    switch input.masterState {
    case .unreadable:
        return .unreadable
    case .present:
        return .on
    case .absent:
        return input.lockedIds.isEmpty ? .off : .legacy
    }
}

// MARK: - Visible set

/// The single rule for which locked chats the CURRENT account lists, excludes from the picker or counts.
public enum SGChatLockVisibleCount {
    /// Drops the account peer (Saved Messages is never lockable from these screens), vault-hidden ids (their
    /// existence must not be revealed outside the vault), unresolved ids (another account's locks: names are
    /// resolved only through the current account's engine) and legacy groups with a migration target (their
    /// upgraded supergroup carries the lock and is listed instead). Sorted ascending, so the output is
    /// deterministic for one input.
    public static func compute(lockedIds: Set<Int64>, accountPeerId: Int64, isVaultHidden: (Int64) -> Bool, resolved: [Int64: Int64?]) -> [Int64] {
        var visible: [Int64] = []
        for id in lockedIds {
            if id == accountPeerId {
                continue
            }
            if isVaultHidden(id) {
                continue
            }
            guard let entry = resolved[id] else {
                // Unresolved in this account.
                continue
            }
            if entry != nil {
                // A legacy group upgraded to a supergroup: the supergroup row stands for both.
                continue
            }
            visible.append(id)
        }
        return visible.sorted()
    }
}

/// `SGChatLockVisibleCount.compute` over the screen's input.
public func sgChatLockVisibleIds(_ input: SGChatLockCenterInput) -> [Int64] {
    return SGChatLockVisibleCount.compute(lockedIds: input.lockedIds, accountPeerId: input.accountPeerId, isVaultHidden: { input.vaultHidden.contains($0) }, resolved: input.resolved)
}

/// What the "Add a Chat…" picker must not offer: every visible locked chat plus the account peer (spec §2.3).
public func sgChatLockPickerExclusions(_ input: SGChatLockCenterInput) -> Set<Int64> {
    var exclusions = Set(sgChatLockVisibleIds(input))
    exclusions.insert(input.accountPeerId)
    return exclusions
}

// MARK: - Removal set

/// The ids a removal of `target` takes with it: `target` plus every LOCKED legacy group whose migration
/// target is `target`. `SGSecretVaultAccountWatcher` re-copies a lock from a locked legacy group to its
/// upgraded supergroup on every emission, so removing only the supergroup's lock while the old group id
/// stays locked re-locks the supergroup at once (spec §0, §3 F5).
public func sgChatLockRemovalSet(target: Int64, lockedIds: Set<Int64>, migrationTargets: [Int64: Int64?]) -> Set<Int64> {
    var result: Set<Int64> = [target]
    for id in lockedIds where id != target {
        if let entry = migrationTargets[id], let migrated = entry, migrated == target {
            result.insert(id)
        }
    }
    return result
}

// MARK: - Rows

/// The node class a row renders with. The ItemList DEBUG assertion fires when a stable id changes class
/// between two builds, so no stable id may ever map to two kinds (spec §2.1, test #8).
public enum SGChatLockCenterRowKind: Equatable {
    /// `ItemListActionItem`.
    case action
    /// `ItemListSwitchItem` (controlled: `enableInteractiveChanges: false`).
    case toggle
    /// `ItemListSectionHeaderItem`.
    case header
    /// `ItemListTextItem` (footers and notices).
    case text
    /// `ItemListPeerItem`.
    case peer
    /// `ItemListPeerActionItem`.
    case peerAction
}

/// One row of the Chat Lock screen, in display order as `sgChatLockCenterRows` emits them.
public enum SGChatLockCenterRow: Equatable {
    // OFF
    case turnOn
    case offExplainer

    // ON — master section
    case masterHeader
    case changeMaster
    case masterBiometrics(enabled: Bool)
    /// `biometrics`: the switch is shown, so the biometric sentence is prepended.
    case masterFooter(biometrics: Bool)

    // LEGACY — master section
    case legacySetMaster
    case legacyNotice

    // ON / LEGACY — locked chats
    case lockedChatsHeader
    case peer(Int64)
    case addChat
    case lockedChatsFooter(empty: Bool, otherAccounts: Bool)

    // ON — turn off (master proof)
    case turnOff
    case turnOffFooter

    // LEGACY — turn off (device-owner proof)
    case turnOffWithoutMaster(enabled: Bool)
    case legacyTurnOffFooter(deviceAuthHint: Bool)

    // RECOVERY (count only, nothing writes)
    case recoveryNotice(pendingCount: Int)
    case recoverySetNewPin(enabled: Bool)
    case recoveryTurnOff(enabled: Bool)
    case recoveryHint

    // UNREADABLE
    case unreadableNotice

    public var kind: SGChatLockCenterRowKind {
        switch self {
        case .turnOn, .changeMaster, .legacySetMaster, .turnOff, .turnOffWithoutMaster, .recoverySetNewPin, .recoveryTurnOff:
            return .action
        case .masterBiometrics:
            return .toggle
        case .masterHeader, .lockedChatsHeader:
            return .header
        case .offExplainer, .masterFooter, .legacyNotice, .lockedChatsFooter, .turnOffFooter, .legacyTurnOffFooter, .recoveryNotice, .recoveryHint, .unreadableNotice:
            return .text
        case .peer:
            return .peer
        case .addChat:
            return .peerAction
        }
    }

    /// Stable ids (spec §2.1): fixed rows `Int64.min + k` (one k per row kind, never reused across states),
    /// peer rows the packed peer id, the add row `Int64.max - 1`, footers `Int64.max - 2…`. A packed peer id
    /// is positive and far below `Int64.max - 64`, so it can never collide with a fixed id.
    public var stableId: Int64 {
        switch self {
        case .turnOn:
            return Int64.min + 0
        case .masterHeader:
            return Int64.min + 1
        case .changeMaster:
            return Int64.min + 2
        case .masterBiometrics:
            return Int64.min + 3
        case .legacySetMaster:
            return Int64.min + 4
        case .lockedChatsHeader:
            return Int64.min + 5
        case .turnOff:
            return Int64.min + 6
        case .turnOffWithoutMaster:
            return Int64.min + 7
        case .recoveryNotice:
            return Int64.min + 8
        case .recoverySetNewPin:
            return Int64.min + 9
        case .recoveryTurnOff:
            return Int64.min + 10
        case .unreadableNotice:
            return Int64.min + 11
        case let .peer(id):
            return id
        case .addChat:
            return Int64.max - 1
        case .offExplainer:
            return Int64.max - 2
        case .masterFooter:
            return Int64.max - 3
        case .legacyNotice:
            return Int64.max - 4
        case .lockedChatsFooter:
            return Int64.max - 5
        case .turnOffFooter:
            return Int64.max - 6
        case .legacyTurnOffFooter:
            return Int64.max - 7
        case .recoveryHint:
            return Int64.max - 8
        }
    }
}

/// The rows of the Chat Lock screen for `input`, in display order (spec §2.1). Peer rows come in
/// `SGChatLockVisibleCount.compute` order (ascending id); the screen re-sorts them by display title when it
/// has the names.
public func sgChatLockCenterRows(_ input: SGChatLockCenterInput) -> [SGChatLockCenterRow] {
    switch sgChatLockCenterState(input) {
    case .recovery:
        var rows: [SGChatLockCenterRow] = [
            .recoveryNotice(pendingCount: input.pendingCount),
            .recoverySetNewPin(enabled: input.canAuthDeviceOwner),
            .recoveryTurnOff(enabled: input.canAuthDeviceOwner)
        ]
        if !input.canAuthDeviceOwner {
            rows.append(.recoveryHint)
        }
        return rows
    case .unreadable:
        return [.unreadableNotice]
    case .off:
        return [.turnOn, .offExplainer]
    case .on:
        var rows: [SGChatLockCenterRow] = [.masterHeader, .changeMaster]
        if input.hasBiometrics {
            rows.append(.masterBiometrics(enabled: input.masterBiometric))
        }
        rows.append(.masterFooter(biometrics: input.hasBiometrics))
        rows.append(contentsOf: sgChatLockLockedChatRows(input))
        rows.append(.turnOff)
        rows.append(.turnOffFooter)
        return rows
    case .legacy:
        var rows: [SGChatLockCenterRow] = [.masterHeader, .legacySetMaster, .legacyNotice]
        rows.append(contentsOf: sgChatLockLockedChatRows(input))
        rows.append(.turnOffWithoutMaster(enabled: input.canAuthDeviceOwner))
        rows.append(.legacyTurnOffFooter(deviceAuthHint: !input.canAuthDeviceOwner))
        return rows
    }
}

/// Section B of the ON and LEGACY states: header, one row per visible locked chat, "Add a Chat…", footer.
private func sgChatLockLockedChatRows(_ input: SGChatLockCenterInput) -> [SGChatLockCenterRow] {
    let visible = sgChatLockVisibleIds(input)
    var rows: [SGChatLockCenterRow] = [.lockedChatsHeader]
    rows.append(contentsOf: visible.map { SGChatLockCenterRow.peer($0) })
    rows.append(.addChat)
    rows.append(.lockedChatsFooter(empty: visible.isEmpty, otherAccounts: input.accountCount > 1))
    return rows
}

// MARK: - Flow specs

/// Which brute-force budget a PIN screen counts against (`ChatLockThrottle.Scope`). Every per-chat screen is
/// `.chat(id)`, every master screen `.master`: the controller's default is `.vault`, so a forgotten scope
/// would charge the vault's budget and report the screen as a vault screen (spec §3).
public enum SGChatLockScopeSpec: Equatable {
    case chat(Int64)
    case master
}

/// `ChatPincodePurpose`.
public enum SGChatLockPurposeSpec: Equatable {
    case unlock
    case manage
}

/// What "Forgot pincode?" / "Reset Chat Lock" does on a `.verify` screen.
public enum SGChatLockRecoverySpec: Equatable {
    /// A chat's screen pushes the master screen (`sgChatLockMasterLadder(for:masterExists:)`).
    case masterPin
    /// The master screen offers the device-owner "Reset Chat Lock" after 4 wrong entries or during a lockout.
    case resetChatLock
    /// No recovery rung (a chat's screen while no master exists).
    case none
}

/// The entitlement gates a flow may pass through. Exactly two sites: before a new per-chat code and before
/// the first master (spec §4) — change / remove / unlock / biometrics / disable / recovery are never gated.
public enum SGChatLockGateSpec: Equatable {
    case createChatLockPincode
}

/// The ChatPincodeManager writes a flow performs. Every one is preceded by `guardWritable()`.
public enum SGChatLockWriteSpec: Equatable {
    case setPincode
    case setMasterPincode
    case removePincode
    case setBiometrics
    case setMasterBiometrics
    case disableChatLock
}

/// Which set-up explainer (spec §2.4) opens a master-first flow: `.hub` (OFF, "Turn On Chat Lock") promises
/// the picker that follows, `.chat` names that chat's own pincode as the second step, and `.legacy` (the hub
/// while chats are already locked without a master: "Set Master Pincode", "Add a Chat…") promises nothing
/// afterwards — the master is the recovery key of the chats already locked.
public enum SGChatLockExplainerSpec: Equatable {
    case hub
    case chat
    case legacy
}

/// One step of a flow (spec §6 C2). `subtitleKey` / `captionKey` are `SGChatLockCopyKey` raw values; an
/// empty `subtitleKey` keeps the step's default copy.
public enum SGChatLockFlowSpec: Equatable {
    case gate(SGChatLockGateSpec)
    case explainer(SGChatLockExplainerSpec)
    case verify(scope: SGChatLockScopeSpec, purpose: SGChatLockPurposeSpec, recovery: SGChatLockRecoverySpec, isMasterRecovery: Bool, biometricEnabled: Bool, turnsOffChatLock: Bool, subtitleKey: String)
    case set(scope: SGChatLockScopeSpec, captionKey: String)
    /// `ChatLockSession.runTurnOffChatLockRecovery`: device-owner proof, then Chat Lock is turned off.
    case deviceOwnerTurnOff
    case write(SGChatLockWriteSpec)
}

/// The user actions `SGChatLockFlows` offers. Per-chat actions carry the packed peer id, so the specs can
/// name their `.chat(id)` scope.
public enum SGChatLockAction: Equatable {
    /// F2 / F3: a new per-chat code (the guided master-first chain when no master exists).
    case lockChat(peerId: Int64)
    /// F1: the first master pincode (Turn On / Set Master Pincode). `legacy` is the hub's LEGACY state (chats
    /// already locked without a master) and picks the explainer.
    case armMaster(legacy: Bool)
    /// F4
    case changePincode(peerId: Int64)
    /// F5
    case removeLock(peerId: Int64)
    /// F6
    case setBiometrics(Bool, peerId: Int64)
    /// F7
    case changeMaster
    /// F8
    case setMasterBiometrics(Bool)
    /// F9: master proof.
    case turnOff
    /// F10: device-owner proof (LEGACY, no master to ask for).
    case turnOffWithoutMaster
}

/// A chat's own `.verify` screen for a management action: the code itself is the proof (`.manage`: no
/// biometric button, no auto-attempt), with the master ladder whenever a master exists.
private func sgChatLockChatVerify(_ peerId: Int64, masterExists: Bool, subtitleKey: SGChatLockCopyKey) -> SGChatLockFlowSpec {
    return .verify(scope: .chat(peerId), purpose: .manage, recovery: masterExists ? .masterPin : .none, isMasterRecovery: false, biometricEnabled: false, turnsOffChatLock: false, subtitleKey: subtitleKey.rawValue)
}

/// The master's own `.verify` screen for a management action.
private func sgChatLockMasterVerify(subtitleKey: SGChatLockCopyKey) -> SGChatLockFlowSpec {
    return .verify(scope: .master, purpose: .manage, recovery: .resetChatLock, isMasterRecovery: true, biometricEnabled: false, turnsOffChatLock: false, subtitleKey: subtitleKey.rawValue)
}

/// The screens and writes of `action`, in order (spec §3). Alternatives inside a flow are documented on
/// the action: a per-chat `.verify` proven with the MASTER keeps the lock for `changePincode` and
/// `setBiometrics(true)` (the latter then sets a new chat code first — biometrics are never enabled on a
/// code the owner cannot enter) and removes it for `removeLock`.
public func sgChatLockFlow(for action: SGChatLockAction, masterExists: Bool, hasBiometrics: Bool) -> [SGChatLockFlowSpec] {
    switch action {
    case let .lockChat(peerId):
        if masterExists {
            return [
                .gate(.createChatLockPincode),
                .set(scope: .chat(peerId), captionKey: SGChatLockCopyKey.captionChat.rawValue),
                .write(.setPincode)
            ]
        }
        // J2 #3: the master comes first; `setPincode` is never reached while no master exists.
        return [
            .explainer(.chat),
            .gate(.createChatLockPincode),
            .set(scope: .master, captionKey: SGChatLockCopyKey.captionMaster.rawValue),
            .write(.setMasterPincode),
            .set(scope: .chat(peerId), captionKey: SGChatLockCopyKey.captionChat.rawValue),
            .write(.setPincode)
        ]
    case let .armMaster(legacy):
        return [
            .explainer(legacy ? .legacy : .hub),
            .gate(.createChatLockPincode),
            .set(scope: .master, captionKey: SGChatLockCopyKey.captionMaster.rawValue),
            .write(.setMasterPincode)
        ]
    case let .changePincode(peerId):
        return [
            sgChatLockChatVerify(peerId, masterExists: masterExists, subtitleKey: .verifyToChange),
            .set(scope: .chat(peerId), captionKey: SGChatLockCopyKey.captionNewChat.rawValue),
            .write(.setPincode)
        ]
    case let .removeLock(peerId):
        return [
            sgChatLockChatVerify(peerId, masterExists: masterExists, subtitleKey: .verifyToRemove),
            .write(.removePincode)
        ]
    case let .setBiometrics(enabled, peerId):
        if !enabled {
            // Capability only shrinks: no proof.
            return [.write(.setBiometrics)]
        }
        return [
            sgChatLockChatVerify(peerId, masterExists: masterExists, subtitleKey: .verifyToEnableBiometrics),
            .write(.setBiometrics)
        ]
    case .changeMaster:
        return [
            sgChatLockMasterVerify(subtitleKey: .masterToChange),
            .set(scope: .master, captionKey: SGChatLockCopyKey.captionNewMaster.rawValue),
            .write(.setMasterPincode)
        ]
    case let .setMasterBiometrics(enabled):
        if !enabled {
            return [.write(.setMasterBiometrics)]
        }
        return [
            sgChatLockMasterVerify(subtitleKey: .masterToEnableBiometrics),
            .write(.setMasterBiometrics)
        ]
    case .turnOff:
        // Exactly today's Settings screen: the master's biometric button may be offered (explicit tap only —
        // master screens never auto-attempt), the subtitle is the step's own "turns off Chat Lock" copy.
        return [
            .verify(scope: .master, purpose: .unlock, recovery: .resetChatLock, isMasterRecovery: true, biometricEnabled: hasBiometrics, turnsOffChatLock: true, subtitleKey: ""),
            .write(.disableChatLock)
        ]
    case .turnOffWithoutMaster:
        return [
            .deviceOwnerTurnOff,
            .write(.disableChatLock)
        ]
    }
}

/// The master screen a per-chat `.verify` pushes from "Forgot pincode?" (`.masterPin`), for the actions that
/// have one; nil when no master exists or the action has no ladder. Always `.master`, `isMasterRecovery`,
/// `.resetChatLock`, `.manage`, no biometrics — and its success never removes anything by itself: the flow
/// decides what the proof is for.
public func sgChatLockMasterLadder(for action: SGChatLockAction, masterExists: Bool) -> SGChatLockFlowSpec? {
    guard masterExists else {
        return nil
    }
    let subtitleKey: SGChatLockCopyKey
    switch action {
    case .changePincode:
        subtitleKey = .masterLadderForChange
    case .removeLock:
        subtitleKey = .masterLadderForRemove
    case .setBiometrics(true, _):
        subtitleKey = .masterLadderForBiometrics
    case .lockChat, .armMaster, .setBiometrics(false, _), .changeMaster, .setMasterBiometrics, .turnOff, .turnOffWithoutMaster:
        return nil
    }
    return sgChatLockMasterVerify(subtitleKey: subtitleKey)
}
