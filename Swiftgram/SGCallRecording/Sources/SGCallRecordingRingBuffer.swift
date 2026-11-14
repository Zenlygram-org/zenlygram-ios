// MARK: Zenlygram — call recording, the buffer between the audio thread and the encoder.
//
// Both taps (`RecordedDataIsAvailable` for the microphone, `NeedMorePlayData` for the mixed
// playout) are called on the audio-unit render thread, from inside the shared ADM's own mutex
// (submodules/TgVoipWebrtc/Sources/OngoingCallThreadLocalContext.mm). Anything slow there is
// audible: the iOS ADM has a glitch detector that will log exactly this
// (tgcalls/platform/darwin/iOS/tgcalls_audio_device_ios.mm:462).
//
// So the producer side does one thing: memcpy into storage allocated once, up front, under an
// `os_unfair_lock` held for the duration of that memcpy and nothing else. `os_unfair_lock` is the
// right primitive here specifically because it donates priority to whoever holds it, so the
// high-priority render thread cannot be left waiting behind the ordinary-priority encoder queue.
// No allocation, no Foundation, no file I/O, no Swift runtime calls that can allocate.
//
// Capacity is ten seconds per direction. The encoder drains every 200 ms, so the buffer only has to
// absorb a stall; if it ever does overflow the newest samples are dropped (a truncated tail is
// better than a hole in the middle) and counted.
//
// SILENCE IS NOT THE SAME AS NOTHING, AND THIS IS WHERE THE MIX IS MADE POSSIBLE. The two
// directions carry no timestamps; the drain loop sums them by sample index from t = 0, and takes
// the same amount of time off both each pass. That is only correct because a buffer here is exactly
// as long as the time that has passed — so any sample this buffer swallows would shift its
// direction against the other one permanently, and bake the offset into the one file the user gets.
// Every path that would otherwise DROP audio therefore replaces it with the same number of zero
// samples instead: the overflow tail, the format-change reset (re-expressed in the new format's
// sample rate so the *duration* is what is preserved), and the mute gate in SGCallRecordingSession,
// which pushes silence through `writeSilence` rather than returning. A muted half-minute has to
// stay a silent half-minute, not vanish.
//
// This is the alignment mechanism, not an artefact of how the file used to be written. Nothing here
// may start "optimising away" a silent interval.

import Foundation

final class SGAudioRingBuffer {
    /// Interleaved int16 samples, i.e. `frames * channels`.
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    private var writeIndex: Int = 0
    private var availableCount: Int = 0

    /// The format the samples currently in the buffer are in. Read from the callback arguments
    /// rather than assumed: a route change can move either value even though 48 kHz mono is what
    /// both directions use in practice.
    private var sampleRate: Int = 0
    private var channelCount: Int = 0

