import Foundation
import SGSimpleSettings
import SGChatLock

// MARK: Zenlygram — Chat Lock Center: the accessor over `SGChatLockCopy` (wf14-chatlock spec §2).
//
// Keyed on `SGSimpleSettings.shared.languageCode` exactly like `FenixuzChatLockStrings.localized(en:uz:ru:)`
// — it is fed from `presentationData.strings.baseLanguageCode` (SharedAccountContext), so this module's
// copy, the SGChatLock strings it reuses (`SGProtectionStrings`) and the `SGLocalizable` texts the flows
// reuse through `i18n` all speak the same language.

public enum SGChatLockCenterStrings {

    // MARK: - Language

    /// The copy of `key` in the module's language.
    public static func text(_ key: SGChatLockCopyKey) -> String {
        let copy = SGChatLockCopy.copy(for: key)
        switch SGSimpleSettings.shared.languageCode {
        case "uz":
            return copy.uz
        case "ru":
            return copy.ru
        default:
            return copy.en
        }
    }

    /// "Face ID" / "Touch ID" for every `%@`, resolved at runtime from the device. "Face ID" when the device
    /// has neither — those rows and captions are not shown then.
    public static var biometricName: String {
        return ChatLockBiometricHelper.availableType() == .touchID ? "Touch ID" : "Face ID"
    }

    private static func format(_ key: SGChatLockCopyKey, _ arguments: String...) -> String {
        return SGChatLockCopy.fill(text(key), arguments)
    }

    // MARK: - §1 — the model

    public static var model: String { return text(.model) }

    // MARK: - §2.1 — hub

    public static var title: String { return text(.title) }
    public static var turnOn: String { return text(.turnOn) }
    public static var offExplainer: String { return text(.offExplainer) }
    public static var masterHeader: String { return text(.masterHeader) }
    public static var changeMaster: String { return text(.changeMaster) }

    public static func masterBiometrics(_ biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        return format(.masterBiometrics, biometry)
    }

    public static func masterBiometricsFooter(_ biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        return format(.masterBiometricsFooter, biometry, biometry)
    }

    public static var masterFooter: String { return text(.masterFooter) }

    /// Footer of the MASTER PINCODE section: the biometric sentence (when the switch exists) above the
    /// static one.
    public static func masterSectionFooter(showsBiometrics: Bool, biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        if showsBiometrics {
            return masterBiometricsFooter(biometry) + "\n\n" + masterFooter
        }
        return masterFooter
    }

    public static var lockedChatsHeader: String { return text(.lockedChatsHeader) }
    public static var lockTypePin: String { return text(.lockTypePin) }
    public static var lockTypePassword: String { return text(.lockTypePassword) }

    /// A locked chat's row subtitle: the lock type, plus " · Face ID" while its biometrics are on and the
    /// device has them.
    public static func lockSubtitle(isPassword: Bool, biometrics: Bool, biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        let type = isPassword ? lockTypePassword : lockTypePin
        return biometrics ? type + " · " + biometry : type
    }

    public static var swipeRemove: String { return text(.swipeRemove) }
    public static var addChat: String { return text(.addChat) }
    public static var listFooter: String { return text(.listFooter) }
    public static var emptyFooter: String { return text(.emptyFooter) }
    public static var vaultFooter: String { return text(.vaultFooter) }
    public static var otherAccountsFooter: String { return text(.otherAccountsFooter) }

    /// Footer of the LOCKED CHATS section: list / empty sentence, then the static vault sentence (always —
    /// its presence leaks nothing), then the other-accounts sentence when more than one account is logged in.
    public static func lockedChatsFooter(empty: Bool, otherAccounts: Bool) -> String {
        var parts = [empty ? emptyFooter : listFooter, vaultFooter]
        if otherAccounts {
            parts.append(otherAccountsFooter)
        }
        return parts.joined(separator: "\n\n")
    }

    public static var turnOffFooter: String { return text(.turnOffFooter) }
    public static var legacySetMaster: String { return text(.legacySetMaster) }
    public static var legacyNotice: String { return text(.legacyNotice) }
    public static var legacyTurnOffFooter: String { return text(.legacyTurnOffFooter) }

    /// Footer of the LEGACY turn-off section: the device-owner sentence, plus the "set a device passcode"
    /// hint while the device cannot prove ownership.
    public static func legacyTurnOffSectionFooter(canAuthDeviceOwner: Bool) -> String {
        if canAuthDeviceOwner {
            return legacyTurnOffFooter
        }
        return legacyTurnOffFooter + "\n\n" + SGProtectionStrings.deviceAuthUnavailableHint
    }

    public static var unreadableTitle: String { return text(.unreadableTitle) }
    public static var unreadableText: String { return text(.unreadableText) }

