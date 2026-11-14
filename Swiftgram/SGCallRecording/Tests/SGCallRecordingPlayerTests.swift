import XCTest
import AVFoundation
import UIKit

import SwiftSignalKit
@testable import SGCallRecording

/// Zenlygram — lifecycle of the recording player with the audio session, the engine, the clock and
/// the notification centre all replaced by fakes. Nothing here touches `AVAudioSession`, starts an
/// `AVAudioEngine` or plays a sound: these prove the state machine (no surprise playback, bounded
/// activation, interruption handling, claim release), not the device's audio behaviour.
final class SGCallRecordingPlayerTests: XCTestCase {
    private var center: NotificationCenter!
    private var clock: SGFakeTimeoutClock!
    private var session: SGFakeAudioSessionArbiter!
    private var outputs: [SGFakePlayerOutput] = []
    private var sourceChunks: Int = 10
    private var player: SGCallRecordingPlayer!
    private var endings: [SGCallRecordingPlaybackEnd] = []

    override func setUp() {
        super.setUp()
        self.center = NotificationCenter()
        self.clock = SGFakeTimeoutClock()
        self.session = SGFakeAudioSessionArbiter()
        self.outputs = []
        self.sourceChunks = 10
        self.endings = []
        self.player = self.makePlayer()
    }

    override func tearDown() {
        self.player.stop()
        self.player = nil
        super.tearDown()
    }

    private func makePlayer(makeOutput: (() -> SGCallRecordingPlayerOutput)? = nil) -> SGCallRecordingPlayer {
        return SGCallRecordingPlayer(
            notificationCenter: self.center,
            activationTimeout: 2.0,
            scheduleTimeout: { [unowned self] delay, fire in
                return self.clock.schedule(delay: delay, fire: fire)
            },
            makeSource: { [unowned self] _ in
                return SGFakePCMSource(chunks: self.sourceChunks)
            },
            makeOutput: makeOutput ?? { [unowned self] () -> SGCallRecordingPlayerOutput in
                let output = SGFakePlayerOutput()
                self.outputs.append(output)
                return output
            }
        )
    }

    private func play(_ id: String = "a", acquire: SGCallRecordingAudioSessionAcquire? = nil) {
        self.player.play(id: id, audioPaths: ["/unused"], acquireAudioSession: acquire ?? self.session.acquire, onFinish: { [unowned self] end in
            self.endings.append(end)
        })
    }

    // MARK: - No surprise playback

    func testNothingStartsBeforeTheArbiterGrantsTheSession() {
        self.play()

        XCTAssertEqual(self.session.claims.count, 1)
        XCTAssertTrue(self.outputs.isEmpty, "no engine may exist before the session is granted")
        XCTAssertEqual(self.player.currentIdValue, "a")
        XCTAssertEqual(self.clock.pending.map { $0.delay }, [2.0], "the claim must be bounded")
    }

    func testActivationTimeoutReleasesTheClaimAndALateGrantNeverPlays() {
        self.play()

        self.clock.fireAll()

        XCTAssertEqual(self.endings, [.activationTimedOut])
        XCTAssertEqual(self.session.claims[0].disposeCount, 1, "the queued claim must be given back to the arbiter")
        XCTAssertNil(self.player.currentIdValue)

        // The call ends minutes later and the arbiter grants the claim anyway.
        self.session.claims[0].activated()
        XCTAssertTrue(self.outputs.isEmpty, "a grant after the timeout must not start playback")
        XCTAssertEqual(self.endings, [.activationTimedOut])
    }

    func testGrantInTimeCancelsTheTimeoutAndStartsPlayback() {
        self.play()

        self.session.claims[0].activated()

        XCTAssertEqual(self.clock.pending.first?.disposed, true, "the timeout must be cancelled on grant")
        XCTAssertEqual(self.outputs.count, 1)
        XCTAssertEqual(self.outputs[0].startCount, 1)
        XCTAssertEqual(self.outputs[0].scheduledFrames.count, 3, "three buffers of lead")

        // A timer that still fires (disposed too late) must be harmless once playing.
        self.clock.pending[0].fire()
        XCTAssertTrue(self.endings.isEmpty)
        XCTAssertEqual(self.player.currentIdValue, "a")
    }

    func testBackgroundWhileWaitingForTheSessionGivesTheClaimBack() {
        self.play()

        self.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertEqual(self.endings, [.interrupted])
        XCTAssertEqual(self.session.claims[0].disposeCount, 1)
        self.session.claims[0].activated()
        XCTAssertTrue(self.outputs.isEmpty, "a claim granted after backgrounding must not play")
    }

