import Foundation

// Self-test fixture of the strings gate (wf15 §15.4 rule a, WP-I2b): a cloud SF Symbol name in any
// string literal of the module's sources must FAIL. The two neighbours must not count: an
// accessibility identifier ("sgtasks.…", never shown or spoken) and a feature key without a
// dot-separated cloud component. A comment naming "icloud.slash" is never scanned.
final class FixtureBannerCell {
    let symbolName = "icloud.slash"
    let identifier = "sgtasks.cloud.banner"
    let feature = "tasks_cloud"
}
