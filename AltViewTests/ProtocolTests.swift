import XCTest
@testable import AltView

final class ProtocolTests: XCTestCase {
    func testFramingHandlesEveryByteBoundaryAndUnicode() throws {
        let message = WireMessage(kind: .state, lease: UUID(), revision: 12, content: .multilingual)
        let data = try FrameCodec.encode(message)
        var decoder = FrameDecoder()
        var received: [WireMessage] = []
        for byte in data { received += try decoder.append(Data([byte])) }
        XCTAssertEqual(received, [message])
    }
    func testMultipleFramesInOneRead() throws {
        let one = WireMessage(kind: .heartbeat)
        let two = WireMessage(kind: .take)
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.append(FrameCodec.encode(one) + FrameCodec.encode(two)), [one, two])
    }
    func testOversizedAndZeroLengthsAreRejectedBeforePayloadArrives() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF])))
        decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 0])))
    }
    func testMalformedJSONIsRejected() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 1, 0xFF])))
    }
    func testSlowSocketRetainsOnlyLatestSnapshot() throws {
        var outbox = MessageOutbox()
        for index in 1...10_000 {
            try outbox.enqueue(WireMessage(kind: .state, revision: UInt64(index)))
            try outbox.enqueue(WireMessage(kind: .heartbeat))
        }
        XCTAssertEqual(outbox.count, 2)
        XCTAssertEqual(outbox.next()?.revision, 10_000)
        XCTAssertEqual(outbox.next()?.kind, .heartbeat)
        XCTAssertNil(outbox.next())
    }
    func testControlQueueIsBoundedAndTakesPriority() throws {
        var outbox = MessageOutbox()
        try outbox.enqueue(WireMessage(kind: .state))
        for _ in 0..<16 { try outbox.enqueue(WireMessage(kind: .take)) }
        XCTAssertThrowsError(try outbox.enqueue(WireMessage(kind: .take)))
        XCTAssertEqual(outbox.next()?.kind, .take)
        outbox.clearState()
        XCTAssertNil(outbox.latestState)
    }
    func testMailboxStaysBoundedWhileConsumerIsBlocked() {
        let queue = DispatchQueue(label: "blocked-consumer")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let delivered = expectation(description: "latest value")
        var received: [Int] = []
        let mailbox = SnapshotMailbox<Int>(queue: queue) { value in received.append(value); delivered.fulfill() }
        let start = ProcessInfo.processInfo.systemUptime
        for value in 0...100_000 { mailbox.offer(value) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        gate.signal()
        wait(for: [delivered], timeout: 3)
        queue.sync { XCTAssertEqual(received, [100_000]) }
    }
    func testPairingRoundTripAndValidation() throws {
        for _ in 0..<100 {
            let key = try PairingKey.generate()
            let code = PairingKey.text(key)
            XCTAssertEqual(code.count, 9)
            XCTAssertEqual(Array(code)[4], "-")
            XCTAssertTrue(code.filter { $0 != "-" }.allSatisfy { "23456789ABCDEFGHJKLMNPQRSTUVWXYZ".contains($0) })
            XCTAssertTrue(PairingKey.isValid(key))
            XCTAssertEqual(PairingKey.parse(code), key)
        }
    }
    func testPairingCodeAcceptsTypingAndPasteFormatting() {
        let expected = Data("ABCD2345".utf8)
        XCTAssertEqual(PairingKey.parse("abcd2345"), expected)
        XCTAssertEqual(PairingKey.parse(" \tabcd-2345\n"), expected)
        XCTAssertEqual(PairingKey.parse("ABCD 2345"), expected)
        for invalid in ["", "123456", "ABCD234", "ABCD23456", "ABCD234!", "ABCD2340", "ABCD2341",
                        "ABCD234I", "ABCD234O", "ＡBCD2345", "ABCD234ß", String(repeating: "A", count: 64)] {
            XCTAssertNil(PairingKey.parse(invalid), "Accepted invalid code: \(invalid)")
        }
        XCTAssertFalse(PairingKey.isValid(Data("abcd2345".utf8)))
        XCTAssertFalse(PairingKey.isValid(Data(repeating: 0, count: 8)))
        XCTAssertFalse(PairingKey.isValid(Data(repeating: 0, count: 31)))
        XCTAssertFalse(PairingKey.isValid(Data(repeating: 0, count: 32)))
    }
    func testContentLimitsCountUTF8Bytes() {
        XCTAssertFalse(DisplayContent(body: String(repeating: "അ", count: 9_000)).isValid)
        XCTAssertTrue(DisplayContent.multilingual.isValid)
    }
    func testBodyOnlySnapshotDefaultsAndExplicitSpaceReservation() throws {
        let decoder = JSONDecoder()
        let bodyOnly = try decoder.decode(DisplayContent.self, from: Data(#"{"body":"Welcome","visible":true}"#.utf8))
        XCTAssertEqual(bodyOnly, DisplayContent(body: "Welcome"))
        let legacy = try decoder.decode(DisplayContent.self, from: Data(#"{"title":"Title","body":"Body","footer":"Footer","visible":false}"#.utf8))
        XCTAssertEqual(legacy.emptyRegions, .collapse)
        let reserved = try decoder.decode(DisplayContent.self, from: Data(#"{"body":"Welcome","visible":true,"emptyRegions":"reserve"}"#.utf8))
        XCTAssertEqual(reserved, DisplayContent(body: "Welcome", emptyRegions: .reserve))
        var frames = FrameDecoder()
        let message = WireMessage(kind: .state, lease: UUID(), revision: 1, content: reserved)
        XCTAssertEqual(try frames.append(FrameCodec.encode(message)), [message])
        for invalid in [#"{"visible":true}"#, #"{"body":"Body"}"#,
                        #"{"body":"Body","visible":true,"title":42}"#,
                        #"{"body":"Body","visible":true,"emptyRegions":"unknown"}"#] {
            XCTAssertThrowsError(try decoder.decode(DisplayContent.self, from: Data(invalid.utf8)))
        }
    }
}
