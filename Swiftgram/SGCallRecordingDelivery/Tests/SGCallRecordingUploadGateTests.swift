import Foundation
import XCTest

import SwiftSignalKit
import TelegramCore

/// The REAL `OutgoingLocalFileUploadGate.gate` combinator (TelegramCore), driven with SwiftSignalKit
/// verdict streams and a content probe that counts factory calls, starts and disposals.
/// `Int` stands in for the upload result (100 is the final `.content`), `GateTestError` for the
/// upload error.
private enum GateTestError: Equatable {
    case denied
    case upload
}

private let finalValue = 100

private final class ContentProbe {
    let factoryCalls = Atomic(value: 0)
    let starts = Atomic(value: 0)
    let disposals = Atomic(value: 0)

    func signal(_ body: @escaping (Subscriber<Int, GateTestError>) -> Void) -> Signal<Int, GateTestError> {
        let _ = self.factoryCalls.modify { $0 + 1 }
        return Signal { subscriber in
            let _ = self.starts.modify { $0 + 1 }
            body(subscriber)
            return ActionDisposable {
                let _ = self.disposals.modify { $0 + 1 }
            }
        }
    }
}

private final class Recorder {
    private struct State {
        var values: [Int] = []
        var errors: [GateTestError] = []
        var completions = 0
    }

    private let state = Atomic(value: State())

    var values: [Int] {
        return self.state.with { $0.values }
    }
    var errors: [GateTestError] {
        return self.state.with { $0.errors }
    }
    var completions: Int {
        return self.state.with { $0.completions }
    }

    func start(_ signal: Signal<Int, GateTestError>, onTerminate: (() -> Void)? = nil) -> Disposable {
        return signal.start(next: { value in
            let _ = self.state.modify { state in
                var state = state
                state.values.append(value)
                return state
            }
        }, error: { error in
            let _ = self.state.modify { state in
                var state = state
                state.errors.append(error)
                return state
            }
            onTerminate?()
        }, completed: {
            let _ = self.state.modify { state in
                var state = state
                state.completions += 1
                return state
            }
            onTerminate?()
        })
    }
}

/// A verdict stream that records whether it is still subscribed.
private final class VerdictProbe {
    let subscriptions = Atomic(value: 0)
    let disposals = Atomic(value: 0)

    func wrap(_ signal: Signal<Bool, NoError>) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let _ = self.subscriptions.modify { $0 + 1 }
            let inner = signal.start(next: { subscriber.putNext($0) }, completed: { subscriber.putCompletion() })
            return ActionDisposable {
                let _ = self.disposals.modify { $0 + 1 }
                inner.dispose()
            }
        }
    }
}

private func gate(verdicts: Signal<Bool, NoError>, timeout: Double = 30.0, content: @escaping () -> Signal<Int, GateTestError>) -> Signal<Int, GateTestError> {
    return OutgoingLocalFileUploadGate.gate(verdicts: verdicts, firstVerdictTimeout: timeout, timeoutQueue: Queue.concurrentDefaultQueue(), denied: GateTestError.denied, isFinal: { $0 == finalValue }, content: content)
}

final class SGCallRecordingUploadGateTests: XCTestCase {
    // 1. A revocation before the content's first event disposes it at once.
    func testRevokeBeforeFirstProgressDisposesContent() {
        let verdicts = ValuePipe<Bool>()
        let probe = ContentProbe()
        let recorder = Recorder()
        let disposable = recorder.start(gate(verdicts: verdicts.signal(), content: { probe.signal { _ in } }))
        defer {
            disposable.dispose()
        }

        verdicts.putNext(true)
        XCTAssertEqual(probe.starts.with { $0 }, 1)
        verdicts.putNext(false)

        XCTAssertEqual(probe.disposals.with { $0 }, 1)
        XCTAssertEqual(recorder.errors, [.denied])
        XCTAssertEqual(probe.starts.with { $0 }, 1)
    }

    // 2. Repeated `true` never restarts the content. A pipe, because a default ValuePromise would
    // drop the repeats and the test would pass without exercising anything.
    func testRepeatedAllowDoesNotRestart() {
        let verdicts = ValuePipe<Bool>()
        let probe = ContentProbe()
        let recorder = Recorder()
        let disposable = recorder.start(gate(verdicts: verdicts.signal(), content: { probe.signal { _ in } }))
        defer {
            disposable.dispose()
        }

        verdicts.putNext(true)
        verdicts.putNext(true)
        verdicts.putNext(true)

        XCTAssertEqual(probe.factoryCalls.with { $0 }, 1)
        XCTAssertEqual(probe.starts.with { $0 }, 1)
        XCTAssertEqual(probe.disposals.with { $0 }, 0)
        XCTAssertEqual(recorder.errors, [])
    }

