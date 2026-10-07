import AppKit
import Network
import XCTest
@testable import AltView

private final class ConfidenceLayoutTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class ConfidenceTests: XCTestCase {
    func testEncryptedTextTakeoverHideClearDisconnectAndPause() throws {
        let suite = "ConfidenceText.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let confidence = ConfidenceViewController(defaults: defaults)
        let key = try PairingKey.generate()
        var status = ReceiverStatus(), lyricStatus = SenderStatus(), bibleStatus = SenderStatus()
        let receiver = ReceiverServer(receiverID: UUID()) { status = $0; confidence.update($0) }
        let lyrics = SenderClient(name: "eucaly") { lyricStatus = $0 }
        let bible = SenderClient(name: "ViewTheWord") { bibleStatus = $0 }
        defer {
            lyrics.disconnect(); bible.disconnect(); receiver.stop(); confidence.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        receiver.start(name: "Confidence text", key: key, advertise: false)
        eventually { status.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(status.port))!)
        lyrics.connect(to: endpoint, key: key); bible.connect(to: endpoint, key: key)
        eventually { lyricStatus.connected && bibleStatus.connected }
        XCTAssertEqual(lyricStatus.capabilities, [AltViewProtocol.confidenceText])
        XCTAssertNil(status.ownerID)
        lyrics.submit(.lyrics); lyrics.takeOutput()
        eventually { status.content == .lyrics }
        bible.submit(.scripture); bible.takeOutput()
        eventually { status.content == .scripture && status.ownerID == bible.senderID }
        eventually { bibleStatus.feedback.accepted }
        XCTAssertEqual(confidence.presentation.text.body, DisplayContent.scripture.body)
        var hidden = DisplayContent.scripture; hidden.visible = false
        bible.submit(hidden)
        eventually { status.content == hidden }
        XCTAssertEqual(confidence.presentation.text.body, hidden.body)
        receiver.clearOutput()
        eventually { status.ownerID == nil }
        XCTAssertEqual(confidence.presentation.text, .empty)
        bible.submit(.scripture); bible.takeOutput()
        eventually { status.content == .scripture }
        bible.disconnect()
        eventually { status.ownerID == nil && status.confidenceContent == .empty }
        XCTAssertEqual(confidence.presentation.text, .empty)
        receiver.stop()
        eventually { !status.listening }
        XCTAssertEqual(confidence.presentation.text, .empty)
        receiver.start(name: "Confidence text", key: key, advertise: false)
        eventually { status.listening }
        XCTAssertEqual(confidence.presentation.text, .empty)
        XCTAssertNil(status.ownerID)
    }

