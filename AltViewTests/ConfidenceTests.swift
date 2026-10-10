import AppKit
import Network
import XCTest
@testable import AltView

private final class ConfidenceLayoutTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

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
    func testDualTranslationLayoutFitsBothColumnsAndSingleTranslationRegainsWidth() throws {
        let options = ConfidenceOptions()
        var text = ConfidenceText(title: "Esther 8:9", body: "Short primary text", footer: "Primary translation",
            secondary: .init(body: String(repeating: "Long multilingual verse സമാധാനം שלום. ", count: 70), footer: "Secondary translation"))
        let dual = ConfidenceLayout.make(text: text, options: options)
        let secondary = try XCTUnwrap(dual.secondaryBody), footer = try XCTUnwrap(dual.secondaryFooter)
        XCTAssertEqual(dual.body.width, secondary.width); XCTAssertEqual(dual.body.minY, secondary.minY)
        XCTAssertGreaterThan(secondary.minX, dual.body.maxX)
        XCTAssertGreaterThan(dual.title.minY, ConfidenceLayout.clockBand.maxY)
        XCTAssertEqual(dual.title.width, dual.main.width)
        XCTAssertEqual(footer.minX, secondary.minX); XCTAssertEqual(dual.footer.width, footer.width)
        XCTAssertLessThan(dual.bodySize, options.fontSize)
        for (value, rect) in [(text.body, dual.body), (text.secondary!.body, secondary)] {
            XCTAssertLessThanOrEqual(CanvasTextLayout.measure(value, size: dual.bodySize, width: rect.width, style: options.style), rect.height + 0.1)
            XCTAssertTrue(dual.main.contains(rect))
        }
        XCTAssertNotNil(dual.divider)
        text.secondary = nil
        let single = ConfidenceLayout.make(text: text, options: options)
        XCTAssertEqual(single.body.width, single.main.width); XCTAssertNil(single.secondaryBody); XCTAssertNil(single.divider)
        text.secondary = .init(body: " \n ", footer: "No verse")
        XCTAssertNil(ConfidenceLayout.make(text: text, options: options).secondaryBody)
    }
    func testEncryptedDualTranslationsReachConfidenceWhileAudienceRemainsPrimary() throws {
        let key = try PairingKey.generate(), scene = ConfidencePresentation()
        var output = ReceiverStatus(), status = SenderStatus()
        let receiver = ReceiverServer(receiverID: UUID()) { output = $0; scene.update($0) }
        let sender = SenderClient(name: "ViewTheWord") { status = $0 }
        defer { sender.disconnect(); receiver.stop(); scene.media.shutdown() }
        receiver.start(name: "Dual confidence", key: key, advertise: false)
        eventually { output.listening }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
        eventually { status.connected }
        var content = DisplayContent(title: "John 3:16", body: "Audience primary", footer: "NIV",
            confidence: .init(title: "John 3:16", body: "Audience primary", footer: "NIV", secondary: .init(body: "Confidence secondary", footer: "NLT")))
        sender.submit(content); sender.takeOutput()
        eventually { status.feedback.accepted && scene.text.secondary?.body == "Confidence secondary" }
        XCTAssertEqual(output.content.body, "Audience primary"); XCTAssertEqual(output.content.footer, "NIV")
        let audience = OutputCanvas(frame: .zero)
        audience.presentation.update(content: output.content, style: OutputStyle(), template: LowerThirdTemplate(), artwork: nil, immediately: true)
        XCTAssertFalse(audience.accessibilityLabel()?.contains("Confidence secondary") ?? true)
        let confidence = ConfidenceCanvas(presentation: scene)
        XCTAssertTrue(confidence.accessibilityLabel()?.contains("Confidence secondary") ?? false)
        content.visible = false; sender.submit(content)
        eventually { !output.content.visible && status.feedback.accepted }
        XCTAssertEqual(scene.text.secondary?.body, "Confidence secondary")
        content.confidence?.secondary = nil; sender.submit(content)
        eventually { scene.text.secondary == nil && status.feedback.accepted }
        XCTAssertEqual(scene.layout.body.width, scene.layout.main.width)
        receiver.clearOutput()
        eventually { scene.text == .empty }
    }
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
        XCTAssertEqual(lyricStatus.capabilities, Set(AltViewProtocol.capabilities))
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
    func testLocalMediaPreferenceRestoresInConfidenceWorkspace() throws {
        _ = NSApplication.shared
        let suite = "ConfidenceMediaWorkspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "confidenceLocalMediaEnabled")
        let controller = ConfidenceViewController(defaults: defaults)
        defer { controller.shutdown() }
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        let views = descendants(controller.view)
        XCTAssertTrue(controller.presentation.media.enabled)
        XCTAssertEqual(controller.output.readiness, .closed)
        let toggle = try XCTUnwrap(views.compactMap { $0 as? NSSwitch }.first { $0.accessibilityIdentifier() == "confidenceMediaSwitch" })
        XCTAssertEqual(toggle.state, .on)
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("Remembers your choice.") })
        toggle.state = .off; toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertFalse(defaults.bool(forKey: "confidenceLocalMediaEnabled"))
        controller.shutdown()
        let resumed = ConfidenceViewController(defaults: defaults)
        defer { resumed.shutdown() }
        XCTAssertFalse(resumed.presentation.media.enabled)
        XCTAssertEqual(try XCTUnwrap(descendants(resumed.view).compactMap { $0 as? NSSwitch }.first).state, .off)
        XCTAssertEqual(resumed.output.readiness, .closed)
    }
    func testMediaSetupActionAndEmptyPreviewGuidanceStayInOperatorWorkspace() throws {
        _ = NSApplication.shared
        let suite = "ConfidenceMediaSetup.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "confidenceLocalMediaEnabled")
        let notifications = NotificationCenter()
        var allowed = false, asks = 0, settingsOpens = 0
        let media = ConfidenceMediaController(defaults: defaults, hasPermission: { allowed }, askPermission: { asks += 1 }, applicationNotifications: notifications)
        let controller = ConfidenceViewController(defaults: defaults, media: media, openScreenRecordingSettings: { settingsOpens += 1; return false })
        defer { controller.shutdown() }
        let window = ConfidenceLayoutTestWindow(contentRect: NSRect(x: -8000, y: 0, width: 1000, height: 650),
                                               styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        UI.fill(controller.view, in: root, padding: 24)
        window.orderFront(nil)
        defer { window.close() }
        func render(_ name: String) throws {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                root.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
                let image = NSImage(size: root.bounds.size)
                image.lockFocus()
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill(); root.bounds.fill()
                }
                let snapshot = NSImage(size: root.bounds.size); snapshot.addRepresentation(bitmap)
                snapshot.draw(in: root.bounds, from: .zero, operation: .sourceOver, fraction: 1)
                image.unlockFocus()
                let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/private/tmp/altview-media-\(name)-\(appearance.rawValue).png"))
            }
        }
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        let views = descendants(controller.view)
        let action = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "confidenceMediaAction" })
        let state = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "confidenceMediaState" })
        let notice = try XCTUnwrap(views.compactMap { $0 as? ConfidencePreviewNotice }.first)
        XCTAssertEqual(asks, 0, "Restoring the workspace must not request permission")
        XCTAssertEqual(state.stringValue, "Permission needed")
        XCTAssertEqual(action.title, "Open Screen Recording Settings…")
        XCTAssertFalse(action.isHidden); XCTAssertFalse(notice.isHidden)
        try render("permission")
        action.performClick(nil)
        XCTAssertEqual(asks, 1, "Only the explicit action can register an initial access request")
        XCTAssertEqual(settingsOpens, 1)
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Open System Settings manually") })

        allowed = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(state.stringValue, "Waiting for media")
        XCTAssertTrue(action.isHidden, "Waiting for a slide has nothing to retry")
        XCTAssertTrue(descendants(notice).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Current pane") })
        try render("waiting")
        controller.update(.init(ownerName: "Eucaly · Other Mac", confidenceMedia: .init(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()), process: nil)))
        XCTAssertEqual(state.stringValue, "Connection is not local")
        XCTAssertFalse(notice.isHidden); XCTAssertTrue(action.isHidden)
        XCTAssertTrue(descendants(notice).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("over the network") })
        try render("remote")

        controller.update(.init(ownerName: "Eucaly · This Mac", confidenceMedia: .init(connection: UUID(), lease: UUID(), revision: 1,
            presentation: .init(sessionID: UUID(), mode: .media, windowID: 77, windowGeneration: UUID()),
            process: nil, sourceIssue: .missingIdentity)))
        XCTAssertEqual(state.stringValue, "Cannot verify local Eucaly")
        XCTAssertFalse(notice.isHidden); XCTAssertTrue(action.isHidden)
        XCTAssertTrue(descendants(notice).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("connected locally") })
        XCTAssertEqual(asks, 1, "An unverified local source cannot request capture access")
        try render("unverified")

        let output = ConfidenceCanvas(presentation: controller.presentation)
        output.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        XCTAssertFalse(descendants(output).contains { $0 is ConfidencePreviewNotice }, "Operator hints must never be part of output canvases")
        let bitmap = try XCTUnwrap(output.bitmapImageRepForCachingDisplay(in: output.bounds))
        output.cacheDisplay(in: output.bounds, to: bitmap)
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(center.redComponent, 0.01); XCTAssertLessThan(center.greenComponent, 0.01); XCTAssertLessThan(center.blueComponent, 0.01)
        controller.update(.init(confidenceContent: .init(body: "Presented lyric")))
        XCTAssertTrue(notice.isHidden, "Setup guidance must not cover presented text")
        let hide = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Hide Confidence" })
        hide.performClick(nil)
        XCTAssertFalse(notice.isHidden)
        let open = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Open Display" })
        open.performClick(nil)
        XCTAssertTrue(controller.presentation.visible)
        XCTAssertTrue(notice.isHidden, "Reopening an output must remove the old hidden-output guidance")
    }
    func testAudienceHideAndHiddenNavigationRetainExplicitConfidenceText() throws {
        var state = ReceiverState()
        let connection = UUID()
        XCTAssertTrue(state.register(connection: connection, senderID: UUID(), name: "eucaly"))
        let lease = try XCTUnwrap(state.take(connection: connection))
        let shown = ConfidenceText(body: "Presented lyric")
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 1,
                                  content: DisplayContent(body: shown.body, confidence: shown)))
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 2,
                                  content: DisplayContent(body: "Hidden Current navigation", visible: false, confidence: shown)))
        XCTAssertFalse(state.content.visible)
        XCTAssertEqual(state.confidenceContent, shown)
        XCTAssertTrue(state.apply(connection: connection, lease: lease, revision: 3,
                                  content: DisplayContent(visible: false, confidence: .empty)))
        XCTAssertEqual(state.confidenceContent, .empty)
    }
    func testCustomTextSnapshotsAndTakeoverCannotRestoreOtherText() throws {
        var state = ReceiverState()
        let a = UUID(), b = UUID()
        XCTAssertTrue(state.register(connection: a, senderID: UUID(), name: "Lyrics"))
        XCTAssertTrue(state.register(connection: b, senderID: UUID(), name: "Bible"))
        let first = try XCTUnwrap(state.take(connection: a))
        XCTAssertTrue(state.apply(connection: a, lease: first, revision: 1, content: .lyrics))
        var hidden = DisplayContent.lyrics; hidden.visible = false
        XCTAssertTrue(state.apply(connection: a, lease: first, revision: 2, content: hidden))
        XCTAssertEqual(state.confidenceContent.body, hidden.body)
        hidden.body = "Changed custom text while Audience is hidden"
        XCTAssertTrue(state.apply(connection: a, lease: first, revision: 3, content: hidden))
        XCTAssertEqual(state.confidenceContent.body, hidden.body, "Complete custom-text snapshots never retain obsolete text")
        let second = try XCTUnwrap(state.take(connection: b))
        XCTAssertEqual(state.confidenceContent, .empty)
        XCTAssertFalse(state.apply(connection: a, lease: first, revision: 4, content: .lyrics))
        XCTAssertTrue(state.apply(connection: b, lease: second, revision: 1, content: .scripture))
        state.clearOwner()
        XCTAssertEqual(state.confidenceContent, .empty)
        XCTAssertFalse(state.apply(connection: b, lease: second, revision: 2, content: .scripture))
        XCTAssertNil(state.take(connection: UUID(), onlyIfUnowned: true))
    }
    func testConfidenceSnapshotRoundTripsIndependentlyOfAudienceVisibility() throws {
        let content = DisplayContent(body: "Audience hidden", visible: false, confidence: ConfidenceText(body: "Presented"))
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.append(FrameCodec.encode(WireMessage(kind: .state, content: content))).first?.content, content)
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
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), advertiseReceiver: false, displays: { [display] })
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
    func testOversizedConfidenceTextClearsTextAndKeepsTransportHealthy() throws {
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
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), advertiseReceiver: false, window: window)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: suite) }
        controller.showConfidencePage(); controller.showWindow(nil)
        window.setContentSize(NSSize(width: 1160, height: 650))
        let root = try XCTUnwrap(window.contentView)
        func views(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(views) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            root.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
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
            window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
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
        var dual = verse
        dual.secondary = .init(body: "ദൈവം ലോകത്തെ സ്നേഹിച്ചു.\nഅവനിൽ വിശ്വസിക്കുന്നവർക്ക്\nനിത്യജീവൻ ഉണ്ടാകുന്നു.", footer: "മലയാളം")
        for (name, text) in [("scripture", verse), ("dual", dual), ("lyrics", ConfidenceText(body: "Amazing grace! How sweet the sound\nThat saved a wretch like me!\nI once was lost, but now am found;\nWas blind, but now I see.")), ("12-hour", verse)] {
            var options = ConfidenceOptions(); options.twentyFourHourClock = name != "12-hour"
            scene.configure(options)
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
