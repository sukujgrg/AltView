import AppKit
import XCTest
@testable import AltView

private final class MonitorTestInventory {
    var displays: [OutputDisplay]
    init(_ displays: [OutputDisplay]) { self.displays = displays }
}

private final class MonitorLayoutTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class DisplayAssignmentTests: XCTestCase {
    private func monitor(_ id: UInt32 = 101, identity: String = "monitor-a", mirrored: Bool = false) -> OutputDisplay {
        OutputDisplay(id: id, name: "Studio Display", frame: NSRect(x: -8000, y: 0, width: 960, height: 540),
                      identity: identity, isMirrored: mirrored)
    }
    private func preferences() throws -> UserDefaults {
        let name = "MonitorAssignments.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func button(_ title: String, in root: NSView) throws -> NSButton {
        try XCTUnwrap(views(root).compactMap { $0 as? NSButton }.first { $0.title == title })
    }
    private func picker(in root: NSView) throws -> NSPopUpButton {
        try XCTUnwrap(views(root).compactMap { $0 as? NSPopUpButton }.first)
    }
    private func output(_ role: DisplayRole, inventory: MonitorTestInventory) -> OutputWindowController {
        _ = NSApplication.shared
        return OutputWindowController(name: role.title, makeCanvas: { NSView() }, displays: { inventory.displays })
    }

    func testAssignmentsReserveMonitorsEvenWithBothWindowsClosed() throws {
        let a = monitor(), b = monitor(102, identity: "monitor-b")
        let defaults = try preferences()
        let assignments = DisplayAssignments(defaults: defaults, displays: { [a, b] })
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        XCTAssertFalse(assignments.select(a.target, for: .confidence))
        XCTAssertTrue(assignments.select(b.target, for: .confidence))
        let restored = DisplayAssignments(defaults: defaults, displays: { [b, a] })
        XCTAssertEqual(restored.target(for: .audience), a.target)
        XCTAssertEqual(restored.target(for: .confidence), b.target)
        XCTAssertFalse(restored.select(b.target, for: .audience))
        XCTAssertTrue(restored.select(nil, for: .confidence))
        XCTAssertTrue(restored.select(b.target, for: .audience))
    }

    func testPreviewChoiceDoesNotReviveLegacyAssignmentAfterRestart() throws {
        let a = monitor(), defaults = try preferences()
        defaults.set(a.id, forKey: "outputDisplayID")
        let assignments = DisplayAssignments(defaults: defaults, displays: { [a] })
        XCTAssertEqual(assignments.target(for: .audience), a.target)
        XCTAssertTrue(assignments.select(nil, for: .audience))
        let restored = DisplayAssignments(defaults: defaults, displays: { [a] })
        XCTAssertNil(restored.target(for: .audience))
        XCTAssertEqual(defaults.data(forKey: "audienceMonitorAssignment"), Data("null".utf8))
    }

    func testMissingLegacyMonitorRequiresExplicitChoice() throws {
        let defaults = try preferences()
        defaults.set(777, forKey: "confidenceDisplayID")
        let assignments = DisplayAssignments(defaults: defaults, displays: { [self.monitor()] })
        let saved = try XCTUnwrap(assignments.target(for: .confidence))
        XCTAssertEqual(saved.identity, "legacy:777")
        XCTAssertNotNil(assignments.problem(for: saved, role: .confidence))
        XCTAssertFalse(assignments.canIdentify(.confidence))
        XCTAssertTrue(assignments.select(nil, for: .confidence))
    }

    func testUnreadablePreferencesDoNotSilentlyUsePreview() throws {
        let defaults = try preferences()
        defaults.set(Data("invalid".utf8), forKey: "audienceMonitorAssignment")
        let a = monitor()
        let assignments = DisplayAssignments(defaults: defaults, displays: { [a] })
        XCTAssertNotNil(assignments.target(for: .audience))
        XCTAssertNotNil(assignments.problem(for: assignments.target(for: .audience), role: .audience))
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        defaults.set("invalid storage type", forKey: "audienceMonitorAssignment")
        let restored = DisplayAssignments(defaults: defaults, displays: { [a] })
        XCTAssertNotNil(restored.target(for: .audience))
        XCTAssertNotNil(restored.problem(for: restored.target(for: .audience), role: .audience))
    }