    func testBackgroundWhilePlayingStops() {
        self.play()
        self.session.claims[0].activated()

        self.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertEqual(self.endings, [.interrupted])
        XCTAssertEqual(self.outputs[0].stopCount, 1)
        XCTAssertEqual(self.session.claims[0].disposeCount, 1)
    }

    // MARK: - Route and engine changes

    func testHeadphonesUnpluggedStopsInsteadOfMovingToTheSpeaker() {
        self.play()
        self.session.claims[0].activated()

        self.postRouteChange(.newDeviceAvailable)
        XCTAssertTrue(self.endings.isEmpty, "plugging something in is not a reason to stop")

        self.postRouteChange(.oldDeviceUnavailable)
        XCTAssertEqual(self.endings, [.interrupted])
        XCTAssertEqual(self.outputs[0].stopCount, 1)
        XCTAssertEqual(self.session.claims[0].disposeCount, 1)
    }

    func testRouteLossWhileWaitingForTheSessionIsIgnored() {
        // The previous holder (the call) tearing its route down is not our playback.
        self.play()

        self.postRouteChange(.oldDeviceUnavailable)

        XCTAssertTrue(self.endings.isEmpty)
        XCTAssertEqual(self.session.claims[0].disposeCount, 0)
    }

    func testEngineReconfigurationStopsTheOwnEngineOnly() {
        self.play()
        self.session.claims[0].activated()

        self.center.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
        XCTAssertTrue(self.endings.isEmpty, "another engine's reconfiguration is not ours")

        self.center.post(name: .AVAudioEngineConfigurationChange, object: self.outputs[0].configurationChangeObject)
        XCTAssertEqual(self.endings, [.interrupted])
        XCTAssertNil(self.player.currentIdValue)
    }

    func testMediaServicesResetStops() {
        self.play()
        self.session.claims[0].activated()

        self.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        XCTAssertEqual(self.endings, [.interrupted])
    }

    func testArbiterTakingTheSessionBackStops() {
        self.play()
        self.session.claims[0].activated()

        self.session.claims[0].deactivate()

        XCTAssertEqual(self.endings, [.interrupted])
        XCTAssertEqual(self.outputs[0].stopCount, 1)
    }

    // MARK: - Ending and replacement

    func testPlaysToTheEndAndReleasesTheClaim() {
        self.sourceChunks = 2
        self.play()
        self.session.claims[0].activated()
        XCTAssertEqual(self.outputs[0].scheduledFrames.count, 2)

        self.outputs[0].playBackNext()
        XCTAssertTrue(self.endings.isEmpty, "one buffer is still queued")
        self.outputs[0].playBackNext()

        XCTAssertEqual(self.endings, [.finished])
        XCTAssertEqual(self.session.claims[0].disposeCount, 1)
        XCTAssertNil(self.player.currentIdValue)
    }

    func testReplacingAnItemDoesNotOverscheduleFromStaleCompletions() {
        self.play("a")
        self.session.claims[0].activated()

        // `stop()` inside the second play fires the first item's pending completions, as the node does.
        self.play("b")
        self.session.claims[1].activated()

        XCTAssertEqual(self.session.claims[0].disposeCount, 1)
        XCTAssertEqual(self.outputs.count, 2, "each playback gets a fresh engine")
        XCTAssertEqual(self.outputs[1].scheduledFrames.count, 3, "stale completions must not schedule for the new item")
        XCTAssertTrue(self.endings.isEmpty, "a replaced item is stopped, not finished")
        XCTAssertEqual(self.player.currentIdValue, "b")
    }

    func testExplicitStopReportsNothingAndDetachesFromNotifications() {
        self.play()
        self.session.claims[0].activated()

        self.player.stop()
        self.player.stop()

        XCTAssertTrue(self.endings.isEmpty, "an explicit stop is not an ending")
        XCTAssertEqual(self.session.claims[0].disposeCount, 1, "stop is idempotent")
        XCTAssertEqual(self.outputs[0].stopCount, 1)

        self.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        self.postRouteChange(.oldDeviceUnavailable)
        XCTAssertTrue(self.endings.isEmpty)
        XCTAssertEqual(self.session.claims[0].disposeCount, 1)
    }

    // MARK: - Synchronous arbiter and failures

