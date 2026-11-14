import Foundation
import SwiftSignalKit
import TelegramCore

public struct SGStatus: Equatable, Codable {
    // MARK: Zenlygram — THIS IS NOT THE ZENLYGRAM SUBSCRIPTION. Read this before using it.
    //
    // `SGStatus` is upstream Swiftgram's own Pro flag, and it now means exactly one thing here:
    // "may this build use upstream Swiftgram's Pro-gated extras?". Zenlygram answers yes,
    // always, for everyone — those extras are not what Zenlygram sells. Every value is therefore
    // still clamped to Pro (>= minimumStatus) at this single point: the memberwise init, the
    // decoder and direct assignments all funnel through the clamp, so a stored entry, a server
    // response or a default can never downgrade the app to a non-Pro state.
    //
    // **Zenlygram Pro — Secret Vault, Chat Lock, Tasks, Edit History and (later) the AI
    // Assistant — is `SGEntitlement`, never this.** Ask `SGEntitlement.can(.createVaultEntry)`
    // and friends; those gates cover CREATION only, and reading / un-hiding / unlocking /
    // deleting existing protected material is never gated at all (design §4.7).
    //
    // The deliberate in/out decision for every site that reads this value (design §8.3 items
    // 21, 23 and 24). All of them are OUT of the paid bundle, which is why the clamp stays:
    //
    //   - app icons                 ThemeSettingsController 637 / 1125-1126, ThemeSettingsAppIconItem 466
    //   - custom app badge          SGProUI/AppBadgeSelectorController 77, Display/WindowContent 352
    //   - input-panel toolbar       AttachmentTextInputPanelNode 2429, ChatTextInputPanelNode 5998,
    //                               MessageInputPanelComponent 3147
    //   - message keyword filter    ChatMessageItemView 703 (via SGSimpleSettings.ephemeralStatus)
    //   - OpenUrl deep link         OpenUrl 902
    //   - settings actions / rows   PeerInfoScreenSettingsActions 52, PeerInfoSettingsItems 209
    //   - notification exceptions   NotificationService (pinned / mention-and-reply actions)
    //
    // Adding a NEW reader of `status` is almost always a mistake: if the feature is one of the
    // five Zenlygram sells, it belongs behind `SGEntitlement`; if it is not, it is free and needs
    // no check at all.
    public static let minimumStatus: Int64 = 2

    public var status: Int64 {
        didSet {
            if status < SGStatus.minimumStatus {
                status = SGStatus.minimumStatus
            }
        }
    }

    public static var `default`: SGStatus {
        return SGStatus(status: SGStatus.minimumStatus)
    }

    public init(status: Int64) {
        self.status = max(status, SGStatus.minimumStatus)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.status = max(try container.decodeIfPresent(Int64.self, forKey: "status") ?? SGStatus.minimumStatus, SGStatus.minimumStatus)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encodeIfPresent(self.status, forKey: "status")
    }
}

public func updateSGStatusInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (SGStatus) -> SGStatus) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.sgStatus, { entry in
            let currentSettings: SGStatus
            if let entry = entry?.get(SGStatus.self) {
                currentSettings = entry
            } else {
                currentSettings = SGStatus.default
            }
            return SharedPreferencesEntry(f(currentSettings))
        })
    }
}
