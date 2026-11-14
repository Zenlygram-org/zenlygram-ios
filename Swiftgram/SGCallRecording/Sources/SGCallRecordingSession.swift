// MARK: Zenlygram — call recording, the session.
//
// WHAT THIS IS. One recording of one 1:1 call: the tap, the ring buffers, the mixer and its single
// Opus encoder, and the state machine around them. It owns no UI and knows nothing about calls —
// the caller hands it a way to attach an audio sink and a way to ask whether the microphone is
// muted, and it hands back a state signal. That keeps the piece that touches the most sensitive
// data in the app small enough to read in one sitting.
//
// ONE FILE. A person who records a call wants a recording of the CONVERSATION. Two files — "your
// voice" and "their voice" — is a developer's answer to a user's question: it hands them an
// assembly job they never asked for, and every place the recording goes afterwards (the share
// sheet, another app, a lawyer) has to be told to play both at once. So the two directions are
// summed here, while they are still PCM, and one Ogg/Opus stream is written: `<id>.ogg`.
//
// THE THING THAT USED TO MAKE THAT HARD IS ALREADY SOLVED. The microphone and the playout arrive on
// two different clocks, and this layer does not relate them — which is why an earlier version of
// this file wrote one stream per direction rather than invent a common timebase. But the invariant
// that made playback able to sum the two files is the same invariant a mix needs: NEITHER STREAM
// MAY EVER LOSE TIME. Every path that would drop audio writes the same length of SILENCE instead —
// the mute gate below, and the ring buffer's overflow and format-change paths (see
// SGCallRecordingRingBuffer). So both rings are, by construction, exactly as long as the time that
// has passed, and summing them by sample index from t = 0 is the same approximation the player was
// already making — now made once, at record time, into the artefact the user actually gets.
//
// THE RINGS THEREFORE STAY. They are not an implementation detail of "two files"; they ARE the
// alignment mechanism. What changed is only what the drain loop does with them: it takes the same
// amount of time from both, sums it, and feeds one encoder. See `drainImpl`.
//
// THE MUTE GATE IS LOAD-BEARING. `setMuteMicrophone` is applied downstream of this tap — it reaches
// the outgoing audio channel (tgcalls/v2/InstanceV2Impl.cpp:2044-2054), not the audio device — so
// the microphone callback keeps delivering audio while the user is muted. Without the explicit gate
// below, a recording would contain speech the other party never heard. That is a privacy bug
// against our own user, and it is the kind of thing App Review is right to reject. The gate writes
// silence rather than nothing, which preserves the privacy property exactly (no speech the far side
// never heard is captured) while keeping the stream on its clock.
//
// WHAT IT CANNOT DO. It cannot put a tone into the outgoing stream: `addExternalAudioSamples` is an
// empty default (tgcalls/Instance.h:199) overridden only by the legacy `InstanceImpl` and
// `GroupInstanceCustomImpl`, and not by `InstanceV2Impl`, `InstanceV2ReferenceImpl` or
// `InstanceV2CompatImpl` — which between them serve every call version this app negotiates. The
// "tell the other party" setting is therefore implemented as a real chat message plus a local tone,
// and says so in its own description. See SGCallRecordingGate.notifyOtherParty.

import Foundation

import SwiftSignalKit
import OpusBinding
import SGCallRecordingObjC
import SGCustomerSyncCore

/// Which side of the call a buffer came from. Matches the constants the ObjC tap passes.
public enum SGCallRecordingDirection: Int32 {
    /// The local microphone, as captured by the OS — already echo-cancelled and AGC'd, because the
    /// ADM runs `kAudioUnitSubType_VoiceProcessingIO` for a normal call.
    case local = 0
    /// The mixed playout buffer, i.e. what the user hears from the other party.
    case remote = 1
}

public enum SGCallRecordingFailure: Equatable {
    /// The build-time flag is off, or the shared audio device this tap needs does not exist (the
    /// `ios_killswitch_disable_call_device` path removes it entirely).
    case unavailable
    /// The one-time consent screen has not been accepted.
    case noConsent
    /// The files could not be created or written.
    case storage
    /// There is not enough free space to start.
    case noSpace
    /// This account's recordings are being removed (a logout or account removal is still being
    /// cleaned up), so nothing new may be recorded under it yet. Not a paywall, not a setting:
    /// it clears once the cleanup finishes or the account is seen signed in again.
    case accountCleanupPending
}

/// Something the user has to be told about a recording that DID produce a file.
///
/// A failure means nothing was saved; a problem means something was, but it is not what the user
/// expected. Both have to reach a screen — the point of the whole feature is that the artefact
/// exists, and silently handing back less than the user watched the indicator promise is the one
/// outcome that cannot be defended.
public enum SGCallRecordingProblem: Equatable {
    /// A write failed part-way through, so what is on disk stops before the call did.
    case truncated
}

public enum SGCallRecordingState: Equatable {
    case idle
    case recording(startTimestamp: Double)
    case finishing
    /// Finished and saved, but with something the user must be told.
    case finished(SGCallRecordingProblem)
    case failed(SGCallRecordingFailure)