    /// The UNREADABLE notice.
    public static var unreadableNotice: String {
        return unreadableTitle + "\n\n" + unreadableText
    }

    /// The RECOVERY notice (count only, no named rows).
    public static func recoveryNotice(pendingCount: Int) -> String {
        return SGProtectionStrings.chatLockLostTitle + "\n\n" + SGProtectionStrings.chatLockLostText(count: pendingCount)
    }

    public static var toastChatLockOn: String { return text(.toastChatLockOn) }
    public static var toastChatLockOff: String { return text(.toastChatLockOff) }
    public static var toastMasterChanged: String { return text(.toastMasterChanged) }
    public static var toastChatLocked: String { return text(.toastChatLocked) }
    public static var toastLockRemoved: String { return text(.toastLockRemoved) }
    public static var toastPincodeChanged: String { return text(.toastPincodeChanged) }

    // MARK: - §2.2 — per-chat detail

    public static var changePincode: String { return text(.changePincode) }

    public static func unlockWithBiometrics(_ biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        return format(.unlockWithBiometrics, biometry)
    }

    /// The "Change Pincode" footer; its "Forgot…" sentence is omitted while no master exists (LEGACY).
    public static func changePincodeFooter(masterExists: Bool) -> String {
        if masterExists {
            return text(.changePincodeFooterType) + " " + text(.changePincodeFooterForgot)
        }
        return text(.changePincodeFooterType)
    }

    public static func chatBiometricsFooter(_ biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        return format(.chatBiometricsFooter, biometry, biometry)
    }

    /// Footer under "Change Pincode" / the Face ID switch: the change sentence(s), then the biometric
    /// sentence when the switch is shown.
    public static func changePincodeSectionFooter(masterExists: Bool, showsBiometrics: Bool, biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        if showsBiometrics {
            return changePincodeFooter(masterExists: masterExists) + "\n\n" + chatBiometricsFooter(biometry)
        }
        return changePincodeFooter(masterExists: masterExists)
    }

    public static var removeLock: String { return text(.removeLock) }

    /// The "Remove Lock" footer; its "Forgot…" sentence is omitted while no master exists (LEGACY).
    public static func removeFooter(masterExists: Bool) -> String {
        if masterExists {
            return text(.removeFooterAsks) + " " + text(.removeFooterForgot)
        }
        return text(.removeFooterAsks)
    }

    // MARK: - §2.3 — picker

    public static var pickerTitle: String { return text(.pickerTitle) }

    // MARK: - §2.4 — PIN screen captions

    public static var verifyToChange: String { return text(.verifyToChange) }
    public static var verifyToRemove: String { return text(.verifyToRemove) }

    public static func verifyToEnableBiometrics(_ biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        return format(.verifyToEnableBiometrics, biometry)
    }

    public static var masterToChange: String { return text(.masterToChange) }

    public static func masterToEnableBiometrics(_ biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        return format(.masterToEnableBiometrics, biometry)
    }

    public static var masterLadderForChange: String { return text(.masterLadderForChange) }
    public static var masterLadderForRemove: String { return text(.masterLadderForRemove) }

    public static func masterLadderForBiometrics(_ biometry: String = SGChatLockCenterStrings.biometricName) -> String {
        return format(.masterLadderForBiometrics, biometry)
    }

    public static var captionMaster: String { return text(.captionMaster) }
    public static var captionNewMaster: String { return text(.captionNewMaster) }

    /// "Pincode for <chat>", or the generic caption when the chat must not be named (vault-hidden) or has
    /// no resolved title.
    public static func captionChat(_ title: String?) -> String {
        if let title, !title.isEmpty {
            return format(.captionChat, title)
        }
        return text(.captionChatGeneric)
    }

    public static var captionChatGeneric: String { return text(.captionChatGeneric) }

    /// "New pincode for <chat>", or the generic caption (see `captionChat`).
    public static func captionNewChat(_ title: String?) -> String {
        if let title, !title.isEmpty {
            return format(.captionNewChat, title)
        }
        return text(.captionNewChatGeneric)
    }

    public static var captionNewChatGeneric: String { return text(.captionNewChatGeneric) }

    // MARK: - §2.4 — explainer alerts

    public static var continueAction: String { return text(.continueAction) }
    public static var setupTitle: String { return text(.setupTitle) }
    public static var setupTextFromHub: String { return text(.setupTextFromHub) }
    public static var setupTextFromChat: String { return text(.setupTextFromChat) }
    public static var setupTextLegacy: String { return text(.setupTextLegacy) }

    // MARK: - §2.5 — menus

    public static var menuLock: String { return text(.menuLock) }
    public static var menuManageLock: String { return text(.menuManageLock) }
    public static var menuRemoveLock: String { return text(.menuRemoveLock) }
}
