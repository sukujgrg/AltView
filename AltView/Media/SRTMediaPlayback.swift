@preconcurrency import AVFoundation
import HaishinKit
import os
#if os(macOS)
import CoreAudio
#endif

final class SRTMediaDecodedOutput: StreamOutput, @unchecked Sendable {
    // Preserve short decoder/network bursts until the main actor can enqueue
    // them on the timed display layer; discard oldest pictures on overload.
    let ingest = SRTMediaIngest(videoCapacity: 8)
    func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) { ingest.offer(.video(video)) }
    func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        if let pcm = audio as? AVAudioPCMBuffer { ingest.offer(.audio(pcm, when)) }
    }
}

/// Decoded audio and video use one timestamp origin. The presentation host is
/// responsible only for drawing frames; no eucaly model or macOS window APIs.
@MainActor
final class SRTMediaPlayback {
    private static let logger = Logger(subsystem: "com.suku.AltView", category: "media-playback")
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var origin: Double?
    private var hostOrigin: Double = 0
    private var audioStart: AVAudioFramePosition?
    private var audioFrames: AVAudioFramePosition = 0
    private var audioHostStart: Double = 0
    private let playoutDelay = 0.08
    private let maximumQueuedAudio = 0.3
    var muted = false { didSet { player.volume = muted ? 0 : 1 } }
    var audioDevice: UInt32?
    var frame: CMSampleBuffer?
    var onFrame: ((CMSampleBuffer?) -> Void)?
    var onError: ((String) -> Void)?
    init(engine: AVAudioEngine = AVAudioEngine()) { self.engine = engine; engine.attach(player) }
    private func hostTime(for pts: Double) -> Double {
        if origin == nil {
            origin = pts
            hostOrigin = CMClockGetTime(CMClockGetHostTimeClock()).seconds + playoutDelay
        }
        return hostOrigin + pts - (origin ?? pts)
    }
    func consume(_ sample: SRTMediaIngest.Sample) {
        switch sample {
        case .video(let buffer):
            let pts = buffer.presentationTimeStamp.seconds
            guard pts.isFinite else { return }
            let target = hostTime(for: pts)
            // A stalled decoder must recover to the current picture, not replay
            // an old queue. Discontinuities reset the common audio/video clock.
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if target < now - 0.3 || target > now + 1 { reset(); _ = hostTime(for: pts) }
            var timing = CMSampleTimingInfo(duration: buffer.duration,
                presentationTimeStamp: CMTime(seconds: hostTime(for: pts), preferredTimescale: 90000), decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy else { return }
            frame = copy; onFrame?(copy)
        case .audio(let buffer, let when):
            guard when.isSampleTimeValid, when.sampleRate == buffer.format.sampleRate,
                  when.sampleRate > 0, buffer.frameLength > 0 else { return }
            let pts = Double(when.sampleTime) / when.sampleRate
            if format != buffer.format {
                stopAudio(); engine.stop(); engine.disconnectNodeOutput(player); format = nil
                #if os(macOS)
                if let unit = engine.outputNode.audioUnit {
                    var device = audioDevice ?? 0
                    if audioDevice == nil {
                        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                        var size = UInt32(MemoryLayout<UInt32>.size)
                        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                        if result != noErr { onError?("The default audio output is unavailable (\(result))."); return }
                    }
                    let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device)))
                    if result != noErr { onError?("The selected audio output is unavailable (\(result))."); return }
                }
                #endif
                engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
                do { try engine.start() } catch { onError?("Audio output failed: \(error.localizedDescription)"); return }
                format = buffer.format
                player.volume = muted ? 0 : 1
            }
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let remaining = remainingAudioFrames(at: now, sampleRate: when.sampleRate)
            // PTS uses a 90 kHz clock: allow its one-sample rounding, but recover
            // the common A/V origin after real loss, an underrun or a stale queue.
            let timestampDifference = audioStart.map { when.sampleTime - ($0 + audioFrames) } ?? 0
            let discontinuity = abs(timestampDifference) > 2
            if audioStart != nil && (discontinuity || remaining <= 0 ||
                remaining + Double(buffer.frameLength) > maximumQueuedAudio * when.sampleRate) {
                let reason = discontinuity ? "source_discontinuity" : remaining <= 0 ? "underrun" : "queue_limit"
                Self.logger.notice("audio_rebuffer reason=\(reason, privacy: .public) queued_frames=\(remaining) timestamp_delta_frames=\(timestampDifference)")
                stopAudio()
                origin = pts; hostOrigin = now + playoutDelay
                frame = nil; onFrame?(nil)
            }
            if audioStart == nil {
                var target = hostTime(for: pts)
                // Engine/device startup can consume the original lead time.
                // Move both audio and video together instead of clamping packets.
                if target < now + 0.02 || target > now + maximumQueuedAudio {
                    origin = pts; hostOrigin = now + playoutDelay; target = hostOrigin
                    frame = nil; onFrame?(nil)
                }
                audioStart = when.sampleTime; audioHostStart = target
                player.scheduleBuffer(buffer, at: nil)
                player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: target)))
                Self.logger.notice("audio_start lead_s=\(target - now) sample_rate=\(when.sampleRate)")
            } else {
                // One device-clock stream. Separate host deadlines can create
                // a gap/overlap at every rounded PTS or overlap a late batch.
                player.scheduleBuffer(buffer, at: nil)
            }
            audioFrames += AVAudioFramePosition(buffer.frameLength)
        }
    }
    private func remainingAudioFrames(at now: Double, sampleRate: Double) -> Double {
        guard audioStart != nil else { return 0 }
        if let rendered = player.lastRenderTime, let played = player.playerTime(forNodeTime: rendered), played.isSampleTimeValid {
            let elapsed = rendered.isHostTimeValid ? max(0, now - AVAudioTime.seconds(forHostTime: rendered.hostTime)) : 0
            return Double(audioFrames - played.sampleTime) - elapsed * sampleRate
        }
        return Double(audioFrames) - max(0, now - audioHostStart) * sampleRate
    }
    private func stopAudio() {
        player.stop(); audioStart = nil; audioFrames = 0; audioHostStart = 0
    }
    func reset() {
        stopAudio(); engine.stop(); format = nil
        origin = nil; frame = nil; onFrame?(nil)
    }
}
