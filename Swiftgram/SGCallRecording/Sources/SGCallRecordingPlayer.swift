// MARK: Zenlygram — call recording, playback.
//
// Plays a recording back inside the app. Nothing is written to disk to make that happen, and
// nothing is ever copied out of the recordings directory.
//
// A recording made by this build is ONE file — the two directions were summed at record time — so
// playback is a straight decode. A recording made before that is still a PAIR, and those are still
// here and still play: the reader decodes both and sums them on the fly, exactly as it always did,
// so an older recording sounds like the same conversation it always did. Hence `audioPaths` rather
// than a single path; it is one element or two, and the mixing loop below does not care which.
//
// Decoding is streamed rather than done up front on purpose: an hour of call at 48 kHz mono is
// ~345 MB of PCM per file, which is not something to materialise for a settings screen.
//
// For a pair, the two streams were captured on two different clocks (see SGCallRecordingSession),
// so summing them from t = 0 is an approximation. It is the honest one available at this layer, and
// it is the same one the recorder now makes once, up front. (An approximation at the ppm level:
// every path that could drop or elide samples on one side writes silence instead, so the two stay
// index-aligned. See SGCallRecordingRingBuffer.)
//
// THE AUDIO SESSION IS NOT OURS TO TAKE. `ManagedAudioSession` is the single owner of
// `AVAudioSession` in this app; a `setCategory(.playback)` issued straight to the shared instance
// while a call is running replaces the live `.playAndRecord`/`voiceChat` configuration under
// tgcalls' VoiceProcessingIO unit and kills the microphone for the rest of that call, with no
// recovery — `ManagedAudioSession.setup` short-circuits on its cached type, so it never reapplies.
// And the recordings list is reachable exactly then, with the call minimised behind the status-bar
// call bar. So playback asks the arbiter for the session like every other client in the app
// (see NotificationSoundSelection.playSound) and plays only once it is granted; if the call takes
// the session back, the arbiter's deactivate stops us.
//
// NO SURPRISE PLAYBACK. The arbiter never evicts a `.voiceCall` holder, so a claim made during a
// call is not refused — it is QUEUED, and it is granted the moment the call ends: minutes later,
// possibly with the app in the background and no Stop button on screen, out of the loudspeaker.
// For a recording of a private conversation that is the worst failure this file can have. So:
//   - the claim is bounded: if the session is not granted within `sgPlayerActivationTimeout`, the
//     claim is given back and playback ends with `.activationTimedOut`; a grant that lands after
//     that is fenced off by the generation and ignored;
//   - the app going to the background ends playback (waiting or playing);
//   - losing the output (headphones unplugged), the engine being reconfigured under us, or media
//     services resetting ends playback rather than carrying on out loud or sitting silent in a
//     "Playing" row.
// The caller (the recordings list) additionally refuses Play while a call is ongoing and calls
// `stop()` when the screen goes away; this file is the backstop, not the only guard.

import Foundation
import UIKit
import AVFoundation

import SwiftSignalKit
import OpusBinding

private let sgPlayerSampleRate: Double = 48000.0
private let sgPlayerChunkFrames: Int = 24000
private let sgPlayerBuffersAhead: Int = 3
/// `OP_HOLE` from opusfile: a gap in the stream, and the one negative result that means "call again"
/// rather than "give up".
private let sgPlayerOpusHole: Int32 = -3
private let sgPlayerMaxHoleRetries: Int = 8
/// How long the arbiter has to grant the session. A `.play` claim is normally granted within a few
/// hundred milliseconds; one that is still pending after this is queued behind something that will
/// not give the session up (a call), and must not be left to fire later.
let sgPlayerActivationTimeout: Double = 2.0

/// Asks the app's audio-session arbiter for the session. `activated` is invoked on the main queue
/// once playback may start; `deactivate` is invoked on the main queue when the session has to be
/// given back (an incoming call, say). Disposing the result releases the claim.
public typealias SGCallRecordingAudioSessionAcquire = (_ activated: @escaping () -> Void, _ deactivate: @escaping () -> Void) -> Disposable

/// Why playback ended on its own. Not reported for an explicit `stop()`.
public enum SGCallRecordingPlaybackEnd: Equatable {
    /// The recording played to its end.
    case finished
    /// The audio session was not granted in time — typically because a call holds it. Nothing was
    /// played and nothing will be.
    case activationTimedOut
    /// The session was taken back, the output went away, the engine was reconfigured, media services
    /// reset, or the app went to the background.
    case interrupted
    /// The file could not be opened or the engine could not start.
    case failed
}

