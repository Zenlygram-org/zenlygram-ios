// MARK: Zenlygram — Chat Lock Center (wf14-chatlock spec §2.1, §2.2, §6 C3)
//
// The screen Settings → Zenlygram → Chat Lock pushes (`sgChatLockController`) and the per-chat screen it and
// the chat profile push (`sgChatLockPeerController`). Both screens only RENDER: which of the five states the
// hub is in, which rows it shows under which stable ids and which locked chats this account may list is
// decided by the pure, host-tested layer in SGChatLockFlows (`sgChatLockCenterState` / `sgChatLockCenterRows` /
// `SGChatLockVisibleCount`), and every user action is one `SGChatLockFlows` call — the single site of the
// throttle-scope / purpose / recovery / entitlement-gate invariants of every PIN screen. Nothing here reads
// chat content, calls `ChatLockSession.grant` / `requireUnlock`, or shows anything a credential protects: the
// list names the locked chats of the CURRENT account only (what the chat list already shows), never a
// vault-hidden chat and never another account's (spec §4).

import SGChatLock
import SGChatLockFlows
import SGCustomerSyncCore

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import ItemListPeerItem
import ItemListPeerActionItem
import AccountContext

// MARK: - Focus

/// A row of the Chat Lock screen another screen may ask to scroll to and flash (spec §2.1, §9).
public enum SGChatLockFocus: String {
    /// The master pincode row: Turn On Chat Lock / Change Master Pincode / Set Master Pincode.
    case master
    /// The LOCKED CHATS section.
    case lockedChats
    /// The "Add a Chat…" row.
    case addChat
}

private struct SGChatLockFocusTag: ItemListItemTag {
    let focus: SGChatLockFocus

    func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? SGChatLockFocusTag {
            return other.focus == self.focus
        }
        return false
    }
}

// MARK: - Refresh triggers

/// The refresh triggers both screens share (spec §2.1): the locked ids changed (on any surface), protected data
/// became available after boot (an UNREADABLE master may be readable now), the app became active (the Face ID
/// enrolment or the signed-in accounts may have changed). Master changes post no notification, so every own
/// flow completion and every `didAppear` refresh as well. Main queue.
private final class SGChatLockRefreshObserver {
    private var tokens: [NSObjectProtocol] = []

    init(refresh: @escaping () -> Void) {
        let center = NotificationCenter.default
        for name in [ChatPincodeManager.lockedPeersDidChangeNotification, UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            self.tokens.append(center.addObserver(forName: name, object: nil, queue: .main, using: { _ in
                refresh()
            }))
        }
    }

    func invalidate() {
        for token in self.tokens {
            NotificationCenter.default.removeObserver(token)
        }
        self.tokens.removeAll()
    }

    deinit {
        self.invalidate()
    }
}

/// Every action handler re-reads the two preconditions first (spec §2.1, J2 #5 / J3 #6): while the Chat Lock
/// credentials must be set up again, or while the master credential cannot be read, nothing acts — the screen
/// refreshes into RECOVERY / UNREADABLE instead. (The flows re-read them again right before every write.)
private func sgChatLockIsActionable() -> Bool {
    let manager = ChatPincodeManager.shared
    if manager.protectionRecoveryStatus().chatLockNeedsRecovery {
        return false
    }
    if manager.masterCredentialState() == .unreadable {
        return false
    }
    return true
}

