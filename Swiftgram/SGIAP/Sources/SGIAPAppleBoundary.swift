import Foundation

/// Zenlygram — what the StoreKit engine may do with Apple's evidence, decided without StoreKit.
///
/// While Apple work is HELD (`SGEntitlement.isAppleBackendEnabled` false: no explicit
/// `apple_backend_enabled`, no authenticated configuration, no product ids, or a public-policy-only
/// build) there is no server this build may prove a payment to. It must not finish a product id it
/// does not list, finish a refund, send an attach outbox entry or remove one — a device may still
/// hold transactions and outbox entries from an earlier build, and a build that already lists product
/// ids and has an authenticated client is held too until the flag says otherwise. So every one of
/// them DEFERS: nothing is finished, enqueued, removed, rewritten or sent, and StoreKit keeps
/// redelivering until an enabled build handles it.
///
/// An enabled build keeps its exact previous ingest table and order. A product id another handler owns
/// (`routedProductIds`: `sg_config.lenta_iaps` in a Lenta build, empty otherwise) is never finished,
/// enqueued or attached here, held or not: it goes to that handler. Foundation only, so the table runs on
/// the host (`Tests/run-apple-boundary-tests.sh`).
enum SGIAPAppleBoundary {
    /// What `ingest` does with one verified transaction.
    enum Ingest: Equatable {
        /// Not touched at all: not finished, not enqueued, not removed.
        case leaveUntouched
        /// Another handler's product (a Lenta purchase): handed to it, never finished here.
        case route
        /// A product id this build does not sell: finished.
        case finishUnlisted
        /// A refund: its outbox entry is dropped and it is finished.
        case finishRevoked
        /// Enqueued and attached; finished only after a 2xx.
        case attach
    }

    static func ingest(isAppleHeld: Bool, configuredProductIds: [String], routedProductIds: [String] = [], productId: String, isRevoked: Bool) -> Ingest {
        if routedProductIds.contains(productId) {
            return .route
        }
        if isAppleHeld {
            return .leaveUntouched
        }
        guard !configuredProductIds.isEmpty else {
            // No product ids configured: nothing can be classified, so nothing is finished.
            return .leaveUntouched
        }
        guard configuredProductIds.contains(productId) else {
            return .finishUnlisted
        }
        return isRevoked ? .finishRevoked : .attach
    }

    /// What delivering one outbox entry does.
    enum Delivery: Equatable {
        /// The entry stays exactly as it is: not sent, not removed, its transaction not finished.
        case leaveUntouched
        /// `POST /v1/apple/attach`; removed and finished only after a 2xx.
        case attach
    }

    /// Held: never sent, whatever client exists. Enabled but without a client yet (`configure(...)`
    /// has not run — `Transaction.updates` starts at launch): kept for a later drain.
    static func delivery(isAppleHeld: Bool, hasClient: Bool) -> Delivery {
        guard !isAppleHeld, hasClient else {
            return .leaveUntouched
        }
        return .attach
    }
}