    func testAppearancePreferencesPreserveTextAndClockSettings() throws {
        let saved = Data(#"{"fontSize":120,"twentyFourHourClock":false}"#.utf8)
        let options = try JSONDecoder().decode(ConfidenceOptions.self, from: saved)
        XCTAssertEqual(options.fontSize, 120)
        XCTAssertEqual(options.fontName, "System"); XCTAssertEqual(options.alignment, .left)
        XCTAssertFalse(options.twentyFourHourClock)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        XCTAssertEqual(Set(written.keys), ["fontName", "fontSize", "alignment", "twentyFourHourClock"])
    }
    func testAudienceHideAndHiddenNavigationRetainExplicitConfidenceText() throws {
        var state = ReceiverState()
        let connection = UUID()
        XCTAssertTrue(state.register(connection: connection, senderID: UUID(), name: "eucaly"))
        let lease = try XCTUnwrap(state.take(connection: connection))
        let shown = ConfidenceText(body: "Presented lyric")
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 1,
                                  content: DisplayContent(body: shown.body, confidence: shown), supportsConfidence: true))
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 2,
                                  content: DisplayContent(body: "Hidden Current navigation", visible: false, confidence: shown), supportsConfidence: true))
        XCTAssertFalse(state.content.visible)
        XCTAssertEqual(state.confidenceContent, shown)
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 3,
                                  content: DisplayContent(visible: false, confidence: .empty), supportsConfidence: true))
        XCTAssertEqual(state.confidenceContent, .empty)
    }
    func testLegacyHideClearAndTakeoverCannotRestoreOtherText() throws {
        var state = ReceiverState()
        let a = UUID(), b = UUID()
        XCTAssertTrue(state.register(connection: a, senderID: UUID(), name: "Lyrics"))
        XCTAssertTrue(state.register(connection: b, senderID: UUID(), name: "Bible"))
        let first = try XCTUnwrap(state.take(connection: a))
        XCTAssertTrue(state.apply(connection: a, lease: first, revision: 1, content: .lyrics))
        var hidden = DisplayContent.lyrics; hidden.visible = false
        XCTAssertTrue(state.apply(connection: a, lease: first, revision: 2, content: hidden))
        XCTAssertEqual(state.confidenceContent.body, hidden.body)
        let second = try XCTUnwrap(state.take(connection: b))
        XCTAssertEqual(state.confidenceContent, .empty)
        XCTAssertFalse(state.apply(connection: a, lease: first, revision: 3, content: .lyrics))
        XCTAssertTrue(state.apply(connection: b, lease: second, revision: 1, content: .scripture))
        state.clearOwner()
        XCTAssertEqual(state.confidenceContent, .empty)
        XCTAssertFalse(state.apply(connection: b, lease: second, revision: 2, content: .scripture))
        XCTAssertNil(state.take(connection: UUID(), onlyIfUnowned: true))
    }
    func testConfidenceExtensionRoundTripsAndLegacyDecodingStillWorks() throws {
        let content = DisplayContent(body: "Audience hidden", visible: false, confidence: ConfidenceText(body: "Presented"))
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.append(FrameCodec.encode(WireMessage(kind: .state, content: content))).first?.content, content)
        let legacy = Data(#"{"body":"Legacy","visible":false}"#.utf8)
        let decoded = try JSONDecoder().decode(DisplayContent.self, from: legacy)
        XCTAssertNil(decoded.confidence)
        XCTAssertEqual(decoded.body, "Legacy")
    }
    func testConfidenceVisibilityAndAppearanceAreIndependent() {
        let scene = ConfidencePresentation()
        let content = ConfidenceText(title: "John 3:16", body: "For God so loved the world", footer: "KJV")
        scene.update(ReceiverStatus(content: DisplayContent(visible: false), confidenceContent: content))
        XCTAssertTrue(scene.visible)
        XCTAssertEqual(scene.text, content)
        var options = ConfidenceOptions(); options.fontSize = 120; options.alignment = .center
        scene.configure(options)
        XCTAssertEqual(scene.options, options)
        XCTAssertGreaterThan(scene.layout.main.width, 1700)
        scene.setVisible(false)
        scene.update(ReceiverStatus(confidenceContent: content))
        XCTAssertFalse(scene.visible, "Sender changes never unhide confidence")
        scene.setVisible(true)
        XCTAssertEqual(scene.text, content)
    }
    func testLongVerseFitsFullWidth() {
        let options = ConfidenceOptions()
        let content = ConfidenceText(title: "Esther 8:9", body: String(repeating: "Long multilingual verse സമാധാനം שלום. ", count: 70), footer: "Primary translation")
        let layout = ConfidenceLayout.make(text: content, options: options)
        XCTAssertLessThan(layout.bodySize, options.fontSize)
        XCTAssertLessThanOrEqual(CanvasTextLayout.measure(content.body, size: layout.bodySize, width: layout.body.width, style: options.style), layout.body.height + 0.1)
        XCTAssertEqual(layout.main.width, 1824)
    }
    func testDisplayDisconnectWaitsForSameIDAndStopCancelsRestoration() {
        _ = NSApplication.shared
        let chosen = OutputDisplay(id: 101, name: "Confidence", frame: NSRect(x: -8000, y: 0, width: 960, height: 540))
        var displays = [chosen]
        let output = OutputWindowController(name: "Confidence test", makeCanvas: { NSView() }, displays: { displays })
        defer { output.stop() }
        output.show(displayID: chosen.id)
        XCTAssertEqual(output.readiness, .ready)
        displays = [.init(id: 102, name: "Other output", frame: chosen.frame)]
        output.reconcile()
        XCTAssertEqual(output.readiness, .displayMissing)
        XCTAssertNil(output.activeDisplayID)
        XCTAssertTrue(output.isActive, "A missing monitor retains its assignment")
        displays.append(chosen); output.reconcile()
        XCTAssertEqual(output.readiness, .ready)
        output.stop(); output.reconcile()
        XCTAssertEqual(output.readiness, .closed)
        XCTAssertNil(output.activeDisplayID)
    }
    func testWorkspaceRejectsConflictingDisplayAssignmentsAndKeepsPreferencesIndependent() throws {
        let suite = "ConfidenceDisplays.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let display = OutputDisplay(id: 101, name: "Stage monitor", frame: NSRect(x: -8000, y: 0, width: 960, height: 540), identity: "stage")
        defaults.set(101, forKey: "outputDisplayID")
        defaults.set(101, forKey: "confidenceDisplayID")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), displays: { [display] })
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: suite) }
        let root = try XCTUnwrap(controller.window?.contentView)
        func views(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + views($0) } }
        func button(_ title: String) throws -> NSButton { try XCTUnwrap(views(root).compactMap { $0 as? NSButton }.first { $0.title == title }) }
        XCTAssertFalse(try button("Open Display").isEnabled)
        XCTAssertTrue(views(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("Assigned to Confidence") })
        controller.showConfidencePage()
        XCTAssertFalse(try button("Open Display").isEnabled)
        XCTAssertTrue(views(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("Assigned to Audience") })
        let picker = try XCTUnwrap(views(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "confidenceMonitorPicker" })
        picker.selectItem(at: 0); picker.sendAction(picker.action, to: picker.target)
        try button("Open Display").performClick(nil)
        XCTAssertTrue(controller.isPresenting)
        controller.closeConfidence()
        controller.showReceiverPage()
        XCTAssertTrue(try button("Open Display").isEnabled, "An explicit reassignment frees the audience monitor")
        controller.showConfidencePage()
        let size = try XCTUnwrap(views(root).compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Confidence font size" })
        size.doubleValue = 120; size.sendAction(size.action, to: size.target)
        let options = try JSONDecoder().decode(ConfidenceOptions.self, from: XCTUnwrap(defaults.data(forKey: "confidenceOptions")))
        XCTAssertEqual(options.fontSize, 120)
        XCTAssertNil(defaults.data(forKey: "outputStyle"))
        let audience = try JSONDecoder().decode(DisplayTarget.self, from: XCTUnwrap(defaults.data(forKey: "audienceMonitorAssignment")))
        XCTAssertEqual(audience.identity, "stage")
    }
    func testOversizedNegotiatedTextClearsTextAndKeepsTransportHealthy() throws {
        let key = try PairingKey.generate()
        var status = ReceiverStatus(), senderStatus = SenderStatus()
        let receiver = ReceiverServer(receiverID: UUID()) { status = $0 }
        let sender = SenderClient(name: "Frame limits") { senderStatus = $0 }
        defer { sender.disconnect(); receiver.stop() }
        receiver.start(name: "Frames", key: key, advertise: false)
        eventually { status.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(status.port))!), key: key)
        eventually { senderStatus.connected }
        sender.submit(.scripture); sender.takeOutput()
        eventually { status.content == .scripture }
        let text = String(repeating: "\u{01}", count: 6_000)
        sender.submit(DisplayContent(body: text, confidence: .init(body: text)))
        eventually { status.content == .empty && senderStatus.feedback.accepted }
        XCTAssertTrue(senderStatus.connected)
        XCTAssertEqual(status.confidenceContent, .empty)
    }
    func testConfidenceWorkspaceFitsCompactSizeInBothAppearances() throws {
        _ = NSApplication.shared
        let suite = "ConfidenceLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let window = ConfidenceLayoutTestWindow(contentRect: NSRect(x: -8000, y: 0, width: 1160, height: 650),
                                               styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), window: window)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: suite) }
        controller.showConfidencePage(); controller.showWindow(nil)
        window.setContentSize(NSSize(width: 1160, height: 650))
        let root = try XCTUnwrap(window.contentView)
        func views(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(views) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.bounds.width, 1160, accuracy: 1)
            XCTAssertEqual(root.bounds.height, 650, accuracy: 1)
            let canvas = try XCTUnwrap(views(root).compactMap { $0 as? ConfidenceCanvas }.first)
            let preview = canvas.convert(canvas.bounds, to: root)
            XCTAssertTrue(root.bounds.contains(preview)); XCTAssertGreaterThan(preview.width, 300)
            XCTAssertEqual(preview.width / preview.height, 16.0 / 9, accuracy: 0.01)
            XCTAssertTrue(try XCTUnwrap(views(root).compactMap { $0 as? NSButton }.first { $0.title == "Close Display" }).isHidden)
            for title in ["Open Display", "Hide Confidence", "Identify"] {
                let button = try XCTUnwrap(views(root).compactMap { $0 as? NSButton }.first { $0.title == title })
                XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)))
                XCTAssertFalse(button.visibleRect.isEmpty, "\(title) must remain reachable at compact size")
            }
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
            try png.write(to: URL(fileURLWithPath: "/private/tmp/altview-confidence-workspace-\(appearance.rawValue).png"))
        }
    }
    func testRenderConfidenceFixtures() throws {
        _ = NSApplication.shared
        let scene = ConfidencePresentation()
        let verse = ConfidenceText(title: "JOHN 3:16", body: "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life.", footer: "King James Version")
        for (name, text) in [("scripture", verse), ("lyrics", ConfidenceText(body: "Amazing grace! How sweet the sound\nThat saved a wretch like me!\nI once was lost, but now am found;\nWas blind, but now I see."))] {
            scene.update(ReceiverStatus(confidenceContent: text))
            let view = ConfidenceCanvas(presentation: scene); view.frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/altview-confidence-\(name).png"))
        }
    }
    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "Timed out waiting for confidence state", file: file, line: line)
    }
}
