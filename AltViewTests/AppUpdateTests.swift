import AppKit
import Sparkle
import XCTest
@testable import AltView

@MainActor
private final class FakeUpdateDriver: AppUpdateDriving {
    var state = AppUpdateState(canCheckForUpdates: true)
    var onStateChange: ((AppUpdateState) -> Void)?
    var starts = 0
    var checks = 0
    func start() { starts += 1 }
    func checkForUpdates() { checks += 1 }
    func setAutomaticChecks(_ enabled: Bool) {
        state.automaticallyChecksForUpdates = enabled
        onStateChange?(state)
    }
}

@MainActor
final class AppUpdateTests: XCTestCase {
    func testSingleStartupAutomaticPreferenceAndManualCheck() {
        let driver = FakeUpdateDriver()
        let controller = AppUpdateController(driver: driver, isPresenting: { false })
        controller.start(); controller.start()
        XCTAssertEqual(driver.starts, 1)
        controller.checkForUpdates(nil)
        XCTAssertEqual(driver.checks, 1)
        controller.toggleAutomaticChecks(nil)
        XCTAssertFalse(controller.state.automaticallyChecksForUpdates)
        let automatic = NSMenuItem(title: "Automatic", action: #selector(controller.toggleAutomaticChecks(_:)), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(automatic))
        XCTAssertEqual(automatic.state, .off)
        driver.state.canCheckForUpdates = false
        driver.onStateChange?(driver.state)
        controller.checkForUpdates(nil)
        XCTAssertEqual(driver.checks, 1)
    }

    func testPresentationBlocksMenuAndButtonChecksButKeepsReminder() {
        var presenting = false
        let driver = FakeUpdateDriver()
        let controller = AppUpdateController(driver: driver, isPresenting: { presenting })
        let menu = NSMenuItem(title: "Check", action: #selector(controller.checkForUpdates(_:)), keyEquivalent: "")
        driver.state.availableVersion = "1.1"
        driver.onStateChange?(driver.state)
        XCTAssertTrue(controller.validateMenuItem(menu))
        XCTAssertEqual(menu.title, "Update to 1.1…")
        presenting = true
        XCTAssertFalse(controller.validateMenuItem(menu))
        XCTAssertEqual(menu.toolTip, AppUpdateController.activityExplanation)
        controller.checkForUpdates(nil)
        XCTAssertEqual(driver.checks, 0)
        XCTAssertEqual(controller.state.availableVersion, "1.1")
        presenting = false
        controller.checkForUpdates(nil)
        XCTAssertEqual(driver.checks, 1)
    }

    func testScheduledChecksStayQuietAndRelaunchChecksCurrentPresentationState() throws {
        var presenting = true
        let driver = SparkleUpdateDriver(isPresenting: { presenting })
        let userDriver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: nil)
        XCTAssertTrue(driver.supportsGentleScheduledUpdateReminders)
        XCTAssertFalse(driver.updaterShouldRelaunchApplication(updater))
        XCTAssertThrowsError(try driver.updater(updater, mayPerform: .updates))
        XCTAssertNoThrow(try driver.updater(updater, mayPerform: .updateInformation))
        presenting = false
        XCTAssertTrue(driver.updaterShouldRelaunchApplication(updater))
        XCTAssertNoThrow(try driver.updater(updater, mayPerform: .updates))
        // No updater is started: these tests never fetch a feed or install an update.
    }

    func testOutputActivityIncludesPreviewAndDisconnectedDisplay() {
        let output = OutputWindowController(presentation: CanvasPresentation())
        defer { output.stop() }
        XCTAssertFalse(output.isActive)
        output.show(displayID: nil)
        XCTAssertTrue(output.isActive)
        output.stop()
        XCTAssertFalse(output.isActive)
        output.show(displayID: UInt32.max)
        XCTAssertTrue(output.isActive, "Waiting for a disconnected output display is still a presentation")
        output.stop()
        XCTAssertFalse(output.isActive)
    }
}