    public var isActive: Bool {
        switch self {
        case .recording, .finishing:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }
}

/// The block the native tap invokes on the audio render thread.
/// `(direction, interleaved int16 samples, sample count, channel count, sample rate)`.
public typealias SGCallRecordingAudioSink = (Int32, UnsafePointer<Int16>, Int, Int, Int32) -> Void

/// Attaches a sink and returns a detach block, or nil when there is nothing to attach to.
public typealias SGCallRecordingSinkAttach = (@escaping SGCallRecordingAudioSink) -> (() -> Void)?

private let sgCallRecordingOutputSampleRate = 48000
/// 20 ms at 48 kHz — the frame size `TGOggOpusWriter` is configured for (opusenc.m:124-130).
private let sgCallRecordingFrameSampleCount = 960
/// Ten seconds of mono 48 kHz. The encoder drains every 200 ms, so this only has to absorb a stall.
private let sgCallRecordingRingCapacity = 48000 * 10
/// Read chunk out of the ring on each drain pass.
private let sgCallRecordingScratchCapacity = 48000
/// HOW FAR THE TWO DIRECTIONS MAY DRIFT APART BEFORE THE MIXER STOPS WAITING. One second of mono
/// 48 kHz.
///
/// The mixer consumes `min(local, remote)` so the two can never slip against each other. That is
/// correct while both taps are producing and catastrophic when only one is: `min` is zero, nothing
/// is encoded, and the recording stalls while the badge and the indicator keep promising the user
/// it is running. A stalled recording that looks like it is working is the worst outcome available
/// here, so the wait is bounded: once the two buffers differ by more than this, the short side is
/// padded with exactly that much silence and the mix carries on.
///
/// One second is five drain periods. Ordinary jitter is at most one (a tap callback landing just
/// after a drain), and the events that genuinely hold one direction — an audio route change, a
/// codec switch, a half-open call — are hundreds of milliseconds, so this is never tripped by
/// normal operation. And the padding is not usually even a lie: if the starved direction was
/// producing nothing, silence is what happened. It is only wrong if that audio existed somewhere
/// and arrives later in a burst, in which case it lands late by the amount padded — bounded, and
/// recorded, rather than a recording that quietly stops.
private let sgCallRecordingSkewToleranceSamples = sgCallRecordingOutputSampleRate
/// Refuse to start below this much free space. Opus at the writer's bitrate is roughly 2 MB/hour,
/// so this is not a capacity estimate — it is a floor that keeps a recording from being the thing
/// that fills the last of the disk, which is the one condition under which a write fails mid-call.
private let sgCallRecordingMinimumFreeBytes: Int64 = 120 * 1024 * 1024
/// Drain passes between sidecar refreshes: 50 × 200 ms = 10 s.
private let sgCallRecordingMetadataRefreshInterval = 50

// MARK: - One direction, brought into the domain the mix happens in

/// Downmixes one direction to mono and resamples it to 48 kHz. Stateful, so there is one per
/// direction and they are never shared.
///
/// This used to live inside the encoder, which was the right place while each direction had an
/// encoder of its own. It has to happen BEFORE the mix now, for two reasons. The taps report their
/// own sample rate and channel count — read from the callback arguments rather than assumed,
/// because a route change can move either — and two buffers can only be summed by index once both
/// are expressed in the same format. And mono 48 kHz is the only domain in which "the same number
/// of samples" means "the same amount of time", which is exactly what the mixer's `min` depends on.
private final class SGCallRecordingMonoNormalizer {
    /// Linear-resampler state, used whenever the tap reports something other than 48 kHz.
    private var resamplePhase: Double = 0.0
    private var previousSample: Double = 0.0
    private var hasPreviousSample: Bool = false

    /// Appends the normalized form of `samples` to `output`. Appends nothing for an empty or
    /// malformed buffer — which loses no time, because the ring only ever hands over samples it was
    /// given or silence it owes.
    func append(samples: UnsafePointer<Int16>, count: Int, sampleRate: Int, channelCount: Int, into output: inout [Int16]) {
        if count <= 0 || sampleRate <= 0 || channelCount <= 0 {
            return
        }
        let step = Double(sampleRate) / Double(sgCallRecordingOutputSampleRate)
        let frameCount = count / channelCount
        var index = 0
        while index < frameCount {
            var accumulator: Int = 0
            for channel in 0 ..< channelCount {
                accumulator += Int(samples[index * channelCount + channel])
            }
            let mono = Double(accumulator) / Double(channelCount)

            if !self.hasPreviousSample {
                self.hasPreviousSample = true
                self.previousSample = mono
                self.resamplePhase = 0.0
            }

            while self.resamplePhase < 1.0 {
                let interpolated = self.previousSample + (mono - self.previousSample) * self.resamplePhase
                output.append(Int16(max(-32768.0, min(32767.0, interpolated.rounded()))))
                self.resamplePhase += step
            }
            self.resamplePhase -= 1.0
            self.previousSample = mono

            index += 1
        }
    }
}

// MARK: - The encoder

/// Opens the file-backed data item the encoder writes into. Production always uses
/// `SGOggFileDataItem(existingFileAtPath:)`; the internal session initializer lets tests substitute
/// a subclass that fails real writes at a chosen page, so the write-failure paths run for real.
typealias SGCallRecordingDataItemOpener = (String) -> SGOggFileDataItem?

private final class SGCallRecordingStreamEncoder {
    let path: String
    private let writer: TGOggOpusWriter
    private let dataItem: SGOggFileDataItem
    private let pending: UnsafeMutablePointer<Int16>
    private var pendingCount: Int = 0