/// Where decoded mono float comes from. A seam so the lifecycle can be exercised without a file.
protocol SGCallRecordingPCMSource: AnyObject {
    var isFinished: Bool { get }
    /// Fills `destination` and returns how many frames were produced; 0 once exhausted.
    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int
}

/// The audio-engine half of the player, behind a seam so the lifecycle can be driven in tests with
/// no audio hardware. One instance per playback: a fresh engine every time means nothing survives
/// an engine reconfiguration or a media-services reset into the next recording.
protocol SGCallRecordingPlayerOutput: AnyObject {
    /// The object `AVAudioEngineConfigurationChange` is posted for.
    var configurationChangeObject: AnyObject { get }
    func start(format: AVAudioFormat) throws
    /// `completion` runs on any thread once the buffer has been played back, or discarded by `stop()`.
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void)
    func stop()
}

final class SGCallRecordingEngineOutput: SGCallRecordingPlayerOutput {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    var configurationChangeObject: AnyObject {
        return self.engine
    }

    func start(format: AVAudioFormat) throws {
        if !self.engine.attachedNodes.contains(self.playerNode) {
            self.engine.attach(self.playerNode)
            self.engine.connect(self.playerNode, to: self.engine.mainMixerNode, format: format)
        }
        if !self.engine.isRunning {
            try self.engine.start()
        }
        self.playerNode.play()
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        self.playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack, completionHandler: { _ in
            completion()
        })
    }

    func stop() {
        self.playerNode.stop()
        if self.engine.isRunning {
            self.engine.stop()
        }
    }
}

/// Internal, not private: it is a default argument of the (internal) player initializer.
func sgPlayerMainQueueTimeout(_ delay: Double, _ fire: @escaping () -> Void) -> Disposable {
    let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: fire, queue: Queue.mainQueue())
    timer.start()
    return ActionDisposable {
        timer.invalidate()
    }
}

/// True for the route changes after which continuing would either play out of a different output
/// than the one the user chose (headphones unplugged → loudspeaker) or play to nowhere.
private func sgPlayerRouteChangeLosesOutput(_ userInfo: [AnyHashable: Any]?) -> Bool {
    guard let rawReason = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
        return false
    }
    switch reason {
    case .oldDeviceUnavailable, .noSuitableRouteForCategory:
        return true
    default:
        return false
    }
}

/// Pulls from a recording's file (or, for a pre-mix recording, its pair) and hands back mono float.
final class SGCallRecordingMixReader: SGCallRecordingPCMSource {
    /// One per file: exactly one for a recording made by this build, two for a pre-mix pair.
    private let readers: [OggOpusReader]
    private var finished: [Bool]
    private var counts: [Int]
    /// `readers.count` chunks laid end to end, one per reader.
    private let scratch: UnsafeMutablePointer<Int16>

    init?(paths: [String]) {
        let readers = paths.compactMap { OggOpusReader(path: $0) }
        if readers.isEmpty {
            return nil
        }
        self.readers = readers
        self.finished = Array(repeating: false, count: readers.count)
        self.counts = Array(repeating: 0, count: readers.count)
        self.scratch = UnsafeMutablePointer<Int16>.allocate(capacity: readers.count * sgPlayerChunkFrames)
        self.scratch.initialize(repeating: 0, count: readers.count * sgPlayerChunkFrames)
    }

    deinit {
        self.scratch.deinitialize(count: self.readers.count * sgPlayerChunkFrames)
        self.scratch.deallocate()
    }

    var isFinished: Bool {
        return !self.finished.contains(false)
    }

    /// Fills `destination` (float32, mono) and returns how many frames were produced.
    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let wanted = min(maxFrames, sgPlayerChunkFrames)
        var produced = 0