/// `EnginePeer.Peer` for the locked ids; `[:]` for none. An id this account does not know resolves to nil
/// (another account's lock) and is dropped by `SGChatLockVisibleCount.compute`.
private func sgChatLockResolvedPeers(context: AccountContext, ids: [EnginePeer.Id]) -> Signal<[EnginePeer.Id: EnginePeer?], NoError> {
    if ids.isEmpty {
        return .single([:])
    }
    return context.engine.data.subscribe(EngineDataMap(ids.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
}

// MARK: - Hub: facts

/// What the hub reads from the Chat Lock manager and session on every refresh — on the main thread, as the
/// Settings builders do — before the engine resolves the locked chats' names. Lock metadata (type, Face ID on)
/// is not content; the per-chat pincodes are never read.
private struct SGChatLockFacts: Equatable {
    struct LockInfo: Equatable {
        let isPassword: Bool
        let biometricEnabled: Bool
    }

    var masterState: SGChatLockMasterState
    var masterBiometric: Bool
    /// Device-wide, every account's locks, ascending.
    var lockedIds: [EnginePeer.Id]
    var locks: [EnginePeer.Id: LockInfo]
    /// Hidden in the CURRENT account's Secret Vault (fail-closed).
    var vaultHidden: Set<EnginePeer.Id>
    var needsRecovery: Bool
    var pendingCount: Int
    var canAuthDeviceOwner: Bool
    var hasBiometrics: Bool

    static func read(accountPeerId: EnginePeer.Id) -> SGChatLockFacts {
        let manager = ChatPincodeManager.shared
        let session = ChatLockSession.shared
        let masterState: SGChatLockMasterState
        switch manager.masterCredentialState() {
        case .present:
            masterState = .present
        case .absent:
            masterState = .absent
        case .unreadable:
            masterState = .unreadable
        }
        let lockedIds = manager.lockedPeerIds().sorted()
        var locks: [EnginePeer.Id: LockInfo] = [:]
        var vaultHidden = Set<EnginePeer.Id>()
        for id in lockedIds {
            let metadata = manager.getMetadata(for: id)
            locks[id] = LockInfo(isPassword: metadata.passwordType == .text, biometricEnabled: metadata.biometricEnabled)
            if session.isVaultHidden(peerId: id, accountPeerId: accountPeerId) {
                vaultHidden.insert(id)
            }
        }
        let status = manager.protectionRecoveryStatus()
        return SGChatLockFacts(
            masterState: masterState,
            masterBiometric: manager.getMasterMetadata().biometricEnabled,
            lockedIds: lockedIds,
            locks: locks,
            vaultHidden: vaultHidden,
            needsRecovery: status.chatLockNeedsRecovery,
            pendingCount: status.pendingLockedChatCount,
            canAuthDeviceOwner: session.canAuthenticateDeviceOwner,
            hasBiometrics: ChatLockBiometricHelper.availableType() != nil
        )
    }
}

/// The pure input of the screen (spec §6 C2) from the facts and the names this account resolved.
private func sgChatLockCenterInput(facts: SGChatLockFacts, peers: [EnginePeer.Id: EnginePeer?], accountPeerId: EnginePeer.Id, accountCount: Int) -> SGChatLockCenterInput {
    var resolved: [Int64: Int64?] = [:]
    for (id, peer) in peers {
        guard let peer else {
            // Unresolved in this account: not listed, not counted, not excluded from the picker.
            continue
        }
        if case let .legacyGroup(group) = peer {
            resolved[id.toInt64()] = .some(group.migrationReference?.peerId.toInt64())
        } else {
            resolved[id.toInt64()] = .some(nil)
        }
    }
    return SGChatLockCenterInput(
        masterState: facts.masterState,
        masterBiometric: facts.masterBiometric,
        lockedIds: Set(facts.lockedIds.map { $0.toInt64() }),
        vaultHidden: Set(facts.vaultHidden.map { $0.toInt64() }),
        accountPeerId: accountPeerId.toInt64(),
        resolved: resolved,
        needsRecovery: facts.needsRecovery,
        pendingCount: facts.pendingCount,
        canAuthDeviceOwner: facts.canAuthDeviceOwner,
        hasBiometrics: facts.hasBiometrics,
        accountCount: accountCount
    )
}

// MARK: - Hub: arguments, state, entries

private final class SGChatLockArguments {
    let context: AccountContext
    let perform: (SGChatLockCenterRow) -> Void
    let toggle: (SGChatLockCenterRow, Bool) -> Void
    let openPeer: (EnginePeer) -> Void
    let removeLock: (EnginePeer) -> Void
    let setPeerIdWithRevealedOptions: (EnginePeer.Id?, EnginePeer.Id?) -> Void

    init(context: AccountContext, perform: @escaping (SGChatLockCenterRow) -> Void, toggle: @escaping (SGChatLockCenterRow, Bool) -> Void, openPeer: @escaping (EnginePeer) -> Void, removeLock: @escaping (EnginePeer) -> Void, setPeerIdWithRevealedOptions: @escaping (EnginePeer.Id?, EnginePeer.Id?) -> Void) {
        self.context = context
        self.perform = perform
        self.toggle = toggle
        self.openPeer = openPeer
        self.removeLock = removeLock
        self.setPeerIdWithRevealedOptions = setPeerIdWithRevealedOptions
    }
}

private struct SGChatLockHubState: Equatable {
    var revealedPeerId: EnginePeer.Id?
}

/// The sections of the hub (spec §6 C3).
private enum SGChatLockSection: Int32 {
    case master
    case chats
    case turnOff
    case notice
}

private func sgChatLockSection(of row: SGChatLockCenterRow) -> SGChatLockSection {
    switch row {
    case .turnOn, .offExplainer, .masterHeader, .changeMaster, .masterBiometrics, .masterFooter, .legacySetMaster, .legacyNotice:
        return .master
    case .lockedChatsHeader, .peer, .addChat, .lockedChatsFooter:
        return .chats
    case .turnOff, .turnOffFooter, .turnOffWithoutMaster, .legacyTurnOffFooter, .recoverySetNewPin, .recoveryTurnOff, .recoveryHint:
        return .turnOff
    case .recoveryNotice, .unreadableNotice:
        return .notice
    }
}

/// One rendered row. `row` carries the stable id (`SGChatLockCenterRow.stableId`: one id per node kind, never
/// reused across states — the ItemList DEBUG assertion on kind changes is what this protects) and the section;
/// `index` the display order; the rest is what the node draws, so equality tracks every visible change.
private enum SGChatLockEntry: ItemListNodeEntry {
    case action(index: Int32, row: SGChatLockCenterRow, title: String, kind: ItemListActionKind, focus: SGChatLockFocus?)
    case toggle(index: Int32, row: SGChatLockCenterRow, title: String, value: Bool)
    case header(index: Int32, row: SGChatLockCenterRow, text: String, focus: SGChatLockFocus?)
    case text(index: Int32, row: SGChatLockCenterRow, text: String)
    case peer(index: Int32, row: SGChatLockCenterRow, peer: EnginePeer, subtitle: String, revealed: Bool)
    case peerAction(index: Int32, row: SGChatLockCenterRow, title: String, focus: SGChatLockFocus?)

    private var row: SGChatLockCenterRow {
        switch self {
        case let .action(_, row, _, _, _):
            return row
        case let .toggle(_, row, _, _):
            return row
        case let .header(_, row, _, _):
            return row
        case let .text(_, row, _):
            return row
        case let .peer(_, row, _, _, _):
            return row
        case let .peerAction(_, row, _, _):
            return row
        }
    }

    private var index: Int32 {
        switch self {
        case let .action(index, _, _, _, _):
            return index
        case let .toggle(index, _, _, _):
            return index
        case let .header(index, _, _, _):
            return index
        case let .text(index, _, _):
            return index
        case let .peer(index, _, _, _, _):
            return index
        case let .peerAction(index, _, _, _):
            return index
        }
    }

    private var focus: SGChatLockFocus? {
        switch self {
        case let .action(_, _, _, _, focus):
            return focus
        case let .header(_, _, _, focus):
            return focus
        case let .peerAction(_, _, _, focus):
            return focus
        case .toggle, .text, .peer:
            return nil
        }
    }

    var section: ItemListSectionId {
        return sgChatLockSection(of: self.row).rawValue
    }

    var stableId: Int64 {
        return self.row.stableId
    }

    var tag: ItemListItemTag? {
        return self.focus.map { SGChatLockFocusTag(focus: $0) }
    }

    static func < (lhs: SGChatLockEntry, rhs: SGChatLockEntry) -> Bool {
        return lhs.index < rhs.index
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SGChatLockArguments
        switch self {
        case let .action(_, row, title, kind, _):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: kind, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.perform(row)
            }, tag: self.tag)
        case let .toggle(_, row, title, value):
            // Controlled: the switch only reports the requested value; it moves when the write has happened and
            // the screen has re-read the manager (spec §3 F8).
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enableInteractiveChanges: false, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(row, value)
            })
        case let .header(_, _, text, _):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section, tag: self.tag)
        case let .text(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .peer(_, _, peer, subtitle, revealed):
            return ItemListPeerItem(
                presentationData: presentationData,
                systemStyle: .glass,
                dateTimeFormat: presentationData.dateTimeFormat,
                nameDisplayOrder: presentationData.nameDisplayOrder,
                context: arguments.context,
                peer: peer,
                presence: nil,
                // VoiceOver reads the name, then this value: "<name>, PIN · Face ID".
                text: .text(subtitle, .secondary),
                label: .disclosure(""),
                editing: ItemListPeerItemEditing(editable: true, editing: false, revealed: revealed),
                revealOptions: ItemListPeerItemRevealOptions(options: [
                    ItemListPeerItemRevealOption(type: .destructive, title: SGChatLockCenterStrings.swipeRemove, action: {
                        arguments.removeLock(peer)
                    })
                ]),
                enabled: true,
                selectable: true,
                sectionId: self.section,
                action: {
                    arguments.openPeer(peer)
                },
                setPeerIdWithRevealedOptions: { peerId, fromPeerId in
                    arguments.setPeerIdWithRevealedOptions(peerId, fromPeerId)
                },
                removePeer: { _ in
                    arguments.removeLock(peer)
                }
            )
        case let .peerAction(_, row, title, _):
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesItemList.plusIconImage(presentationData.theme), title: title, sectionId: self.section, height: .peerList, color: .accent, action: {
                arguments.perform(row)
            }, tag: self.tag)
        }
    }
}

