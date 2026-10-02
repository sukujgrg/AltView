import XCTest
@testable import AltView

final class TextComposerTests: XCTestCase {
    func testTemplateChoiceStaysPrivateAndHideKeepsThePublishedTemplate() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: DisplayContent(body: "Text", template: .scripture))
        composer.receive(SenderStatus(connected: true, ownsOutput: true))
        composer.show()
        composer.draft.template = .lyrics
        XCTAssertTrue(composer.hasUnpublishedChanges)
        composer.hide(); composer.showSubmitted()
        XCTAssertEqual(sender.snapshots.last?.template, .scripture)
        composer.show()
        XCTAssertEqual(sender.snapshots.last?.template, .lyrics)
        XCTAssertFalse(composer.hasUnpublishedChanges)
    }
    private final class Sender: TextSending {
        var snapshots: [DisplayContent] = []
        var takes = 0, releases = 0, disconnects = 0
        func submit(_ content: DisplayContent) { snapshots.append(content) }
        func takeOutput() { takes += 1 }
        func releaseOutput() { releases += 1 }
        func disconnect() { disconnects += 1 }
    }
    func testEmptyRowPreferenceStaysPrivateUntilPublishedAndHideKeepsPublishedChoice() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: DisplayContent(body: "Body"))
        composer.receive(SenderStatus(connected: true, ownsOutput: true))
        composer.show()
        composer.draft.emptyRegions = .reserve
        XCTAssertTrue(composer.hasUnpublishedChanges)
        XCTAssertEqual(sender.snapshots.last?.emptyRegions, .collapse)
        composer.hide()
        XCTAssertEqual(sender.snapshots.last?.emptyRegions, .collapse)
        composer.show()
        XCTAssertEqual(sender.snapshots.last?.emptyRegions, .reserve)
        XCTAssertFalse(composer.hasUnpublishedChanges)
    }
    func testFirstShowTakesOutputAndUpdatesDoNotTakeAgain() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: .scripture)
        composer.receive(SenderStatus(connected: true))
        XCTAssertFalse(composer.show())
        XCTAssertEqual(sender.takes, 1)
        XCTAssertEqual(sender.snapshots, [.scripture])
        XCTAssertFalse(composer.canShow, "Do not queue duplicate takes while waiting for a grant")
        composer.receive(SenderStatus(connected: true, ownsOutput: true))
        XCTAssertEqual(composer.primaryTitle, "Publish Text")
        composer.draft = .lyrics
        XCTAssertEqual(sender.snapshots, [.scripture], "Editing stays private")
        XCTAssertTrue(composer.hasUnpublishedChanges)
        composer.show()
        XCTAssertEqual(sender.takes, 1)
        XCTAssertEqual(sender.snapshots.last, .lyrics)
    }
    func testConnectionPublishesOnlyTheExplicitlyRequestedSnapshot() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: .scripture)
        XCTAssertTrue(composer.show())
        composer.draft = .lyrics
        XCTAssertTrue(sender.snapshots.isEmpty)
        composer.receive(SenderStatus(connected: true))
        XCTAssertEqual(sender.snapshots, [.scripture])
        XCTAssertTrue(composer.hasUnpublishedChanges)
    }
    func testHideDoesNotPublishUnsentEditsAndKeepsDraft() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: .scripture)
        composer.receive(SenderStatus(connected: true, ownsOutput: true))
        composer.show()
        composer.draft = .lyrics
        composer.hide()
        var hidden = DisplayContent.scripture; hidden.visible = false
        XCTAssertEqual(sender.snapshots.last, hidden)
        XCTAssertEqual(composer.draft, .lyrics)
        XCTAssertEqual(composer.primaryTitle, "Publish Text")
        composer.show()
        XCTAssertEqual(sender.snapshots.last, .lyrics)
        XCTAssertEqual(sender.takes, 0)
    }
    func testStopPreservesDraftAndReleasesOnlyOwnOutput() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: .scripture)
        composer.receive(SenderStatus(connected: true, ownsOutput: true))
        composer.stop()
        XCTAssertEqual(sender.releases, 1)
        XCTAssertEqual(composer.draft, .scripture)
        composer.receive(SenderStatus(connected: true, ownerName: "Another source"))
        composer.stop()
        XCTAssertEqual(sender.releases, 1)
    }
    func testShowingLastTextDoesNotPublishNewEditsOrTakeAnotherSource() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: .scripture)
        composer.receive(SenderStatus(connected: true, ownsOutput: true))
        composer.show()
        composer.draft = .lyrics
        composer.draft.emptyRegions = .reserve
        composer.hide()
        composer.showSubmitted()
        XCTAssertEqual(sender.snapshots.last, .scripture)
        XCTAssertTrue(composer.isVisible)
        XCTAssertTrue(composer.hasUnpublishedChanges)
        XCTAssertEqual(composer.draft.body, DisplayContent.lyrics.body)
        XCTAssertEqual(composer.draft.emptyRegions, .reserve)
        XCTAssertEqual(sender.takes, 0)
        composer.receive(SenderStatus(connected: true, ownerName: "Another app"))
        let count = sender.snapshots.count
        composer.showSubmitted()
        XCTAssertEqual(sender.snapshots.count, count)
        XCTAssertEqual(sender.takes, 0)
    }
    func testStopCancelsAnInFlightTakeByDisconnecting() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: .scripture)
        composer.receive(SenderStatus(connected: true))
        composer.show()
        XCTAssertTrue(composer.takingOutput)
        composer.stop()
        XCTAssertEqual(sender.disconnects, 1)
        XCTAssertFalse(composer.status.connected)
        XCTAssertFalse(composer.takingOutput)
        XCTAssertEqual(composer.draft, .scripture)
    }
    func testCancelledConnectionCannotPublishWhenItEventuallyConnects() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: .scripture)
        composer.show(); composer.stop()
        composer.receive(SenderStatus(connected: true))
        XCTAssertTrue(sender.snapshots.isEmpty)
        XCTAssertEqual(sender.takes, 0)
    }
    func testEmptyOrOversizedDraftCannotTakeOver() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender)
        composer.receive(SenderStatus(connected: true, ownerName: "Another source"))
        XCTAssertFalse(composer.canShow)
        composer.show()
        composer.draft = DisplayContent(body: String(repeating: "x", count: 24_001))
        XCTAssertFalse(composer.canShow)
        composer.show()
        XCTAssertEqual(sender.takes, 0)
        XCTAssertTrue(sender.snapshots.isEmpty)
    }
    func testConnectingOrLosingOwnershipNeverAutomaticallyTakesOver() {
        let sender = Sender()
        let composer = TextComposerSession(sender: sender, draft: .scripture)
        composer.receive(SenderStatus(connected: true, ownerName: "Another source"))
        XCTAssertEqual(sender.takes, 0)
        composer.show()
        composer.receive(SenderStatus(connected: true, ownsOutput: true))
        composer.receive(SenderStatus(connected: true, ownerName: "Another source"))
        composer.draft = .lyrics
        XCTAssertEqual(sender.takes, 1)
        XCTAssertEqual(composer.primaryTitle, "Publish Text")
    }
}
