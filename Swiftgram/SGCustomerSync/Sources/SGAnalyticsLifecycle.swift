import Foundation
import UIKit
import SGCustomerSyncCore

/// Zenlygram — the app lifecycle as the customer-data coordinator needs it (design 40 §10.4,
/// §10.6): the events that open and close app sessions and the background flush. The sessions
/// themselves are the reducer's decisions (`.sessionStart` / `.sessionEnd`).
///
/// - Foreground: the FIRST of `willEnterForeground` / `didBecomeActive` per foreground entry
///   (`.foreground`); the entry ends with `didEnterBackground`, so a background launch followed by a
///   foreground gives exactly one, and returning from Control Centre or an alert gives none.
/// - `didEnterBackground`: `.background` inside the background task `zg.customer.flush` — the
///   session ends and at most one batch ≤ 64 KiB per account goes out; the task ends when they
///   answered or after 8 s (`SGAnalyticsBatcher.backgroundDeadline`), whichever is first, so it never
///   crowds Tasks' own 20 s flush (`zenlygram.tasks.flush`) out of the background window.
/// - `willTerminate`: `.terminate` (best effort, no flush).
/// Main queue.
final class SGAnalyticsLifecycle {
    /// One background entry's flush: the background task ends once the coordinator has decided
    /// (`ready`) and every batch it sent answered.
    final class Flush {
        private var pending = 0
        private var isReady = false
        private var completion: (() -> Void)?

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        /// A batch went out.
        func begin() {
            self.pending += 1
        }

        /// A batch answered.
        func end() {
            self.pending -= 1
            self.finishIfDone()
        }

        /// The coordinator sent every batch of this entry.
        func ready() {
            self.isReady = true
            self.finishIfDone()
        }

        private func finishIfDone() {
            guard self.isReady, self.pending <= 0, let completion = self.completion else {
                return
            }
            self.completion = nil
            completion()
        }
    }

    private final class BackgroundTask {
        var identifier: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard self.identifier != .invalid else {
                return
            }
            UIApplication.shared.endBackgroundTask(self.identifier)
            self.identifier = .invalid
        }
    }

    private weak var coordinator: SGCustomerSyncCoordinator?
    private var observers: [NSObjectProtocol] = []
    /// Inside a foreground entry (`.foreground` was sent for it).
    private var isInForegroundEntry: Bool

    /// `isForeground`: the process is not in the background now (a launch into the foreground is
    /// already an entry: the reducer starts its session when the accounts are known).
    init(coordinator: SGCustomerSyncCoordinator, isForeground: Bool) {
        self.coordinator = coordinator
        self.isInForegroundEntry = isForeground
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        assert(Thread.isMainThread)
        let center = NotificationCenter.default
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                self?.enterForeground()
            }))
        }
        self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.enterBackground()
        }))
        self.observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.coordinator?.send(.terminate)
        }))
    }

    private func enterForeground() {
        guard !self.isInForegroundEntry else {
            return
        }
        self.isInForegroundEntry = true
        self.coordinator?.send(.foreground)
    }

    private func enterBackground() {
        self.isInForegroundEntry = false
        let task = BackgroundTask()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: "zg.customer.flush") {
            task.end()
        }
        let flush = Flush(completion: {
            task.end()
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + SGAnalyticsBatcher.backgroundDeadline) {
            task.end()
        }
        guard let coordinator = self.coordinator else {
            task.end()
            return
        }
        coordinator.enterBackground(flush)
    }
}
