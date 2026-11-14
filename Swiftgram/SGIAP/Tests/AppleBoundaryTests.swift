import Foundation

/// Zenlygram — `SGIAPAppleBoundary`, the table the StoreKit engine follows before it finishes,
/// enqueues, removes or sends anything. While Apple work is HELD (`SGEntitlement.isAppleBackendEnabled`
/// false: no explicit `apple_backend_enabled`, no authenticated configuration, no product ids, or a
/// public-policy-only build) every transaction and every outbox entry is left exactly as it is —
/// including a build that already lists product ids and has an authenticated client. Only an enabled
/// build keeps the ingest table and its order, and attaches only once its client exists.
@main
struct AppleBoundaryTests {
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    private static let listed = "org.zenlygram.pro.month"
    private static let unlisted = "com.swiftgram.legacy.month"
    private static let configured = [listed, "org.zenlygram.pro.year"]

    static func main() {
        self.heldLeavesEveryTransactionUntouched()
        self.enabledKeepsItsIngestTableAndOrder()
        self.heldNeverDeliversAnOutboxEntry()
        self.enabledDeliversOnlyWithAClient()
        self.routedProductsNeverReachTheProEngine()
        print("SGIAPAppleBoundary: all checks passed")
    }

    private static func heldLeavesEveryTransactionUntouched() {
        // Historical evidence a device may hold from an earlier, fully configured build.
        let rows: [(String, String, Bool)] = [
            ("listed payment", listed, false),
            ("unlisted product", unlisted, false),
            ("listed refund", listed, true),
            ("unlisted refund", unlisted, true)
        ]
        for ids in [configured, []] {
            for (name, productId, isRevoked) in rows {
                let action = SGIAPAppleBoundary.ingest(isAppleHeld: true, configuredProductIds: ids, productId: productId, isRevoked: isRevoked)
                check(action == .leaveUntouched, "held must not finish or enqueue a \(name) (products \(ids)); got \(action)")
            }
        }
    }

    private static func enabledKeepsItsIngestTableAndOrder() {
        check(SGIAPAppleBoundary.ingest(isAppleHeld: false, configuredProductIds: [], productId: unlisted, isRevoked: true) == .leaveUntouched, "no product ids is checked first: not even a refund is finished")
        check(SGIAPAppleBoundary.ingest(isAppleHeld: false, configuredProductIds: configured, productId: unlisted, isRevoked: false) == .finishUnlisted, "an enabled build still finishes a product it does not sell")
        check(SGIAPAppleBoundary.ingest(isAppleHeld: false, configuredProductIds: configured, productId: unlisted, isRevoked: true) == .finishUnlisted, "an unlisted refund is unlisted first, as before")
        check(SGIAPAppleBoundary.ingest(isAppleHeld: false, configuredProductIds: configured, productId: listed, isRevoked: true) == .finishRevoked, "a listed refund is still finished")
        check(SGIAPAppleBoundary.ingest(isAppleHeld: false, configuredProductIds: configured, productId: listed, isRevoked: false) == .attach, "a listed payment is still attached")
    }

    private static func heldNeverDeliversAnOutboxEntry() {
        // Held with an authenticated client already configured: the drain, the foreground pass and
        // Restore must neither send an entry to the server nor remove or finish it.
        check(SGIAPAppleBoundary.delivery(isAppleHeld: true, hasClient: true) == .leaveUntouched, "held must not send a pending attach even with a client")
        check(SGIAPAppleBoundary.delivery(isAppleHeld: true, hasClient: false) == .leaveUntouched, "held must never treat a pending attach as attached")
    }

    private static func enabledDeliversOnlyWithAClient() {
        check(SGIAPAppleBoundary.delivery(isAppleHeld: false, hasClient: true) == .attach, "an enabled build attaches")
        // `client` is nil until `configure(...)` has run; a transaction can arrive before that.
        check(SGIAPAppleBoundary.delivery(isAppleHeld: false, hasClient: false) == .leaveUntouched, "an enabled build before configure(...) keeps the entry")
    }

    /// TIJ-11: a routed id (`sg_config.lenta_iaps`) is handed to its own handler — never finished as unlisted, never
    /// attached, never finished as a refund — held or enabled, with or without Pro product ids; every other id keeps
    /// the table above.
    private static func routedProductsNeverReachTheProEngine() {
        let routed = ["org.zenlygram.ios.lenta.plus.monthly", "org.zenlygram.ios.lenta.name.t1"]
        for productId in routed {
            for isAppleHeld in [true, false] {
                for ids in [configured, []] {
                    for isRevoked in [true, false] {
                        let action = SGIAPAppleBoundary.ingest(isAppleHeld: isAppleHeld, configuredProductIds: ids, routedProductIds: routed, productId: productId, isRevoked: isRevoked)
                        check(action == .route, "a routed id must go to its handler (held \(isAppleHeld), products \(ids), revoked \(isRevoked)); got \(action)")
                    }
                }
            }
        }
        check(SGIAPAppleBoundary.ingest(isAppleHeld: false, configuredProductIds: configured, routedProductIds: routed, productId: unlisted, isRevoked: false) == .finishUnlisted, "routing does not change an unlisted id")
        check(SGIAPAppleBoundary.ingest(isAppleHeld: false, configuredProductIds: configured, routedProductIds: routed, productId: listed, isRevoked: false) == .attach, "routing does not change a Pro id")
        check(SGIAPAppleBoundary.ingest(isAppleHeld: true, configuredProductIds: configured, routedProductIds: routed, productId: listed, isRevoked: false) == .leaveUntouched, "routing does not change a held Pro id")
    }
}
