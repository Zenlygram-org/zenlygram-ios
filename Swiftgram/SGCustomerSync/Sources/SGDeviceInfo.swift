import Foundation
import UIKit
import AccountContext
import SGCustomerSyncCore

/// Zenlygram — the device facts the profile snapshot and the analytics context carry (design 40
/// §9.2), read on the main thread as the device reports them; the core normalises them
/// (`SGCustomerNormalise`). Never read here: the user-assigned device name, IDFA/IDFV, contacts,
/// location or anything about chats (contract §6.9).
enum SGDeviceInfo {
    /// `CFBundleShortVersionString` (`ver`, clipped by the core).
    static let appVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    /// `CFBundleVersion`.
    static let appBuild: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    /// The facts now; `uiLanguage` is `presentationData.strings.baseLanguageCode`. Main thread.
    static func facts(uiLanguage: String?) -> SGCustomerDeviceFacts {
        return SGCustomerDeviceFacts(
            deviceClass: UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone,
            deviceModel: SGDeviceInfo.deviceModel,
            osVersion: UIDevice.current.systemVersion,
            appVersion: SGDeviceInfo.appVersion,
            appBuild: SGDeviceInfo.appBuild,
            uiLanguage: uiLanguage,
            locale: SGDeviceInfo.locale(),
            timezone: TimeZone.autoupdatingCurrent.identifier,
            distribution: SGDeviceInfo.distribution
        )
    }

    /// The hardware model identifier (`iPhone17,1`): `utsname.machine`; on the simulator the model
    /// it simulates.
    static let deviceModel: String? = {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #endif
        var info = utsname()
        guard uname(&info) == 0 else {
            return nil
        }
        let machine = withUnsafeBytes(of: &info.machine) { buffer -> String in
            return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }()

    /// The current locale as `language[-Script][-REGION]` (iOS 16+ from its components; earlier its
    /// identifier, which the core normalises the same way). The auto-updating locale and time zone
    /// follow a change of the device settings without a relaunch.
    static func locale() -> String? {
        let current = Locale.autoupdatingCurrent
        if #available(iOS 16.0, *) {
            let language = current.language
            return SGCustomerNormalise.bcp47(language: language.languageCode?.identifier, script: language.script?.identifier, region: language.region?.identifier)
        } else {
            return current.identifier
        }
    }

    /// `debug` unless this is an App Store build; then `testflight` with a sandbox receipt, else
    /// `appstore` (the pattern AppDelegate uses for its own debug logging).
    static var distribution: SGCustomerDistribution {
        guard GlobalExperimentalSettings.isAppStoreBuild else {
            return .debug
        }
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? .testflight : .appstore
    }
}
