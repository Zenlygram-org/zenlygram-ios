import XCTest

import OpusBinding
import SGCallRecordingObjC
import SwiftSignalKit
@testable import SGCallRecording

/// Zenlygram — deterministic synthetic-PCM tests of the recorder pipeline: availability and consent
/// gates → tap attach → ring buffers → per-direction normalisation → mute gate → mix → Ogg/Opus file
/// → sidecar (with the recorded account and peer) → detach. The written file is decoded again to
/// check what was actually captured.
///
/// The "tap" is a closure these tests drive by hand with generated sine waves. This is NOT a
/// two-party call: it proves nothing about the native audio-device tap, CallKit, the call screen or
/// the audio session — those need a real call on a device.
///
/// The pipeline uses the internal initializer through `@testable` so it runs with either shipping
/// gate value. The public initializer is checked separately.
final class SGCallRecordingSessionTests: XCTestCase {
    private static let accountPeerId: Int64 = 4_200_000_042
    private static let peerId: Int64 = 4_200_000_077
    private static let peerTitle = "Synthetic PCM"
    private static let toneAmplitude: Double = 8_000.0
    /// Decoded RMS at or below this is silence; a tone at `toneAmplitude` decodes far above it.
    private static let silenceRMS: Double = 150.0
    private static let toneRMS: Double = 2_000.0

    private var savedConsent = false
    private var createdRecordingIds: [String] = []

    override func setUp() {
        super.setUp()
        self.savedConsent = SGCallRecordingGate.consentAccepted
    }

    override func tearDown() {
        for id in self.createdRecordingIds {
            SGCallRecordingStore.shared.delete(id: id)
        }
        self.createdRecordingIds = []
        SGCallRecordingGate.consentAccepted = self.savedConsent
        super.tearDown()
    }

    // MARK: - Gates

    func testProductionInitializerFollowsTheShippingGate() {
        SGCallRecordingGate.consentAccepted = false
        let idsBefore = self.recordingIds()

        let session = SGCallRecordingSession(peerTitle: SGCallRecordingSessionTests.peerTitle, accountPeerId: SGCallRecordingSessionTests.accountPeerId)
        var attachCount = 0
        let started = session.start(isMicrophoneMuted: false, attachSink: { _ in
            attachCount += 1
            return {}
        })

        XCTAssertFalse(started)
        // The availability gate is checked before consent, so which refusal comes back says which
        // gate the public initializer actually read.
        XCTAssertEqual(session.stateValue, sgCallRecordingAvailable ? .failed(.noConsent) : .failed(.unavailable))
        XCTAssertEqual(attachCount, 0)
        XCTAssertEqual(self.recordingIds(), idsBefore)
    }

