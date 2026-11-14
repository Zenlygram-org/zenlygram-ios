import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import LocalizedPeerData
import UndoUI
import AccountContext
import SGChatLock
import SGEntitlement
import SGEntitlementUI
import SGCustomerSyncCore
import SGStrings

// MARK: Zenlygram — Chat Lock Center: the shared flows (wf14-chatlock spec §3, §4, §6 C2).
//
// Every Chat Lock user action — from the Settings hub, the per-chat screen, the chat profile and the
// chat-list long-press — comes through here. Each action is `sgChatLockFlow(for:masterExists:hasBiometrics:)`
// (the pure, host-tested spec) interpreted step by step by one private `Run`; the two PIN-screen steps
// (`.verify`, `.set`) are turned into a `ChatPincodeViewController` by ONE function,
// `makePincodeController(spec:…)`, so the invariants of §4 live at a single site:
//   - every per-chat screen counts against `.chat(id)`, every master screen against `.master` (the
//     controller's default is `.vault`);
//   - management screens are `.manage`: the code itself is the proof, no biometric button, no auto-attempt,
//     `biometricEnabled: false`, reported as `chat_lock.settings`;
//   - a chat's screen offers the master ladder iff a master exists; the master screen always carries
//     `isMasterRecovery`, `.resetChatLock` and `.master`, so a lockout has a way out — and its success never
//     removes anything by itself: the flow decides (keep for change / biometrics, remove for remove);
//   - exactly two entitlement CREATE gates (a new per-chat code, the first master); change / remove /
//     unlock / biometrics / disable / recovery are never gated;
//   - `guardWritable()` runs immediately before every write: nothing is written while the recovery bit is
//     set (the mirror is frozen) or while the master credential is unreadable (`.blockedByRecovery`);
//   - analytics are recorded here, once per user action (`chat_lock.lock_set` for the master armed and a new
//     per-chat code, `chat_lock.lock_removed` for a per-chat removal and both turn-offs); nothing for
//     change-code, biometric toggles, change-master or picker opens; the registry is frozen.
// No flow calls `ChatLockSession.grant` or `requireUnlock`; nothing here reads chat content.

/// Where a flow puts its screens. `present`: a UIKit modal (the full-screen PIN container) from the window's
/// root view controller; `presentOverlay`: Display's `.window(.root)` (paywall, alerts, toasts); `push`: onto
/// the host's Display navigation stack (the chat picker).
public struct SGChatLockHost {
    public let present: (UIViewController) -> Void
    public let presentOverlay: (ViewController) -> Void
    public let push: (ViewController) -> Void

    public init(present: @escaping (UIViewController) -> Void, presentOverlay: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
        self.present = present
        self.presentOverlay = presentOverlay
        self.push = push
    }

    /// The host most callers have: a Display `ViewController` (held weakly). PIN containers go to
    /// `view.window?.rootViewController` (the presentation contract every Chat Lock screen uses), overlays
    /// to `present(_:in: .window(.root))`, pushes to its `NavigationController`.
    public init(controller: ViewController?) {
        self.init(
            present: { [weak controller] viewController in
                controller?.view.window?.rootViewController?.present(viewController, animated: true)
            },
            presentOverlay: { [weak controller] overlay in
                controller?.present(overlay, in: .window(.root))
            },
            push: { [weak controller] pushed in
                (controller?.navigationController as? NavigationController)?.pushViewController(pushed)
            }
        )
    }
}

/// How a flow ended.
public enum SGChatLockFlowOutcome {
    /// The action's write happened.
    case done
    /// Nothing the action asked for happened: cancelled, a blocked CREATE gate (paywall shown), a
    /// precondition that no longer held, or the device-owner Reset turned Chat Lock off in the middle of a
    /// management flow. (For `turnOff`, that Reset counts as `.done`.) A flow may still have written an
    /// earlier step — the guided set-up's master stays armed when the chat's screen is cancelled — so the
    /// caller refreshes on every outcome.
    case cancelled
    /// The recovery bit appeared (or the master credential became unreadable) before a write: nothing was
    /// written. The hub refreshes into RECOVERY / UNREADABLE; the profile pushes the hub.
    case blockedByRecovery
}

/// The completion toasts (spec §2.1).
public enum SGChatLockToast {
    case chatLockOn
    case chatLockOff
    case masterChanged
    case chatLocked
    case lockRemoved
    case pincodeChanged
}

public enum SGChatLockFlows {

    // MARK: - Visibility