/// The hub's rows (spec §2.1) from the pure row list: copy resolved, peer rows re-sorted by display title.
private func sgChatLockHubEntries(input: SGChatLockCenterInput, facts: SGChatLockFacts, peers: [EnginePeer.Id: EnginePeer?], state: SGChatLockHubState, presentationData: PresentationData) -> [SGChatLockEntry] {
    let rows = sgChatLockCenterRows(input)
    var entries: [SGChatLockEntry] = []
    var index: Int32 = 0
    let nextIndex: () -> Int32 = {
        let value = index
        index += 1
        return value
    }

    // Peer rows come in ascending-id order from the pure layer; the screen shows them by display title.
    var peerRows: [(peer: EnginePeer, row: SGChatLockCenterRow)] = []
    for row in rows {
        if case let .peer(id) = row, let peer = peers[EnginePeer.Id(id)] ?? nil {
            peerRows.append((peer, row))
        }
    }
    peerRows.sort { lhs, rhs in
        let lhsTitle = lhs.peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        let rhsTitle = rhs.peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        // Locale-aware and case-insensitive (Finder order), so a mixed uz/ru/en list reads in the order users
        // expect; the code-unit `<` put every lower-case and every Cyrillic title after the upper-case Latin ones.
        let order = lhsTitle.localizedStandardCompare(rhsTitle)
        if order != .orderedSame {
            return order == .orderedAscending
        }
        return lhs.peer.id < rhs.peer.id
    }
    var sortedPeers = peerRows.makeIterator()

    for row in rows {
        switch row {
        case .turnOn:
            entries.append(.action(index: nextIndex(), row: row, title: SGChatLockCenterStrings.turnOn, kind: .generic, focus: .master))
        case .offExplainer:
            entries.append(.text(index: nextIndex(), row: row, text: SGChatLockCenterStrings.offExplainer))
        case .masterHeader:
            entries.append(.header(index: nextIndex(), row: row, text: SGChatLockCenterStrings.masterHeader, focus: nil))
        case .changeMaster:
            entries.append(.action(index: nextIndex(), row: row, title: SGChatLockCenterStrings.changeMaster, kind: .generic, focus: .master))
        case let .masterBiometrics(enabled):
            entries.append(.toggle(index: nextIndex(), row: row, title: SGChatLockCenterStrings.masterBiometrics(), value: enabled))
        case let .masterFooter(biometrics):
            entries.append(.text(index: nextIndex(), row: row, text: SGChatLockCenterStrings.masterSectionFooter(showsBiometrics: biometrics)))
        case .legacySetMaster:
            entries.append(.action(index: nextIndex(), row: row, title: SGChatLockCenterStrings.legacySetMaster, kind: .generic, focus: .master))
        case .legacyNotice:
            entries.append(.text(index: nextIndex(), row: row, text: SGChatLockCenterStrings.legacyNotice))
        case .lockedChatsHeader:
            entries.append(.header(index: nextIndex(), row: row, text: SGChatLockCenterStrings.lockedChatsHeader, focus: .lockedChats))
        case .peer:
            // The n-th peer row of the pure list takes the n-th peer in title order (same ids, same count); an
            // id without a resolved peer cannot occur here (`compute` lists resolved ids only) and is skipped.
            if let next = sortedPeers.next() {
                let info = facts.locks[next.peer.id]
                let subtitle = SGChatLockCenterStrings.lockSubtitle(isPassword: info?.isPassword ?? false, biometrics: (info?.biometricEnabled ?? false) && facts.hasBiometrics)
                entries.append(.peer(index: nextIndex(), row: next.row, peer: next.peer, subtitle: subtitle, revealed: state.revealedPeerId == next.peer.id))
            }
        case .addChat:
            entries.append(.peerAction(index: nextIndex(), row: row, title: SGChatLockCenterStrings.addChat, focus: .addChat))
        case let .lockedChatsFooter(empty, otherAccounts):
            entries.append(.text(index: nextIndex(), row: row, text: SGChatLockCenterStrings.lockedChatsFooter(empty: empty, otherAccounts: otherAccounts)))
        case .turnOff:
            entries.append(.action(index: nextIndex(), row: row, title: SGProtectionStrings.turnOffChatLock, kind: .destructive, focus: nil))
        case .turnOffFooter:
            entries.append(.text(index: nextIndex(), row: row, text: SGChatLockCenterStrings.turnOffFooter))
        case let .turnOffWithoutMaster(enabled):
            entries.append(.action(index: nextIndex(), row: row, title: SGProtectionStrings.turnOffChatLock, kind: enabled ? .destructive : .disabled, focus: nil))
        case let .legacyTurnOffFooter(deviceAuthHint):
            entries.append(.text(index: nextIndex(), row: row, text: SGChatLockCenterStrings.legacyTurnOffSectionFooter(canAuthDeviceOwner: !deviceAuthHint)))
        case let .recoveryNotice(pendingCount):
            entries.append(.text(index: nextIndex(), row: row, text: SGChatLockCenterStrings.recoveryNotice(pendingCount: pendingCount)))
        case let .recoverySetNewPin(enabled):
            entries.append(.action(index: nextIndex(), row: row, title: SGProtectionStrings.setNewChatLockPin, kind: enabled ? .generic : .disabled, focus: nil))
        case let .recoveryTurnOff(enabled):
            entries.append(.action(index: nextIndex(), row: row, title: SGProtectionStrings.turnOffChatLock, kind: enabled ? .destructive : .disabled, focus: nil))
        case .recoveryHint:
            entries.append(.text(index: nextIndex(), row: row, text: SGProtectionStrings.deviceAuthUnavailableHint))
        case .unreadableNotice:
            entries.append(.text(index: nextIndex(), row: row, text: SGChatLockCenterStrings.unreadableNotice))
        }
    }
    return entries
}

