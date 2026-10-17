import XCTest
import AVFoundation
import AppKit
@testable import AltView
@testable import HaishinKit
@testable import SRTHaishinKit

@MainActor
final class SRTMediaTests: XCTestCase {
    func testTransportKeepsExact60FPSClockTicksAtLargeHostTimes() throws {
        let origin = CMTime(value: 1_234_567_890_123, timescale: 24_000_000)
        for i in 0..<1800 {
            var header = PESOptionalHeader()
            let pts = CMTimeAdd(origin, CMTime(value: Int64(i), timescale: 60))
            header.setTimestamp(origin, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            let timing = try XCTUnwrap(header.makeSampleTimingInfo(.invalid))
            XCTAssertEqual(timing.presentationTimeStamp, CMTime(value: 9000 + Int64(i) * 1500, timescale: 90000))
        }
    }

    func testVideoPresentationDoesNotExpireUsingThePreviousFrameInterval() throws {
        let playback = SRTMediaPlayback()
        for pts in [10.0, 10.012, 10.034, 10.049] {
            let source = try frame(at: pts)
            playback.consume(.video(source))
            let presented = try XCTUnwrap(playback.frame)
            XCTAssertFalse(presented.duration.isValid, "A previous PTS gap cannot describe this frame's display duration")
            XCTAssertTrue(presented.imageBuffer === source.imageBuffer)
        }
        playback.reset()
    }

    func testTransportKeepsOneOriginWhenAudioAndVideoStartAtDifferentTimes() async throws {
        let encoder = TestVideoEncoder()
        let compressed = await encoder.encode([try frame(at: 5.25)])
        let encoded = expectation(description: "Encoded timestamp fixture")
        var video: CMSampleBuffer?
        let collect = Task {
            for await packet in compressed { video = packet; encoded.fulfill(); break }
        }
        await fulfillment(of: [encoded], timeout: 5)
        await encoder.stop(); collect.cancel()
        let picture = try XCTUnwrap(video)
        let audio = AVAudioCompressedBuffer(format: try aacFormat(), packetCapacity: 1, maximumPacketSize: 16)
        audio.byteLength = 1; audio.packetCount = 1; audio.data.storeBytes(of: UInt8(0), as: UInt8.self)
        let writer = TSWriter(), output = writer.output
        writer.expectedMedias = [.audio, .video]
        writer.setTimestampOrigin(CMTime(seconds: 5, preferredTimescale: 90000))
        writer.audioFormat = audio.format; writer.videoFormat = picture.formatDescription
        XCTAssertEqual(writer.pmt.PCRPID, TSWriter.defaultAudioPID, "The transport clock must continue while video is idle")
        // The first audio callback is 250 ms later than the first video.
        writer.append(picture)
        writer.append(audio, when: AVAudioTime(sampleTime: 264000, atRate: 48000))
        var timestamps: [UInt16: Double] = [:]
        var audioCarriesClock = false
        for await data in output {
            for offset in stride(from: 0, to: data.count, by: TSPacket.size) {
                let packet = try XCTUnwrap(TSPacket(data: data.subdata(in: offset..<offset + TSPacket.size)))
                guard [TSWriter.defaultVideoPID, TSWriter.defaultAudioPID].contains(packet.pid),
                      packet.payloadUnitStartIndicator else { continue }
                let header = try XCTUnwrap(PESOptionalHeader(data: Data(packet.payload.dropFirst(6))))
                timestamps[packet.pid] = try XCTUnwrap(header.makeSampleTimingInfo(.zero)).presentationTimeStamp.seconds
                if packet.pid == TSWriter.defaultAudioPID { audioCarriesClock = packet.adaptationField?.pcrFlag == true }
            }
            if timestamps.count == 2 { break }
        }
        XCTAssertEqual(try XCTUnwrap(timestamps[TSWriter.defaultVideoPID]), 0.35, accuracy: 1.0 / 90000)
        XCTAssertEqual(try XCTUnwrap(timestamps[TSWriter.defaultAudioPID]), 0.60, accuracy: 1.0 / 90000)
        XCTAssertTrue(audioCarriesClock)
        writer.clear()
    }

    func testLiveCanvasEnqueuesShortBurstsEvenWhenReadinessIsFalse() throws {
        let picture = BackpressuredMediaDisplayLayer()
        let canvas = EucalyMediaCanvas(presentation: EucalyMediaPresentation(), picture: picture)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for i in 0..<8 { canvas.display(try frame(at: now + 0.08 + Double(i) / 60)) }
        XCTAssertEqual(picture.received.count, 8, "Native readiness must not silently drop real-time decoded frames")
        XCTAssertEqual(canvas.backpressuredEnqueueCount, 8)
        XCTAssertEqual(canvas.overloadFlushCount, 0)
        for (i, buffer) in picture.received.enumerated() {
            XCTAssertEqual(buffer.presentationTimeStamp.seconds, now + 0.08 + Double(i) / 60, accuracy: 1.0 / 90000)
        }
    }

    func testLiveCanvasBoundsAStalledQueueAndFlushesOldTimeline() throws {
        let picture = BackpressuredMediaDisplayLayer()
        let canvas = EucalyMediaCanvas(presentation: EucalyMediaPresentation(), picture: picture)
        let timebase = try XCTUnwrap(picture.controlTimebase)
        CMTimebaseSetRate(timebase, rate: 0)
        let now = CMTimebaseGetTime(timebase).seconds
        for i in 0..<25 { canvas.display(try frame(at: now + 0.08 + Double(i) / 60)) }
        XCTAssertEqual(canvas.overloadFlushCount, 1)
        XCTAssertEqual(picture.flushes, 1)
        canvas.flushVideoTimeline()
        for i in 0..<8 { canvas.display(try frame(at: now + 0.08 + Double(i) / 60)) }
        XCTAssertEqual(canvas.overloadFlushCount, 1, "Clock recovery must discard the old queue accounting too")
        canvas.display(nil)
        XCTAssertEqual(picture.clears, 1)
    }

    func testRapidMediaRestartKeepsReplacementReadinessAndDecodeDrain() async throws {
        let name = "MediaRestart.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Int.random(in: 24000...49000), forKey: "mediaSRTport")
        let controller = EucalyMediaViewController(defaults: defaults, secrets: TestMediaSecrets())
        _ = controller.view
        var offer: MediaOffer?
        controller.onMediaOfferChange = { offer = $0 }
        controller.configurePairing(key: Data("ABCD2345".utf8), receiverID: UUID())
        defer { controller.shutdown() }
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<400 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTFail("Media receiver did not reach the expected state")
        }
        try await waitFor { offer != nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let start = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Start Receiving" })
        let port = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Media listening port" })
        start.performClick(nil)
        try await waitFor { offer?.ready == true }
        for _ in 0..<3 {
            controller.stopReceiving()
            port.integerValue = Int.random(in: 24000...49000)
            start.performClick(nil)
            try await waitFor { offer?.ready == true }
            let ready = try XCTUnwrap(offer)
            let sender = SRTMediaSession(), ingest = SRTMediaIngest()
            do {
                var settings = SRTMediaSettings(); settings.host = "127.0.0.1"; settings.port = ready.port
                try await sender.publish(settings: settings, passphrase: ready.passphrase, ingest: ingest)
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
                let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                for i in 0..<90 {
                    ingest.offer(.video(try frame(at: origin + Double(i) / 60, patternSeed: UInt32(i + 1))))
                    let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
                    pcm.frameLength = 800
                    for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0, count: 800) }
                    ingest.offer(.audio(pcm, AVAudioTime(sampleTime: Int64((origin * 48000).rounded()) + Int64(i * 800), atRate: 48000)))
                    let remaining = origin + Double(i + 1) / 60 - CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                }
                try await waitFor { controller.presentation.playback.frame != nil }
                XCTAssertTrue(offer?.ready == true, "A retired task must not clear the replacement listener readiness")
            } catch { ingest.finish(); await sender.close(); throw error }
            ingest.finish(); await sender.close()
        }
    }

    func testReceiverPairingPersistsGeneratedMediaSecretAndRotatesWithoutStartingOutput() async throws {
        let name = "MediaPairing.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Int.random(in: 24000...49000), forKey: "mediaSRTport")
        defaults.set(20, forKey: "mediaSRTlatency")
        let secrets = TestMediaSecrets(), id = UUID()
        let controller = EucalyMediaViewController(defaults: defaults, secrets: secrets)
        _ = controller.view
        var offer: MediaOffer?
        controller.onMediaOfferChange = { offer = $0 }
        defer { controller.shutdown() }
        func prepared(_ key: String) async throws -> MediaOffer {
            offer = nil; controller.configurePairing(key: Data(key.utf8), receiverID: id)
            for _ in 0..<200 {
                if let offer { return offer }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw NSError(domain: "MediaPairing", code: 1)
        }
        let first = try await prepared("ABCD2345")
        XCTAssertEqual(first.receiverID, id); XCTAssertEqual(first.passphrase.count, 32)
        XCTAssertTrue(first.isValid); XCTAssertFalse(first.ready); XCTAssertFalse(controller.receiving)
        XCTAssertFalse(controller.output.isActive)
        let restored = try await prepared("ABCD2345")
        XCTAssertEqual(restored.passphrase, first.passphrase)
        let rotated = try await prepared("WXYZ6789")
        XCTAssertNotEqual(rotated.passphrase, first.passphrase)
        XCTAssertFalse(controller.receiving); XCTAssertFalse(rotated.ready)
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        let start = try XCTUnwrap(buttons(controller.view).first { $0.title == "Start Receiving" })
        start.performClick(nil)
        for _ in 0..<200 {
            if offer?.ready == true { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(offer?.ready == true, "Readiness is published after the real SRT listener binds")
        XCTAssertFalse(controller.output.isActive, "Start Receiving cannot open a display")
        controller.invalidatePairing()
        XCTAssertNil(offer); XCTAssertFalse(controller.receiving)
        XCTAssertEqual(start.title, "Start Receiving"); XCTAssertFalse(start.isEnabled)
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains(first.passphrase))
    }

    func testPlaybackLeadSweepMeasuresDelayedBatchesAndRecovery() async throws {
        for lead in [0.02, 0.04, 0.06, 0.08] {
            let fixture = try PlaybackFixture(playoutDelay: lead)
            var underruns = 0
            fixture.playback.onRebuffer = { if $0 == "underrun" { underruns += 1 } }
            fixture.playback.consume(.video(try frame(at: 5)))
            // Device/decoder startup can arrive after the original video origin.
            try await Task.sleep(nanoseconds: 150_000_000)
            let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            for batch in 0..<24 {
                let jitter = [0.0, 0.060, 0.010, 0.030][batch % 4]
                let deadline = start + Double(batch * 3 * 1024) / 48000 + jitter
                let wait = deadline - CMClockGetTime(CMClockGetHostTimeClock()).seconds
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                for packet in (batch * 3)..<(batch * 3 + 3) { try fixture.offer(packet: packet, timestamp: Int64(240000 + packet * 1024 + packet % 2)) }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
            let samples = fixture.captured.samples
            let first = try XCTUnwrap(samples.firstIndex { abs($0) > 0.02 })
            let last = try XCTUnwrap(samples.lastIndex { abs($0) > 0.02 })
            var zeroRun = 0, longestZeroRun = 0
            for value in samples[first...last] {
                zeroRun = abs(value) < 0.000001 ? zeroRun + 1 : 0
                longestZeroRun = max(longestZeroRun, zeroRun)
            }
            print("PLAYOUT_SWEEP lead_ms=\(Int(lead * 1000)) jitter_ms=60 batch=3 underruns=\(underruns) longest_silence_samples=\(longestZeroRun) rendered_samples=\(last - first)")
            XCTAssertTrue(fixture.errors.isEmpty)
            // This sweep is a diagnostic, not a wall-clock performance gate:
            // competing audio engines/host load can exceed the injected jitter.
            // Normal/batched waveform regressions above still require continuity.
            XCTAssertGreaterThan(last - first, 40000, "Every candidate must continue rendering after recovery")
            // A forced underrun must recover at every candidate without clearing video.
            let held = fixture.playback.frame
            try fixture.offer(packet: 72)
            XCTAssertTrue(fixture.playback.frame === held)
            XCTAssertGreaterThan(underruns, 0)
            fixture.stop()
        }
    }

    func testRecoveryBufferNegotiationHonorsTransportTypeBeforeOverrides() async throws {
        for (receiverDelay, senderDelay) in [(20, 20), (40, 40), (80, 20), (20, 80)] {
            var settings = SRTMediaSettings(); settings.host = "127.0.0.1"
            settings.port = Int.random(in: 24000...49000); settings.latency = receiverDelay
            let receiver = SRTConnection(), sender = SRTConnection()
            let listener = Task { try await receiver.connect(settings.url(passphrase: "regression-media-123", listening: true)) }
            try await Task.sleep(nanoseconds: 100_000_000)
            settings.latency = senderDelay
            do {
                try await sender.connect(settings.url(passphrase: "regression-media-123")); try await listener.value
                let received = try await receiver.getSocketOption(.rcvlatency)
                let advertised = try await sender.getSocketOption(.peerlatency)
                XCTAssertEqual(received?.intValue, max(receiverDelay, senderDelay))
                XCTAssertEqual(advertised?.intValue, max(receiverDelay, senderDelay))
                print("SRT negotiated receiver=\(receiverDelay) sender=\(senderDelay) actual=\(received?.intValue ?? -1) ms")
            } catch { await sender.close(); await receiver.close(); listener.cancel(); throw error }
            await sender.close(); await receiver.close()
        }
    }

    func testAnnexBParserPreservesNALUnitsInLargeFrames() {
        // About 24 Mbps at 60 fps, including escaped start-code lookalikes.
        let payload = Data(repeating: 0x55, count: 49_984) + Data([0, 0, 3, 1, 0x55])
        let units = [Data([0x09, 0x10]), Data([0x67, 0x64, 0, 0x28]),
            Data([0x68, 0xEE, 0x3C, 0x80]), Data([0x65]) + payload]
        var annexB = units.reduce(into: Data()) { $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1) }
        let reader = NALUnitReader()
        var parsed: [H264NALUnit] = [], total = 0
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<600 {
            parsed = reader.read(&annexB, type: H264NALUnit.self)
            total += parsed.reduce(0) { $0 + $1.payload.count }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("Annex-B parser: 600 x \(annexB.count) bytes in \(elapsed) seconds; checksum=\(total)")
        XCTAssertEqual(parsed.reversed().map(\.data), units)
        XCTAssertEqual(total, 600 * units.reduce(0) { $0 + $1.count - 1 })
    }

    func testAnnexBParserHandlesShortEmptyAndMixedStartCodes() {
        let reader = NALUnitReader()
        for var bytes in [Data(), Data([0]), Data([0, 0]), Data([0, 0, 1]),
            Data([0, 0, 0, 1]), Data([0, 0, 1, 0, 0, 0, 1])] {
            XCTAssertTrue(reader.read(&bytes, type: H264NALUnit.self).isEmpty)
        }
        let units = [Data([0x09, 0x10]), Data([0x65, 0xAA, 0, 0, 3, 1, 0xBB]), Data([0x41, 0xCC])]
        let bytes = Data([0xFF, 0xFF, 0, 0, 1]) + units[0] + Data([0, 0, 0, 1]) + units[1]
            + Data([0, 0, 1]) + units[2] + Data([0, 0, 0, 1])
        var sliced = bytes.dropFirst(2)
        XCTAssertEqual(reader.read(&sliced, type: H264NALUnit.self).reversed().map(\.data), units)
    }

    func testDecodedVideoBurstIsBoundedAndPreservesPresentationOrder() throws {
        let output = SRTMediaDecodedOutput()
        for i in 0..<3 { output.ingest.offer(.video(try frame(at: Double(i) / 60))) }
        func timestamps(_ samples: [SRTMediaIngest.Sample]) -> [Double] {
            samples.compactMap { if case .video(let frame) = $0 { return frame.presentationTimeStamp.seconds }; return nil }
        }
        XCTAssertEqual(timestamps(output.ingest.drain()), [0, 1.0 / 60, 2.0 / 60])
        for i in 0..<30 { output.ingest.offer(.video(try frame(at: Double(i)))) }
        XCTAssertEqual(timestamps(output.ingest.drain()), (22..<30).map(Double.init))
        XCTAssertEqual(output.ingest.videoStatistics.offered, 33)
        XCTAssertEqual(output.ingest.videoStatistics.discarded, 22)
        output.ingest.finish(); output.ingest.offer(.video(try frame(at: 40)))
        XCTAssertTrue(output.ingest.drain().isEmpty)
    }

    func testHostScheduledVideoDoesNotWaitForAnotherDisplayClock() async throws {
        let frames = try [frame(at: 1), frame(at: 11)]
        let encoder = TestVideoEncoder()
        let compressed = await encoder.encode(frames)
        let encoded = expectation(description: "Hardware encoder produced two frames")
        encoded.expectedFulfillmentCount = 2
        var packets: [CMSampleBuffer] = []
        let collect = Task {
            for await packet in compressed {
                packets.append(packet); encoded.fulfill()
                if packets.count == 2 { break }
            }
        }
        await fulfillment(of: [encoded], timeout: 5)
        await encoder.stop(); collect.cancel()
        XCTAssertEqual(packets.count, 2)

        let connection = SRTConnection(), output = SRTMediaDecodedOutput()
        let stream = SRTStream(connection: connection)
        await stream.addOutput(output)
        await stream.setVideoOutputIsScheduled(false)
        let incoming = await stream.incoming
        await incoming.startRunning()
        let start = ProcessInfo.processInfo.systemUptime
        for packet in packets { await incoming.append(packet) }
        var timestamps: [Double] = []
        while timestamps.count < 2 && ProcessInfo.processInfo.systemUptime - start < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
            for sample in output.ingest.drain() {
                if case .video(let frame) = sample { timestamps.append(frame.presentationTimeStamp.seconds) }
            }
        }
        await incoming.stopRunning(); output.ingest.finish(); await connection.close()
        XCTAssertEqual(timestamps, [1, 11], "The host must receive future frames promptly and schedule them on its own clock")
    }

    func testPlaybackRendersContinuousPCMWithRoundedPacketTimestamps() async throws {
        try await checkPlaybackContinuity()
    }

    func testClockRecoveryHoldsThePictureUntilReplacementAndStopClearsIt() async throws {
        let fixture = try PlaybackFixture()
        let playback = fixture.playback
        defer { fixture.stop() }
        var clears = 0
        playback.onFrame = { if $0 == nil { clears += 1 } }
        playback.consume(.video(try frame(at: 5)))
        let original = try XCTUnwrap(playback.frame)
        // The first audio packet can arrive after the video has already appeared.
        try await Task.sleep(nanoseconds: 150_000_000)
        try fixture.offer(packet: 0)
        XCTAssertTrue(playback.frame === original, "Audio startup must hold the visible picture while reanchoring")
        XCTAssertEqual(clears, 0, "Clock recovery must not flash black")
        try await Task.sleep(nanoseconds: 250_000_000)
        try fixture.offer(packet: 1)
        XCTAssertTrue(playback.frame === original, "An underrun must retain the last picture")
        XCTAssertEqual(clears, 0)
        playback.consume(.video(try frame(at: Double(240000 + 1024) / 48000)))
        XCTAssertNotNil(playback.frame)
        playback.reset()
        XCTAssertNil(playback.frame)
        XCTAssertEqual(clears, 1, "Stopping the receiver must still clear the picture")
    }

    func testCanvasTimelineFlushPreservesTheRenderedImageUntilExplicitClear() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Displayed pixel-buffer inspection requires macOS 14.4") }
        _ = NSApplication.shared
        let presentation = EucalyMediaPresentation(), picture = AVSampleBufferDisplayLayer()
        let canvas = EucalyMediaCanvas(presentation: presentation, picture: picture)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 128, height: 72),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFront(nil)
        defer { presentation.playback.reset(); window.close() }
        canvas.layoutSubtreeIfNeeded()
        presentation.playback.consume(.video(try frame(at: 5)))
        try await Task.sleep(nanoseconds: 250_000_000)
        let timebase = try XCTUnwrap(picture.controlTimebase)
        XCTAssertEqual(CMTimebaseSetRate(timebase, rate: 0), noErr)
        XCTAssertNotNil(picture.sampleBufferRenderer.displayedPixelBuffer(), "The native renderer must have a visible picture")
        XCTAssertEqual(CMTimebaseSetRate(timebase, rate: 1), noErr)
        canvas.flushVideoTimeline()
        try await Task.sleep(nanoseconds: 50_000_000)
        // Flush resets decoding readiness even while the last image remains.
        // Inspect that image after recovery on the normal running clock.
        XCTAssertEqual(CMTimebaseSetRate(timebase, rate: 0), noErr)
        XCTAssertNotNil(picture.sampleBufferRenderer.displayedPixelBuffer(), "Discarding old deadlines must retain the rendered image")
        // Render a replacement so Stop is checked from a ready, running state.
        XCTAssertEqual(CMTimebaseSetRate(timebase, rate: 1), noErr)
        presentation.playback.consume(.video(try frame(at: 5.25)))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(picture.isReadyForDisplay)
        presentation.playback.reset()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(picture.isReadyForDisplay, "Stopping must still remove the image")
    }

    func testLateOrFutureVideoCannotRestartCleanAudioOrClearThePicture() throws {
        let fixture = try PlaybackFixture()
        let playback = fixture.playback
        defer { fixture.stop() }
        var clears = 0
        playback.onFrame = { if $0 == nil { clears += 1 } }
        for packet in 0..<3 { try fixture.offer(packet: packet) }
        playback.consume(.video(try frame(at: 5.04)))
        let current = try XCTUnwrap(playback.frame)
        playback.consume(.video(try frame(at: 1)))
        XCTAssertTrue(fixture.engine.isRunning, "A stale video callback must not stop the audio engine")
        XCTAssertTrue(playback.frame === current)
        playback.consume(.video(try frame(at: 20)))
        XCTAssertTrue(fixture.engine.isRunning, "A future video timestamp must not restart clean audio")
        XCTAssertTrue(playback.frame === current)
        playback.consume(.video(try frame(at: 5.02)))
        XCTAssertTrue(playback.frame === current, "Out-of-order frames must not replace newer pictures")
        XCTAssertEqual(clears, 0)
        try fixture.offer(packet: 6)
        playback.consume(.video(try frame(at: 5.02)))
        XCTAssertTrue(playback.frame === current, "Pictures queued before a clock reset must not reappear")
        playback.consume(.video(try frame(at: Double(240000 + 6 * 1024) / 48000)))
        XCTAssertFalse(playback.frame === current, "The next frame on the recovered clock must replace the held picture")
        XCTAssertTrue(fixture.engine.isRunning)
        XCTAssertEqual(clears, 0)
    }

    func testPlaybackRendersContinuousPCMAfterLateStartupAndBatchedDelivery() async throws {
        try await checkPlaybackContinuity(startupDelay: 0.15, deliveryBatch: 3)
    }

    private func checkPlaybackContinuity(startupDelay: Double = 0, deliveryBatch: Int = 1) async throws {
        let fixture = try PlaybackFixture()
        let playback = fixture.playback
        defer { fixture.stop() }
        playback.consume(.video(try frame(at: 5)))
        if startupDelay > 0 { try await Task.sleep(nanoseconds: UInt64(startupDelay * 1_000_000_000)) }
        let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for packet in 0..<60 {
            let deadline = start + Double(max(0, packet / deliveryBatch * deliveryBatch - 3) * 1024) / 48000
            let delay = deadline - CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            // MPEG-TS's 90 kHz clock rounds a 48 kHz PCM timestamp by one sample.
            try fixture.offer(packet: packet, timestamp: Int64(240000 + packet * 1024 + packet % 2))
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(fixture.errors.isEmpty, fixture.errors.joined(separator: "; "))
        let samples = fixture.captured.samples
        let first = try XCTUnwrap(samples.firstIndex { abs($0) > 0.02 })
        let last = try XCTUnwrap(samples.lastIndex { abs($0) > 0.02 })
        XCTAssertGreaterThan(last - first, 4096)
        guard last - first > 4096 else { return }
        let interior = Array(samples[(first + 2048)..<(last - 2048)])
        let maxJump = zip(interior, interior.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        let rms = sqrt(interior.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, interior.count)))
        print("Rendered playback: delay=\(startupDelay) batch=\(deliveryBatch) frames=\(interior.count) rms=\(rms) maxJump=\(maxJump)")
        XCTAssertGreaterThan(interior.count, 40000)
        XCTAssertGreaterThan(rms, 0.065); XCTAssertLessThan(rms, 0.075)
        XCTAssertLessThan(maxJump, 0.02, "Packet timestamps must not insert gaps or overlap continuous PCM")
    }

    func testPlaybackReanchorsAudioAndVideoAfterUnderrunAndBoundsQueuedAudio() async throws {
        let fixture = try PlaybackFixture()
        let playback = fixture.playback
        defer { fixture.stop() }
        for packet in 0..<3 { try fixture.offer(packet: packet) }
        try await Task.sleep(nanoseconds: 350_000_000)
        try fixture.offer(packet: 3)
        playback.consume(.video(try frame(at: Double(240000 + 3 * 1024) / 48000)))
        var lead = try XCTUnwrap(playback.frame).presentationTimeStamp.seconds - CMClockGetTime(CMClockGetHostTimeClock()).seconds
        XCTAssertGreaterThan(lead, 0.03, "An underrun must restart the shared A/V clock with playout lead time")
        XCTAssertLessThan(lead, 0.3)
        for packet in 4..<44 { try fixture.offer(packet: packet) }
        playback.consume(.video(try frame(at: Double(240000 + 43 * 1024) / 48000)))
        lead = try XCTUnwrap(playback.frame).presentationTimeStamp.seconds - CMClockGetTime(CMClockGetHostTimeClock()).seconds
        XCTAssertGreaterThan(lead, 0.03)
        XCTAssertLessThan(lead, 0.3, "An oversized batch must recover to bounded, synchronized playout")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(fixture.errors.isEmpty, fixture.errors.joined(separator: "; "))
        let samples = fixture.captured.samples
        let last = try XCTUnwrap(samples.lastIndex { abs($0) > 0.02 })
        XCTAssertGreaterThan(last, 5000)
        guard last > 5000 else { return }
        let tail = Array(samples[(last - 4096)..<(last - 512)])
        XCTAssertGreaterThan(tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(tail.count), 0.004)
        XCTAssertLessThan(zip(tail, tail.dropFirst()).map { abs($0 - $1) }.max() ?? 0, 0.02)
        try fixture.offer(packet: 44)
        try fixture.offer(packet: 1000)
        playback.consume(.video(try frame(at: Double(240000 + 1000 * 1024) / 48000)))
        lead = try XCTUnwrap(playback.frame).presentationTimeStamp.seconds - CMClockGetTime(CMClockGetHostTimeClock()).seconds
        XCTAssertGreaterThan(lead, 0.03)
        XCTAssertLessThan(lead, 0.3, "A source timestamp jump must reanchor audio and video together")
        XCTAssertTrue(fixture.engine.isRunning, "Video recovery must not discard the restarted audio")
        playback.reset()
        XCTAssertNil(playback.frame)
        XCTAssertFalse(fixture.engine.isRunning)
    }

    func testTransportTimestampsDecodeKnownVectorsAndEveryPTSBit() {
        // MPEG-TS PTS fields have marker bits between the three bit groups.
        // In particular, the lowest seven timestamp bits come from byte five.
        let vectors: [(Int64, [UInt8])] = [
            (0, [0x21, 0x00, 0x01, 0x00, 0x01]),
            (1, [0x21, 0x00, 0x01, 0x00, 0x03]),
            (90000, [0x21, 0x00, 0x05, 0xBF, 0x21]),
            ((1 << 33) - 1, [0x2F, 0xFF, 0xFF, 0xFF, 0xFF])
        ]
        for (timestamp, bytes) in vectors {
            XCTAssertEqual(TSTimestamp.decode(Data(bytes)), timestamp)
            XCTAssertEqual(TSTimestamp.decode(Data([0xFF, 0xFF] + bytes), offset: 2), timestamp)
            XCTAssertEqual(TSTimestamp.encode(timestamp, 0x20), Data(bytes))
        }
        for bit in 0..<33 {
            let timestamp = Int64(1) << bit
            XCTAssertEqual(TSTimestamp.decode(TSTimestamp.encode(timestamp, 0x20)), timestamp, "PTS bit \(bit)")
        }
        var previous = TSTimestamp.decode(TSTimestamp.encode(9000, 0x20))
        for packet in 1..<500 {
            let next = TSTimestamp.decode(TSTimestamp.encode(9000 + Int64(packet) * 1920, 0x20))
            XCTAssertEqual(next - previous, 1920, "48 kHz AAC must keep its exact 1024-sample cadence")
            previous = next
        }
    }
    func testPESHeadersRejectTruncatedTimestampFields() throws {
        for count in 0..<PESOptionalHeader.fixedSectionSize {
            XCTAssertNil(PESOptionalHeader(data: Data(repeating: 0x80, count: count)))
        }
        let pts = TSTimestamp.encode(9000, 0x20)
        let both = TSTimestamp.encode(10920, 0x30) + TSTimestamp.encode(9000, 0x10)
        for (indicator, fields) in [(PESPTSDTSIndicator.onlyPTS, pts), (.bothPresent, both)] {
            for count in 0..<fields.count {
                let short = Data(fields.prefix(count))
                XCTAssertNil(PESOptionalHeader(data: Data([0x80, indicator.rawValue << 6, UInt8(count)]) + short),
                    "The declared header must contain every timestamp byte")
                XCTAssertNil(PESOptionalHeader(data: Data([0x80, indicator.rawValue << 6, UInt8(fields.count)]) + short),
                    "The supplied header must contain every declared byte")
                var header = PESOptionalHeader()
                header.ptsDtsIndicator = indicator.rawValue
                header.optionalFields = short
                XCTAssertNil(header.makeSampleTimingInfo(.invalid), "Directly constructed headers must also be safe")
            }
            let header = try XCTUnwrap(PESOptionalHeader(data: Data([0x80, indicator.rawValue << 6, UInt8(fields.count)]) + fields))
            let timing = try XCTUnwrap(header.makeSampleTimingInfo(.invalid))
            XCTAssertEqual(timing.presentationTimeStamp, CMTime(value: indicator == .onlyPTS ? 9000 : 10920, timescale: 90000))
            if indicator == .bothPresent {
                XCTAssertEqual(timing.decodeTimeStamp, CMTime(value: 9000, timescale: 90000))
            } else {
                XCTAssertFalse(timing.decodeTimeStamp.isValid)
            }
        }
        XCTAssertNil(PESOptionalHeader(data: Data([0x80, 0x40, 5]) + pts), "DTS without PTS is forbidden")
    }

    func testTransportReaderDiscardsMalformedPESTimestampsAndContinues() async throws {
        let reader = TSReader(), output = reader.output
        let pat = TSProgramAssociation(), pmt = TSProgramMap()
        pat.programs = [1: TSWriter.defaultPMTPID]
        pmt.PCRPID = TSWriter.defaultAudioPID
        var audio = ESSpecificData()
        audio.streamType = .adtsAac; audio.elementaryPID = TSWriter.defaultAudioPID
        pmt.elementaryStreamSpecificData = [audio]
        for packet in pat.arrayOfPackets(TSWriter.defaultPATPID) + pmt.arrayOfPackets(TSWriter.defaultPMTPID) {
            XCTAssertEqual(reader.read(packet.data), TSPacket.size)
        }
        let frame = adts(Data([0]))
        func readPES(_ header: Data) {
            let length = header.count + frame.count
            let payload = Data([0, 0, 1, 192, UInt8(length >> 8), UInt8(length & 0xff)]) + header + frame
            var packet = TSPacket()
            packet.pid = TSWriter.defaultAudioPID; packet.payloadUnitStartIndicator = true
            XCTAssertEqual(packet.fill(payload, useAdaptationField: true), payload.count)
            XCTAssertEqual(reader.read(packet.data), TSPacket.size)
        }
        let pts = TSTimestamp.encode(9000, 0x20)
        readPES(Data([0x80, 0x80, 5]) + pts)
        // Includes the one-byte PTS header that originally crashed TSReader.
        for (indicator, fields) in [(UInt8(0x80), pts), (0xc0, TSTimestamp.encode(9000, 0x30) + TSTimestamp.encode(7080, 0x10))] {
            for count in 0..<fields.count {
                readPES(Data([0x80, indicator, UInt8(count)]) + Data(fields.prefix(count)))
            }
        }
        readPES(Data([0x80, 0x40, 5]) + pts)
        readPES(Data([0x80, 0x80, 5]) + TSTimestamp.encode(10920, 0x20))
        // Starting another PES flushes the preceding valid packet; clear then
        // finishes the output stream so the test can inspect every emission.
        readPES(Data([0x80, 0x80, 1, 0x21]))
        reader.clear()
        var samples: [CMSampleBuffer] = []
        for await (pid, sample) in output {
            XCTAssertEqual(pid, TSWriter.defaultAudioPID)
            samples.append(sample)
        }
        XCTAssertEqual(samples.map(\.presentationTimeStamp), [CMTime(value: 9000, timescale: 90000), CMTime(value: 10920, timescale: 90000)])
        for sample in samples {
            XCTAssertEqual(sample.numSamples, 1)
            XCTAssertEqual(sample.dataBuffer?.dataLength, frame.count)
        }
    }

    func testSettingsRejectMalformedAddressesAndSecretsAndNeverEncodePassphrase() throws {
        var settings = SRTMediaSettings(); settings.host = "192.168.1.20"
        XCTAssertTrue(settings.isValid)
        let secret = "test-private-media-123"
        let url = try settings.url(passphrase: secret)
        XCTAssertEqual(url.host, settings.host); XCTAssertEqual(url.port, 10000)
        XCTAssertTrue(url.query?.contains("latency=80") == true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains(secret))
        settings.host = "srt://wrong/path"; XCTAssertFalse(settings.isValid)
        settings.host = "localhost"; settings.port = 0; XCTAssertFalse(settings.isValid)
        XCTAssertFalse(SRTMediaSettings.validPassphrase("short"))
        XCTAssertFalse(SRTMediaSettings.validPassphrase("bad&query=secret"))
    }

    func testIngestKeepsNewestVideoAndBoundsAudioAndRejectsAfterStop() throws {
        let queue = SRTMediaIngest()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        for i in 0..<30 {
            queue.offer(.video(try frame(at: Double(i))))
            queue.offer(.audio(try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)), AVAudioTime(sampleTime: Int64(i), atRate: 48000)))
        }
        let values = queue.drain()
        XCTAssertEqual(values.count, 9)
        if case .video(let buffer) = try XCTUnwrap(values.last) { XCTAssertEqual(buffer.presentationTimeStamp.seconds, 29) }
        else { XCTFail("Expected newest video") }
        queue.finish(); queue.offer(.video(try frame(at: 40)))
        XCTAssertTrue(queue.drain().isEmpty)
    }

    func testMediaWorkspaceHasNoClockOrTextStylingAndStartsStopped() throws {
        _ = NSApplication.shared
        let domain = "MediaWorkspace.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let controller = EucalyMediaViewController(defaults: defaults)
        defer { controller.shutdown() }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let children = views(controller.view)
        let labels = children.compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertFalse(labels.contains("CURRENT TIME"))
        XCTAssertTrue(labels.contains("eucaly Media"))
        XCTAssertFalse(controller.receiving)
        XCTAssertEqual(controller.output.readiness, .closed)
        XCTAssertTrue(children.contains { $0 is EucalyMediaCanvas })

    }

    func testEncryptedSRTLoopbackCarriesH264AndAACAndCloses() async throws {
        var settings = SRTMediaSettings(); settings.host = "127.0.0.1"
        settings.port = Int.random(in: 24000...49000); settings.latency = 20
        let secret = "loopback-media-123456"
        let receiver = SRTMediaSession(), sender = SRTMediaSession(), decoded = SRTMediaDecodedOutput(), ingest = SRTMediaIngest()
        let receive = Task { try await receiver.receive(settings: settings, passphrase: secret, output: decoded) }
        try await Task.sleep(nanoseconds: 200_000_000)
        do { try await sender.publish(settings: settings, passphrase: secret, ingest: ingest) }
        catch {
            await receiver.close(); receive.cancel()
            throw error
        }
        try await receive.value
        let connection = await receiver.connection
        let actualLatency = try await connection.getSocketOption(.rcvlatency)
        XCTAssertEqual(actualLatency?.intValue, 20)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let frameCount = 180, samplesPerFrame = 800
        var videos = 0, audios = 0
        var firstVideoPTS: Double?, lastVideoPTS: Double?
        var audioSamples = 0, energy = 0.0, maxJump: Float = 0
        var previous: Float?, previousEnd: Int64?, maxTimestampGap: Int64 = 0
        for i in 0..<frameCount {
            let pts = start + Double(i) / 60
            ingest.offer(.video(try frame(at: pts, patternSeed: UInt32(i + 1))))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samplesPerFrame)))
            pcm.frameLength = AVAudioFrameCount(samplesPerFrame)
            for channel in 0..<2 { for sample in 0..<samplesPerFrame {
                pcm.floatChannelData![channel][sample] = Float(sin(Double(i * samplesPerFrame + sample) * 2 * .pi * 440 / 48000) * 0.1)
            } }
            ingest.offer(.audio(pcm, AVAudioTime(sampleTime: Int64((start * 48000).rounded()) + Int64(i * samplesPerFrame), atRate: 48000)))
            let remaining = start + Double(i + 1) / 60 - CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            for value in decoded.ingest.drain() {
                switch value {
                case .video(let sample):
                    videos += 1
                    let pts = sample.presentationTimeStamp.seconds
                    if let lastVideoPTS { XCTAssertGreaterThan(pts, lastVideoPTS, "Host-scheduled pictures must stay in presentation order") }
                    if firstVideoPTS == nil { firstVideoPTS = pts }; lastVideoPTS = pts
                    let dimensions = CMVideoFormatDescriptionGetDimensions(try XCTUnwrap(sample.formatDescription))
                    XCTAssertEqual(dimensions.width, 1920); XCTAssertEqual(dimensions.height, 1080)
                case .audio(let buffer, let when):
                    audios += 1; XCTAssertGreaterThan(buffer.frameLength, 0)
                    XCTAssertEqual(when.sampleRate, buffer.format.sampleRate, "Decoded audio needs a usable clock for HDMI playback")
                    if audios > 10, let channel = buffer.floatChannelData?[0] {
                        if let previousEnd {
                            let gap = when.sampleTime - previousEnd
                            maxTimestampGap = max(maxTimestampGap, abs(gap))
                        }
                        previousEnd = when.sampleTime + Int64(buffer.frameLength)
                        for i in 0..<Int(buffer.frameLength) {
                            let value = channel[i]
                            energy += Double(value * value); audioSamples += 1
                            if let previous { maxJump = max(maxJump, abs(value - previous)) }; previous = value
                        }
                    }
                }
            }
        }
        ingest.finish(); decoded.ingest.finish()
        await sender.close(); await receiver.close()
        print("SRT 1080p60 motion loopback: decoded=\(videos)/\(frameCount)")
        // Cold hardware-codec startup and current machine load affect frame
        // counts. Report throughput, but assert delivery/ordering rather than
        // making the functional suite depend on a wall-clock performance floor.
        XCTAssertGreaterThan(videos, 5, "Decoded H.264 frames must cross the real encrypted SRT socket")
        XCTAssertGreaterThan((lastVideoPTS ?? 0) - (firstVideoPTS ?? 0), 1, "Video must continue beyond startup")
        XCTAssertGreaterThan(audios, 5, "AAC audio must cross the same MPEG-TS stream")
        let rms = sqrt(energy / Double(max(1, audioSamples)))
        print("SRT audio quality: samples=\(audioSamples) rms=\(rms) maxJump=\(maxJump) timestampGap=\(maxTimestampGap)")
        XCTAssertGreaterThan(audioSamples, 24000)
        XCTAssertGreaterThan(rms, 0.05); XCTAssertLessThan(rms, 0.09)
        XCTAssertLessThan(maxJump, 0.02, "AAC transport must preserve the waveform across packet boundaries")
        XCTAssertLessThanOrEqual(maxTimestampGap, 2, "Decoded packet timestamps must form a continuous audio clock")
        let connected = await sender.isConnected(); XCTAssertFalse(connected)
    }

    func testWaitingListenerCanStopAndRebindWithoutASender() async throws {
        var settings = SRTMediaSettings(); settings.port = Int.random(in: 24000...49000); settings.host = "127.0.0.1"
        let receiver = SRTMediaSession(), output = SRTMediaDecodedOutput()
        let waiting = Task { try await receiver.receive(settings: settings, passphrase: "cancel-listener-123", output: output) }
        try await Task.sleep(nanoseconds: 200_000_000)
        await receiver.close()
        do { try await waiting.value; XCTFail("A stopped listener must fail its pending accept") } catch {}
        let replacement = SRTMediaSession(), sender = SRTMediaSession()
        let next = Task { try await replacement.receive(settings: settings, passphrase: "cancel-listener-123", output: output) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let ingest = SRTMediaIngest()
        try await sender.publish(settings: settings, passphrase: "cancel-listener-123", ingest: ingest)
        try await next.value
        // This receiver has no incoming frames: stopping it must still close the
        // blocking receive and release its port promptly.
        await replacement.close(); ingest.finish(); await sender.close()
    }

    func testLargeAACPacketsDoNotAbortTheDecoder() throws {
        let codec = AudioCodec(); codec.settings.format = .pcm; codec.startRunning()
        defer { codec.stopRunning() }
        // These structurally valid frames deliberately have invalid AAC payloads.
        // The codec may reject their contents, but must never abort while sizing
        // either the source buffer or the converter's cached input buffer.
        for count in [1343, 2048, 8184, 8] {
            let frame = adts(Data(repeating: 0, count: count))
            codec.append(try audioSample([frame], at: 0.1))
        }
        XCTAssertTrue(codec.isRunning)
    }

    func testRepeatedSessionRetirementDoesNotShutDownAnotherConnection() async throws {
        var settings = SRTMediaSettings(); settings.host = "127.0.0.1"; settings.latency = 40
        settings.port = Int.random(in: 24000...49000)
        let receiver = SRTMediaSession(), sender = SRTMediaSession(), output = SRTMediaDecodedOutput(), ingest = SRTMediaIngest()
        let waiting = Task { try await receiver.receive(settings: settings, passphrase: "session-lifetime-123", output: output) }
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            try await sender.publish(settings: settings, passphrase: "session-lifetime-123", ingest: ingest)
            try await waiting.value
            for _ in 0..<32 { let retired = SRTMediaSession(); await retired.close() }
            // Give the native garbage collector time to retire closed sockets.
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let connected = await sender.isConnected(), receiving = await receiver.isConnected()
            XCTAssertTrue(connected); XCTAssertTrue(receiving)
        } catch {
            ingest.finish(); output.ingest.finish(); await sender.close(); await receiver.close(); waiting.cancel()
            throw error
        }
        ingest.finish(); output.ingest.finish(); await sender.close(); await receiver.close()
    }

    func testRealLargeAACFramesDecodeAcrossTheWholeInputBufferPool() async throws {
        let packets = try encodedAAC(highEntropy: true)
        XCTAssertTrue(packets.contains { $0.count > 1024 }, "Exercise valid AAC packets that caused the fixed-size buffer crash")
        XCTAssertGreaterThan(packets.count, 24)
        let codec = AudioCodec(); codec.settings.format = .pcm
        let output = codec.outputStream
        codec.startRunning()
        for (index, packet) in packets.enumerated() {
            codec.append(try audioSample([adts(packet)], at: 0.1 + Double(index) * 1024 / 48000))
        }
        codec.stopRunning()
        var decoded = 0
        for await (buffer, when) in output {
            XCTAssertEqual((buffer as? AVAudioPCMBuffer)?.frameLength, 1024)
            XCTAssertEqual(when.sampleRate, 48000)
            XCTAssertEqual(Double(when.sampleTime) / when.sampleRate, 0.1 + Double(decoded) * 1024 / 48000, accuracy: 1.0 / 48000)
            decoded += 1
        }
        XCTAssertEqual(decoded, packets.count, "Large packets must be decoded, not silently discarded")
    }

    func testCompressedAudioCopyChecksCapacityAndCopiesEveryPacketDescription() throws {
        let format = try aacFormat()
        let source = AVAudioCompressedBuffer(format: format, packetCapacity: 2, maximumPacketSize: 1024)
        source.packetCount = 2; source.byteLength = 1343
        source.packetDescriptions?[0] = .init(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 600)
        source.packetDescriptions?[1] = .init(mStartOffset: 600, mVariableFramesInPacket: 0, mDataByteSize: 743)
        memset(source.data, 42, Int(source.byteLength))
        let small = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 1024)
        XCTAssertFalse(small.copy(source)); XCTAssertEqual(small.byteLength, 0)
        let target = AVAudioCompressedBuffer(format: format, packetCapacity: 2, maximumPacketSize: 1024)
        XCTAssertTrue(target.copy(source)); XCTAssertEqual(target.byteLength, 1343)
        XCTAssertEqual(target.packetDescriptions?[1].mStartOffset, 600)
        XCTAssertEqual(target.packetDescriptions?[1].mDataByteSize, 743)
        XCTAssertEqual(target.data.load(fromByteOffset: 1342, as: UInt8.self), 42)
        source.packetDescriptions?[1].mStartOffset = 1344
        XCTAssertFalse(target.copy(source), "Invalid packet ranges must not touch destination storage")
    }

    func testADTSReaderStopsOnMalformedOrIncompleteFrames() {
        let valid = adts(Data(repeating: 0, count: 20))
        let reader = ADTSReader()
        for data in [Data([0xFF]), Data(repeating: 0, count: 7), Data(valid.dropLast()),
                     Data([0xFF, 0xF1, 0x4C, 0x80, 0, 0x1F, 0xFC])] {
            reader.read(data); XCTAssertEqual(Array(reader), [])
        }
        reader.read(valid + Data([0xFF])); XCTAssertEqual(Array(reader), [valid.count])
        let crc = adts(Data(repeating: 0, count: 20), crc: true)
        reader.read(valid + crc); XCTAssertEqual(Array(reader), [valid.count, crc.count])
    }

    func testDecodedAACHasAdvancingTimestampsAndSkipsCRCHeaders() async throws {
        let packets = try encodedAAC()
        XCTAssertGreaterThan(packets.count, 3)
        let frames = packets.prefix(3).enumerated().map { adts($0.element, crc: $0.offset == 1) }
        let codec = AudioCodec(); codec.settings.format = .pcm
        let output = codec.outputStream
        codec.startRunning(); codec.append(try audioSample(frames, at: 0.1)); codec.stopRunning()
        var timestamps: [Double] = []
        for await (buffer, when) in output {
            XCTAssertEqual(when.sampleRate, 48000)
            XCTAssertEqual((buffer as? AVAudioPCMBuffer)?.frameLength, 1024)
            timestamps.append(Double(when.sampleTime) / when.sampleRate)
        }
        XCTAssertEqual(timestamps.count, 3)
        for (index, pts) in timestamps.enumerated() {
            XCTAssertEqual(pts, 0.1 + Double(index) * 1024 / 48000, accuracy: 1.0 / 48000)
        }
        let sampleOnly = AVAudioTime(sampleTime: 9600, atRate: 48000)
        XCTAssertEqual(sampleOnly.makeTime().seconds, 0.2, accuracy: 0.000001)
    }

    private func aacFormat() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]))
    }
    private func encodedAAC(highEntropy: Bool = false) throws -> [Data] {
        let pcmFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let converter = try XCTUnwrap(AVAudioConverter(from: pcmFormat, to: try aacFormat()))
        converter.bitRate = highEntropy ? converter.applicableEncodeBitRates?.map(\.intValue).max() ?? 320000 : 192000
        var packets: [Data] = [], random: UInt32 = 12345
        for index in 0..<(highEntropy ? 64 : 16) {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1024)); pcm.frameLength = 1024
            for channel in 0..<2 { for i in 0..<1024 {
                if highEntropy {
                    random = random &* 1664525 &+ 1013904223
                    pcm.floatChannelData![channel][i] = index < 10 ? 0 : Float(Int32(bitPattern: random)) / Float(Int32.max) * 0.8
                } else {
                    pcm.floatChannelData![channel][i] = Float(sin(Double(index * 1024 + i) * 2 * .pi * 440 / 48000)) * 0.2
                }
            } }
            let encoded = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 1, maximumPacketSize: 8192)
            var supplied = false, error: NSError?
            _ = converter.convert(to: encoded, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return pcm
            }
            if let error { throw error }
            if encoded.byteLength > 0 { packets.append(Data(bytes: encoded.data, count: Int(encoded.byteLength))) }
        }
        return packets
    }
    private func adts(_ payload: Data, crc: Bool = false) -> Data {
        let length = payload.count + (crc ? 9 : 7)
        var result = Data([0xFF, crc ? 0xF0 : 0xF1, 0x4C, 0x80 | UInt8(length >> 11),
            UInt8((length >> 3) & 0xFF), UInt8((length & 7) << 5) | 0x1F, 0xFC])
        if crc { result.append(contentsOf: [0, 0]) }
        result.append(payload); return result
    }
    private func audioSample(_ frames: [Data], at pts: Double) throws -> CMSampleBuffer {
        let data = frames.reduce(into: Data()) { $0.append($1) }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block), noErr)
        let bytes = try XCTUnwrap(block)
        XCTAssertEqual(data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bytes,
            offsetIntoDestination: 0, dataLength: data.count) }, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1024, timescale: 48000),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90000), decodeTimeStamp: .invalid)
        var sizes = frames.map(\.count), sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bytes,
            formatDescription: try aacFormat().formatDescription, sampleCount: frames.count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: sizes.count,
            sampleSizeArray: &sizes, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func frame(at pts: Double, patternSeed: UInt32? = nil) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 72, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let data = CVPixelBufferGetBaseAddress(image) {
            if let patternSeed {
                // Translate a detailed image. Unrelated random pixels every
                // frame exercise bitrate-control frame dropping instead of
                // representative sustained presentation-video throughput.
                for y in 0..<72 {
                    let row = data.advanced(by: y * CVPixelBufferGetBytesPerRow(image)).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<128 {
                        let position = UInt32(y * 128 + (x + Int(patternSeed)) % 128)
                        let random = position &* 1664525 &+ 1013904223
                        row[x] = 0xFF000000 | (random & 0xFFFFFF)
                    }
                }
            } else { memset(data, 80, CVPixelBufferGetBytesPerRow(image) * 72) }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: patternSeed == nil ? 50 : 60),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &buffer)
        return try XCTUnwrap(buffer)
    }
}