    func testMirroredUnknownAndAmbiguousMonitorsCannotBeAssigned() throws {
        let defaults = try preferences(), a = monitor()
        let inventory = MonitorTestInventory([monitor(mirrored: true)])
        let assignments = DisplayAssignments(defaults: defaults, displays: { inventory.displays })
        XCTAssertFalse(assignments.select(a.target, for: .audience))
        inventory.displays = [a, monitor(102)] // Different runtime IDs, indistinguishable identities.
        assignments.refresh()
        XCTAssertFalse(assignments.select(a.target, for: .audience))
        XCTAssertNil(a.target.resolve(in: inventory.displays))
        inventory.displays = [OutputDisplay(id: 103, name: "Connecting monitor", frame: a.frame)]
        assignments.refresh()
        XCTAssertFalse(assignments.select(inventory.displays[0].target, for: .audience))
    }

    func testDisconnectedAssignmentRemainsReservedAndResolvesNewRuntimeID() throws {
        let a = monitor(), defaults = try preferences()
        let inventory = MonitorTestInventory([a])
        let assignments = DisplayAssignments(defaults: defaults, displays: { inventory.displays })
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        inventory.displays = []; assignments.refresh()
        XCTAssertEqual(assignments.target(for: .audience), a.target)
        XCTAssertFalse(assignments.select(a.target, for: .confidence))
        inventory.displays = [monitor(909)]; assignments.refresh()
        XCTAssertNil(assignments.problem(for: a.target, role: .audience))
        XCTAssertEqual(assignments.target(for: .audience)?.resolve(in: inventory.displays)?.id, 909)
    }

    func testActiveOutputRejectsReusedIDAndReconnectsOnlyToSameIdentity() throws {
        let a = monitor(), inventory = MonitorTestInventory([monitor()])
        let output = output(.audience, inventory: inventory)
        defer { output.stop() }
        output.show(target: a.target)
        let initial = try XCTUnwrap(NSApp.windows.first { $0.title == "AltView Audience" && $0.isVisible })
        XCTAssertEqual(output.readiness, .ready)
        inventory.displays = [monitor(identity: "replacement-monitor")]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertFalse(initial.isVisible, "A lost monitor closes immediately before macOS can move its window")
        XCTAssertEqual(output.readiness, .displayMissing)
        XCTAssertTrue(output.isActive)
        XCTAssertNil(output.activeDisplayID)
        inventory.displays = [monitor(909)]
        output.reconcile()
        XCTAssertEqual(output.readiness, .ready)
        XCTAssertEqual(output.activeDisplayID, 909)
        output.stop()
        inventory.displays = []; output.reconcile()
        inventory.displays = [a]; output.reconcile()
        XCTAssertEqual(output.readiness, .closed, "Close cancels reconnect restoration")
        XCTAssertFalse(output.isActive)
    }