    /// Whether a chat's profile ("Lock Chat" / "Chat Lock…") and its chat-list row ("Lock Chat" / "Remove
    /// Lock") may offer the lock actions: never for the account peer (Saved Messages), in an app extension,
    /// while the Chat Lock credentials must be set up again, while the master credential is unreadable, or
    /// for a vault-hidden peer while that vault is closed (its existence must not be revealed). Main thread.
    public static func canOfferLockActions(peerId: EnginePeer.Id, context: AccountContext) -> Bool {
        let accountPeerId = context.account.peerId
        if peerId == accountPeerId {
            return false
        }
        if SGChatLockFlows.isAppExtension {
            return false
        }
        let manager = ChatPincodeManager.shared
        if manager.protectionRecoveryStatus().chatLockNeedsRecovery {
            return false
        }
        if manager.masterCredentialState() == .unreadable {
            return false
        }
        let session = ChatLockSession.shared
        if session.isVaultHidden(peerId: peerId, accountPeerId: accountPeerId) && !session.isVaultOpen(accountPeerId: accountPeerId) {
            return false
        }
        return true
    }

    // MARK: - Per-chat flows

    /// F2 / F3: a new pincode for `peerId`. With a master: CREATE gate → the chat's `.set` → `setPincode`.
    /// Without one: explainer → gate → the master's `.set` → `setMasterPincode` → immediately the chat's
    /// `.set` → `setPincode`; cancelling after the master write leaves Chat Lock on with no locked chat,
    /// which every screen renders consistently. `title` is the chat's display title (nil keeps the generic
    /// caption; a vault-hidden chat is never named).
    public static func lockChat(peerId: EnginePeer.Id, title: String?, context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        guard SGChatLockFlows.guardWritable() else {
            completion(.blockedByRecovery)
            return
        }
        guard peerId != context.account.peerId, !ChatPincodeManager.shared.isLocked(peerId) else {
            completion(.cancelled)
            return
        }
        let subject = PincodeSubject(peerId: peerId, title: SGChatLockFlows.nameableTitle(title, peerId: peerId, context: context))
        SGChatLockFlows.start(.lockChat(peerId: peerId.toInt64()), subject: subject, context: context, host: host, completion: completion)
    }

    /// F4: the chat's current code (or, via "Forgot pincode?", the master) → a new code. The lock and its
    /// biometric choice are kept.
    public static func changePincode(peerId: EnginePeer.Id, title: String?, context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        guard SGChatLockFlows.guardWritable() else {
            completion(.blockedByRecovery)
            return
        }
        guard ChatPincodeManager.shared.isLocked(peerId) else {
            completion(.cancelled)
            return
        }
        let subject = PincodeSubject(peerId: peerId, title: SGChatLockFlows.nameableTitle(title, peerId: peerId, context: context))
        SGChatLockFlows.start(.changePincode(peerId: peerId.toInt64()), subject: subject, context: context, host: host, completion: completion)
    }

    /// F5: the chat's current code (or the master) → the lock is removed, together with every locked legacy
    /// group that was upgraded to this chat (otherwise the vault watcher re-locks it at once).
    public static func removeLock(peerId: EnginePeer.Id, title: String?, context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        guard SGChatLockFlows.guardWritable() else {
            completion(.blockedByRecovery)
            return
        }
        guard ChatPincodeManager.shared.isLocked(peerId) else {
            completion(.cancelled)
            return
        }
        let subject = PincodeSubject(peerId: peerId, title: SGChatLockFlows.nameableTitle(title, peerId: peerId, context: context))
        SGChatLockFlows.start(.removeLock(peerId: peerId.toInt64()), subject: subject, context: context, host: host, completion: completion)
    }

    /// F6: OFF needs no proof (capability only shrinks). ON: the chat's code → `setBiometricEnabled(true)`
    /// (records the enrolment baseline); proven with the master instead → a new chat code first, written
    /// with biometrics on (never enable biometrics on a code the owner cannot enter).
    public static func setBiometrics(_ enabled: Bool, peerId: EnginePeer.Id, title: String?, context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        guard SGChatLockFlows.guardWritable() else {
            completion(.blockedByRecovery)
            return
        }
        guard ChatPincodeManager.shared.isLocked(peerId) else {
            completion(.cancelled)
            return
        }
        let subject = PincodeSubject(peerId: peerId, title: SGChatLockFlows.nameableTitle(title, peerId: peerId, context: context))
        SGChatLockFlows.start(.setBiometrics(enabled, peerId: peerId.toInt64()), subject: subject, context: context, host: host, completion: completion)
    }

    // MARK: - Master flows

    /// F1: the first master pincode (Turn On Chat Lock / Set Master Pincode): explainer → CREATE gate → the
    /// master's `.set` → `setMasterPincode`. `legacy` is the hub's LEGACY state (chats already locked without
    /// a master): the explainer then presents the master as their recovery key instead of promising a first
    /// chat to lock. The caller decides what follows (the hub pushes the picker in OFF and after "Add a Chat…").
    public static func armMaster(legacy: Bool, context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        guard SGChatLockFlows.guardWritable() else {
            completion(.blockedByRecovery)
            return
        }
        guard !ChatPincodeManager.shared.isMasterEnabled() else {
            completion(.cancelled)
            return
        }
        SGChatLockFlows.start(.armMaster(legacy: legacy), subject: PincodeSubject(peerId: nil, title: nil), context: context, host: host, completion: completion)
    }

