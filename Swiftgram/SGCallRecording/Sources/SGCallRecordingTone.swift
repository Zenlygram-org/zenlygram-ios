// MARK: Zenlygram — call recording, the local "recording started" cue.
//
// This tone is played to the LOCAL user only. `setTone:` mixes its samples into the playout buffer
// inside `AudioDeviceIOS::OnGetPlayoutData`
// (tgcalls/platform/darwin/iOS/tgcalls_audio_device_ios.mm:494-538), i.e. straight into this
// device's speaker, downstream of everything the other party could ever hear. It is how the app
// plays ringback and busy tones, and it cannot reach the far side.
//
// The far side is told by an ordinary chat message instead — see
// `SGCallRecordingGate.notifyOtherParty` and the setting's own description.

import Foundation

/// Two short 880 Hz beeps, mono 48 kHz signed 16-bit — the format `OngoingCallContext.Tone`
/// expects.
public func sgCallRecordingNoticeToneData() -> Data {
    let sampleRate: Double = 48000.0
    let frequency: Double = 880.0
    let beepDuration: Double = 0.12
    let gapDuration: Double = 0.09
    let amplitude: Double = 0.22

    let beepSampleCount = Int(sampleRate * beepDuration)
    let gapSampleCount = Int(sampleRate * gapDuration)
    let totalSampleCount = beepSampleCount * 2 + gapSampleCount

    var samples = [Int16](repeating: 0, count: totalSampleCount)
    // A short raised-cosine fade at each end keeps the beep from clicking.
    let fadeSampleCount = max(1, Int(sampleRate * 0.008))

    func renderBeep(at offset: Int) {
        for index in 0 ..< beepSampleCount {
            let phase = 2.0 * Double.pi * frequency * (Double(index) / sampleRate)
            var envelope: Double = 1.0
            if index < fadeSampleCount {
                envelope = Double(index) / Double(fadeSampleCount)
            } else if index >= beepSampleCount - fadeSampleCount {
                envelope = Double(beepSampleCount - index) / Double(fadeSampleCount)
            }
            let value = sin(phase) * amplitude * envelope * 32767.0
            samples[offset + index] = Int16(max(-32768.0, min(32767.0, value)))
        }
    }

    renderBeep(at: 0)
    renderBeep(at: beepSampleCount + gapSampleCount)

    return samples.withUnsafeBufferPointer { buffer in
        return Data(buffer: buffer)
    }
}
