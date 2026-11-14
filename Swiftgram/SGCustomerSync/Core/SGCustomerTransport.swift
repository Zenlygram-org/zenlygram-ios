import Foundation

/// Zenlygram — one customer-data request as the core plans it (design 40 §6.5): the route, the exact
/// body bytes and, for `delete` only, the `Idempotency-Key`.
public struct SGCustomerRequest: Equatable {
    public let route: SGCustomerRoute
    /// nil for the one GET (`me`).
    public let body: Data?
    public let idempotencyKey: String?

    private init(route: SGCustomerRoute, body: Data?, idempotencyKey: String?) {
        self.route = route
        self.body = body
        self.idempotencyKey = idempotencyKey
    }

    /// `POST /v1/profile/consents` (`SGConsentsRequest.body(events:)`).
    public static func consents(_ body: Data) -> SGCustomerRequest {
        return SGCustomerRequest(route: .consents, body: body, idempotencyKey: nil)
    }

    /// `POST /v1/profile/sync` (`SGProfileSnapshot.body(observedAt:)`).
    public static func sync(_ body: Data) -> SGCustomerRequest {
        return SGCustomerRequest(route: .sync, body: body, idempotencyKey: nil)
    }

    /// `POST /v1/profile/events` (`SGAnalyticsBatch.body`).
    public static func events(_ body: Data) -> SGCustomerRequest {
        return SGCustomerRequest(route: .events, body: body, idempotencyKey: nil)
    }

    /// `GET /v1/profile/me`.
    public static let me = SGCustomerRequest(route: .me, body: nil, idempotencyKey: nil)

    /// `POST /v1/account/delete` with the deletion's persisted key (every retry reuses it).
    public static func delete(idempotencyKey: String) -> SGCustomerRequest {
        return SGCustomerRequest(route: .delete, body: SGAccountDeleteRequest.body, idempotencyKey: idempotencyKey)
    }
}

/// Zenlygram — what the app side implements over `SGEntitlement.shared.customerData(...)`
/// (`SGCustomerTransportLive`, I-3): one async call per route that only converts the facade's
/// result into an `SGCustomerRawAnswer` — never classifies (that is `SGCustomerWire.classify`),
/// never logs, never decodes a success body. `accountPeerId` is the packed `PeerId.toInt64()`; the
/// call runs under the account's CURRENT session.
public protocol SGCustomerTransport: AnyObject {
    func consents(body: Data, accountPeerId: Int64) async -> SGCustomerRawAnswer
    func sync(body: Data, accountPeerId: Int64) async -> SGCustomerRawAnswer
    func me(accountPeerId: Int64) async -> SGCustomerRawAnswer
    func events(body: Data, accountPeerId: Int64) async -> SGCustomerRawAnswer
    func delete(body: Data, idempotencyKey: String, accountPeerId: Int64) async -> SGCustomerRawAnswer
}

extension SGCustomerTransport {
    /// Sends `request` on its route.
    public func send(_ request: SGCustomerRequest, accountPeerId: Int64) async -> SGCustomerRawAnswer {
        let body = request.body ?? Data()
        switch request.route {
        case .consents:
            return await self.consents(body: body, accountPeerId: accountPeerId)
        case .sync:
            return await self.sync(body: body, accountPeerId: accountPeerId)
        case .me:
            return await self.me(accountPeerId: accountPeerId)
        case .events:
            return await self.events(body: body, accountPeerId: accountPeerId)
        case .delete:
            return await self.delete(body: body, idempotencyKey: request.idempotencyKey ?? "", accountPeerId: accountPeerId)
        }
    }

    /// Sends `request`, classifies the answer (`SGCustomerWire.classify`) and logs the call's typed
    /// line. The raw answer comes back too: a consents terminal needs its `field`.
    public func call(_ request: SGCustomerRequest, accountPeerId: Int64) async -> (outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer) {
        let answer = await self.send(request, accountPeerId: accountPeerId)
        let outcome = SGCustomerWire.classify(answer)
        SGCustomerWire.log(outcome, answer: answer, route: request.route)
        return (outcome, answer)
    }
}