// MARK: - Hub: controller

/// Settings → Zenlygram → Chat Lock (spec §2.1): the five states OFF / ON / LEGACY / RECOVERY / UNREADABLE, the
/// master pincode section, the locked chats of this account with "Add a Chat…", and Turn off. `onChanged` runs
/// on every refresh so the Settings row's On / Off value (read while that list is built) follows. `focus`
/// scrolls to and flashes one row.
public func sgChatLockController(context: AccountContext, onChanged: @escaping () -> Void, focus: SGChatLockFocus? = nil) -> ViewController {
    let accountPeerId = context.account.peerId
    let analyticsAccountPeerId = accountPeerId.toInt64()
    var hostImpl: (() -> SGChatLockHost)?
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?

    let initialState = SGChatLockHubState()
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((SGChatLockHubState) -> SGChatLockHubState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let factsPromise = ValuePromise(SGChatLockFacts.read(accountPeerId: accountPeerId), ignoreRepeated: true)
    /// The input of the latest build: the picker's exclusions are computed from it at tap time.
    let latestInput = Atomic<SGChatLockCenterInput?>(value: nil)
    let refresh: () -> Void = {
        factsPromise.set(SGChatLockFacts.read(accountPeerId: accountPeerId))
        onChanged()
    }
    let actionable: () -> Bool = {
        if sgChatLockIsActionable() {
            return true
        }
        refresh()
        return false
    }
    /// The RECOVERY counterpart of `actionable()`: the two device-owner actions run only while the recovery bit is
    /// still set — `resolveChatLockRecovery` / `resolveChatLockRecoveryByTurningOff` do not re-read it, so a stale
    /// RECOVERY render must never let device-owner (passcode) proof replace or drop a master that exists again.
    let recoveryPending: () -> Bool = {
        if ChatPincodeManager.shared.protectionRecoveryStatus().chatLockNeedsRecovery {
            return true
        }
        refresh()
        return false
    }
    let currentPresentationData: () -> PresentationData = {
        return context.sharedContext.currentPresentationData.with { $0 }
    }

    // "Add a Chat…" (spec §2.3): the picker on this stack; the chat's `.set` screen is presented OVER the picker
    // and a cancelled screen keeps the picker so another chat can be chosen; `.done` dismisses it.
    let presentPicker: () -> Void = {
        guard let host = hostImpl?() else {
            return
        }
        var excluded: Set<EnginePeer.Id> = [accountPeerId]
        if let input = latestInput.with({ $0 }) {
            excluded = Set(sgChatLockPickerExclusions(input).map { EnginePeer.Id($0) })
        }
        SGChatLockFlows.presentPicker(context: context, host: host, excluded: excluded, onPicked: { peer, title, picker in
            SGChatLockFlows.lockChat(peerId: peer.id, title: title, context: context, host: SGChatLockHost(controller: picker), completion: { [weak picker] outcome in
                refresh()
                switch outcome {
                case .done:
                    picker?.dismiss()
                    if let host = hostImpl?() {
                        SGChatLockFlows.toast(.chatLocked, context: context, host: host)
                    }
                case .blockedByRecovery:
                    // The hub behind the picker has refreshed into RECOVERY: nothing more can be locked.
                    picker?.dismiss()
                case .cancelled:
                    break
                }
            })
        })
    }

    // F1 (OFF: Turn On Chat Lock → then the picker at once) / F1 "master only" (LEGACY: Set Master Pincode) /
    // the LEGACY "Add a Chat…" master-first chain (master `.set`, then the picker). `armMaster` is the explainer
    // → CREATE gate → master `.set` → `setMasterPincode`; `setPincode` is never reached while no master exists.
    // `legacy` picks the explainer: in LEGACY the master is the recovery key of the chats already locked, and
    // the OFF text's "then pick the first chat to lock" would be false there.
    let armMaster: (_ legacy: Bool, _ thenPicker: Bool) -> Void = { legacy, thenPicker in
        guard actionable(), let host = hostImpl?() else {
            return
        }
        SGChatLockFlows.armMaster(legacy: legacy, context: context, host: host, completion: { outcome in
            refresh()
            if case .done = outcome {
                SGChatLockFlows.toast(.chatLockOn, context: context, host: host)
                if thenPicker {
                    presentPicker()
                }
            }
        })
    }

    let presentDeviceAuthUnavailable: () -> Void = {
        sgPresentDeviceAuthUnavailable(context: context, present: { c, a in
            presentControllerImpl?(c, a)
        })
    }

    let arguments = SGChatLockArguments(context: context, perform: { row in
        switch row {
        case .turnOn:
            armMaster(false, true)
        case .legacySetMaster:
            armMaster(true, false)
        case .addChat:
            guard actionable() else {
                return
            }
            if ChatPincodeManager.shared.isMasterEnabled() {
                presentPicker()
            } else {
                // An "Add a Chat…" row without a master is LEGACY: the legacy explainer, then the picker.
                armMaster(true, true)
            }
        case .changeMaster:
            guard actionable(), let host = hostImpl?() else {
                return
            }
            SGChatLockFlows.changeMaster(context: context, host: host, completion: { outcome in
                refresh()
                if case .done = outcome {
                    SGChatLockFlows.toast(.masterChanged, context: context, host: host)
                }
            })
        case .turnOff:
            guard actionable(), let host = hostImpl?() else {
                return
            }
            SGChatLockFlows.turnOff(context: context, host: host, completion: { outcome in
                refresh()
                if case .done = outcome {
                    SGChatLockFlows.toast(.chatLockOff, context: context, host: host)
                }
            })
        case let .turnOffWithoutMaster(enabled):
            guard actionable(), let host = hostImpl?() else {
                return
            }
            guard enabled, ChatLockSession.shared.canAuthenticateDeviceOwner else {
                // The disabled row still answers a tap with what to do about it (never a silent no-op).
                presentDeviceAuthUnavailable()
                return
            }
            SGChatLockFlows.turnOffWithoutMaster(context: context, host: host, completion: { outcome in
                refresh()
                if case .done = outcome {
                    SGChatLockFlows.toast(.chatLockOff, context: context, host: host)
                }
            })
        case let .recoverySetNewPin(enabled):
            // RECOVERY (spec §2.1): the in-screen equivalent of the Settings recovery sheet — device-owner proof,
            // then the manager replaces every lost credential at once. Nothing else writes in this state.
            guard recoveryPending(), let host = hostImpl?() else {
                return
            }
            guard enabled, ChatLockSession.shared.canAuthenticateDeviceOwner else {
                presentDeviceAuthUnavailable()
                return
            }
            ChatLockSession.shared.runSetNewPinRecovery(.chatLock, presentationData: currentPresentationData(), present: host.present, completion: { result in
                if case .unavailable = result {
                    presentDeviceAuthUnavailable()
                }
                refresh()
            })
        case let .recoveryTurnOff(enabled):
            guard recoveryPending() else {
                return
            }
            guard enabled, ChatLockSession.shared.canAuthenticateDeviceOwner else {
                presentDeviceAuthUnavailable()
                return
            }
            ChatLockSession.shared.runTurnOffChatLockRecovery(completion: { result in
                if case .unavailable = result {
                    presentDeviceAuthUnavailable()
                }
                refresh()
            })
        case .offExplainer, .masterHeader, .masterBiometrics, .masterFooter, .legacyNotice, .lockedChatsHeader, .peer, .lockedChatsFooter, .turnOffFooter, .legacyTurnOffFooter, .recoveryNotice, .recoveryHint, .unreadableNotice:
            break
        }
    }, toggle: { row, value in
        // F8: OFF needs no proof; ON asks for the master first. The switch follows the re-read.
        guard case .masterBiometrics = row, actionable(), let host = hostImpl?() else {
            return
        }
        SGChatLockFlows.setMasterBiometrics(value, context: context, host: host, completion: { _ in
            refresh()
        })
    }, openPeer: { peer in
        pushControllerImpl?(sgChatLockPeerController(context: context, peerId: peer.id))
    }, removeLock: { peer in
        // F5 from the swipe: the chat's code (or the master) → the lock and its upgraded-group pairs go.
        updateState { state in
            var state = state
            state.revealedPeerId = nil
            return state
        }
        guard actionable(), let host = hostImpl?() else {
            return
        }
        let presentationData = currentPresentationData()
        let title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        SGChatLockFlows.removeLock(peerId: peer.id, title: title, context: context, host: host, completion: { outcome in
            refresh()
            if case .done = outcome {
                SGChatLockFlows.toast(.lockRemoved, context: context, host: host)
            }
        })
    }, setPeerIdWithRevealedOptions: { peerId, fromPeerId in
        updateState { state in
            var state = state
            if (peerId == nil && fromPeerId == state.revealedPeerId) || (peerId != nil && fromPeerId == nil) {
                state.revealedPeerId = peerId
            }
            return state
        }
    })

    let accountCount = context.sharedContext.activeAccountsWithInfo
    |> map { $0.accounts.count }
    |> distinctUntilChanged

    // The names are resolved for the SAME facts they are rendered with, so a list never mixes a new id set
    // with an old resolution.
    let resolved = factsPromise.get()
    |> mapToSignal { facts -> Signal<(SGChatLockFacts, [EnginePeer.Id: EnginePeer?]), NoError> in
        return sgChatLockResolvedPeers(context: context, ids: facts.lockedIds)
        |> map { (facts, $0) }
    }

    let observer = SGChatLockRefreshObserver(refresh: refresh)

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get(), resolved, accountCount)
    |> deliverOnMainQueue
    |> map { presentationData, state, resolved, accountCount -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let (facts, peers) = resolved
        let input = sgChatLockCenterInput(facts: facts, peers: peers, accountPeerId: accountPeerId, accountCount: accountCount)
        let _ = latestInput.swap(input)
        if sgChatLockCenterState(input) == .recovery {
            // As the Settings recovery sheet does: showing the recovery state acknowledges it, so the one-time
            // chat-list notice stops repeating.
            ChatPincodeManager.shared.acknowledgeProtectionRecovery()
        }
        let entries = sgChatLockHubEntries(input: input, facts: facts, peers: peers, state: state, presentationData: presentationData)
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(SGChatLockCenterStrings.title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            ensureVisibleItemTag: focus.map { SGChatLockFocusTag(focus: $0) }
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        observer.invalidate()
    }

    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { _ in
        // Zenlygram — analytics `screen.view chat_lock.settings` (design 40 §10.2; the registry is frozen).
        SGAnalytics.screen(.chatLockSettings, accountPeerId: analyticsAccountPeerId)
        // Coming back from the per-chat screen, the picker or a PIN screen re-reads the manager: master changes
        // post no notification.
        refresh()
    }
    // The focus flash (the Settings hub recipe): the first transaction whose item nodes include the focused
    // row highlights it, once.
    if let focus {
        let focusTag = SGChatLockFocusTag(focus: focus)
        var didFocusOnItem = false
        controller.afterTransactionCompleted = { [weak controller] in
            if !didFocusOnItem, let controller {
                controller.forEachItemNode { itemNode in
                    if let itemNode = itemNode as? ItemListItemNode, let tag = itemNode.tag, tag.isEqual(to: focusTag) {
                        didFocusOnItem = true
                        itemNode.displayHighlight()
                    }
                }
            }
        }
    }
    hostImpl = { [weak controller] in
        return SGChatLockHost(controller: controller)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    return controller
}

// MARK: - Per-chat detail

/// What the per-chat screen reads from the manager on every refresh (never the pincode itself).
private struct SGChatLockPeerFacts: Equatable {
    var isLocked: Bool
    var isPassword: Bool
    var biometricEnabled: Bool
    var masterExists: Bool
    var hasBiometrics: Bool

    static func read(peerId: EnginePeer.Id) -> SGChatLockPeerFacts {
        let manager = ChatPincodeManager.shared
        let metadata = manager.getMetadata(for: peerId)
        return SGChatLockPeerFacts(
            isLocked: manager.isLocked(peerId),
            isPassword: metadata.passwordType == .text,
            biometricEnabled: metadata.biometricEnabled,
            masterExists: manager.isMasterEnabled(),
            hasBiometrics: ChatLockBiometricHelper.availableType() != nil
        )
    }
}

private final class SGChatLockPeerArguments {
    let context: AccountContext
    let changePincode: () -> Void
    let setBiometrics: (Bool) -> Void
    let removeLock: () -> Void

    init(context: AccountContext, changePincode: @escaping () -> Void, setBiometrics: @escaping (Bool) -> Void, removeLock: @escaping () -> Void) {
        self.context = context
        self.changePincode = changePincode
        self.setBiometrics = setBiometrics
        self.removeLock = removeLock
    }
}

private enum SGChatLockPeerSection: Int32 {
    case peer
    case manage
    case remove
}

/// The rows of the per-chat screen (spec §2.2), in order. Fixed ids, one per row kind.
private enum SGChatLockPeerEntry: ItemListNodeEntry {
    case peer(EnginePeer, subtitle: String)
    case changePincode(String)
    case biometrics(title: String, value: Bool)
    case manageFooter(String)
    case removeLock(String)
    case removeFooter(String)

    var section: ItemListSectionId {
        switch self {
        case .peer:
            return SGChatLockPeerSection.peer.rawValue
        case .changePincode, .biometrics, .manageFooter:
            return SGChatLockPeerSection.manage.rawValue
        case .removeLock, .removeFooter:
            return SGChatLockPeerSection.remove.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .peer:
            return 0
        case .changePincode:
            return 1
        case .biometrics:
            return 2
        case .manageFooter:
            return 3
        case .removeLock:
            return 4
        case .removeFooter:
            return 5
        }
    }

    static func < (lhs: SGChatLockPeerEntry, rhs: SGChatLockPeerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SGChatLockPeerArguments
        switch self {
        case let .peer(peer, subtitle):
            return ItemListPeerItem(
                presentationData: presentationData,
                systemStyle: .glass,
                dateTimeFormat: presentationData.dateTimeFormat,
                nameDisplayOrder: presentationData.nameDisplayOrder,
                context: arguments.context,
                peer: peer,
                presence: nil,
                text: .text(subtitle, .secondary),
                label: .none,
                editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: false),
                enabled: true,
                selectable: false,
                highlightable: false,
                sectionId: self.section,
                action: nil,
                setPeerIdWithRevealedOptions: { _, _ in },
                removePeer: { _ in }
            )
        case let .changePincode(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.changePincode()
            })
        case let .biometrics(title, value):
            // Controlled (spec §3 F6): OFF is written at once, ON only after the chat's code (or the master and a
            // new code) was entered; the switch moves when the screen has re-read the manager.
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enableInteractiveChanges: false, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setBiometrics(value)
            })
        case let .manageFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .removeLock(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.removeLock()
            })
        case let .removeFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func sgChatLockPeerEntries(facts: SGChatLockPeerFacts, peer: EnginePeer?) -> [SGChatLockPeerEntry] {
    var entries: [SGChatLockPeerEntry] = []
    if let peer {
        entries.append(.peer(peer, subtitle: SGChatLockCenterStrings.lockSubtitle(isPassword: facts.isPassword, biometrics: facts.biometricEnabled && facts.hasBiometrics)))
    }
    entries.append(.changePincode(SGChatLockCenterStrings.changePincode))
    if facts.hasBiometrics {
        entries.append(.biometrics(title: SGChatLockCenterStrings.unlockWithBiometrics(), value: facts.biometricEnabled))
    }
    entries.append(.manageFooter(SGChatLockCenterStrings.changePincodeSectionFooter(masterExists: facts.masterExists, showsBiometrics: facts.hasBiometrics)))
    entries.append(.removeLock(SGChatLockCenterStrings.removeLock))
    entries.append(.removeFooter(SGChatLockCenterStrings.removeFooter(masterExists: facts.masterExists)))
    return entries
}