        for index in 0 ..< self.readers.count {
            self.counts[index] = 0
            if self.finished[index] {
                continue
            }
            // LOOP UNTIL THE CHUNK IS FULL. `OggOpusReader.read` is a bare `op_read`, and `op_read`
            // decodes exactly ONE Opus packet per call — 960 frames, 20 ms, for a file this app
            // wrote — then returns. It is documented to return less than asked for and it never
            // fills the caller's buffer.
            //
            // Calling it once made every scheduled `AVAudioPCMBuffer` 20 ms long instead of the 500
            // ms this class is built around, so the three buffers scheduled ahead were 60 ms of
            // lead, not 1.5 s. The device's own output latency is larger than that on every real
            // iPhone, so the player node ran dry between buffers, rendered silence, and resumed
            // when the next one landed: audio that cuts in and out tens of times a second, in every
            // recording, regardless of what was recorded. The file on disk was always fine.
            let base = self.scratch.advanced(by: index * sgPlayerChunkFrames)
            var filled = 0
            var holeRetries = 0
            while filled < wanted {
                let result = self.readers[index].read(base.advanced(by: filled), bufSize: Int32(wanted - filled))
                if result > 0 {
                    filled += Int(result)
                } else if result == sgPlayerOpusHole && holeRetries < sgPlayerMaxHoleRetries {
                    // A gap in the stream. opusfile's own guidance is to call again; bounded so a
                    // corrupt file cannot spin here forever.
                    holeRetries += 1
                } else {
                    // 0 is clean end of stream; any other negative is a decode error. Either way
                    // this reader is done — and whatever it already produced this round still plays.
                    self.finished[index] = true
                    break
                }
            }
            self.counts[index] = filled
            produced = max(produced, filled)
        }

        if produced == 0 {
            return 0
        }
        for frame in 0 ..< produced {
            var value: Float = 0.0
            for index in 0 ..< self.readers.count where frame < self.counts[index] {
                value += Float(self.scratch[index * sgPlayerChunkFrames + frame]) / 32768.0
            }
            destination[frame] = max(-1.0, min(1.0, value))
        }
        return produced
    }
}

public final class SGCallRecordingPlayer {
    public static let shared = SGCallRecordingPlayer()

    private enum Phase {
        case idle
        /// The claim is with the arbiter; nothing has been started and the timeout is armed.
        case awaitingAudioSession
        case playing
    }

    private let format: AVAudioFormat?
    private let notificationCenter: NotificationCenter
    private let activationTimeout: Double
    private let scheduleTimeout: (Double, @escaping () -> Void) -> Disposable
    private let makeSource: ([String]) -> SGCallRecordingPCMSource?
    private let makeOutput: () -> SGCallRecordingPlayerOutput

    private var phase: Phase = .idle
    private var source: SGCallRecordingPCMSource?
    private var output: SGCallRecordingPlayerOutput?
    private var pendingBufferCount: Int = 0
    private var onFinish: ((SGCallRecordingPlaybackEnd) -> Void)?
    private var audioSessionDisposable: Disposable?
    private var activationTimeoutDisposable: Disposable?
    private var observers: [NSObjectProtocol] = []
    /// Bumped by every `play()` and every `stop()`.
    ///
    /// `AVAudioPlayerNode.stop()` fires the pending `.dataPlayedBack` completion handlers, and the
    /// header of `scheduleBuffer(...)` is explicit that they arrive on a non-main thread — so they
    /// hop to the main queue and land AFTER the `play()` that replaced them has finished resetting
    /// the counter. Without a token each stale handler schedules one more buffer for the NEW item,
    /// leaving the node holding more buffers than the counter knows about; the counter then reaches
    /// zero early and `finishPlayback()` cuts the tail off the recording, by a further 1.5 s with
    /// every switch.
    ///
    /// The same token fences the arbiter's late grant after the activation timeout, and every
    /// lifecycle notification that hops to the main queue after the playback it was meant for ended.
    private var playbackGeneration: Int = 0

    private let currentIdPromise = ValuePromise<String?>(nil, ignoreRepeated: true)
    /// The id of the recording currently playing (or waiting for the audio session), or nil. Drives
    /// the play/stop state in the list.
    public var currentId: Signal<String?, NoError> {
        return self.currentIdPromise.get()
    }
    public private(set) var currentIdValue: String?

    init(
        notificationCenter: NotificationCenter = .default,
        activationTimeout: Double = sgPlayerActivationTimeout,
        scheduleTimeout: @escaping (Double, @escaping () -> Void) -> Disposable = sgPlayerMainQueueTimeout,
        makeSource: @escaping ([String]) -> SGCallRecordingPCMSource? = { SGCallRecordingMixReader(paths: $0) },
        makeOutput: @escaping () -> SGCallRecordingPlayerOutput = { SGCallRecordingEngineOutput() }
    ) {
        self.format = AVAudioFormat(standardFormatWithSampleRate: sgPlayerSampleRate, channels: 1)
        self.notificationCenter = notificationCenter
        self.activationTimeout = activationTimeout
        self.scheduleTimeout = scheduleTimeout
        self.makeSource = makeSource
        self.makeOutput = makeOutput
    }