    /// F7: the current master → a new one. The EXISTING master is re-written, so its generation marker (the
    /// vault's "Forgot" rung 2) survives; its biometric choice is kept.
    public static func changeMaster(context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        guard SGChatLockFlows.guardWritable() else {
            completion(.blockedByRecovery)
            return
        }
        guard ChatPincodeManager.shared.isMasterEnabled() else {
            completion(.cancelled)
            return
        }
        SGChatLockFlows.start(.changeMaster, subject: PincodeSubject(peerId: nil, title: nil), context: context, host: host, completion: completion)
    }

    /// F8: OFF needs no proof; ON: the master → `setMasterBiometricEnabled(true)` (records the baseline).
    public static func setMasterBiometrics(_ enabled: Bool, context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        guard SGChatLockFlows.guardWritable() else {
            completion(.blockedByRecovery)
            return
        }
        guard ChatPincodeManager.shared.isMasterEnabled() else {
            completion(.cancelled)
            return
        }
        SGChatLockFlows.start(.setMasterBiometrics(enabled), subject: PincodeSubject(peerId: nil, title: nil), context: context, host: host, completion: completion)
    }

    /// F9: confirmation alert → the master (exactly today's Settings screen: `turnsOffChatLock`, Reset after 4
    /// wrong entries) → `disableChatLock()` (sweeps the master and every chat, keeps the vault credential).
    public static func turnOff(context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        guard SGChatLockFlows.guardWritable() else {
            completion(.blockedByRecovery)
            return
        }
        guard ChatPincodeManager.shared.isMasterEnabled() else {
            completion(.cancelled)
            return
        }
        SGChatLockFlows.presentTurnOffConfirmation(context: context, host: host, completion: { proceed in
            guard proceed else {
                completion(.cancelled)
                return
            }
            SGChatLockFlows.start(.turnOff, subject: PincodeSubject(peerId: nil, title: nil), context: context, host: host, completion: completion)
        })
    }

    /// F10 (LEGACY): confirmation alert → device-owner proof (`runTurnOffChatLockRecovery`; the iPhone
    /// passcode is allowed because no credential exists to ask for) → Chat Lock off. Ungated and never
    /// blocked by the recovery bit (it is a recovery exit); `.unavailable` is surfaced, never a silent no-op.
    /// Runs only while the master credential is `.absent` (re-read again right before the proof): a PRESENT
    /// master is the credential to ask for, so that state is `turnOff`'s (the master screen, Reset after 4
    /// wrong entries) and is refused here with `.cancelled` — the iPhone passcode alone must never turn Chat
    /// Lock off past an existing master; an UNREADABLE keychain is never acted on, like every other flow.
    public static func turnOffWithoutMaster(context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        guard ChatPincodeManager.shared.masterCredentialState() == .absent else {
            completion(.cancelled)
            return
        }
        SGChatLockFlows.presentTurnOffConfirmation(context: context, host: host, completion: { proceed in
            guard proceed else {
                completion(.cancelled)
                return
            }
            SGChatLockFlows.start(.turnOffWithoutMaster, subject: PincodeSubject(peerId: nil, title: nil), context: context, host: host, completion: completion)
        })
    }

    // MARK: - Picker

