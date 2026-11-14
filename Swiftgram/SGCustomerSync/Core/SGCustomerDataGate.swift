import Foundation

/// Zenlygram — what each signed-in account may do with customer data right now (design 40 §6.4):
/// the interface Tasks pulls (T§2, T§5.1) and every emitter reads. Only SGCustomerSync publishes;
/// in an extension, or in a build without the pipeline, nothing is ever published (every clearance
/// `[]`, `isPipelineActive == false`).
///
/// Tasks maps it (T§5.1, the owner of the mapping): Tasks not configured → `.legacy`; pipeline
/// inactive with Tasks configured → `.forbidden`; `.tasksSync` → `.allowed`; `.recordEvents` →
/// `.waiting`; otherwise `.forbidden`. A `.failed` activation publishes `isPipelineActive == true`
/// with `[]` everywhere, so Tasks answers `.forbidden`.
public final class SGCustomerDataGate {
    public static let shared = SGCustomerDataGate()

    /// Posted on the main queue when a published value changed: `userInfo["accountPeerId"]` (`Int64`)
    /// for one account's clearance; no `userInfo` when `isPipelineActive` changed (every account).
    public static let didChangeNotification = Notification.Name("SGCustomerDataGateDidChange")
    public static let accountPeerIdKey = "accountPeerId"

    public struct Clearance: OptionSet, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// Readable, `granted`, the latest grant not rejected, not erasing, the link not ended.
        public static let recordEvents = Clearance(rawValue: 1 << 0)
        /// `recordEvents`, linked, the latest grant acked at this authority, not `not_linked`.
        public static let uploadProfile = Clearance(rawValue: 1 << 1)
        /// `uploadProfile` and a profile receipt for the current binding.
        public static let uploadEvents = Clearance(rawValue: 1 << 2)
        /// Cloud Tasks may sync (= `uploadEvents`).
        public static let tasksSync = Clearance(rawValue: 1 << 3)
    }

    private let lock = NSLock()
    private var pipelineActive = false
    private var clearances: [Int64: Clearance] = [:]
    private let post: (Int64?) -> Void

    /// - Parameter post: replaces the notification (tests); its argument is the account, or nil for
    ///   a pipeline change.
    init(post: ((Int64?) -> Void)? = nil) {
        self.post = post ?? { accountPeerId in
            let userInfo: [AnyHashable: Any]? = accountPeerId.map { [SGCustomerDataGate.accountPeerIdKey: $0] }
            NotificationCenter.default.post(name: SGCustomerDataGate.didChangeNotification, object: nil, userInfo: userInfo)
        }
    }

    /// False only in a build that does not ship the pipeline (`.notShipped`), in an extension and
    /// before SGCustomerSync started.
    public var isPipelineActive: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.pipelineActive
    }

    /// The account's clearance (`accountPeerId` = the packed `PeerId.toInt64()`); `[]` until published.
    public func clearance(accountPeerId: Int64) -> Clearance {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.clearances[accountPeerId] ?? []
    }

    /// SGCustomerSync only. Posts only when the value changed.
    public func publish(_ clearance: Clearance, accountPeerId: Int64) {
        self.lock.lock()
        let previous = self.clearances[accountPeerId] ?? []
        if clearance.isEmpty {
            self.clearances.removeValue(forKey: accountPeerId)
        } else {
            self.clearances[accountPeerId] = clearance
        }
        self.lock.unlock()
        if previous != clearance {
            self.deliver(accountPeerId)
        }
    }

    /// SGCustomerSync only. Posts only when the value changed.
    public func setPipelineActive(_ active: Bool) {
        self.lock.lock()
        let changed = self.pipelineActive != active
        self.pipelineActive = active
        self.lock.unlock()
        if changed {
            self.deliver(nil)
        }
    }

    private func deliver(_ accountPeerId: Int64?) {
        let post = self.post
        if Thread.isMainThread {
            post(accountPeerId)
        } else {
            DispatchQueue.main.async {
                post(accountPeerId)
            }
        }
    }
}