    /// THE SHIPPING ENTRY, END TO END. Everything else here drives the pipeline through the internal
    /// availability override; this case goes through the PUBLIC initializer only — the one
    /// `PresentationCall.startRecording()` uses — so it passes only in a build whose compile-time gate
    /// is on. With the gate off it is expected to fail at `start` with `.failed(.unavailable)`.
    ///
    /// Explicit consent, an account that reconciliation has reported signed in (fence lifted, no
    /// pending cleanup), the call's peer, synthetic PCM on both legs with a muted tail, stop, and the
    /// decoded artefact. Still NOT a two-party call: no native tap, CallKit or audio session.
    func testProductionEntryRecordsAConsentedCallEndToEnd() throws {
        SGCallRecordingGate.consentAccepted = true
        let accountPeerId: Int64 = 4_200_000_503
        // What launch reconciliation does for a signed-in account, minus its deletions: lift this
        // process's fence. The precondition then says whether the store would let it record at all.
        SGCallRecordingStore.shared.unfenceRecording(signedInAccountPeerIds: [accountPeerId])
        XCTAssertTrue(SGCallRecordingStore.shared.canRecord(accountPeerId: accountPeerId), "precondition: a signed-in account with no pending cleanup may record")

        let session = SGCallRecordingSession(peerTitle: SGCallRecordingSessionTests.peerTitle, accountPeerId: accountPeerId, peerId: SGCallRecordingSessionTests.peerId)
        var sink: SGCallRecordingAudioSink?
        var attachCount = 0
        var detachCount = 0
        let started = session.start(isMicrophoneMuted: false, attachSink: { attached in
            attachCount += 1
            sink = attached
            return {
                detachCount += 1
            }
        })
        if let id = SGCallRecordingStore.shared.activeRecordingId {
            self.createdRecordingIds.append(id)
        }
        XCTAssertTrue(started, "the public entry must start a consented recording; got \(session.stateValue)")
        guard case .recording = session.stateValue else {
            return XCTFail("expected .recording through the public initializer, got \(session.stateValue)")
        }
        XCTAssertEqual(attachCount, 1)
        let tap = try XCTUnwrap(sink)
        let liveId = try XCTUnwrap(SGCallRecordingStore.shared.activeRecordingId)

        // Half a second of both voices, then the user mutes for the second half: the microphone
        // keeps delivering speech, the other party has gone quiet.
        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        let quietRemote = SGSyntheticPCM(frequency: 660.0, sampleRate: 48_000, channelCount: 1, amplitude: 0.0)
        for chunk in 0 ..< 100 {
            if chunk == 50 {
                session.setIsMicrophoneMuted(true)
            }
            local.feedTenMilliseconds(into: tap, direction: .local)
            if chunk < 50 {
                remote.feedTenMilliseconds(into: tap, direction: .remote)
            } else {
                quietRemote.feedTenMilliseconds(into: tap, direction: .remote)
            }
        }

        session.stop()
        XCTAssertEqual(detachCount, 1, "stop detaches the native tap exactly once")
        XCTAssertEqual(self.waitForTerminalState(of: session), .idle, "a clean stop is a clean save")

        let recordingId = try XCTUnwrap(session.savedRecordingId, "the finished recording is handed on for (opt-in) delivery")
        XCTAssertEqual(recordingId, liveId)
        XCTAssertFalse(SGCallRecordingStore.shared.isActive(id: recordingId))
        XCTAssertTrue(self.recordingIds().contains(recordingId), "the recording is listed")

        let item = try XCTUnwrap(SGCallRecordingStore.shared.item(id: recordingId))
        XCTAssertEqual(item.audioPaths.count, 1)
        XCTAssertTrue(item.isComplete)
        XCTAssertEqual(item.accountPeerId, accountPeerId, "the recording belongs to the account that made it")
        XCTAssertEqual(item.peerId, SGCallRecordingSessionTests.peerId)
        XCTAssertEqual(item.peerTitle, SGCallRecordingSessionTests.peerTitle)
        XCTAssertEqual(item.duration, 1.0, accuracy: 0.1)
        let audioURL = URL(fileURLWithPath: item.audioPaths[0])
        XCTAssertEqual(try audioURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, "recordings never ride a backup")

        let decoded = try XCTUnwrap(sgDecodeOggOpus(path: item.audioPaths[0]))
        XCTAssertEqual(Double(decoded.count) / 48_000.0, 1.0, accuracy: 0.1)
        XCTAssertGreaterThan(sgRMS(decoded, from: 0.1, to: 0.4), SGCallRecordingSessionTests.toneRMS, "both voices are in the mix")
        XCTAssertLessThan(sgRMS(decoded, from: 0.6, to: 0.9), SGCallRecordingSessionTests.silenceRMS, "speech while muted is not recorded")
    }

    func testUnavailableFeatureRefusesEvenWithConsent() {
        SGCallRecordingGate.consentAccepted = true
        let idsBefore = self.recordingIds()

        let session = self.makeSession(isFeatureAvailable: false)
        var attachCount = 0
        let started = session.start(isMicrophoneMuted: false, attachSink: { _ in
            attachCount += 1
            return {}
        })

        XCTAssertFalse(started)
        XCTAssertEqual(session.stateValue, .failed(.unavailable))
        XCTAssertEqual(attachCount, 0, "a build with the feature off must never tap audio")
        XCTAssertNil(session.savedRecordingId)
        XCTAssertEqual(self.recordingIds(), idsBefore, "a refused start must leave nothing on disk")
    }

    func testRefusesWithoutConsentAndNeverAttachesTheTap() {
        SGCallRecordingGate.consentAccepted = false
        let idsBefore = self.recordingIds()

        let session = self.makeSession(isFeatureAvailable: true)
        var attachCount = 0
        let started = session.start(isMicrophoneMuted: false, attachSink: { _ in
            attachCount += 1
            return {}
        })

        XCTAssertFalse(started)
        XCTAssertEqual(session.stateValue, .failed(.noConsent))
        XCTAssertEqual(attachCount, 0, "no sample may be tapped before consent")
        XCTAssertNil(session.savedRecordingId)
        XCTAssertEqual(self.recordingIds(), idsBefore, "a refused start must leave nothing on disk")
    }

    // MARK: - Pipeline

