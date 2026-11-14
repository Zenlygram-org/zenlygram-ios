import Foundation
import BuildConfig

// Zenlygram — link to the app's own App Store listing, used by the invite texts and the
// login "app outdated" prompt (upstream used the localized InviteText.URL, which pointed at
// Swiftgram's listing in this fork). The id comes from the build configuration's
// `appstore_id` (build-system/zenlygram-*.json), the same value openAppStorePage() uses.
// While there is no App Store Connect record yet (appstore_id == 0, dev/sim builds),
// `fallback` (the neutral localized InviteText.URL) is returned instead.
private let sgAppStoreId: Int64 = BuildConfig(baseAppBundleId: Bundle.main.bundleIdentifier ?? "").appStoreId

public func sgAppStoreUrl(fallback: String) -> String {
    if sgAppStoreId > 0 {
        return "https://apps.apple.com/app/id\(sgAppStoreId)"
    }
    return fallback
}