    private(set) var isBroken: Bool = false
    private(set) var didFinalize: Bool = false
    /// File length once the Opus header pages are written.
    private let headerByteCount: UInt
    /// File length after the last write the data item reported no error for. Every `appendData:` is
    /// one whole Ogg page and either lands completely or latches `hasError`, so everything up to
    /// here is intact pages.
    private var committedByteCount: UInt

    /// At least one complete AUDIO page is on disk, i.e. the file decodes to something.
    ///
    /// Not "the encoder accepted PCM": the writer holds up to a second of encoded packets in memory
    /// (`max_ogg_delay`, opusenc.m:129) and only the final flush writes them, so a recording whose
    /// final flush fails has accepted every sample and still holds nothing but the header.
    var hasAudioOnDisk: Bool {
        return self.committedByteCount > self.headerByteCount
    }

    init?(path: String, openDataItem: SGCallRecordingDataItemOpener) {
        guard let dataItem = openDataItem(path) else {
            return nil
        }
        let writer = TGOggOpusWriter()
        // `writeOggPage` returns the page's INTENDED length and never inspects what `appendData:`
        // managed to write (opusenc.m:59-69), so `begin` reports success even when not one header
        // byte reached the disk. The data item's own error latch is the only honest answer.
        guard writer.begin(with: dataItem), !dataItem.hasError else {
            dataItem.closeFile()
            return nil
        }
        self.path = path
        self.headerByteCount = dataItem.writtenByteCount
        self.committedByteCount = dataItem.writtenByteCount
        self.dataItem = dataItem
        self.writer = writer
        self.pending = UnsafeMutablePointer<Int16>.allocate(capacity: sgCallRecordingFrameSampleCount)
        self.pending.initialize(repeating: 0, count: sgCallRecordingFrameSampleCount)
    }

    deinit {
        self.pending.deinitialize(count: sgCallRecordingFrameSampleCount)
        self.pending.deallocate()
        self.dataItem.closeFile()
    }

    var duration: Double {
        return self.writer.encodedDuration()
    }

    /// Feeds already-mixed mono 48 kHz samples to the encoder in whole 20 ms frames. Downmixing and
    /// resampling happened upstream, per direction, in `SGCallRecordingMonoNormalizer`.
    func append(samples: UnsafePointer<Int16>, count: Int) {
        if self.isBroken || self.didFinalize {
            return
        }
        if count <= 0 {
            return
        }
        for index in 0 ..< count {
            self.push(sample: samples[index])
        }
    }

    private func push(sample: Int16) {
        self.pending[self.pendingCount] = sample
        self.pendingCount += 1
        if self.pendingCount == sgCallRecordingFrameSampleCount {
            self.writeFrame(UnsafeMutableRawPointer(self.pending).assumingMemoryBound(to: UInt8.self), byteCount: sgCallRecordingFrameSampleCount * 2)
            self.pendingCount = 0
        }
    }

    /// One `writeFrame`, and the honest answer to whether it reached the disk. The writer's own
    /// result only reports encoder failures — `writeOggPage` returns the page's intended length
    /// whatever happened to it (opusenc.m:59-69) — so the data item's latch is read after every
    /// call, including the zero-length one that flushes the tail.
    private func writeFrame(_ bytes: UnsafeMutablePointer<UInt8>?, byteCount: Int) {
        if self.isBroken {
            return
        }
        if !self.writer.writeFrame(bytes, frameByteCount: UInt(byteCount)) || self.dataItem.hasError {
            self.isBroken = true
            return
        }
        self.committedByteCount = self.dataItem.writtenByteCount
    }

    /// Writes the trailing partial frame (which is what sets Ogg's end-of-stream), or flushes the
    /// pages still held in memory when there is none, and closes the file. A failure here latches
    /// `isBroken` like any other: the held pages are the end of the call, so losing them is a
    /// truncation, and losing them with nothing before them leaves no audio at all. Safe to call
    /// more than once.
    func finalizeStream() {
        if self.didFinalize {
            return
        }
        self.didFinalize = true
        if self.pendingCount > 0 {
            self.writeFrame(UnsafeMutableRawPointer(self.pending).assumingMemoryBound(to: UInt8.self), byteCount: self.pendingCount * 2)
            self.pendingCount = 0
        } else {
            self.writeFrame(nil, byteCount: 0)
        }
        self.dataItem.closeFile()
    }
}

// MARK: - The session

public final class SGCallRecordingSession {
    private let queue: Queue
    private let peerTitle: String
    private let accountPeerId: Int64?
    /// The other party of the call (`PeerId.toInt64()`), recorded in the sidecar so privacy checks
    /// run against the peer that was actually recorded rather than a guessed title. nil for callers
    /// that do not know it; never invented.
    private let peerId: Int64?
    /// Production callers always use `sgCallRecordingAvailable`; the internal initializer lets
    /// tests exercise the pipeline without exposing a public availability override.
    private let isFeatureAvailable: Bool
    private let store: SGCallRecordingStore
    private let openDataItem: SGCallRecordingDataItemOpener