    func testSyntheticTwoDirectionPCMProducesOneSealedRecording() throws {
        SGCallRecordingGate.consentAccepted = true

        let session = self.makeSession(isFeatureAvailable: true)
        var sink: SGCallRecordingAudioSink?
        var detachCount = 0
        let started = session.start(isMicrophoneMuted: false, attachSink: { attached in
            sink = attached
            return {
                detachCount += 1
            }
        })
        XCTAssertTrue(started)
        guard case .recording = session.stateValue, let tap = sink else {
            XCTFail("expected a recording session with an attached tap, got \(session.stateValue)")
            return
        }

        // A second start on a live session is refused and does not attach a second tap.
        XCTAssertFalse(session.start(isMicrophoneMuted: false, attachSink: { _ in
            XCTFail("second tap attached")
            return {}
        }))

        // One second per direction, in 10 ms chunks, in the formats the device can report: the
        // microphone as 48 kHz mono, the playout as 16 kHz stereo (exercises downmix + resample).
        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 16_000, channelCount: 2, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        for _ in 0 ..< 100 {
            local.feedTenMilliseconds(into: tap, direction: .local)
            remote.feedTenMilliseconds(into: tap, direction: .remote)
        }

        session.stop()
        session.stop()
        XCTAssertEqual(detachCount, 1, "stop must detach the tap exactly once")
        XCTAssertEqual(session.stateValue, .finishing, "the indicator stays up until the file is sealed")

        // The native detach is asynchronous: the tap may still fire for a moment after stop().
        // That must be harmless rather than a crash or a write into the sealed file.
        local.feedTenMilliseconds(into: tap, direction: .local)
        remote.feedTenMilliseconds(into: tap, direction: .remote)

        let terminal = self.waitForTerminalState(of: session)
        XCTAssertEqual(terminal, .idle)

        let recordingId = try XCTUnwrap(session.savedRecordingId)
        self.createdRecordingIds.append(recordingId)
        XCTAssertFalse(SGCallRecordingStore.shared.isActive(id: recordingId))

        let item = try XCTUnwrap(SGCallRecordingStore.shared.item(id: recordingId))
        XCTAssertEqual(item.audioPaths.count, 1, "both directions are mixed into one file")
        XCTAssertTrue(item.isComplete)
        XCTAssertEqual(item.accountPeerId, SGCallRecordingSessionTests.accountPeerId)
        XCTAssertEqual(item.peerId, SGCallRecordingSessionTests.peerId, "the recorded peer is what privacy checks run against")
        XCTAssertEqual(item.peerTitle, SGCallRecordingSessionTests.peerTitle)
        XCTAssertEqual(item.duration, 1.0, accuracy: 0.1)

        let data = try Data(contentsOf: URL(fileURLWithPath: item.audioPaths[0]))
        XCTAssertEqual(Array(data.prefix(4)), Array("OggS".utf8), "the recording is an Ogg stream")
        XCTAssertEqual(item.totalSize, Int64(data.count))

        let decoded = try XCTUnwrap(sgDecodeOggOpus(path: item.audioPaths[0]))
        XCTAssertEqual(Double(decoded.count) / 48_000.0, 1.0, accuracy: 0.1)
        XCTAssertGreaterThan(sgRMS(decoded, from: 0.1, to: 0.9), SGCallRecordingSessionTests.toneRMS, "both voices are in the mix")

        // A decoder read may return only one 20 ms Opus packet. The playback reader must fill
        // the caller's requested chunk, or its queued audio runs dry between callbacks.
        let playbackReader = try XCTUnwrap(SGCallRecordingMixReader(paths: item.audioPaths))
        let requestedFrames = 24_000
        var chunk = [Float](repeating: 0.0, count: requestedFrames)
        var decodedOffset = 0
        let maximumReads = (decoded.count + requestedFrames - 1) / requestedFrames + 1
        for _ in 0 ..< maximumReads {
            let produced = chunk.withUnsafeMutableBufferPointer {
                playbackReader.read(into: $0.baseAddress!, maxFrames: $0.count)
            }
            let expectedFrames = min(requestedFrames, decoded.count - decodedOffset)
            XCTAssertEqual(produced, expectedFrames)
            guard produced > 0 else { break }
            guard produced <= expectedFrames else {
                return XCTFail("playback decoded more samples than the recorded stream")
            }
            var maximumError: Float = 0.0
            for index in 0 ..< produced {
                maximumError = max(maximumError, abs(chunk[index] - Float(decoded[decodedOffset + index]) / 32768.0))
            }
            XCTAssertEqual(maximumError, 0.0, accuracy: 0.00001)
            decodedOffset += produced
        }
        XCTAssertEqual(decodedOffset, decoded.count, "playback preserves the final partial chunk")
        XCTAssertTrue(playbackReader.isFinished)
    }

    /// The privacy invariant behind the mute gate: mute is applied downstream of the tap, so the
    /// microphone keeps delivering audio the other party never hears. None of it may be recorded,
    /// and the muted interval must stay on the clock (silence, not a cut).
    func testMuteGateRecordsSilenceForTheMutedInterval() throws {
        SGCallRecordingGate.consentAccepted = true

        let session = self.makeSession(isFeatureAvailable: true)
        var sink: SGCallRecordingAudioSink?
        XCTAssertTrue(session.start(isMicrophoneMuted: false, attachSink: { attached in
            sink = attached
            return {}
        }))
        let tap = try XCTUnwrap(sink)

        // The other party is silent throughout; only the microphone carries a tone.
        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 48_000, channelCount: 1, amplitude: 0.0)
        for chunk in 0 ..< 100 {
            if chunk == 50 {
                session.setIsMicrophoneMuted(true)
            }
            local.feedTenMilliseconds(into: tap, direction: .local)
            remote.feedTenMilliseconds(into: tap, direction: .remote)
        }
        session.stop()
        XCTAssertEqual(self.waitForTerminalState(of: session), .idle)