    private(set) var droppedSampleCount: Int = 0
    /// Samples that were dropped (overflow, or discarded by a format change) and still owe the
    /// stream an equal length of silence. Flushed into the buffer as soon as there is room, and
    /// emitted directly by `read` once the buffer is empty, so the ordering is exact either way.
    private var pendingSilenceCount: Int = 0
    /// Set by `close()` when the recording is stopped; every later write is refused. Read and
    /// written only under the lock, so a write either lands entirely before the close or not at all.
    private var isClosed: Bool = false

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        self.storage.deinitialize(count: self.capacity)
        self.storage.deallocate()
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
    }

    /// PRODUCER — audio render thread only.
    func write(samples: UnsafePointer<Int16>, count: Int, sampleRate: Int, channelCount: Int) {
        if count <= 0 || sampleRate <= 0 || channelCount <= 0 {
            return
        }
        os_unfair_lock_lock(self.lock)
        if self.isClosed {
            os_unfair_lock_unlock(self.lock)
            return
        }
        self.applyFormatLocked(sampleRate: sampleRate, channelCount: channelCount)
        self.flushPendingSilenceLocked()
        self.appendLocked(samples: samples, count: count)
        os_unfair_lock_unlock(self.lock)
    }

    /// PRODUCER — audio render thread only. Writes `count` zero samples.
    ///
    /// This is what the mute gate uses. Returning early instead would remove the muted interval
    /// from the stream rather than silencing it, and the two directions would be permanently offset
    /// against each other from that point on.
    func writeSilence(count: Int, sampleRate: Int, channelCount: Int) {
        if count <= 0 || sampleRate <= 0 || channelCount <= 0 {
            return
        }
        os_unfair_lock_lock(self.lock)
        if self.isClosed {
            os_unfair_lock_unlock(self.lock)
            return
        }
        self.applyFormatLocked(sampleRate: sampleRate, channelCount: channelCount)
        self.flushPendingSilenceLocked()
        self.appendLocked(samples: nil, count: count)
        os_unfair_lock_unlock(self.lock)
    }

    /// LOCK HELD. Adopts a new capture format, converting whatever has to be discarded into an
    /// equivalent debt of silence.
    private func applyFormatLocked(sampleRate: Int, channelCount: Int) {
        if sampleRate == self.sampleRate && channelCount == self.channelCount {
            return
        }
        // A format change makes the pending samples uninterpretable (the buffer carries raw
        // interleaved values, not their format), so they cannot be kept — but their DURATION can.
        // Re-express both the buffered samples and any silence already owed as a sample count in
        // the NEW format, so the change costs the stream no time at all.
        var rescaled = 0
        let owed = self.availableCount + self.pendingSilenceCount
        if owed > 0, self.sampleRate > 0, self.channelCount > 0 {
            let seconds = Double(owed / self.channelCount) / Double(self.sampleRate)
            rescaled = Int((seconds * Double(sampleRate)).rounded()) * channelCount
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.writeIndex = 0
        self.availableCount = 0
        self.pendingSilenceCount = rescaled
    }

    /// LOCK HELD. Converts as much of the owed silence as fits into real zero samples, so it lands
    /// in the stream ahead of whatever is written next.
    private func flushPendingSilenceLocked() {
        if self.pendingSilenceCount <= 0 {
            return
        }
        let room = self.capacity - self.availableCount
        if room <= 0 {
            return
        }
        let amount = min(room, self.pendingSilenceCount)
        self.pendingSilenceCount -= amount
        self.appendLocked(samples: nil, count: amount)
    }

    /// LOCK HELD. `samples == nil` writes zeros.
    private func appendLocked(samples: UnsafePointer<Int16>?, count: Int) {
        var toWrite = count
        if toWrite > self.capacity - self.availableCount {
            // Overflow: keep what is already buffered, drop the tail — but owe the stream that many
            // silent samples, so a stall shortens the audio without shifting it.
            let accepted = self.capacity - self.availableCount
            let dropped = toWrite - accepted
            self.droppedSampleCount += dropped
            self.pendingSilenceCount += dropped
            toWrite = accepted
        }
        if toWrite > 0 {
            let firstChunk = min(toWrite, self.capacity - self.writeIndex)
            if let samples = samples {
                memcpy(self.storage.advanced(by: self.writeIndex), samples, firstChunk * MemoryLayout<Int16>.stride)
                if firstChunk < toWrite {
                    memcpy(self.storage, samples.advanced(by: firstChunk), (toWrite - firstChunk) * MemoryLayout<Int16>.stride)
                }
            } else {
                memset(self.storage.advanced(by: self.writeIndex), 0, firstChunk * MemoryLayout<Int16>.stride)
                if firstChunk < toWrite {
                    memset(self.storage, 0, (toWrite - firstChunk) * MemoryLayout<Int16>.stride)
                }
            }
            self.writeIndex = (self.writeIndex + toWrite) % self.capacity
            self.availableCount += toWrite
        }
    }

    /// CONSUMER — encoder queue only. Returns how many interleaved samples were copied out, and the
    /// format they are in.
    func read(into destination: UnsafeMutablePointer<Int16>, maxCount: Int) -> (count: Int, sampleRate: Int, channelCount: Int) {
        os_unfair_lock_lock(self.lock)

        var count = min(maxCount, self.availableCount)
        if count > 0 {
            var readIndex = self.writeIndex - self.availableCount
            if readIndex < 0 {
                readIndex += self.capacity
            }
            let firstChunk = min(count, self.capacity - readIndex)
            memcpy(destination, self.storage.advanced(by: readIndex), firstChunk * MemoryLayout<Int16>.stride)
            if firstChunk < count {
                memcpy(destination.advanced(by: firstChunk), self.storage, (count - firstChunk) * MemoryLayout<Int16>.stride)
            }
            self.availableCount -= count
        } else if self.pendingSilenceCount > 0 {
            // The buffer has drained and silence is still owed (the producer never got room to
            // write it). Hand it to the encoder directly rather than losing the time.
            count = min(maxCount, self.pendingSilenceCount)
            memset(destination, 0, count * MemoryLayout<Int16>.stride)
            self.pendingSilenceCount -= count
        }
        let sampleRate = self.sampleRate
        let channelCount = self.channelCount

        os_unfair_lock_unlock(self.lock)

        return (count, sampleRate, channelCount)
    }

    /// Empties the buffer and reopens it for writing, at the start of a recording.
    func reset() {
        os_unfair_lock_lock(self.lock)
        self.writeIndex = 0
        self.availableCount = 0
        self.pendingSilenceCount = 0
        self.droppedSampleCount = 0
        self.isClosed = false
        os_unfair_lock_unlock(self.lock)
    }

    /// Refuses every write from now on; what is already buffered stays readable. Called when the
    /// recording stops: the native sink is dropped asynchronously, and audio it delivers after Stop
    /// is not part of the recording. Taking the lock means a write in progress finishes first.
    func close() {
        os_unfair_lock_lock(self.lock)
        self.isClosed = true
        os_unfair_lock_unlock(self.lock)
    }
}

/// A single 32-bit flag written from the main queue and read from the audio render thread.
///
/// Used for the mute gate. An aligned 32-bit load/store is indivisible on every architecture this
/// app runs on, so no lock is needed and none is wanted on the render thread; the only consequence
/// of the missing barrier is that a toggle may be observed one 10 ms buffer late, which is exactly
/// the granularity of the thing being gated anyway.
final class SGAtomicFlag {
    private let storage: UnsafeMutablePointer<Int32>

    init(_ initialValue: Bool) {
        self.storage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.storage.initialize(to: initialValue ? 1 : 0)
    }

    deinit {
        self.storage.deinitialize(count: 1)
        self.storage.deallocate()
    }

    var value: Bool {
        get {
            return self.storage.pointee != 0
        }
        set {
            self.storage.pointee = newValue ? 1 : 0
        }
    }
}