    private let statePromise: ValuePromise<SGCallRecordingState>
    public private(set) var stateValue: SGCallRecordingState {
        didSet {
            self.statePromise.set(self.stateValue)
        }
    }
    public var state: Signal<SGCallRecordingState, NoError> {
        return self.statePromise.get()
    }

    /// The id of the recording this session actually SAVED, set on the main queue immediately
    /// before the terminal state is published and never cleared.
    ///
    /// nil means nothing is on disk for this session: it never started, it wrote no bytes, or the
    /// user deleted it while the call was still running (in which case `stop()` honours that delete
    /// and returns before this is set). The caller uses it to hand the finished recording to
    /// `SGCallRecordingDelivery`; publishing it any earlier would mean offering to upload a file
    /// the encoder has not finished writing.
    public private(set) var savedRecordingId: String?

    /// The identifier of the recording currently being written, if any.
    private var recordingId: String?
    private var startTimestamp: Double?

    private let localRing = SGAudioRingBuffer(capacity: sgCallRecordingRingCapacity)
    private let remoteRing = SGAudioRingBuffer(capacity: sgCallRecordingRingCapacity)
    /// Read from the audio render thread; see SGAtomicFlag.
    private let microphoneMutedFlag = SGAtomicFlag(false)

    private var detachSink: (() -> Void)?
    private var timer: SwiftSignalKit.Timer?

    // Encoder-queue state.
    private var encoder: SGCallRecordingStreamEncoder?
    private let localNormalizer = SGCallRecordingMonoNormalizer()
    private let remoteNormalizer = SGCallRecordingMonoNormalizer()
    /// Normalized mono 48 kHz samples waiting for the other direction to catch up. Whatever the mix
    /// consumes is taken from the head of both, so at most one of these is ever non-empty after a
    /// drain, and never by more than `sgCallRecordingSkewToleranceSamples`.
    private var pendingLocal: [Int16] = []
    private var pendingRemote: [Int16] = []
    private var scratch: UnsafeMutablePointer<Int16>?
    /// Copies of the sidecar's fixed fields, so the periodic refresh runs entirely on the encoder
    /// queue without reaching back to main-queue state.
    private var queueRecordingId: String?
    private var queueStartTimestamp: Double = 0.0
    private var drainsSinceMetadataRefresh: Int = 0
    /// Latched once this session has asked the main queue to stop it on its own: a mid-call write
    /// failure (audit #109), or the live recording deleted / its account removed under it.
    private var didRequestStop: Bool = false

    public convenience init(peerTitle: String, accountPeerId: Int64?, peerId: Int64? = nil) {
        self.init(peerTitle: peerTitle, accountPeerId: accountPeerId, peerId: peerId, isFeatureAvailable: sgCallRecordingAvailable)
    }

    /// Internal test seam. Consent remains required; production callers use the public initializer.
    /// `encodeQueue` and `openDataItem` exist so tests can hold the encoder queue at an exact point
    /// and fail real file writes; production always takes the defaults.
    init(
        peerTitle: String,
        accountPeerId: Int64?,
        peerId: Int64?,
        isFeatureAvailable: Bool,
        encodeQueue: Queue = Queue(name: "SGCallRecordingEncode"),
        openDataItem: @escaping SGCallRecordingDataItemOpener = { SGOggFileDataItem(existingFileAtPath: $0) }
    ) {
        self.queue = encodeQueue
        self.openDataItem = openDataItem
        self.peerTitle = peerTitle
        self.accountPeerId = accountPeerId
        self.peerId = peerId
        self.isFeatureAvailable = isFeatureAvailable
        self.store = SGCallRecordingStore.shared
        self.statePromise = ValuePromise<SGCallRecordingState>(.idle, ignoreRepeated: true)
        self.stateValue = .idle
    }

    deinit {
        self.detachSink?()
        self.timer?.invalidate()
        let scratch = self.scratch
        let encoder = self.encoder
        let store = self.store
        let recordingId = self.recordingId
        self.queue.async {
            encoder?.finalizeStream()
            if let scratch = scratch {
                scratch.deinitialize(count: sgCallRecordingScratchCapacity)
                scratch.deallocate()
            }
            if let recordingId = recordingId, store.activeRecordingId == recordingId {
                store.activeRecordingId = nil
            }
        }
    }