        let recordingId = try XCTUnwrap(session.savedRecordingId)
        self.createdRecordingIds.append(recordingId)
        let item = try XCTUnwrap(SGCallRecordingStore.shared.item(id: recordingId))
        let decoded = try XCTUnwrap(sgDecodeOggOpus(path: item.audioPaths[0]))

        XCTAssertEqual(Double(decoded.count) / 48_000.0, 1.0, accuracy: 0.1, "the muted half stays on the clock")
        XCTAssertGreaterThan(sgRMS(decoded, from: 0.1, to: 0.4), SGCallRecordingSessionTests.toneRMS, "unmuted speech is recorded")
        XCTAssertLessThan(sgRMS(decoded, from: 0.6, to: 0.9), SGCallRecordingSessionTests.silenceRMS, "speech while muted must not be recorded")
    }

    func testStartingMutedRecordsNoMicrophone() throws {
        SGCallRecordingGate.consentAccepted = true

        let session = self.makeSession(isFeatureAvailable: true)
        var sink: SGCallRecordingAudioSink?
        XCTAssertTrue(session.start(isMicrophoneMuted: true, attachSink: { attached in
            sink = attached
            return {}
        }))
        let tap = try XCTUnwrap(sink)

        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 48_000, channelCount: 1, amplitude: 0.0)
        for _ in 0 ..< 50 {
            local.feedTenMilliseconds(into: tap, direction: .local)
            remote.feedTenMilliseconds(into: tap, direction: .remote)
        }
        session.stop()
        XCTAssertEqual(self.waitForTerminalState(of: session), .idle)

        let recordingId = try XCTUnwrap(session.savedRecordingId)
        self.createdRecordingIds.append(recordingId)
        let item = try XCTUnwrap(SGCallRecordingStore.shared.item(id: recordingId))
        let decoded = try XCTUnwrap(sgDecodeOggOpus(path: item.audioPaths[0]))
        XCTAssertLessThan(sgRMS(decoded, from: 0.05, to: 0.45), SGCallRecordingSessionTests.silenceRMS)
    }

    // MARK: - Early stop, one leg, relative timeline

    /// Stop before the other party ever produced audio: the final drain writes the leg that exists
    /// against silence instead of discarding it, and the file is sealed before success is claimed.
    func testEarlyStopWithOneLegKeepsThatLeg() throws {
        SGCallRecordingGate.consentAccepted = true
        let (session, tap, _) = try self.startRecording()

        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        for _ in 0 ..< 50 {
            local.feedTenMilliseconds(into: tap, direction: .local)
        }
        session.stop()
        XCTAssertEqual(session.stateValue, .finishing, "no success before the stream is finalized")
        XCTAssertNil(session.savedRecordingId)
        XCTAssertEqual(self.waitForTerminalState(of: session), .idle)

        let recordingId = try XCTUnwrap(session.savedRecordingId)
        self.createdRecordingIds.append(recordingId)
        let item = try XCTUnwrap(SGCallRecordingStore.shared.item(id: recordingId))
        XCTAssertTrue(item.isComplete)
        let decoded = try XCTUnwrap(sgDecodeOggOpus(path: item.audioPaths[0]))
        XCTAssertEqual(Double(decoded.count) / 48_000.0, 0.5, accuracy: 0.06)
        XCTAssertGreaterThan(sgRMS(decoded, from: 0.05, to: 0.45), SGCallRecordingSessionTests.toneRMS)
    }

    /// Stopped with nothing captured: no file, no saved id, and the outcome is a failure, never a
    /// success for an empty recording.
    func testStopWithNothingCapturedIsNotASuccess() throws {
        SGCallRecordingGate.consentAccepted = true
        let idsBefore = self.recordingIds()
        let (session, _, _) = try self.startRecording()
        session.stop()
        XCTAssertEqual(self.waitForTerminalState(of: session), .failed(.storage))
        XCTAssertNil(session.savedRecordingId)
        XCTAssertEqual(self.recordingIds(), idsBefore)
    }

    /// The playout leg at 16 kHz stereo is resampled and downmixed onto the 48 kHz mono timeline:
    /// fed in lockstep with the microphone, it must cover the whole second — not be compressed into
    /// part of it (too few samples) or stretched past it (too many).
    func testResampledLegStaysOnTheSharedTimeline() throws {
        SGCallRecordingGate.consentAccepted = true
        let (session, tap, _) = try self.startRecording()

        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: 0.0)
        let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 16_000, channelCount: 2, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        for _ in 0 ..< 100 {
            local.feedTenMilliseconds(into: tap, direction: .local)
            remote.feedTenMilliseconds(into: tap, direction: .remote)
        }
        session.stop()
        XCTAssertEqual(self.waitForTerminalState(of: session), .idle)

        let recordingId = try XCTUnwrap(session.savedRecordingId)
        self.createdRecordingIds.append(recordingId)
        let item = try XCTUnwrap(SGCallRecordingStore.shared.item(id: recordingId))
        let decoded = try XCTUnwrap(sgDecodeOggOpus(path: item.audioPaths[0]))
        XCTAssertEqual(Double(decoded.count) / 48_000.0, 1.0, accuracy: 0.06)
        XCTAssertGreaterThan(sgRMS(decoded, from: 0.05, to: 0.45), SGCallRecordingSessionTests.toneRMS, "the playout leg starts at the start")
        XCTAssertGreaterThan(sgRMS(decoded, from: 0.55, to: 0.95), SGCallRecordingSessionTests.toneRMS, "and runs to the end")
    }

    // MARK: - Final write failure, and audio after Stop

    /// THE FINAL FLUSH FAILS BEFORE ANY AUDIO PAGE REACHED THE DISK. The Ogg writer holds up to a
    /// second of encoded packets in memory before it emits a page, so every audio byte of this short
    /// recording is written by `finalizeStream`. When that write fails the file holds only the Opus
    /// header — it decodes to nothing — and it must not be saved, listed, or offered for upload as a
    /// recording, clean or truncated.
    ///
    /// Both tails of the final flush: a whole number of 20 ms frames (the zero-length EOS flush) and
    /// a trailing partial frame.
    func testFinalFlushFailureWithOnlyTheHeaderOnDiskSavesNothing() throws {
        SGCallRecordingGate.consentAccepted = true
        for chunkCount in [50, 51] {
            let idsBefore = self.recordingIds()
            let (session, tap, detachCount) = try self.startRecording(openDataItem: { path in
                SGFailingOggFileDataItem(path: path, audioPageLimit: 0)
            })
            let liveId = try XCTUnwrap(SGCallRecordingStore.shared.activeRecordingId)

            let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
            let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
            for _ in 0 ..< chunkCount {
                local.feedTenMilliseconds(into: tap, direction: .local)
                remote.feedTenMilliseconds(into: tap, direction: .remote)
            }
            session.stop()

            XCTAssertEqual(self.waitForTerminalState(of: session), .failed(.storage), "\(chunkCount) chunks: a header-only file is not a saved recording")
            XCTAssertEqual(detachCount(), 1)
            XCTAssertNil(session.savedRecordingId, "\(chunkCount) chunks: nothing playable is handed to delivery")
            XCTAssertNil(SGCallRecordingStore.shared.item(id: liveId))
            XCTAssertFalse(self.anyFileExists(id: liveId), "\(chunkCount) chunks: the header-only file and its sidecar are removed")
            XCTAssertEqual(self.recordingIds(), idsBefore)
        }
    }

    /// THE FINAL FLUSH FAILS AFTER A PLAYABLE PREFIX REACHED THE DISK. The first second went out as
    /// a complete page mid-call; the last half second is lost when the final flush fails. What is on
    /// disk is kept — it is a real, decodable part of the conversation — but it must be reported as
    /// truncated and marked incomplete, never as a clean save of the whole call.
    func testFinalFlushFailureAfterAPlayablePrefixIsReportedTruncated() throws {
        SGCallRecordingGate.consentAccepted = true
        let (session, tap, _) = try self.startRecording(openDataItem: { path in
            SGFailingOggFileDataItem(path: path, audioPageLimit: 1)
        })

        // 1.5 s in whole 20 ms frames: one page at ~1 s, the rest held for the final flush.
        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        for _ in 0 ..< 150 {
            local.feedTenMilliseconds(into: tap, direction: .local)
            remote.feedTenMilliseconds(into: tap, direction: .remote)
        }
        session.stop()

        XCTAssertEqual(self.waitForTerminalState(of: session), .finished(.truncated), "a lost tail is reported, not hidden")
        let recordingId = try XCTUnwrap(session.savedRecordingId, "the playable prefix is kept")
        let item = try XCTUnwrap(SGCallRecordingStore.shared.item(id: recordingId))
        XCTAssertFalse(item.isComplete, "the sidecar says the recording stops early")

        let decoded = try XCTUnwrap(sgDecodeOggOpus(path: item.audioPaths[0]))
        let decodedSeconds = Double(decoded.count) / 48_000.0
        XCTAssertEqual(decodedSeconds, 1.0, accuracy: 0.1, "exactly the page that reached the disk")
        XCTAssertLessThan(decodedSeconds, 1.4, "the lost tail is not on disk")
        XCTAssertGreaterThan(sgRMS(decoded, from: 0.1, to: 0.9), SGCallRecordingSessionTests.toneRMS, "the prefix is the conversation")
    }

    /// AUDIO THAT ARRIVES AFTER STOP IS NOT RECORDED. The native detach is asynchronous, so the tap
    /// can keep firing after the user pressed Stop and before the encoder's final drain runs. That
    /// audio was never covered by the recording the user asked for. The encoder queue is held here
    /// so the final drain deterministically runs after the late audio has been delivered.
    func testAudioDeliveredAfterStopIsNotRecorded() throws {
        SGCallRecordingGate.consentAccepted = true
        let encodeQueue = Queue(name: "SGCallRecordingEncodeHeldByTest")
        let (session, tap, detachCount) = try self.startRecording(encodeQueue: encodeQueue)

        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        for _ in 0 ..< 50 {
            local.feedTenMilliseconds(into: tap, direction: .local)
            remote.feedTenMilliseconds(into: tap, direction: .remote)
        }

        let hold = DispatchSemaphore(value: 0)
        encodeQueue.async {
            hold.wait()
        }
        session.stop()
        XCTAssertEqual(detachCount(), 1)
        XCTAssertEqual(session.stateValue, .finishing)
        // Half a second of both legs after Stop, before the final drain.
        for _ in 0 ..< 50 {
            local.feedTenMilliseconds(into: tap, direction: .local)
            remote.feedTenMilliseconds(into: tap, direction: .remote)
        }
        hold.signal()

        XCTAssertEqual(self.waitForTerminalState(of: session), .idle)
        let recordingId = try XCTUnwrap(session.savedRecordingId)
        let item = try XCTUnwrap(SGCallRecordingStore.shared.item(id: recordingId))
        XCTAssertTrue(item.isComplete)
        let decoded = try XCTUnwrap(sgDecodeOggOpus(path: item.audioPaths[0]))
        XCTAssertEqual(Double(decoded.count) / 48_000.0, 0.5, accuracy: 0.06, "only what was delivered before Stop")
        XCTAssertGreaterThan(sgRMS(decoded, from: 0.05, to: 0.45), SGCallRecordingSessionTests.toneRMS)
    }

    // MARK: - Deletion and account removal while recording

    /// A Delete of the live recording (per-row, "Delete All", a wipe) tombstones it. Capture must
    /// end on its own — tap detached, no hang-up needed — and nothing may be saved or offered.
    func testDeletingTheLiveRecordingStopsCaptureAndSavesNothing() throws {
        SGCallRecordingGate.consentAccepted = true
        let (session, tap, detachCount) = try self.startRecording()
        let liveId = try XCTUnwrap(SGCallRecordingStore.shared.activeRecordingId)

        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        for _ in 0 ..< 30 {
            local.feedTenMilliseconds(into: tap, direction: .local)
            remote.feedTenMilliseconds(into: tap, direction: .remote)
        }
        XCTAssertTrue(SGCallRecordingStore.shared.delete(id: liveId), "a live delete is acknowledged once tombstoned")

        // No stop() here: the session must end itself.
        XCTAssertEqual(self.waitForTerminalState(of: session), .idle)
        XCTAssertEqual(detachCount(), 1, "the tap is detached")
        XCTAssertNil(session.savedRecordingId, "a deleted recording is never handed to delivery")
        XCTAssertNil(SGCallRecordingStore.shared.item(id: liveId))
        XCTAssertFalse(self.anyFileExists(id: liveId), "audio and sidecar are gone")
    }

    /// An account removal (logout) fences the account. A recording of that account still running
    /// must end and be removed, not outlive it until hang-up.
    func testAccountRemovalFenceStopsCaptureAndSavesNothing() throws {
        SGCallRecordingGate.consentAccepted = true
        let accountPeerId: Int64 = 4_200_000_501
        let (session, tap, detachCount) = try self.startRecording(accountPeerId: accountPeerId)
        let liveId = try XCTUnwrap(SGCallRecordingStore.shared.activeRecordingId)

        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        for _ in 0 ..< 30 {
            local.feedTenMilliseconds(into: tap, direction: .local)
        }
        SGCallRecordingStore.shared.fenceRecording(accountPeerId: accountPeerId)

        XCTAssertEqual(self.waitForTerminalState(of: session), .idle)
        XCTAssertEqual(detachCount(), 1)
        XCTAssertNil(session.savedRecordingId)
        XCTAssertFalse(self.anyFileExists(id: liveId))
    }

    /// A start for an account whose cleanup is pending is refused with its own reason, before any
    /// file exists or the tap is attached — never reported as "free space".
    func testFencedAccountCannotStartAndSaysWhy() {
        SGCallRecordingGate.consentAccepted = true
        let accountPeerId: Int64 = 4_200_000_502
        SGCallRecordingStore.shared.fenceRecording(accountPeerId: accountPeerId)
        let idsBefore = self.recordingIds()

        let session = self.makeSession(isFeatureAvailable: true, accountPeerId: accountPeerId)
        var attachCount = 0
        XCTAssertFalse(session.start(isMicrophoneMuted: false, attachSink: { _ in
            attachCount += 1
            return {}
        }))
        XCTAssertEqual(session.stateValue, .failed(.accountCleanupPending))
        XCTAssertEqual(attachCount, 0)
        XCTAssertEqual(self.recordingIds(), idsBefore)
    }

    /// THE FINISH/DELETE RACE (review M2/M4). A delete that lands right after the live marker goes
    /// down purges at once, with no tombstone. The final sidecar — which names the other party —
    /// must already have been written while the recording was live, so nothing is written after
    /// that purge to resurrect it, and the purged recording is not reported as saved.
    ///
    /// Deterministic: the delete runs synchronously inside the store's own `activeRecordingIdSignal`
    /// emission for the marker going down, i.e. exactly between "marker cleared" and whatever the
    /// session does next.
    func testDeleteImmediatelyAfterTheLiveMarkerClearsDoesNotResurrectTheSidecar() throws {
        SGCallRecordingGate.consentAccepted = true
        let (session, tap, _) = try self.startRecording()
        let liveId = try XCTUnwrap(SGCallRecordingStore.shared.activeRecordingId)

        var deletedAtClear = false
        var sawLive = false
        let barrier = SGCallRecordingStore.shared.activeRecordingIdSignal.start(next: { activeId in
            if activeId == liveId {
                sawLive = true
            } else if sawLive && activeId == nil && !deletedAtClear {
                deletedAtClear = true
                SGCallRecordingStore.shared.delete(id: liveId)
            }
        })
        defer {
            barrier.dispose()
        }

        let local = SGSyntheticPCM(frequency: 440.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        let remote = SGSyntheticPCM(frequency: 660.0, sampleRate: 48_000, channelCount: 1, amplitude: SGCallRecordingSessionTests.toneAmplitude)
        for _ in 0 ..< 30 {
            local.feedTenMilliseconds(into: tap, direction: .local)
            remote.feedTenMilliseconds(into: tap, direction: .remote)
        }
        session.stop()
        XCTAssertEqual(self.waitForTerminalState(of: session), .idle)

        XCTAssertTrue(deletedAtClear, "the barrier must have fired")
        XCTAssertNil(session.savedRecordingId, "a purged recording is not reported as saved")
        XCTAssertNil(SGCallRecordingStore.shared.item(id: liveId))
        XCTAssertFalse(self.anyFileExists(id: liveId), "no sidecar is written after the purge")
    }

    // MARK: - Helpers

    private func makeSession(
        isFeatureAvailable: Bool,
        accountPeerId: Int64 = SGCallRecordingSessionTests.accountPeerId,
        encodeQueue: Queue = Queue(name: "SGCallRecordingEncodeTest"),
        openDataItem: @escaping SGCallRecordingDataItemOpener = { SGOggFileDataItem(existingFileAtPath: $0) }
    ) -> SGCallRecordingSession {
        return SGCallRecordingSession(
            peerTitle: SGCallRecordingSessionTests.peerTitle,
            accountPeerId: accountPeerId,
            peerId: SGCallRecordingSessionTests.peerId,
            isFeatureAvailable: isFeatureAvailable,
            encodeQueue: encodeQueue,
            openDataItem: openDataItem
        )
    }

    /// Starts a recording with a hand-driven tap; the third value reads how often it was detached.
    private func startRecording(
        accountPeerId: Int64 = SGCallRecordingSessionTests.accountPeerId,
        encodeQueue: Queue = Queue(name: "SGCallRecordingEncodeTest"),
        openDataItem: @escaping SGCallRecordingDataItemOpener = { SGOggFileDataItem(existingFileAtPath: $0) }
    ) throws -> (SGCallRecordingSession, SGCallRecordingAudioSink, () -> Int) {
        let session = self.makeSession(isFeatureAvailable: true, accountPeerId: accountPeerId, encodeQueue: encodeQueue, openDataItem: openDataItem)
        var sink: SGCallRecordingAudioSink?
        var detachCount = 0
        XCTAssertTrue(session.start(isMicrophoneMuted: false, attachSink: { attached in
            sink = attached
            return {
                detachCount += 1
            }
        }))
        if let id = SGCallRecordingStore.shared.activeRecordingId {
            self.createdRecordingIds.append(id)
        }
        return (session, try XCTUnwrap(sink), { detachCount })
    }

    /// Any file of this recording — audio (mixed or legacy legs) or sidecar — still on disk.
    private func anyFileExists(id: String) -> Bool {
        let store = SGCallRecordingStore.shared
        let paths = [store.mixedFilePath(id: id), store.localFilePath(id: id), store.remoteFilePath(id: id), store.metadataFilePath(id: id)]
        return paths.contains { path in
            path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        }
    }

    private func recordingIds() -> Set<String> {
        return Set(SGCallRecordingStore.shared.list().map { $0.id })
    }

    private func waitForTerminalState(of session: SGCallRecordingSession) -> SGCallRecordingState? {
        let expectation = self.expectation(description: "recording reaches a terminal state")
        var terminal: SGCallRecordingState?
        let disposable = (session.state
        |> deliverOnMainQueue).start(next: { state in
            switch state {
            case .idle, .finished, .failed:
                if terminal == nil {
                    terminal = state
                    expectation.fulfill()
                }
            case .recording, .finishing:
                break
            }
        })
        self.wait(for: [expectation], timeout: 10.0)
        disposable.dispose()
        return terminal
    }
}

