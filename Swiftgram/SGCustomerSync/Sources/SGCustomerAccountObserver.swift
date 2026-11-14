import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGCustomerSyncCore

/// Zenlygram — the signed-in Telegram accounts as the customer-data coordinator sees them (design 40
/// §6.1 step 6, §11.5): `sharedContext.activeAccountContexts` → the account set, the primary account
/// and each account's context (held weakly).
///
/// - The FIRST emission is handed over at once: the coordinator publishes every account's clearance
///   from persisted state before the Tasks coordinator (started right after it) reads the gate, and
///   runs the launch reconciliation (purge of accounts logged out while the app was closed).
/// - Every later emission is handed over one main-queue turn after it arrived: `SGAccountCleanup`
///   (subscribed earlier) has then run `SGEntitlement.logout` for a removed account, so the logout's
///   final withdraw send (`preRevokeUploadsProvider`) has captured its bodies before the coordinator
///   purges anything of that account.
/// An emission that changes neither the set nor the primary account only refreshes the contexts.
final class SGCustomerAccountObserver {
    struct Accounts: Equatable {
        /// Ascending packed id.
        let signedIn: [SGCustomerCoordinatorCore.SignedIn]
        let primary: Int64?
    }

    private final class WeakContext {
        weak var value: AccountContext?

        init(_ value: AccountContext) {
            self.value = value
        }
    }

    private let disposable = MetaDisposable()
    private var contexts: [Int64: WeakContext] = [:]
    private var last: Accounts?
    private var isFirst = true

    /// Main queue, once: `onChange` gets each new account set (see above) — the first one possibly
    /// before this returns.
    func start(sharedContext: SharedAccountContext, onChange: @escaping (Accounts) -> Void) {
        assert(Thread.isMainThread)
        self.disposable.set((sharedContext.activeAccountContexts
        |> deliverOnMainQueue).startStrict(next: { [weak self] activeAccounts in
            guard let self else {
                return
            }
            var contexts: [Int64: WeakContext] = [:]
            var signedIn: [SGCustomerCoordinatorCore.SignedIn] = []
            for (_, context, _) in activeAccounts.accounts {
                let accountPeerId = context.account.peerId.toInt64()
                guard contexts[accountPeerId] == nil else {
                    continue
                }
                contexts[accountPeerId] = WeakContext(context)
                signedIn.append(SGCustomerCoordinatorCore.SignedIn(accountPeerId: accountPeerId, tg: context.account.peerId.id._internalGetInt64Value()))
            }
            signedIn.sort { $0.accountPeerId < $1.accountPeerId }
            let accounts = Accounts(signedIn: signedIn, primary: activeAccounts.primary?.account.peerId.toInt64())
            self.contexts = contexts
            guard accounts != self.last else {
                return
            }
            self.last = accounts
            if self.isFirst {
                self.isFirst = false
                onChange(accounts)
            } else {
                DispatchQueue.main.async {
                    onChange(accounts)
                }
            }
        }))
    }

    deinit {
        self.disposable.dispose()
    }

    /// The account's context while it is signed in.
    func context(accountPeerId: Int64) -> AccountContext? {
        return self.contexts[accountPeerId]?.value
    }
}