    deinit {
        for observer in self.observers {
            self.notificationCenter.removeObserver(observer)
        }
        self.activationTimeoutDisposable?.dispose()
        self.output?.stop()
        self.audioSessionDisposable?.dispose()
    }

    /// Starts playback, replacing whatever was playing. Main queue.
    ///
    /// `onFinish` reports why playback ended on its own; it is not called for an explicit `stop()`.
    /// The caller must not offer Play while a call is ongoing; if it does anyway, the claim is queued
    /// behind the call and this ends with `.activationTimedOut` rather than playing after the call.
    public func play(item: SGCallRecordingItem, acquireAudioSession: SGCallRecordingAudioSessionAcquire, onFinish: @escaping (SGCallRecordingPlaybackEnd) -> Void) {
        self.play(id: item.id, audioPaths: item.audioPaths, acquireAudioSession: acquireAudioSession, onFinish: onFinish)
    }

    func play(id: String, audioPaths: [String], acquireAudioSession: SGCallRecordingAudioSessionAcquire, onFinish: @escaping (SGCallRecordingPlaybackEnd) -> Void) {
        assert(Thread.isMainThread)
        self.stop()

        guard self.format != nil, let source = self.makeSource(audioPaths) else {
            onFinish(.failed)
            return
        }

        self.playbackGeneration += 1
        let generation = self.playbackGeneration
        self.phase = .awaitingAudioSession
        self.source = source
        self.onFinish = onFinish
        self.pendingBufferCount = 0
        self.currentIdValue = id
        self.currentIdPromise.set(id)
        self.addLifecycleObservers(generation: generation)

        self.activationTimeoutDisposable = self.scheduleTimeout(self.activationTimeout, { [weak self] in
            guard let self, self.playbackGeneration == generation, self.phase == .awaitingAudioSession else {
                return
            }
            self.finishPlayback(.activationTimedOut)
        })

        // Nothing is played until the arbiter says the session is ours.
        let audioSessionDisposable = acquireAudioSession({ [weak self] in
            guard let self, self.playbackGeneration == generation, self.phase == .awaitingAudioSession else {
                return
            }
            self.beginEngine(generation: generation)
        }, { [weak self] in
            guard let self, self.playbackGeneration == generation else {
                return
            }
            self.finishPlayback(.interrupted)
        })
        // The grant (and whatever follows it — an engine that fails to start, a one-buffer file that
        // finishes) can run synchronously inside `acquireAudioSession`. If that already ended this
        // playback, `stop()` ran before there was a claim to give back: give it back now, or it
        // stays registered with the arbiter for good.
        if self.playbackGeneration == generation {
            self.audioSessionDisposable = audioSessionDisposable
        } else {
            audioSessionDisposable.dispose()
        }
    }

    private func beginEngine(generation: Int) {
        assert(Thread.isMainThread)
        self.activationTimeoutDisposable?.dispose()
        self.activationTimeoutDisposable = nil
        guard let format = self.format else {
            self.finishPlayback(.failed)
            return
        }
        let output = self.makeOutput()
        self.output = output
        self.phase = .playing
        do {
            try output.start(format: format)
        } catch {
            self.finishPlayback(.failed)
            return
        }
        guard self.playbackGeneration == generation else {
            return
        }
        // Registered once the engine runs: a reconfiguration stops the engine without firing the
        // buffer completions, which would otherwise leave a silent "Playing" row until a manual Stop.
        self.observers.append(self.notificationCenter.addObserver(forName: .AVAudioEngineConfigurationChange, object: output.configurationChangeObject, queue: nil, using: { [weak self] _ in
            Queue.mainQueue().async {
                self?.interrupt(generation: generation, onlyWhilePlaying: true)
            }
        }))
        self.refillQueue(generation: generation)
    }