private final class BackpressuredMediaDisplayLayer: AVSampleBufferDisplayLayer {
    var received: [CMSampleBuffer] = []
    var flushes = 0
    var clears = 0
    override var isReadyForMoreMediaData: Bool { false }
    override func enqueue(_ sampleBuffer: CMSampleBuffer) { received.append(sampleBuffer) }
    override func flush() { flushes += 1 }
    override func flushAndRemoveImage() { clears += 1 }
}

private actor TestVideoEncoder {
    private let codec = VideoCodec()
    func encode(_ frames: [CMSampleBuffer]) -> AsyncStream<CMSampleBuffer> {
        codec.settings = .init(videoSize: .init(width: 128, height: 72),
            allowFrameReordering: false, isLowLatencyRateControlEnabled: true)
        let output = codec.outputStream
        codec.startRunning()
        frames.forEach { codec.append($0) }
        return output
    }
    func stop() { codec.stopRunning() }
}

@MainActor
private final class PlaybackFixture {
    let engine = AVAudioEngine()
    let captured = PlaybackSamples()
    let playback: SRTMediaPlayback
    private let format: AVAudioFormat
    var errors: [String] = []
    init(playoutDelay: Double = 0.08) throws {
        format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let hardware = engine.outputNode.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw XCTSkip("No audio output device") }
        let mixer = engine.mainMixerNode, silencer = AVAudioMixerNode()
        engine.attach(silencer)
        engine.connect(mixer, to: silencer, format: hardware)
        engine.connect(silencer, to: engine.outputNode, format: hardware)
        // Observe real device-clock rendering without playing a test tone aloud.
        silencer.outputVolume = 0
        let captured = captured
        mixer.installTap(onBus: 0, bufferSize: 512, format: hardware) { buffer, _ in captured.append(buffer) }
        playback = SRTMediaPlayback(engine: engine, playoutDelay: playoutDelay)
        playback.onError = { [weak self] in self?.errors.append($0) }
    }
    func offer(packet: Int, timestamp: Int64? = nil) throws {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)); pcm.frameLength = 1024
        for channel in 0..<2 { for sample in 0..<1024 {
            pcm.floatChannelData![channel][sample] = Float(sin(Double(packet * 1024 + sample) * 2 * .pi * 440 / 48000)) * 0.1
        } }
        playback.consume(.audio(pcm, AVAudioTime(sampleTime: timestamp ?? Int64(240000 + packet * 1024), atRate: 48000)))
    }
    func stop() { playback.reset(); engine.mainMixerNode.removeTap(onBus: 0) }
}

private final class PlaybackSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []
    var samples: [Float] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        lock.lock(); values.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))); lock.unlock()
    }
}
