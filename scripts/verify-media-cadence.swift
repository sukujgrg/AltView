// Compiled by verify-media-cadence.py with the production sender, transport,
// playback and canvas declarations. Uses private fixture windows/preferences.
import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit
import CoreImage

private final class CadenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

nonisolated func saveFixtureFrame(_ image: CVPixelBuffer, suffix: String) {
    let url = URL(fileURLWithPath: CommandLine.arguments[3] + suffix + ".png")
    try? CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: image), to: url,
        format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
}

@MainActor
final class CadenceVerification: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let args = CommandLine.arguments
                guard args.count >= 4 else {
                    fputs("Run this fixture through scripts/verify-media-cadence.py\n", stderr)
                    NSApplication.shared.terminate(nil); return
                }
                let report = try await verify(url: URL(fileURLWithPath: args[1]), seconds: Double(args[2]) ?? 20,
                    captureOnly: args.count > 4 && args[4] == "capture",
                    startAt: args.count > 5 ? Double(args[5]) ?? 0 : 0,
                    recovery: args.count > 6 ? Int(args[6]) ?? 80 : 80)
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: args[3]), options: .atomic)
                print(String(decoding: data, as: UTF8.self))
                NSApplication.shared.terminate(nil)
            } catch {
                fputs("Cadence verification failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func window(_ title: String, at x: CGFloat, content: NSView) -> NSWindow {
        let window = CadenceWindow(contentRect: NSRect(x: x, y: 180, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentView = content; window.orderFrontRegardless()
        return window
    }

    private func verify(url: URL, seconds: Double, captureOnly: Bool, startAt: Double, recovery: Int) async throws -> [String: Any] {
        guard #available(macOS 14.4, *) else { throw Failure.message("Native video metrics require macOS 14.4") }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Verify localhost video cadence")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        NSWindow.allowsAutomaticWindowTabbing = false
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let nominalRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        guard duration > startAt + seconds + 5 else {
            throw Failure.message("The video must continue beyond the seek, five-second warmup and measurement; looping would invalidate cadence")
        }
        let item = AVPlayerItem(asset: asset), player = AVPlayer(playerItem: item)
        player.isMuted = true
        let sourceView = NSView(); sourceView.wantsLayer = true
        let sourcePicture = AVPlayerLayer(player: player)
        sourcePicture.videoGravity = .resizeAspect
        sourceView.layer?.addSublayer(sourcePicture)
        let source = window("Cadence check · source", at: 20, content: sourceView)
        sourcePicture.frame = sourceView.bounds
        let presentation = EucalyMediaPresentation(), picture = AVSampleBufferDisplayLayer()
        let canvas = EucalyMediaCanvas(presentation: presentation, picture: picture)
        let preview = window("Cadence check · AltView localhost", at: 680, content: canvas)
        canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
        source.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        var hostLeads: [Double] = [], layerLeads: [Double] = []
        let display = presentation.playback.onFrame
        presentation.playback.onFrame = { buffer in
            if let buffer {
                let pts = buffer.presentationTimeStamp.seconds
                hostLeads.append(pts - CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                layerLeads.append(pts - (picture.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? 0))
            }
            display?(buffer)
        }
        presentation.playback.muted = true
        var rebufferCount = 0, audioErrors: [String] = [], rebufferReasons: [String] = []
        presentation.playback.onRebuffer = { reason in rebufferCount += 1; rebufferReasons.append(reason) }
        presentation.playback.onError = { audioErrors.append($0) }

        var settings = SRTMediaSettings(); settings.host = "127.0.0.1"
        settings.port = Int.random(in: 24000...49000); settings.latency = recovery; settings.frameRate = 60
        let passphrase = UUID().uuidString
        let receiver = SRTMediaSession(), sender = SRTMediaSession(), decoded = SRTMediaDecodedOutput()
        let ingest = SRTMediaIngest(), audio = SRTProgramAudio(ingest: ingest)
        var captureFailure: String?
        let capture = SRTAudienceCapture(ingest: ingest, audio: audio) { captureFailure = $0 }
        let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let receive = Task {
            try await receiver.receive(settings: settings, passphrase: passphrase, output: decoded,
                onListening: { ready.continuation.yield(()) })
        }
        for await _ in ready.stream { break }
        try await sender.publish(settings: settings, passphrase: passphrase, ingest: captureOnly ? SRTMediaIngest() : ingest)
        try await receive.value
        let captureDrain = Task {
            if captureOnly {
                for await _ in ingest.signals { _ = ingest.drain() }
            }
        }
        var decodedPTS: [(host: Double, pts: Double)] = []
        let drain = Task {
            for await _ in decoded.ingest.signals {
                guard !Task.isCancelled else { break }
                for sample in decoded.ingest.drain() {
                    if case .video(let frame) = sample {
                        decodedPTS.append((CMClockGetTime(CMClockGetHostTimeClock()).seconds, frame.presentationTimeStamp.seconds))
                    }
                    presentation.playback.consume(sample)
                }
            }
        }
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            fputs("Source fixture: frame=\(source.frame) visible=\(source.isVisible) occluded=\(source.occlusionState) view=\(sourceView.bounds)\n", stderr)
            try await capture.start(windowID: UInt32(source.windowNumber), frameRate: 60)
            if startAt > 0 {
                await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            // Native setup can outlast activation. Keep both fixture windows
            // visible for the warmup; occluded rendering is a different test.
            preview.orderFrontRegardless(); source.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            player.play()
            // Allow source, SRT and hardware codecs to settle before measuring.
            try await Task.sleep(nanoseconds: 5_000_000_000)
            if let captureFailure { fputs("Capture status: \(captureFailure)\n", stderr) }
            let before = await picture.sampleBufferRenderer.videoPerformanceMetrics
            let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let sent = ingest.videoStatistics, received = decoded.ingest.videoStatistics
            let captureBefore = await capture.statistics()
            let enqueued = canvas.enqueuedFrameCount, backpressured = canvas.backpressuredEnqueueCount
            let overloads = canvas.overloadFlushCount, rebuffers = rebufferCount
            rebufferReasons.removeAll()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let end = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let after = await picture.sampleBufferRenderer.videoPerformanceMetrics
            let currentSent = ingest.videoStatistics, currentReceived = decoded.ingest.videoStatistics
            let captureAfter = await capture.statistics()
            let measured = decodedPTS.filter { $0.host >= start && $0.host < end }
            let intervals = zip(measured, measured.dropFirst()).map { $1.pts - $0.pts }
            let sorted = intervals.sorted()
            let elapsed = end - start
            let total = (after?.totalNumberOfFrames ?? 0) - (before?.totalNumberOfFrames ?? 0)
            let dropped = (after?.numberOfDroppedFrames ?? 0) - (before?.numberOfDroppedFrames ?? 0)
            let delayed = (after?.totalAccumulatedFrameDelay ?? 0) - (before?.totalAccumulatedFrameDelay ?? 0)
            var report: [String: Any] = [
                "file": url.path, "source_fps": nominalRate, "output_requested_fps": 60,
                "srt_recovery_ms": recovery,
                "fixture_active": NSApplication.shared.isActive, "source_key_window": source.isKeyWindow,
                "start_at_seconds": startAt,
                "capture_only": captureOnly,
                "measurement_seconds": elapsed, "capture_frames": currentSent.offered - sent.offered,
                "capture_callback_frames": captureAfter.received - captureBefore.received,
                "capture_rate_limited_frames": captureAfter.rateLimited - captureBefore.rateLimited,
                "sender_mailbox_drops": currentSent.discarded - sent.discarded,
                "decoded_frames": currentReceived.offered - received.offered,
                "receiver_mailbox_drops": currentReceived.discarded - received.discarded,
                "enqueued_frames": canvas.enqueuedFrameCount - enqueued,
                "backpressured_enqueues": canvas.backpressuredEnqueueCount - backpressured,
                "renderer_overload_flushes": canvas.overloadFlushCount - overloads,
                "native_metrics_available": before != nil && after != nil,
                "host_lead_last_ms": (hostLeads.last ?? 0) * 1000,
                "layer_lead_last_ms": (layerLeads.last ?? 0) * 1000,
                "layer_clock_rate": picture.controlTimebase.map { CMTimebaseGetRate($0) } ?? -1,
                "picture_width": picture.bounds.width,
                "picture_height": picture.bounds.height,
                "native_total_frames": total, "native_dropped_frames": dropped,
                "native_displayed_fps": Double(total - dropped) / elapsed,
                "native_average_frame_delay_ms": delayed * 1000 / Double(max(1, total - dropped)),
                "decoded_fps": Double(measured.count) / elapsed,
                "source_pts_interval_p50_ms": sorted.isEmpty ? 0 : sorted[sorted.count / 2] * 1000,
                "source_pts_interval_p99_ms": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))] * 1000,
                "source_pts_max_gap_ms": (sorted.last ?? 0) * 1000,
                "audio_rebuffers": rebufferCount - rebuffers, "audio_rebuffer_reasons": rebufferReasons, "audio_errors": audioErrors,
                "capture_error": captureFailure ?? "",
                "display_refresh_max_hz": source.screen?.maximumFramesPerSecond ?? 0,
                "macos": ProcessInfo.processInfo.operatingSystemVersionString
            ]
            if let timebase = picture.controlTimebase {
                CMTimebaseSetRate(timebase, rate: 0)
                try await Task.sleep(nanoseconds: 30_000_000)
                let displayed = picture.sampleBufferRenderer.displayedPixelBuffer()
                report["displayed_image_available"] = displayed != nil
                if let displayed { saveFixtureFrame(displayed, suffix: ".displayed") }
            }
            await capture.stop(); audio.stop(); ingest.finish(); decoded.ingest.finish(); drain.cancel(); captureDrain.cancel()
            await sender.close(); await receiver.close(); presentation.playback.reset()
            player.pause(); source.close(); preview.close()
            return report
        } catch {
            await capture.stop(); audio.stop(); ingest.finish(); decoded.ingest.finish(); drain.cancel(); captureDrain.cancel()
            await sender.close(); await receiver.close(); presentation.playback.reset()
            player.pause(); source.close(); preview.close()
            throw error
        }
    }

    private enum Failure: Error { case message(String) }
}

@main
struct MediaCadenceMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let verification = CadenceVerification()
        application.delegate = verification
        application.run()
    }
}