    func testActiveOutputClosesDuringMirroringAndAmbiguousIdentity() throws {
        let a = monitor(), inventory = MonitorTestInventory([monitor()])
        let output = output(.confidence, inventory: inventory)
        defer { output.stop() }
        output.show(target: a.target)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "AltView Confidence" && $0.isVisible })
        inventory.displays = [monitor(mirrored: true)]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(output.readiness, .unavailable)
        XCTAssertFalse(window.isVisible)
        inventory.displays = [a, monitor(102)]; output.reconcile()
        XCTAssertEqual(output.readiness, .unavailable)
        XCTAssertTrue(output.isActive)
        inventory.displays = [a]; output.reconcile()
        XCTAssertEqual(output.readiness, .ready)
    }

    func testBothPickersExposeReservationsAndDistinctNumbersForSameNames() throws {
        let a = monitor(), b = monitor(102, identity: "monitor-b")
        let inventory = MonitorTestInventory([a, b])
        let assignments = DisplayAssignments(defaults: try preferences(), displays: { inventory.displays })
        let audience = output(.audience, inventory: inventory), confidence = output(.confidence, inventory: inventory)
        defer { audience.stop(); confidence.stop() }
        let aControls = MonitorControls(role: .audience, assignments: assignments, output: audience)
        let cControls = MonitorControls(role: .confidence, assignments: assignments, output: confidence)
        let aPicker = try picker(in: aControls), cPicker = try picker(in: cControls)
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        XCTAssertEqual(aPicker.titleOfSelectedItem, "1 · Studio Display")
        let occupied = try XCTUnwrap(cPicker.item(withTitle: "1 · Studio Display · Audience"))
        XCTAssertFalse(occupied.isEnabled)
        XCTAssertTrue(assignments.select(b.target, for: .confidence))
        XCTAssertFalse(try XCTUnwrap(aPicker.item(withTitle: "2 · Studio Display · Confidence")).isEnabled)
        XCTAssertEqual(cPicker.titleOfSelectedItem, "2 · Studio Display")
        cPicker.selectItem(at: 0); cPicker.sendAction(cPicker.action, to: cPicker.target)
        XCTAssertTrue(try XCTUnwrap(aPicker.item(withTitle: "2 · Studio Display")).isEnabled)
    }

    func testOpenAndWaitingAssignmentsAreLockedAndCannotIdentifyLiveMonitor() throws {
        let a = monitor(), inventory = MonitorTestInventory([monitor()])
        let assignments = DisplayAssignments(defaults: try preferences(), displays: { inventory.displays })
        let output = output(.confidence, inventory: inventory)
        defer { output.stop() }
        let controls = MonitorControls(role: .confidence, assignments: assignments, output: output)
        XCTAssertTrue(assignments.select(a.target, for: .confidence))
        XCTAssertTrue(try button("Identify", in: controls).isEnabled)
        try button("Open Display", in: controls).performClick(nil)
        XCTAssertEqual(output.readiness, .ready)
        XCTAssertTrue(try button("Open Display", in: controls).isHidden)
        XCTAssertFalse(try button("Close Display", in: controls).isHidden)
        XCTAssertFalse(try picker(in: controls).isEnabled)
        XCTAssertFalse(assignments.select(nil, for: .confidence))
        XCTAssertFalse(try button("Identify", in: controls).isEnabled)
        inventory.displays = []
        assignments.refresh(); output.reconcile()
        XCTAssertTrue(assignments.isLocked(.confidence))
        XCTAssertEqual(try picker(in: controls).titleOfSelectedItem, "1 · Studio Display · Disconnected")
        XCTAssertTrue(try button("Close Display", in: controls).isEnabled)
        try button("Close Display", in: controls).performClick(nil)
        XCTAssertFalse(try button("Open Display", in: controls).isHidden)
        XCTAssertTrue(try button("Close Display", in: controls).isHidden)
        XCTAssertTrue(try picker(in: controls).isEnabled)
        XCTAssertFalse(try button("Open Display", in: controls).isEnabled)
        XCTAssertTrue(assignments.select(nil, for: .confidence))
        XCTAssertTrue(try button("Open Display", in: controls).isEnabled)
    }

    func testIdentifyOverlayClosesBeforeOpeningOutput() throws {
        let a = monitor(), inventory = MonitorTestInventory([monitor()])
        let assignments = DisplayAssignments(defaults: try preferences(), displays: { inventory.displays })
        let output = output(.audience, inventory: inventory)
        defer { output.stop() }
        let controls = MonitorControls(role: .audience, assignments: assignments, output: output)
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        try button("Identify", in: controls).performClick(nil)
        let overlay = try XCTUnwrap(NSApp.windows.first { window in
            window.isVisible && window.title.isEmpty && window.contentView.map {
                views($0).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "AltView Monitor 1" }
            } == true
        })
        try button("Open Display", in: controls).performClick(nil)
        XCTAssertFalse(overlay.isVisible)
        XCTAssertEqual(output.readiness, .ready)
        XCTAssertFalse(try button("Identify", in: controls).isEnabled)
    }

    func testOpenRechecksInventoryEvenBeforeScreenNotificationArrives() throws {
        let a = monitor(), inventory = MonitorTestInventory([monitor()])
        let assignments = DisplayAssignments(defaults: try preferences(), displays: { inventory.displays })
        let output = output(.audience, inventory: inventory)
        defer { output.stop() }
        let controls = MonitorControls(role: .audience, assignments: assignments, output: output)
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        inventory.displays = [monitor(identity: "replacement")]
        try button("Open Display", in: controls).performClick(nil)
        XCTAssertFalse(output.isActive)
        XCTAssertFalse(try button("Open Display", in: controls).isEnabled)
        XCTAssertEqual(assignments.target(for: .audience), a.target)
    }

    func testPreviewWindowsRemainIndependentAndLockOnlyTheirOwnPickers() throws {
        let inventory = MonitorTestInventory([monitor()])
        let assignments = DisplayAssignments(defaults: try preferences(), displays: { inventory.displays })
        let audience = output(.audience, inventory: inventory), confidence = output(.confidence, inventory: inventory)
        defer { audience.stop(); confidence.stop() }
        let aControls = MonitorControls(role: .audience, assignments: assignments, output: audience)
        let cControls = MonitorControls(role: .confidence, assignments: assignments, output: confidence)
        try button("Open Display", in: aControls).performClick(nil)
        XCTAssertEqual(audience.readiness, .preview)
        XCTAssertTrue(try picker(in: cControls).isEnabled)
        try button("Open Display", in: cControls).performClick(nil)
        XCTAssertEqual(confidence.readiness, .preview)
        try button("Close Display", in: aControls).performClick(nil)
        XCTAssertEqual(confidence.readiness, .preview)
        XCTAssertFalse(try picker(in: cControls).isEnabled)
    }

    func testControlsMonitorRequiresConfirmationAndRechecksAssignment() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let a = monitor(OutputWindowController.displayID(screen))
        let inventory = MonitorTestInventory([a])
        let assignments = DisplayAssignments(defaults: try preferences(), displays: { inventory.displays })
        let output = output(.audience, inventory: inventory)
        let controls = MonitorControls(role: .audience, assignments: assignments, output: output)
        let window = NSWindow(contentRect: NSRect(x: screen.frame.midX, y: screen.frame.midY, width: 300, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controls; window.orderFrontRegardless()
        defer { output.stop(); window.close() }
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        try button("Open Display", in: controls).performClick(nil)
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(output.isActive, "Covering the controls always requires confirmation")
        XCTAssertTrue(assignments.select(nil, for: .audience))
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(output.isActive, "A changed assignment invalidates the pending confirmation")
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        try button("Open Display", in: controls).performClick(nil)
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(output.isActive)
        try button("Open Display", in: controls).performClick(nil)
        inventory.displays = []
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(output.isActive, "A lost monitor cannot open after confirmation")
    }

    func testAssignedMonitorControlsFitCompactWorkspaceInBothAppearances() throws {
        _ = NSApplication.shared
        let a = monitor(), b = monitor(102, identity: "monitor-b"), defaults = try preferences()
        let c = monitor(103, identity: "monitor-c")
        defaults.set(try JSONEncoder().encode(a.target), forKey: "audienceMonitorAssignment")
        defaults.set(try JSONEncoder().encode(b.target), forKey: "confidenceMonitorAssignment")
        defaults.set(true, forKey: "customTextEnabled")
        let labels = DisplayAssignments(defaults: defaults, displays: { [a, b, c] })
        XCTAssertTrue(labels.rename(a.target, to: "Front Left TV"))
        XCTAssertTrue(labels.rename(b.target, to: "Stage TV"))
        XCTAssertTrue(labels.rename(c.target, to: "Front Right TV"))
        let window = MonitorLayoutTestWindow(contentRect: NSRect(x: -8000, y: 0, width: 1160, height: 650),
                                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(),
                                                  window: window, displays: { [a, b, c] })
        defer { controller.shutdown(); controller.close() }
        controller.showWindow(nil); window.setContentSize(NSSize(width: 1160, height: 650))
        let root = try XCTUnwrap(window.contentView)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for role in DisplayRole.allCases {
                if role == .audience { controller.showReceiverPage() } else { controller.showConfidencePage() }
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(root.bounds.size, NSSize(width: 1160, height: 650))
                let nav = try XCTUnwrap(views(root).compactMap { $0 as? NSOutlineView }.first { $0.accessibilityIdentifier() == "workspaceSidebar" })
                XCTAssertGreaterThanOrEqual(nav.numberOfRows, 7)
                XCTAssertTrue(root.bounds.contains(nav.convert(nav.bounds, to: root)))
                let monitorPicker = try XCTUnwrap(views(root).compactMap { $0 as? NSPopUpButton }.first {
                    $0.accessibilityIdentifier() == "\(role.rawValue)MonitorPicker"
                })
                let occupied = monitorPicker.itemArray.first { $0.title.hasSuffix(" · \(role.other.title)") }
                XCTAssertFalse(try XCTUnwrap(occupied).isEnabled)
                XCTAssertTrue(try button("Close Display", in: root).isHidden, "Show the action available for the current display state")
                for control in [monitorPicker as NSView, try button("Open Display", in: root), try button("Identify", in: root), try button("Name…", in: root)] {
                    XCTAssertTrue(root.bounds.contains(control.convert(control.bounds, to: root)))
                    XCTAssertFalse(control.visibleRect.isEmpty)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let image = NSImage(size: root.bounds.size)
                image.lockFocus()
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill(); root.bounds.fill()
                }
                let snapshot = NSImage(size: root.bounds.size); snapshot.addRepresentation(bitmap)
                snapshot.draw(in: root.bounds, from: .zero, operation: .sourceOver, fraction: 1)
                image.unlockFocus()
                let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/private/tmp/altview-\(role.rawValue)-monitors-\(appearance.rawValue).png"))
            }
        }
    }

    func testThreeIdenticalTVsKeepTheirNamesAndNumbersAcrossReorderAndRelaunch() throws {
        let a = monitor(), b = monitor(102, identity: "monitor-b"), c = monitor(103, identity: "monitor-c")
        let defaults = try preferences(), inventory = MonitorTestInventory([a, b, c])
        let assignments = DisplayAssignments(defaults: defaults, displays: { inventory.displays })
        for (display, name, number) in [(a, "Front Left TV", 1), (b, "Front Right TV", 2), (c, "Stage TV", 3)] {
            XCTAssertEqual(assignments.number(for: display.target), number)
            XCTAssertTrue(assignments.rename(display.target, to: name))
        }
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        XCTAssertTrue(assignments.select(c.target, for: .confidence))
        let audiencePreference = defaults.data(forKey: "audienceMonitorAssignment")
        inventory.displays = [monitor(909, identity: "monitor-c"), monitor(808)] // New IDs, reversed order, one TV missing.
        assignments.refresh()
        let restored = DisplayAssignments(defaults: defaults, displays: { inventory.displays })
        XCTAssertEqual(restored.displays.map(\.identity), [a.identity, c.identity])
        XCTAssertEqual(restored.label(for: a.target), "1 · Front Left TV")
        XCTAssertEqual(restored.label(for: b.target), "2 · Front Right TV")
        XCTAssertEqual(restored.label(for: c.target), "3 · Stage TV")
        XCTAssertEqual(restored.target(for: .audience)?.resolve(in: inventory.displays)?.id, 808)
        XCTAssertEqual(restored.target(for: .confidence)?.resolve(in: inventory.displays)?.id, 909)
        XCTAssertEqual(defaults.data(forKey: "audienceMonitorAssignment"), audiencePreference)
        let d = monitor(104, identity: "monitor-d")
        inventory.displays = [d, c, a]; restored.refresh()
        XCTAssertEqual(restored.number(for: d.target), 4, "A new TV must not take a missing TV's number or name")
        XCTAssertNil(restored.nickname(for: d.target))
        inventory.displays = [c, d, b, a]; restored.refresh()
        XCTAssertEqual(restored.displays.map(\.identity), [a.identity, b.identity, c.identity, d.identity])
    }

    func testNamingIsSharedAndDoesNotChangeLiveOutputOrAssignment() throws {
        let a = monitor(), inventory = MonitorTestInventory([monitor()]), defaults = try preferences()
        let assignments = DisplayAssignments(defaults: defaults, displays: { inventory.displays })
        let audience = output(.audience, inventory: inventory), confidence = output(.confidence, inventory: inventory)
        defer { audience.stop(); confidence.stop() }
        let aControls = MonitorControls(role: .audience, assignments: assignments, output: audience)
        let cControls = MonitorControls(role: .confidence, assignments: assignments, output: confidence)
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        try button("Open Display", in: aControls).performClick(nil)
        let savedAssignment = defaults.data(forKey: "audienceMonitorAssignment")
        XCTAssertTrue(try button("Name…", in: aControls).isEnabled)
        XCTAssertTrue(assignments.rename(a.target, to: "Front Left TV"))
        XCTAssertEqual(audience.readiness, .ready)
        XCTAssertEqual(audience.activeDisplayID, a.id)
        XCTAssertEqual(defaults.data(forKey: "audienceMonitorAssignment"), savedAssignment)
        XCTAssertEqual(try picker(in: aControls).titleOfSelectedItem, "1 · Front Left TV")
        XCTAssertFalse(try picker(in: aControls).isEnabled)
        XCTAssertFalse(try XCTUnwrap(picker(in: cControls).item(withTitle: "1 · Front Left TV · Audience")).isEnabled)
        XCTAssertTrue(views(aControls).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Audience on 1 · Front Left TV" })
        audience.stop()
        XCTAssertTrue(assignments.select(nil, for: .audience))
        XCTAssertTrue(assignments.select(a.target, for: .confidence))
        XCTAssertEqual(try picker(in: cControls).titleOfSelectedItem, "1 · Front Left TV", "The name belongs to the TV, not its output role")
    }

    func testDisconnectedNamedTVAndItsReservationRemainVisible() throws {
        let a = monitor(), inventory = MonitorTestInventory([monitor()]), defaults = try preferences()
        let assignments = DisplayAssignments(defaults: defaults, displays: { inventory.displays })
        let output = output(.audience, inventory: inventory)
        defer { output.stop() }
        let controls = MonitorControls(role: .audience, assignments: assignments, output: output)
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        XCTAssertTrue(assignments.rename(a.target, to: "Front Left TV"))
        inventory.displays = []; assignments.refresh()
        XCTAssertEqual(try picker(in: controls).titleOfSelectedItem, "1 · Front Left TV · Disconnected")
        XCTAssertFalse(try button("Open Display", in: controls).isEnabled)
        XCTAssertFalse(try button("Identify", in: controls).isEnabled)
        XCTAssertTrue(try button("Name…", in: controls).isEnabled)
        XCTAssertFalse(assignments.select(a.target, for: .confidence))
        XCTAssertTrue(assignments.rename(a.target, to: "Front TV"))
        let restored = DisplayAssignments(defaults: defaults, displays: { [] })
        XCTAssertEqual(restored.label(for: a.target), "1 · Front TV")
        XCTAssertEqual(restored.target(for: .audience), a.target)
    }

    func testUnknownAndAmbiguousIdentitiesCannotReceiveNames() throws {
        let a = monitor(), inventory = MonitorTestInventory([monitor()])
        let assignments = DisplayAssignments(defaults: try preferences(), displays: { inventory.displays })
        XCTAssertTrue(assignments.rename(a.target, to: "Front TV"))
        inventory.displays.append(monitor(102)); assignments.refresh()
        XCTAssertFalse(assignments.canRename(a.target))
        XCTAssertFalse(assignments.rename(a.target, to: "Wrong TV"))
        XCTAssertEqual(assignments.nickname(for: a.target), "Front TV")
        let unknown = OutputDisplay(id: 103, name: "Connecting TV", frame: a.frame)
        inventory.displays = [unknown]; assignments.refresh()
        XCTAssertNil(assignments.number(for: unknown.target))
        XCTAssertFalse(assignments.canRename(unknown.target))
        XCTAssertFalse(assignments.rename(unknown.target, to: "Unknown TV"))
    }

    func testNameValidationAndResetDoNotAffectSavedOutputSelection() throws {
        let a = monitor(), assignments = DisplayAssignments(defaults: try preferences(), displays: { [self.monitor()] })
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        XCTAssertTrue(assignments.rename(a.target, to: "  Front Left TV  "))
        XCTAssertEqual(assignments.nickname(for: a.target), "Front Left TV")
        for invalid in [String(repeating: "x", count: 41), "Front\nTV", "Front\tTV", "Front\u{2028}TV"] {
            XCTAssertFalse(assignments.rename(a.target, to: invalid))
            XCTAssertEqual(assignments.nickname(for: a.target), "Front Left TV")
        }
        XCTAssertTrue(assignments.rename(a.target, to: String(repeating: "📺", count: 40)))
        XCTAssertTrue(assignments.rename(a.target, to: " \n "))
        XCTAssertNil(assignments.nickname(for: a.target))
        XCTAssertEqual(assignments.label(for: a.target), "1 · Studio Display")
        XCTAssertEqual(assignments.target(for: .audience), a.target)
    }

    func testIdentifyUsesSavedNumberAndNameAfterScreenListChanges() throws {
        let a = monitor(), b = monitor(102, identity: "monitor-b"), c = monitor(103, identity: "monitor-c")
        let inventory = MonitorTestInventory([a, b, c])
        let assignments = DisplayAssignments(defaults: try preferences(), displays: { inventory.displays })
        let output = output(.confidence, inventory: inventory)
        defer { output.stop() }
        let controls = MonitorControls(role: .confidence, assignments: assignments, output: output)
        XCTAssertTrue(assignments.rename(c.target, to: "Stage TV"))
        XCTAssertTrue(assignments.select(c.target, for: .confidence))
        inventory.displays = [c, b]; assignments.refresh()
        try button("Identify", in: controls).performClick(nil)
        let overlay = try XCTUnwrap(NSApp.windows.first { window in
            window.isVisible && window.title.isEmpty && window.contentView.map {
                views($0).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "AltView Monitor 3" }
            } == true
        })
        XCTAssertTrue(views(try XCTUnwrap(overlay.contentView)).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Stage TV" })
        XCTAssertTrue(assignments.rename(c.target, to: "Stage Right TV"))
        XCTAssertFalse(overlay.isVisible, "A label change removes an old identification overlay")
    }

    func testNameSheetSavesCancelsAndValidatesWithoutOpeningDisplay() throws {
        let a = monitor(), inventory = MonitorTestInventory([monitor()])
        let assignments = DisplayAssignments(defaults: try preferences(), displays: { inventory.displays })
        let output = output(.audience, inventory: inventory)
        let controls = MonitorControls(role: .audience, assignments: assignments, output: output)
        let window = MonitorLayoutTestWindow(contentRect: NSRect(x: -8000, y: 0, width: 350, height: 350),
                                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controls; window.orderFrontRegardless()
        defer { output.stop(); window.close() }
        XCTAssertTrue(assignments.select(a.target, for: .audience))
        try button("Name…", in: controls).performClick(nil)
        let sheet = try XCTUnwrap(window.attachedSheet), root = try XCTUnwrap(sheet.contentView)
        let field = try XCTUnwrap(views(root).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "monitorName" })
        XCTAssertTrue(views(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == a.identity && $0.isSelectable })
        field.stringValue = String(repeating: "x", count: 41)
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertFalse(try button("Save Name", in: root).isEnabled)
        field.stringValue = "  Front Left TV  "
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(try button("Save Name", in: root).isEnabled)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(assignments.nickname(for: a.target), "Front Left TV")
        XCTAssertFalse(output.isActive)
        try button("Name…", in: controls).performClick(nil)
        let cancelled = try XCTUnwrap(window.attachedSheet)
        let cancelledField = try XCTUnwrap(views(try XCTUnwrap(cancelled.contentView)).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "monitorName" })
        XCTAssertEqual(cancelledField.stringValue, "Front Left TV")
        cancelledField.stringValue = "Do not save"
        window.endSheet(cancelled, returnCode: .alertSecondButtonReturn)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(assignments.nickname(for: a.target), "Front Left TV")
        XCTAssertFalse(output.isActive)
    }
}
