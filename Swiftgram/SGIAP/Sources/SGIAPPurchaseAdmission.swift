import Foundation

/// Zenlygram — whether a NEW App Store purchase may start (contract `monetization-policy`,
/// `x-client-state.apple_purchase_admission`).
///
/// The only route from the paywall to StoreKit's purchase sheet. In order:
/// 1. the local cached mode must be paid (free short-circuits: nothing is asked or bought);
/// 2. a FRESH, verified PAID policy fetched for this purchase (`authorize`) — never the cached one,
///    so a transport failure, an invalid or older answer, or a fresh free policy refuses;
/// 3. for a LINKED account only, a successful server `prepare` for this exact product — every
///    failure refuses, never falling back to an unbound purchase; an UNLINKED install skips it and
///    buys with no `appAccountToken` (linking stays optional, as App Review requires);
/// 4. the local mode is re-checked after every await, and only then is `purchase` invoked.
///
/// Restore, the attach of already-paid transactions, `Transaction.updates` and the StoreKit
/// fallback never pass through here: existing purchases are never gated by the policy.
///
/// Limit: an Apple purchase sheet admitted here before the policy flips cannot be cancelled
/// atomically; the server's own `prepare` / attach rules and Apple remain the backstop.
///
/// Foundation only, so the rule is exercised on the host (`Tests/run-purchase-admission-tests.sh`).
enum SGIAPPurchaseAdmission {
    /// The fresh public policy fetched for this purchase.
    enum Authorization: Equatable {
        case paid
        case free
        /// Not fetched, not verified, expired, older than the accepted one, or conflicting.
        case unavailable
        /// Another policy request is in flight: try again in a moment.
        case busy
    }

    /// `POST /v1/apple/prepare` for a linked account.
    enum Prepare: Equatable {
        case prepared(appAccountToken: UUID, productId: String)
        /// `409 monetization_disabled`: the server is free.
        case monetizationDisabled
        /// The account's session was refused (401): it must be linked again before it can buy.
        case sessionRefused
        /// Any other answer, or a 2xx without a usable token.
        case unavailable
        /// No answer at all.
        case offline

        /// The wire answer, classified. `status == nil` is a transport failure.
        init(status: Int?, appAccountToken: String?, productId: String?, errorCode: String?) {
            guard let status else {
                self = .offline
                return
            }
            if (200 ..< 300).contains(status) {
                guard let raw = appAccountToken, let token = UUID(uuidString: raw), let productId, !productId.isEmpty else {
                    self = .unavailable
                    return
                }
                self = .prepared(appAccountToken: token, productId: productId)
                return
            }
            if status == 409, errorCode == "monetization_disabled" {
                self = .monetizationDisabled
                return
            }
            self = .unavailable
        }
    }

    enum Refusal: Equatable {
        /// Free right now: nothing new is sold.
        case notOffered
        case unavailable
        case noConnection
        case busy
        /// A linked account's session was refused: link it again.
        case relink
    }

    enum Outcome<T> {
        case admitted(T)
        case refused(Refusal)
    }

    static func run<T>(
        productId: String,
        isOfferedLocally: () -> Bool,
        authorize: () async -> Authorization,
        prepare: (() async -> Prepare)?,
        purchase: (UUID?) async -> T
    ) async -> Outcome<T> {
        guard isOfferedLocally() else {
            return .refused(.notOffered)
        }
        switch await authorize() {
        case .paid:
            break
        case .free:
            return .refused(.notOffered)
        case .unavailable:
            return .refused(.unavailable)
        case .busy:
            return .refused(.busy)
        }
        guard isOfferedLocally() else {
            return .refused(.notOffered)
        }
        var appAccountToken: UUID?
        if let prepare {
            switch await prepare() {
            case let .prepared(token, preparedProductId):
                guard preparedProductId == productId else {
                    return .refused(.unavailable)
                }
                appAccountToken = token
            case .monetizationDisabled:
                return .refused(.notOffered)
            case .sessionRefused:
                return .refused(.relink)
            case .unavailable:
                return .refused(.unavailable)
            case .offline:
                return .refused(.noConnection)
            }
            guard isOfferedLocally() else {
                return .refused(.notOffered)
            }
        }
        return .admitted(await purchase(appAccountToken))
    }
}

extension SGIAPPurchaseAdmission.Outcome: Equatable where T: Equatable {}