/// A real file-backed data item whose writes start failing after a fixed number of AUDIO pages, the
/// way ENOSPC or EIO fails a recording mid-call. The Opus header pages (granule position 0) always
/// go through; every page before the limit reaches the file through `SGOggFileDataItem` itself;
/// from the first page past it nothing more is written and the error latch reads set.
///
/// Only ever touched by the session's start (on main) and then its encoder queue, in that order.
private final class SGFailingOggFileDataItem: SGOggFileDataItem {
    private let audioPageLimit: Int
    private var audioPageCount = 0
    private var injectedFailure = false

    init?(path: String, audioPageLimit: Int) {
        self.audioPageLimit = audioPageLimit
        super.init(existingFileAtPath: path)
    }

    override func appendData(_ data: Data!) {
        guard let data = data else {
            return
        }
        // Bytes 6..<14 of an Ogg page header are its granule position: 0 for the Opus header pages.
        let isAudioPage = data.count >= 14 && data[data.startIndex + 6 ..< data.startIndex + 14].contains { $0 != 0 }
        if isAudioPage {
            if self.injectedFailure || self.audioPageCount >= self.audioPageLimit {
                self.injectedFailure = true
                return
            }
            self.audioPageCount += 1
        }
        super.appendData(data)
    }

    override var hasError: Bool {
        return self.injectedFailure || super.hasError
    }
}

