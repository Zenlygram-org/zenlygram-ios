import Foundation

/// One "this verifying token carries no account claims — fetch one that does" request.
struct SGEntitlementAccountClaimsRequest: Equatable, Hashable {
    let accountPeerId: Int64
    /// The legacy token the request is about. A new token is a new question.
    let token: String
}

/// Zenlygram — which accounts, in paid mode, hold a verifying token WITHOUT the genuine account
/// claims (`account_ent` / `account_until`) and still need the server asked for one that has them.
///
/// Such a token proves nothing paid, so its holder is degraded until a fresh token arrives; the
/// ordinary cadence would not ask for a day (a fresh `iat` skips the foreground refresh). The rule
/// this value enforces:
/// - a request is only SPENT when the scheduler actually admitted it (`admitted`); a skip or a wait
///   (in flight, the 60 s collapse, the budget, a backoff) leaves it due, so the next opportunity
///   asks again;
/// - a request whose call failed is due again (`failed`) — unless the account has moved on to a
///   newer token in the meantime;
/// - nothing is due before the first idle window after launch (invariant I1);
/// - a token that carries the claims settles the account (`noteSatisfied`).
///
/// Pure and Foundation-only, so it is exercised on the host (`Tests/run-policy-core-tests.sh`).
struct SGEntitlementAccountClaimsLedger: Equatable {
    /// The latest claim-less token seen per account.
    private var wanted: [Int64: String] = [:]
    /// The token per account a request was admitted for.
    private var asked: [Int64: String] = [:]

    mutating func noteMissing(accountPeerId: Int64, token: String) {
        self.wanted[accountPeerId] = token
    }

    mutating func noteSatisfied(accountPeerId: Int64) {
        self.wanted.removeValue(forKey: accountPeerId)
        self.asked.removeValue(forKey: accountPeerId)
    }

    /// The requests that should be attempted now, in account order. Reading it spends nothing.
    func due(firstIdlePassed: Bool) -> [SGEntitlementAccountClaimsRequest] {
        guard firstIdlePassed else {
            return []
        }
        return self.wanted.keys.sorted().compactMap { peerId in
            guard let token = self.wanted[peerId], self.asked[peerId] != token else {
                return nil
            }
            return SGEntitlementAccountClaimsRequest(accountPeerId: peerId, token: token)
        }
    }

    /// The scheduler admitted the call (`.fetch` / `.rotate`) for `request`.
    mutating func admitted(_ request: SGEntitlementAccountClaimsRequest) {
        self.asked[request.accountPeerId] = request.token
    }

    /// The admitted call did not deliver a token: ask again at the next opportunity — only if the
    /// account is still on that same token.
    mutating func failed(_ request: SGEntitlementAccountClaimsRequest) {
        if self.asked[request.accountPeerId] == request.token {
            self.asked.removeValue(forKey: request.accountPeerId)
        }
    }
}