/// One locked chat (spec §2.2): Change Pincode, Unlock with Face ID / Touch ID (when the device has it), Remove
/// Lock — each through `SGChatLockFlows`, each proven with the chat's own code or, via "Forgot pincode?", the
/// master. Pushed from a hub row or from the profile's "Chat Lock…" (for a vault-hidden chat through
/// `sgChatLockPushProtected`, so it is gated and evicted with the vault). Pops with a toast when the lock
/// disappears while it is shown.
public func sgChatLockPeerController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let analyticsAccountPeerId = context.account.peerId.toInt64()
    var hostImpl: (() -> SGChatLockHost)?
    var popImpl: (() -> Void)?

    let factsPromise = ValuePromise(SGChatLockPeerFacts.read(peerId: peerId), ignoreRepeated: true)
    let latestPeer = Atomic<EnginePeer?>(value: nil)
    let refresh: () -> Void = {
        factsPromise.set(SGChatLockPeerFacts.read(peerId: peerId))
    }
    let actionable: () -> Bool = {
        if sgChatLockIsActionable() {
            return true
        }
        refresh()
        return false
    }
    /// The chat's display title for the PIN screens; the flows drop it for a vault-hidden chat.
    let currentTitle: () -> String? = {
        guard let peer = latestPeer.with({ $0 }) else {
            return nil
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        return peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
    }

    var didPop = false
    let popWithToast: () -> Void = {
        guard !didPop else {
            return
        }
        didPop = true
        if let host = hostImpl?() {
            SGChatLockFlows.toast(.lockRemoved, context: context, host: host)
        }
        popImpl?()
    }

    let arguments = SGChatLockPeerArguments(context: context, changePincode: {
        // F4: the current code (or the master) → a new code; the lock and its Face ID choice are kept.
        guard actionable(), let host = hostImpl?() else {
            return
        }
        SGChatLockFlows.changePincode(peerId: peerId, title: currentTitle(), context: context, host: host, completion: { outcome in
            refresh()
            if case .done = outcome {
                SGChatLockFlows.toast(.pincodeChanged, context: context, host: host)
            }
        })
    }, setBiometrics: { value in
        guard actionable(), let host = hostImpl?() else {
            return
        }
        SGChatLockFlows.setBiometrics(value, peerId: peerId, title: currentTitle(), context: context, host: host, completion: { _ in
            refresh()
        })
    }, removeLock: {
        // F5: the current code (or the master) → the lock and its upgraded-group pairs go; the screen pops.
        guard actionable(), let host = hostImpl?() else {
            return
        }
        SGChatLockFlows.removeLock(peerId: peerId, title: currentTitle(), context: context, host: host, completion: { outcome in
            refresh()
            if case .done = outcome {
                popWithToast()
            }
        })
    })

    let observer = SGChatLockRefreshObserver(refresh: refresh)
    // Removed elsewhere (the hub's swipe, the chat list, a recovery) while this screen is up: pop with the toast.
    let lockDisposable = (factsPromise.get()
    |> deliverOnMainQueue).startStrict(next: { facts in
        if !facts.isLocked {
            popWithToast()
        }
    })

    let peerSignal: Signal<EnginePeer?, NoError> = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))

    let signal = combineLatest(context.sharedContext.presentationData, factsPromise.get(), peerSignal)
    |> deliverOnMainQueue
    |> map { presentationData, facts, peer -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let _ = latestPeer.swap(peer)
        let title = peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder) ?? FenixuzChatLockStrings.lockedChatPreview
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: sgChatLockPeerEntries(facts: facts, peer: peer),
            style: .blocks
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        observer.invalidate()
        lockDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { _ in
        // Same screen name as the hub (design 40 §10.2; deduped within the pipeline).
        SGAnalytics.screen(.chatLockSettings, accountPeerId: analyticsAccountPeerId)
        refresh()
    }
    hostImpl = { [weak controller] in
        return SGChatLockHost(controller: controller)
    }
    popImpl = { [weak controller] in
        guard let controller else {
            return
        }
        if let navigationController = controller.navigationController as? NavigationController {
            navigationController.filterController(controller, animated: true)
        } else {
            controller.dismiss()
        }
    }
    return controller
}