    func testEngineFailureInsideASynchronousGrantStillReleasesTheClaim() {
        self.player = self.makePlayer(makeOutput: { [unowned self] in
            let output = SGFakePlayerOutput()
            output.startError = NSError(domain: "SGCallRecordingPlayerTests", code: 1)
            self.outputs.append(output)
            return output
        })
        let claim = SGFakeAudioSessionClaim()
        self.play(acquire: { activated, deactivate in
            claim.activated = activated
            claim.deactivate = deactivate
            activated()
            return ActionDisposable {
                claim.disposeCount += 1
            }
        })

        XCTAssertEqual(self.endings, [.failed])
        XCTAssertEqual(claim.disposeCount, 1, "a claim returned after the playback already ended must be given back")
        XCTAssertNil(self.player.currentIdValue)
    }

    func testUnreadableFileFailsWithoutClaimingTheSession() {
        let player = SGCallRecordingPlayer(notificationCenter: self.center, makeOutput: { [unowned self] in
            let output = SGFakePlayerOutput()
            self.outputs.append(output)
            return output
        })
        var ending: SGCallRecordingPlaybackEnd?
        let missing = NSTemporaryDirectory() + "sg-player-missing-\(UUID().uuidString).ogg"

        player.play(id: "missing", audioPaths: [missing], acquireAudioSession: self.session.acquire, onFinish: { end in
            ending = end
        })

        XCTAssertEqual(ending, .failed)
        XCTAssertTrue(self.session.claims.isEmpty)
        XCTAssertTrue(self.outputs.isEmpty)
        XCTAssertNil(player.currentIdValue)
    }

    private func postRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        self.center.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }
}

// MARK: - Fakes

private final class SGFakeAudioSessionClaim {
    var activated: () -> Void = {}
    var deactivate: () -> Void = {}
    var disposeCount: Int = 0
}

/// Stands in for `ManagedAudioSession`: records each claim and lets the test decide when (or
/// whether) it is granted or taken back.
private final class SGFakeAudioSessionArbiter {
    private(set) var claims: [SGFakeAudioSessionClaim] = []

    var acquire: SGCallRecordingAudioSessionAcquire {
        return { [unowned self] activated, deactivate in
            let claim = SGFakeAudioSessionClaim()
            claim.activated = activated
            claim.deactivate = deactivate
            self.claims.append(claim)
            return ActionDisposable {
                claim.disposeCount += 1
            }
        }
    }
}

private final class SGFakeTimeout {
    let delay: Double
    let fire: () -> Void
    var disposed: Bool = false

    init(delay: Double, fire: @escaping () -> Void) {
        self.delay = delay
        self.fire = fire
    }
}

/// A clock the test advances by hand. Disposing a timeout only records it, so a test can also fire
/// one that was cancelled too late and check the player ignores it.
private final class SGFakeTimeoutClock {
    private(set) var pending: [SGFakeTimeout] = []

    func schedule(delay: Double, fire: @escaping () -> Void) -> Disposable {
        let timeout = SGFakeTimeout(delay: delay, fire: fire)
        self.pending.append(timeout)
        return ActionDisposable {
            timeout.disposed = true
        }
    }

    func fireAll() {
        for timeout in self.pending where !timeout.disposed {
            timeout.fire()
        }
    }
}

private final class SGFakePCMSource: SGCallRecordingPCMSource {
    private var remainingChunks: Int
    private var exhausted: Bool = false

    init(chunks: Int) {
        self.remainingChunks = chunks
    }

    var isFinished: Bool {
        return self.exhausted
    }

    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        guard self.remainingChunks > 0 else {
            self.exhausted = true
            return 0
        }
        self.remainingChunks -= 1
        let frames = min(960, maxFrames)
        destination.update(repeating: 0.0, count: frames)
        if self.remainingChunks == 0 {
            self.exhausted = true
        }
        return frames
    }
}

/// Stands in for the engine + player node. `stop()` discards pending buffers and fires their
/// completions, as `AVAudioPlayerNode.stop()` does.
private final class SGFakePlayerOutput: SGCallRecordingPlayerOutput {
    let configurationChangeObject: AnyObject = NSObject()
    var startError: Error?
    private(set) var startCount: Int = 0
    private(set) var stopCount: Int = 0
    private(set) var scheduledFrames: [Int] = []
    private var pendingCompletions: [() -> Void] = []

    func start(format: AVAudioFormat) throws {
        self.startCount += 1
        if let startError = self.startError {
            throw startError
        }
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        self.scheduledFrames.append(Int(buffer.frameLength))
        self.pendingCompletions.append(completion)
    }

    func stop() {
        self.stopCount += 1
        let completions = self.pendingCompletions
        self.pendingCompletions = []
        for completion in completions {
            completion()
        }
    }

    func playBackNext() {
        guard !self.pendingCompletions.isEmpty else {
            return
        }
        self.pendingCompletions.removeFirst()()
    }
}