/// A continuous sine wave delivered the way the native tap delivers audio: interleaved Int16, the
/// count being the total number of values (frames × channels).
private final class SGSyntheticPCM {
    private let frequency: Double
    private let sampleRate: Int
    private let channelCount: Int
    private let amplitude: Double
    private var frameIndex: Int = 0

    init(frequency: Double, sampleRate: Int, channelCount: Int, amplitude: Double) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.amplitude = amplitude
    }

    func feedTenMilliseconds(into sink: SGCallRecordingAudioSink, direction: SGCallRecordingDirection) {
        let frameCount = self.sampleRate / 100
        var samples = [Int16](repeating: 0, count: frameCount * self.channelCount)
        for frame in 0 ..< frameCount {
            let phase = 2.0 * Double.pi * self.frequency * Double(self.frameIndex + frame) / Double(self.sampleRate)
            let value = Int16(self.amplitude * sin(phase))
            for channel in 0 ..< self.channelCount {
                samples[frame * self.channelCount + channel] = value
            }
        }
        self.frameIndex += frameCount
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            sink(direction.rawValue, base, buffer.count, self.channelCount, Int32(self.sampleRate))
        }
    }
}

/// Decodes a mono Ogg/Opus file to 48 kHz Int16. `op_read` returns one packet per call, and
/// `OP_HOLE` (-3) is a recoverable gap, so both are looped over; any other negative is an error.
private func sgDecodeOggOpus(path: String) -> [Int16]? {
    guard let reader = OggOpusReader(path: path) else {
        return nil
    }
    let bufferCount = 5_760
    var buffer = [Int16](repeating: 0, count: bufferCount)
    var output: [Int16] = []
    var holes = 0
    while true {
        let read = buffer.withUnsafeMutableBytes { bytes -> Int32 in
            return reader.read(bytes.baseAddress!, bufSize: Int32(bufferCount))
        }
        if read > 0 {
            output.append(contentsOf: buffer[0 ..< Int(read)])
        } else if read == -3 && holes < 8 {
            holes += 1
        } else if read == 0 {
            return output
        } else {
            return nil
        }
    }
}

/// RMS of the decoded signal between two times, in seconds at 48 kHz.
private func sgRMS(_ samples: [Int16], from start: Double, to end: Double) -> Double {
    let lower = max(0, Int(start * 48_000.0))
    let upper = min(samples.count, Int(end * 48_000.0))
    if upper <= lower {
        return 0.0
    }
    var sum: Double = 0.0
    for index in lower ..< upper {
        let value = Double(samples[index])
        sum += value * value
    }
    return (sum / Double(upper - lower)).squareRoot()
}
