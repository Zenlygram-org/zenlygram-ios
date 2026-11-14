import Foundation
// The real failure mapping behind SGLinkAccountProofPolicy (built by run-link-lifecycle-tests.sh).
import SGEntitlement

private actor ControlledResponse {
    private var completion: CheckedContinuation<String, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func response() async -> String {
        self.calls += 1
        return await withCheckedContinuation { continuation in
            self.completion = continuation
            self.ready?.resume()
            self.ready = nil
        }
    }

    func waitForRequest() async {
        if self.completion != nil { return }
        await withCheckedContinuation { self.ready = $0 }
    }

    func confirm() {
        self.completion?.resume(returning: "confirmed-once")
        self.completion = nil
    }
}

@main
struct LinkAccountLifecycleTests {
    @MainActor
    static func main() async {
        var lifecycle = SGLinkAccountLifecycle()
        let hidden = lifecycle.beginRun()
        precondition(!lifecycle.accepts(hidden), "A request cannot apply before the screen appears")

        lifecycle.setVisible(true)
        let first = lifecycle.beginRun()
        precondition(lifecycle.accepts(first))
        // SwiftUI can repeat onAppear without the controller changing ownership.
        lifecycle.setVisible(true)
        precondition(lifecycle.accepts(first))

        lifecycle.deferPoll(seconds: 120, now: 10)
        lifecycle.setVisible(false)
        precondition(!lifecycle.accepts(first), "A hidden screen accepted a one-shot confirmation")
        lifecycle.setVisible(true)
        let resumed = lifecycle.beginRun()
        precondition(lifecycle.accepts(resumed))
        precondition(!lifecycle.accepts(first), "Reopening resurrected an old request")
        // A normal jittered poll or a new code cannot bypass the server's rate limit.
        lifecycle.deferPoll(seconds: 3, now: 20)
        precondition(lifecycle.pollDelay(now: 20) == 110)

        lifecycle.setForeground(false)
        precondition(!lifecycle.accepts(resumed), "A backgrounded request persisted a binding")
        lifecycle.setForeground(true)
        let foreground = lifecycle.beginRun()
        precondition(!lifecycle.accepts(resumed))
        precondition(lifecycle.accepts(foreground))
        precondition(lifecycle.pollDelay(now: 100) == 30)

        let replacement = lifecycle.beginRun()
        precondition(!lifecycle.accepts(foreground), "Restart let a stale error regenerate the key")
        precondition(lifecycle.accepts(replacement))
        precondition(lifecycle.pollDelay(now: 129) == 1)
        precondition(lifecycle.pollDelay(now: 130) == 0)
        precondition(lifecycle.pollDelay(now: 200) == 0)

        // A late 429 received during suspension still applies to a resumed request's IP budget.
        lifecycle.setForeground(false)
        lifecycle.deferPoll(seconds: 60, now: 210)
        lifecycle.setForeground(true)
        _ = lifecycle.beginRun()
        precondition(lifecycle.pollDelay(now: 220) == 50)
        lifecycle.deferPoll(seconds: -10, now: 220)
        lifecycle.deferPoll(seconds: .infinity, now: 220)
        precondition(lifecycle.pollDelay(now: 220) == 50)
        lifecycle.deferPoll(seconds: Double(Int.max), now: 220)
        precondition(lifecycle.pollDelay(now: 220).isFinite)

        // Returning to the foreground does not restart an already dismissed screen.
        lifecycle.setVisible(false)
        lifecycle.setForeground(false)
        lifecycle.setForeground(true)
        let dismissed = lifecycle.beginRun()
        precondition(!lifecycle.accepts(dismissed))

        lifecycle.deferStart(seconds: 90, now: 300)
        lifecycle.setVisible(true)
        _ = lifecycle.beginRun()
        lifecycle.deferStart(seconds: 3, now: 310)
        precondition(lifecycle.startDelay(now: 310) == 80, "Get New Code bypassed start Retry-After")
        precondition(lifecycle.startDelay(now: 390) == 0)

        // The actual request holder used by the model retains a confirmation while its UI waiter
        // is canceled. Resuming awaits the same HTTP response, even if the code has since expired.
        let server = ControlledResponse()
        var slot = SGLinkAccountRequestSlot<String>()
        let firstRequest = slot.request(now: { 400 }) { await server.response() }
        await server.waitForRequest()
        let oldGeneration = lifecycle.beginRun()
        let oldWaiter = Task { await firstRequest.task.value }
        lifecycle.setForeground(false)
        oldWaiter.cancel()
        await server.confirm()
        let oldResult = await oldWaiter.value
        precondition(oldResult.value == "confirmed-once")
        precondition(!lifecycle.accepts(oldGeneration))
        lifecycle.setForeground(true)
        let newGeneration = lifecycle.beginRun()
        let resumedRequest = slot.request { fatalError("Duplicate one-shot poll issued") }
        let result = await resumedRequest.task.value
        precondition(result.value == "confirmed-once" && lifecycle.accepts(newGeneration))
        precondition(result.receivedAt == 400 && oldResult.receivedAt == 400)
        var budget = SGLinkAccountLifecycle()
        budget.deferPoll(seconds: 60, now: oldResult.receivedAt)
        budget.deferPoll(seconds: 60, now: result.receivedAt)
        precondition(budget.pollDelay(now: 450) == 10, "Resume restarted the entire Retry-After")
        let calls = await server.calls
        precondition(calls == 1)
        slot.consume(resumedRequest.id)
        precondition(slot.current == nil)

        let replacementRequest = slot.request { "replacement" }
        slot.consume(firstRequest.id)
        precondition(slot.current?.id == replacementRequest.id, "Old waiter cleared the new request")
        slot.reset()
        let fresh = slot.request { "fresh-code" }
        let freshResult = await fresh.task.value
        precondition(fresh.id != replacementRequest.id && freshResult.value == "fresh-code")

        // The poll step's decisions, exactly as `SGLinkAccountModel.poll` applies them
        // (`SGLinkAccountKeyRestartBudget.reaction`). One flow: `begin()` resets the budget; a key
        // change restarts once with the current key; a second key change in the same flow ends in
        // a VISIBLE failure instead of polling the old start or looping; a new attempt may restart
        // again.
        func isRestart(_ reaction: SGLinkAccountPollReaction<String>) -> Bool {
            if case .restartWithCurrentKey = reaction { return true }
            return false
        }
        func failure(_ reaction: SGLinkAccountPollReaction<String>) -> SGLinkAccountFailureReason<String>? {
            if case let .fail(reason) = reaction { return reason }
            return nil
        }
        func hint(_ reaction: SGLinkAccountPollReaction<String>) -> SGLinkAccountPollHint? {
            if case let .keepPolling(hint) = reaction { return hint }
            return nil
        }
        var flow = SGLinkAccountKeyRestartBudget()
        flow.reset()                                                      // begin()
        precondition(hint(flow.reaction(to: SGLinkAccountPollAnswer<String>.pending)) == .clear)
        precondition(isRestart(flow.reaction(to: SGLinkAccountPollAnswer<String>.restartBind)), "the first key change did not restart with the current key")
        precondition(hint(flow.reaction(to: SGLinkAccountPollAnswer<String>.offline)) == .noConnection, "offline on the fresh start must keep polling with a hint")
        let second = flow.reaction(to: SGLinkAccountPollAnswer<String>.restartBind)
        guard case .temporarilyUnavailable? = failure(second) else {
            preconditionFailure("a second key change in one flow restarted again or kept polling instead of failing visibly")
        }
        flow.reset()                                                      // the user taps "try again"
        precondition(isRestart(flow.reaction(to: SGLinkAccountPollAnswer<String>.restartBind)), "a new attempt could not restart")

        var answers = SGLinkAccountKeyRestartBudget()
        if case .complete = answers.reaction(to: SGLinkAccountPollAnswer<String>.confirmed) {} else { preconditionFailure("confirmed must complete") }
        precondition(hint(answers.reaction(to: SGLinkAccountPollAnswer<String>.rateLimited)) == .keep)
        guard case .declined? = failure(answers.reaction(to: SGLinkAccountPollAnswer<String>.denied)),
              case .codeExpired? = failure(answers.reaction(to: SGLinkAccountPollAnswer<String>.expired)),
              case .didNotGoThrough? = failure(answers.reaction(to: SGLinkAccountPollAnswer<String>.consumed)),
              case .didNotGoThrough? = failure(answers.reaction(to: SGLinkAccountPollAnswer<String>.bindNotFound)),
              case let .failed(passed)? = failure(answers.reaction(to: SGLinkAccountPollAnswer<String>.failed("device_revoked"))), passed == "device_revoked"
        else {
            preconditionFailure("a poll answer mapped to the wrong outcome")
        }
        precondition(answers.used == 0, "an answer other than restartBind spent the restart budget")

        // Tasks proof mode, decided by the real SGEntitlementFailureMapping.
        // An Apple-only stored session (refresh token, no verified Telegram id) cannot short-circuit
        // a proof the caller requires; ordinary callers keep the "already linked" shortcut.
        precondition(!SGLinkAccountProofPolicy.opensAsLinked(hasStoredSession: true, requiresTelegramProof: true), "a stored session skipped the required Telegram proof")
        precondition(SGLinkAccountProofPolicy.opensAsLinked(hasStoredSession: true, requiresTelegramProof: false), "the existing already-linked behaviour changed")
        precondition(!SGLinkAccountProofPolicy.opensAsLinked(hasStoredSession: false, requiresTelegramProof: false), "an unlinked account opened as linked")
        // Failures whose mapped consequence drops the install key must not reach `apply` in proof
        // mode (it would regenerate the key a valid stored session is bound to)...
        for keyDropping: SGEntitlementFailureClass in [.refused(.invalidPubkey), .session(.deviceKeyMismatch)] {
            precondition(!SGLinkAccountProofPolicy.appliesBindStartFailure(keyDropping, requiresTelegramProof: true), "proof mode would destroy the install key on \(keyDropping)")
            // ...while the legacy flow still applies them (its key regeneration is unchanged).
            precondition(SGLinkAccountProofPolicy.appliesBindStartFailure(keyDropping, requiresTelegramProof: false), "legacy key recovery changed for \(keyDropping)")
        }
        // Ordinary failures keep their normal handling in proof mode too.
        for ordinary: SGEntitlementFailureClass in [.offline(.timeout), .rateLimited(retryAfter: 30), .refused(.bindPaused), .session(.invalidToken), .unknownRefusal(code: "x", status: 400)] {
            precondition(SGLinkAccountProofPolicy.appliesBindStartFailure(ordinary, requiresTelegramProof: true), "proof mode swallowed an ordinary failure \(ordinary)")
        }
        precondition(!SGLinkAccountProofPolicy.mayRegenerateKeyAndRestart(requiresTelegramProof: true), "proof mode may regenerate the key")
        precondition(SGLinkAccountProofPolicy.mayRegenerateKeyAndRestart(requiresTelegramProof: false), "legacy invalid_pubkey restart changed")
        print("Link account lifecycle regression tests passed")
    }
}
