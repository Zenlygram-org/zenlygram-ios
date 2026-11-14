import Foundation
import Display
import AccountContext

/// Zenlygram — the consent entry points Tasks reaches through hooks (wf15 §6.1, D1).
///
/// The consent wall, the one prompt and the Data & consent screen live in the `SGCustomerSync`
/// module, which depends on this one (F3: `SGCustomerSync` → `SGTasks`), so Tasks never imports
/// it. The hooks are declared here and installed once by `SGCustomerSync.start(sharedContext:)`
/// (main queue, before `SGTasksSyncCoordinator.start`); a build whose customer-data pipeline is
/// not active installs nothing, and every caller has a fallback for `installed == nil`.
public struct SGTasksConsentEntry {
    /// Optional mode: presents the account's FIRST consent prompt if the account never decided
    /// (state `none`) and no prompt was shown in this attach; returns true when a prompt is now up.
    /// Required mode: no-op, false (the wall at launch decided; Tasks adds nothing).
    public let promptIfUndecided: (AccountContext) -> Bool
    /// The Data & consent screen (Settings › Zenlygram › Maʼlumotlar va rozilik), pushed by the
    /// sync-off line; nil while the pipeline is inactive.
    public let dataConsentController: (AccountContext) -> ViewController?
    /// Whether the account's consent wall or prompt is on screen (nothing else is presented over it).
    public let isConsentScreenUp: (AccountContext) -> Bool

    public init(promptIfUndecided: @escaping (AccountContext) -> Bool, dataConsentController: @escaping (AccountContext) -> ViewController?, isConsentScreenUp: @escaping (AccountContext) -> Bool) {
        self.promptIfUndecided = promptIfUndecided
        self.dataConsentController = dataConsentController
        self.isConsentScreenUp = isConsentScreenUp
    }

    /// Set once by `SGCustomerSync.start`, main queue; read on the main queue by the Tasks screens.
    public static var installed: SGTasksConsentEntry?

    /// The route the sync-off line opens when no hook is installed: the Data & consent row of the
    /// Settings › Zenlygram hub (`OpenUrl.swift`, `tg://sg/settings?row=<key>`).
    public static let dataConsentFallbackURL = "tg://sg/settings?row=dataConsent"
}