    // 3. A long valid upload is never denied by the first-verdict watchdog.
    func testLongUploadIsNotDeniedByTheWatchdog() {
        self.runLongUpload(verdicts: ValuePromise<Bool>(true).get())
    }

    func testLongUploadIsNotDeniedByTheWatchdogWithAContinuousVerdictStream() {
        let verdicts = ValuePromise<Bool>(true, ignoreRepeated: false)
        let ticker = Queue()
        let timer = SwiftSignalKit.Timer(timeout: 0.01, repeat: true, completion: {
            verdicts.set(true)
        }, queue: ticker)
        timer.start()
        defer {
            timer.invalidate()
        }
        self.runLongUpload(verdicts: verdicts.get())
    }

    private func runLongUpload(verdicts: Signal<Bool, NoError>) {
        let probe = ContentProbe()
        let recorder = Recorder()
        let done = self.expectation(description: "terminated")
        let disposable = recorder.start(gate(verdicts: verdicts, timeout: 0.05, content: {
            probe.signal { subscriber in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    subscriber.putNext(1)
                    subscriber.putNext(finalValue)
                    subscriber.putCompletion()
                }
            }
        }), onTerminate: {
            done.fulfill()
        })
        self.wait(for: [done], timeout: 5.0)
        disposable.dispose()

