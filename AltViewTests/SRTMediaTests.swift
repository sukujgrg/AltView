import XCTest
import AVFoundation
import AppKit
@testable import AltView
@testable import HaishinKit
@testable import SRTHaishinKit

@MainActor
final class SRTMediaTests: XCTestCase {
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
        settings.port = Int.random(in: 24000...49000); settings.latency = 40
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
    init() throws {
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
        playback = SRTMediaPlayback(engine: engine)
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
