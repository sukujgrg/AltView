import XCTest
@testable import AltView

final class ProtocolTests: XCTestCase {
    func testContentTemplateIsOptionalAndTravelsWithEachSnapshot() throws {
        let decoder = JSONDecoder()
        for value in [#"{"body":"Text","visible":true}"#, #"{"body":"Text","visible":true,"template":null}"#] {
            XCTAssertNil(try decoder.decode(DisplayContent.self, from: Data(value.utf8)).template)
        }
        for preset in ContentTemplate.builtIns + [ContentTemplate(rawValue: "speaker-intro")] {
            let content = DisplayContent(title: "Reference", body: "Text", footer: "Translation", template: preset)
            let message = WireMessage(kind: .state, lease: UUID(), revision: 1, content: content)
            var frames = FrameDecoder()
            XCTAssertEqual(try frames.append(FrameCodec.encode(message)), [message])
        }
        for value in [#"{"body":"Text","visible":true,"template":""}"#, #"{"body":"Text","visible":true,"template":42}"#,
                      #"{"body":"Text","visible":true,"template":"bad id"}"#] {
            XCTAssertThrowsError(try decoder.decode(DisplayContent.self, from: Data(value.utf8)))
        }
    }

    func testTemplateCatalogueRoundTripAcceptsFutureIDsAndValidatesBounds() throws {
        let future = TemplateDescriptor(id: ContentTemplate(rawValue: "speaker-intro"), name: "Speaker introduction")
        let templates = TemplateDescriptor.builtIns + [future]
        for kind: WireMessage.Kind in [.welcome, .feedback] {
            let message = WireMessage(kind: kind, receiverID: UUID(), outputReadiness: .closed,
                                      templates: templates, templatePolicy: .fixed(future.id))
            var frames = FrameDecoder()
            XCTAssertEqual(try frames.append(FrameCodec.encode(message)), [message])
        }
        XCTAssertTrue(TemplateCapabilities(templates: templates, policy: .fixed(future.id)).isValid)
        XCTAssertTrue(TemplateCapabilities().isValid)
        XCTAssertTrue(TemplateCapabilities(templates: [], policy: .custom).isValid)
        for invalid in [
            TemplateCapabilities(templates: [future, future]),
            TemplateCapabilities(templates: [TemplateDescriptor(id: future.id, name: " \n")]),
            TemplateCapabilities(templates: [TemplateDescriptor(id: future.id, name: String(repeating: "x", count: 129))]),
            TemplateCapabilities(templates: (0...64).map { TemplateDescriptor(id: ContentTemplate(rawValue: "id-\($0)"), name: "Name") }),
            TemplateCapabilities(templates: templates, policy: TemplatePolicy(mode: .fixed)),
            TemplateCapabilities(templates: [], policy: .fixed(.lyrics)),
            TemplateCapabilities(templates: templates, policy: TemplatePolicy(mode: .sender, template: .lyrics)),
            TemplateCapabilities(policy: .custom)
        ] { XCTAssertFalse(invalid.isValid) }
        for id in ["", "bad id", String(repeating: "x", count: 65)] {
            XCTAssertFalse(DisplayContent(body: "Text", template: ContentTemplate(rawValue: id)).isValid)
        }
    }

    func testLegacyAndUnavailableTemplateFallbackKeepsTextAndDesiredChoice() {
        let requested = DisplayContent(title: "Title", body: "Body", footer: "Footer", visible: false, emptyRegions: .reserve, template: .lyrics)
        var unmarked = requested; unmarked.template = nil
        for capabilities in [TemplateCapabilities(), TemplateCapabilities(templates: [])] {
            XCTAssertEqual(capabilities.contentForSending(requested), unmarked)
            XCTAssertFalse(capabilities.detail(requested: requested.template).isEmpty)
        }
        let available = TemplateCapabilities(templates: TemplateDescriptor.builtIns, policy: .custom)
        XCTAssertEqual(available.contentForSending(requested), requested, "Receiver override must not erase the requested choice")
        XCTAssertTrue(available.detail(requested: .lyrics).contains("overrides"))
        let unknown = DisplayContent(body: "Body", template: ContentTemplate(rawValue: "future-template"))
        XCTAssertNil(LowerThirdTemplate().selectedContentTemplate(for: unknown), "A removed or unknown ID uses custom layout on this receiver")
        XCTAssertEqual(unknown.template?.rawValue, "future-template")
    }

    func testFeedbackStaysBoundedAndYieldsToSnapshotsAndControls() throws {
        var outbox = MessageOutbox()
        let lease = UUID()
        for revision in 1...10_000 {
            try outbox.enqueue(WireMessage(kind: .feedback, lease: lease, revision: UInt64(revision), outputReadiness: .ready))
        }
        try outbox.enqueue(WireMessage(kind: .state, revision: 1))
        try outbox.enqueue(WireMessage(kind: .ownership))
        XCTAssertEqual(outbox.count, 3)
        XCTAssertEqual(outbox.next()?.kind, .ownership)
        XCTAssertEqual(outbox.next()?.kind, .state)
        let feedback = try XCTUnwrap(outbox.next())
        XCTAssertEqual(feedback.revision, 10_000)
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.append(FrameCodec.encode(feedback)), [feedback])
        XCTAssertNil(outbox.next())
    }
    func testAcknowledgementsAreLeaseScopedAndTimeoutNeverStopsNewSnapshots() {
        let lease = UUID()
        var feedback = DeliveryFeedback()
        feedback.sent(1, now: 0)
        feedback.sent(2, now: 1)
        feedback.receive(WireMessage(kind: .feedback, lease: UUID(), revision: 2, outputReadiness: .closed), lease: lease, now: 2)
        XCTAssertEqual(feedback.acceptedRevision, 0)
        XCTAssertEqual(feedback.output, .closed)
        feedback.receive(WireMessage(kind: .feedback, lease: lease, revision: 3, outputReadiness: .ready), lease: lease, now: 3)
        XCTAssertEqual(feedback.acceptedRevision, 0, "A future revision cannot acknowledge unsent text")
        XCTAssertTrue(feedback.checkTimeout(now: 6))
        XCTAssertTrue(feedback.overdue)
        feedback.sent(10, now: 7)
        XCTAssertEqual(feedback.sentRevision, 10, "Feedback never gates new snapshots")
        feedback.receive(WireMessage(kind: .feedback, lease: lease, revision: 10, outputReadiness: .ready), lease: lease, now: 8)
        XCTAssertTrue(feedback.accepted)
        XCTAssertFalse(feedback.overdue)
        feedback.receive(WireMessage(kind: .feedback, lease: lease, revision: 1, outputReadiness: .preview), lease: lease, now: 9)
        XCTAssertEqual(feedback.acceptedRevision, 10)
        feedback.resetSnapshot()
        XCTAssertFalse(feedback.accepted)
        XCTAssertEqual(feedback.output, .preview, "Release keeps display information")
        XCTAssertFalse(feedback.checkTimeout(now: 100))
    }

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
