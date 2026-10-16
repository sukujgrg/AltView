import XCTest
@testable import AltView

// Legacy wire fields remain readable for existing senders; the retired
// Confidence UI and clock are no longer instantiated.
@MainActor
final class ConfidenceTests: XCTestCase {
    func testSecondaryConfidenceRoundTripsAndRejectsOversizedFields() throws {
        let confidence = ConfidenceText(title: "John 3:16", body: "Primary", footer: "NIV", secondary: .init(body: "Secondary", footer: "NLT"))
        let content = DisplayContent(body: "Audience primary", confidence: confidence)
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.append(FrameCodec.encode(.init(kind: .state, content: content))).first?.content, content)
        let single = ConfidenceText(title: "John 3:16", body: "Primary", footer: "NIV")
        XCTAssertNil(try JSONDecoder().decode(ConfidenceText.self, from: JSONEncoder().encode(single)).secondary)
        var oversized = content
        oversized.confidence?.secondary?.body = String(repeating: "é", count: 12_001)
        XCTAssertFalse(oversized.isValid)
        oversized.confidence?.secondary = .init(body: "Secondary", footer: String(repeating: "é", count: 513))
        XCTAssertFalse(oversized.isValid)
    }
    func testDualConfidenceSnapshotRetainsOnHideAndClearsOnRemovalAndTakeover() throws {
        var state = ReceiverState()
        let a = UUID(), b = UUID()
        XCTAssertTrue(state.register(connection: a, senderID: UUID(), name: "ViewTheWord"))
        XCTAssertTrue(state.register(connection: b, senderID: UUID(), name: "eucaly"))
        let lease = try XCTUnwrap(state.take(connection: a))
        let text = ConfidenceText(title: "John 3:16", body: "Primary", footer: "NIV", secondary: .init(body: "Secondary", footer: "NLT"))
        var content = DisplayContent(title: text.title, body: text.body, footer: text.footer, confidence: text)
        XCTAssertTrue(state.apply(connection: a, lease: lease, revision: 1, content: content))
        XCTAssertEqual(state.confidenceContent, text); XCTAssertEqual(state.content.body, "Primary")
        content.visible = false
        XCTAssertTrue(state.apply(connection: a, lease: lease, revision: 2, content: content))
        XCTAssertEqual(state.confidenceContent, text)
        content.confidence?.secondary = nil
        XCTAssertTrue(state.apply(connection: a, lease: lease, revision: 3, content: content))
        XCTAssertNil(state.confidenceContent.secondary)
        content.confidence = text
        XCTAssertTrue(state.apply(connection: a, lease: lease, revision: 4, content: content))
        XCTAssertEqual(state.confidenceContent, text, "Both translations are part of the complete Confidence snapshot")
        let second = try XCTUnwrap(state.take(connection: b))
        XCTAssertEqual(state.confidenceContent, .empty)
        XCTAssertFalse(state.apply(connection: a, lease: lease, revision: 5, content: content))
        XCTAssertTrue(state.apply(connection: b, lease: second, revision: 1, content: .lyrics))
        XCTAssertNil(state.confidenceContent.secondary)
    }
}