    /// "Add a Chat…" (spec §2.3): the chat picker pushed on the host's stack — no `.onlyWriteable` (read-only
    /// channels must be lockable), never `.includeSelf`, `excluded` ∪ {account peer}. `onPicked` receives the
    /// chat, its display title and the picker itself: present the chat's `.set` OVER the picker (`lockChat`
    /// with `SGChatLockHost(controller: picker)`) and dismiss the picker on `.done`, so a cancelled screen
    /// keeps the picker for another choice. Vault chats never appear (the chat list hides them outside the
    /// vault). Note: the picker's exclusions filter its search results; a locked chat picked from the list is
    /// refused by `lockChat` (`.cancelled`) rather than re-locked without proof.
    @discardableResult
    public static func presentPicker(context: AccountContext, host: SGChatLockHost, excluded: Set<EnginePeer.Id>, onPicked: @escaping (EnginePeer, String, ViewController) -> Void) -> ViewController {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var excludedPeerIds = excluded
        excludedPeerIds.insert(context.account.peerId)
        let picker = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(
            context: context,
            filter: [.excludeSavedMessages, .excludeRecent, .doNotSearchMessages, .removeSearchHeader],
            hasChatListSelector: true,
            hasContactSelector: false,
            hasGlobalSearch: false,
            title: SGChatLockCenterStrings.pickerTitle,
            excludedPeerIds: excludedPeerIds
        ))
        picker.peerSelected = { [weak picker] peer, _ in
            guard let picker else {
                return
            }
            let title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
            onPicked(peer, title, picker)
        }
        host.push(picker)
        return picker
    }

    // MARK: - Icon, toasts, alerts

    /// The profile "…" item's icon (spec §2.5): a tinted SF `lock.shield` — NOT "Chat/Context Menu/Lock",
    /// which is already "Start Secret Chat" in the same menu.
    public static func menuIcon(color: UIColor) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 17.0, weight: .regular)
        let image = UIImage(systemName: "lock.shield", withConfiguration: configuration)?.withRenderingMode(.alwaysTemplate)
        return generateTintedImage(image: image, color: color)
    }

    /// A completion toast, through `host.presentOverlay` (precedent: the Settings retention toast).
    public static func toast(_ toast: SGChatLockToast, context: AccountContext, host: SGChatLockHost) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let text: String
        switch toast {
        case .chatLockOn:
            text = SGChatLockCenterStrings.toastChatLockOn
        case .chatLockOff:
            text = SGChatLockCenterStrings.toastChatLockOff
        case .masterChanged:
            text = SGChatLockCenterStrings.toastMasterChanged
        case .chatLocked:
            text = SGChatLockCenterStrings.toastChatLocked
        case .lockRemoved:
            text = SGChatLockCenterStrings.toastLockRemoved
        case .pincodeChanged:
            text = SGChatLockCenterStrings.toastPincodeChanged
        }
        host.presentOverlay(UndoOverlayController(
            presentationData: presentationData,
            content: .info(title: nil, text: text, timeout: nil, customUndoText: nil),
            elevatedLayout: false,
            action: { _ in return true }
        ))
    }

    /// Every device-owner action proves ownership first, and an iPhone with neither a passcode nor an
    /// enrolled biometric has nothing to prove it with: this is what the user is told (same copy as the
    /// Settings recovery sheet).
    public static func presentDeviceAuthUnavailable(context: AccountContext, host: SGChatLockHost) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        host.presentOverlay(textAlertController(context: context, title: SGProtectionStrings.deviceAuthUnavailableTitle, text: SGProtectionStrings.deviceAuthUnavailableText, actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]))
    }

    // MARK: - Private: preconditions

    /// `SGProtectedStore.isAppExtension`, spelled out so this module needs no store dependency.
    private static var isAppExtension: Bool {
        return Bundle.main.bundlePath.hasSuffix(".appex")
    }

    private static var hasBiometrics: Bool {
        return ChatLockBiometricHelper.availableType() != nil
    }

    /// Re-read immediately before every write (spec §6 C2, J2 #5): nothing is written while the Chat Lock
    /// credentials must be set up again (the locked-ids mirror is frozen; `setPincode` / `setMasterPincode`
    /// must not run) or while the master credential is unreadable (an "absent" read on an unreadable
    /// keychain could let a new master overwrite a real one).
    private static func guardWritable() -> Bool {
        let manager = ChatPincodeManager.shared
        if manager.protectionRecoveryStatus().chatLockNeedsRecovery {
            return false
        }
        if manager.masterCredentialState() == .unreadable {
            return false
        }
        return true
    }

    /// The title a PIN screen may show: never for a vault-hidden chat (the `sgChatLockMayNameChat` rule),
    /// nil for an empty title.
    private static func nameableTitle(_ title: String?, peerId: EnginePeer.Id, context: AccountContext) -> String? {
        guard let title, !title.isEmpty else {
            return nil
        }
        if ChatLockSession.shared.isVaultHidden(peerId: peerId, accountPeerId: context.account.peerId) {
            return nil
        }
        return title
    }

    // MARK: - Private: alerts

    /// The set-up explainer (spec §2.4): Cancel / Continue, no outside-tap dismissal so the flow always learns
    /// the answer.
    private static func presentExplainer(_ spec: SGChatLockExplainerSpec, context: AccountContext, host: SGChatLockHost, completion: @escaping (Bool) -> Void) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let text: String
        switch spec {
        case .hub:
            text = SGChatLockCenterStrings.setupTextFromHub
        case .chat:
            text = SGChatLockCenterStrings.setupTextFromChat
        case .legacy:
            text = SGChatLockCenterStrings.setupTextLegacy
        }
        host.presentOverlay(textAlertController(context: context, title: SGChatLockCenterStrings.setupTitle, text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {
                completion(false)
            }),
            TextAlertAction(type: .defaultAction, title: SGChatLockCenterStrings.continueAction, action: {
                completion(true)
            })
        ], dismissOnOutsideTap: false))
    }

    /// The turn-off confirmation: the existing `Settings.ChatLock.Disable.*` texts (not duplicated here).
    private static func presentTurnOffConfirmation(context: AccountContext, host: SGChatLockHost, completion: @escaping (Bool) -> Void) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        host.presentOverlay(textAlertController(context: context, title: i18n("Settings.ChatLock.Disable.Title", lang), text: i18n("Settings.ChatLock.Disable.Text", lang), actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {
                completion(false)
            }),
            TextAlertAction(type: .destructiveAction, title: i18n("Settings.ChatLock.Disable.Action", lang), action: {
                completion(true)
            })
        ], dismissOnOutsideTap: false))
    }

    // MARK: - Private: PIN screens

    /// The chat a flow is about (nil for master-only flows) and the title its screens may show.
    private struct PincodeSubject {
        let peerId: EnginePeer.Id?
        let title: String?
    }

    /// What a `.verify` screen proved.
    private enum Proof {
        case code(ChatLockPasswordType)
        case master(ChatLockPasswordType)
    }

    private struct PincodeHandlers {
        /// `.verify`: the screen succeeded with this proof (after its dismissal).
        let onProof: ((Proof) -> Void)?
        /// `.set`: the new credential, its type and whether biometrics are on by default.
        let onSet: ((String, ChatLockPasswordType, Bool) -> Void)?
        /// The device-owner "Reset Chat Lock" rung ran: Chat Lock is off now.
        let onReset: (() -> Void)?
        /// The screen was closed without a result.
        let onCancel: () -> Void
    }

    /// Wraps a PIN screen in the hidden-bar, full-screen UIKit container every Chat Lock screen uses and hands
    /// it to the host.
    private static func presentPincode(_ controller: ChatPincodeViewController, host: SGChatLockHost) {
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.setNavigationBarHidden(true, animated: false)
        navigationController.modalPresentationStyle = .fullScreen
        host.present(navigationController)
    }

    private static func throttleScope(_ scope: SGChatLockScopeSpec) -> ChatLockThrottle.Scope {
        switch scope {
        case let .chat(id):
            return .chat(EnginePeer.Id(id))
        case .master:
            return .master
        }
    }

    /// The caption a spec step names, resolved against the subject (the chat captions name the chat only when
    /// it may be named) and the device's biometry; nil keeps the step's default copy.
    private static func caption(_ key: String, subject: PincodeSubject) -> String? {
        guard !key.isEmpty, let copyKey = SGChatLockCopyKey(rawValue: key) else {
            return nil
        }
        switch copyKey {
        case .captionChat:
            return SGChatLockCenterStrings.captionChat(subject.title)
        case .captionNewChat:
            return SGChatLockCenterStrings.captionNewChat(subject.title)
        case .verifyToEnableBiometrics:
            return SGChatLockCenterStrings.verifyToEnableBiometrics()
        case .masterToEnableBiometrics:
            return SGChatLockCenterStrings.masterToEnableBiometrics()
        case .masterLadderForBiometrics:
            return SGChatLockCenterStrings.masterLadderForBiometrics()
        default:
            return SGChatLockCenterStrings.text(copyKey)
        }
    }

    /// THE site that turns a `.verify` / `.set` spec step into a screen. `ladder` is the master screen a
    /// per-chat `.verify` pushes from "Forgot pincode?" (`sgChatLockMasterLadder`), built through this same
    /// function. nil for a step that is not a screen.
    private static func makePincodeController(spec: SGChatLockFlowSpec, subject: PincodeSubject, ladder: SGChatLockFlowSpec?, presentationData: PresentationData, handlers: PincodeHandlers) -> ChatPincodeViewController? {
        let manager = ChatPincodeManager.shared
        switch spec {
        case let .set(scope, captionKey):
            let onSet = handlers.onSet
            let controller = ChatPincodeViewController(
                mode: .set(onSuccess: { code, type, biometricEnabled in
                    onSet?(code, type, biometricEnabled)
                }),
                presentationData: presentationData,
                throttleScope: SGChatLockFlows.throttleScope(scope)
            )
            controller.subtitleOverride = SGChatLockFlows.caption(captionKey, subject: subject)
            controller.onCancel = handlers.onCancel
            return controller
        case let .verify(scope, purpose, recovery, isMasterRecovery, biometricEnabled, turnsOffChatLock, subtitleKey):
            let onProof = handlers.onProof
            let recoveryValue: ChatPincodeRecovery
            switch recovery {
            case .none:
                // No "Forgot pincode?" (no master exists); `.legacy` with `onForgot: nil` shows no button.
                recoveryValue = .legacy
            case .masterPin:
                guard let ladder else {
                    return nil
                }
                let ladderHandlers = PincodeHandlers(onProof: handlers.onProof, onSet: nil, onReset: handlers.onReset, onCancel: {})
                recoveryValue = .masterPin(makeMasterController: {
                    // Same site, same invariants. `sgChatLockMasterLadder` only ever produces a `.verify`
                    // step, so this cannot fail; it must never fall back to an open screen.
                    guard let master = SGChatLockFlows.makePincodeController(spec: ladder, subject: subject, ladder: nil, presentationData: presentationData, handlers: ladderHandlers) else {
                        preconditionFailure("Chat Lock: the master ladder must be a .verify step")
                    }
                    return master
                })
            case .resetChatLock:
                let onReset = handlers.onReset
                recoveryValue = .resetChatLock(onReset: {
                    onReset?()
                })
            }
            let mode: ChatPincodeMode
            switch scope {
            case let .chat(id):
                let peerId = EnginePeer.Id(id)
                let metadata = manager.getMetadata(for: peerId)
                // Biometrics may stand in only on an unlock screen whose credential has them on; management
                // screens pass false (belt and braces with `purpose: .manage`).
                let allowsBiometrics = biometricEnabled && purpose == .unlock && metadata.biometricEnabled
                mode = .verify(passwordType: metadata.passwordType, biometricEnabled: allowsBiometrics, onVerify: { code in
                    return manager.verify(code, for: peerId)
                }, onSuccess: {
                    onProof?(.code(metadata.passwordType))
                }, onForgot: nil)
            case .master:
                let metadata = manager.getMasterMetadata()
                let allowsBiometrics = biometricEnabled && purpose == .unlock && metadata.biometricEnabled
                mode = .verify(passwordType: metadata.passwordType, biometricEnabled: allowsBiometrics, onVerify: { code in
                    return manager.verifyMaster(code)
                }, onSuccess: {
                    onProof?(.master(metadata.passwordType))
                }, onForgot: nil)
            }
            let controller = ChatPincodeViewController(
                mode: mode,
                presentationData: presentationData,
                isMasterRecovery: isMasterRecovery,
                recovery: recoveryValue,
                throttleScope: SGChatLockFlows.throttleScope(scope),
                turnsOffChatLock: turnsOffChatLock,
                purpose: purpose == .manage ? .manage : .unlock
            )
            if case .chat = scope {
                controller.chatTitle = subject.title
            }
            controller.subtitleOverride = SGChatLockFlows.caption(subtitleKey, subject: subject)
            controller.onCancel = handlers.onCancel
            return controller
        case .gate, .explainer, .deviceOwnerTurnOff, .write:
            return nil
        }
    }

    // MARK: - Private: the interpreter

    private static func start(_ action: SGChatLockAction, subject: PincodeSubject, context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
        let masterExists = ChatPincodeManager.shared.isMasterEnabled()
        let run = Run(
            action: action,
            steps: sgChatLockFlow(for: action, masterExists: masterExists, hasBiometrics: SGChatLockFlows.hasBiometrics),
            ladder: sgChatLockMasterLadder(for: action, masterExists: masterExists),
            subject: subject,
            context: context,
            host: host,
            completion: completion
        )
        run.advance()
    }

    /// Walks one action's steps. Kept alive by the screens' handlers while a screen is up; released with the
    /// completion.
    private final class Run {
        private let action: SGChatLockAction
        private var steps: [SGChatLockFlowSpec]
        private let ladder: SGChatLockFlowSpec?
        private let subject: PincodeSubject
        private let context: AccountContext
        private let host: SGChatLockHost
        private let presentationData: PresentationData
        private let completion: (SGChatLockFlowOutcome) -> Void
        private var index = 0
        private var lastSet: (code: String, type: ChatLockPasswordType, biometricEnabled: Bool)?
        private var lastProof: Proof?
        private var turnedOffByDeviceOwner = false
        private var finished = false

        init(action: SGChatLockAction, steps: [SGChatLockFlowSpec], ladder: SGChatLockFlowSpec?, subject: PincodeSubject, context: AccountContext, host: SGChatLockHost, completion: @escaping (SGChatLockFlowOutcome) -> Void) {
            self.action = action
            self.steps = steps
            self.ladder = ladder
            self.subject = subject
            self.context = context
            self.host = host
            self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
            self.completion = completion
        }

        private var accountPeerId: Int64 {
            return self.context.account.peerId.toInt64()
        }

        private func finish(_ outcome: SGChatLockFlowOutcome) {
            guard !self.finished else {
                return
            }
            self.finished = true
            self.completion(outcome)
        }

        func advance() {
            guard !self.finished else {
                return
            }
            guard self.index < self.steps.count else {
                self.finish(.done)
                return
            }
            let step = self.steps[self.index]
            self.index += 1
            switch step {
            case let .explainer(spec):
                SGChatLockFlows.presentExplainer(spec, context: self.context, host: self.host, completion: { proceed in
                    if proceed {
                        self.advance()
                    } else {
                        self.finish(.cancelled)
                    }
                })
            case .gate:
                // The re-check after the explainer (F1 / F3), before the paywall can be shown.
                guard SGChatLockFlows.guardWritable() else {
                    self.finish(.blockedByRecovery)
                    return
                }
                guard sgEntitlementGate(.createChatLockPincode, context: self.context, present: self.host.presentOverlay) else {
                    // Paywall shown (or the capability is unavailable): nothing was written.
                    self.finish(.cancelled)
                    return
                }
                self.advance()
            case .verify:
                let handlers = PincodeHandlers(onProof: { proof in
                    self.lastProof = proof
                    if case .master = proof, let peerId = self.subject.peerId {
                        // The master outranks every chat code: the chat's budget is cleared too.
                        ChatLockThrottle.reset(.chat(peerId))
                    }
                    self.advance()
                }, onSet: nil, onReset: {
                    // The device-owner Reset turned Chat Lock off: for turn-off that IS the action.
                    self.finish(self.action == .turnOff ? .done : .cancelled)
                }, onCancel: {
                    self.finish(.cancelled)
                })
                guard let controller = SGChatLockFlows.makePincodeController(spec: step, subject: self.subject, ladder: self.ladder, presentationData: self.presentationData, handlers: handlers) else {
                    self.finish(.cancelled)
                    return
                }
                SGChatLockFlows.presentPincode(controller, host: self.host)
            case .set:
                let handlers = PincodeHandlers(onProof: nil, onSet: { code, type, biometricEnabled in
                    self.lastSet = (code, type, biometricEnabled)
                    self.advance()
                }, onReset: nil, onCancel: {
                    self.finish(.cancelled)
                })
                guard let controller = SGChatLockFlows.makePincodeController(spec: step, subject: self.subject, ladder: nil, presentationData: self.presentationData, handlers: handlers) else {
                    self.finish(.cancelled)
                    return
                }
                SGChatLockFlows.presentPincode(controller, host: self.host)
            case .deviceOwnerTurnOff:
                // F10: the device-owner proof stands in only while there is no master to ask for (re-read here,
                // after the confirmation alert, like every write re-reads its precondition). The recovery bit is
                // deliberately not consulted: this step is a recovery exit.
                guard ChatPincodeManager.shared.masterCredentialState() == .absent else {
                    self.finish(.cancelled)
                    return
                }
                ChatLockSession.shared.runTurnOffChatLockRecovery(completion: { result in
                    switch result {
                    case .success:
                        // `resolveChatLockRecoveryByTurningOff` = `disableChatLock()`: the write is done.
                        self.turnedOffByDeviceOwner = true
                        SGAnalytics.record(.chatLockLockRemoved, accountPeerId: self.accountPeerId)
                        self.advance()
                    case .cancelled:
                        self.finish(.cancelled)
                    case .unavailable:
                        SGChatLockFlows.presentDeviceAuthUnavailable(context: self.context, host: self.host)
                        self.finish(.cancelled)
                    }
                })
            case let .write(kind):
                self.perform(kind)
            }
        }

        private func perform(_ kind: SGChatLockWriteSpec) {
            let manager = ChatPincodeManager.shared
            switch kind {
            case .setMasterPincode:
                guard SGChatLockFlows.guardWritable() else {
                    self.finish(.blockedByRecovery)
                    return
                }
                guard let set = self.lastSet else {
                    self.finish(.cancelled)
                    return
                }
                self.lastSet = nil
                if case .changeMaster = self.action {
                    // F7: the existing master is re-written (its generation marker survives); its biometric
                    // choice is kept. No analytics event.
                    let metadata = manager.getMasterMetadata()
                    manager.setMasterPincode(set.code, type: set.type, biometricEnabled: metadata.biometricEnabled && SGChatLockFlows.hasBiometrics)
                } else {
                    // F1 / F3: the first master is armed. Never over a master that appeared meanwhile — a
                    // master is only ever replaced with its own proof (changeMaster).
                    if manager.isMasterEnabled() {
                        if case .lockChat = self.action {
                            self.advance()
                        } else {
                            self.finish(.cancelled)
                        }
                        return
                    }
                    manager.setMasterPincode(set.code, type: set.type, biometricEnabled: set.biometricEnabled)
                    SGAnalytics.record(.chatLockLockSet(method: set.type == .text ? .password : .pin, biometric: set.biometricEnabled), accountPeerId: self.accountPeerId)
                }
                self.advance()
            case .setPincode:
                guard SGChatLockFlows.guardWritable() else {
                    self.finish(.blockedByRecovery)
                    return
                }
                guard let peerId = self.subject.peerId, let set = self.lastSet else {
                    self.finish(.cancelled)
                    return
                }
                self.lastSet = nil
                switch self.action {
                case .lockChat:
                    // F2 / F3: never over an existing lock without its proof, and never while no master
                    // exists (J2 #3).
                    guard !manager.isLocked(peerId), manager.isMasterEnabled() else {
                        self.finish(.cancelled)
                        return
                    }
                    manager.setPincode(set.code, for: peerId, type: set.type, biometricEnabled: set.biometricEnabled)
                    SGAnalytics.record(.chatLockLockSet(method: set.type == .text ? .password : .pin, biometric: set.biometricEnabled), accountPeerId: self.accountPeerId)
                case .changePincode:
                    // F4: the lock and its biometric choice are kept; only the code (and its type) change.
                    // No analytics event.
                    guard manager.isLocked(peerId) else {
                        self.finish(.cancelled)
                        return
                    }
                    let metadata = manager.getMetadata(for: peerId)
                    manager.setPincode(set.code, for: peerId, type: set.type, biometricEnabled: metadata.biometricEnabled && SGChatLockFlows.hasBiometrics)
                case .setBiometrics:
                    // F6 via the master ladder: a new code the owner can enter, with biometrics on (the
                    // enrolment baseline is recorded in the same write).
                    guard manager.isLocked(peerId) else {
                        self.finish(.cancelled)
                        return
                    }
                    manager.setPincode(set.code, for: peerId, type: set.type, biometricEnabled: true)
                case .armMaster, .removeLock, .changeMaster, .setMasterBiometrics, .turnOff, .turnOffWithoutMaster:
                    self.finish(.cancelled)
                    return
                }
                self.advance()
            case .removePincode:
                guard SGChatLockFlows.guardWritable() else {
                    self.finish(.blockedByRecovery)
                    return
                }
                guard let peerId = self.subject.peerId else {
                    self.finish(.cancelled)
                    return
                }
                self.removeLockAndPairs(of: peerId)
            case .setBiometrics:
                guard case let .setBiometrics(enabled, _) = self.action, let peerId = self.subject.peerId else {
                    self.finish(.cancelled)
                    return
                }
                if enabled, case .master? = self.lastProof {
                    // Proven with the master: biometrics are never enabled on a code the owner cannot enter,
                    // so a new chat code is set first and written with biometrics on (F6).
                    self.lastProof = nil
                    self.steps.insert(contentsOf: [
                        .set(scope: .chat(peerId.toInt64()), captionKey: SGChatLockCopyKey.captionNewChat.rawValue),
                        .write(.setPincode)
                    ], at: self.index)
                    self.advance()
                    return
                }
                guard SGChatLockFlows.guardWritable() else {
                    self.finish(.blockedByRecovery)
                    return
                }
                guard manager.isLocked(peerId) else {
                    self.finish(.cancelled)
                    return
                }
                // ON records the enrolment baseline (audit #40); OFF needs no proof. No analytics event.
                manager.setBiometricEnabled(enabled, for: peerId)
                self.advance()
            case .setMasterBiometrics:
                guard case let .setMasterBiometrics(enabled) = self.action else {
                    self.finish(.cancelled)
                    return
                }
                guard SGChatLockFlows.guardWritable() else {
                    self.finish(.blockedByRecovery)
                    return
                }
                guard manager.isMasterEnabled() else {
                    self.finish(.cancelled)
                    return
                }
                manager.setMasterBiometricEnabled(enabled)
                self.advance()
            case .disableChatLock:
                if self.turnedOffByDeviceOwner {
                    // F10: `runTurnOffChatLockRecovery` already turned Chat Lock off (and the event is recorded).
                    self.advance()
                    return
                }
                guard SGChatLockFlows.guardWritable() else {
                    self.finish(.blockedByRecovery)
                    return
                }
                // F9: sweeps the master and every chat's credential, keeps the vault credential, resets the
                // throttles and unfreezes the mirror.
                manager.disableChatLock()
                SGAnalytics.record(.chatLockLockRemoved, accountPeerId: self.accountPeerId)
                self.advance()
            }
        }

        /// F5: removes `peerId`'s lock together with every locked legacy group upgraded to it (one engine
        /// lookup over the locked ids in the legacy-group namespace), then ONE `chat_lock.lock_removed`.
        private func removeLockAndPairs(of peerId: EnginePeer.Id) {
            let manager = ChatPincodeManager.shared
            let lockedIds = manager.lockedPeerIds()
            let lockedValues = Set(lockedIds.map { $0.toInt64() })
            let target = peerId.toInt64()
            let apply: ([Int64: Int64?]) -> Void = { migrationTargets in
                let removal = sgChatLockRemovalSet(target: target, lockedIds: lockedValues, migrationTargets: migrationTargets)
                for id in removal.sorted() {
                    manager.removePincode(for: EnginePeer.Id(id))
                }
                ChatLockThrottle.reset(.chat(peerId))
                SGAnalytics.record(.chatLockLockRemoved, accountPeerId: self.accountPeerId)
                self.advance()
            }
            let legacyGroupIds = lockedIds.filter { $0 != peerId && $0.namespace == Namespaces.Peer.CloudGroup }
            guard !legacyGroupIds.isEmpty else {
                apply([:])
                return
            }
            let _ = (self.context.engine.data.get(EngineDataMap(legacyGroupIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { peers in
                var migrationTargets: [Int64: Int64?] = [:]
                for (id, peer) in peers {
                    guard let peer else {
                        // Unresolved in this account: not paired (and not removed).
                        continue
                    }
                    if case let .legacyGroup(group) = peer {
                        migrationTargets[id.toInt64()] = .some(group.migrationReference?.peerId.toInt64())
                    } else {
                        migrationTargets[id.toInt64()] = .some(nil)
                    }
                }
                apply(migrationTargets)
            })
        }
    }
}