    /// Never called by anything but an explicit user action. There is no code path in this app that
    /// starts a recording on its own, under any setting.
    ///
    /// Returns false and publishes a `.failed` state when a gate refuses.
    @discardableResult
    public func start(isMicrophoneMuted: Bool, attachSink: SGCallRecordingSinkAttach) -> Bool {
        assert(Thread.isMainThread)
        if self.stateValue.isActive {
            return false
        }
        guard self.isFeatureAvailable else {
            self.stateValue = .failed(.unavailable)
            return false
        }
        guard SGCallRecordingGate.consentAccepted else {
            self.stateValue = .failed(.noConsent)
            return false
        }
        // The account-removal fence. While an account's recordings are being purged (or the purge
        // ledger cannot be read, or the account was removed in this process and has not been seen
        // signed in again) nothing new may be recorded under it: a recording started here would
        // outlive the account it belongs to. Checked before any file exists or the tap is attached.
        // No account to attribute the recording to is refused the same way.
        guard let accountPeerId = self.accountPeerId, self.store.canRecord(accountPeerId: accountPeerId) else {
            self.stateValue = .failed(.accountCleanupPending)
            return false
        }
        guard self.store.ensureDirectory() != nil else {
            self.stateValue = .failed(.storage)
            return false
        }
        // A disk that fills mid-call is the one way a write fails after the user has watched the
        // indicator for an hour, so it is checked before anything is promised rather than
        // discovered afterwards.
        if let available = self.store.availableCapacity(), available < sgCallRecordingMinimumFreeBytes {
            self.stateValue = .failed(.noSpace)
            return false
        }
        // Clear out anything a previous crash left half-written before adding to the directory, and
        // take the chance — foreground, unlocked — to raise older files to `.complete`.
        self.store.sweepOrphans()
        self.store.tightenProtection()

        let id = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        guard let audioPath = self.store.mixedFilePath(id: id) else {
            self.stateValue = .failed(.storage)
            return false
        }
        // The file is created empty with `.completeUnlessOpen` applied AT creation; a file written
        // first and protected afterwards has already existed unprotected.
        guard self.store.createProtectedFile(atPath: audioPath) else {
            self.store.delete(id: id)
            self.stateValue = .failed(.storage)
            return false
        }

        // THE ENCODER IS BUILT HERE, NOT ON THE QUEUE. Constructing it asynchronously after
        // publishing `.recording` meant a failure to open the file, or to write the Ogg header, was
        // discovered only at hang-up: `drainImpl`'s `encoder?.append` silently swallowed every
        // buffer while the badge, the toast and the CallKit marker asserted for the whole call that
        // the conversation was being recorded.
        guard let encoder = SGCallRecordingStreamEncoder(path: audioPath, openDataItem: self.openDataItem) else {
            self.store.delete(id: id)
            self.stateValue = .failed(.storage)
            return false
        }

        // THE SIDECAR IS WRITTEN NOW, marked incomplete, and rewritten at stop().
        //
        // Written only at stop(), it was the single point whose failure made a whole recorded call
        // vanish: `list()` enumerates sidecars, so a perfectly good .ogg file with no sidecar is
        // invisible, undeletable from the UI and swept as an orphan the next time the user records.
        // A process killed mid-call (jetsam on a long video call, a crash, force-quit) produced
        // exactly that. Writing it up front means an interrupted recording is listed, playable and
        // deletable, and says on the row that it stops early.
        let startTimestamp = Date().timeIntervalSince1970
        guard self.store.writeMetadata(id: id, metadata: SGCallRecordingMetadata.mixed(
            startTimestamp: startTimestamp,
            duration: 0.0,
            peerTitle: self.peerTitle,
            accountPeerId: self.accountPeerId,
            peerId: self.peerId,
            isComplete: false
        )) else {
            self.store.delete(id: id)
            // The store refuses the FIRST sidecar for a fenced account too (a removal that started
            // after the check above). That is not a storage failure and must not say "free space".
            self.stateValue = self.store.canRecord(accountPeerId: accountPeerId) ? .failed(.storage) : .failed(.accountCleanupPending)
            return false
        }

        self.microphoneMutedFlag.value = isMicrophoneMuted
        self.localRing.reset()
        self.remoteRing.reset()

        // The sink captures the ring buffers and the mute flag, NOT self: the native side drops the
        // sink asynchronously, so it may still fire for a moment after `stop()`. Capturing the
        // buffers keeps them alive exactly as long as the sink is, and the sink itself does nothing
        // that could outlive them.
        let localRing = self.localRing
        let remoteRing = self.remoteRing
        let microphoneMutedFlag = self.microphoneMutedFlag
        guard let detach = attachSink({ direction, samples, sampleCount, channelCount, sampleRate in
            switch direction {
            case SGCallRecordingDirection.local.rawValue:
                // THE MUTE GATE, AND IT SURVIVES THE MIX UNCHANGED. Mute is applied DOWNSTREAM of
                // this tap — it reaches the outgoing audio channel, not the audio device — so the
                // microphone keeps delivering audio the far side never heard, and without this the
                // recording would contain it. Silence, not nothing: the remote direction keeps
                // filling from `NeedMorePlayData` throughout, so returning early here would excise
                // the muted interval from the local direction only, and every sample after it would
                // be mixed against the wrong moment of the other party for the rest of the call.
                if microphoneMutedFlag.value {
                    localRing.writeSilence(count: sampleCount, sampleRate: Int(sampleRate), channelCount: channelCount)
                    return
                }
                localRing.write(samples: samples, count: sampleCount, sampleRate: Int(sampleRate), channelCount: channelCount)
            case SGCallRecordingDirection.remote.rawValue:
                remoteRing.write(samples: samples, count: sampleCount, sampleRate: Int(sampleRate), channelCount: channelCount)
            default:
                break
            }
        }) else {
            self.store.delete(id: id)
            self.stateValue = .failed(.unavailable)
            return false
        }
        self.detachSink = detach

        self.recordingId = id
        self.startTimestamp = startTimestamp
        // Tells the store that this recording's files — the `.ogg` and its sidecar — are live: no
        // delete, per-row or "Delete All", may unlink them out from under the open descriptor, and
        // the protection-tightening pass must not re-class them to `.complete` while they are open.
        self.store.activeRecordingId = id

        self.encoder = encoder
        self.pendingLocal.removeAll(keepingCapacity: true)
        self.pendingRemote.removeAll(keepingCapacity: true)
        self.pendingLocal.reserveCapacity(sgCallRecordingSkewToleranceSamples + sgCallRecordingScratchCapacity)
        self.pendingRemote.reserveCapacity(sgCallRecordingSkewToleranceSamples + sgCallRecordingScratchCapacity)
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: sgCallRecordingScratchCapacity)
        scratch.initialize(repeating: 0, count: sgCallRecordingScratchCapacity)
        self.scratch = scratch
        self.queueRecordingId = id
        self.queueStartTimestamp = startTimestamp
        self.drainsSinceMetadataRefresh = 0
        self.didRequestStop = false