    private func addLifecycleObservers(generation: Int) {
        let center = self.notificationCenter
        // Leaving the app ends playback, whether it is waiting for the session or already playing:
        // a queued claim granted in the background is exactly the surprise this file must not allow.
        self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: { [weak self] _ in
            Queue.mainQueue().async {
                self?.interrupt(generation: generation, onlyWhilePlaying: false)
            }
        }))
        // Observing is read-only: this module still never configures `AVAudioSession` itself.
        self.observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil, using: { [weak self] notification in
            guard sgPlayerRouteChangeLosesOutput(notification.userInfo) else {
                return
            }
            Queue.mainQueue().async {
                self?.interrupt(generation: generation, onlyWhilePlaying: true)
            }
        }))
        self.observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil, using: { [weak self] _ in
            Queue.mainQueue().async {
                self?.interrupt(generation: generation, onlyWhilePlaying: false)
            }
        }))
    }

    /// Route and engine changes only matter once something is coming out of the speaker; while the
    /// claim is pending they can be the previous holder (the call) tearing its route down.
    private func interrupt(generation: Int, onlyWhilePlaying: Bool) {
        assert(Thread.isMainThread)
        guard self.playbackGeneration == generation, self.phase != .idle else {
            return
        }
        if onlyWhilePlaying && self.phase != .playing {
            return
        }
        self.finishPlayback(.interrupted)
    }

    /// Tops the node back up to `sgPlayerBuffersAhead`.
    ///
    /// Each completion used to schedule exactly ONE replacement, so the queue could only ever shrink:
    /// a single late main-queue turnaround cost a buffer of lead permanently, and nothing ever won it
    /// back. Topping up instead means a hiccup costs one late buffer rather than a smaller queue for
    /// the rest of the recording.
    private func refillQueue(generation: Int) {
        assert(Thread.isMainThread)
        while self.pendingBufferCount < sgPlayerBuffersAhead {
            let before = self.pendingBufferCount
            self.scheduleNextBuffer(generation: generation)
            // The reader is exhausted, or a guard inside bailed. Either way nothing was queued and
            // looping again would spin.
            if self.pendingBufferCount == before {
                return
            }
        }
    }

    /// Main queue. Idempotent.
    public func stop() {
        assert(Thread.isMainThread)
        if self.phase == .idle {
            return
        }
        // Retires every completion handler, grant, timeout and notification still in flight before
        // `output.stop()` delivers the completions.
        self.playbackGeneration += 1
        self.phase = .idle
        self.activationTimeoutDisposable?.dispose()
        self.activationTimeoutDisposable = nil
        for observer in self.observers {
            self.notificationCenter.removeObserver(observer)
        }
        self.observers = []
        self.source = nil
        self.onFinish = nil
        self.pendingBufferCount = 0
        let output = self.output
        self.output = nil
        output?.stop()
        // Giving the claim back is what deactivates the session, through the arbiter that granted
        // it — and, for a claim still queued behind a call, what keeps it from being granted later.
        // This module never configures `AVAudioSession.sharedInstance()`.
        self.audioSessionDisposable?.dispose()
        self.audioSessionDisposable = nil
        self.currentIdValue = nil
        self.currentIdPromise.set(nil)
    }

    public func isPlaying(id: String) -> Bool {
        return self.currentIdValue == id
    }

    private func scheduleNextBuffer(generation: Int) {
        guard self.phase == .playing, self.playbackGeneration == generation, let source = self.source, let output = self.output, let format = self.format else {
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sgPlayerChunkFrames)) else {
            self.finishPlayback(.failed)
            return
        }
        guard let channelData = buffer.floatChannelData?[0] else {
            self.finishPlayback(.failed)
            return
        }
        let produced = source.read(into: channelData, maxFrames: sgPlayerChunkFrames)
        if produced == 0 {
            if self.pendingBufferCount == 0 {
                self.finishPlayback(.finished)
            }
            return
        }
        buffer.frameLength = AVAudioFrameCount(produced)
        self.pendingBufferCount += 1
        output.schedule(buffer, completion: { [weak self] in
            Queue.mainQueue().async {
                guard let self else {
                    return
                }
                // A handler belonging to a previous item: its buffer is already discarded, and its
                // count was zeroed by the `stop()` that retired it.
                if self.playbackGeneration != generation || self.phase != .playing {
                    return
                }
                self.pendingBufferCount -= 1
                if let source = self.source, source.isFinished, self.pendingBufferCount == 0 {
                    self.finishPlayback(.finished)
                } else {
                    self.refillQueue(generation: generation)
                }
            }
        })
    }

    private func finishPlayback(_ reason: SGCallRecordingPlaybackEnd) {
        let onFinish = self.onFinish
        self.stop()
        onFinish?(reason)
    }
}
