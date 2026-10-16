import XCTest
import AVFoundation
import AppKit
@testable import AltView
@testable import HaishinKit
@testable import SRTHaishinKit

@MainActor
final class SRTMediaTests: XCTestCase {
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
        var videos = 0, audios = 0
        for i in 0..<100 {
            let pts = start + Double(i) * 0.02
            ingest.offer(.video(try frame(at: pts)))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)); pcm.frameLength = 960
            for channel in 0..<2 { for sample in 0..<960 { pcm.floatChannelData![channel][sample] = Float(sin(Double(i * 960 + sample) * 2 * .pi * 440 / 48000) * 0.1) } }
            ingest.offer(.audio(pcm, AVAudioTime(sampleTime: Int64(pts * 48000), atRate: 48000)))
            try await Task.sleep(nanoseconds: 20_000_000)
            for value in decoded.ingest.drain() {
                switch value {
                case .video(let sample):
                    videos += 1
                    let dimensions = CMVideoFormatDescriptionGetDimensions(try XCTUnwrap(sample.formatDescription))
                    XCTAssertEqual(dimensions.width, 1920); XCTAssertEqual(dimensions.height, 1080)
                case .audio(let buffer, let when):
                    audios += 1; XCTAssertGreaterThan(buffer.frameLength, 0)
                    XCTAssertEqual(when.sampleRate, buffer.format.sampleRate, "Decoded audio needs a usable clock for HDMI playback")
                }
            }
        }
        ingest.finish(); decoded.ingest.finish()
        await sender.close(); await receiver.close()
        XCTAssertGreaterThan(videos, 5, "Decoded H.264 frames must cross the real encrypted SRT socket")
        XCTAssertGreaterThan(audios, 5, "AAC audio must cross the same MPEG-TS stream")
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

    private func frame(at pts: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 72, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let data = CVPixelBufferGetBaseAddress(image) { memset(data, 80, CVPixelBufferGetBytesPerRow(image) * 72) }
        CVPixelBufferUnlockBaseAddress(image, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 50),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &buffer)
        return try XCTUnwrap(buffer)
    }
}
