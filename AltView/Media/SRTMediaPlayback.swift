@preconcurrency import AVFoundation
import HaishinKit
#if os(macOS)
import CoreAudio
#endif

final class SRTMediaDecodedOutput: StreamOutput, @unchecked Sendable {
    let ingest = SRTMediaIngest()
    func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) { ingest.offer(.video(video)) }
    func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        if let pcm = audio as? AVAudioPCMBuffer { ingest.offer(.audio(pcm, when)) }
    }
}

/// Decoded audio and video use one timestamp origin. The presentation host is
/// responsible only for drawing frames; no eucaly model or macOS window APIs.
@MainActor
final class SRTMediaPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var origin: Double?
    private var hostOrigin: Double = 0
    private var scheduledAudio = 0
    private var generation = UUID()
    var muted = false { didSet { player.volume = muted ? 0 : 1 } }
    var audioDevice: UInt32?
    var frame: CMSampleBuffer?
    var onFrame: ((CMSampleBuffer?) -> Void)?
    var onError: ((String) -> Void)?
    init() { engine.attach(player) }
    private func hostTime(for pts: Double) -> Double {
        if origin == nil {
            origin = pts
            hostOrigin = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.04
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
            guard when.isSampleTimeValid, when.sampleRate > 0 else { return }
            let pts = Double(when.sampleTime) / when.sampleRate
            let target = hostTime(for: pts)
            if format != buffer.format {
                player.stop(); engine.stop(); engine.disconnectNodeOutput(player)
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
                player.play()
            }
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            guard target >= now - 0.1, target <= now + 1, scheduledAudio < 12 else { return }
            let token = generation
            scheduledAudio += 1
            let host = AVAudioTime.hostTime(forSeconds: max(target, now))
            player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: host), options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.scheduledAudio = max(0, self.scheduledAudio - 1)
                }
            }
        }
    }
    func reset() {
        generation = UUID(); player.stop(); engine.stop(); format = nil
        origin = nil; scheduledAudio = 0; frame = nil; onFrame?(nil)
    }
}
