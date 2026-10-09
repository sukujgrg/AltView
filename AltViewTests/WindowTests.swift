import AppKit
import Network
import XCTest
@testable import AltView

// Hosted runners can have a screen shorter than the layouts under test. Keep
// AppKit's screen fitting out of these tests while retaining window Auto Layout.
private final class LayoutTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class WindowTests: XCTestCase {
    func testAudienceAndConfidencePreviewFramesMatchAcrossWindowSizes() throws {
        _ = NSApplication.shared
        let domain = "AltViewTests.MatchingPreviews.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let window = LayoutTestWindow(contentRect: NSRect(x: -8000, y: 0, width: 1160, height: 650),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0, window: window)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        controller.showWindow(nil)
        let root = try XCTUnwrap(window.contentView)
        for size in [NSSize(width: 1160, height: 650), NSSize(width: 1480, height: 900)] {
            window.setContentSize(size)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for ratio in PreviewAspectRatio.allCases {
                    var frames: [(stage: NSRect, canvas: NSRect)] = []
                    for role in ["Audience", "Confidence"] {
                        if role == "Audience" { controller.showReceiverPage() } else { controller.showConfidencePage() }
                        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? PreviewAspectRatioPicker }.first)
                        picker.selectItem(withTitle: ratio.rawValue); picker.sendAction(picker.action, to: picker.target)
                        root.layoutSubtreeIfNeeded()
                        let stage = try XCTUnwrap(descendants(root).compactMap { $0 as? WorkspaceCanvasStage }.first)
                        let canvas = try XCTUnwrap(stage.subviews.first)
                        frames.append((stage.convert(stage.bounds, to: root), canvas.convert(canvas.bounds, to: root)))
                        if role == "Audience" {
                            for title in ["Edit Audience Design", "Clear & Release"] {
                                let control = try button(title, in: root)
                                XCTAssertTrue(root.bounds.contains(control.convert(control.bounds, to: root)))
                                XCTAssertFalse(control.visibleRect.isEmpty)
                            }
                        }
                        if size.width == 1160 && ratio == .computer {
                            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                                root.cacheDisplay(in: root.bounds, to: bitmap)
                            }
                            let image = NSImage(size: root.bounds.size)
                            image.lockFocus()
                            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                                NSColor.windowBackgroundColor.setFill(); root.bounds.fill()
                            }
                            let snapshot = NSImage(size: root.bounds.size); snapshot.addRepresentation(bitmap)
                            snapshot.draw(in: root.bounds, from: .zero, operation: .sourceOver, fraction: 1)
                            image.unlockFocus()
                            let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
                            try png.write(to: URL(fileURLWithPath: "/private/tmp/altview-matched-\(role.lowercased())-\(appearance.rawValue).png"))
                        }
                    }
                    XCTAssertEqual(frames[0].stage, frames[1].stage, "Preview surroundings must match for \(ratio.rawValue)")
                    XCTAssertEqual(frames[0].canvas, frames[1].canvas, "Monitor sizes must match for \(ratio.rawValue)")
                }
            }
        }
    }

    func testPreviewAspectRatiosResizeIndependentlyAndRestoreSelections() throws {
        _ = NSApplication.shared
        let domain = "AltViewTests.PreviewRatios.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let window = LayoutTestWindow(contentRect: NSRect(x: -8000, y: 0, width: 1160, height: 650),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0, window: window)
        defer { controller.shutdown(); controller.close() }
        controller.showReceiverPage(); controller.showWindow(nil)
        let root = try XCTUnwrap(window.contentView)
        let pickers = descendants(root).compactMap { $0 as? PreviewAspectRatioPicker }
        let audience = try XCTUnwrap(pickers.first { $0.accessibilityLabel() == "Audience preview aspect ratio" })
        XCTAssertEqual(audience.itemTitles, ["16:9", "16:10", "4:3"])
        let audienceCanvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        for ratio in PreviewAspectRatio.allCases {
            audience.selectItem(withTitle: ratio.rawValue)
            audience.sendAction(audience.action, to: audience.target)
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(audienceCanvas.bounds.width / audienceCanvas.bounds.height, ratio.value, accuracy: 0.01)
            XCTAssertTrue(root.bounds.contains(audience.convert(audience.bounds, to: root)))
            XCTAssertNil(defaults.string(forKey: "confidencePreviewAspectRatio"))
        }
        controller.showConfidencePage()
        let confidence = try XCTUnwrap(descendants(root).compactMap { $0 as? PreviewAspectRatioPicker }.first { $0.accessibilityLabel() == "Confidence preview aspect ratio" })
        XCTAssertEqual(confidence.itemTitles, ["16:9", "16:10", "4:3"])
        XCTAssertEqual(confidence.titleOfSelectedItem, "16:9")
        let confidenceCanvas = try XCTUnwrap(descendants(root).compactMap { $0 as? ConfidenceCanvas }.first)
        for ratio in PreviewAspectRatio.allCases {
            confidence.selectItem(withTitle: ratio.rawValue)
            confidence.sendAction(confidence.action, to: confidence.target)
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(confidenceCanvas.bounds.width / confidenceCanvas.bounds.height, ratio.value, accuracy: 0.01)
            XCTAssertTrue(root.bounds.contains(confidence.convert(confidence.bounds, to: root)))
            XCTAssertEqual(audience.titleOfSelectedItem, "4:3")
        }
        confidence.selectItem(withTitle: "16:10")
        confidence.sendAction(confidence.action, to: confidence.target)
        controller.showDesignPage()
        let design = try XCTUnwrap(descendants(root).compactMap { $0 as? PreviewAspectRatioPicker }.first { $0.accessibilityLabel() == "Design preview aspect ratio" })
        XCTAssertEqual(design.itemTitles, ["16:9", "16:10", "4:3"])
        XCTAssertEqual(design.titleOfSelectedItem, "16:9")
        let designCanvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let apply = try button("Apply Changes", in: root)
        let initiallyEnabled = apply.isEnabled
        for ratio in PreviewAspectRatio.allCases {
            design.selectItem(withTitle: ratio.rawValue); design.sendAction(design.action, to: design.target)
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(designCanvas.bounds.width / designCanvas.bounds.height, ratio.value, accuracy: 0.01)
            XCTAssertTrue(root.bounds.contains(design.convert(design.bounds, to: root)))
            XCTAssertEqual(apply.isEnabled, initiallyEnabled, "Preview shape must not change the design draft")
            XCTAssertEqual(audience.titleOfSelectedItem, "4:3")
            XCTAssertEqual(confidence.titleOfSelectedItem, "16:10")
            let stage = try XCTUnwrap(designCanvas.superview)
            XCTAssertEqual(stage.subviews.last?.frame, designCanvas.frame, "Layout guides must follow the resized monitor")
        }
        design.selectItem(withTitle: "16:10"); design.sendAction(design.action, to: design.target)
        let back = try button("Back to Audience", in: root)
        XCTAssertNotNil(back.image); XCTAssertEqual(back.imagePosition, .imageLeading)
        back.performClick(nil)
        XCTAssertEqual(descendants(root).compactMap { $0 as? PreviewAspectRatioPicker }.first?.accessibilityLabel(), "Audience preview aspect ratio")
        let restored = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { restored.shutdown(); restored.close() }
        let restoredRoot = try XCTUnwrap(restored.window?.contentView)
        restored.showReceiverPage()
        XCTAssertEqual(descendants(restoredRoot).compactMap { $0 as? PreviewAspectRatioPicker }.first?.titleOfSelectedItem, "4:3")
        restored.showConfidencePage()
        XCTAssertEqual(descendants(restoredRoot).compactMap { $0 as? PreviewAspectRatioPicker }.first?.titleOfSelectedItem, "16:10")
        restored.showDesignPage()
        XCTAssertEqual(descendants(restoredRoot).compactMap { $0 as? PreviewAspectRatioPicker }.first?.titleOfSelectedItem, "16:10")
    }

    func testHiddenPreviewDefersLayoutAndRedrawUntilVisible() throws {
        _ = NSApplication.shared
        var fits = 0
        let cache = CanvasTextLayoutCache { content, style, template in
            fits += 1; return .make(content: content, style: style, template: template)
        }
        let scene = CanvasPresentation(layoutCache: cache)
        let canvas = OutputCanvas(presentation: scene)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 225),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close() }
        canvas.needsDisplay = false
        let initiallyDirty = canvas.needsDisplay
        scene.update(content: DisplayContent(body: "First preview"), style: OutputStyle(), template: LowerThirdTemplate(), artwork: nil)
        XCTAssertEqual(fits, 0)
        XCTAssertEqual(canvas.needsDisplay, initiallyDirty, "The snapshot must not invalidate an offscreen view")
        window.orderFrontRegardless()
        eventually("first visible preview fits") { canvas.isVisibleForUpdates && fits == 1 }
        XCTAssertEqual(canvas.accessibilityLabel(), "First preview")

        canvas.isHidden = true; canvas.needsDisplay = false
        scene.update(content: DisplayContent(body: "Hidden edit"), style: OutputStyle(), template: LowerThirdTemplate(), artwork: nil)
        XCTAssertEqual(fits, 1)
        XCTAssertFalse(canvas.needsDisplay)
        canvas.isHidden = false
        eventually("unhidden preview catches up") { fits == 2 }
        XCTAssertEqual(canvas.accessibilityLabel(), "Hidden edit")

        window.orderOut(nil)
        eventually("window is offscreen") { !canvas.isVisibleForUpdates }
        canvas.needsDisplay = false
        scene.update(content: DisplayContent(body: "Latest preview"), style: OutputStyle(), template: LowerThirdTemplate(), artwork: nil)
        XCTAssertEqual(fits, 2)
        XCTAssertFalse(canvas.needsDisplay)
        window.orderFrontRegardless()
        eventually("reopened preview catches up") { canvas.isVisibleForUpdates && fits == 3 }
        XCTAssertEqual(canvas.accessibilityLabel(), "Latest preview")
    }

    func testWorkspaceDoesNotFitHiddenDesignOrTextPreviews() throws {
        let domain = "AltViewTests.HiddenLayouts.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "customTextEnabled")
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Shared private draft")), forKey: "customTextDraft")
        var fits = 0
        let cache = CanvasTextLayoutCache { content, style, template in
            fits += 1; return .make(content: content, style: style, template: template)
        }
        let scene = CanvasPresentation(layoutCache: cache)
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), presentation: scene)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        eventually("receiver ready") { controller.receiverStatus.listening }
        XCTAssertEqual(fits, 0, "Draft controls can update without fitting offscreen previews")
        controller.showDesignPage()
        eventually("design fits the private draft") { fits == 1 }
        controller.showComposerPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        // The XCTest host can be inactive behind the user's foreground app.
        controller.window?.orderFrontRegardless()
        eventually("Text preview is visible") { canvas.isVisibleForUpdates }
        XCTAssertEqual(fits, 1, "Text and Design share matching draft layouts")
        controller.showReceiverPage()
        XCTAssertEqual(fits, 1, "A blank output and hidden drafts require no text fitting")
    }

    func testOutputSleepPreventionIsScopedToOpenPresentation() throws {
        _ = NSApplication.shared
        let scene = CanvasPresentation()
        var begun: [NSObject] = [], ended: [ObjectIdentifier] = []
        var controller: OutputWindowController? = OutputWindowController(presentation: scene, beginActivity: { options, reason in
            XCTAssertTrue(options.contains(.idleSystemSleepDisabled))
            XCTAssertTrue(options.contains(.idleDisplaySleepDisabled))
            XCTAssertTrue(options.contains(.userInitiated))
            XCTAssertFalse(reason.isEmpty)
            let token = NSObject(); begun.append(token); return token
        }, endActivity: { token in ended.append(ObjectIdentifier(token)) })
        defer { controller?.stop() }
        XCTAssertTrue(begun.isEmpty)
        controller?.show(displayID: nil)
        XCTAssertEqual(begun.count, 1)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "AltView — Preview Audience" && $0.isVisible })
        scene.update(content: .scripture, style: OutputStyle(), template: LowerThirdTemplate(), artwork: nil)
        scene.update(content: .empty, style: OutputStyle(), template: LowerThirdTemplate(), artwork: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(begun.count, 1, "Text and readiness updates must not duplicate the activity")
        XCTAssertTrue(ended.isEmpty, "The output's keying background is still active")
        window.miniaturize(nil)
        eventually("minimized output releases sleep prevention") { controller?.readiness == .minimized && ended.count == 1 }
        window.deminiaturize(nil)
        eventually("restored output reacquires sleep prevention") { controller?.readiness == .preview && begun.count == 2 }
        window.close()
        XCTAssertEqual(ended.count, 2)
        controller?.stop(); controller?.stop()
        controller?.show(displayID: UInt32.max)
        XCTAssertEqual(begun.count, 2, "Waiting for a disconnected display must allow sleep")
        controller = nil
        var lastWindow: NSWindow?
        autoreleasepool {
            let teardown = OutputWindowController(presentation: scene, beginActivity: { _, _ in
                let token = NSObject(); begun.append(token); return token
            }, endActivity: { ended.append(ObjectIdentifier($0)) })
            teardown.show(displayID: nil)
            lastWindow = NSApp.windows.first { $0.title == "AltView — Preview Audience" && $0.isVisible }
        }
        XCTAssertEqual(begun.count, 3)
        XCTAssertEqual(ended, begun.map { ObjectIdentifier($0) }, "Every activity ends exactly once, including teardown")
        lastWindow?.close()
    }

    func testLocalComposerRestoresPublishedSnapshotAfterAutomaticPortChanges() throws {
        let domain = "AltViewTests.LocalPortChange.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let published = DisplayContent(title: "Published title", body: "Published text")
        defaults.set(true, forKey: "customTextEnabled")
        try defaults.set(JSONEncoder().encode(published), forKey: "customTextDraft")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate())
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        controller.showComposerPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        eventually("receiver ready") { controller.receiverStatus.listening }
        let previousPort = try XCTUnwrap(controller.receiverStatus.port)
        try button("Publish Text & Design", in: root).performClick(nil)
        eventually("local snapshot published") { controller.receiverStatus.content == published }
        let owner = try XCTUnwrap(controller.receiverStatus.ownerID)
        let title = try field("Text title", in: root)
        title.stringValue = "Private draft edit"
        title.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: title))
        try button("Hide Text", in: root).performClick(nil)
        var hidden = published; hidden.visible = false
        eventually("published snapshot hidden") { controller.receiverStatus.content == hidden }

        let settings = try settingsContent(in: controller)
        try button("Pause Receiving", in: settings).performClick(nil)
        eventually("receiving paused") { !controller.receiverStatus.listening }
        try button("Resume Receiving", in: settings).performClick(nil)
        eventually("receiving resumed") { controller.receiverStatus.listening }
        XCTAssertNotEqual(controller.receiverStatus.port, previousPort)
        eventually("local sender restores hidden snapshot on the new port", timeout: 10) {
            controller.receiverStatus.ownerID == owner && controller.receiverStatus.content == hidden
        }
        XCTAssertEqual(title.stringValue, "Private draft edit", "Reconnect must preserve the private draft")
        controller.showComposerPage()

        try button("Stop Presenting", in: root).performClick(nil)
        eventually("local ownership released") { controller.receiverStatus.ownerID == nil }
        let reopened = try settingsContent(in: controller)
        try button("Pause Receiving", in: reopened).performClick(nil)
        eventually("receiving paused after release") { !controller.receiverStatus.listening }
        try button("Resume Receiving", in: reopened).performClick(nil)
        eventually("released sender reconnects without publishing", timeout: 10) {
            controller.receiverStatus.listening && controller.receiverStatus.connections == 1
        }
        XCTAssertNil(controller.receiverStatus.ownerID)
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        controller.showComposerPage()
    }

    func testDefaultReceiversChooseIndependentPortsAndShowManualConnectionDetails() throws {
        let firstDomain = "AltViewTests.AutomaticPort.\(UUID())", secondDomain = "AltViewTests.AutomaticPort.\(UUID())"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstDomain))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondDomain))
        firstDefaults.set("Automatic port one", forKey: "receiverName")
        secondDefaults.set("Automatic port two", forKey: "receiverName")
        let key = try PairingKey.generate()
        // Exercise the real app default, without a test port override.
        let first = ReceiverWindowController(defaults: firstDefaults, pairingKey: key)
        let second = ReceiverWindowController(defaults: secondDefaults, pairingKey: try PairingKey.generate())
        defer {
            first.shutdown(); first.close(); second.shutdown(); second.close()
            firstDefaults.removePersistentDomain(forName: firstDomain); secondDefaults.removePersistentDomain(forName: secondDomain)
        }
        eventually("both defaults start without a port conflict") { first.receiverStatus.listening && second.receiverStatus.listening }
        let firstPort = try XCTUnwrap(first.receiverStatus.port), secondPort = try XCTUnwrap(second.receiverStatus.port)
        XCTAssertGreaterThan(firstPort, 0); XCTAssertGreaterThan(secondPort, 0)
        XCTAssertNotEqual(firstPort, secondPort)
        first.showWindow(nil)
        let settings = try settingsContent(in: first)
        let details = try XCTUnwrap(descendants(settings).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "receiverManualPort"
        })
        XCTAssertFalse(details.isHidden)
        XCTAssertTrue(details.stringValue.contains(String(firstPort)))
        XCTAssertFalse(details.isEditable, "Receiving ports are automatic, not a user setting")
        settings.layoutSubtreeIfNeeded()
        XCTAssertTrue(settings.bounds.contains(details.convert(details.bounds, to: settings)))
        try button("Pause Receiving", in: settings).performClick(nil)
        eventually("paused port is no longer advertised to the user") { !first.receiverStatus.listening && details.isHidden }
        try button("Resume Receiving", in: settings).performClick(nil)
        eventually("resumed port is shown") { first.receiverStatus.listening && !details.isHidden }
        XCTAssertTrue(details.stringValue.contains(String(try XCTUnwrap(first.receiverStatus.port))))
        var local: LocalReceiverConnection?
        first.connectLocal { local = try? $0.get() }
        eventually("local sender uses assigned port") { local != nil }
        XCTAssertEqual(local?.port, first.receiverStatus.port)
        XCTAssertEqual(local?.key, key)
        first.showReceiverPage()
    }

    func testReceiverPortRecoveryKeepsLocalPublicationWaiting() throws {
        let occupied = try OccupiedReceiverPort()
        defer { occupied.release() }
        let domain = "AltViewTests.PortRecovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: occupied.port)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        eventually("receiver is recovering") { controller.receiverStatus.starting && controller.receiverStatus.message.contains("retrying") }
        var connection: LocalReceiverConnection?
        controller.connectLocal { result in
            switch result {
            case .success(let value): connection = value
            case .failure(let error): XCTFail("Temporary conflict must keep publication pending: \(error)")
            }
        }
        XCTAssertNil(connection)
        occupied.release()
        eventually("pending local connection continues automatically") { connection != nil && controller.receiverStatus.listening }
        XCTAssertEqual(connection?.port, occupied.port)
        XCTAssertEqual(connection?.key, key)
        XCTAssertFalse(controller.receiverStatus.starting)
        XCTAssertNil(controller.receiverStatus.ownerID, "Starting a receiver alone must not publish text")
    }

    func testPauseReceivingCancelsPortRecoveryAndPendingPublication() throws {
        let occupied = try OccupiedReceiverPort()
        defer { occupied.release() }
        let domain = "AltViewTests.PausePortRecovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: occupied.port)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        controller.showWindow(nil)
        eventually("receiver is recovering") { controller.receiverStatus.starting && controller.receiverStatus.message.contains("retrying") }
        let settings = try settingsContent(in: controller)
        XCTAssertTrue(descendants(settings).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("retrying automatically") })
        let name = try field("Receiver name", in: settings)
        XCTAssertFalse(name.isEditable)
        let cancelled = expectation(description: "pending publication cancelled")
        controller.connectLocal { result in
            if case .success = result { XCTFail("Pause must cancel the pending local connection") }
            cancelled.fulfill()
        }
        try button("Pause Receiving", in: settings).performClick(nil)
        wait(for: [cancelled], timeout: 2)
        eventually("receiving paused") { !controller.receiverStatus.starting && !controller.receiverStatus.listening }
        XCTAssertTrue(name.isEditable)
        occupied.release()
        let settled = expectation(description: "cancelled retry cannot restart receiving")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertFalse(controller.receiverStatus.listening)
        XCTAssertFalse(controller.receiverStatus.starting)
        try button("Resume Receiving", in: settings).performClick(nil)
        eventually("explicit resume still works") { controller.receiverStatus.listening }
        XCTAssertFalse(name.isEditable)
    }

    func testReceiverAdvertisesSavedPolicyAndOnlyBroadcastsAppliedChanges() throws {
        let domain = "AltViewTests.TemplatePolicy.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        var saved = LowerThirdTemplate(); saved.textTemplate = .lyrics
        try defaults.set(JSONEncoder().encode(saved), forKey: "lowerThirdTemplate")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        var status = SenderStatus()
        let sender = SenderClient(name: "Policy observer") { status = $0 }
        defer { sender.disconnect(); controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        eventually("listener ready") { controller.receiverStatus.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(controller.receiverStatus.port))!), key: key)
        eventually("saved override in handshake") { status.connected && status.templateCapabilities.policy == .fixed(.lyrics) }
        controller.showReceiverPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        let selection = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Audience template" })
        selection.selectItem(withTitle: "Scripture"); selection.sendAction(selection.action, to: selection.target)
        XCTAssertEqual(status.templateCapabilities.policy, .fixed(.lyrics), "A design draft is private")
        try button("Apply Template", in: root).performClick(nil)
        eventually("applied override broadcast without publishing") { status.templateCapabilities.policy == .fixed(.scripture) }
        XCTAssertNil(controller.receiverStatus.ownerID)
        selection.selectItem(withTitle: "Custom layout"); selection.sendAction(selection.action, to: selection.target)
        XCTAssertEqual(status.templateCapabilities.policy, .fixed(.scripture), "An unapplied choice stays private")
        selection.selectItem(withTitle: "Scripture"); selection.sendAction(selection.action, to: selection.target)
        XCTAssertFalse(try button("Apply Template", in: root).isEnabled)
    }

    func testAudienceAssignmentIsSeparateFromDesignDraftsAndEditorOpensActiveDesign() throws {
        let domain = "AltViewTests.AudienceDesignSeparation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        var status = SenderStatus()
        let sender = SenderClient(name: "ViewTheWord") { status = $0 }
        defer { sender.disconnect(); controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        eventually("receiver ready") { controller.receiverStatus.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(controller.receiverStatus.port))!), key: key)
        eventually("sender connected") { status.connected }
        let source = DisplayContent(title: "Reference", body: "Actual verse", footer: "Translation", template: .scripture)
        sender.submit(source); sender.takeOutput()
        eventually("source accepted") { controller.receiverStatus.content == source }
        let root = try XCTUnwrap(controller.window?.contentView)
        let assignment = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Audience template"
        })
        controller.showDesignPage()
        let profiles = try editingTemplate(in: root)
        XCTAssertEqual(profiles.selectedSegment, DesignProfileID.allCases.firstIndex(of: .scripture))
        let editor = try XCTUnwrap(try button("Choose PNG…", in: root).target as? LowerThirdWindowController)
        XCTAssertTrue(descendants(editor.contentView).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "Audience uses Scripture · From ViewTheWord"
        })
        selectTemplate(.lyrics, in: profiles)
        let font = try XCTUnwrap(descendants(editor.contentView).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Draft font"
        })
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        XCTAssertTrue(editor.hasChanges)
        controller.showReceiverPage()
        assignment.selectItem(withTitle: "Lyrics"); assignment.sendAction(assignment.action, to: assignment.target)
        XCTAssertEqual(status.templateCapabilities.policy, .sender)
        try button("Apply Template", in: root).performClick(nil)
        eventually("assignment broadcast") { status.templateCapabilities.policy == .fixed(.lyrics) }
        var saved = try JSONDecoder().decode(TemplateDesignLibrary.self, from: XCTUnwrap(defaults.data(forKey: "templateDesignLibrary")))
        XCTAssertEqual(saved.lyrics.style.fontName, "System", "Applying assignment must not publish pending design edits")
        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(editor.draftLibrary?.lyrics.style.fontName, "Georgia")
        controller.showDesignPage()
        XCTAssertEqual(editor.editingProfile, .lyrics)
        let canvas = try XCTUnwrap(descendants(editor.contentView).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(canvas.content.body, source.body)
        XCTAssertEqual(canvas.style.fontName, "Georgia")
        try button("Apply Changes", in: root).performClick(nil)
        saved = try JSONDecoder().decode(TemplateDesignLibrary.self, from: XCTUnwrap(defaults.data(forKey: "templateDesignLibrary")))
        XCTAssertEqual(saved.selection, .lyrics)
        XCTAssertEqual(saved.lyrics.style.fontName, "Georgia")
        XCTAssertEqual(controller.receiverStatus.ownerID, sender.senderID)
        XCTAssertEqual(controller.receiverStatus.content, source)
        XCTAssertFalse(editor.hasChanges)
    }

    func testAudienceTemplatePreviewUpdatesBeforeApplyAndKeepsLiveOutputSeparate() throws {
        let domain = "AltViewTests.PendingAudiencePreview.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        var library = TemplateDesignLibrary()
        library.custom.style.fontName = "Georgia"
        try defaults.set(JSONEncoder().encode(library), forKey: "templateDesignLibrary")
        let key = try PairingKey.generate()
        let live = CanvasPresentation(reduceMotion: { true })
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0, presentation: live)
        var status = SenderStatus()
        let sender = SenderClient(name: "Verse sender") { status = $0 }
        defer { sender.disconnect(); controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        eventually("receiver ready") { controller.receiverStatus.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(controller.receiverStatus.port))!), key: key)
        eventually("sender connected") { status.connected }
        var source = DisplayContent(title: "Reference", body: "Current verse", footer: "Translation", template: .scripture)
        sender.submit(source); sender.takeOutput()
        eventually("verse accepted") { live.content == source }
        controller.showReceiverPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let assignment = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Audience template"
        })
        let heading = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "audiencePreviewHeading"
        })
        XCTAssertTrue(canvas.presentation === live)
        assignment.selectItem(withTitle: "Lyrics"); assignment.sendAction(assignment.action, to: assignment.target)
        XCTAssertFalse(canvas.presentation === live)
        XCTAssertEqual(canvas.presentation.template.textTemplate, .lyrics)
        XCTAssertEqual(canvas.accessibilityLabel(), "Current verse")
        XCTAssertEqual(heading.stringValue, "TEMPLATE PREVIEW · NOT APPLIED")
        XCTAssertEqual(live.template.textTemplate, .scripture)
        XCTAssertEqual(status.templateCapabilities.policy, .sender)
        source.body = "Next verse"
        sender.submit(source)
        eventually("pending preview follows incoming text") { canvas.content.body == "Next verse" && live.content.body == "Next verse" }
        XCTAssertEqual(canvas.presentation.template.textTemplate, .lyrics)
        XCTAssertEqual(live.template.textTemplate, .scripture)
        assignment.selectItem(withTitle: "From sending app"); assignment.sendAction(assignment.action, to: assignment.target)
        XCTAssertTrue(canvas.presentation === live, "Returning to the applied choice restores the live preview and its animation clock")
        XCTAssertEqual(canvas.accessibilityLabel(), "Reference\nNext verse\nTranslation")
        XCTAssertEqual(heading.stringValue, "THIS MAC · AUDIENCE PREVIEW")
        assignment.selectItem(withTitle: "Custom layout"); assignment.sendAction(assignment.action, to: assignment.target)
        XCTAssertEqual(canvas.style.fontName, "Georgia")
        XCTAssertEqual(live.style.fontName, "System")
        try button("Apply Template", in: root).performClick(nil)
        eventually("applied template advertised") { status.templateCapabilities.policy == .custom }
        XCTAssertTrue(canvas.presentation === live)
        XCTAssertEqual(live.template.textTemplate, .custom)
        XCTAssertEqual(live.style.fontName, "Georgia")
        XCTAssertEqual(live.content, source)
        XCTAssertEqual(controller.receiverStatus.ownerID, sender.senderID)
        assignment.selectItem(withTitle: "Lyrics"); assignment.sendAction(assignment.action, to: assignment.target)
        sender.releaseOutput()
        eventually("pending preview clears with ownership loss") { controller.receiverStatus.ownerID == nil && canvas.content == .empty && live.content == .empty }
        XCTAssertEqual(canvas.presentation.template.textTemplate, .lyrics)
    }

    func testAudienceTemplateAssignmentWaitsForSavedArtworkRecovery() throws {
        let domain = "AltViewTests.AudienceTemplateArtwork.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        var library = TemplateDesignLibrary()
        library.lyrics.template.enabled = true; library.lyrics.template.artwork = .custom
        library.lyrics.template.assetID = UUID(); library.lyrics.template.assetName = "missing.png"
        try defaults.set(JSONEncoder().encode(library), forKey: "templateDesignLibrary")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        let root = try XCTUnwrap(controller.window?.contentView)
        let assignment = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Audience template"
        })
        let apply = try button("Apply Template", in: root)
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let live = canvas.presentation
        assignment.selectItem(withTitle: "Lyrics"); assignment.sendAction(assignment.action, to: assignment.target)
        XCTAssertFalse(apply.isEnabled)
        XCTAssertEqual(canvas.presentation.template.textTemplate, .lyrics)
        XCTAssertFalse(canvas.content.visible)
        XCTAssertEqual(live.template.textTemplate, .custom)
        apply.performClick(nil)
        var saved = try JSONDecoder().decode(TemplateDesignLibrary.self, from: XCTUnwrap(defaults.data(forKey: "templateDesignLibrary")))
        XCTAssertEqual(saved.selection, .sender)
        controller.showDesignPage()
        let profiles = try editingTemplate(in: root)
        eventually("saved artwork lookup finished") { profiles.isEnabled }
        selectTemplate(.lyrics, in: profiles)
        try button("Artwork", in: root).performClick(nil)
        try button("Apply Changes", in: root).performClick(nil)
        controller.showReceiverPage()
        XCTAssertTrue(apply.isEnabled, "The pending audience choice remains available after design recovery")
        apply.performClick(nil)
        saved = try JSONDecoder().decode(TemplateDesignLibrary.self, from: XCTUnwrap(defaults.data(forKey: "templateDesignLibrary")))
        XCTAssertEqual(saved.selection, .lyrics)
        XCTAssertFalse(saved.lyrics.template.showsArtwork)
    }

    func testComposerDiscoversFutureTemplatesAndKeepsSelectionPrivateAcrossCatalogueChanges() throws {
        let domain = "AltViewTests.TemplateMenu.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Jordan Lee")), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let first = TemplateDescriptor(id: ContentTemplate(rawValue: "intro-one"), name: "Speaker")
        let second = TemplateDescriptor(id: ContentTemplate(rawValue: "intro-two"), name: "Speaker")
        let capabilities = TemplateCapabilities(templates: [first, second], policy: .sender)
        let receiver = try TemplateTestReceiver(key: key, capabilities: capabilities)
        let listening = expectation(description: "template menu receiver ready")
        receiver.start { listening.fulfill() }
        defer { receiver.stop() }
        wait(for: [listening], timeout: 3)
        var received: [DisplayContent] = []
        receiver.onContent = { received.append($0) }
        let controller = TextComposerViewController(defaults: defaults,
            loadPairing: { _ in nil }, storePairing: { _, _ in }) { _ in XCTFail("Must connect remotely") }
        let window = layoutWindow(); window.isReleasedWhenClosed = false; window.contentView = controller.view
        defer { controller.shutdown(); window.close() }
        let root = controller.view
        let destination = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Text destination" })
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Requested text template" })
        destination.selectItem(at: 1); destination.sendAction(destination.action, to: destination.target)
        XCTAssertFalse(picker.isEnabled)
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try button("Connect using an address instead", in: sheet).performClick(nil)
        try field("Receiver address", in: sheet).stringValue = "127.0.0.1"
        try field("Receiver port", in: sheet).stringValue = String(try XCTUnwrap(receiver.port).rawValue)
        let code = try field("Pairing code", in: sheet); code.stringValue = PairingKey.text(key)
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: code))
        try button("Connect Only", in: sheet).performClick(nil)
        eventually("discovered choices populated") { window.attachedSheet == nil && picker.isEnabled && picker.numberOfItems == 3 }
        XCTAssertEqual(picker.itemTitles, ["Receiver’s layout", "Speaker", "Speaker"], "IDs, not display names, identify templates")
        picker.selectItem(at: 2); picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(controller.draft.template, second.id)
        XCTAssertTrue(received.isEmpty, "Choosing a template never takes output")
        try button("Publish Text", in: root).performClick(nil)
        eventually("chosen opaque ID published") { received.last?.template == second.id }
        let selectedItem = picker.selectedItem
        receiver.updateCapabilities(TemplateCapabilities(templates: [first, second], policy: .custom))
        eventually("override feedback shown") {
            self.descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("AltView overrides sender templates") }
        }
        XCTAssertTrue(picker.selectedItem === selectedItem, "Ordinary status updates must not rebuild the menu")
        receiver.updateCapabilities(TemplateCapabilities(templates: [first], policy: .fixed(first.id)))
        eventually("removed choice retained but unavailable") { picker.titleOfSelectedItem == "intro-two · Unavailable" }
        XCTAssertFalse(try XCTUnwrap(picker.selectedItem).isEnabled)
        XCTAssertEqual(controller.draft.template, second.id)
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("AltView uses Speaker for every message.") })
        try button("Publish Text", in: root).performClick(nil)
        eventually("unavailable request omitted on next publish") { received.count == 2 && received.last?.template == nil }
        receiver.updateCapabilities(capabilities)
        eventually("restored choice becomes selectable again") { picker.selectedItem?.representedObject as? String == second.id.rawValue && picker.selectedItem?.isEnabled == true }
        XCTAssertEqual(controller.draft.template, second.id)
    }

    func testTemplateSamplesFitCompactWorkspaceAndComposerNotesMatchForcedLyrics() throws {
        let domain = "AltViewTests.Templates.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "customTextEnabled")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        let window = try XCTUnwrap(controller.window), root = try XCTUnwrap(window.contentView)
        window.setContentSize(NSSize(width: 1160, height: 650))
        controller.showDesignPage()
        let samples = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Design preview content" })
        let selection = try editingTemplate(in: root)
        for name in ["Scripture", "Lyrics"] {
            selectTemplate(try XCTUnwrap(DesignProfileID(rawValue: name)), in: selection)
            samples.selectItem(withTitle: "Sample · \(name)"); samples.sendAction(samples.action, to: samples.target)
            root.layoutSubtreeIfNeeded()
            let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
            XCTAssertGreaterThan(preview.bounds.width, 400)
            XCTAssertEqual(preview.bounds.width / preview.bounds.height, 16.0 / 9, accuracy: 0.01)
            XCTAssertTrue(root.bounds.contains(selection.convert(selection.bounds, to: root)))
            XCTAssertTrue(root.bounds.contains(try button("Apply Changes", in: root).convert(try button("Apply Changes", in: root).bounds, to: root)))
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "Template-\(name)-compact"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        controller.showReceiverPage()
        root.layoutSubtreeIfNeeded()
        let audienceBitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: audienceBitmap)
        let audienceData = try XCTUnwrap(audienceBitmap.representation(using: .png, properties: [:]))
        let audienceAttachment = XCTAttachment(data: audienceData, uniformTypeIdentifier: "public.png")
        audienceAttachment.name = "Audience-template-compact"; audienceAttachment.lifetime = .keepAlways
        add(audienceAttachment)
        let assignment = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Audience template" })
        assignment.selectItem(withTitle: "Lyrics"); assignment.sendAction(assignment.action, to: assignment.target)
        try button("Apply Template", in: root).performClick(nil)
        controller.showComposerPage()
        XCTAssertEqual(descendants(root).compactMap { $0 as? NSTextField }.filter { $0.stringValue == "Hidden by Design · text is kept" }.count, 2)
        controller.showDesignPage()
        try button("Revert All Changes", in: root).performClick(nil)
    }

    func testTextTemplatesPreviewApplyRevertAndPreserveCustomSettings() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true; baseline.alignment = .right
        baseline.showsTitle = false
        var style = OutputStyle(); style.alignment = .right
        controller.update(template: baseline, style: style, artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        func picker(_ name: String) throws -> NSPopUpButton {
            try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == name })
        }
        let selection = try picker("Template")
        let samples = try picker("Design preview content")
        let alignment = try picker("Lower third text alignment")
        let title = try button("Title", in: root), footer = try button("Footer", in: root)
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        var applied: LowerThirdTemplate?
        controller.onApply = { value, _ in applied = value }
        samples.selectItem(withTitle: "Lyrics"); samples.sendAction(samples.action, to: samples.target)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Center")
        XCTAssertFalse(alignment.isEnabled); XCTAssertFalse(title.isEnabled); XCTAssertFalse(footer.isEnabled)
        XCTAssertEqual(title.state, .off); XCTAssertEqual(footer.state, .off)
        XCTAssertEqual(preview.accessibilityLabel(), DisplayContent.lyrics.body)
        XCTAssertFalse(controller.hasChanges, "Selecting a sample cannot edit the design")
        selection.selectItem(withTitle: "Scripture"); selection.sendAction(selection.action, to: selection.target)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Left")
        XCTAssertEqual(title.state, .on); XCTAssertEqual(footer.state, .on)
        XCTAssertNil(applied)
        XCTAssertTrue(controller.hasChanges)
        controller.revertChanges()
        XCTAssertEqual(selection.titleOfSelectedItem, "From sending app")
        XCTAssertEqual(alignment.titleOfSelectedItem, "Center")
        selection.selectItem(withTitle: "Lyrics"); selection.sendAction(selection.action, to: selection.target)
        // Changes to other controls cannot save the preset over the custom rows/alignment.
        try button("Artwork", in: root).performClick(nil)
        controller.applyChanges()
        XCTAssertEqual(applied?.textTemplate, .lyrics)
        XCTAssertEqual(applied?.alignment, .right)
        XCTAssertEqual(applied?.showsTitle, false); XCTAssertEqual(applied?.showsFooter, true)
        selection.selectItem(withTitle: "Custom layout"); selection.sendAction(selection.action, to: selection.target)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Right")
        XCTAssertTrue(alignment.isEnabled); XCTAssertTrue(title.isEnabled); XCTAssertTrue(footer.isEnabled)
        XCTAssertEqual(title.state, .off); XCTAssertEqual(footer.state, .on)
        XCTAssertEqual(controller.style.alignment, .right)
        controller.revertChanges()
        XCTAssertEqual(selection.titleOfSelectedItem, "Lyrics")
        // Source updates must refresh both the preview and the available controls.
        selection.selectItem(withTitle: "From sending app"); selection.sendAction(selection.action, to: selection.target)
        let scripture = DisplayContent(title: "Reference", body: "Verse", footer: "Translation", template: .scripture)
        controller.updateContent(draft: .empty, source: scripture, externalSource: "ViewTheWord", customTextEnabled: false)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Left")
        XCTAssertEqual(preview.accessibilityLabel(), "Reference\nVerse\nTranslation")
        controller.updateContent(draft: .empty, source: DisplayContent(body: "Custom"), externalSource: "ViewTheWord", customTextEnabled: false)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Right")
        XCTAssertTrue(alignment.isEnabled)
    }

    func testOutputReadinessTracksPreviewSleepCloseAndMissingDisplay() throws {
        _ = NSApplication.shared
        let controller = OutputWindowController(presentation: CanvasPresentation())
        var states: [OutputReadiness] = []
        controller.onReadinessChange = { states.append($0) }
        defer { controller.stop() }
        XCTAssertEqual(controller.readiness, .closed)
        controller.show(displayID: nil)
        XCTAssertEqual(controller.readiness, .preview)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(controller.readiness, .asleep)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(controller.readiness, .preview)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "AltView — Preview Audience" && $0.isVisible })
        window.close()
        XCTAssertEqual(controller.readiness, .closed)
        controller.show(displayID: UInt32.max)
        XCTAssertEqual(controller.readiness, .displayMissing)
        controller.stop()
        XCTAssertEqual(states, [.preview, .asleep, .preview, .closed, .displayMissing, .closed])
    }
    func testReceiverWindowReportsReadinessOverTheConnection() throws {
        let key = try PairingKey.generate()
        let domain = "AltViewTests.Feedback.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        var status = SenderStatus()
        let sender = SenderClient(name: "Window feedback") { status = $0 }
        defer { sender.disconnect(); controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        eventually("receiver listening") { controller.receiverStatus.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(controller.receiverStatus.port))!), key: key)
        eventually("closed reported") { status.feedback.output == .closed }
        let root = try XCTUnwrap(controller.window?.contentView)
        try button("Open Display", in: root).performClick(nil)
        eventually("preview reported") { status.feedback.output == .preview }
        controller.closeOutput()
        eventually("close reported") { status.feedback.output == .closed }
    }

    private func layoutWindow() -> NSWindow {
        LayoutTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    }
    private func eventually(_ description: String, timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) {
        let done = expectation(description: description)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() {
            if predicate() { done.fulfill() }
            else if ProcessInfo.processInfo.systemUptime < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check) }
        }
        check(); wait(for: [done], timeout: timeout + 0.5)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func editingTemplate(in view: NSView) throws -> NSSegmentedControl {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSSegmentedControl }.first {
            $0.accessibilityIdentifier() == "editingTemplate"
        })
    }
    private func selectTemplate(_ profile: DesignProfileID, in control: NSSegmentedControl) {
        control.selectedSegment = DesignProfileID.allCases.firstIndex(of: profile)!
        control.sendAction(control.action, to: control.target)
    }
    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }
    private func field(_ label: String, in view: NSView) throws -> NSTextField {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label })
    }
    private func visibleSettingsContent() -> NSView? {
        NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(descendants)
            .first { $0.accessibilityIdentifier() == "workspaceSettingsContent" }
    }
    private func settingsContent(in controller: ReceiverWindowController) throws -> NSView {
        controller.showConnectionsPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        return try XCTUnwrap(descendants(root).first {
            $0.accessibilityIdentifier() == "workspaceConnectionsContent"
        })
    }
    private func sidebar(in root: NSView) throws -> NSOutlineView {
        try XCTUnwrap(descendants(root).compactMap { $0 as? NSOutlineView }.first)
    }
    private func sidebarTitles(_ navigation: NSOutlineView) -> [String] {
        (0..<navigation.numberOfRows).compactMap { row in
            guard let column = navigation.tableColumns.first,
                  let item = navigation.item(atRow: row),
                  let cell = navigation.delegate?.outlineView?(navigation, viewFor: column, item: item) as? NSTableCellView else { return nil }
            return cell.textField?.stringValue
        }
    }
    private func selectedSidebarTitle(_ navigation: NSOutlineView) -> String {
        let titles = sidebarTitles(navigation)
        return navigation.selectedRow >= 0 ? titles[navigation.selectedRow] : ""
    }
    private func settingsSwitch(in controller: ReceiverWindowController) throws -> NSSwitch {
        controller.showSettings()
        let settings = try XCTUnwrap(visibleSettingsContent())
        return try XCTUnwrap(descendants(settings).compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityIdentifier() == "enableCustomText"
        })
    }
    func testComposerEmptyRowPreferencePreviewsPublishesAndPersists() throws {
        let domain = "AltViewTests.EmptyRows.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Body only")), forKey: "customTextDraft")
        var template = LowerThirdTemplate(); template.enabled = true
        try defaults.set(JSONEncoder().encode(template), forKey: "lowerThirdTemplate")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let keepSpace = try button("Keep space for empty Title and Footer", in: root)
        let publish = try button("Publish Text & Design", in: root)
        XCTAssertTrue(root.bounds.contains(publish.convert(publish.bounds, to: root)))
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(keepSpace.state, .off)
        keepSpace.performClick(nil)
        XCTAssertEqual(preview.content.emptyRegions, .reserve)
        XCTAssertEqual(controller.receiverStatus.content, .empty, "Changing spacing must remain private")
        publish.performClick(nil)
        eventually("spacing sent over the local connection") { controller.receiverStatus.content.emptyRegions == .reserve }
        keepSpace.performClick(nil)
        XCTAssertEqual(controller.receiverStatus.content.emptyRegions, .reserve, "Later edits must stay private")
        publish.performClick(nil)
        eventually("automatic spacing published") { controller.receiverStatus.content.emptyRegions == .collapse }
        let badge = try XCTUnwrap(descendants(root).compactMap { $0 as? StatusBadge }.first {
            $0.accessibilityIdentifier() == "composerPresentationStatus"
        })
        XCTAssertEqual(badge.text, "PUBLISHED")
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "workspaceContentStatus" })
        let changes = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "textDraftStatus" })
        XCTAssertTrue(changes.isHidden, "Publishing must clear the change indicator")
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Audience window closed") })
        keepSpace.performClick(nil)
        XCTAssertFalse(changes.isHidden)
        try button("Hide Text", in: root).performClick(nil)
        // The composer badge updates immediately; the receiver changes after
        // the snapshot travels over the local connection and returns to the UI.
        eventually("hidden content reflected in the workspace and receiver") {
            badge.text == "HIDDEN" && !controller.receiverStatus.content.visible
        }
        XCTAssertFalse(controller.receiverStatus.content.visible)
        try button("Show Last Text", in: root).performClick(nil)
        eventually("showing last text keeps the new spacing private") {
            badge.text == "PUBLISHED" && controller.receiverStatus.content.visible
        }
        XCTAssertEqual(controller.receiverStatus.content.emptyRegions, .collapse)
        XCTAssertFalse(changes.isHidden)
        try button("Stop Presenting", in: root).performClick(nil)
        eventually("released content reflected in the workspace") { badge.text == "NOT PRESENTING" && controller.receiverStatus.ownerID == nil }
        XCTAssertNil(controller.receiverStatus.ownerID)
        controller.showReceiverPage()
        let outputBadge = try XCTUnwrap(descendants(root).compactMap { $0 as? StatusBadge }.first {
            $0.accessibilityIdentifier() == "workspaceContentStatus"
        })
        XCTAssertEqual(outputBadge.text, "NO TEXT")
        controller.shutdown()
        let saved = try JSONDecoder().decode(DisplayContent.self, from: XCTUnwrap(defaults.data(forKey: "customTextDraft")))
        XCTAssertEqual(saved.emptyRegions, .reserve)
    }
    func testReceiverStartsAutomaticallyAndPauseSurvivesPageChanges() throws {
        let domain = "AltViewTests.Receiver.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let navigation = try sidebar(in: root)
        XCTAssertEqual(sidebarTitles(navigation), ["Outputs", "Audience", "Confidence", "Setup", "Connections"])
        XCTAssertEqual(selectedSidebarTitle(navigation), "Audience")
        eventually("ready without a click") { controller.receiverStatus.listening }
        XCTAssertNil(controller.receiverStatus.ownerName)
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "receiverPairingCode" })
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "receiverListeningStatus" })
        XCTAssertFalse(descendants(root).compactMap { $0 as? NSButton }.contains { $0.title == "Pair a sender…" })
        let settings = try settingsContent(in: controller)
        XCTAssertEqual(selectedSidebarTitle(navigation), "Connections")
        settings.layoutSubtreeIfNeeded()
        let code = try field("Pairing code", in: settings)
        XCTAssertEqual(code.stringValue, PairingKey.text(try XCTUnwrap(controller.pairingKey)))
        let controls: [NSView] = [code, try button("Copy Code", in: settings), try button("Reset Code…", in: settings),
                                  try button("Pause Receiving", in: settings)]
        for control in controls {
            XCTAssertTrue(settings.bounds.contains(control.convert(control.bounds, to: settings)))
        }
        try button("Pause Receiving", in: settings).performClick(nil)
        eventually("paused") { !controller.receiverStatus.listening }
        let name = try field("Receiver name", in: settings)
        XCTAssertTrue(name.isEditable)
        name.stringValue = "Presentation Mac"
        controller.showReceiverPage()
        controller.setCustomTextEnabled(true); controller.showComposerPage(); controller.showReceiverPage()
        XCTAssertFalse(controller.receiverStatus.listening)
        let reopenedSettings = try settingsContent(in: controller)
        try button("Resume Receiving", in: reopenedSettings).performClick(nil)
        eventually("resumed") { controller.receiverStatus.listening }
        XCTAssertFalse(name.isEditable)
        XCTAssertEqual(defaults.string(forKey: "receiverName"), "Presentation Mac")
        XCTAssertEqual(code.stringValue, PairingKey.text(try XCTUnwrap(controller.pairingKey)))
    }
    func testCustomTextOptInPreservesDraftAndRestoresWithoutPublishing() throws {
        let domain = "AltViewTests.CustomTextOptIn.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let draft = DisplayContent(body: "Saved private message")
        try defaults.set(JSONEncoder().encode(draft), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        let navigation = try sidebar(in: root)
        eventually("receiver ready with Custom Text disabled") { controller.receiverStatus.listening }
        XCTAssertFalse(controller.customTextEnabled, "An existing saved draft must not opt the user in")
        XCTAssertEqual(sidebarTitles(navigation), ["Outputs", "Audience", "Confidence", "Setup", "Connections"])
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "receiverPairingCode" })
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.allSatisfy { $0.accessibilityLabel() != "Text title" })

        controller.showDesignPage()
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Design preview content" })
        XCTAssertNil(picker.item(withTitle: "Text draft"))
        XCTAssertEqual(picker.titleOfSelectedItem, "Sample · Speaker")
        XCTAssertTrue(try button("Edit Text…", in: root).isHidden)
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(preview.content.body, "Jordan Lee", "Design stays useful without the hidden text draft")
        picker.selectItem(withTitle: "Sample · Announcement"); picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(preview.content.body, "A place to belong")
        XCTAssertEqual(controller.receiverStatus.content, .empty, "Samples must never reach output")

        var enableNotifications = 0
        controller.onCustomTextSettingChange = { enableNotifications += 1 }
        let toggle = try settingsSwitch(in: controller)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertFalse(controller.customTextEnabled, "Opening Settings alone must not enable Custom Text")
        toggle.state = .on; toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertEqual(selectedSidebarTitle(navigation), "Audience", "Design remains associated with Audience")
        visibleSettingsContent()?.window?.close()
        controller.showComposerPage()
        XCTAssertTrue(controller.customTextEnabled)
        XCTAssertTrue(defaults.bool(forKey: "customTextEnabled"))
        XCTAssertEqual(sidebarTitles(navigation).filter { $0 == "Text" }.count, 1)
        XCTAssertEqual(selectedSidebarTitle(navigation), "Text")
        let composerPreview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(composerPreview.content, draft)
        XCTAssertEqual(controller.receiverStatus.connections, 0)
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        controller.showDesignPage()
        XCTAssertEqual(picker.titleOfSelectedItem, "Sample · Announcement", "Enabling Custom Text preserves the chosen design preview")
        XCTAssertNotNil(picker.item(withTitle: "Text draft"))
        XCTAssertFalse(try button("Edit Text…", in: root).isHidden)
        try button("Edit Text…", in: root).performClick(nil)
        XCTAssertEqual(enableNotifications, 1)
        XCTAssertEqual(sidebarTitles(navigation).filter { $0 == "Text" }.count, 1, "Reopening Text must not duplicate its page")
        controller.shutdown(); controller.close()

        let reopened = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { reopened.shutdown(); reopened.close() }
        let reopenedRoot = try XCTUnwrap(reopened.window?.contentView)
        let restoredNavigation = try sidebar(in: reopenedRoot)
        XCTAssertTrue(reopened.customTextEnabled)
        XCTAssertEqual(sidebarTitles(restoredNavigation).filter { $0 == "Text" }.count, 1)
        XCTAssertEqual(selectedSidebarTitle(restoredNavigation), "Audience")
        eventually("reopened receiver ready") { reopened.receiverStatus.listening }
        XCTAssertEqual(reopened.receiverStatus.connections, 0)
        XCTAssertNil(reopened.receiverStatus.ownerID)
        XCTAssertEqual(reopened.receiverStatus.content, .empty)
        reopened.showComposerPage()
        XCTAssertEqual(try XCTUnwrap(descendants(reopenedRoot).compactMap { $0 as? OutputCanvas }.first).content, draft)
    }
    func testConnectionsAreSharedAndNativeSidebarTracksOutputAndDesignNavigation() throws {
        let domain = "AltViewTests.Sidebar.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0, window: layoutWindow())
        defer { controller.shutdown(); controller.close() }
        controller.showWindow(nil)
        let root = try XCTUnwrap(controller.window?.contentView)
        let navigation = try sidebar(in: root)
        XCTAssertFalse(descendants(root).compactMap { $0 as? NSSegmentedControl }.contains { $0.accessibilityLabel() == "AltView workspace" })
        controller.showConfidencePage()
        XCTAssertEqual(selectedSidebarTitle(navigation), "Confidence")
        let connections = try settingsContent(in: controller)
        XCTAssertEqual(selectedSidebarTitle(navigation), "Connections")
        let status = try XCTUnwrap(descendants(connections).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "receiverPairingStatus" })
        eventually("receiver ready") { controller.receiverStatus.port != nil }
        XCTAssertEqual(status.stringValue, "No sender connected")
        let sender = SenderClient(name: "Presentation Mac") { _ in }
        defer { sender.disconnect() }
        let endpoint = Network.NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(controller.receiverStatus.port))!)
        sender.connect(to: endpoint, key: key)
        eventually("paired without publishing") { controller.receiverStatus.connections == 1 }
        XCTAssertEqual(status.stringValue, "1 sender connected")
        XCTAssertNil(controller.receiverStatus.ownerID)
        let second = SenderClient(name: "Second Mac") { _ in }
        defer { second.disconnect() }
        second.connect(to: endpoint, key: key)
        eventually("both named senders") { controller.receiverStatus.connections == 2 }
        XCTAssertEqual(status.stringValue, "2 senders connected")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            controller.window?.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1160, height: 650), NSSize(width: 1440, height: 900)] {
                controller.window?.setContentSize(size)
                root.layoutSubtreeIfNeeded()
                for title in ["Copy Code", "Reset Code…", "Pause Receiving"] {
                    let control = try button(title, in: connections)
                    XCTAssertTrue(root.bounds.contains(control.convert(control.bounds, to: root)))
                }
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/altview-connections-\(appearance.rawValue)-\(Int(size.width)).png"))
                attachment.name = "Sidebar-Connections-\(appearance.rawValue)-\(Int(size.width))"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let list = try XCTUnwrap(descendants(connections).compactMap { $0 as? NSTableView }.first { $0.accessibilityIdentifier() == "receiverSenderList" })
        XCTAssertEqual(list.numberOfRows, 2)
        func senderAction(_ senderID: UUID) throws -> NSButton {
            let row = try XCTUnwrap(controller.receiverStatus.senderConnections.firstIndex { $0.senderID == senderID })
            let cell = try XCTUnwrap(list.view(atColumn: 1, row: row, makeIfNecessary: true))
            return try XCTUnwrap(descendants(cell).compactMap { $0 as? NSButton }.first)
        }
        sender.submit(.scripture); sender.takeOutput()
        eventually("sender is shown as presenting") { controller.receiverStatus.senderConnections.contains { $0.senderID == sender.senderID && $0.isPresenting } }
        let disconnectIdle = try senderAction(second.senderID)
        XCTAssertEqual(disconnectIdle.title, "Disconnect")
        disconnectIdle.performClick(nil)
        eventually("idle sender disconnected") { controller.receiverStatus.connections == 1 && controller.receiverStatus.senderConnections.contains { $0.senderID == second.senderID && $0.isDisconnected } }
        XCTAssertEqual(controller.receiverStatus.content, .scripture)
        let allow = try senderAction(second.senderID)
        XCTAssertEqual(allow.title, "Allow Reconnect")
        allow.performClick(nil)
        eventually("idle sender automatically reconnects when allowed") { controller.receiverStatus.connections == 2 }
        try senderAction(sender.senderID).performClick(nil)
        eventually("disconnecting the presenter clears its output") { controller.receiverStatus.connections == 1 && controller.receiverStatus.ownerID == nil && controller.receiverStatus.content == .empty }
        XCTAssertTrue(controller.receiverStatus.listening)
        controller.showReceiverPage()
        XCTAssertEqual(selectedSidebarTitle(navigation), "Audience")
        try button("Edit Audience Design", in: root).performClick(nil)
        XCTAssertEqual(selectedSidebarTitle(navigation), "Audience")
        XCTAssertNotNil(try button("Back to Audience", in: root))
        try button("Back to Audience", in: root).performClick(nil)
        XCTAssertNotNil(try button("Edit Audience Design", in: root))
        controller.showSettings()
        let settings = try XCTUnwrap(visibleSettingsContent())
        XCTAssertFalse(descendants(settings).contains { $0.accessibilityIdentifier() == "receiverPairingCode" })
        XCTAssertEqual(selectedSidebarTitle(navigation), "Audience")
        sender.disconnect(); second.disconnect()
        eventually("all senders disconnected") { controller.receiverStatus.connections == 0 }
    }
    func testTurningOffCustomTextStopsSendingAndKeepsDraftPrivateOnReenable() throws {
        let domain = "AltViewTests.DisableCustomText.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Currently published")), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.showReceiverPage()
        controller.showComposerPage()
        try button("Publish Text & Design", in: root).performClick(nil)
        eventually("custom text owns output") { controller.receiverStatus.ownerID != nil }
        let title = try field("Text title", in: root)
        title.stringValue = "Next private title"
        title.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: title))

        let toggle = try settingsSwitch(in: controller)
        XCTAssertEqual(toggle.state, .on)
        toggle.state = .off; toggle.sendAction(toggle.action, to: toggle.target)
        controller.showSettings()
        eventually("turning off disconnects only Custom Text") {
            controller.receiverStatus.ownerID == nil && controller.receiverStatus.connections == 0
        }
        XCTAssertTrue(controller.receiverStatus.listening)
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        let navigation = try sidebar(in: root)
        XCTAssertEqual(sidebarTitles(navigation), ["Outputs", "Audience", "Confidence", "Setup", "Connections"])
        XCTAssertEqual(selectedSidebarTitle(navigation), "Audience")
        XCTAssertFalse(defaults.bool(forKey: "customTextEnabled"))
        controller.showComposerPage()
        XCTAssertFalse(controller.customTextEnabled, "A stale Text shortcut cannot enable the feature")
        controller.showDesignPage()
        XCTAssertTrue(try button("Edit Text…", in: root).isHidden)
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Design preview content" })
        XCTAssertNil(picker.item(withTitle: "Text draft"))

        controller.setCustomTextEnabled(true); controller.showComposerPage()
        XCTAssertEqual(try field("Text title", in: root).stringValue, "Next private title")
        XCTAssertEqual(controller.receiverStatus.connections, 0)
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        try button("Publish Text & Design", in: root).performClick(nil)
        eventually("explicit publication still works after reenabling") { controller.receiverStatus.content.title == "Next private title" }
        controller.setCustomTextEnabled(false)
        controller.shutdown(); controller.close()

        let reopened = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { reopened.shutdown(); reopened.close() }
        XCTAssertFalse(reopened.customTextEnabled)
        let saved = try JSONDecoder().decode(DisplayContent.self, from: XCTUnwrap(defaults.data(forKey: "customTextDraft")))
        XCTAssertEqual(saved.title, "Next private title")
    }
    func testCompactWorkspaceKeepsCanvasAndActionsVisibleInBothAppearances() throws {
        let domain = "AltViewTests.CompactWorkspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent.scripture), forKey: "customTextDraft")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0,
                                                  window: layoutWindow())
        defer { controller.shutdown(); controller.close() }
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        controller.setCustomTextEnabled(true)
        controller.showWindow(nil)
        root.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 1160, height: 650))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for (showPage, action) in [
                (controller.showComposerPage, "Publish Text & Design"),
                (controller.showDesignPage, "Apply Changes"),
                (controller.showReceiverPage, "Open Display")
            ] {
                showPage()
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(root.bounds.width, 1160, accuracy: 1, "Changing pages must not enlarge the window")
                XCTAssertEqual(root.bounds.height, 650, accuracy: 1, "Opening \(action) in \(appearance.rawValue) must not enlarge the window")
                let primary = try button(action, in: root)
                XCTAssertTrue(root.bounds.contains(primary.convert(primary.bounds, to: root)), action)
                XCTAssertFalse(primary.visibleRect.isEmpty, "\(action) must not be clipped by a scroll view")
                let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
                let frame = canvas.convert(canvas.bounds, to: root)
                XCTAssertTrue(root.bounds.contains(frame), "Preview stays inside the compact workspace")
                XCTAssertGreaterThan(frame.width, 300)
                XCTAssertEqual(frame.width / frame.height, 16.0 / 9, accuracy: 0.01)
                let statusID = action == "Publish Text & Design" ? "composerPresentationStatus"
                    : action == "Apply Changes" ? "designDraftStatus" : "workspaceContentStatus"
                let status = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == statusID })
                XCTAssertTrue(root.bounds.contains(status.convert(status.bounds, to: root)))
                if action != "Open Display" {
                    XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "workspaceContentStatus" },
                                   "Receiver status belongs only on Output")
                }
            }
        }
        controller.showDesignPage()
        root.layoutSubtreeIfNeeded()
        let inspector = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(try XCTUnwrap(inspector.documentView).frame.height, inspector.contentSize.height)
    }
    func testDesignPreviewKeepsItsSizeWhenSwitchingLayouts() throws {
        let domain = "AltViewTests.DesignPreviewSize.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var template = LowerThirdTemplate(); template.enabled = true
        var style = OutputStyle(); style.background = "0000FF"
        try defaults.set(JSONEncoder().encode(template), forKey: "lowerThirdTemplate")
        try defaults.set(JSONEncoder().encode(style), forKey: "outputStyle")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0,
                                                  window: layoutWindow())
        defer { controller.shutdown(); controller.close() }
        controller.showDesignPage()
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let stage = try XCTUnwrap(canvas.superview)
        let mode = try button("Use lower-third layout", in: root)
        for size in [NSSize(width: 1160, height: 650), NSSize(width: 1280, height: 800), NSSize(width: 1520, height: 900)] {
            window.setContentSize(size)
            root.layoutSubtreeIfNeeded()
            let originalStage = stage.convert(stage.bounds, to: root)
            let originalCanvas = canvas.convert(canvas.bounds, to: root)
            for _ in 0..<4 {
                mode.performClick(nil)
                root.layoutSubtreeIfNeeded()
                let currentStage = stage.convert(stage.bounds, to: root)
                let currentCanvas = canvas.convert(canvas.bounds, to: root)
                XCTAssertEqual(root.bounds.width, size.width, accuracy: 1)
                XCTAssertEqual(root.bounds.height, size.height, accuracy: 1)
                XCTAssertEqual(currentStage.minY, originalStage.minY, accuracy: 1)
                XCTAssertEqual(currentStage.height, originalStage.height, accuracy: 1, "Hiding layout controls must not resize the preview stage")
                XCTAssertEqual(currentCanvas.width, originalCanvas.width, accuracy: 1)
                XCTAssertEqual(currentCanvas.height, originalCanvas.height, accuracy: 1)
                XCTAssertEqual(currentCanvas.width / currentCanvas.height, 16.0 / 9, accuracy: 0.01)
                if size.height >= 800 { XCTAssertGreaterThan(currentCanvas.height, 300, "The preview must use the available height") }
                let apply = try button("Apply Changes", in: root)
                XCTAssertTrue(root.bounds.contains(apply.convert(apply.bounds, to: root)))
            }
        }
    }
    func testTextWorkspaceUsesAvailableHeightForBothDestinations() throws {
        let domain = "AltViewTests.TextWorkspaceHeight.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "customTextEnabled")
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Test")), forKey: "customTextDraft")
        var remoteStatus = ReceiverStatus()
        let key = try PairingKey.generate()
        let receiver = ReceiverServer(receiverID: UUID()) { remoteStatus = $0 }
        receiver.start(name: "Layout test", key: key, advertise: false)
        defer { receiver.stop() }
        eventually("layout receiver ready") { remoteStatus.port != nil }
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0,
                                                  window: layoutWindow())
        defer { controller.shutdown(); controller.close() }
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let destination = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Text destination"
        })
        for selection in [0, 1, 0] {
            destination.selectItem(at: selection)
            destination.sendAction(destination.action, to: destination.target)
            if let sheet = window.attachedSheet?.contentView {
                try button("Connect using an address instead", in: sheet).performClick(nil)
                try field("Receiver address", in: sheet).stringValue = "127.0.0.1"
                try field("Receiver port", in: sheet).stringValue = String(try XCTUnwrap(remoteStatus.port))
                let code = try field("Pairing code", in: sheet)
                code.stringValue = PairingKey.text(key)
                code.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: code))
                try button("Connect & Publish Text", in: sheet).performClick(nil)
                eventually("remote text is live") { remoteStatus.content.body == "Test" }
            }
            root.layoutSubtreeIfNeeded()
            XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "workspaceContentStatus" })
            for height: CGFloat in [1000, 650, 1000] {
                window.setContentSize(NSSize(width: 1164, height: height))
                let settled = expectation(description: "Window resize and content updates settle")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
                wait(for: [settled], timeout: 1)
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(root.bounds.height, height, accuracy: 1, "The test must exercise the requested window height")
                let status = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "textPublicationDetail" })
                let statusFrame = status.convert(status.bounds, to: root)
                XCTAssertEqual(statusFrame.minY, 20, accuracy: 1, "Publishing status stays at the bottom of the window")
                let publish = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "showText" })
                let publishFrame = publish.convert(publish.bounds, to: root)
                XCTAssertTrue(root.bounds.contains(publishFrame))
                XCTAssertLessThan(publishFrame.minY - statusFrame.maxY, 20, "Publishing actions stay beside their status")
                let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first {
                    $0.accessibilityLabel() == "Compose editor"
                })
                let document = try XCTUnwrap(editor.documentView)
                if height == 1000 {
                    XCTAssertLessThanOrEqual(document.frame.height, editor.contentSize.height + 1,
                                             "All editor fields fit without scrolling when the window is tall")
                    let footer = try field("Text footer", in: root)
                    XCTAssertTrue(editor.documentVisibleRect.contains(footer.convert(footer.bounds, to: document)))
                } else {
                    XCTAssertGreaterThan(document.frame.height, editor.contentSize.height,
                                         "A compact window can scroll the editor while keeping actions visible")
                }
            }
            if selection == 1 {
                let changes = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "textDraftStatus" })
                XCTAssertTrue(changes.isHidden)
                let publication = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
                    $0.accessibilityIdentifier() == "textPublicationStatus"
                })
                XCTAssertTrue(publication.stringValue.contains("127.0.0.1"), "Publication status must name its destination")
                let body = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "Text body" })
                let longText = (1...45).map { "Line \($0): a longer published message." }.joined(separator: "\n")
                body.string = longText
                body.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: body))
                XCTAssertFalse(changes.isHidden)
                XCTAssertEqual(remoteStatus.content.body, "Test", "Editing must not change the receiving Mac")
                try button("Publish Text", in: root).performClick(nil)
                eventually("long text published") { remoteStatus.content.body == longText }
                XCTAssertTrue(changes.isHidden)
                root.layoutSubtreeIfNeeded()
                let sent = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first { $0.accessibilityLabel() == "Last text sent" })
                let sentBody = try XCTUnwrap(descendants(sent).compactMap { $0 as? NSTextField }.first { $0.stringValue == longText })
                XCTAssertEqual(sentBody.maximumNumberOfLines, 0, "Sent text must remain readable in full")
                XCTAssertGreaterThan(try XCTUnwrap(sent.documentView).frame.height, sent.contentSize.height)
                controller.showDesignPage()
                try button("Use lower-third layout", in: root).performClick(nil)
                controller.showComposerPage()
                XCTAssertTrue(changes.isHidden, "Changes to this Mac’s design are not unpublished changes for another Mac")
                XCTAssertTrue(descendants(root).compactMap { $0 as? StatusBadge }.allSatisfy { $0.text != "DRAFT" })
                receiver.stop()
                let publicationBadge = try XCTUnwrap(descendants(root).compactMap { $0 as? StatusBadge }.first {
                    $0.accessibilityIdentifier() == "composerPresentationStatus"
                })
                eventually("disconnection replaces stale ownership with offline status") {
                    publicationBadge.text == "OFFLINE" && publication.stringValue.hasPrefix("Connection lost")
                }
                XCTAssertEqual(sentBody.stringValue, longText, "The last sent text stays available while offline")
            }
        }
    }
    func testLocalPublicationFailureExplainsWhyAndKeepsChangesUnpublished() throws {
        let domain = "AltViewTests.LocalPublicationFailure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Private message")), forKey: "customTextDraft")
        let composer = TextComposerViewController(defaults: defaults) { completion in
            completion(.failure(ComposerConnectionError(message: "This Mac’s receiver could not start.")))
        }
        defer { composer.shutdown() }
        let root = composer.view
        try button("Publish Text & Design", in: root).performClick(nil)
        let detail = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "textPublicationDetail"
        })
        XCTAssertEqual(detail.stringValue, "This Mac’s receiver could not start.")
        let changes = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "textDraftStatus" })
        XCTAssertFalse(changes.isHidden)
        XCTAssertTrue(try button("Publish Text & Design", in: root).isEnabled)
    }
    func testRemotePairingFailureRetryConnectOnlyAndOneStepPublishing() throws {
        let domain = "AltViewTests.RemoteComposer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent.scripture), forKey: "customTextDraft")
        let key = try XCTUnwrap(PairingKey.parse("ABCD2345"))
        var output = ReceiverStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        server.start(name: "Pairing UX test", key: key, advertise: false)
        defer { server.stop() }
        eventually("receiver ready") { output.port != nil }
        let controller = TextComposerViewController(defaults: defaults,
            loadPairing: { _ in nil }, storePairing: { _, _ in }) { _ in XCTFail("Remote pairing must never connect locally") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1062, height: 714), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controller.view
        defer { controller.shutdown(); window.close() }
        let destination = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first)
        destination.selectItem(at: 1); destination.sendAction(destination.action, to: destination.target)
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try button("Connect using an address instead", in: sheet).performClick(nil)
        try field("Receiver address", in: sheet).stringValue = "127.0.0.1"
        try field("Receiver port", in: sheet).stringValue = String(try XCTUnwrap(output.port))
        let code = try field("Pairing code", in: sheet)
        code.stringValue = "ABCD2346"
        // Bonjour updates must not erase a code typed for a manual address.
        controller.updateReceivers([DiscoveredReceiver(name: "Nearby Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1))], error: nil)
        XCTAssertEqual(code.stringValue, "ABCD2346")
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: code))
        try button("Connect & Publish Text", in: sheet).performClick(nil)
        eventually("wrong code remains editable") {
            code.isEnabled && self.descendants(sheet).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("Couldn’t connect.") }
        }
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertEqual(output.content, .empty)
        XCTAssertNil(output.ownerName)
        code.stringValue = PairingKey.text(key).lowercased()
        try button("Connect Only", in: sheet).performClick(nil)
        eventually("connection confirmed before sheet closes") { window.attachedSheet == nil && output.connections == 1 }
        XCTAssertNil(output.ownerName, "Connect Only must keep the draft private")
        XCTAssertEqual(output.content, .empty)
        try button("Change Receiver…", in: controller.view).performClick(nil)
        let secondSheet = try XCTUnwrap(window.attachedSheet?.contentView)
        XCTAssertEqual(try field("Pairing code", in: secondSheet).stringValue, "")
        try button("Connect & Publish Text", in: secondSheet).performClick(nil)
        eventually("remembered pairing publishes after one action") { window.attachedSheet == nil && output.content == .scripture }
        try button("Stop Presenting", in: controller.view).performClick(nil)
        eventually("stopped") { output.ownerName == nil }
    }
    func testStalledFirstConnectionRetriesAndPublishesWithoutAnotherClick() throws {
        let domain = "AltViewTests.PairingRetry.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent.scripture), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let receiver = try PairingRetryTestReceiver(key: key)
        defer { receiver.stop() }
        let listening = expectation(description: "retry receiver ready")
        receiver.start { listening.fulfill() }
        wait(for: [listening], timeout: 3)
        var published: DisplayContent?
        receiver.onContent = { published = $0 }
        let controller = TextComposerViewController(defaults: defaults,
            loadPairing: { _ in nil }, storePairing: { _, _ in }) { _ in XCTFail("Must connect remotely") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1062, height: 714), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controller.view
        defer { controller.shutdown(); window.close() }
        let destination = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first)
        destination.selectItem(at: 1); destination.sendAction(destination.action, to: destination.target)
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try button("Connect using an address instead", in: sheet).performClick(nil)
        try field("Receiver address", in: sheet).stringValue = "127.0.0.1"
        try field("Receiver port", in: sheet).stringValue = String(try XCTUnwrap(receiver.port).rawValue)
        let code = try field("Pairing code", in: sheet)
        code.stringValue = PairingKey.text(key)
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: code))
        try button("Connect & Publish Text", in: sheet).performClick(nil)
        eventually("retry stays in the connection sheet", timeout: 13) {
            self.descendants(sheet).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Retrying the network") }
        }
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertFalse(code.isEnabled)
        XCTAssertNil(published)
        XCTAssertFalse(descendants(sheet).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("Couldn’t connect.") })
        eventually("original click pairs and publishes", timeout: 5) { window.attachedSheet == nil && published == .scripture }
        XCTAssertEqual(receiver.acceptedConnections, 2)
    }
    func testCancellingPairingLookupCannotConnectOrPublishLater() throws {
        let domain = "AltViewTests.CancelPairing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent.scripture), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let gate = DispatchSemaphore(value: 0)
        let lookup = expectation(description: "pairing lookup started")
        let finished = expectation(description: "cancelled lookup returned")
        let controller = TextComposerViewController(defaults: defaults,
            loadPairing: { _ in lookup.fulfill(); _ = gate.wait(timeout: .now() + 5); finished.fulfill(); return key },
            storePairing: { _, _ in XCTFail("Cancelled pairing must not be saved") }) { _ in XCTFail("Must not connect locally") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1062, height: 714), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controller.view
        defer { gate.signal(); controller.shutdown(); window.close() }
        let destination = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first)
        destination.selectItem(at: 1); destination.sendAction(destination.action, to: destination.target)
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try button("Connect using an address instead", in: sheet).performClick(nil)
        let host = try field("Receiver address", in: sheet); host.stringValue = "127.0.0.1"
        XCTAssertEqual(try field("Receiver port", in: sheet).stringValue, "", "Manual connections must not assume the old fixed port")
        try field("Receiver port", in: sheet).stringValue = "1"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: host))
        try button("Connect & Publish Text", in: sheet).performClick(nil)
        wait(for: [lookup], timeout: 3)
        try button("Cancel", in: sheet).performClick(nil)
        gate.signal(); wait(for: [finished], timeout: 3)
        let settled = expectation(description: "late lookup discarded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(try button("Connect & Publish Text…", in: controller.view).isEnabled)
        XCTAssertFalse(try button("Stop Presenting", in: controller.view).isEnabled)
    }
    func testLowerThirdEditorInitializesWithinLaptopScreen() throws {
        let controller = LowerThirdWindowController()
        controller.update(template: LowerThirdTemplate(), style: OutputStyle(), artwork: nil, busy: false, message: "")
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.title, "AltView — Lower Third")
        XCTAssertLessThanOrEqual(window.frame.width, 1440)
        XCTAssertLessThanOrEqual(window.frame.height, 840)
        XCTAssertFalse(window.contentView?.hasAmbiguousLayout ?? true)
        controller.shutdown()
    }
    func testLowerThirdDraftStaysPrivateAcrossReceiverRefreshAndReverts() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var applied = LowerThirdTemplate(); applied.enabled = true
        controller.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        var published: [LowerThirdTemplate] = []
        controller.onApply = { template, _ in published.append(template) }
        try button("Fit to Canvas", in: root).performClick(nil)
        XCTAssertEqual(controller.template.artworkRegion.width, 100)
        XCTAssertTrue(published.isEmpty, "Editing must never alter receiver output")
        controller.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "")
        XCTAssertEqual(controller.template.artworkRegion.width, 100, "A live status refresh must preserve the draft")
        var editTextRequests = 0
        controller.onEditText = { editTextRequests += 1 }
        try button("Edit Text…", in: root).performClick(nil)
        XCTAssertEqual(editTextRequests, 1)
        XCTAssertTrue(controller.hasChanges, "Opening Compose must preserve the private design draft")
        XCTAssertEqual(controller.template.artworkRegion.width, 100)
        XCTAssertTrue(published.isEmpty, "Opening Compose must not apply a design")
        try button("Show layout guides", in: root).performClick(nil)
        try button("Preview Animation", in: root).performClick(nil)
        XCTAssertTrue(published.isEmpty, "Preview controls are private")
        try button("Apply Changes", in: root).performClick(nil)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.artworkRegion.width, 100)
        XCTAssertFalse(controller.hasChanges)
        try button("Reset This Template’s Positions", in: root).performClick(nil)
        XCTAssertEqual(controller.template.artworkRegion.width, 90)
        try button("Revert All Changes", in: root).performClick(nil)
        XCTAssertEqual(controller.template.artworkRegion.width, 100, "Revert restores the last applied design")
        XCTAssertEqual(published.count, 1)
    }
    func testDesignKeepsSenderTextAcrossProfilesAndRefreshesIncomingChanges() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        controller.update(library: TemplateDesignLibrary(), artworks: [:], busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Design preview content" })
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let source = DisplayContent(title: "Live reference", body: "Sender's actual text", footer: "Translation", template: .scripture)
        controller.updateContent(draft: .empty, source: source, externalSource: "ViewTheWord", customTextEnabled: false)
        for profile in DesignProfileID.allCases {
            controller.selectProfile(profile)
            XCTAssertEqual(picker.titleOfSelectedItem, "Current source")
            XCTAssertEqual(canvas.content.body, source.body)
        }
        var next = source; next.body = "Next verse"
        controller.updateContent(draft: .empty, source: next, externalSource: "ViewTheWord", customTextEnabled: false)
        XCTAssertEqual(canvas.content.body, "Next verse")
        picker.selectItem(withTitle: "Sample · Announcement")
        picker.sendAction(picker.action, to: picker.target)
        controller.selectProfile(.scripture)
        XCTAssertEqual(picker.titleOfSelectedItem, "Sample · Scripture", "Explicit sample previews remain available")
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "Scripture sample preview · not live"
        })
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "Previewing sample text. Choose Current source to preview text from ViewTheWord."
        })
        controller.updateContent(draft: DisplayContent(body: "Private draft"), source: .empty, externalSource: nil)
        picker.selectItem(withTitle: "Text draft"); picker.sendAction(picker.action, to: picker.target)
        controller.selectProfile(.custom)
        XCTAssertEqual(picker.titleOfSelectedItem, "Text draft")
        XCTAssertEqual(canvas.content.body, "Private draft")
        XCTAssertFalse(controller.hasChanges)
    }

    func testDesignSelectorControlsSettingsAndPreviewWithoutChangingAudienceAssignment() throws {
        let editor = LowerThirdWindowController()
        defer { editor.shutdown() }
        var library = TemplateDesignLibrary()
        library.selection = .scripture
        library.lyrics.style.fontName = "Georgia"
        library.scripture.style.fontName = "Helvetica"
        editor.update(library: library, artworks: [:], busy: false, message: "")
        XCTAssertEqual(editor.editingProfile, .scripture, "Open the saved audience design initially")
        let source = DisplayContent(title: "Reference", body: "Actual sender text", footer: "Translation", template: .scripture)
        editor.updateContent(draft: .empty, source: source, externalSource: "ViewTheWord", customTextEnabled: false)
        let root = editor.contentView
        let selector = try editingTemplate(in: root)
        XCTAssertEqual(selector.accessibilityLabel(), "Design")
        XCTAssertFalse(descendants(root).compactMap { $0 as? NSPopUpButton }.contains {
            $0.accessibilityLabel() == "Template" && !$0.isHiddenOrHasHiddenAncestor
        }, "Audience assignment has no visible control in the design editor")
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        var publications = 0
        editor.onApplyLibrary = { _, _ in publications += 1 }
        for profile in DesignProfileID.allCases {
            selectTemplate(profile, in: selector)
            XCTAssertEqual(editor.editingProfile, profile)
            XCTAssertEqual(preview.presentation.template.textTemplate, profile.selection)
            XCTAssertEqual(preview.style.fontName, library.design(profile).style.fontName)
            XCTAssertEqual(preview.content.body, source.body)
            XCTAssertEqual(publications, 0)
        }
        // Editing another design is navigation, independent of the audience choice.
        editor.selectProfile(.lyrics)
        XCTAssertEqual(editor.draftLibrary?.selection, .scripture)
        XCTAssertEqual(preview.presentation.template.textTemplate, .lyrics)
        XCTAssertEqual(publications, 0)
    }

    func testDesignNumericEditsRefreshPreviewWhileTypingAndRemainPrivate() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let width = try field("Body Width percent", in: root)
        var publications = 0
        controller.onApply = { _, _ in publications += 1 }
        width.stringValue = "65"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: width))
        XCTAssertEqual(canvas.presentation.template.bodyRegion.width, 65)
        XCTAssertTrue(controller.hasChanges)
        XCTAssertEqual(publications, 0)
        width.stringValue = "oops"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: width))
        XCTAssertEqual(canvas.presentation.template.bodyRegion.width, 65, "Invalid input keeps the last valid preview")
        XCTAssertFalse(try button("Apply Changes", in: root).isEnabled)
        width.stringValue = "72"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: width))
        XCTAssertEqual(canvas.presentation.template.bodyRegion.width, 72)
        controller.revertChanges()
        XCTAssertEqual(canvas.presentation.template.bodyRegion.width, baseline.bodyRegion.width)
        XCTAssertEqual(publications, 0)
    }

    func testLowerThirdInvalidInputBlocksApplyAndExplainsClamping() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let height = try field("Body Height percent", in: root)
        var published = 0
        controller.onApply = { _, _ in published += 1 }
        for text in ["oops", "nan", "inf", ""] {
            height.stringValue = text
            controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: height))
            XCTAssertFalse(try button("Apply Changes", in: root).isEnabled)
            controller.applyChanges()
            XCTAssertEqual(published, 0)
            XCTAssertEqual(height.stringValue, text, "Keep invalid input visible so it can be corrected")
        }
        height.stringValue = "999"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: height))
        XCTAssertEqual(controller.template.bodyRegion.height, 21)
        XCTAssertEqual(height.stringValue, "21")
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("Position or size adjusted") })
        controller.applyChanges()
        XCTAssertEqual(published, 1)
        let duration = try field("Animation duration in seconds", in: root)
        duration.stringValue = "-1"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: duration))
        XCTAssertEqual(controller.template.duration, 0.1)
        controller.revertChanges()
        XCTAssertEqual(duration.stringValue, "0.45")
    }
    func testLowerThirdNoneAnimationRecoversAnInvalidDuration() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let duration = try field("Animation duration in seconds", in: root)
        duration.stringValue = "bad"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: duration))
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Lower third animation" })
        picker.selectItem(withTitle: "None"); picker.sendAction(picker.action, to: picker.target)
        XCTAssertFalse(duration.isEnabled)
        XCTAssertEqual(duration.stringValue, "0.45")
        XCTAssertTrue(try button("Apply Changes", in: root).isEnabled)
        controller.applyChanges()
        XCTAssertFalse(controller.hasChanges)
        XCTAssertEqual(controller.template.animation, .none)
    }
    func testLowerThirdExternalEnableMergesWithoutLosingLayoutDraft() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        let root = try XCTUnwrap(controller.window?.contentView)
        try button("Use lower-third layout", in: root).performClick(nil)
        try button("Fit to Canvas", in: root).performClick(nil)
        try button("Use lower-third layout", in: root).performClick(nil)
        var incoming = LowerThirdTemplate(); incoming.enabled = true
        controller.update(template: incoming, style: OutputStyle(), artwork: nil, busy: false, message: "")
        XCTAssertTrue(controller.template.enabled)
        XCTAssertEqual(controller.template.artworkRegion.width, 100)
        controller.revertChanges()
        XCTAssertTrue(controller.template.enabled)
        XCTAssertEqual(controller.template.artworkRegion.width, 90)
    }
    func testLowerThirdMissingPNGCanRecoverToBuiltInWithoutImport() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var applied = LowerThirdTemplate()
        applied.enabled = true; applied.artwork = .custom; applied.assetID = UUID(); applied.assetName = "missing.png"
        controller.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "Saved PNG unavailable")
        let root = try XCTUnwrap(controller.window?.contentView)
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Lower third artwork" })
        XCTAssertFalse(try button("Apply Changes", in: root).isEnabled)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("PNG unavailable.") })
        picker.selectItem(withTitle: "Built-in banner"); picker.sendAction(picker.action, to: picker.target)
        XCTAssertTrue(try button("Apply Changes", in: root).isEnabled)
        var published: LowerThirdTemplate?
        controller.onApply = { value, _ in published = value }
        controller.applyChanges()
        XCTAssertEqual(published?.artwork, .builtIn)
    }
    func testLowerThirdEditorKeepsActionsVisibleAtMinimumWindowSize() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 600))
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let apply = try button("Apply Changes", in: root)
        let frame = apply.convert(apply.bounds, to: root)
        XCTAssertTrue(root.bounds.contains(frame), "Apply must remain visible while settings scroll")
        XCTAssertFalse(root.hasAmbiguousLayout)
        let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentSize.height)
    }
    func testLowerThirdOptionalTextUsesDraftApplyRevertAndKeepsPositions() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let titleSwitch = try button("Title", in: root)
        let footerSwitch = try button("Footer", in: root)
        let titleHeight = try field("Title Height percent", in: root)
        let footerY = try field("Footer Y percent", in: root)
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let bodyY = try field("Body Y percent", in: root)
        let bodyHeight = try field("Body Height percent", in: root)
        let grid = try XCTUnwrap(descendants(root).compactMap { $0 as? NSGridView }.first)
        XCTAssertTrue(grid.cell(atColumnIndex: 0, rowIndex: 2).contentView === titleSwitch)
        XCTAssertTrue(grid.cell(atColumnIndex: 0, rowIndex: 4).contentView === footerSwitch)
        var applied: LowerThirdTemplate?
        controller.onApply = { value, _ in applied = value }
        XCTAssertEqual(titleSwitch.state, .on); XCTAssertEqual(footerSwitch.state, .on)
        titleHeight.stringValue = "bad"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: titleHeight))
        titleSwitch.performClick(nil); footerSwitch.performClick(nil)
        XCTAssertFalse(titleHeight.isEnabled); XCTAssertFalse(footerY.isEnabled)
        XCTAssertEqual(titleHeight.stringValue, "4", "Hiding clears invalid input but preserves the saved position")
        XCTAssertEqual(preview.accessibilityLabel(), "Jordan Lee")
        XCTAssertEqual(bodyY.stringValue, "74"); XCTAssertEqual(bodyHeight.stringValue, "20")
        XCTAssertFalse(bodyY.isEnabled); XCTAssertFalse(bodyHeight.isEnabled)
        XCTAssertTrue(try field("Body Width percent", in: root).isEnabled)
        XCTAssertNil(applied, "Visibility changes stay private until Apply")
        XCTAssertTrue(try button("Apply Changes", in: root).isEnabled)
        controller.applyChanges()
        XCTAssertEqual(applied?.showsTitle, false); XCTAssertEqual(applied?.showsFooter, false)
        XCTAssertEqual(applied?.bodyRegion, LowerThirdTemplate().bodyRegion)
        XCTAssertEqual(applied?.titleRegion, LowerThirdTemplate().titleRegion)
        titleSwitch.performClick(nil); footerSwitch.performClick(nil)
        XCTAssertTrue(titleHeight.isEnabled); XCTAssertTrue(footerY.isEnabled)
        XCTAssertTrue(bodyY.isEnabled); XCTAssertTrue(bodyHeight.isEnabled)
        XCTAssertEqual(bodyY.stringValue, "79"); XCTAssertEqual(bodyHeight.stringValue, "11")
        XCTAssertTrue(preview.accessibilityLabel()?.contains("GUEST SPEAKER") ?? false)
        controller.revertChanges()
        XCTAssertEqual(titleSwitch.state, .off); XCTAssertEqual(footerSwitch.state, .off)
        XCTAssertEqual(bodyY.stringValue, "74"); XCTAssertEqual(bodyHeight.stringValue, "20")
        XCTAssertEqual(preview.accessibilityLabel(), "Jordan Lee")
    }
    func testFullCanvasTextVisibilityPreviewsPublishesAndSurvivesLayoutChanges() throws {
        let domain = "AltViewTests.FullCanvasVisibility.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let content = DisplayContent(title: "Heading", body: "Main message", footer: "Credit")
        defaults.set(true, forKey: "customTextEnabled")
        try defaults.set(JSONEncoder().encode(content), forKey: "customTextDraft")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        eventually("receiver ready") { controller.receiverStatus.listening }
        controller.showDesignPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        let mode = try button("Use lower-third layout", in: root)
        let title = try button("Title", in: root)
        let footer = try button("Footer", in: root)
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(mode.state, .off)
        XCTAssertFalse(preview.presentation.template.enabled)
        title.performClick(nil)
        XCTAssertEqual(preview.accessibilityLabel(), "Main message\nCredit")
        footer.performClick(nil)
        XCTAssertEqual(preview.accessibilityLabel(), "Main message")
        XCTAssertEqual(preview.content, content, "Hiding a row must preserve its text")
        XCTAssertEqual(controller.receiverStatus.content, .empty, "Visibility edits remain private")
        controller.showComposerPage()
        let textPreview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(textPreview.accessibilityLabel(), "Main message")
        XCTAssertEqual(descendants(root).compactMap { $0 as? NSTextField }.filter { $0.stringValue == "Hidden by Design · text is kept" }.count, 2)
        try button("Publish Text & Design", in: root).performClick(nil)
        eventually("text and visibility published") { controller.receiverStatus.content == content }
        let saved = try JSONDecoder().decode(LowerThirdTemplate.self, from: XCTUnwrap(defaults.data(forKey: "lowerThirdTemplate")))
        XCTAssertFalse(saved.enabled); XCTAssertFalse(saved.showsTitle); XCTAssertFalse(saved.showsFooter)
        controller.showReceiverPage()
        let live = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(live.accessibilityLabel(), "Main message")
        XCTAssertEqual(live.content, content)
        controller.showDesignPage()
        mode.performClick(nil)
        XCTAssertTrue(preview.presentation.template.enabled)
        XCTAssertEqual(preview.accessibilityLabel(), "Main message")
        title.performClick(nil); footer.performClick(nil)
        XCTAssertEqual(preview.accessibilityLabel(), "Heading\nMain message\nCredit")
        mode.performClick(nil)
        XCTAssertFalse(preview.presentation.template.enabled)
        XCTAssertEqual(preview.accessibilityLabel(), "Heading\nMain message\nCredit")
        try button("Revert All Changes", in: root).performClick(nil)
        XCTAssertEqual(title.state, .off); XCTAssertEqual(footer.state, .off)
        XCTAssertEqual(preview.accessibilityLabel(), "Main message")
    }
    func testFullCanvasCanApplyAfterHidingInvalidLowerThirdFields() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        for label in ["Body Height percent", "Animation duration in seconds"] {
            let input = try field(label, in: root)
            input.stringValue = "bad"
            controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: input))
        }
        XCTAssertFalse(controller.canPublish)
        try button("Use lower-third layout", in: root).performClick(nil)
        XCTAssertTrue(controller.canPublish, "Hidden lower-third fields must not block full-canvas output")
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertFalse(preview.presentation.template.enabled, "Sample previews must use the selected layout too")
        controller.applyChanges()
        XCTAssertFalse(controller.template.enabled)
        XCTAssertEqual(controller.template.bodyRegion, baseline.bodyRegion)
        XCTAssertEqual(controller.template.duration, baseline.duration)
        try button("Use lower-third layout", in: root).performClick(nil)
        XCTAssertTrue(try field("Body Height percent", in: root).isEnabled)
        XCTAssertEqual(try field("Animation duration in seconds", in: root).stringValue, "0.45")
    }
    func testArtworkToggleKeepsDraftPrivateAndPreservesSavedPlacement() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        baseline.artworkRegion = TemplateRegion(x: 4, y: 68, width: 92, height: 28)
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let toggle = try button("Artwork", in: root)
        let width = try field("Artwork Width percent", in: root)
        let grid = try XCTUnwrap(descendants(root).compactMap { $0 as? NSGridView }.first)
        XCTAssertTrue(grid.cell(atColumnIndex: 0, rowIndex: 1).contentView === toggle)
        XCTAssertEqual(toggle.state, .on)
        var published: LowerThirdTemplate?
        controller.onApply = { value, _ in published = value }
        width.stringValue = "bad"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: width))
        toggle.performClick(nil)
        XCTAssertFalse(width.isEnabled)
        XCTAssertEqual(width.stringValue, "92")
        XCTAssertFalse(try button("Fit to Canvas", in: root).isEnabled)
        XCTAssertTrue(controller.canPublish, "Hidden artwork's disabled fields must not block publication")
        XCTAssertNil(published)
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        XCTAssertFalse(controller.template.showsArtwork, "A receiver refresh must preserve the draft")
        controller.applyChanges()
        XCTAssertEqual(published?.showsArtwork, false)
        XCTAssertEqual(published?.artworkRegion, baseline.artworkRegion)
        XCTAssertEqual(published?.bodyRegion, baseline.bodyRegion)
        toggle.performClick(nil)
        XCTAssertTrue(width.isEnabled)
        XCTAssertTrue(try button("Fit to Canvas", in: root).isEnabled)
        XCTAssertEqual(controller.template.artworkRegion, baseline.artworkRegion)
        controller.revertChanges()
        XCTAssertEqual(toggle.state, .off)
        XCTAssertFalse(controller.hasChanges)
    }
    func testHiddenMissingArtworkCanPublishTextAndPersistTheChoice() throws {
        let domain = "AltViewTests.HiddenArtwork.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let content = DisplayContent(title: "Title", body: "Text without artwork", footer: "Footer")
        defaults.set(true, forKey: "customTextEnabled")
        try defaults.set(JSONEncoder().encode(content), forKey: "customTextDraft")
        var template = LowerThirdTemplate(); template.enabled = true; template.artwork = .custom
        template.assetID = UUID(); template.assetName = "missing.png"
        try defaults.set(JSONEncoder().encode(template), forKey: "lowerThirdTemplate")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        eventually("receiver ready") { controller.receiverStatus.listening }
        controller.showDesignPage()
        eventually("missing PNG reported") {
            self.descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("PNG unavailable.") }
        }
        try button("Artwork", in: root).performClick(nil)
        let draft = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertTrue(draft.content.visible)
        XCTAssertEqual(draft.accessibilityLabel(), "Title\nText without artwork\nFooter")
        XCTAssertTrue(try button("Apply Changes", in: root).isEnabled)
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let publish = try button("Publish Text & Design", in: root)
        XCTAssertTrue(publish.isEnabled)
        publish.performClick(nil)
        eventually("text published without the missing PNG") { controller.receiverStatus.content == content }
        let saved = try JSONDecoder().decode(LowerThirdTemplate.self, from: XCTUnwrap(defaults.data(forKey: "lowerThirdTemplate")))
        XCTAssertFalse(saved.showsArtwork)
        XCTAssertEqual(saved.assetID, template.assetID)
        XCTAssertEqual(saved.artwork, .custom)
        controller.showReceiverPage()
        let live = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(live.content, content, "A hidden missing PNG must not blank live output")
        XCTAssertFalse(live.presentation.template.showsArtwork)
        controller.showDesignPage()
        try button("Artwork", in: root).performClick(nil)
        XCTAssertFalse(try button("Apply Changes", in: root).isEnabled, "Showing the missing PNG must require recovery again")
    }
    func testAutomaticBodyPlacementClearsErrorsInCalculatedFields() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let bodyY = try field("Body Y percent", in: root)
        bodyY.stringValue = "bad"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: bodyY))
        XCTAssertFalse(try button("Apply Changes", in: root).isEnabled)
        try button("Title", in: root).performClick(nil)
        XCTAssertFalse(bodyY.isEnabled)
        XCTAssertEqual(bodyY.stringValue, "74")
        XCTAssertTrue(try button("Apply Changes", in: root).isEnabled)
        controller.applyChanges()
        XCTAssertFalse(controller.hasChanges)
        XCTAssertEqual(controller.template.bodyRegion.y, 79)
    }
    func testComposerEmbedsWithoutConnectingOrOpeningAnotherWindow() throws {
        let domain = "AltViewTests.Composer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var connections = 0
        let controller = TextComposerViewController(defaults: defaults) { _ in connections += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1062, height: 714), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.contentView?.hasAmbiguousLayout ?? true)
        XCTAssertEqual(connections, 0, "Opening the composer must not connect or take output")
        controller.shutdown()
        window.close()
    }
    func testCoalescedComposerTakeoverReleasesLocalDesignPublicationLock() throws {
        let domain = "AltViewTests.CoalescedComposer.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent.scripture), forKey: "customTextDraft")
        let controller = TextComposerViewController(defaults: defaults) { _ in XCTFail("Already connected") }
        defer { controller.shutdown() }
        let root = controller.view
        var locked = false, cancellations = 0
        controller.prepareLocalPublish = { _ in locked = true; return true }
        controller.cancelLocalPublish = { locked = false; cancellations += 1 }
        controller.receive(SenderStatus(connected: true))
        try button("Publish Text & Design", in: root).performClick(nil)
        XCTAssertTrue(locked); XCTAssertTrue(controller.isPresenting)
        controller.receive(SenderStatus(connected: true, lastGrantedLease: UUID(), ownerName: "Another presenter"))
        XCTAssertFalse(locked); XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(controller.isPresenting)
        XCTAssertTrue(try button("Publish Text & Design", in: root).isEnabled)
    }
    func testWorkspaceDraftPreviewAndAtomicLocalPublication() throws {
        let domain = "AltViewTests.Workspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let original = DisplayContent(title: "Draft title", body: "Private rehearsal", footer: "Draft footer")
        try defaults.set(JSONEncoder().encode(original), forKey: "customTextDraft")
        var base = LowerThirdTemplate(); base.enabled = true
        try defaults.set(JSONEncoder().encode(base), forKey: "lowerThirdTemplate")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        eventually("receiver ready") { controller.receiverStatus.listening }
        controller.showDesignPage()
        root.layoutSubtreeIfNeeded()
        let designScroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(designScroll.frame.height, 200, "Embedded Design must keep its settings and preview visible")
        let background = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Draft keying background" })
        background.selectItem(at: 1); background.sendAction(background.action, to: background.target)
        try button("Title", in: root).performClick(nil)
        XCTAssertNil(defaults.data(forKey: "outputStyle"), "Appearance stays private before publishing")
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(preview.style.background, "00FF00")
        XCTAssertEqual(preview.accessibilityLabel(), "Private rehearsal\nDraft footer")
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Hidden by Design · text is kept" })
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        try button("Publish Text & Design", in: root).performClick(nil)
        // A later edit must not enter the snapshot requested by the click.
        let title = try field("Text title", in: root)
        title.stringValue = "Next draft"
        title.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: title))
        eventually("text and design accepted") {
            controller.receiverStatus.content == original && defaults.data(forKey: "outputStyle") != nil
        }
        let saved = try JSONDecoder().decode(OutputStyle.self, from: XCTUnwrap(defaults.data(forKey: "outputStyle")))
        XCTAssertEqual(saved.background, "00FF00")
        let savedLayout = try JSONDecoder().decode(LowerThirdTemplate.self, from: XCTUnwrap(defaults.data(forKey: "lowerThirdTemplate")))
        XCTAssertFalse(savedLayout.showsTitle)
        XCTAssertEqual(title.stringValue, "Next draft")
        controller.showReceiverPage()
        let live = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(live.style.background, "00FF00")
        XCTAssertEqual(live.content, original)
        XCTAssertEqual(live.accessibilityLabel(), "Private rehearsal\nDraft footer")
        controller.showDesignPage()
        let font = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Draft font" })
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let republish = try button("Publish Text & Design", in: root)
        republish.sendAction(republish.action, to: republish.target)
        let hide = try button("Hide Text", in: root)
        hide.sendAction(hide.action, to: hide.target)
        eventually("hidden during pending publication") { !controller.receiverStatus.content.visible }
        let stillApplied = try JSONDecoder().decode(OutputStyle.self, from: XCTUnwrap(defaults.data(forKey: "outputStyle")))
        XCTAssertEqual(stillApplied.fontName, "System")
        controller.showDesignPage()
        XCTAssertTrue(try button("Apply Changes", in: root).isEnabled, "Hide must release the publishing lock and retain the draft design")
    }

    func testExternalSourcePreviewAndDesignApplyPreserveOwnership() throws {
        let domain = "AltViewTests.ExternalWorkspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let draft = DisplayContent(body: "Local private draft")
        try defaults.set(JSONEncoder().encode(draft), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        eventually("receiver ready") { controller.receiverStatus.port != nil }
        var status = SenderStatus()
        let sender = SenderClient(name: "Presentation App") { status = $0 }
        defer { sender.disconnect() }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: controller.receiverStatus.port!)!), key: key)
        eventually("sender connected") { status.connected }
        let text = DisplayContent(title: "External title", body: "External body", footer: "External footer")
        sender.submit(text); sender.takeOutput()
        eventually("external live") { controller.receiverStatus.content == text }
        controller.showDesignPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Design preview content" })
        XCTAssertEqual(picker.titleOfSelectedItem, "Current source")
        XCTAssertNil(picker.item(withTitle: "Text draft"))
        XCTAssertTrue(try button("Open Text Draft…", in: root).isHidden)
        let designPreview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(designPreview.content, text)
        try button("Use lower-third layout", in: root).performClick(nil)
        try button("Footer", in: root).performClick(nil)
        XCTAssertEqual(controller.receiverStatus.content, text)
        try button("Apply Changes", in: root).performClick(nil)
        XCTAssertEqual(controller.receiverStatus.ownerID, sender.senderID)
        XCTAssertEqual(controller.receiverStatus.content, text)
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        XCTAssertEqual(controller.receiverStatus.connections, 1, "Enabling Custom Text must not connect another sender")
        controller.showDesignPage()
        XCTAssertEqual(picker.titleOfSelectedItem, "Current source")
        XCTAssertFalse(try button("Open Text Draft…", in: root).isHidden)
        try button("Open Text Draft…", in: root).performClick(nil)
        let localPreview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(localPreview.content, draft)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Publishing your message will replace this source’s text") })
        XCTAssertEqual(controller.receiverStatus.ownerID, sender.senderID)
        XCTAssertEqual(controller.receiverStatus.content, text)
        controller.setCustomTextEnabled(false)
        XCTAssertTrue(controller.receiverStatus.listening)
        XCTAssertEqual(controller.receiverStatus.ownerID, sender.senderID)
        XCTAssertEqual(controller.receiverStatus.content, text)
    }

    func testCancelLocalPublishKeepsStagedDesignAndSavedTextPrivate() throws {
        let domain = "AltViewTests.CancelWorkspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Cancel this publication")), forKey: "customTextDraft")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.showDesignPage()
        let font = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Draft font" })
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let publish = try button("Publish Text & Design", in: root)
        publish.sendAction(publish.action, to: publish.target)
        let stop = try button("Stop Presenting", in: root)
        stop.sendAction(stop.action, to: stop.target)
        eventually("receiver ready after cancellation") { controller.receiverStatus.listening }
        XCTAssertNil(controller.receiverStatus.ownerID)
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        XCTAssertNil(defaults.data(forKey: "outputStyle"))
        controller.showDesignPage()
        XCTAssertTrue(try button("Apply Changes", in: root).isEnabled)
        XCTAssertEqual(font.titleOfSelectedItem, "Georgia")
        try button("Revert All Changes", in: root).performClick(nil)
        XCTAssertEqual(font.titleOfSelectedItem, "System")
    }

    func testApplyChecksOutputArtworkAndExplainsWhichProfileNeedsRepair() throws {
        let editor = LowerThirdWindowController()
        defer { editor.shutdown() }
        var library = TemplateDesignLibrary()
        library.lyrics.template.enabled = true; library.lyrics.template.artwork = .custom
        library.lyrics.template.assetID = UUID(); library.lyrics.template.assetName = "missing-lyrics.png"
        editor.update(library: library, artworks: [:], busy: false, message: "")
        let root = editor.contentView
        var saved: TemplateDesignLibrary?
        editor.onApplyLibrary = { value, _ in saved = value }

        // A fixed policy must be checked even with no active source.
        library.selection = .lyrics
        editor.update(library: library, artworks: [:], busy: false, message: "")
        editor.selectProfile(.custom)
        try button("Fit to Canvas", in: root).performClick(nil)
        XCTAssertFalse(try button("Apply Changes", in: root).isEnabled)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains("Lyrics PNG unavailable") && $0.stringValue.contains("Design")
        })
        editor.applyChanges()
        XCTAssertNil(saved)
        XCTAssertTrue(editor.hasChanges, "A failed Apply must preserve the draft and baseline")
        editor.revertChanges()
        XCTAssertEqual(editor.draftLibrary?.selection, .lyrics)
        library.selection = .sender
        editor.update(library: library, artworks: [:], busy: false, message: "")

        // Following the sender must validate the actual source, not the editor sample.
        editor.updateContent(draft: DisplayContent(body: "Local draft"),
                             source: DisplayContent(body: "Song", template: .lyrics), externalSource: "Lyric sender")
        try button("Title", in: root).performClick(nil)
        XCTAssertFalse(try button("Apply Changes", in: root).isEnabled)
        editor.applyChanges()
        XCTAssertNil(saved)
        editor.selectProfile(.lyrics)
        try button("Artwork", in: root).performClick(nil)
        XCTAssertTrue(try button("Apply Changes", in: root).isEnabled)
        editor.applyChanges()
        XCTAssertFalse(try XCTUnwrap(saved).lyrics.template.showsArtwork)
        XCTAssertFalse(editor.hasChanges)
    }

    func testCustomFontAndSizeEditsPreserveAlignmentInBothLayouts() throws {
        let editor = LowerThirdWindowController()
        defer { editor.shutdown() }
        var template = LowerThirdTemplate(); template.enabled = true
        editor.update(library: TemplateDesignLibrary(template: template), artworks: [:], busy: false, message: "")
        let root = editor.contentView
        func picker(_ label: String) throws -> NSPopUpButton {
            try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == label })
        }
        let lowerAlignment = try picker("Lower third text alignment")
        lowerAlignment.selectItem(withTitle: "Right"); lowerAlignment.sendAction(lowerAlignment.action, to: lowerAlignment.target)
        let font = try picker("Draft font")
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        let size = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Draft font size" })
        size.doubleValue = 110; size.sendAction(size.action, to: size.target)
        XCTAssertEqual(editor.style.fontName, "Georgia")
        XCTAssertEqual(editor.style.fontSize, 110)
        XCTAssertEqual(editor.template.alignment, .right)
        XCTAssertEqual(lowerAlignment.titleOfSelectedItem, "Right")
        XCTAssertEqual(editor.style.alignment, .center, "Typography edits must retain the full-canvas alignment too")

        try button("Use lower-third layout", in: root).performClick(nil)
        let fullAlignment = try picker("Draft text alignment")
        fullAlignment.selectItem(withTitle: "Left"); fullAlignment.sendAction(fullAlignment.action, to: fullAlignment.target)
        font.selectItem(withTitle: "Helvetica"); font.sendAction(font.action, to: font.target)
        size.doubleValue = 96; size.sendAction(size.action, to: size.target)
        XCTAssertEqual(editor.style.alignment, .left)
        XCTAssertEqual(fullAlignment.titleOfSelectedItem, "Left")
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(preview.style.forDisplay(content: preview.content, template: preview.presentation.template).alignment, .left)
    }

    func testLocalPublicationCommitsHealthyDesignWhileEditingMissingArtwork() throws {
        let domain = "AltViewTests.HealthyProfilePublication.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "customTextEnabled")
        var library = TemplateDesignLibrary()
        library.lyrics.template.enabled = true; library.lyrics.template.artwork = .custom
        library.lyrics.template.assetID = UUID(); library.lyrics.template.assetName = "missing-lyrics.png"
        try defaults.set(JSONEncoder().encode(library), forKey: "templateDesignLibrary")
        let content = DisplayContent(body: "Healthy Custom publication")
        try defaults.set(JSONEncoder().encode(content), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        let root = try XCTUnwrap(controller.window?.contentView)
        eventually("receiver ready") { controller.receiverStatus.listening }
        var status = SenderStatus()
        let sender = SenderClient(name: "Missing Lyrics fixture") { status = $0 }
        defer { sender.disconnect() }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(controller.receiverStatus.port))!), key: key)
        eventually("fixture connected") { status.connected }
        sender.submit(DisplayContent(body: "Unavailable old source", template: .lyrics)); sender.takeOutput()
        eventually("old lyric source active") { controller.receiverStatus.ownerName == "Missing Lyrics fixture" }

        controller.showDesignPage()
        let profiles = try editingTemplate(in: root)
        eventually("artwork load finished") { profiles.isEnabled }
        selectTemplate(.lyrics, in: profiles)
        let font = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Draft font" })
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        let editor = try XCTUnwrap(try button("Choose PNG…", in: root).target as? LowerThirdWindowController)
        XCTAssertFalse(try button("Apply Changes", in: root).isEnabled)
        controller.showComposerPage()
        let publish = try button("Publish Text & Design", in: root)
        XCTAssertTrue(publish.isEnabled)
        publish.performClick(nil)
        eventually("healthy text accepted and staged designs saved") {
            guard let data = defaults.data(forKey: "templateDesignLibrary"),
                  let saved = try? JSONDecoder().decode(TemplateDesignLibrary.self, from: data) else { return false }
            return controller.receiverStatus.content == content && saved.lyrics.style.fontName == "Georgia" && !editor.hasChanges
        }
        controller.showReceiverPage()
        let output = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertTrue(output.content.visible)
        XCTAssertEqual(output.content.body, content.body)
        XCTAssertEqual(output.presentation.template.textTemplate, .custom)
    }

    func testIndependentTemplateDraftsApplyAndRevertTogether() throws {
        let editor = LowerThirdWindowController()
        defer { editor.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        let library = TemplateDesignLibrary(template: baseline)
        editor.update(library: library, artworks: [:], busy: false, message: "")
        let root = editor.contentView
        func picker(_ label: String) throws -> NSPopUpButton {
            try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == label })
        }
        let profile = try editingTemplate(in: root)
        let font = try picker("Draft font"), alignment = try picker("Lower third text alignment")
        let lineLayout = try picker("Lyrics line layout")
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let scope = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "designChangeScope"
        })
        selectTemplate(.lyrics, in: profile)
        XCTAssertFalse(editor.hasChanges, "Selecting a profile is private navigation")
        XCTAssertEqual(editor.draftLibrary?.selection, .sender)
        XCTAssertEqual(preview.presentation.template.textTemplate, .lyrics)
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        lineLayout.selectItem(withTitle: "Compact pairs"); lineLayout.sendAction(lineLayout.action, to: lineLayout.target)
        alignment.selectItem(withTitle: "Right"); alignment.sendAction(alignment.action, to: alignment.target)
        try button("Title", in: root).performClick(nil)
        XCTAssertTrue(editor.template.showsTitle, "Built-in templates now allow row customization")
        XCTAssertEqual(scope.stringValue, "Apply and Revert cover: Lyrics")
        var applied: TemplateDesignLibrary?
        editor.onApplyLibrary = { value, _ in applied = value }
        selectTemplate(.scripture, in: profile)
        XCTAssertEqual(scope.stringValue, "Apply and Revert cover: Lyrics", "Navigation must keep hidden drafts in the action summary")
        XCTAssertEqual(font.titleOfSelectedItem, "System")
        XCTAssertEqual(alignment.titleOfSelectedItem, "Left")
        XCTAssertEqual(editor.template.lyricLineLayout, .preserve)
        try button("Fit to Canvas", in: root).performClick(nil)
        XCTAssertEqual(scope.stringValue, "Apply and Revert cover: Scripture · Lyrics")
        editor.update(library: library, artworks: [:], busy: false, message: "")
        selectTemplate(.lyrics, in: profile)
        XCTAssertEqual(font.titleOfSelectedItem, "Georgia")
        XCTAssertEqual(lineLayout.titleOfSelectedItem, "Compact pairs")
        XCTAssertEqual(alignment.titleOfSelectedItem, "Right")
        XCTAssertTrue(editor.template.showsTitle)
        XCTAssertNil(applied)
        editor.applyChanges()
        let saved = try XCTUnwrap(applied)
        XCTAssertEqual(saved.lyrics.style.fontName, "Georgia")
        XCTAssertEqual(saved.lyrics.template.lyricLineLayout, .compact)
        XCTAssertEqual(saved.scripture.template.artworkRegion.width, 100)
        XCTAssertEqual(saved.custom.template.artworkRegion.width, 90)
        XCTAssertEqual(saved.selection, .sender)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertTrue(scope.stringValue.hasPrefix("Apply saves all design changes"))
        font.selectItem(withTitle: "Helvetica"); font.sendAction(font.action, to: font.target)
        selectTemplate(.scripture, in: profile)
        try button("Reset This Template’s Positions", in: root).performClick(nil)
        let background = try picker("Draft keying background")
        background.selectItem(withTitle: "Green · Chroma key"); background.sendAction(background.action, to: background.target)
        XCTAssertEqual(scope.stringValue, "Apply and Revert cover: Scripture · Lyrics · Shared key colour")
        try button("Revert All Changes", in: root).performClick(nil)
        XCTAssertEqual(editor.draftLibrary?.scripture.template.artworkRegion.width, 100)
        XCTAssertEqual(editor.draftLibrary?.background, library.background)
        XCTAssertEqual(editor.draftLibrary?.selection, .sender)
        selectTemplate(.lyrics, in: profile)
        XCTAssertEqual(font.titleOfSelectedItem, "Georgia")
        XCTAssertFalse(editor.hasChanges)
        XCTAssertTrue(scope.stringValue.hasPrefix("Apply saves all design changes"))
    }

    func testTemplateArtworkSurvivesOtherProfileUpdatesRestartAndSenderChanges() throws {
        let domain = "AltViewTests.TemplateArtwork.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let store = PNGArtworkStore(directory: directory.appendingPathComponent("Stored"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let original = directory.appendingPathComponent("original.png")
        try png.write(to: original)
        var migratedAsset: PNGArtwork?
        let imported = expectation(description: "legacy artwork imported")
        store.importPNG(from: original) { result in migratedAsset = try? result.get(); imported.fulfill() }
        wait(for: [imported], timeout: 3)
        let old = try XCTUnwrap(migratedAsset)
        var template = LowerThirdTemplate(); template.enabled = true; template.artwork = .custom
        template.assetID = old.id; template.assetName = old.name
        try defaults.set(JSONEncoder().encode(template), forKey: "lowerThirdTemplate")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, artworkStore: store)
        defer { controller.shutdown(); controller.close() }
        controller.showDesignPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        let profiles = try editingTemplate(in: root)
        eventually("migrated artwork loaded") { profiles.isEnabled }
        selectTemplate(.lyrics, in: profiles)
        let choose = try button("Choose PNG…", in: root)
        // Use the real importer without opening a file chooser in the test.
        let editor = try XCTUnwrap(choose.target as? LowerThirdWindowController)
        editor.importArtwork(from: original)
        eventually("lyric artwork imported") { editor.template.assetID != old.id && editor.canPublish }
        let lyricsID = try XCTUnwrap(editor.template.assetID)
        editor.applyChanges()
        selectTemplate(.scripture, in: profiles)
        XCTAssertEqual(editor.template.assetID, old.id)
        try button("Fit to Canvas", in: root).performClick(nil)
        editor.applyChanges()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Stored/\(old.id.uuidString).png").path),
                      "A shared artwork must not be deleted when Lyrics replaces its copy")
        try FileManager.default.removeItem(at: original)
        controller.shutdown(); controller.close()

        // Network delivery and AppKit layout can outlast the short exit animation.
        // Control its clock and Reduce Motion setting while checking the exiting scene.
        var now: TimeInterval = 10
        let presentation = CanvasPresentation(clock: { now }, reduceMotion: { false })
        let restarted = ReceiverWindowController(defaults: defaults, pairingKey: key, artworkStore: store,
                                                 presentation: presentation)
        defer { restarted.shutdown(); restarted.close() }
        restarted.showDesignPage()
        let restartedRoot = try XCTUnwrap(restarted.window?.contentView)
        let picker = try editingTemplate(in: restartedRoot)
        eventually("saved profile artwork reloaded") { picker.isEnabled && restarted.receiverStatus.listening }
        for (name, id) in [("Lyrics", lyricsID), ("Scripture", old.id), ("Custom", old.id)] {
            selectTemplate(try XCTUnwrap(DesignProfileID(rawValue: name)), in: picker)
            let savedEditor = try XCTUnwrap(try button("Choose PNG…", in: restartedRoot).target as? LowerThirdWindowController)
            XCTAssertEqual(savedEditor.template.assetID, id)
            XCTAssertEqual(savedEditor.draftArtwork?.id, id)
        }
        var status = SenderStatus()
        let sender = SenderClient(name: "Template fixture") { status = $0 }
        defer { sender.disconnect() }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: restarted.receiverStatus.port!)!), key: key)
        eventually("fixture sender connected") { status.connected }
        restarted.showReceiverPage()
        let outputPreview = try XCTUnwrap(descendants(restartedRoot).compactMap { $0 as? OutputCanvas }.first)
        for (request, id) in [(ContentTemplate.lyrics, lyricsID), (.scripture, old.id), (.lyrics, lyricsID)] {
            let content = DisplayContent(body: "Original\nphrasing", template: request)
            sender.submit(content); sender.takeOutput()
            eventually("sender selects saved \(request.name) design") {
                outputPreview.presentation.artwork?.id == id && restarted.receiverStatus.content == content
            }
        }
        outputPreview.presentation.stopAnimation()
        sender.submit(.empty)
        eventually("empty snapshot hides the owned composition") { restarted.receiverStatus.content == .empty }
        XCTAssertEqual(outputPreview.presentation.artwork?.id, lyricsID, "An empty hide must retain the exiting Lyrics artwork")
        XCTAssertEqual(outputPreview.presentation.template.textTemplate, .lyrics)
        XCTAssertEqual(outputPreview.presentation.displayedContent.template, .lyrics)
        XCTAssertEqual(presentation.motion.target, 0)
        XCTAssertEqual(presentation.progress, 1)
        now += presentation.template.duration / 2
        XCTAssertEqual(presentation.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(presentation.displayedContent.template, .lyrics)
        now += presentation.template.duration
        eventually("completed exit clears displayed text") { presentation.displayedContent == .empty }
    }

    func testTemplateDesignFitsCompactWorkspace() throws {
        let domain = "AltViewTests.TemplateDesignLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "customTextEnabled")
        var library = TemplateDesignLibrary()
        library.lyrics.template.enabled = true; library.lyrics.template.lyricLineLayout = .compact
        library.lyrics.style.fontSize = 60; library.background = "00FF00"
        try defaults.set(JSONEncoder().encode(library), forKey: "templateDesignLibrary")
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "You are the light\nthat guides me home\nYou are the hope\nthat makes me whole", template: .lyrics)), forKey: "customTextDraft")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate())
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        controller.showDesignPage()
        let window = try XCTUnwrap(controller.window), root = try XCTUnwrap(window.contentView)
        window.setContentSize(NSSize(width: 1160, height: 650))
        let profiles = try editingTemplate(in: root)
        let samples = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Design preview content" })
        selectTemplate(.lyrics, in: profiles)
        samples.selectItem(withTitle: "Text draft"); samples.sendAction(samples.action, to: samples.target)
        window.orderFrontRegardless()
        for (name, appearance) in [("Light", NSAppearance.Name.aqua), ("Dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
            XCTAssertEqual(preview.bounds.width / preview.bounds.height, 16.0 / 9, accuracy: 0.01)
            XCTAssertGreaterThan(preview.bounds.width, 400)
            for control in [profiles as NSView, try button("Apply Changes", in: root), try button("Revert All Changes", in: root)] {
                XCTAssertTrue(root.bounds.contains(control.convert(control.bounds, to: root)))
            }
            let inspector = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first {
                $0.accessibilityLabel() == "Design inspector"
            })
            let document = try XCTUnwrap(inspector.documentView)
            inspector.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - inspector.contentSize.height)))
            inspector.reflectScrolledClipView(inspector.contentView)
            root.layoutSubtreeIfNeeded()
            XCTAssertFalse(profiles.visibleRect.isEmpty, "Template navigation must remain visible after scrolling")
            XCTAssertTrue(root.bounds.contains(profiles.convert(profiles.bounds, to: root)))
            let scope = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "designChangeScope" })
            XCTAssertFalse(scope.visibleRect.isEmpty, "The action scope must remain visible")
            XCTAssertEqual(preview.accessibilityLabel(), "You are the light that guides me home\nYou are the hope that makes me whole")
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            try XCTUnwrap(window.appearance).performAsCurrentDrawingAppearance {
                root.cacheDisplay(in: root.bounds, to: bitmap)
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "TemplateDesign-1160-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testDesignAppearanceRevertAndInvalidLayoutBlockPublication() throws {
        let editor = LowerThirdWindowController()
        defer { editor.shutdown() }
        var applied = LowerThirdTemplate(); applied.enabled = true
        editor.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "")
        editor.updateContent(draft: DisplayContent(body: "My draft"), source: .empty, externalSource: nil)
        let root = editor.contentView
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let font = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Draft font" })
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        editor.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "")
        XCTAssertEqual(preview.style.fontName, "Georgia")
        XCTAssertEqual(preview.accessibilityLabel(), "My draft")
        let height = try field("Body Height percent", in: root)
        height.stringValue = "oops"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: height))
        XCTAssertFalse(editor.canPublish)
        editor.revertChanges()
        XCTAssertTrue(editor.canPublish)
        XCTAssertEqual(preview.style.fontName, "System")
        XCTAssertFalse(editor.hasChanges)
    }

}