        let timer = SwiftSignalKit.Timer(timeout: 0.2, repeat: true, completion: { [weak self] in
            self?.drain()
        }, queue: self.queue)
        timer.start()
        self.timer = timer

        self.stateValue = .recording(startTimestamp: startTimestamp)
        // Zenlygram — `feature.used call_recording` for the recording's account (design 40 §10.2).
        SGAnalytics.featureUsed(.callRecording, accountPeerId: accountPeerId)
        return true
    }

    /// Mirrors the call's mute state into the tap. Called whenever `PresentationCall.isMuted`
    /// changes, and once at start.
    public func setIsMicrophoneMuted(_ value: Bool) {
        self.microphoneMutedFlag.value = value
    }

    /// Ends the recording and seals the file. Idempotent.
    public func stop() {
        assert(Thread.isMainThread)
        guard case .recording = self.stateValue else {
            return
        }
        guard let id = self.recordingId, let startTimestamp = self.startTimestamp else {
            return
        }
        self.stateValue = .finishing

        // NOTHING THE TAP DELIVERS FROM HERE ON IS PART OF THE RECORDING. The native detach is
        // asynchronous, so the tap keeps firing until the audio device drops the sink, and the final
        // drain below runs later still on the encoder queue: without this, audio from after the user
        // pressed Stop would be read into the file. Closing takes each ring's lock, so it also waits
        // out a write already in progress — everything the rings hold once this returns was
        // delivered before Stop. The same gate covers a stop this session requested on its own.
        self.localRing.close()
        self.remoteRing.close()
        self.detachSink?()
        self.detachSink = nil
        self.timer?.invalidate()
        self.timer = nil

        self.recordingId = nil
        self.startTimestamp = nil

        let store = self.store
        let peerTitle = self.peerTitle
        let accountPeerId = self.accountPeerId
        let peerId = self.peerId
        // Captured STRONGLY on purpose: this block finishes the Ogg stream, seals the file and
        // writes the sidecar. With a weak capture, a session released while it was queued would bail
        // out here and leave a headerless .ogg file behind that nothing ever lists or cleans up.
        self.queue.async {
            // One last pass so the tail of the call is not thrown away. `isFinal` drops the skew
            // tolerance to nothing: no more audio is coming, so anything one side is still holding
            // is written against silence on the other rather than discarded.
            self.drainImpl(isFinal: true)

            self.encoder?.finalizeStream()

            let duration = self.encoder?.duration ?? 0.0
            // KEEP THE BYTES. `isBroken` latches on the FIRST failed write — one ENOSPC at minute 59
            // of an hour-long call — and every Ogg page flushed before that is a complete, playable
            // stream that libopusfile reads up to the last intact page. Treating the latch as "this
            // file is worthless" deleted 59 good minutes of a conversation that cannot be recorded
            // again. It decides whether to WARN, not whether to keep.
            let wroteAnything = self.encoder?.hasAudioOnDisk ?? false
            let wasTruncated = self.encoder?.isBroken ?? false
            let audioPath = self.encoder?.path

            if let path = audioPath {
                if wroteAnything {
                    store.sealFile(atPath: path)
                } else {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }

            self.encoder = nil
            self.pendingLocal.removeAll(keepingCapacity: false)
            self.pendingRemote.removeAll(keepingCapacity: false)
            self.queueRecordingId = nil
            if let scratch = self.scratch {
                scratch.deinitialize(count: sgCallRecordingScratchCapacity)
                scratch.deallocate()
                self.scratch = nil
            }

            // WHAT HAS TO BE TRUE OF THE ORDER BELOW. A delete of this recording (per-row Delete,
            // "Delete All", an account removal, a wipe) can land at any instant. While the store
            // still believes the recording is live, such a delete only tombstones it (durably) and
            // flags it — it cannot unlink files a session holds. Once the live marker is down, a
            // delete purges immediately and leaves NO tombstone. So every write that could recreate
            // a file — the final sidecar, with the other party's name in it — has to happen WHILE
            // the recording is still live, where `writeMetadata` refuses a tombstoned id; the marker
            // goes down after that; and only then is the outcome decided, from a fresh look at the
            // tombstone, the account fence and the file itself. Writing the sidecar after clearing
            // the marker (as this used to) let a delete landing in between purge everything and the
            // write then resurrect a sidecar naming the other party.
            let isOwnerFenced: () -> Bool = {
                guard let accountPeerId = accountPeerId else {
                    return false
                }
                return store.isRecordingFenced(accountPeerId: accountPeerId)
            }

            // 1. Still live: already deleted (or its account removed)?
            var deleted = store.consumeDeleteWhenFinished(id: id) || isOwnerFenced()

            // 2. Still live: the final sidecar. Refused (as a no-op) for a tombstoned id.
            var metadataWritten = false
            if !deleted && wroteAnything {
                metadataWritten = store.writeMetadata(id: id, metadata: SGCallRecordingMetadata.mixed(
                    startTimestamp: startTimestamp,
                    duration: duration,
                    peerTitle: peerTitle,
                    accountPeerId: accountPeerId,
                    peerId: peerId,
                    isComplete: !wasTruncated
                ))
            }

            // 3. The live marker goes down. The stream is finalized and the descriptor closed.
            if store.activeRecordingId == id {
                store.activeRecordingId = nil
            }

            // 4. Re-check now that nothing can be added to the in-memory flag any more: a delete
            // that landed during 1–2 left a tombstone on disk (and clearing the marker dropped the
            // flag, which is why the tombstone is what is read here).
            if !deleted && (store.isDeleted(id: id) || isOwnerFenced()) {
                deleted = true
            }

            if deleted || !wroteAnything {
                // Not live any more, so this unlinks every file and the tombstone.
                store.delete(id: id)
            }

            let wasDeleted = deleted
            let sidecarWritten = metadataWritten
            Queue.mainQueue().async { [weak self = self] in
                guard let self else {
                    return
                }
                if wasDeleted {
                    // The user (or an account removal) asked for this to be gone. Nothing saved,
                    // nothing offered for upload.
                    self.stateValue = .idle
                    return
                }
                if !wroteAnything {
                    self.stateValue = .failed(.storage)
                    return
                }
                // 5. A delete after step 3 purges at once with no tombstone. Never hand on an id
                // whose audio is already gone: a stat, valid while the device is locked.
                let stillOnDisk = !store.isDeleted(id: id) && audioPath.map { FileManager.default.fileExists(atPath: $0) } == true
                if !stillOnDisk {
                    self.stateValue = .idle
                    return
                }
                // Set BEFORE the state is published: the subscriber reacts to the state on this
                // same runloop turn, and it is the recording's id that tells it what to upload.
                self.savedRecordingId = id
                if wasTruncated || !sidecarWritten {
                    // Either the audio stops early, or the rewrite failed and the sidecar still
                    // carries the start-time record — which says "incomplete" and a stale duration.
                    // Both mean the same thing to the user: what was saved stops before the call
                    // did, and they have to be told, because the indicator promised otherwise.
                    self.stateValue = .finished(.truncated)
                } else {
                    self.stateValue = .idle
                }
            }
        }
    }

    private func drain() {
        self.drainImpl(isFinal: false)
        // AUDIT #109 — A WRITE THAT FAILS MID-CALL ENDS THE RECORDING NOW, not at hang-up. The
        // encoder latches `isBroken` on the first failed page and swallows everything after it, so
        // without this the badge, the call bar and the CallKit marker would keep saying the call is
        // being recorded while nothing is. `stop()` is the existing, idempotent end: it detaches the
        // tap, keeps every byte already flushed and publishes `.finished(.truncated)` (or
        // `.failed(.storage)` if nothing was written), which clears every indicator and alerts.
        //
        // THE SAME FOR A RECORDING DELETED UNDER IT. A per-row Delete, "Delete All", an account
        // removal or a wipe tombstones the live recording (the store cannot unlink open files) and
        // fences its account. Capture must end then, not at hang-up: the user asked for this audio
        // to be gone, so this drain (scheduled every 200 ms; not a hard real-time bound — a
        // stalled queue or main thread delays it) asks for `stop()`, which detaches the tap, clears
        // REC and honours the tombstone by saving nothing. A stat and a lock-guarded in-memory set
        // read on this queue, with no store lock held across I/O — nothing to deadlock on. The
        // in-memory fence covers removals in THIS process; a ledger that turns unreadable or
        // corrupt mid-call only blocks NEW starts (`canRecord`), it does not end a live recording.
        if !self.didRequestStop, let id = self.queueRecordingId {
            let isBroken = self.encoder?.isBroken ?? false
            let isDeleted = self.store.isDeleted(id: id)
            let isFenced = self.accountPeerId.map { self.store.isRecordingFenced(accountPeerId: $0) } ?? false
            if isBroken || isDeleted || isFenced {
                self.didRequestStop = true
                Queue.mainQueue().async { [weak self] in
                    self?.stop()
                }
                return
            }
        }
        // Refresh the sidecar every ten seconds. It keeps the duration roughly right for a
        // recording the process never gets to finish, and it refreshes the mtime so the orphan
        // sweep cannot mistake a very long call for abandoned wreckage.
        self.drainsSinceMetadataRefresh += 1
        if self.drainsSinceMetadataRefresh >= sgCallRecordingMetadataRefreshInterval {
            self.drainsSinceMetadataRefresh = 0
            guard let id = self.queueRecordingId else {
                return
            }
            self.store.writeMetadata(id: id, metadata: SGCallRecordingMetadata.mixed(
                startTimestamp: self.queueStartTimestamp,
                duration: self.encoder?.duration ?? 0.0,
                peerTitle: self.peerTitle,
                accountPeerId: self.accountPeerId,
                peerId: self.peerId,
                isComplete: false
            ))
        }
    }

    /// Encoder queue only. Takes the same amount of time off both rings, sums it, and hands the
    /// result to the one encoder.
    ///
    /// `isFinal` is the pass `stop()` runs once the tap is detached. Nothing more is coming, so the
    /// skew tolerance drops to zero and whatever one side is still holding is written out against
    /// silence rather than discarded with the session.
    private func drainImpl(isFinal: Bool) {
        guard let scratch = self.scratch else {
            return
        }
        self.normalize(self.localRing, with: self.localNormalizer, into: &self.pendingLocal, scratch: scratch)
        self.normalize(self.remoteRing, with: self.remoteNormalizer, into: &self.pendingRemote, scratch: scratch)

        // THE STARVATION RULE. Consuming `min(local, remote)` is what keeps the two from slipping
        // apart, and it is also what makes a one-sided call encode nothing at all: `min` is zero
        // for as long as one tap is quiet, and the recording stalls while the indicator says it is
        // running. So the wait is bounded. Past `sgCallRecordingSkewToleranceSamples` of one-sided
        // data the short side is padded — at its HEAD, because the backlog on the long side covers
        // the interval the short side delivered nothing for — and the mix carries on. See that
        // constant for why the bound is where it is.
        let skew = self.pendingLocal.count - self.pendingRemote.count
        let tolerance = isFinal ? 1 : sgCallRecordingSkewToleranceSamples
        if skew >= tolerance {
            self.pendingRemote.insert(contentsOf: repeatElement(Int16(0), count: skew), at: 0)
        } else if -skew >= tolerance {
            self.pendingLocal.insert(contentsOf: repeatElement(Int16(0), count: -skew), at: 0)
        }

        let count = min(self.pendingLocal.count, self.pendingRemote.count)
        if count <= 0 {
            return
        }
        var offset = 0
        while offset < count {
            let chunk = min(count - offset, sgCallRecordingScratchCapacity)
            for index in 0 ..< chunk {
                // SUM AND CLAMP — deliberately NOT `(a + b) / 2`.
                //
                // Halving both sides guarantees no clipping by making every recording 6 dB quiet,
                // which pays a certain cost on every single call to insure against a peak that
                // needs both parties loud at the same instant — i.e. against people talking over
                // each other, which is a small part of a conversation. A recording the user has to
                // turn all the way up, in an app whose volume they do not control, is a worse
                // artefact than an occasional clipped syllable. Int32 first so the sum cannot wrap;
                // the clamp is the only place a sample is ever altered.
                let sum = Int32(self.pendingLocal[offset + index]) + Int32(self.pendingRemote[offset + index])
                scratch[index] = Int16(max(Int32(Int16.min), min(Int32(Int16.max), sum)))
            }
            self.encoder?.append(samples: scratch, count: chunk)
            offset += chunk
        }
        // Whatever is left over stays for the next drain, so the two never slip apart.
        self.pendingLocal.removeFirst(count)
        self.pendingRemote.removeFirst(count)
    }

    /// Empties one ring into its direction's pending buffer, in mono 48 kHz.
    private func normalize(_ ring: SGAudioRingBuffer, with normalizer: SGCallRecordingMonoNormalizer, into output: inout [Int16], scratch: UnsafeMutablePointer<Int16>) {
        while true {
            let (count, sampleRate, channelCount) = ring.read(into: scratch, maxCount: sgCallRecordingScratchCapacity)
            if count == 0 {
                return
            }
            normalizer.append(samples: scratch, count: count, sampleRate: sampleRate, channelCount: channelCount, into: &output)
            if count < sgCallRecordingScratchCapacity {
                return
            }
        }
    }
}
