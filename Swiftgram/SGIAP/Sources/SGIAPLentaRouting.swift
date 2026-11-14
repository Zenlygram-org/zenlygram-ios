#if SG_LENTA
import Foundation
import StoreKit
import SGConfig
import SGLogging

/// Zenlygram — Lenta's StoreKit products (TIJ-11; spec «Premium handle'lar» › «SGIAP yo'naltirishi»).
///
/// `sg_config.lenta_iaps` lists them: Lenta Plus (`lenta.plus` subscription group, separate from Pro's), the
/// premium-name tiers and the auction steps. The Pro engine never finishes, enqueues or attaches one of them
/// (`SGIAPAppleBoundary.Ingest.route`), Pro Restore and the Pro snapshot never count them, and the Pro group lookup
/// never picks one. Every `Transaction.updates` element of a listed id goes to the handler SGFeedCommerce installs;
/// that handler proves the payment to Lenta's server and finishes the transaction only after a 2xx. Without a
/// handler yet (the Lenta runtime starts with the tab) the transaction stays unfinished: the handler re-reads
/// `Transaction.unfinished` when it is installed.
///
/// The listener runs even when Pro's Apple work is held: Lenta's own server is a different trust zone.
public enum SGIAPLentaRouting {
    /// `sg_config.lenta_iaps`.
    public static var productIds: Set<String> {
        return Set(SG_CONFIG.lentaIaps)
    }

    private static let lock = NSLock()
    // `@Sendable (VerificationResult<Transaction>) async -> Void`, stored untyped: the type exists from iOS 15.
    private static var handlerStorage: Any?

    /// Installs (or, with nil, removes) the Lenta transaction handler. Called on every listed update, verified or
    /// not; it is never called for any other product.
    @available(iOS 15.0, *)
    public static func setHandler(_ handler: (@Sendable (VerificationResult<Transaction>) async -> Void)?) {
        self.lock.lock()
        self.handlerStorage = handler
        self.lock.unlock()
    }

    @available(iOS 15.0, *)
    private static var handler: (@Sendable (VerificationResult<Transaction>) async -> Void)? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.handlerStorage as? @Sendable (VerificationResult<Transaction>) async -> Void
    }

    /// True when the update is a Lenta product: handed to the handler (or left unfinished without one). False for
    /// every other product, which the Pro engine handles as before.
    @available(iOS 15.0, *)
    static func route(_ update: VerificationResult<Transaction>) async -> Bool {
        let productId: String
        switch update {
        case let .verified(transaction), let .unverified(transaction, _):
            productId = transaction.productID
        }
        guard self.productIds.contains(productId) else {
            return false
        }
        if let handler = self.handler {
            await handler(update)
        } else {
            SGLogger.shared.log("SGIAP", "Routed transaction left unfinished until its handler starts")
        }
        return true
    }
}
#endif