        XCTAssertEqual(recorder.errors, [])
        XCTAssertEqual(recorder.values, [1, finalValue])
        XCTAssertEqual(recorder.completions, 1)
    }

    // 4. Cached synchronous content: passes when allowed, never starts when not.
    func testCachedSynchronousContentWithCurrentAllow() {
        let verdictProbe = VerdictProbe()
        let probe = ContentProbe()
        let recorder = Recorder()
        let disposable = recorder.start(gate(verdicts: verdictProbe.wrap(ValuePromise<Bool>(true).get()), content: {
            probe.signal { subscriber in
                subscriber.putNext(finalValue)
                subscriber.putCompletion()
            }
        }))
        defer {
            disposable.dispose()
        }

        XCTAssertEqual(recorder.values, [finalValue])
        XCTAssertEqual(recorder.completions, 1)
        XCTAssertEqual(recorder.errors, [])
        XCTAssertEqual(verdictProbe.subscriptions.with { $0 }, 1)
        XCTAssertEqual(verdictProbe.disposals.with { $0 }, 1)
    }

    func testCachedSynchronousContentWithCurrentDeny() {
        let probe = ContentProbe()
        let recorder = Recorder()
        let disposable = recorder.start(gate(verdicts: ValuePromise<Bool>(false).get(), content: {
            probe.signal { subscriber in
                subscriber.putNext(finalValue)
                subscriber.putCompletion()
            }
        }))
        defer {
            disposable.dispose()
        }

        XCTAssertEqual(probe.factoryCalls.with { $0 }, 0)
        XCTAssertEqual(probe.starts.with { $0 }, 0)
        XCTAssertEqual(recorder.values, [])
        XCTAssertEqual(recorder.errors, [.denied])
    }

    // 5. A revocation after the final value changes nothing.
    func testLateRevokeAfterFinalIsIgnored() {
        let verdicts = ValuePipe<Bool>()
        let probe = ContentProbe()
        let recorder = Recorder()
        var contentSubscriber: Subscriber<Int, GateTestError>?
        let disposable = recorder.start(gate(verdicts: verdicts.signal(), content: {
            probe.signal { contentSubscriber = $0 }
        }))
        defer {
            disposable.dispose()
        }

        verdicts.putNext(true)
        contentSubscriber?.putNext(finalValue)
        verdicts.putNext(false)

        XCTAssertEqual(recorder.values, [finalValue])
        XCTAssertEqual(recorder.completions, 1)
        XCTAssertEqual(recorder.errors, [])
    }

    // 6. Every way of not getting an allow is a denial.
    func testNoVerdictWithinTheTimeoutIsDenied() {
        let probe = ContentProbe()
        let recorder = Recorder()
        let done = self.expectation(description: "denied")
        let disposable = recorder.start(gate(verdicts: .never(), timeout: 0.05, content: { probe.signal { _ in } }), onTerminate: {
            done.fulfill()
        })
        self.wait(for: [done], timeout: 5.0)
        disposable.dispose()

        XCTAssertEqual(recorder.errors, [.denied])
        XCTAssertEqual(probe.factoryCalls.with { $0 }, 0)
    }

    func testEmptyVerdictStreamIsDenied() {
        let probe = ContentProbe()
        let recorder = Recorder()
        let disposable = recorder.start(gate(verdicts: .complete(), content: { probe.signal { _ in } }))
        defer {
            disposable.dispose()
        }

        XCTAssertEqual(recorder.errors, [.denied])
        XCTAssertEqual(probe.factoryCalls.with { $0 }, 0)
    }

    func testFalseFirstIsDenied() {
        let verdicts = ValuePipe<Bool>()
        let probe = ContentProbe()
        let recorder = Recorder()
        let disposable = recorder.start(gate(verdicts: verdicts.signal(), content: { probe.signal { _ in } }))
        defer {
            disposable.dispose()
        }

        verdicts.putNext(false)
        verdicts.putNext(true)

        XCTAssertEqual(recorder.errors, [.denied])
        XCTAssertEqual(probe.factoryCalls.with { $0 }, 0)
    }

    // 7. Content outcomes pass through.
    func testContentErrorPropagates() {
        let probe = ContentProbe()
        let recorder = Recorder()
        let disposable = recorder.start(gate(verdicts: ValuePromise<Bool>(true).get(), content: {
            probe.signal { $0.putError(.upload) }
        }))
        defer {
            disposable.dispose()
        }

        XCTAssertEqual(recorder.errors, [.upload])
    }

    func testContentCompletingWithoutFinalCompletes() {
        let probe = ContentProbe()
        let recorder = Recorder()
        let disposable = recorder.start(gate(verdicts: ValuePromise<Bool>(true).get(), content: {
            probe.signal { subscriber in
                subscriber.putNext(1)
                subscriber.putCompletion()
            }
        }))
        defer {
            disposable.dispose()
        }

        XCTAssertEqual(recorder.values, [1])
        XCTAssertEqual(recorder.completions, 1)
        XCTAssertEqual(recorder.errors, [])
    }

    // 8. Disposal mid-upload disposes everything and emits nothing further.
    func testDisposalMidUploadDisposesEverything() {
        let verdicts = ValuePipe<Bool>()
        let verdictProbe = VerdictProbe()
        let probe = ContentProbe()
        let recorder = Recorder()
        var contentSubscriber: Subscriber<Int, GateTestError>?
        let disposable = recorder.start(gate(verdicts: verdictProbe.wrap(verdicts.signal()), content: {
            probe.signal { contentSubscriber = $0 }
        }))

        verdicts.putNext(true)
        contentSubscriber?.putNext(1)
        disposable.dispose()
        contentSubscriber?.putNext(2)
        verdicts.putNext(false)

        XCTAssertEqual(probe.disposals.with { $0 }, 1)
        XCTAssertEqual(verdictProbe.disposals.with { $0 }, 1)
        XCTAssertEqual(recorder.values, [1])
        XCTAssertEqual(recorder.errors, [])
        XCTAssertEqual(recorder.completions, 0)
    }

    // Barrier regressions: a revocation or disposal that lands while the content factory is still
    // building must win — the upload is never started afterwards.
    func testRevokeDuringBlockedFactoryNeverStartsContent() {
        let verdicts = ValuePipe<Bool>()
        let probe = ContentProbe()
        let recorder = Recorder()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let disposable = recorder.start(gate(verdicts: verdicts.signal(), content: {
            entered.signal()
            release.wait()
            return probe.signal { _ in }
        }))
        defer {
            disposable.dispose()
        }

        let factoryReturned = self.expectation(description: "factory returned")
        DispatchQueue.global().async {
            verdicts.putNext(true)
            factoryReturned.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5.0), .success)
        verdicts.putNext(false)
        release.signal()
        self.wait(for: [factoryReturned], timeout: 5.0)

        XCTAssertEqual(probe.factoryCalls.with { $0 }, 1)
        XCTAssertEqual(probe.starts.with { $0 }, 0)
        XCTAssertEqual(recorder.errors, [.denied])
    }

    func testDisposalDuringBlockedFactoryNeverStartsContent() {
        let verdicts = ValuePipe<Bool>()
        let probe = ContentProbe()
        let recorder = Recorder()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let disposable = recorder.start(gate(verdicts: verdicts.signal(), content: {
            entered.signal()
            release.wait()
            return probe.signal { _ in }
        }))

        let factoryReturned = self.expectation(description: "factory returned")
        DispatchQueue.global().async {
            verdicts.putNext(true)
            factoryReturned.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5.0), .success)
        disposable.dispose()
        release.signal()
        self.wait(for: [factoryReturned], timeout: 5.0)

        XCTAssertEqual(probe.factoryCalls.with { $0 }, 1)
        XCTAssertEqual(probe.starts.with { $0 }, 0)
        XCTAssertEqual(recorder.errors, [])
        XCTAssertEqual(recorder.values, [])
    }
}
