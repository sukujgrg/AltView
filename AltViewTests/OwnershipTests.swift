import XCTest
@testable import AltView

final class OwnershipTests: XCTestCase {
    func testExplicitHandoverRejectsOldSenderAndOldLease() throws {
        var state = ReceiverState()
        let a = UUID(), b = UUID()
        XCTAssertTrue(state.register(connection: a, senderID: UUID(), name: "A"))
        XCTAssertTrue(state.register(connection: b, senderID: UUID(), name: "B"))
        let oldLease = try XCTUnwrap(state.take(connection: a))
        XCTAssertTrue(state.apply(connection: a, lease: oldLease, revision: 1, content: .scripture))
        let bLease = try XCTUnwrap(state.take(connection: b))
        XCTAssertEqual(state.content, .empty)
        XCTAssertFalse(state.apply(connection: a, lease: oldLease, revision: 2, content: .lyrics))
        XCTAssertFalse(state.release(connection: a, lease: oldLease))
        XCTAssertTrue(state.apply(connection: b, lease: bLease, revision: 1, content: .lyrics))
        let newLease = try XCTUnwrap(state.take(connection: a))
        XCTAssertNotEqual(newLease, oldLease)
        XCTAssertFalse(state.apply(connection: a, lease: oldLease, revision: 100, content: .scripture))
    }
    func testStaleAndDuplicateSnapshotsCannotUndoBlank() throws {
        var state = ReceiverState()
        let a = UUID()
        XCTAssertTrue(state.register(connection: a, senderID: UUID(), name: "A"))
        let lease = try XCTUnwrap(state.take(connection: a))
        XCTAssertTrue(state.apply(connection: a, lease: lease, revision: 10, content: .scripture))
        var blank = DisplayContent.scripture; blank.visible = false
        XCTAssertTrue(state.apply(connection: a, lease: lease, revision: 11, content: blank))
        XCTAssertFalse(state.apply(connection: a, lease: lease, revision: 10, content: .scripture))
        XCTAssertFalse(state.apply(connection: a, lease: lease, revision: 11, content: .scripture))
        XCTAssertEqual(state.content, blank)
    }
    func testDisconnectOnlyClearsOwningConnection() throws {
        var state = ReceiverState()
        let a = UUID(), b = UUID()
        XCTAssertTrue(state.register(connection: a, senderID: UUID(), name: "A"))
        XCTAssertTrue(state.register(connection: b, senderID: UUID(), name: "B"))
        let lease = try XCTUnwrap(state.take(connection: a))
        XCTAssertTrue(state.apply(connection: a, lease: lease, revision: 1, content: .scripture))
        state.disconnect(b)
        XCTAssertEqual(state.content, .scripture)
        state.disconnect(a)
        XCTAssertEqual(state.content, .empty)
        XCTAssertNil(state.owner)
    }
    func testUnidentifiedAndInvalidSendersCannotControl() {
        var state = ReceiverState()
        let id = UUID()
        XCTAssertNil(state.take(connection: id))
        XCTAssertFalse(state.register(connection: id, senderID: UUID(), name: "  "))
        XCTAssertTrue(state.register(connection: id, senderID: UUID(), name: "A"))
        XCTAssertFalse(state.register(connection: id, senderID: UUID(), name: "B"))
    }
    func testSameSenderIdentityOnTwoSocketsDoesNotShareLease() throws {
        var state = ReceiverState()
        let id = UUID(), a = UUID(), b = UUID()
        XCTAssertTrue(state.register(connection: a, senderID: id, name: "A"))
        XCTAssertTrue(state.register(connection: b, senderID: id, name: "A"))
        let lease = try XCTUnwrap(state.take(connection: a))
        XCTAssertFalse(state.apply(connection: b, lease: lease, revision: 1, content: .scripture))
    }
    func testReconnectCannotStealOutputAfterAnotherSenderTakesIt() {
        var state = ReceiverState()
        let a = UUID(), b = UUID()
        XCTAssertTrue(state.register(connection: a, senderID: UUID(), name: "Returning sender"))
        XCTAssertTrue(state.register(connection: b, senderID: UUID(), name: "Current sender"))
        let lease = state.take(connection: b)!
        XCTAssertTrue(state.apply(connection: b, lease: lease, revision: 1, content: .lyrics))
        XCTAssertNil(state.take(connection: a, onlyIfUnowned: true))
        XCTAssertEqual(state.content, .lyrics)
        state.clearOwner()
        XCTAssertNotNil(state.take(connection: a, onlyIfUnowned: true))
    }
}
