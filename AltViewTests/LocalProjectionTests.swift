import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import ScreenCaptureKit
import XCTest
@testable import AltView

@MainActor
final class LocalProjectionTests: XCTestCase {
    private func presentation(_ mode: ProjectionPresentation.Mode = .media) -> ProjectionPresentation {
        .init(sessionID: UUID(), mode: mode, windowID: 77, windowGeneration: UUID())
    }
    func testMediaSharesOwnershipAndRejectsStaleUpdates() throws {
        var state = ReceiverState()
        let connection = UUID(), other = UUID()
        XCTAssertTrue(state.register(connection: connection, senderID: UUID(), name: "Eucaly"))
        XCTAssertTrue(state.register(connection: other, senderID: UUID(), name: "Other"))
        let lease = try XCTUnwrap(state.take(connection: connection))
        let media = DisplayContent(visible: false, projection: presentation())
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 1, content: media, supportsProjection: true))
        XCTAssertNotNil(state.confidenceMedia)
        XCTAssertEqual(state.confidenceContent, .empty)
        XCTAssertNil(state.confidenceMedia?.process, "A remote/unverified sender cannot supply a capture source")
        XCTAssertFalse(state.apply(connection: connection, lease: lease, revision: 1, content: .lyrics, supportsProjection: true))
        XCTAssertFalse(state.apply(connection: other, lease: lease, revision: 2, content: .lyrics, supportsProjection: true))
        XCTAssertEqual(state.confidenceMedia?.presentation, media.projection)
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 2,
            content: DisplayContent(body: "Primary", confidence: .init(body: "Primary"), projection: presentation(.lyrics)),
            supportsProjection: true))
        XCTAssertNil(state.confidenceMedia); XCTAssertEqual(state.confidenceContent.body, "Primary")
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 3, content: media, supportsProjection: true))
        _ = state.take(connection: other)
        XCTAssertNil(state.confidenceMedia)
        XCTAssertFalse(state.apply(connection: connection, lease: lease, revision: 4, content: media, supportsProjection: true))
    }
    func testClearReleaseDisconnectAndUnsupportedExtensionClearMedia() throws {
        for action in 0..<4 {
            var state = ReceiverState(); let connection = UUID()
            XCTAssertTrue(state.register(connection: connection, senderID: UUID(), name: "Eucaly"))
            let lease = try XCTUnwrap(state.take(connection: connection))
            XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 1,
                content: .init(visible: false, projection: presentation()), supportsProjection: true))
            switch action {
            case 0: _ = state.apply(connection: connection, lease: lease, revision: 2, content: .empty, supportsProjection: true)
            case 1: _ = state.release(connection: connection, lease: lease)
            case 2: state.disconnect(connection)
            default: _ = state.apply(connection: connection, lease: lease, revision: 2,
                content: .init(body: "Legacy", projection: presentation()), supportsProjection: false)
            }
            XCTAssertNil(state.confidenceMedia)
        }
    }
    func testIdentityValidationAndWireCompatibility() throws {
        let process = try XCTUnwrap(LocalProjectionProcess.current)
        XCTAssertTrue(process.isLiveLocalProcess)
        XCTAssertFalse(LocalProjectionProcess(processID: process.processID, startTime: process.startTime + 1, bootMarker: process.bootMarker).isLiveLocalProcess)
        XCTAssertFalse(LocalProjectionProcess(processID: process.processID, startTime: process.startTime, bootMarker: String(repeating: "0", count: 64)).isLiveLocalProcess)
        let content = DisplayContent(visible: false, projection: presentation())
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.append(FrameCodec.encode(.init(kind: .state, content: content))).first?.content, content)
        var invalid = content; invalid.projection?.windowGeneration = nil
        XCTAssertFalse(invalid.isValid)
        let legacy = try JSONDecoder().decode(DisplayContent.self, from: Data(#"{"body":"Legacy","visible":true}"#.utf8))
        XCTAssertNil(legacy.projection)
    }
    func testLocalIdentityFailuresStayDistinctAndNeverVerifyChangedProcesses() throws {
        let process = try XCTUnwrap(LocalProjectionProcess.current)
        XCTAssertNil(process.sourceIssue())
        XCTAssertEqual(process.sourceIssue(localMarker: nil), .bootMismatch)
        XCTAssertEqual(process.sourceIssue(localMarker: String(repeating: "0", count: 64)), .bootMismatch)
        XCTAssertEqual(process.sourceIssue(readStartTime: { _ in nil }), .processUnavailable)
        XCTAssertEqual(process.sourceIssue(readStartTime: { _ in process.startTime + 1 }), .processChanged)
        XCTAssertEqual(LocalProjectionProcess(processID: 0, startTime: 0, bootMarker: "").sourceIssue(), .invalidIdentity)
    }
    func testLocalVerificationRefreshCannotReplaceAnAcceptedOwnerOrReport() throws {
        var state = ReceiverState()
        let connection = UUID(), other = UUID(), process = try XCTUnwrap(LocalProjectionProcess.current)
        XCTAssertTrue(state.register(connection: connection, senderID: UUID(), name: "Eucaly"))
        XCTAssertTrue(state.register(connection: other, senderID: UUID(), name: "Other"))
        let lease = try XCTUnwrap(state.take(connection: connection))
        let report = presentation()
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 1,
                                  content: .init(visible: false, projection: report), supportsProjection: true,
                                  sourceIssue: .processUnavailable))
        XCTAssertFalse(state.refreshMediaSource(connection: other, process: process, sourceIssue: nil))
        XCTAssertTrue(state.refreshMediaSource(connection: connection, process: process, sourceIssue: nil))
        XCTAssertEqual(state.confidenceMedia?.presentation, report); XCTAssertEqual(state.confidenceMedia?.revision, 1)
        XCTAssertFalse(state.refreshMediaSource(connection: connection, process: process, sourceIssue: nil))
        _ = state.take(connection: other)
        XCTAssertFalse(state.refreshMediaSource(connection: connection, process: process, sourceIssue: nil))
        XCTAssertNil(state.confidenceMedia)
    }
}
